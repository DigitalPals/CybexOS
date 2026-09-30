#!/usr/bin/env python3
"""Exercise the durable recovery journal against disposable filesystem state."""
import contextlib
import importlib.machinery
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import types
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
loader = importlib.machinery.SourceFileLoader('transaction', str(
    ROOT / 'roles/base/files/cybexos-update-transaction'))
spec = importlib.util.spec_from_loader(loader.name, loader)
transaction = importlib.util.module_from_spec(spec)
loader.exec_module(transaction)


class Recovery(unittest.TestCase):
    def setUp(self):
        self.enterContext(contextlib.redirect_stdout(io.StringIO()))
        self.temp = tempfile.TemporaryDirectory(prefix='cybexos-transaction-test.')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.home = self.root / 'home'
        self.home.mkdir()
        self.store = transaction.snapshot.Store(self.root)
        for directory in (self.store.roots, self.store.boot, self.store.metadata, self.store.replaced):
            directory.mkdir(parents=True, exist_ok=True)
        self.point = '20260930T100000Z-123'
        (self.store.roots / self.point).mkdir()
        self.layout = types.SimpleNamespace(usable=True, kind='btrfs', pending_reboot=False,
                                            uuid='fixture')
        self.vendor = ['.local/share/cybexos/runtime', '.local/share/cybexos/current', '.local/bin/helper']
        (self.home / self.vendor[0]).mkdir(parents=True)
        (self.home / self.vendor[0] / 'shell.qml').write_text('old desktop')
        (self.home / self.vendor[1]).symlink_to('releases/1.0.0')
        self.personal = self.home / '.config/cybexos/shell.json'
        self.personal.parent.mkdir(parents=True)
        self.personal.write_text('{"personal": true}')
        for name, value in (
            ('vendor_paths', lambda: self.vendor),
            ('failed_units', lambda: []),
            ('desktop_active', lambda _uid: False),
            ('boot_id', lambda: 'old-boot'),
            ('health', lambda _record, **_options: None),
        ):
            mocked = patch.object(transaction, name, value)
            mocked.start()
            self.addCleanup(mocked.stop)
        account = types.SimpleNamespace(pw_dir=str(self.home), pw_name='fixture', pw_gid=os.getgid())
        for target, name, value in (
            (transaction.pwd, 'getpwuid', lambda _uid: account),
            (transaction.snapshot, 'detect_layout', lambda: self.layout),
            (transaction.snapshot, 'opened_store', self.opened_store),
            (transaction.snapshot, 'subvolume_uuid', lambda _path: 'original-root'),
            (transaction.snapshot, 'complete_interrupted', lambda _store: None),
            (transaction.snapshot, 'command_restore', self.restore),
        ):
            mocked = patch.object(target, name, value)
            mocked.start()
            self.addCleanup(mocked.stop)
        self.restores = 0

    @contextlib.contextmanager
    def opened_store(self, _layout, create=False):
        yield self.store

    def restore(self, _args):
        self.restores += 1
        self.layout.pending_reboot = True
        path = self.store.replaced / 'root.replaced-20260930T100100Z.json'
        path.write_text(json.dumps({'point': self.point, 'state': 'complete'}))

    def begin(self):
        transaction.begin('update-fixture', self.point, os.getuid())

    def record(self):
        return transaction.read(self.store.path / 'transactions/update-fixture')

    def test_boot_home_operations_drop_identity_without_opening_a_pam_session(self):
        command = ['/usr/bin/tar', '--list', '--file=-']
        with patch.object(transaction.os, 'geteuid', return_value=0):
            dropped = transaction.home_command(1201, command)
        self.assertEqual(dropped, ['/usr/bin/setpriv', '--reuid', '1201', '--regid', str(os.getgid()),
                                   '--init-groups', '--', '/usr/bin/env', f'HOME={self.home}',
                                   'USER=fixture', 'LOGNAME=fixture', *command])
        with patch.object(transaction.os, 'geteuid', return_value=1201):
            self.assertEqual(transaction.home_command(1201, command), command)

    def test_commit_validates_and_releases_checkpoint_and_pin(self):
        self.begin()
        transaction.transition('update-fixture', 'applying')
        with patch.object(transaction, 'health') as health:
            transaction.transition('update-fixture', 'commit')
            health.assert_called_once()
        self.assertEqual(self.record()['state'], 'committed')
        self.assertFalse((self.store.metadata / f'{self.point}.pin').exists())
        self.assertFalse((self.store.path / 'transactions/update-fixture/vendor').exists())

    def test_health_failure_keeps_checkpoint_until_automatic_rollback(self):
        self.begin()
        transaction.transition('update-fixture', 'applying')
        (self.home / self.vendor[0] / 'shell.qml').write_text('broken new desktop')
        self.personal.write_text('{"personal": "edited while updating"}')
        (self.home / '.local/bin').mkdir(parents=True)
        (self.home / '.local/bin/helper').write_text('new helper')
        with patch.object(transaction, 'health', side_effect=transaction.snapshot.Failure('bad QML')):
            with self.assertRaises(transaction.snapshot.Failure):
                transaction.transition('update-fixture', 'commit')
        transaction.rollback('update-fixture')
        self.assertEqual(self.restores, 1)
        self.assertEqual(self.record()['state'], 'rolled-back')
        self.assertTrue(self.record()['restartRequired'])
        self.assertEqual((self.home / self.vendor[0] / 'shell.qml').read_text(), 'old desktop')
        self.assertFalse((self.home / '.local/bin/helper').exists())
        self.assertEqual(self.personal.read_text(), '{"personal": "edited while updating"}')
        self.assertEqual(os.readlink(self.home / self.vendor[1]), 'releases/1.0.0')
        transaction.rollback('update-fixture')
        self.assertEqual(self.restores, 1, 'retry must not exchange roots twice')

    def test_terminal_cleanup_failure_cannot_reopen_a_completed_transaction(self):
        for action, terminal in (('commit', 'committed'), ('rollback', 'rolled-back')):
            with self.subTest(action=action):
                identifier = 'cleanup-' + action
                transaction.begin(identifier, self.point, os.getuid())
                transaction.transition(identifier, 'applying')
                with patch.object(transaction, 'remove', side_effect=OSError('cleanup interrupted')):
                    with contextlib.redirect_stderr(io.StringIO()) as errors:
                        if action == 'rollback':
                            transaction.rollback(identifier)
                        else:
                            transaction.transition(identifier, action)
                    self.assertIn('retained cleanup artifact', errors.getvalue())
                record = transaction.read(self.store.path / 'transactions' / identifier)
                self.assertEqual(record['state'], terminal)
                with patch.object(transaction, 'rollback') as retry:
                    transaction.recover()
                    retry.assert_not_called()

    def test_interrupted_vendor_restore_retries_without_second_root_exchange(self):
        self.begin()
        transaction.transition('update-fixture', 'applying')
        with patch.object(transaction, 'restore_vendor', side_effect=OSError('interrupted')):
            with self.assertRaises(OSError):
                transaction.rollback('update-fixture')
        self.assertEqual(self.record()['state'], 'rollback-failed')
        transaction.rollback('update-fixture')
        self.assertEqual(self.restores, 1)
        self.assertEqual(self.record()['state'], 'rolled-back')

    def test_interrupted_restore_completed_after_reboot_never_exchanges_root_again(self):
        self.begin()
        transaction.transition('update-fixture', 'applying')
        with patch.object(transaction, 'restore_vendor', side_effect=OSError('power lost')):
            with self.assertRaises(OSError):
                transaction.rollback('update-fixture')
        # The exchange completed before power failed, and the next boot uses
        # its restored root; only the user-owned vendor archive needs replay.
        self.layout.pending_reboot = False
        self.personal.write_text('{"edited after restart": true}')
        with patch.object(transaction, 'boot_id', return_value='new-boot'):
            transaction.rollback('update-fixture')
        self.assertEqual(self.restores, 1)
        self.assertFalse(self.record()['restartRequired'])
        self.assertEqual(self.personal.read_text(), '{"edited after restart": true}')

    def test_recovery_from_a_failed_boot_still_requires_restart_after_root_exchange(self):
        self.begin()
        transaction.transition('update-fixture', 'applying')
        with patch.object(transaction, 'boot_id', return_value='failed-new-boot'):
            with self.assertRaises(SystemExit) as error:
                transaction.recover()
        self.assertEqual(error.exception.code, 75)
        self.assertTrue(self.record()['restartRequired'])
        self.assertEqual(self.restores, 1)

    def test_a_failed_sync_leaves_the_durable_applying_record_recoverable(self):
        self.begin()
        original_execute = transaction.execute

        def fail_journal_sync(command, **options):
            if command[:2] == ['sync', '-f']:
                raise transaction.snapshot.Failure('simulated filesystem sync failure')
            return original_execute(command, **options)

        with patch.object(transaction, 'execute', side_effect=fail_journal_sync):
            with self.assertRaises(transaction.snapshot.Failure):
                transaction.transition('update-fixture', 'applying')
        self.assertEqual(self.record()['state'], 'applying')
        with self.assertRaises(transaction.snapshot.Failure):
            transaction.transition('update-fixture', 'abort')
        transaction.rollback('update-fixture')
        self.assertEqual(self.record()['state'], 'rolled-back')
        self.assertEqual(self.restores, 1)

    def test_major_upgrade_waits_for_new_boot_then_explicit_desktop_validation(self):
        self.begin()
        original = self.personal.read_bytes()
        metadata = {'targetFedora': '45', 'source': 'fixture-reviewed-release'}
        transaction.transition('update-fixture', 'arm-upgrade', metadata)
        self.assertEqual(self.record()['state'], 'awaiting-upgrade')
        self.assertEqual(self.record()['upgrade'], metadata)
        with patch.object(transaction.subprocess, 'run') as finalize:
            transaction.recover()
            finalize.assert_not_called()
        transaction.transition('update-fixture', 'applying')
        with patch.object(transaction, 'health') as check:
            transaction.transition('update-fixture', 'await-desktop')
        check.assert_called_once()
        self.assertEqual(check.call_args.kwargs, {'desktop': False})
        self.assertEqual(self.record()['state'], 'awaiting-desktop')
        self.assertTrue(self.record()['desktopActive'])
        self.assertTrue((self.store.metadata / f'{self.point}.pin').exists())
        self.assertTrue((self.store.path / 'transactions/update-fixture/vendor').is_dir())
        with patch.object(transaction.subprocess, 'run') as finalize:
            with patch.object(transaction, 'boot_id', return_value='another-boot'):
                transaction.recover()
            finalize.assert_not_called()
        self.assertEqual(self.personal.read_bytes(), original)
        transaction.transition('update-fixture', 'commit')
        self.assertEqual(self.record()['state'], 'committed')
        self.assertFalse((self.store.metadata / f'{self.point}.pin').exists())
        self.assertEqual(self.personal.read_bytes(), original)

    def test_failed_major_upgrade_finalization_rolls_back_before_logins(self):
        self.begin()
        transaction.transition('update-fixture', 'arm-upgrade', {'targetFedora': '45'})
        original_run = subprocess.run
        finalizations = []

        def execute_fixture(command, **options):
            if command[0].endswith('cybexos-major-upgrade'):
                finalizations.append(command)
                return types.SimpleNamespace(returncode=1)
            return original_run(command, **options)

        with patch.object(transaction.subprocess, 'run', side_effect=execute_fixture):
            with patch.object(transaction, 'boot_id', return_value='new-major-boot'):
                with self.assertRaises(SystemExit) as error:
                    transaction.recover()
        self.assertEqual(error.exception.code, 75)
        self.assertEqual(finalizations[0][1:], ['finalize', 'update-fixture'])
        self.assertEqual(self.record()['state'], 'rolled-back')
        self.assertTrue(self.record()['restartRequired'])
        self.assertEqual(self.personal.read_text(), '{"personal": true}')

    def test_invalid_major_upgrade_transition_keeps_checkpoint_and_user_state(self):
        self.begin()
        before = self.record()
        for metadata in (None, {}, {'targetFedora': 45}, {'targetFedora': '../../root'}):
            with self.subTest(metadata=metadata):
                with self.assertRaises(transaction.snapshot.Failure):
                    transaction.transition('update-fixture', 'arm-upgrade', metadata)
                self.assertEqual(self.record(), before)
                self.assertEqual(self.personal.read_text(), '{"personal": true}')
        with self.assertRaises(transaction.snapshot.Failure):
            transaction.transition('update-fixture', 'await-desktop')
        self.assertTrue((self.store.metadata / f'{self.point}.pin').exists())

    def test_snapshot_retention_never_prunes_an_active_transaction_point(self):
        self.begin()
        old_points = [self.point]
        for index in range(1, 7):
            point = f'20260930T1000{index:02d}Z-123'
            old_points.append(point)
            (self.store.roots / point).mkdir()
            (self.store.boot / f'{point}.tar').write_bytes(b'fixture boot')
            (self.store.metadata / f'{point}.meta').write_text('fixture\n')
        deleted = []

        def filesystem_fixture(command):
            if command[0] == 'tar':
                Path(command[command.index('--file') + 1]).write_bytes(b'new fixture boot')
            elif command[:3] == ['btrfs', 'subvolume', 'snapshot']:
                Path(command[-1]).mkdir()
            elif command[:3] == ['btrfs', 'subvolume', 'delete']:
                deleted.append(Path(command[-1]).name)
                Path(command[-1]).rmdir()
            elif command[:2] != ['sync', '-f']:
                self.fail('Unexpected command escaped the filesystem fixture: ' + repr(command))

        with patch.object(transaction.snapshot, 'run', side_effect=filesystem_fixture), \
                patch.object(transaction.snapshot.shutil, 'which', return_value='/fixture/tool'), \
                patch.object(transaction.snapshot, 'current_kernel', return_value='fixture-kernel'), \
                patch.object(transaction.snapshot, 'regenerate_quietly'), \
                patch.dict(os.environ, {'CYBEXOS_SNAPSHOT_ID': '20260930T100100Z-123'}):
            transaction.snapshot.command_create(['fixture update'])
        self.assertNotIn(self.point, deleted)
        self.assertEqual(deleted, old_points[1:4])
        self.assertTrue((self.store.roots / self.point).is_dir())
        self.assertEqual(len(list(self.store.roots.iterdir())), transaction.snapshot.KEEP)

    def test_boot_recovery_aborts_unapplied_update_and_rolls_back_applied_one(self):
        self.begin()
        with patch.object(transaction, 'boot_id', return_value='next-boot'):
            transaction.recover()
        self.assertEqual(self.record()['state'], 'aborted')
        self.assertEqual(self.restores, 0)
        transaction.begin('second-update', self.point, os.getuid())
        transaction.transition('second-update', 'applying')
        with patch.object(transaction, 'boot_id', return_value='next-boot'):
            with self.assertRaises(SystemExit) as error:
                transaction.recover()
        self.assertEqual(error.exception.code, 75)
        self.assertEqual(self.restores, 1)

    def test_login_dependency_never_recovers_an_update_from_the_current_boot(self):
        self.begin()
        for action, state in ((None, 'prepared'), ('applying', 'applying')):
            if action:
                transaction.transition('update-fixture', action)
            transaction.recover()
            self.assertEqual(self.record()['state'], state)
            self.assertEqual(self.restores, 0)

    def test_refuses_competing_updates_and_illegal_transitions(self):
        self.begin()
        with self.assertRaises(transaction.snapshot.Failure):
            transaction.begin('competing', self.point, os.getuid())
        with self.assertRaises(transaction.snapshot.Failure):
            transaction.transition('update-fixture', 'commit')
        transaction.transition('update-fixture', 'applying')
        with self.assertRaises(transaction.snapshot.Failure):
            transaction.transition('update-fixture', 'abort')

    def test_refuses_symlink_parent_and_preserves_checkpoint(self):
        self.begin()
        (self.home / '.local/bin').symlink_to(self.root / 'outside')
        with self.assertRaises(transaction.snapshot.Failure):
            transaction.rollback('update-fixture')
        self.assertEqual(self.record()['state'], 'rollback-failed')
        self.assertFalse((self.root / 'outside').exists())

    def test_manifest_never_contains_personal_settings_or_registry(self):
        paths = json.loads((ROOT / 'roles/base/files/cybexos-vendor-paths.json').read_text())
        for value in paths:
            self.assertNotIn('.config/cybexos', value)
            self.assertNotIn('.local/share/cybexos/plugins', value)
            self.assertNotIn('.local/share/cybexos/themes', value)
            self.assertNotIn('.service.d', value)

    def test_installed_transaction_payloads_share_the_source(self):
        source = (ROOT / 'image/package').read_text()
        tasks = (ROOT / 'roles/base/tasks/main.yml').read_text()
        for name in ('cybexos-update-transaction', 'cybexos-update-recover', 'cybexos-vendor-paths.json'):
            self.assertIn(name, source)
            self.assertIn(name, tasks)
        subprocess.run(['bash', '-n', str(ROOT / 'roles/base/files/cybexos-update-recover')], check=True)


