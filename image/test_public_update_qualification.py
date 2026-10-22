"""Exercise guest harness failure transitions without packages, systemd or VMs."""
import hashlib
from contextlib import ExitStack, contextmanager, nullcontext, redirect_stdout
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import types
import unittest
from unittest.mock import Mock, patch

import public_update_qualification as public
import qualification


class InterruptedFixture(Exception):
    pass


class PublicUpdateQualification(unittest.TestCase):
    def health_fixture(self):
        required = {'system': {'candidate.service': {'enabled': True, 'active': True}},
                    'user': {'desktop.service': {'active': True}}}
        evidence = {'public_manager_version': '259.10-1.fc44', 'ssh_user': 'qualification', 'ssh_uid': 1000}
        for scope, policy in required.items():
            evidence[scope] = {name: {'Id': name, 'Markers': [], 'LoadState': 'loaded',
                                     'ActiveState': 'active', 'SubState': 'running',
                                     'UnitFileState': 'enabled', 'Result': 'success'} for name in policy}
        return required, evidence

    def test_pending_rpm_trigger_work_in_either_manager_rejects_public_success(self):
        for scope in ('system', 'user'):
            for marker in ('needs-restart', 'needs-reload'):
                with self.subTest(scope=scope, marker=marker):
                    required, evidence = self.health_fixture()
                    # Include an unrelated loaded unit: a failed user bridge
                    # can strand required work outside the candidate's units.
                    evidence[scope]['other.service'] = {'Markers': ['custom-marker', marker]}
                    with self.assertRaisesRegex(RuntimeError, 'Pending RPM-trigger work in ' + scope):
                        public.validate_public_health(evidence, required)

    def test_other_marker_types_are_retained_and_do_not_request_actions(self):
        required, evidence = self.health_fixture()
        markers = ['custom-marker', 'needs-reboot']
        evidence['user']['desktop.service']['Markers'] = markers[:]
        public.validate_public_health(evidence, required)
        self.assertEqual(evidence['user']['desktop.service']['Markers'], markers)

    def test_missing_marker_inventory_and_unhealthy_required_services_are_rejected(self):
        for damage in ('missing-unit', 'missing-markers', 'unloaded', 'disabled',
                       'inactive', 'failed', 'activating', 'failed-result', 'missing-result'):
            with self.subTest(damage=damage):
                required, evidence = self.health_fixture()
                unit = evidence['system']['candidate.service']
                if damage == 'missing-unit':
                    evidence['system'].clear()
                elif damage == 'missing-markers':
                    unit.pop('Markers')
                elif damage == 'unloaded':
                    unit['LoadState'] = 'not-found'
                elif damage == 'disabled':
                    unit['UnitFileState'] = 'disabled'
                elif damage == 'failed-result':
                    unit['Result'] = 'timeout'
                elif damage == 'missing-result':
                    unit.pop('Result')
                else:
                    unit['ActiveState'] = damage
                with self.assertRaises(RuntimeError):
                    public.validate_public_health(evidence, required)

    def test_enabled_oneshot_may_be_inactive_but_must_have_succeeded(self):
        required, evidence = self.health_fixture()
        required['system']['candidate.service'].pop('active')
        evidence['system']['candidate.service'].update(ActiveState='inactive', SubState='dead')
        public.validate_public_health(evidence, required)
        evidence['system']['candidate.service']['Result'] = 'exit-code'
        with self.assertRaisesRegex(RuntimeError, 'unhealthy'):
            public.validate_public_health(evidence, required)

    def collect_health(self, *, version='s "259.10-1.fc44"\n', missing_markers=False, extra_units=()):
        required, evidence = self.health_fixture()
        for scope in ('system', 'user'):
            for name in extra_units:
                evidence[scope][name] = {'Id': name, 'Markers': [], 'LoadState': 'loaded',
                                         'ActiveState': 'active', 'SubState': 'running',
                                         'UnitFileState': 'enabled', 'Result': 'success'}
        calls = []
        def command(args, **options):
            calls.append((args, options, dict(os.environ)))
            self.assertTrue(options['check'])
            self.assertGreater(options['timeout'], 0)
            self.assertLessEqual(options['timeout'], 10)
            if args[0] == '/usr/bin/busctl':
                return types.SimpleNamespace(stdout=version)
            scope = 'user' if '--user' in args else 'system'
            if 'list-units' in args:
                output = json.dumps([{'unit': name} for name in evidence[scope]])
            else:
                self.assertEqual(args[:7], ['/usr/bin/systemctl', '--' + scope, '--no-pager',
                    'show', '--all', '--property=Id,Markers,LoadState,ActiveState,SubState,UnitFileState,Result', '--'])
                names = args[7:]
                self.assertGreater(len(names), 0)
                self.assertLessEqual(len(names), 64)
                output = '\n\n'.join('\n'.join(key + '=' + (' '.join(value) if key == 'Markers' else value)
                    for key, value in state.items() if not (missing_markers and key == 'Markers'))
                    for state in (evidence[scope][name] for name in names)) + '\n'
            return types.SimpleNamespace(stdout=output)
        output = io.StringIO()
        account = types.SimpleNamespace(pw_name='qualification', pw_uid=1000)
        with patch('subprocess.run', side_effect=command), patch('os.getuid', return_value=1000), \
                patch('pwd.getpwuid', return_value=account), patch.dict(os.environ), redirect_stdout(output):
            exec(compile(public.PUBLIC_HEALTH, '<public-health-guest>', 'exec'), {'required': required})
        return json.loads(output.getvalue()), calls

    def test_actual_collector_uses_public_system_bus_and_ordinary_user_session_reads_only(self):
        evidence, calls = self.collect_health()
        self.assertEqual(evidence['public_manager_version'], '259.10-1.fc44')
        self.assertEqual(calls[0][0], ['/usr/bin/busctl', '--system', '--timeout=10', 'get-property',
            'org.freedesktop.systemd1', '/org/freedesktop/systemd1', 'org.freedesktop.systemd1.Manager', 'Version'])
        self.assertEqual(calls[0][2]['DBUS_SYSTEM_BUS_ADDRESS'], 'unix:path=/run/dbus/system_bus_socket')
        user_calls = [entry for entry in calls if '--user' in entry[0]]
        self.assertEqual(len(user_calls), 2)
        for args, _options, environment in user_calls:
            self.assertEqual(environment['XDG_RUNTIME_DIR'], '/run/user/1000')
            self.assertEqual(environment['DBUS_SESSION_BUS_ADDRESS'], 'unix:path=/run/user/1000/bus')
        for args, _options, _environment in calls:
            self.assertFalse(any(item.startswith(('-M', '--machine')) for item in args))
            self.assertFalse({'daemon-reload', 'restart', 'reload-or-restart', 'set-property', 'sudo'} & set(args))

    def test_collector_rejects_invalid_public_version_or_missing_marker_properties(self):
        for version in ('', 's ""\n', 'u 259\n', 's "259" extra\n'):
            with self.subTest(version=version), self.assertRaisesRegex(RuntimeError, 'Manager.Version'):
                self.collect_health(version=version)
        with self.assertRaisesRegex(RuntimeError, 'Incomplete'):
            self.collect_health(missing_markers=True)

    def test_collector_preserves_dash_leading_and_escaped_unit_names_across_chunks_in_both_scopes(self):
        special = ('-.mount', '-.slice', r'dev-disk-by\x2duuid-1234.device',
                   r'var-lib-machine\x20images.mount', r'app-example\x5cname.service')
        names = (*special, *(f'fixture-{index:03d}.service' for index in range(130)))
        evidence, calls = self.collect_health(extra_units=names)
        required, _ = self.health_fixture()
        public.validate_public_health(evidence, required)
        for scope in ('system', 'user'):
            expected = sorted(set(names) | set(required[scope]))
            chunks = [args[7:] for args, _options, _environment in calls
                      if '--' + scope in args and 'show' in args]
            self.assertEqual(chunks, [expected[offset:offset + 64] for offset in range(0, len(expected), 64)])
            self.assertEqual(len(chunks), 3)
            self.assertEqual(chunks[0][:2], ['-.mount', '-.slice'])
            self.assertEqual(set(evidence[scope]), set(expected))
            for name in special:
                self.assertEqual(evidence[scope][name]['Id'], name)

    def assert_nested_health_failure(self, diagnostic, password, expected_stderr):
        import traceback
        required, _ = self.health_fixture()
        failures = (subprocess.CalledProcessError(1, ['/usr/bin/systemctl'], stderr=diagnostic),
                    subprocess.TimeoutExpired(['/usr/bin/systemctl'], 10, stderr=diagnostic.encode()))
        for failure in failures:
            with self.subTest(failure=type(failure).__name__):
                def command(args, **options):
                    self.assertTrue(options['check'])
                    self.assertGreater(options['timeout'], 0)
                    self.assertLessEqual(options['timeout'], 10)
                    if args[0] == '/usr/bin/busctl':
                        return types.SimpleNamespace(stdout='s "259.10-1.fc44"\n')
                    if 'list-units' in args:
                        return types.SimpleNamespace(stdout='[{"unit":"-.mount"}]')
                    self.assertIn('show', args)
                    self.assertEqual(args[6], '--')
                    raise failure
                nested = Mock(side_effect=command)
                authenticated = Mock()
                nested_messages = []
                def ssh(args, **options):
                    self.assertEqual(args, ['ssh-fixture', 'python3 -'])
                    self.assertEqual(options['timeout'], 55)
                    self.assertNotIn(password, options['input'])
                    account = types.SimpleNamespace(pw_name='qualification', pw_uid=1000)
                    with patch('subprocess.run', nested), patch('os.getuid', return_value=1000), \
                            patch('pwd.getpwuid', return_value=account), patch.dict(os.environ):
                        try:
                            exec(compile(options['input'], '<public-health-guest>', 'exec'), {})
                        except RuntimeError as error:
                            nested_messages.append(str(error))
                            remote_stderr = traceback.format_exc()
                        else:
                            self.fail('The failing collector command succeeded')
                    raise subprocess.CalledProcessError(1, args, output='', stderr=remote_stderr)
                with patch.object(public, 'required_service_states', return_value=required), \
                        patch.object(public, 'run', side_effect=ssh) as fresh_ssh:
                    with self.assertRaisesRegex(RuntimeError, 'public health inspection failed') as raised:
                        public.verify_public_health(types.SimpleNamespace(ssh=['ssh-fixture']), password, authenticated)
                message = str(raised.exception)
                self.assertNotIn(password, message)
                if len(diagnostic) > 2000:
                    self.assertNotIn(diagnostic, message)
                    self.assertNotIn(password[len(password) // 2:], message)
                    self.assertNotIn('[redacted]', message)
                else:
                    self.assertIn('[redacted]', message)
                self.assertIn(expected_stderr.replace(password, '[redacted]'), message)
                reason = 'timed out' if isinstance(failure, subprocess.TimeoutExpired) else 'exited 1'
                self.assertEqual(nested_messages, ['Public health command systemctl ' + reason + ': ' + expected_stderr])
                fresh_ssh.assert_called_once()
                self.assertEqual(nested.call_count, 3)
                authenticated.assert_not_called()

    def test_nested_command_failure_omits_excess_stderr_without_retry_or_credentials(self):
        password = 'fixture-password'
        diagnostic = 'x' * 6000 + password + ": /usr/bin/systemctl: invalid option -- '.'"
        self.assert_nested_health_failure(diagnostic, password,
            f'[stderr omitted: {len(diagnostic)} characters exceeds 2000-character limit]')

    def test_nested_command_stderr_limit_preserves_complete_diagnostics_for_outer_redaction(self):
        password = 'fixture-password-CUTOFF_TOKEN'
        useful = ": /usr/bin/systemctl: invalid option -- '.'"
        for size in (1999, 2000, 2001):
            with self.subTest(size=size):
                diagnostic = 'x' * (size - len(password) - len(useful)) + password + useful
                self.assertEqual(len(diagnostic), size)
                expected = diagnostic if size <= 2000 else (
                    '[stderr omitted: 2001 characters exceeds 2000-character limit]')
                self.assert_nested_health_failure(diagnostic, password, expected)

    def test_excess_nested_stderr_omits_credentials_before_across_at_and_after_old_tail_cutoff(self):
        password = 'fixture-password-CUTOFF_TOKEN'
        useful = ": /usr/bin/systemctl: invalid option -- '.'"
        size = 6000
        cutoff = size - 2000
        positions = (cutoff - len(password) - 1, cutoff - len(password) // 2, cutoff, cutoff + 1)
        for start in positions:
            with self.subTest(start=start):
                diagnostic = 'x' * start + password + 'x' * (size - start - len(password) - len(useful)) + useful
                self.assertEqual(len(diagnostic), size)
                # Every case would put this distinctive credential suffix in
                # a raw tail, except the credential wholly before the cutoff.
                if start + len(password) > cutoff:
                    self.assertIn('CUTOFF_TOKEN', diagnostic[-2000:])
                self.assert_nested_health_failure(diagnostic, password,
                    '[stderr omitted: 6000 characters exceeds 2000-character limit]')

    def test_public_health_must_precede_authenticated_sudo_and_failure_never_falls_back(self):
        required, evidence = self.health_fixture()
        guest = Mock(return_value=types.SimpleNamespace(stdout='0\n'))
        with patch.object(public, 'required_service_states', return_value=required), \
                patch.object(public, 'run', return_value=types.SimpleNamespace(stdout=json.dumps(evidence))), \
                patch('subprocess.run', return_value=types.SimpleNamespace(returncode=1)):
            result = public.verify_public_health(types.SimpleNamespace(ssh=['ssh']), 'fixture-password', guest)
        self.assertTrue(result['password_authenticated_sudo'])
        guest.assert_called_once_with(unittest.mock.ANY, 'id -u\n', 'fixture-password', timeout=15)
        for failure in (subprocess.CalledProcessError(1, ['busctl'], stderr='fixture-password bus unavailable'),
                        subprocess.TimeoutExpired(['ssh'], 55, stderr=b'fixture-password timeout')):
            guest.reset_mock()
            with patch.object(public, 'required_service_states', return_value=required), \
                    patch.object(public, 'run', side_effect=failure) as inspect:
                with self.assertRaisesRegex(RuntimeError, 'public health inspection failed') as raised:
                    public.verify_public_health(types.SimpleNamespace(ssh=['ssh']), 'fixture-password', guest)
            self.assertNotIn('fixture-password', str(raised.exception))
            inspect.assert_called_once()
            guest.assert_not_called()

    def test_public_health_rejects_broken_or_passwordless_sudo(self):
        required, evidence = self.health_fixture()
        for returncode in (0, 2, 255):
            with self.subTest(returncode=returncode), \
                    patch.object(public, 'required_service_states', return_value=required), \
                    patch.object(public, 'run', return_value=types.SimpleNamespace(stdout=json.dumps(evidence))), \
                    patch('subprocess.run', return_value=types.SimpleNamespace(returncode=returncode)):
                guest = Mock()
                with self.assertRaisesRegex(RuntimeError, 'sudo no longer requires'):
                    public.verify_public_health(types.SimpleNamespace(ssh=['ssh']), 'fixture-password', guest)
                guest.assert_not_called()
        with patch.object(public, 'required_service_states', return_value=required), \
                patch.object(public, 'run', return_value=types.SimpleNamespace(stdout=json.dumps(evidence))), \
                patch('subprocess.run', return_value=types.SimpleNamespace(returncode=1)):
            with self.assertRaisesRegex(RuntimeError, 'authenticated sudo is not functional'):
                public.verify_public_health(types.SimpleNamespace(ssh=['ssh']), 'fixture-password',
                                            Mock(return_value=types.SimpleNamespace(stdout='1000\n')))

    def test_unhealthy_post_commit_runtime_cannot_earn_commit_or_no_workers_evidence(self):
        import upgrade_qualification as upgrade
        from qualification_contract import PUBLIC_UPDATE
        for outcome in ('health-failure', 'helper-identity-failure', 'first-control-close', 'second-control-close', 'success'):
            healthy = outcome == 'success'
            with self.subTest(outcome=outcome), tempfile.TemporaryDirectory() as temporary, ExitStack() as stack:
                candidate = Path(temporary) / 'desktop.rpm'
                offline = Path(temporary) / 'offline.rpm'
                candidate.write_bytes(b'desktop')
                offline.write_bytes(b'offline')
                desktop_sha = hashlib.sha256(candidate.read_bytes()).hexdigest()
                offline_sha = hashlib.sha256(offline.read_bytes()).hexdigest()
                report = {'checks': [], 'candidate_rpm_sha256': desktop_sha,
                          'candidate_offline_rpm_sha256': offline_sha}
                staged = {'candidate': '/sealed/desktop.rpm', 'offline_candidate': '/sealed/offline.rpm'}
                stack.enter_context(patch.object(upgrade, 'copy_candidate', side_effect=[desktop_sha, offline_sha, None, None]))
                stack.enter_context(patch.object(upgrade, 'copy_dependencies', side_effect=lambda *a, **kw: nullcontext(staged)))
                stack.enter_context(patch.object(upgrade, 'inspect_version', return_value={'installed': 'candidate', 'candidate': 'candidate'}))
                for name in ('provision_fixture', 'stop_interrupted', 'cleanup_fixture', 'boot_recovered'):
                    stack.enter_context(patch.object(public, name))
                stack.enter_context(patch.object(public, 'transfer_source', return_value='a' * 64))
                stack.enter_context(patch.object(public, 'start_public', side_effect=['interrupted-run', 'committed-run']))
                stack.enter_context(patch.object(public, 'wait_public', return_value=({}, {})))
                stack.enter_context(patch.object(public, 'verify_recovered', return_value={'rootUuid': 'same-root'}))
                health = stack.enter_context(patch.object(public, 'verify_public_health', return_value={'public_manager_version': '259.10'},
                    side_effect=None if healthy else RuntimeError('Pending RPM-trigger work')))
                no_workers = stack.enter_context(patch.object(public, 'verify_no_workers'))
                helper_identity = {'expected_sha256': 'b' * 64, 'actual_sha256': 'b' * 64}
                identity = stack.enter_context(patch.object(public, 'verify_installed_updater',
                    return_value=helper_identity,
                    side_effect=RuntimeError('Installed updater differs from candidate')
                    if outcome == 'helper-identity-failure' else None))
                build = {'source_revision': '1' * 40, 'source_content_sha256': '2' * 64}
                guest = Mock(return_value=types.SimpleNamespace(stdout=json.dumps(build)))
                events = []
                class Control:
                    def __init__(self, _vm, _password):
                        self.vm, self.password = _vm, _password
                    def __enter__(self):
                        events.append('ready')
                        return self
                    def __exit__(self, *_args):
                        events.append('closed')
                        if ((outcome == 'first-control-close' and events.count('closed') == 1)
                                or (outcome == 'second-control-close' and events.count('closed') == 2)):
                            raise RuntimeError('Control close failed')
                    def __call__(self, *args, **kwargs):
                        return guest(*args, **kwargs)
                    def start(self):
                        self.identifier = public.start_public(self.vm, self.password)
                        return self.identifier
                    def poweroff(self):
                        events.append('poweroff')
                    def ensure_drained(self):
                        return True
                    def cleanup_staging(self, *_args, **_kwargs):
                        pass
                stack.enter_context(patch.object(public, 'PublicControl', Control))
                def check_health(*_args):
                    self.assertEqual(events, ['ready', 'poweroff', 'closed', 'ready', 'closed'])
                    self.assertEqual(guest.call_args.args[1], public.PROVISION_TIMEOUT)
                    if not healthy:
                        raise RuntimeError('Pending RPM-trigger work')
                    return {'public_manager_version': '259.10'}
                health.side_effect = check_health
                options = dict(candidate_dependencies=None, boot_installed=Mock(), poweroff_installed=Mock(), verify_user_choices=Mock(),
                               preference={}, report=report)
                if healthy:
                    public.qualify_public_updater(Mock(), candidate, offline, 'fixture', guest, **options)
                    self.assertIn('public-updater-committed', report['checks'])
                    self.assertIn('public-updater-no-surviving-workers', report['checks'])
                    self.assertEqual(report['public_updater']['post_commit_health']['public_manager_version'], '259.10')
                    self.assertEqual(report['source_revision'], build['source_revision'])
                    self.assertEqual(report['source_content_sha256'], build['source_content_sha256'])
                    self.assertEqual(report['candidate_rpm_sha256'], desktop_sha)
                    self.assertEqual(report['candidate_offline_rpm_sha256'], offline_sha)
                    self.assertEqual(report['public_updater']['installed_updater'], helper_identity)
                    self.assertEqual(report['public_updater']['updater_sha256'], 'a' * 64)
                    identity.assert_called_once_with(unittest.mock.ANY, 'fixture', unittest.mock.ANY,
                                                     staged['candidate'], desktop_sha, candidate.stat().st_size)
                    self.assertEqual(set(report['checks']), PUBLIC_UPDATE)
                else:
                    expected = {'health-failure': 'Pending RPM-trigger work',
                                'helper-identity-failure': 'Installed updater differs from candidate'}.get(
                                    outcome, 'Control close failed')
                    with self.assertRaisesRegex(RuntimeError, expected):
                        public.qualify_public_updater(Mock(), candidate, offline, 'fixture', guest, **options)
                    self.assertNotIn('public-updater-committed', report['checks'])
                    self.assertNotIn('public-updater-no-surviving-workers', report['checks'])
                    if outcome == 'first-control-close':
                        self.assertEqual(report['checks'], [])
                        no_workers.assert_not_called()
                    else:
                        # Draining through control earns no public evidence.
                        self.assertTrue(no_workers.called)
                if outcome.endswith('control-close') or outcome == 'helper-identity-failure':
                    health.assert_not_called()
                else:
                    health.assert_called_once()

    def committed_worker_fixture(self, leaked_unit=None):
        """Run the caller and generated verifier with causally effective drains.

        Cleanup and the timeout fixture really clear the synthetic cgroup
        population. Checking only after either of them would hide the leak.
        """
        import upgrade_qualification as upgrade
        with tempfile.TemporaryDirectory() as temporary, ExitStack() as stack:
            root = Path(temporary)
            groups = root / 'cgroups'
            groups.mkdir()
            events = []
            candidate, offline = root / 'desktop.rpm', root / 'offline.rpm'
            candidate.write_bytes(b'desktop')
            offline.write_bytes(b'offline')
            desktop_sha = hashlib.sha256(candidate.read_bytes()).hexdigest()
            offline_sha = hashlib.sha256(offline.read_bytes()).hexdigest()
            report = {'checks': [], 'candidate_rpm_sha256': desktop_sha,
                      'candidate_offline_rpm_sha256': offline_sha}
            build = {'source_revision': '1' * 40, 'source_content_sha256': '2' * 64}
            identifiers = iter(('interrupted-run', 'committed-run'))

            def empty_groups():
                for marker in groups.glob('*/cgroup.events'):
                    marker.write_text('populated 0\n')

            def stop(*_args, **_kwargs):
                events.append('stop-drain')
                empty_groups()

            class LocalControl(public.PublicControl):
                def __enter__(self):
                    self.deadline = time.monotonic() + 1500
                    return self

                @property
                def available(self):
                    return not self.broken

                def __call__(self, _vm, script, _password, **_options):
                    if 'groups = ' in script:
                        events.append('passive-worker-check')
                        python = script.split("python3 - <<'PY'\n", 1)[1].rsplit('\nPY\n', 1)[0]
                        python = python.replace('/sys/fs/cgroup/system.slice', str(groups))
                        with patch('time.sleep'):
                            exec(compile(python, '<generated-worker-verifier>', 'exec'), {})
                    elif script == public.PROVISION_TIMEOUT:
                        events.append('timeout-provision-drain')
                        marker = groups / 'cybexos-provision-work.service/cgroup.events'
                        if marker.exists():
                            marker.write_text('populated 0\n')
                    elif script.startswith('rm -rf'):
                        events.append('staging-delete')
                    return types.SimpleNamespace(stdout=json.dumps(build))

                def start(self):
                    self.launch_attempted = True
                    self.identifier = next(identifiers)
                    return self.identifier

                def poweroff(self):
                    self.keep_fixture = True

                def close(self, **_options):
                    self.broken = True
                    events.append('control-closed')

            @contextmanager
            def dependencies(vm, _bundle, password, _root_script, *, cleanup, **_options):
                try:
                    yield {'candidate': '/sealed/desktop.rpm', 'offline_candidate': '/sealed/offline.rpm'}
                finally:
                    cleanup(vm, 'rm -rf -- /sealed\n', password)

            def wait(_vm, _password, _control, identifier, **_options):
                if identifier == 'committed-run':
                    events.append('committed-wait-returned')
                    if leaked_unit:
                        marker = groups / leaked_unit / 'cgroup.events'
                        marker.parent.mkdir()
                        marker.write_text('populated 1\n')
                return {}, {}

            stack.enter_context(patch.object(public, 'PublicControl', LocalControl))
            stack.enter_context(patch.object(upgrade, 'copy_candidate', side_effect=[desktop_sha, offline_sha, None, None]))
            stack.enter_context(patch.object(upgrade, 'copy_dependencies', side_effect=dependencies))
            stack.enter_context(patch.object(upgrade, 'inspect_version', return_value={'installed': 'candidate', 'candidate': 'candidate'}))
            for name in ('provision_fixture', 'boot_recovered'):
                stack.enter_context(patch.object(public, name))
            stack.enter_context(patch.object(public, 'stop_interrupted', side_effect=stop))
            stack.enter_context(patch.object(public, 'cleanup_fixture', side_effect=lambda *_a: events.append('fixture-delete')))
            stack.enter_context(patch.object(public, 'transfer_source', return_value='a' * 64))
            stack.enter_context(patch.object(public, 'wait_public', side_effect=wait))
            stack.enter_context(patch.object(public, 'verify_recovered', return_value={'rootUuid': 'same-root'}))
            health = stack.enter_context(patch.object(public, 'verify_public_health', return_value={}))
            options = dict(candidate_dependencies=None, boot_installed=Mock(), poweroff_installed=Mock(),
                           verify_user_choices=Mock(), preference={}, report=report)

            def qualify():
                public.qualify_public_updater(Mock(), candidate, offline, 'fixture',
                    Mock(return_value=types.SimpleNamespace(stdout=json.dumps(build))), **options)

            if leaked_unit:
                with self.assertRaisesRegex(RuntimeError, 'A transaction worker survived'):
                    qualify()
                health.assert_not_called()
                self.assertNotIn('public-updater-committed', report['checks'])
                self.assertNotIn('public-updater-no-surviving-workers', report['checks'])
                self.assertNotIn('provisioning-cgroup-timeout-drains-detached-workers', report['checks'])
                # Teardown still drains the leak, without erasing the failure
                # that the passive check observed before teardown began.
                self.assertEqual((groups / leaked_unit / 'cgroup.events').read_text(), 'populated 0\n')
                tail = events[events.index('committed-wait-returned') + 1:]
                self.assertEqual(tail, ['passive-worker-check', 'stop-drain', 'staging-delete',
                                        'fixture-delete', 'control-closed'])
            else:
                qualify()
                health.assert_called_once()
                self.assertIn('public-updater-committed', report['checks'])
                self.assertIn('public-updater-no-surviving-workers', report['checks'])
                tail = events[events.index('committed-wait-returned') + 1:]
                self.assertEqual(tail, ['passive-worker-check', 'timeout-provision-drain', 'stop-drain',
                                       'passive-worker-check', 'staging-delete', 'fixture-delete', 'control-closed'])

    def test_committed_updater_leak_fails_before_cleanup_can_mask_it(self):
        self.committed_worker_fixture('cybexos-update-committed-run.service')

    def test_committed_provisioning_leak_fails_before_timeout_fixture_can_mask_it(self):
        self.committed_worker_fixture('cybexos-provision-work.service')

    def test_passive_success_still_runs_timeout_fixture_and_final_worker_check(self):
        self.committed_worker_fixture()

    def test_public_launch_retains_normal_sudo_authentication_for_the_worker_launcher(self):
        # Model sudo's documented -k/-v ticket behavior, then execute the real
        # SSH payload in a shell. A combined validation authenticates but does
        # not leave the ticket the updater's normal sudo probe requires.
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            sudo = root / 'sudo'
            sudo.write_text('''#!/usr/bin/python3
import json, os
from pathlib import Path
import sys
args = sys.argv[1:]
ticket = Path(os.environ['QUALIFICATION_SUDO_TICKET'])
with Path(os.environ['QUALIFICATION_SUDO_CALLS']).open('a') as log:
    log.write(json.dumps(args) + '\\n')
if '-k' in args:
    ticket.unlink(missing_ok=True)
if '-v' in args:
    assert '-S' in args and sys.stdin.readline().strip() == 'fixture-password'
    if '-k' not in args:
        ticket.touch()
elif '-n' in args and not ticket.exists():
    print('sudo: a password is required', file=sys.stderr)
    raise SystemExit(1)
''')
            sudo.chmod(0o755)
            updater = root / 'fixture updater'
            updater.write_text('''#!/usr/bin/python3
import json, subprocess, sys
assert sys.argv[1:] == ['start', '--json', '--no-flatpak', '--system-unit']
subprocess.run(['sudo', '-n', 'true'], check=True)
print(json.dumps({'id': '20261021-120000-1234-5678', 'systemUnit': True, 'state': 'queued'}))
''')
            updater.chmod(0o755)
            calls = root / 'sudo-calls.jsonl'
            environment = {'PATH': str(root) + os.pathsep + os.environ['PATH'],
                           'QUALIFICATION_SUDO_TICKET': str(root / 'ticket'),
                           'QUALIFICATION_SUDO_CALLS': str(calls)}
            with patch.dict(os.environ, environment), patch.object(public, 'UPDATER', str(updater)):
                vm = types.SimpleNamespace(ssh=['bash', '-c'])
                self.assertEqual(public.start_public(vm, 'fixture-password'), '20261021-120000-1234-5678')
            self.assertEqual([json.loads(line) for line in calls.read_text().splitlines()],
                             [['-k'], ['-S', '-p', '', '-v'], ['-n', 'true']])

    def test_public_launch_failures_keep_bounded_redacted_stdout_and_stderr(self):
        password = 'fixture-password'
        command = ['ssh', 'disposable-guest']
        failures = (
            subprocess.CalledProcessError(1, command, output='x' * 10000 + password,
                                          stderr='sudo: a password is required; ' + password),
            subprocess.TimeoutExpired(command, 90, output=b'partial ' + password.encode(),
                                      stderr=b'worker deadline ' + password.encode()),
        )
        for failure in failures:
            with self.subTest(failure=type(failure).__name__), patch.object(public, 'run', side_effect=failure):
                with self.assertRaises(RuntimeError) as raised:
                    public.start_public(types.SimpleNamespace(ssh=command), password)
                message = str(raised.exception)
                self.assertLess(len(message), 5100)
                self.assertNotIn(password, message)
                self.assertIn('[redacted]', message)
                self.assertIn('stderr:', message)
                self.assertIn('exited 1' if isinstance(failure, subprocess.CalledProcessError)
                              else 'timed out', message)

    def test_invalid_public_launch_response_preserves_redacted_diagnostics(self):
        result = types.SimpleNamespace(stdout='not JSON: fixture-password', stderr='fixture-password')
        with patch.object(public, 'run', return_value=result):
            with self.assertRaisesRegex(RuntimeError, 'did not return a run record') as raised:
                public.start_public(types.SimpleNamespace(ssh=['ssh']), 'fixture-password')
        self.assertIn('not JSON:', str(raised.exception))
        self.assertNotIn('fixture-password', str(raised.exception))

    def test_recovery_restores_only_runtime_ssh_after_both_pre_login_boots_settle(self):
        # Baseline policy remains disabled/closed through recovery and the
        # subsequent cold boot. Exercise real harness ordering, rather than
        # matching source strings or assuming qualify_login enabled SSH.
        events = []
        state = {'boot': 0, 'ssh': False, 'firewall': False, 'settled': False,
                 'enabled': False, 'permanent': False}
        vm = Mock()
        def start(**_options):
            state.update(boot=state['boot'] + 1, ssh=False, firewall=False)
            events.append(('start', state['boot']))
        def unlock(_password, **options):
            events.append(('unlock', state['boot']))
            self.assertFalse(state['ssh'] or state['firewall'])
            if options.get('timeout') == 900:
                self.assertTrue(state['settled'])
                state['boot'] = 2  # The automatic restart, not another host start().
                events.append(('automatic-restart', 2))
        screens = iter(('Please enter passphrase for disk root', 'Recovery running'))
        def screen():
            value = next(screens)
            if value == 'Recovery running':
                # The second unlock waits through recovery, including the
                # real observer's durable terminal evidence, before boot #2.
                with tempfile.TemporaryDirectory() as temporary:
                    evidence = self.observer(Path(temporary))
                    self.assertEqual(json.loads(evidence.read_text())['state'], 'rolled-back')
                state['settled'] = True
            return value
        def ssh(**options):
            self.assertTrue(state['settled'])
            self.assertGreaterEqual(state['boot'], 2)
            self.assertFalse(options['setup'])
            self.assertEqual(options['timeout'], 12)
            self.assertEqual(options['redactions'], ('fixture-password',))
            events.append(('ssh', state['boot']))
            if not state['ssh'] or not state['firewall']:
                raise RuntimeError('baseline SSH disabled/firewall closed')
        def bootstrap(_password):
            self.assertTrue(state['settled'])
            self.assertGreaterEqual(state['boot'], 2)
            events.append(('bootstrap', state['boot']))
            state.update(ssh=True, firewall=True)
        def focus(*_args):
            self.assertTrue(state['ssh'] and state['firewall'])
            self.assertTrue(state['settled'])
            events.append(('focus', state['boot']))
        vm.start.side_effect, vm.unlock_disk.side_effect = start, unlock
        vm.screen_text.side_effect, vm.wait_ssh.side_effect = screen, ssh
        vm.bootstrap_installed_ssh.side_effect = bootstrap
        with patch.object(qualification, 'focus_installed_desktop', side_effect=focus), \
                patch.object(public.time, 'sleep'):
            public.boot_recovered(vm, 'fixture-password')
            # The normal next cold boot must re-bootstrap the same baseline;
            # the fix must not persistently enable SSH to make it pass.
            qualification.boot_installed(vm, 'fixture-password', True)
        self.assertEqual(events, [('start', 1), ('unlock', 1), ('unlock', 1),
                                  ('automatic-restart', 2), ('ssh', 2), ('bootstrap', 2), ('focus', 2),
                                  ('start', 3), ('unlock', 3), ('ssh', 3), ('bootstrap', 3), ('focus', 3)])
        self.assertFalse(state['enabled'] or state['permanent'])

    def test_recovery_cannot_bootstrap_if_the_automatic_restart_has_not_happened(self):
        for stuck_first_prompt in (False, True):
            with self.subTest(stuck_first_prompt=stuck_first_prompt):
                vm = Mock()
                vm.screen_text.return_value = ('Please enter passphrase for disk root'
                                               if stuck_first_prompt else 'Recovery running')
                if not stuck_first_prompt:
                    vm.unlock_disk.side_effect = [None, RuntimeError('No second unlock prompt')]
                with patch.object(qualification, 'focus_installed_desktop') as focus, \
                        patch.object(public.time, 'monotonic', side_effect=[0, 61]):
                    with self.assertRaises(RuntimeError):
                        public.boot_recovered(vm, 'fixture-password')
                vm.wait_ssh.assert_not_called()
                vm.bootstrap_installed_ssh.assert_not_called()
                focus.assert_not_called()

    def test_recovery_uses_existing_ssh_when_available_without_console_input(self):
        vm = Mock()
        vm.screen_text.return_value = 'Recovery running'
        with patch.object(qualification, 'focus_installed_desktop') as focus:
            public.boot_recovered(vm, 'fixture-password')
        vm.bootstrap_installed_ssh.assert_not_called()
        vm.wait_ssh.assert_called_once_with(timeout=12, setup=False, redactions=('fixture-password',))
        focus.assert_called_once_with(vm, 'fixture-password', True)

    def adapter(self, root, *, interrupt=False, damaged=False):
        work = root / public.WORK.lstrip('/')
        work.mkdir(parents=True)
        rpm = root / 'candidate.rpm'
        rpm.write_bytes(b'fixture candidate bytes')
        vendor = root / public.VENDOR.lstrip('/')
        vendor.parent.mkdir(parents=True)
        vendor.write_bytes(b'original vendor bytes')
        (root / 'etc/cybexos').mkdir(parents=True)
        root_marker = root / 'etc/cybexos/qualification-public-root'
        root_marker.write_text('before\n')
        config = {'rpms': [{'path': str(rpm), 'sha256': hashlib.sha256(rpm.read_bytes()).hexdigest()}],
                  'vendor': str(vendor), 'interrupt': interrupt}
        if damaged:
            rpm.write_bytes(b'tampered')
        (work / 'dnf.json').write_text(json.dumps(config))
        script = public.DNF_ADAPTER
        for prefix in ('/run/', '/home/', '/etc/'):
            script = script.replace(prefix, str(root) + prefix)
        # The host fixture runs unprivileged. Guest execution still requires
        # root-owned sealed inodes; no production ownership check is changed.
        script = script.replace('path.stat().st_uid == 0', 'path.stat().st_uid == os.geteuid()')
        return script, work, root_marker, vendor

    def test_dnf_failure_or_changed_artifact_never_claims_the_applied_boundary(self):
        for damaged in (False, True):
            with self.subTest(damaged=damaged), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                script, work, marker, vendor = self.adapter(root, interrupt=True, damaged=damaged)
                failure = subprocess.CalledProcessError(2, ['dnf'])
                with patch('sys.argv', ['dnf', '-y', 'upgrade', '--refresh', '--no-best']), \
                        patch('subprocess.run', side_effect=failure) as apply, \
                        patch('subprocess.Popen') as child:
                    with self.assertRaises(AssertionError if damaged else subprocess.CalledProcessError):
                        exec(compile(script, '<guest-dnf-adapter>', 'exec'), {})
                self.assertEqual(apply.call_count, 0 if damaged else 1)
                child.assert_not_called()
                self.assertFalse((work / 'applied.json').exists())
                self.assertEqual(marker.read_text(), 'before\n')
                self.assertEqual(vendor.read_bytes(), b'original vendor bytes')

    def test_download_does_not_mutate_but_applied_transaction_creates_post_checkpoint_sentinels(self):
        for download in (True, False):
            with self.subTest(download=download), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                script, work, marker, vendor = self.adapter(root, interrupt=True)
                args = ['dnf', '-y', 'upgrade', '--refresh', '--no-best'] + (['--downloadonly'] if download else [])
                with patch('sys.argv', args), patch('subprocess.run') as apply, \
                        patch('subprocess.Popen', return_value=types.SimpleNamespace(pid=2000000000)) as child, \
                        patch('time.sleep', side_effect=InterruptedFixture):
                    if download:
                        exec(compile(script, '<guest-dnf-adapter>', 'exec'), {})
                    else:
                        with self.assertRaises(InterruptedFixture):
                            exec(compile(script, '<guest-dnf-adapter>', 'exec'), {})
                command = apply.call_args.args[0]
                self.assertEqual(command[:4], ['/usr/bin/dnf', '-y', '--disablerepo=*', 'install'])
                self.assertNotIn('--nogpgcheck', command)
                if download:
                    self.assertIn('--downloadonly', command)
                    self.assertEqual(marker.read_text(), 'before\n')
                    child.assert_not_called()
                    self.assertFalse((work / 'applied.json').exists())
                else:
                    self.assertEqual(marker.read_text(), 'applied\n')
                    self.assertEqual(vendor.read_bytes(), b'qualification candidate vendor bytes\n')
                    personal = root / 'home/qualification/qualification-public-personal'
                    self.assertEqual(personal.read_text(), 'after-checkpoint\n')
                    self.assertEqual(json.loads((work / 'applied.json').read_text())['detachedPid'], 2000000000)
                    self.assertTrue(child.call_args.kwargs['start_new_session'])

    def observer(self, root, *, login_active=False, settled=False):
        for prefix in ('home/qualification', 'run', 'proc/sys/kernel/random', 'usr/libexec'):
            (root / prefix).mkdir(parents=True)
        home = root / 'home/qualification'
        (home / 'qualification-public-run-id').write_text('fixture-run')
        (root / 'proc/sys/kernel/random/boot_id').write_text('recovery-boot')
        (root / 'usr/libexec/cybexos-update-transaction').touch()
        (root / 'run/nologin').touch()
        evidence = home / 'qualification-public-recovery.json'
        if settled:
            evidence.write_text(json.dumps({'state': 'rolled-back', 'bootId': 'first-recovery-boot'}))
        script = public.OBSERVER_SCRIPT
        for prefix in ('/home/', '/run/', '/usr/', '/proc/'):
            script = script.replace(prefix, str(root) + prefix)
        states = iter(('applying', 'rolling-back', 'rolled-back'))
        def status(*args, **kwargs):
            return types.SimpleNamespace(returncode=0, stdout=json.dumps({'state': next(states)}))
        with patch('subprocess.run', side_effect=status), patch('signal.signal'), \
                patch('subprocess.check_output', return_value='active\n' if login_active else 'inactive\n'), \
                patch('time.sleep'):
            if settled:
                with self.assertRaises(SystemExit) as exit_code:
                    exec(compile(script, '<pre-login-observer>', 'exec'), {})
                self.assertEqual(exit_code.exception.code, 0)
            else:
                exec(compile(script, '<pre-login-observer>', 'exec'), {})
        return evidence

    def test_pre_login_observer_proves_recovery_and_never_overwrites_first_boot_evidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            evidence = self.observer(root)
            data = json.loads(evidence.read_text())
            self.assertEqual(data['states'], ['applying', 'rolling-back', 'rolled-back'])
            self.assertTrue(data['preLogin'])
            self.assertEqual(data['bootId'], 'recovery-boot')
        with tempfile.TemporaryDirectory() as temporary:
            evidence = self.observer(Path(temporary), settled=True)
            self.assertEqual(json.loads(evidence.read_text())['bootId'], 'first-recovery-boot')

    def test_login_before_recovery_prevents_a_successful_observer_record(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with self.assertRaisesRegex(AssertionError, 'Login started before recovery'):
                self.observer(root, login_active=True)
            self.assertFalse((root / public.EVIDENCE.lstrip('/')).exists())
            self.assertFalse((root / 'run/cybexos-qualification-observer-ready').exists())

    def test_public_success_requires_a_committed_journal_and_interruption_requires_applying(self):
        for interrupted, state, expected in ((False, 'applying', 'without committing'),
                                             (True, 'prepared', 'outside the durable applying')):
            with self.subTest(interrupted=interrupted):
                status = {'state': 'running' if interrupted else 'done', 'exitCode': 0}
                response = types.SimpleNamespace(stdout='{"pid": 2000000000}\n')
                with patch.object(public, 'guest_record', return_value=status), \
                        patch.object(public, 'transaction', return_value={'state': state}):
                    with self.assertRaisesRegex(RuntimeError, expected):
                        public.wait_public(None, 'fixture', lambda *a, **kw: response,
                                           'fixture-run', interrupted=interrupted)

    def test_live_or_detached_worker_blocks_interruption_completion(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            unit = 'cybexos-update-fixture-run.service'
            group = root / 'sys/fs/cgroup/system.slice' / unit
            group.mkdir(parents=True)
            (group / 'cgroup.events').write_text('populated 1\n')
            def guest(_vm, script, _password):
                python = script.split("python3 - <<'PY'\n", 1)[1].split('\nPY\n', 1)[0]
                python = python.replace('/sys/', str(root) + '/sys/').replace('/run/', str(root) + '/run/')
                with patch('time.sleep'):
                    exec(compile(python, '<interrupted-worker-audit>', 'exec'), {})
            with self.assertRaisesRegex(RuntimeError, 'workers survived'):
                public.stop_interrupted(None, 'fixture', guest, 'fixture-run', {})


class InstalledUpdaterIdentity(unittest.TestCase):
    def identity(self, damage=None):
        import stat
        installed_path = '/usr/share/cybexos/bin/cybexos-update-run'
        raw = b'#!/bin/bash\nsnapshot_helper_root=/usr/local/libexec\n'
        packaged = b'#!/bin/bash\nsnapshot_helper_root=/usr/libexec\n'
        expected = hashlib.sha256(packaged).hexdigest()
        nevra = 'cybexos-desktop-1:1.0-1.fc44.x86_64'
        with tempfile.TemporaryDirectory(prefix='cybexos-updater-identity-test-') as temporary:
            root = Path(temporary)
            candidate, installed = root / 'candidate.rpm', root / 'updater'
            candidate.write_bytes(b'bound candidate RPM bytes')
            candidate_sha = hashlib.sha256(candidate.read_bytes()).hexdigest()
            candidate_size = candidate.stat().st_size
            installed.write_bytes(packaged)
            row = [installed_path, expected, str(stat.S_IFREG | 0o755), 'root', 'root']
            algorithm = '8'
            rows = [row]
            installed_nevra = nevra
            if damage == 'helper':
                installed.write_bytes(packaged + b'tampered\n')
            elif damage == 'candidate':
                candidate.write_bytes(b'T' + candidate.read_bytes()[1:])
            elif damage == 'different-candidate':
                candidate.write_bytes(b'X' * candidate_size)
            elif damage == 'size':
                candidate_size += 1
            elif damage == 'nevra':
                installed_nevra = 'cybexos-desktop-1:2.0-1.fc44.x86_64'
            elif damage == 'non-sha256':
                algorithm = '1'
            elif damage == 'missing-algorithm':
                algorithm = '(none)'
            elif damage == 'duplicate':
                rows = [row, row[:]]
            elif damage == 'missing':
                row[0] += '.old'
            elif damage == 'malformed':
                row.pop()
            elif damage == 'digest':
                row[1] = 'g' * 64
            elif damage == 'header-symlink':
                row[2] = str(stat.S_IFLNK | 0o777)
            elif damage == 'header-owner':
                row[3] = 'qualification'
            elif damage == 'header-writable':
                row[2] = str(stat.S_IFREG | 0o777)
            elif damage == 'installed-symlink':
                installed.unlink()
                installed.symlink_to(candidate)
            elif damage == 'candidate-symlink':
                candidate.unlink()
                candidate.symlink_to(installed)
            elif damage == 'installed-directory':
                installed.unlink()
                installed.mkdir()
            candidate.chmod(0o400)
            if not installed.is_symlink():
                installed.chmod(0o755)
            if damage == 'installed-writable':
                installed.chmod(0o777)
            elif damage == 'candidate-writable':
                candidate.chmod(0o666)
            header = nevra + '\n' + algorithm + '\n' + ''.join('\t'.join(value) + '\n' for value in rows)
            real_fstat = os.fstat

            def metadata(fd):
                info = real_fstat(fd)
                values = {name: getattr(info, name) for name in
                          ('st_mode', 'st_size', 'st_mtime_ns', 'st_ctime_ns')}
                values.update(st_uid=0, st_gid=0)
                if damage == 'installed-owner' and os.readlink(f'/proc/self/fd/{fd}') == str(installed):
                    values['st_uid'] = 1000
                elif damage == 'candidate-owner' and os.readlink(f'/proc/self/fd/{fd}') == str(candidate):
                    values['st_uid'] = 1000
                return types.SimpleNamespace(**values)

            def query(args, **options):
                self.assertTrue(options['check'])
                self.assertTrue(options['capture_output'])
                self.assertGreater(options['timeout'], 0)
                self.assertLessEqual(options['timeout'], 10)
                self.assertEqual(args[0], '/usr/bin/rpm')
                if args[1] == '-qp':
                    self.assertEqual(args[2], '--qf')
                    self.assertEqual(args[3], '%{NEVRA}\n%{FILEDIGESTALGO}\n'
                        '[%{FILENAMES}\t%{FILEDIGESTS}\t%{FILEMODES}\t%{FILEUSERNAME}\t%{FILEGROUPNAME}\n]')
                    self.assertEqual(args[4], '--')
                    descriptor, = options['pass_fds']
                    self.assertEqual(args[5], f'/proc/self/fd/{descriptor}')
                    self.assertEqual(os.readlink(args[5]), str(candidate))
                    return types.SimpleNamespace(stdout=header)
                self.assertEqual(args[1:], ['-q', '--qf', '%{NEVRA}\n', 'cybexos-desktop'])
                return types.SimpleNamespace(stdout=installed_nevra + '\n')

            def guest(_vm, script, _password, timeout):
                self.assertEqual(timeout, 30)
                python = script.split("python3 - <<'PY'\n", 1)[1].rsplit('\nPY\n', 1)[0]
                # Map only the installed open; preserve the exact manifest
                # pathname used by the production parser and evidence.
                python = python.replace('with opened(installed) as stream:',
                                        f'with opened({str(installed)!r}) as stream:')
                output = io.StringIO()
                with redirect_stdout(output), patch('os.fstat', side_effect=metadata), \
                        patch('subprocess.run', side_effect=query):
                    exec(compile(python, '<generated-updater-identity>', 'exec'), {})
                return types.SimpleNamespace(stdout=output.getvalue())

            evidence = public.verify_installed_updater(None, 'fixture', guest, str(candidate),
                                                       candidate_sha, candidate_size)
            self.assertNotEqual(hashlib.sha256(raw).hexdigest(), expected)
            self.assertEqual(evidence, {'path': installed_path, 'expected_sha256': expected,
                'actual_sha256': expected, 'candidate_rpm_sha256': candidate_sha, 'candidate_nevra': nevra})

    def test_packaged_path_rendering_can_differ_from_the_transferred_raw_source(self):
        self.identity()

    def test_tampered_helper_or_unbound_candidate_cannot_pass_identity(self):
        for damage in ('helper', 'candidate', 'different-candidate', 'size', 'nevra'):
            with self.subTest(damage=damage), self.assertRaises(RuntimeError):
                self.identity(damage)

    def test_malformed_missing_duplicate_or_non_sha256_header_entries_are_rejected(self):
        for damage in ('non-sha256', 'missing-algorithm', 'duplicate', 'missing', 'malformed',
                       'digest', 'header-symlink', 'header-owner', 'header-writable'):
            with self.subTest(damage=damage), self.assertRaises(RuntimeError):
                self.identity(damage)

    def test_installed_and_candidate_files_must_be_regular_protected_and_root_owned(self):
        for damage in ('installed-symlink', 'candidate-symlink', 'installed-directory', 'installed-owner',
                       'candidate-owner', 'installed-writable', 'candidate-writable'):
            with self.subTest(damage=damage), self.assertRaises((RuntimeError, OSError)):
                self.identity(damage)


class ControlProtocol(unittest.TestCase):
    @contextmanager
    def local_ssh(self, *, server=None, password='fixture-password'):
        """Execute the production server across real pipes/process boundaries.

        Only sudo/SSH and the advertised UID are substituted. No root access,
        guest, systemd service, or host resource is created by these tests.
        """
        with tempfile.TemporaryDirectory(prefix='cybexos-control-test-') as temporary, ExitStack() as stack:
            root = Path(temporary)
            events = root / 'events'
            stall = root / 'stall-new-sessions'
            boot = root / 'boot'
            boot.write_text('12345678-1234-1234-1234-123456789abc\n')
            ssh = root / 'ssh'
            ssh.write_text('''#!/usr/bin/python3
import json, os, pathlib, sys, time
root = pathlib.Path(__file__).parent
with (root / 'events').open('a') as out:
    out.write(json.dumps({'event': 'ssh', 'pid': os.getpid()}) + '\\n')
assert 'fixture-password' not in sys.argv[-1]
if (root / 'stall-new-sessions').exists(): time.sleep(2)
os.execvp('bash', ['bash', '-c', sys.argv[-1]])
''')
            sudo = root / 'sudo'
            sudo.write_text('''#!/usr/bin/python3
import json, os, pathlib, sys
root = pathlib.Path(__file__).parent
args = sys.argv[1:]
if args == ['-k']: raise SystemExit(0)
assert args[:4] == ['-k', '-S', '-p', ''] or args == ['-S', '-p', '', '-v']
assert sys.stdin.buffer.readline() == b'fixture-password\\n', 'Password authentication failed'
with (root / 'events').open('a') as out:
    out.write(json.dumps({'event': 'authenticated', 'pid': os.getpid()}) + '\\n')
if args[-1] == '-v': raise SystemExit(0)
assert args[4:7] == ['python3', '-u', '-c']
os.execvp(args[4], args[4:])
''')
            updater = root / 'updater'
            updater.write_text('''#!/usr/bin/python3
import json, pathlib
root = pathlib.Path(__file__).parent
with (root / 'events').open('a') as out:
    out.write(json.dumps({'event': 'launched'}) + '\\n')
print(json.dumps({'id': '20261021-120000-1234-5678', 'systemUnit': True, 'state': 'queued'}))
''')
            for path in (ssh, sudo, updater):
                path.chmod(0o755)
            source = (server or public.CONTROL_SERVER).replace('uid=os.geteuid()', 'uid=0')
            source = source.replace("'/proc/sys/kernel/random/boot_id'", repr(str(boot)))
            stack.enter_context(patch.object(public, 'CONTROL_SERVER', source))
            stack.enter_context(patch.object(public, 'UPDATER', str(updater)))
            stack.enter_context(patch.dict(os.environ, {'PATH': str(root) + os.pathsep + os.environ['PATH']}))
            clean = stack.enter_context(patch.object(public, 'cleanup_fixture'))
            stop = stack.enter_context(patch.object(public, 'stop_interrupted'))
            vm = types.SimpleNamespace(ssh=[str(ssh)])
            control = public.PublicControl(vm, password)
            yield types.SimpleNamespace(root=root, vm=vm, control=control, events=events,
                                        stall=stall, boot=boot, clean=clean, stop=stop)
            # Every test, including failed admission and malformed transport,
            # must have reaped its private SSH/server process and closed pipes.
            if control.process is not None:
                self.assertIsNotNone(control.process.poll())
                for stream in (control.process.stdin, control.process.stdout, control.process.stderr):
                    self.assertTrue(stream.closed)

    def read_events(self, fixture):
        return [json.loads(line) for line in fixture.events.read_text().splitlines()]

    def test_authentication_and_ready_precede_normal_launch_then_no_new_polling_sessions(self):
        with self.local_ssh() as fixture:
            control = fixture.control
            with control:
                self.assertEqual(control.boot, fixture.boot.read_text().strip())
                self.assertEqual([event['event'] for event in self.read_events(fixture)], ['ssh', 'authenticated'])
                self.assertEqual(control.start(), '20261021-120000-1234-5678')
                before = self.read_events(fixture)
                self.assertEqual([event['event'] for event in before],
                                 ['ssh', 'authenticated', 'ssh', 'authenticated', 'launched'])
                fixture.stall.touch()
                # New logins now hang (the observed PAM failure); the already
                # authenticated remote process still runs all control requests.
                with self.assertRaises(subprocess.TimeoutExpired):
                    subprocess.run([*fixture.vm.ssh, 'true'], capture_output=True, timeout=.05)
                stalled_sessions = len(self.read_events(fixture))
                for _ in range(4):
                    self.assertEqual(control(fixture.vm, "printf 'controlled\\n'\n", 'fixture-password').stdout,
                                     'controlled\n')
                self.assertEqual(len(self.read_events(fixture)), stalled_sessions)
            self.assertEqual(fixture.stop.call_count, 1)
            fixture.clean.assert_called_once()

    def test_failed_authentication_never_reaches_ready_or_launch(self):
        with self.local_ssh(password='incorrect-password') as fixture, patch.object(public, 'start_public') as launch:
            with self.assertRaisesRegex(RuntimeError, 'Public control failed|handshake|SSH closed'):
                with fixture.control:
                    fixture.control.start()
            launch.assert_not_called()
            fixture.clean.assert_not_called()

    def test_real_polling_status_and_transaction_reads_share_the_control_process(self):
        with self.local_ssh() as fixture:
            logs = fixture.root / 'logs'
            (logs / 'fixture-run').mkdir(parents=True)
            status = logs / 'fixture-run/status.json'
            status.write_text(json.dumps({'state': 'done', 'exitCode': 0}))
            helper = fixture.root / 'transaction'
            helper.write_text('#!/usr/bin/python3\nprint(\'{"state":"committed"}\')\n')
            helper.chmod(0o755)
            source = public.CONTROL_SERVER.replace('request[\'script\'].encode()',
                "request['script'].replace('/home/qualification/.local/state/cybexos/update/logs', " +
                repr(str(logs)) + ").replace('/usr/libexec/cybexos-update-transaction', " +
                repr(str(helper)) + ').encode()')
            with patch.object(public, 'CONTROL_SERVER', source), fixture.control as control:
                _status, record = public.wait_public(fixture.vm, 'fixture-password', control, 'fixture-run')
                self.assertEqual(record['state'], 'committed')
                self.assertEqual([event['event'] for event in self.read_events(fixture)], ['ssh', 'authenticated'])

    def test_invalid_response_eof_or_boot_change_fails_without_reconnect_or_cleanup(self):
        for damage in ('invalid', 'eof', 'boot'):
            server = public.CONTROL_SERVER
            if damage == 'invalid':
                server = server.replace("emit('result', id=sequence, returncode=code)",
                                        "emit('result', id=sequence, returncode='invalid')")
            elif damage == 'eof':
                server = server.replace("emit('result', id=sequence, returncode=code)", 'raise SystemExit(3)')
            with self.subTest(damage=damage), self.local_ssh(server=server) as fixture:
                with self.assertRaisesRegex(RuntimeError, 'Public control failed'):
                    with fixture.control as control:
                        control.launch_attempted = True
                        control.identifier = 'fixture-run'
                        if damage == 'boot':
                            fixture.boot.write_text('abcdefab-1234-1234-1234-123456789abc\n')
                        control(fixture.vm, 'true\n', 'fixture-password')
                self.assertEqual(len([event for event in self.read_events(fixture) if event['event'] == 'ssh']), 1)
                fixture.stop.assert_not_called()
                fixture.clean.assert_not_called()

    def test_one_absolute_cycle_deadline_cannot_reset_at_launch_or_wait(self):
        with self.local_ssh() as fixture, patch.object(public, 'start_public') as launch:
            with self.assertRaisesRegex(RuntimeError, 'cycle exceeded'):
                with fixture.control as control:
                    original = control.deadline
                    self.assertLessEqual(original - time.monotonic(), 1500)
                    control.deadline = time.monotonic() - 1
                    control.start()
            launch.assert_not_called()
            fixture.clean.assert_not_called()
        with self.local_ssh() as fixture:
            with self.assertRaisesRegex(RuntimeError, 'qualification deadline'):
                with fixture.control as control:
                    control.deadline = time.monotonic() - 1
                    public.wait_public(fixture.vm, 'fixture-password', control, 'fixture-run')

    def test_request_timeout_reaps_command_and_detached_descendant(self):
        with self.local_ssh() as fixture:
            pidfile = fixture.root / 'detached-pid'
            script = ("python3 - <<'PY'\nimport pathlib, subprocess, sys, time\n"
                      "child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)'], start_new_session=True)\n"
                      f"pathlib.Path({str(pidfile)!r}).write_text(str(child.pid))\n"
                      'time.sleep(30)\nPY\n')
            with self.assertRaisesRegex(RuntimeError, 'Public control failed'):
                with fixture.control as control:
                    control(fixture.vm, script, 'fixture-password', timeout=.3)
            self.assertTrue(pidfile.is_file(), 'Detached command never started')
            self.assertFalse(Path('/proc', pidfile.read_text()).exists())

    def test_shutdown_requires_streamed_preparation_marker_and_clean_qemu_exit(self):
        for marker, qemu_code in ((True, 0), (False, 0), (True, 1)):
            server = public.CONTROL_SERVER.replace("request['script'].encode()",
                "request['script'].replace('sync\\n', 'true\\n').replace('systemctl poweroff --no-block\\n', 'true\\n').encode()")
            if not marker:
                server = server.replace("request['script'].replace('sync\\n', 'true\\n')",
                    "request['script'].replace(\"printf '%s\\\\n'\", 'true').replace('sync\\n', 'true\\n')")
            server = server.replace("emit('result', id=sequence, returncode=code)",
                "if 'systemctl poweroff --no-block\\n' in request['script']: raise SystemExit(0)\n        emit('result', id=sequence, returncode=code)")
            with self.subTest(marker=marker, qemu_code=qemu_code), self.local_ssh(server=server) as fixture:
                fixture.vm.process = Mock()
                fixture.vm.process.wait.return_value = qemu_code
                fixture.vm.console = None
                fixture.vm.release_runtime = Mock()
                fixture.vm.ssh_ready = True
                if marker and qemu_code == 0:
                    with fixture.control as control:
                        control.drained = True
                        remaining = control.remaining
                        def consume_preparation_budget(bound):
                            result = remaining(bound)
                            if bound == 90:
                                # Model budget consumed by preparation after
                                # poweroff_guest received its initial bound.
                                control.deadline = time.monotonic() + 10
                            return result
                        with patch.object(control, 'remaining', side_effect=consume_preparation_budget):
                            control.poweroff()
                        self.assertLess(fixture.vm.process.wait.call_args.kwargs['timeout'], 10)
                    fixture.vm.release_runtime.assert_called_once()
                    self.assertFalse(fixture.vm.ssh_ready)
                    fixture.clean.assert_not_called()  # Observer survives recovery reboot.
                else:
                    with self.assertRaises((subprocess.CalledProcessError, RuntimeError)):
                        with fixture.control as control:
                            control.drained = True
                            control.poweroff()
                    fixture.vm.release_runtime.assert_not_called()

    def test_nonzero_command_keeps_control_for_abort_and_redacts_password(self):
        with self.local_ssh() as fixture:
            with fixture.control as control:
                with self.assertRaises(subprocess.CalledProcessError) as caught:
                    control(fixture.vm, "printf 'fixture-password\\n'; exit 7\n", 'fixture-password')
                self.assertEqual(caught.exception.returncode, 7)
                self.assertNotIn('fixture-password', caught.exception.stdout)
                self.assertTrue(control.available)
                self.assertEqual(control(fixture.vm, 'echo abort-control\n', 'fixture-password').stdout, 'abort-control\n')

    def test_failure_stops_and_verifies_before_staging_and_fixture_deletion(self):
        with self.local_ssh() as fixture:
            events = []
            fixture.stop.side_effect = lambda *_a, **_k: events.append('stop-and-verify')
            fixture.clean.side_effect = lambda *_a, **_k: events.append('fixture-delete')
            staged = fixture.root / 'staged'
            staged.touch()
            with self.assertRaisesRegex(RuntimeError, 'first failure'):
                with fixture.control as control:
                    control.launch_attempted = True
                    control.identifier = 'fixture-run'
                    try:
                        raise RuntimeError('first failure')
                    finally:
                        control.cleanup_staging(fixture.vm, f'rm -- {staged}\n', 'fixture-password')
                        events.append('staging-delete')
            self.assertEqual(events, ['stop-and-verify', 'staging-delete', 'fixture-delete'])
            self.assertFalse(staged.exists())

    def test_failed_drain_preserves_first_exception_and_never_deletes_fixture(self):
        with self.local_ssh() as fixture:
            fixture.stop.side_effect = RuntimeError('drain failure')
            with self.assertRaisesRegex(RuntimeError, 'first failure'):
                with fixture.control as control:
                    control.launch_attempted = True
                    control.identifier = 'fixture-run'
                    raise RuntimeError('first failure')
            fixture.stop.assert_called_once()
            fixture.clean.assert_not_called()

    def test_unknown_launch_outcome_leaves_guest_files_to_owned_teardown(self):
        with self.local_ssh() as fixture, patch.object(public, 'start_public', side_effect=RuntimeError('launch failed')):
            staged = fixture.root / 'staged'
            staged.touch()
            with self.assertRaisesRegex(RuntimeError, 'launch failed'):
                with fixture.control as control:
                    try:
                        control.start()
                    finally:
                        control.cleanup_staging(fixture.vm, f'rm -- {staged}\n', 'fixture-password')
            self.assertTrue(staged.exists())
            fixture.clean.assert_not_called()
            fixture.stop.assert_not_called()


if __name__ == '__main__':
    unittest.main()
