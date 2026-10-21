"""The release orchestrator fails closed before publishing or starting VM tests."""
from contextlib import contextmanager
import hashlib
import importlib.machinery
import importlib.util
import io
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import MagicMock, patch

import browser_qualification
from build_support import digest
import offline_upgrade_inputs as inputs

loader = importlib.machinery.SourceFileLoader('release_gate', str(Path(__file__).with_name('release-gate')))
spec = importlib.util.spec_from_loader(loader.name, loader)
gate = importlib.util.module_from_spec(spec)
loader.exec_module(gate)


class ReleaseGate(unittest.TestCase):
    def fixture(self, root, same_iso=False):
        checkout = root / 'source'
        checkout.mkdir()
        (checkout / 'VERSION').write_text('1.2.3\n')
        pxe = root / 'pxe'
        (pxe / 'iso').mkdir(parents=True)
        (pxe / 'README.md').write_text('fixture PXE host')
        baseline = pxe / 'iso/baseline.iso'
        baseline.write_bytes(b'candidate' if same_iso else b'prior ISO')
        output = root / 'output'
        commands = []
        def paths(value):
            value = str(value)
            return pxe / value[len('/data/pxe/'):] if value.startswith('/data/pxe/') else Path(value)
        def run(command):
            commands.append(command)
            if command[0].endswith('/image/build'):
                artifacts = output / 'build/artifacts'
                artifacts.mkdir(parents=True)
                (artifacts / 'candidate.iso').write_bytes(b'candidate')
                (artifacts / 'cybexos-desktop-1.2.3.rpm').write_bytes(b'RPM')
                (artifacts / 'cybexos-offline-apps-1.0.0.rpm').write_bytes(b'offline RPM')
                (artifacts / 'candidate.spdx.json').write_text('{}')
            if command[0].endswith('/image/publish-pxe'):
                (pxe / 'iso/candidate.iso').write_bytes(b'candidate')
            if command[0].endswith('/image/qualify') and '--capture-outcomes' in command:
                destination = Path(command[command.index('--output') + 1])
                destination.mkdir()
                scenario = command[command.index('--scenario') + 1]
                (destination / 'qualification.json').write_text(json.dumps({
                    'status': 'passed', 'scenario': scenario, 'source_revision': 'a' * 40,
                    'source_content_sha256': 'b' * 64, 'checks': ['graphical-installer']}))
            if command[0].endswith('/image/qualify') and '--candidate-dependencies' in command:
                destination = Path(command[command.index('--output') + 1])
                destination.mkdir()
                desktop = Path(command[command.index('--candidate-rpm') + 1])
                offline = Path(command[command.index('--candidate-offline-rpm') + 1])
                bundle = inputs.load_bundle(command[command.index('--candidate-dependencies') + 1],
                                            baseline_iso=Path(command[1]), candidate_rpm=desktop,
                                            candidate_offline_rpm=offline)
                (destination / 'qualification.json').write_text(json.dumps({
                    'status': 'passed', 'iso_sha256': digest(command[1]),
                    'candidate_rpm_sha256': digest(desktop), 'candidate_offline_rpm_sha256': digest(offline),
                    'candidate_dependencies': {**bundle.evidence(), 'guest_signatures_verified': True},
                    'checks': ['installed-rpm-upgrade', 'recovery-boot-restore',
                               'offline-dependency-signatures-and-single-transaction']}))
            if command[0].endswith('/image/qualify-checkout'):
                destination = Path(command[command.index('--output') + 1])
                destination.mkdir()
                scenario = command[command.index('--scenario') + 1]
                (destination / 'checkout-qualification.json').write_text(json.dumps({
                    'status': 'passed', 'scenario': scenario, 'source_revision': 'a' * 40,
                    'source_content_sha256': 'b' * 64, 'checks': ['full-checkout-installation',
                        'installed-parity-fresh', 'installed-parity-saved', 'full-graphical-session']}))
                for profile in ('fresh', 'saved'):
                    (destination / ('parity-' + profile + '.json')).write_text(json.dumps({
                        'status': 'passed', 'scenario': scenario, 'profile': profile, 'source_content_sha256': 'b' * 64}))
        return checkout, baseline, output, paths, run, commands

    @contextmanager
    def execution(self, fixture, extra_args=(), run=None):
        checkout, baseline, output, paths, default_run, _ = fixture
        with patch.object(gate, 'ROOT', checkout), patch.object(gate, 'Path', side_effect=paths), \
             patch.object(gate, 'require_test_iso', side_effect=lambda path: path), \
             patch.object(gate.subprocess, 'run'), patch.object(gate, 'browser_dependencies'), \
             patch.object(gate, 'run_child', side_effect=run or default_run), patch.object(gate.signal, 'signal'), \
             patch('sys.stdout', new_callable=io.StringIO) as stdout, patch('sys.stderr', new_callable=io.StringIO), \
             patch('sys.argv', ['release-gate', '--output', str(output), '--baseline-iso', str(baseline),
                                '--tag', 'v1.2.3', '--execute', *map(str, extra_args)]):
            yield stdout

    def raw_inputs(self, root):
        directory = root / 'raw-rpms'
        directory.mkdir()
        rpm = directory / 'patch-2.8-1.fc44.x86_64.rpm'
        rpm.write_bytes(b'reviewed dependency')
        provenance = root / 'provenance.json'
        provenance.write_text(json.dumps({rpm.name: {'id': 'fedora', 'url': 'https://example.org/fedora/44/'}}))
        identity = {'name': 'patch', 'nevra': 'patch-0:2.8-1.fc44.x86_64', 'architecture': 'x86_64',
                    'signature': {'tag': 'RSAHEADER', 'value': 'RSA/SHA256, Wed Oct 21 2026, Key ID 0123456789abcdef'}}
        flags = ['--upgrade-dependency-rpms', directory, '--upgrade-dependency-provenance', provenance]
        return directory, provenance, rpm, identity, flags

    def invoke(self, root, same_iso=False):
        fixture = self.fixture(root, same_iso)
        with self.execution(fixture):
            if same_iso:
                with self.assertRaisesRegex(RuntimeError, 'different prior ISO'):
                    gate.main()
            else:
                gate.main()
        return fixture[2], fixture[-1]

    def test_same_iso_is_rejected_before_pxe_publication_and_vm_creation(self):
        with tempfile.TemporaryDirectory() as temporary:
            output, commands = self.invoke(Path(temporary), same_iso=True)
            self.assertEqual(len(commands), 1)
            self.assertFalse((output / 'build').exists())
            self.assertEqual(json.loads((output / 'release-gate.json').read_text())['status'], 'failed')

    def test_required_matrix_and_prior_rpm_upgrade_recovery_are_invoked(self):
        with tempfile.TemporaryDirectory() as temporary:
            output, commands = self.invoke(Path(temporary))
            qualifications = [command for command in commands if command[0].endswith('/image/qualify')]
            self.assertEqual(len(qualifications), 5)
            self.assertEqual([command[command.index('--scenario') + 1] for command in qualifications[:4]],
                             ['encrypted-us', 'plain-us', 'encrypted-nl', 'plain-nl'])
            upgrade = qualifications[-1]
            self.assertTrue(upgrade[1].endswith('/baseline.iso'))
            self.assertIn('--candidate-rpm', upgrade)
            self.assertIn('--candidate-offline-rpm', upgrade)
            self.assertIn('--recovery-check', upgrade)
            self.assertIn('--legacy-installer', upgrade)
            self.assertTrue(all('--candidate-dependencies' not in command for command in commands))
            checkout = [command for command in commands if command[0].endswith('/image/qualify-checkout')]
            self.assertEqual(len(checkout), 2)
            self.assertEqual([command[command.index('--scenario') + 1] for command in checkout], ['plain-us', 'plain-nl'])
            for scenario in ('plain-us', 'plain-nl'):
                qualified = json.loads((output / scenario / 'qualification.json').read_text())
                self.assertIn('installed-parity-saved', qualified['checks'])
                self.assertEqual(qualified['checkout_parity']['status'], 'passed')
            report = json.loads((output / 'release-gate.json').read_text())
            self.assertEqual(report['status'], 'passed')
            self.assertNotIn('candidate_dependencies', report)
            self.assertNotIn('upgrade_dependency_fixture', report)
            self.assertFalse((output / 'upgrade-dependencies').exists())
            self.assertFalse((output / 'upgrade-dependency-manifest.json').exists())

    def test_dependency_flags_require_each_other_before_build_or_output_creation(self):
        for flag in ('--upgrade-dependency-rpms', '--upgrade-dependency-provenance'):
            with self.subTest(flag=flag), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                fixture = self.fixture(root)
                with self.execution(fixture, [flag, root / 'missing']), self.assertRaises(SystemExit):
                    gate.main()
                self.assertFalse(fixture[2].exists())
                self.assertEqual(fixture[-1], [])

    def test_bad_dependency_inputs_fail_before_build_and_remove_partial_snapshot(self):
        for problem in ('missing-rpms', 'missing-provenance', 'malformed', 'bad-origin', 'extra', 'symlink'):
            with self.subTest(problem=problem), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                fixture = self.fixture(root)
                directory, provenance, rpm, identity, flags = self.raw_inputs(root)
                if problem == 'missing-rpms':
                    shutil.rmtree(directory)
                elif problem == 'missing-provenance':
                    provenance.unlink()
                elif problem == 'malformed':
                    provenance.write_text('{')
                elif problem == 'bad-origin':
                    provenance.write_text(json.dumps({rpm.name: {'id': 'fedora', 'url': 'http://example.org/'}}))
                elif problem == 'extra':
                    (directory / 'extra.rpm').write_bytes(b'extra')
                else:
                    rpm.unlink()
                    rpm.symlink_to(provenance)
                with self.execution(fixture, flags), patch.object(inputs, 'rpm_identity', return_value=identity), \
                     self.assertRaises((ValueError, OSError)):
                    gate.main()
                self.assertEqual(fixture[-1], [])
                output = fixture[2]
                self.assertFalse((output / 'upgrade-dependencies').exists())
                self.assertEqual(json.loads((output / 'release-gate.json').read_text())['status'], 'failed')

    def test_missing_host_rpm_and_bad_rpm_fail_before_build(self):
        for error in (FileNotFoundError('rpm'), ValueError('Unexpected RPM identity output')):
            with self.subTest(error=error), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                fixture = self.fixture(root)
                _, _, _, _, flags = self.raw_inputs(root)
                with self.execution(fixture, flags), patch.object(inputs, 'rpm_identity', side_effect=error), \
                     self.assertRaises(type(error)):
                    gate.main()
                self.assertEqual(fixture[-1], [])
                self.assertFalse((fixture[2] / 'upgrade-dependencies').exists())

    def test_output_within_raw_inputs_is_rejected_without_mutating_them(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fixture = self.fixture(root)
            directory, _, _, _, flags = self.raw_inputs(root)
            nested = directory / 'output'
            with self.execution(fixture, [*flags, '--output', nested]), self.assertRaises(SystemExit):
                gate.main()
            self.assertFalse(nested.exists())
            self.assertEqual(fixture[-1], [])

    def test_snapshot_binds_fresh_build_bytes_and_only_upgrade_receives_bundle(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fixture = self.fixture(root)
            _, baseline, output, _, run, commands = fixture
            directory, provenance, rpm, identity, flags = self.raw_inputs(root)
            original, provenance_sha = rpm.read_bytes(), digest(provenance)
            source_stat = rpm.stat()
            stage = output / 'upgrade-dependencies'
            def build_and_change_caller(command):
                if command[0].endswith('/image/build'):
                    self.assertEqual(rpm.read_bytes(), original)
                    self.assertEqual(rpm.stat().st_mode, source_stat.st_mode)
                    self.assertEqual(digest(provenance), provenance_sha)
                    self.assertFalse((directory / inputs.MANIFEST).exists())
                    self.assertFalse((stage / inputs.MANIFEST).exists())
                    self.assertFalse((output / 'build').exists())
                    self.assertEqual((stage / rpm.name).read_bytes(), original)
                    self.assertNotEqual((stage / rpm.name).stat().st_ino, source_stat.st_ino)
                    self.assertEqual((stage / rpm.name).stat().st_mode & 0o777, 0o400)
                    rpm.write_bytes(b'changed caller during long build')
                    provenance.write_text('{}')
                run(command)
                if command[0].endswith('/image/build'):
                    (output / 'build/artifacts/cybexos-desktop-1.2.3.rpm').write_bytes(b'fresh build EVR and bytes')
                    (output / 'build/artifacts/cybexos-offline-apps-1.0.0.rpm').write_bytes(b'fresh offline build bytes')
            with self.execution(fixture, flags, build_and_change_caller), \
                 patch.object(inputs, 'rpm_identity', return_value=identity):
                gate.main()
            report = json.loads((output / 'release-gate.json').read_text())
            manifest = json.loads((output / 'upgrade-dependency-manifest.json').read_text())
            self.assertEqual(report['status'], 'passed')
            self.assertEqual(manifest['baseline_iso_sha256'], digest(baseline))
            self.assertEqual(manifest['candidate_rpm_sha256'], digest(output / 'build/artifacts/cybexos-desktop-1.2.3.rpm'))
            self.assertEqual(manifest['candidate_offline_rpm_sha256'], digest(output / 'build/artifacts/cybexos-offline-apps-1.0.0.rpm'))
            self.assertEqual(manifest['rpms'][0]['sha256'], hashlib.sha256(original).hexdigest())
            self.assertEqual(manifest['rpms'][0]['repository']['id'], 'fedora')
            self.assertEqual(report['upgrade_dependency_fixture']['provenance_sha256'], provenance_sha)
            self.assertEqual(report['candidate_dependencies']['rpms'], report['upgrade_dependency_fixture']['rpms'])
            self.assertEqual(report['candidate_dependencies']['manifest_sha256'], digest(output / 'upgrade-dependency-manifest.json'))
            self.assertEqual(report['upgrade_qualification_sha256'], digest(output / 'upgrade/qualification.json'))
            self.assertFalse(stage.exists())
            self.assertEqual(rpm.read_bytes(), b'changed caller during long build')
            self.assertFalse((directory / inputs.MANIFEST).exists())
            qualifications = [command for command in commands if command[0].endswith('/image/qualify')]
            self.assertTrue(all('--candidate-dependencies' not in command for command in qualifications[:-1]))
            self.assertEqual(qualifications[-1], [str(fixture[0] / 'image/qualify'), str(baseline),
                '--output', str(output / 'upgrade'), '--execute-vm', '--erase-disposable-disk', '--scenario', 'encrypted-us',
                '--candidate-rpm', str(output / 'build/artifacts/cybexos-desktop-1.2.3.rpm'),
                '--candidate-offline-rpm', str(output / 'build/artifacts/cybexos-offline-apps-1.0.0.rpm'),
                '--recovery-check', '--legacy-installer', '--candidate-dependencies', str(stage)])

    def test_changed_private_snapshot_fails_binding_before_publication_or_qualify(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fixture = self.fixture(root)
            _, _, rpm, identity, flags = self.raw_inputs(root)
            output, run = fixture[2], fixture[4]
            def tamper(command):
                run(command)
                staged = output / 'upgrade-dependencies' / rpm.name
                staged.chmod(0o600)
                staged.write_bytes(b'changed private snapshot')
            with self.execution(fixture, flags, tamper), patch.object(inputs, 'rpm_identity', return_value=identity), \
                 self.assertRaisesRegex(ValueError, 'changed after admission'):
                gate.main()
            self.assertEqual(len(fixture[-1]), 1)
            self.assertFalse((output / 'upgrade-dependencies').exists())
            self.assertFalse((output / 'build').exists())
            self.assertFalse((output / 'upgrade-dependency-manifest.json').exists())
            self.assertEqual(json.loads((output / 'release-gate.json').read_text())['status'], 'failed')

    def test_child_failures_always_clean_dependency_staging(self):
        for step in ('/image/build', '/image/qualify'):
            with self.subTest(step=step), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                fixture = self.fixture(root)
                _, _, rpm, identity, flags = self.raw_inputs(root)
                run = fixture[4]
                def fail(command):
                    if command[0].endswith(step) and (step.endswith('/build') or '--candidate-dependencies' in command):
                        raise RuntimeError('child failed')
                    run(command)
                with self.execution(fixture, flags, fail), patch.object(inputs, 'rpm_identity', return_value=identity), \
                     self.assertRaisesRegex(RuntimeError, 'child failed'):
                    gate.main()
                self.assertFalse((fixture[2] / 'upgrade-dependencies').exists())
                self.assertFalse((fixture[2] / 'build').exists())
                self.assertEqual(rpm.read_bytes(), b'reviewed dependency')

    def test_qualification_requires_exact_fixture_signatures_bindings_and_recovery(self):
        mutations = [
            lambda report: report.update(status='failed'),
            lambda report: report['candidate_dependencies'].update(guest_signatures_verified=False),
            lambda report: report['candidate_dependencies'].update(manifest_sha256='0' * 64),
            lambda report: report['candidate_dependencies']['rpms'][0]['repository'].update(id='other'),
            lambda report: report.update(candidate_rpm_sha256='0' * 64),
            lambda report: report.update(candidate_offline_rpm_sha256='0' * 64),
            lambda report: report.update(iso_sha256='0' * 64),
            lambda report: report['checks'].remove('recovery-boot-restore'),
            lambda report: report['checks'].remove('offline-dependency-signatures-and-single-transaction'),
        ]
        for index, mutate in enumerate(mutations):
            with self.subTest(index=index), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                fixture = self.fixture(root)
                _, _, _, identity, flags = self.raw_inputs(root)
                output, run = fixture[2], fixture[4]
                def mismatch(command):
                    run(command)
                    if '--candidate-dependencies' in command:
                        evidence = output / 'upgrade/qualification.json'
                        qualified = json.loads(evidence.read_text())
                        mutate(qualified)
                        evidence.write_text(json.dumps(qualified))
                with self.execution(fixture, flags, mismatch), patch.object(inputs, 'rpm_identity', return_value=identity), \
                     self.assertRaisesRegex(RuntimeError, 'exact dependency fixture'):
                    gate.main()
                self.assertFalse((output / 'upgrade-dependencies').exists())
                self.assertEqual(json.loads((output / 'release-gate.json').read_text())['status'], 'failed')

    def test_cleanup_failure_writes_failed_evidence_and_never_prints_passed(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fixture = self.fixture(root)
            _, _, _, identity, flags = self.raw_inputs(root)
            output = fixture[2]
            stage = output / 'upgrade-dependencies'
            remove = shutil.rmtree
            def fail_cleanup(path, *args, **kwargs):
                if path == stage:
                    raise OSError('fixture cleanup failed')
                return remove(path, *args, **kwargs)
            with self.execution(fixture, flags) as stdout, patch.object(inputs, 'rpm_identity', return_value=identity), \
                 patch.object(gate.shutil, 'rmtree', side_effect=fail_cleanup), \
                 self.assertRaisesRegex(OSError, 'fixture cleanup failed'):
                gate.main()
            self.assertEqual(stdout.getvalue(), '')
            report = json.loads((output / 'release-gate.json').read_text())
            self.assertEqual(report['status'], 'failed')
            self.assertIn(str(stage), report['cleanup_error'])
            self.assertTrue((output / 'upgrade-dependency-manifest.json').is_file())
            remove(stage)

    def test_interruption_terminates_owned_process_group_before_returning(self):
        process = MagicMock()
        process.pid = 43210
        process.poll.return_value = None
        process.wait.side_effect = [KeyboardInterrupt(), 0]
        process.__enter__.return_value = process
        with patch.object(gate.subprocess, 'Popen', return_value=process) as spawn, \
             patch.object(gate.os, 'killpg') as stop:
            with self.assertRaises(KeyboardInterrupt):
                gate.run_child(['fixture-child'])
        spawn.assert_called_once_with(['fixture-child'], start_new_session=True)
        stop.assert_called_once_with(process.pid, gate.signal.SIGTERM)
        self.assertEqual(process.wait.call_args_list[-1].kwargs, {'timeout': 30})

    def test_unresponsive_owned_group_is_killed_and_reaped(self):
        process = MagicMock()
        process.pid = 43210
        process.poll.return_value = None
        process.wait.side_effect = [KeyboardInterrupt(), subprocess.TimeoutExpired('fixture', 30), 0]
        process.__enter__.return_value = process
        with patch.object(gate.subprocess, 'Popen', return_value=process), patch.object(gate.os, 'killpg') as stop:
            with self.assertRaises(KeyboardInterrupt):
                gate.run_child(['fixture-child'])
        self.assertEqual([call.args[1] for call in stop.call_args_list], [gate.signal.SIGTERM, gate.signal.SIGKILL])
        self.assertEqual(process.wait.call_count, 3)

    def test_browser_preflight_checks_supported_node_and_driver_before_build(self):
        with patch.dict(browser_qualification.os.environ, {'CYBEXOS_BROWSER': '/fixture/browser'}), \
             patch.object(browser_qualification.shutil, 'which', return_value=None), \
             patch.object(browser_qualification.os, 'access', return_value=True), \
             patch.object(browser_qualification.subprocess, 'run', return_value=SimpleNamespace(returncode=1)) as run:
            with self.assertRaisesRegex(RuntimeError, 'Node.js >=20'):
                browser_qualification.browser_dependencies()
            source = run.call_args.args[0][-1]
            self.assertIn('process.versions.node', source)
            self.assertIn('require("playwright-core")', source)


if __name__ == '__main__':
    unittest.main()