class DesktopHealth(unittest.TestCase):
    """Actual health state machine, with no host service or process operations."""

    def setUp(self):
        self.clock = 0.0
        self.calls = []
        self.ipc_calls = []
        self.ready_after = 0.0
        self.safe_mode = False
        self.bad_journal = False
        self.extra_process = False
        self.restart_every = None
        self.restart_at = None
        self.ipc_gap = None
        self.record = {'uid': 1000, 'desktopActive': True, 'failedUnits': []}
        self.enterContext(patch.object(transaction, 'as_user', side_effect=lambda _uid, command: command))
        self.enterContext(patch.object(transaction, 'desktop_active', return_value=True))
        self.enterContext(patch.object(transaction, 'failed_units', return_value=[]))
        self.enterContext(patch.object(transaction.pwd, 'getpwuid', return_value=types.SimpleNamespace(
            pw_dir='/nonexistent-cybexos-health-fixture', pw_name='fixture')))
        self.enterContext(patch.object(transaction.time, 'monotonic', side_effect=lambda: self.clock))
        self.enterContext(patch.object(transaction.time, 'sleep', side_effect=self.advance))
        self.enterContext(patch.object(transaction, 'execute', side_effect=self.execute))

    def advance(self, seconds):
        self.clock += seconds

    def generation(self):
        if self.restart_every:
            return int(self.clock // self.restart_every)
        return int(self.restart_at is not None and self.clock >= self.restart_at)

    def execute(self, command, **_options):
        self.calls.append(command)
        if command[:2] == ['rpm', '--verifydb']:
            return ''
        if command[:3] in (['systemctl', '--user', 'daemon-reload'],
                           ['systemctl', '--user', 'restart']):
            return ''
        if command[:3] == ['systemctl', '--user', 'show']:
            if command[-2] == 'InvocationID':
                return f'{self.generation() + 1:032x}'
            if command[-2] == 'MainPID':
                return str(3000 + self.generation())
        if command[0] == 'pgrep':
            value = str(3000 + self.generation())
            return value + '\n9999' if self.extra_process else value
        if command[-2:] == ['shell', 'status']:
            return json.dumps({'safe': self.safe_mode})
        if command[-3:] == ['ipc', 'settings', 'status']:
            self.ipc_calls.append(self.clock)
            if self.clock < self.ready_after:
                raise transaction.snapshot.Failure('IPC is not ready yet')
            if self.ipc_gap and self.ipc_gap[0] <= self.clock < self.ipc_gap[1]:
                raise transaction.snapshot.Failure('IPC disappeared during startup')
            return '{"services":{}}'
        if command[0] == 'journalctl':
            return 'ReferenceError: delayed QML startup failed' if self.bad_journal else 'ready'
        self.fail('Unexpected host operation in health fixture: ' + repr(command))

    def test_delayed_qml_readiness_requires_two_stable_seconds_after_ipc(self):
        self.ready_after = 1.5
        transaction.health(self.record)
        self.assertGreaterEqual(self.clock, 3.5)
        self.assertLess(self.clock, 4)
        self.assertGreater(len(self.ipc_calls), 2)
        self.assertEqual(sum(command[:3] == ['systemctl', '--user', 'restart']
                             for command in self.calls), 1)

    def test_restart_during_validation_resets_pid_and_invocation_stability(self):
        self.restart_at = 1.5
        transaction.health(self.record)
        self.assertGreaterEqual(self.clock, 3.5)
        journal = next(command for command in self.calls if command[0] == 'journalctl')
        self.assertIn('_SYSTEMD_INVOCATION_ID=' + f'{2:032x}', journal)

    def test_lost_ipc_resets_the_stability_interval(self):
        self.ipc_gap = (1, 1.5)
        transaction.health(self.record)
        self.assertGreaterEqual(self.clock, 3.5)

    def test_a_restart_loop_never_becomes_healthy(self):
        self.restart_every = 1
        with self.assertRaisesRegex(transaction.snapshot.Failure, 'IPC-ready'):
            transaction.health(self.record)
        self.assertGreaterEqual(self.clock, 45)
        self.assertFalse(any(command[0] == 'journalctl' for command in self.calls))

    def test_fallback_shell_is_not_a_successful_update(self):
        self.safe_mode = True
        with self.assertRaisesRegex(transaction.snapshot.Failure, 'IPC-ready'):
            transaction.health(self.record)
        self.assertEqual(self.ipc_calls, [])
        self.assertGreaterEqual(self.clock, 45)

    def test_a_second_qs_process_is_rejected(self):
        self.extra_process = True
        with self.assertRaisesRegex(transaction.snapshot.Failure, 'IPC-ready'):
            transaction.health(self.record)
        self.assertEqual(self.ipc_calls, [])

    def test_journal_failure_after_ready_ipc_prevents_commit(self):
        self.bad_journal = True
        with self.assertRaisesRegex(transaction.snapshot.Failure, 'QML errors'):
            transaction.health(self.record)
        self.assertGreaterEqual(self.clock, 2)

    def test_new_failed_units_stop_before_restarting_desktop(self):
        self.record['failedUnits'] = ['existing-failure.service']
        with patch.object(transaction, 'failed_units', return_value=[
                'existing-failure.service', 'new-failure.service']):
            with self.assertRaisesRegex(transaction.snapshot.Failure, 'new-failure.service'):
                transaction.health(self.record)
        self.assertEqual(self.calls, [['rpm', '--verifydb']])

    def test_prelogin_health_never_starts_or_queries_a_desktop(self):
        transaction.health(self.record, desktop=False)
        self.assertEqual(self.calls, [['rpm', '--verifydb']])


if __name__ == '__main__':
    unittest.main()
