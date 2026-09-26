"""Exercise installed RPM upgrade ownership, deferred work and retry contracts."""
from contextlib import nullcontext
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

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
        self.assertEqual(commands[1][0], '/usr/sbin/runuser')

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
        import jinja2
        source = (ROOT / 'roles/desktop/templates/hermes-menubar-bridge.service.j2').read_text()
        unit = jinja2.Template(source).render(primary_home='%h', hermes_bridge_executable='/usr/libexec/cybexos-hermes-menubar-bridge')
        self.assertIn('ExecStart=/usr/bin/python3 /usr/libexec/cybexos-hermes-menubar-bridge', unit)
        self.assertIn('--state %h/.local/state/hermes-menubar/conversations.json', unit)
        package = (ROOT / 'image/package').read_text()
        self.assertNotIn('f"{seed}/.local/libexec/hermes-menubar-bridge"', package)


if __name__ == '__main__':
    unittest.main()
