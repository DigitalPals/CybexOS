#!/usr/bin/env python3
"""Exercise first-upgrade recovery deployment without touching the host."""
import contextlib
import importlib.machinery
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import tempfile
import types
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
loader = importlib.machinery.SourceFileLoader('bootstrap', str(
    ROOT / 'roles/base/files/cybexos-update-bootstrap'))
spec = importlib.util.spec_from_loader(loader.name, loader)
bootstrap = importlib.util.module_from_spec(spec)
loader.exec_module(bootstrap)


class Bootstrap(unittest.TestCase):
    def setUp(self):
        temporary = self.enterContext(tempfile.TemporaryDirectory(prefix='cybexos-bootstrap-test.'))
        self.fixture = Path(temporary)
        self.host = self.fixture / 'system'
        self.host.mkdir()
        self.source = self.fixture / 'source'
        self.source.mkdir()
        for name in bootstrap.FILES:
            shutil.copyfile(ROOT / 'roles/base/files' / name, self.source / name)
        self.point = '20260930T140000Z-100'
        self.protected = '20260930T140001Z-101'
        self.store = types.SimpleNamespace(path=self.fixture / 'store', roots=self.fixture / 'snapshots')
        self.store.path.mkdir()
        self.store.roots.mkdir()
        (self.store.roots / self.point).mkdir()
        self.layout = types.SimpleNamespace(usable=True, pending_reboot=False, kind='btrfs')
        self.snapshot = types.SimpleNamespace(detect_layout=lambda: self.layout,
                                             opened_store=self.opened_store,
                                             command_create=self.create_snapshot)
        self.commands = []
        self.enabled = False
        for key, value in (
            ('HOST', self.host), ('ROOT_UID', os.getuid()),
            ('BUNDLES', self.host / 'usr/local/libexec/cybexos-update-bootstrap.d'),
            ('UNIT', self.host / 'etc/systemd/system/cybexos-update-recover.service'),
            ('VENDOR_UNIT', self.host / 'usr/lib/systemd/system/cybexos-update-recover.service'),
            ('snapshot_module', lambda _contents: self.snapshot), ('execute', self.execute),
        ):
            self.enterContext(patch.object(bootstrap, key, value))

    @contextlib.contextmanager
    def opened_store(self, _layout, create=False):
        yield self.store

    def execute(self, command):
        self.commands.append(command)
        if command[:2] == ['systemctl', 'enable']:
            self.enabled = True
        if command[:2] == ['systemctl', 'is-enabled']:
            return 'enabled' if self.enabled else 'disabled'
        if command[:2] == ['systemctl', 'show']:
            unit = command[2]
            property_name = command[4]
            if property_name == 'ExecStart':
                file = bootstrap.UNIT if bootstrap.UNIT.exists() else bootstrap.VENDOR_UNIT
                text = file.read_text()
                start = next(line.split('=', 1)[1] for line in text.splitlines() if line.startswith('ExecStart='))
                return '{ path=' + start + ' ; argv[]=' + start + ' ; }'
            barrier = bootstrap.UNIT.parent / f'{unit}.d/60-cybexos-update-recover.conf'
            if barrier.exists() and f'{property_name}=cybexos-update-recover.service' in barrier.read_text():
                return 'cybexos-update-recover.service'
            return ''
        return ''

    def create_snapshot(self, _arguments):
        # The actual point captures installed code and login barriers before
        # any journal can permit package/home mutation. Root restoration must
        # recover this hook, not the pre-feature root without one.
        shutil.copytree(self.host, self.store.roots / self.protected)
        print(self.protected)

    def prepare(self):
        return bootstrap.prepare(self.source, self.point, 'update-fixture')

    def test_first_upgrade_captures_a_self_contained_root_owned_recovery_hook(self):
        result = self.prepare()
        self.assertEqual(result['snapshot'], self.protected)
        self.assertEqual(result['previousSnapshot'], self.point)
        bundle = Path(result['transactionHelper']).parent
        bootstrap.ready(bundle)
        preserved_root = self.store.roots / self.protected
        preserved_unit = preserved_root / bootstrap.UNIT.relative_to(self.host)
        self.assertIn(f'ExecStart={bundle}/cybexos-update-recover', preserved_unit.read_text())
        for name in bootstrap.FILES:
            preserved = preserved_root / bundle.relative_to(self.host) / name
            self.assertEqual(preserved.read_bytes(), (self.source / name).read_bytes())
            self.assertEqual(preserved.stat().st_mode & 0o022, 0)
        for unit in ('systemd-user-sessions.service', 'sddm.service'):
            barrier = preserved_unit.parent / f'{unit}.d/60-cybexos-update-recover.conf'
            self.assertIn('Requires=cybexos-update-recover.service', barrier.read_text())
        self.assertEqual(list((self.store.roots / self.point).iterdir()), [], 'untouched original point')
        (self.source / 'cybexos-update-transaction').write_text('changed user checkout')
        self.assertNotEqual((bundle / 'cybexos-update-transaction').read_text(), 'changed user checkout')

    def test_missing_checkpoint_refuses_before_any_installed_write(self):
        (self.store.roots / self.point).rmdir()
        with self.assertRaisesRegex(bootstrap.Failure, 'missing'):
            self.prepare()
        self.assertEqual(list(self.host.iterdir()), [])
        self.assertEqual(self.commands, [])

    def test_unfinished_journal_blocks_bootstrap_and_cleanup(self):
        result = self.prepare()
        journal = self.store.path / 'transactions/earlier/transaction.json'
        journal.parent.mkdir(parents=True)
        journal.write_text(json.dumps({'state': 'rolling-back'}))
        with self.assertRaisesRegex(bootstrap.Failure, 'earlier update'):
            self.prepare()
        bundle = Path(result['transactionHelper']).parent
        with self.assertRaisesRegex(bootstrap.Failure, 'unfinished update'):
            bootstrap.finalize(bundle)
        self.assertTrue(bundle.is_dir())

    def test_login_barrier_and_enablement_are_required(self):
        result = self.prepare()
        bundle = Path(result['transactionHelper']).parent
        self.enabled = False
        with self.assertRaisesRegex(bootstrap.Failure, 'not enabled'):
            bootstrap.ready(bundle)
        self.enabled = True
        barrier = bootstrap.UNIT.parent / 'sddm.service.d/60-cybexos-update-recover.conf'
        barrier.unlink()
        with self.assertRaisesRegex(bootstrap.Failure, 'barrier'):
            bootstrap.ready(bundle)

    def test_snapshot_failure_leaves_boot_recovery_but_no_package_mutation(self):
        with patch.object(self.snapshot, 'command_create', side_effect=OSError('snapshot failed')):
            with self.assertRaisesRegex(OSError, 'snapshot failed'):
                self.prepare()
        self.assertTrue(bootstrap.UNIT.is_file())
        self.assertFalse((self.store.roots / self.protected).exists())
        self.assertTrue(all(command[0] in {'sync', 'systemctl', 'restorecon'} for command in self.commands))

    def test_source_and_destination_symlinks_fail_closed(self):
        target = self.source / 'cybexos-update-transaction'
        target.unlink()
        target.symlink_to(ROOT / 'roles/base/files/cybexos-update-transaction')
        with self.assertRaises(OSError):
            self.prepare()
        self.assertEqual(list(self.host.iterdir()), [])
        target.unlink()
        shutil.copyfile(ROOT / 'roles/base/files/cybexos-update-transaction', target)
        (self.host / 'usr').symlink_to(self.fixture / 'escape')
        with self.assertRaises((OSError, bootstrap.Failure)):
            self.prepare()
        self.assertFalse((self.fixture / 'escape').exists())

    def test_bundle_corruption_is_not_reused(self):
        result = self.prepare()
        helper = Path(result['transactionHelper'])
        helper.write_text('unexpected change')
        with self.assertRaisesRegex(bootstrap.Failure, 'changed'):
            self.prepare()

    def install_normal(self, rpm=False):
        libexec = self.host / ('usr/libexec' if rpm else 'usr/local/libexec')
        bootstrap.directory(libexec)
        for name in bootstrap.FILES[:6]:
            bootstrap.atomic_write(libexec / name, (self.source / name).read_bytes(),
                                   0o644 if name.endswith('.json') else 0o755)
        unit = (self.source / 'cybexos-update-recover.service').read_text()
        unit = unit.replace('/usr/local/libexec/', str(libexec) + '/')
        bootstrap.atomic_write(bootstrap.VENDOR_UNIT if rpm else bootstrap.UNIT, unit.encode())
        return libexec

    def test_source_convergence_retires_only_the_bootstrap_bundle(self):
        result = self.prepare()
        bundle = Path(result['transactionHelper']).parent
        normal = self.install_normal()
        bootstrap.finalize(bundle)
        self.assertFalse(bundle.exists())
        bootstrap.ready(normal)
        self.assertTrue((self.store.roots / self.protected / bundle.relative_to(self.host)).is_dir())

    def test_rpm_convergence_removes_only_the_bootstrap_unit_override(self):
        result = self.prepare()
        bundle = Path(result['transactionHelper']).parent
        normal = self.install_normal(rpm=True)
        bootstrap.finalize(bundle)
        self.assertFalse(bundle.exists())
        self.assertFalse(bootstrap.UNIT.exists())
        bootstrap.ready(normal)

    def test_package_only_update_keeps_its_required_recovery_implementation(self):
        result = self.prepare()
        bundle = Path(result['transactionHelper']).parent
        with contextlib.redirect_stderr(io.StringIO()) as warning:
            bootstrap.finalize(bundle)
        self.assertIn('retained', warning.getvalue())
        bootstrap.ready(bundle)


if __name__ == '__main__':
    unittest.main()
