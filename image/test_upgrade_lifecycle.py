"""Exercise installed RPM upgrade ownership, deferred work and retry contracts."""
from contextlib import nullcontext
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import jinja2
import yaml

from desktop_payload import prepare_managed_defaults

ROOT = Path(__file__).resolve().parents[1]


def load(name, relative):
    loader = importlib.machinery.SourceFileLoader(name, str(ROOT / relative))
    spec = importlib.util.spec_from_loader(name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


RECONCILE = load('upgrade_reconcile', 'image/rootfs/usr/libexec/cybexos-reconcile')
INIT = load('upgrade_init', 'image/rootfs/usr/libexec/cybexos-user-init')
MANAGED = load('upgrade_managed', 'image/library/cybexos_managed_file.py')


class Ownership(unittest.TestCase):
    def test_adopt_upgrade_backup_preserve_edit_and_deletion(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            file, ledger = root / 'file', root / 'state/ownership.json'
            file.write_bytes(b'original')
            self.assertTrue(MANAGED.manage(file, b'new', ledger)['preserved'])
            self.assertEqual(file.read_bytes(), b'original')
            self.assertFalse(MANAGED.manage(file, b'original', ledger)['changed'])
            self.assertTrue(MANAGED.manage(file, b'new', ledger)['changed'])
            backups = [p for p in (ledger.parent / 'backups').rglob('*') if p.is_file()]
            self.assertEqual([p.read_bytes() for p in backups], [b'original'])
            file.write_bytes(b'personal')
            self.assertTrue(MANAGED.manage(file, b'newer', ledger)['preserved'])
            file.unlink()
            self.assertTrue(MANAGED.manage(file, b'newer', ledger)['preserved'])
            self.assertFalse(file.exists())

    def test_symlinked_parent_never_writes_external_file(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'external').mkdir()
            (root / 'link').symlink_to(root / 'external')
            result = MANAGED.manage(root / 'link/file', b'default', root / 'ledger')
            self.assertTrue(result['preserved'])
            self.assertFalse((root / 'external/file').exists())

    def test_failed_publication_recovers_without_losing_ownership(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            file, ledger = root / 'file', root / 'state/ownership.json'
            MANAGED.manage(file, b'old', ledger)
            atomic = MANAGED.atomic
            def fail(path, content, mode=0o600):
                if path == file:
                    raise OSError('disk full')
                atomic(path, content, mode)
            with patch.object(MANAGED, 'atomic', side_effect=fail):
                with self.assertRaises(OSError):
                    MANAGED.manage(file, b'new', ledger)
            self.assertEqual(file.read_bytes(), b'old')
            self.assertTrue(MANAGED.manage(file, b'new', ledger)['changed'])
            self.assertEqual(file.read_bytes(), b'new')

    def test_owned_removal_and_custom_override_removal(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            file, ledger = root / 'file', root / 'state/ownership.json'
            MANAGED.manage(file, b'old', ledger)
            self.assertTrue(MANAGED.manage(file, b'', ledger, absent=True)['changed'])
            file.write_bytes(b'custom')
            self.assertTrue(MANAGED.manage(file, b'', ledger, absent=True)['preserved'])
            self.assertEqual(file.read_bytes(), b'custom')


class Lifecycle(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.vendor, self.state = self.root / 'vendor', self.root / 'state'
        self.vendor.mkdir()
        self.version = self.vendor / 'reconcile-version'
        self.version.write_text('a' * 64)
        self.config = self.root / 'config.yml'
        self.config.write_text('saved choices')
        self.alice = SimpleNamespace(pw_name='alice', pw_uid=1000, pw_gid=1000, pw_dir='/home/alice')
        self.bob = SimpleNamespace(pw_name='bob', pw_uid=1001, pw_gid=1001, pw_dir='/home/bob')
        for key, value in (('VENDOR', self.vendor), ('STATE', self.state), ('CONFIG', self.config)):
            patcher = patch.object(RECONCILE, key, value)
            patcher.start()
            self.addCleanup(patcher.stop)
        self.users = patch.object(RECONCILE, 'accounts', return_value=[self.alice]).start()
        self.idle = patch.object(RECONCILE, 'rpm_idle', side_effect=lambda: nullcontext()).start()
        self.apply = patch.object(RECONCILE, 'apply').start()
        self.addCleanup(patch.stopall)

    def test_success_stops_convergence_until_version_config_or_account_changes(self):
        self.assertEqual(RECONCILE.reconcile()['state'], 'ready')
        for _ in range(4):
            self.assertEqual(RECONCILE.reconcile()['state'], 'ready')
        self.apply.assert_called_once_with(self.alice)
        self.version.write_text('b' * 64)
        RECONCILE.reconcile()
        self.assertEqual(self.apply.call_count, 2)
        self.config.write_text('new saved choices')
        RECONCILE.reconcile()
        self.assertEqual(self.apply.call_count, 3)
        self.users.return_value = [self.alice, self.bob]
        RECONCILE.reconcile()
        self.assertEqual(self.apply.call_count, 4)
        self.apply.assert_called_with(self.bob)

    def test_failure_budget_survives_runs_and_explicit_retry_resets_it(self):
        self.apply.side_effect = subprocess.CalledProcessError(1, ['fixture'])
        for _ in range(6):
            state = RECONCILE.reconcile()
        self.assertEqual(state['state'], 'blocked')
        self.assertEqual(self.apply.call_count, RECONCILE.MAX_ATTEMPTS)
        self.assertIn('fixture', state['accounts']['alice']['error'])
        self.apply.side_effect = None
        self.assertEqual(RECONCILE.reconcile(retry=True)['state'], 'ready')
        self.assertEqual(self.apply.call_count, RECONCILE.MAX_ATTEMPTS + 1)
        self.assertNotIn('error', RECONCILE.status()['accounts']['alice'])

    def test_completed_accounts_not_repeated_after_other_account_failure(self):
        self.users.return_value = [self.alice, self.bob]
        def apply(account):
            if account.pw_name == 'bob':
                raise OSError('fixture failure')
        self.apply.side_effect = apply
        for _ in range(4):
            RECONCILE.reconcile()
        self.assertEqual([call.args[0].pw_name for call in self.apply.call_args_list],
                         ['alice', 'bob', 'bob', 'bob'])

    def test_transaction_busy_defers_without_spending_attempt_budget(self):
        self.idle.side_effect = BlockingIOError('RPM busy')
        for _ in range(5):
            state = RECONCILE.reconcile()
        self.apply.assert_not_called()
        self.assertEqual(state['state'], 'pending')
        self.assertEqual(state['accounts']['alice']['attempts'], 0)

    def test_new_release_makes_old_ready_status_pending(self):
        RECONCILE.reconcile()
        self.assertFalse(RECONCILE.status()['pending'])
        self.version.write_text('b' * 64)
        self.assertTrue(RECONCILE.status()['pending'])
        self.assertEqual(RECONCILE.status()['state'], 'pending')

    def test_dormant_account_needs_no_running_user_bus(self):
        # Invoke the real worker with all subprocesses mocked. A dormant
        # account still gets ownership-safe baseline and per-user defaults.
        with patch.object(Path, 'exists', return_value=False), patch.object(RECONCILE.subprocess, 'run') as run:
            # setUp patches apply; retrieve the function through a fresh module.
            worker = load('dormant_reconcile', 'image/rootfs/usr/libexec/cybexos-reconcile')
            worker.apply(self.alice)
        commands = [call.args[0] for call in run.call_args_list]
        self.assertEqual(len(commands), 2)
        self.assertIn('--reconcile', commands[0])
        self.assertEqual(commands[1], ['/usr/libexec/cybexos-configure-installed', '--drain'])
        self.assertNotIn('timeout', run.call_args_list[0].kwargs)

    def test_local_user_reload_matches_feature_change_and_checkout_bus_policy(self):
        worker = load('local_bus_reconcile', 'image/rootfs/usr/libexec/cybexos-reconcile')
        plays = yaml.safe_load((ROOT / 'image/provision.yml').read_text())[0]['tasks']
        features = next(task['block'] for task in plays if task['name'] ==
                        'Apply the configured desktop features to every account')
        reload_task = next(task for task in features if task['name'] ==
                           "Reload the account's user manager after a feature change")
        bus_task = next(task for task in features if task['name'] == "Inspect the account's runtime bus")
        self.assertNotIn('failed_when', reload_task)
        self.assertIn('not cybexos_offline | bool', reload_task['when'])
        self.assertIn('image_account_bus.stat.exists | default(false)', reload_task['when'])
        self.assertIn('is changed', reload_task['when'][-1])
        for account in (self.alice, self.bob):
            with self.subTest(account=account.pw_name), patch.dict(os.environ, {
                    'DBUS_SESSION_BUS_ADDRESS': 'unix:path=/wrong/session',
                    'SYSTEMCTL_FORCE_BUS': '1', 'LD_PRELOAD': '/wrong/library'}, clear=True), \
                    patch.object(Path, 'exists', autospec=True, return_value=True) as exists, \
                    patch.object(worker.subprocess, 'run') as run:
                worker.apply(account)
                exists.assert_called_once_with(Path(f'/run/user/{account.pw_uid}/bus'))
                calls = run.call_args_list
                self.assertEqual([call.args[0] for call in calls[:2]], [
                    ['/usr/libexec/cybexos-configure-installed', '--reconcile', '--user', account.pw_name],
                    ['/usr/libexec/cybexos-configure-installed', '--drain']])
                reload = calls[2]
                self.assertEqual(len(calls), 3)
                self.assertTrue(reload.kwargs['check'])
                self.assertEqual(reload.args[0][:3], ['/usr/bin/timeout', '--kill-after=5s', '30s'])
                self.assertEqual(reload.args[0][3:9], [
                    '/usr/sbin/runuser', '-u', account.pw_name, '--', '/usr/bin/env', '-i'])
                self.assertEqual(reload.args[0][-3:], ['/usr/bin/systemctl', '--user', 'daemon-reload'])
                expected_env = {'PATH': '/usr/sbin:/usr/bin:/sbin:/bin', 'HOME': account.pw_dir,
                                'LANG': 'C.UTF-8', 'PYTHONDONTWRITEBYTECODE': '1',
                                'XDG_RUNTIME_DIR': f'/run/user/{account.pw_uid}',
                                'DBUS_SESSION_BUS_ADDRESS': f'unix:path=/run/user/{account.pw_uid}/bus'}
                self.assertEqual(dict(item.split('=', 1) for item in reload.args[0][9:-3]), expected_env)
                self.assertEqual(reload.kwargs['env'], {key: value for key, value in expected_env.items()
                                                      if key not in ('XDG_RUNTIME_DIR', 'DBUS_SESSION_BUS_ADDRESS')}
                                 | {'HOME': '/root'})
                variables = {'primary_user': account.pw_name, 'primary_home': account.pw_dir,
                             'ansible_facts': {'getent_passwd': {account.pw_name: [
                                 'x', str(account.pw_uid), str(account.pw_gid), '', account.pw_dir]}}}
                def render(value):
                    return jinja2.Template(value, undefined=jinja2.StrictUndefined).render(variables)
                feature_command = [render(value) for value in reload_task['ansible.builtin.command']['argv']]
                self.assertEqual(feature_command[:3], ['/usr/bin/timeout', '--kill-after=5s', '30s'])
                self.assertEqual(feature_command[3:9], reload.args[0][3:9])
                self.assertEqual(dict(item.split('=', 1) for item in feature_command[9:-3]), expected_env)
                self.assertEqual(feature_command[-3:], reload.args[0][-3:])
                self.assertEqual(render(bus_task['ansible.builtin.stat']['path']),
                                 f'/run/user/{account.pw_uid}/bus')
                # The checkout already addresses its own account's local user
                # manager. Keep installed feature changes on that same bus.
                desktop = yaml.safe_load((ROOT / 'roles/desktop/tasks/main.yml').read_text())
                checkout = next(task for task in desktop if task.get('name') ==
                                'Make the explicitly rooted Quickshell unit immediately available')
                self.assertEqual(checkout['ansible.builtin.systemd_service']['scope'], 'user')
                self.assertEqual(render(checkout['environment']['XDG_RUNTIME_DIR']),
                                 expected_env['XDG_RUNTIME_DIR'])

    def test_local_user_reload_failures_propagate_after_provisioning_drain(self):
        worker = load('failed_bus_reconcile', 'image/rootfs/usr/libexec/cybexos-reconcile')
        for failure in (subprocess.CalledProcessError(1, ['systemctl']),
                        subprocess.TimeoutExpired(['systemctl'], 30)):
            with self.subTest(failure=type(failure).__name__), \
                    patch.object(Path, 'exists', return_value=True), \
                    patch.object(worker.subprocess, 'run', side_effect=[None, None, failure]) as run:
                with self.assertRaises(type(failure)):
                    worker.apply(self.alice)
                self.assertEqual(run.call_args_list[1].args[0],
                                 ['/usr/libexec/cybexos-configure-installed', '--drain'])
                self.assertEqual(run.call_count, 3, 'no bridge fallback or reload retry')

    def test_reload_deadline_kills_stalled_client_and_closes_output_pipe(self):
        worker = load('stalled_bus_reconcile', 'image/rootfs/usr/libexec/cybexos-reconcile')
        fake_runuser = self.root / 'stalled-runuser.py'
        process_ids = self.root / 'clients.json'
        fake_runuser.write_text(
            'import json, os, signal, subprocess, sys\n'
            'signal.signal(signal.SIGTERM, signal.SIG_IGN)\n'
            'child = subprocess.Popen([sys.executable, "-c", '
            '"import signal, time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(60)"])\n'
            'def identity(pid):\n'
            '    with open(f"/proc/{pid}/stat") as stream: return [pid, stream.read().rsplit(")", 1)[1].split()[19]]\n'
            'with open(sys.argv[1], "w") as stream: json.dump([identity(os.getpid()), identity(child.pid)], stream)\n'
            'child.wait()\n')
        real_run = subprocess.run
        def run(command, **kwargs):
            if command[0] == '/usr/libexec/cybexos-configure-installed':
                return subprocess.CompletedProcess(command, 0)
            self.assertEqual(command[:3], ['/usr/bin/timeout', '--kill-after=5s', '30s'])
            # Keep production's process-group timeout; shorten only this
            # fixture's deadlines and replace the privileged client body.
            fixture = [command[0], '--kill-after=0.3s', '0.3s',
                       sys.executable, str(fake_runuser), str(process_ids)]
            return real_run(fixture, **kwargs, text=True, capture_output=True, timeout=3)
        def still_alive(pid, start_ticks):
            try:
                fields = Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()
            except (FileNotFoundError, ProcessLookupError):
                return False
            return fields[19] == start_ticks and fields[0] != 'Z'
        try:
            with patch.object(Path, 'exists', return_value=True), \
                    patch.object(worker.subprocess, 'run', side_effect=run):
                started = time.monotonic()
                with self.assertRaises(subprocess.CalledProcessError):
                    worker.apply(self.alice)
                self.assertLess(time.monotonic() - started, 3)
            for pid, start_ticks in json.loads(process_ids.read_text()):
                self.assertFalse(still_alive(pid, start_ticks),
                                 'the client must be dead before the output pipe closes')
        finally:
            if process_ids.is_file():
                for pid, start_ticks in json.loads(process_ids.read_text()):
                    if still_alive(pid, start_ticks):
                        try:
                            os.kill(pid, signal.SIGKILL)
                        except ProcessLookupError:
                            pass

    def test_no_accounts_remains_pending(self):
        self.users.return_value = []
        self.assertEqual(RECONCILE.reconcile()['state'], 'pending')
        self.apply.assert_not_called()


class UserUpgrade(unittest.TestCase):
    def test_defaults_upgrade_even_after_apps_seeded_and_keep_personal_state(self):
        with tempfile.TemporaryDirectory() as temporary, patch.dict(os.environ, {}, clear=True):
            root = Path(temporary)
            vendor, home = root / 'vendor', root / 'home'
            (vendor / 'bin').mkdir(parents=True)
            (vendor / 'lib').mkdir()
            shutil.copyfile(ROOT / 'image/library/cybexos_managed_file.py', vendor / 'lib/managed_files.py')
            relative = '.config/kitty/cybexos.conf'
            seed = vendor / 'essential-seed' / relative
            seed.parent.mkdir(parents=True)
            seed.write_text('version one')
            prepare_managed_defaults(vendor)
            (vendor / 'reconcile-version').write_text('a' * 64)
            (vendor / 'user-seed').mkdir()
            (vendor / 'user-seed/app-tool').write_text('tool one')
            INIT.initialize(home, vendor)
            self.assertEqual((home / relative).read_text(), 'version one')
            (home / 'app-tool').write_text('user updated tool')
            (vendor / 'managed-seed' / relative).write_text('version two')
            (vendor / 'user-seed/app-tool').write_text('tool two')
            (vendor / 'reconcile-version').write_text('b' * 64)
            INIT.initialize(home, vendor)
            self.assertEqual((home / relative).read_text(), 'version two')
            self.assertEqual((home / 'app-tool').read_text(), 'user updated tool')
            (home / relative).write_text('personal preferences')
            (vendor / 'reconcile-version').write_text('c' * 64)
            INIT.initialize(home, vendor)
            self.assertEqual((home / relative).read_text(), 'personal preferences')
            status = json.loads((home / '.local/state/cybexos/defaults-progress.json').read_text())
            self.assertEqual(status['state'], 'ready')
            self.assertEqual(status['preserved'], [relative])

    def test_rpm_posttrans_only_queues_and_bridge_uses_packaged_code(self):
        spec = (ROOT / 'image/cybexos-desktop.spec').read_text().split('%posttrans', 1)[1].split('%changelog')[0]
        self.assertIn('cybexos-reconcile --queue', spec)
        self.assertNotIn('ansible-playbook', spec)
        self.assertNotIn('cybexos-configure-installed', spec)
        source = (ROOT / 'roles/desktop/templates/hermes-menubar-bridge.service.j2').read_text()
        unit = jinja2.Template(source).render(primary_home='%h', hermes_bridge_executable='/usr/libexec/cybexos-hermes-menubar-bridge')
        self.assertIn('ExecStart=/usr/bin/python3 /usr/libexec/cybexos-hermes-menubar-bridge', unit)
        self.assertIn('--state %h/.local/state/hermes-menubar/conversations.json', unit)
        package = (ROOT / 'image/package').read_text()
        self.assertNotIn('f"{seed}/.local/libexec/hermes-menubar-bridge"', package)


if __name__ == '__main__':
    unittest.main()
