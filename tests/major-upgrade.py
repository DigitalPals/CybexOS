#!/usr/bin/env python3
"""Major upgrade fault/recovery fixtures. No host packages, snapshots or services."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import pwd
import subprocess
import tarfile
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
LOADER = importlib.machinery.SourceFileLoader('major_upgrade', str(ROOT / 'roles/base/files/cybexos-major-upgrade'))
SPEC = importlib.util.spec_from_loader(LOADER.name, LOADER)
M = importlib.util.module_from_spec(SPEC)
LOADER.exec_module(M)


class UpgradeTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='cybexos-major-test.')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        for name, path in {'STATE': self.root/'state', 'PAYLOADS': self.root/'payloads',
                           'CONFIG': self.root/'config.yml', 'OFFLINE': self.root/'offline',
                           'TRIGGER': self.root/'system-update'}.items():
            patcher = patch.object(M, name, path)
            patcher.start()
            self.addCleanup(patcher.stop)
        M.CONFIG.write_text('config_schema_version: 1\nprimary_user: fixture\n')
        self.source = self.root/'source'
        (self.source/'inventory/group_vars').mkdir(parents=True)
        self.manifest = {'product':'cybexos', 'supportedFedora':['45'],
                         'architectures':[M.platform.machine()], 'configSchema':1}
        (self.source/'release-manifest.json').write_text(json.dumps(self.manifest))
        (self.source/'inventory/group_vars/all.yml').write_text('fedora_release: "45"\n')
        for name in ('site.yml', 'ansible.cfg', 'inventory/hosts.yml', 'verify'):
            (self.source/name).write_text('fixture\n')
        self.account = pwd.getpwuid(os.getuid())
        self.calls = []
        self.transitions = []

    def baseline(self):
        return {'currentFedora':'44', 'targetFedora':'45', 'uid':self.account.pw_uid,
                'home':self.account.pw_dir, 'secureBoot':'legacy boot', 'hardwareChecks':[]}

    def args(self):
        return argparse.Namespace(target='45', source=self.source, rpm=None, backup=None, uid=self.account.pw_uid)

    def command(self, command, **_kwargs):
        values = list(map(str, command))
        self.calls.append(values)
        if values[0] == str(M.SNAPSHOT):
            return '20300101T000000-123'
        if values[0] == 'dnf5' and 'download' in values:
            M.OFFLINE.mkdir(exist_ok=True)
            (M.OFFLINE/'transaction.json').write_text('{"target":"45"}')
        return ''

    def transaction(self, action, identifier, *extra):
        self.transitions.append((action, identifier, extra))
        return {'state':'awaiting-upgrade' if action == 'status' else action, 'id':identifier}

    def prepared(self):
        with patch.object(M, 'preflight', return_value=self.baseline()), patch.object(M, 'run', side_effect=self.command), patch.object(M, 'transaction', side_effect=self.transaction):
            return M.prepare(self.args())

    def ready(self):
        record = self.prepared()
        with patch.object(M, 'run', side_effect=self.command), patch.object(M, 'transaction', side_effect=self.transaction):
            return M.download(record['id'])

    def test_current_manifest_does_not_advertise_the_next_release(self):
        with self.assertRaises(M.Failure):
            M.compatible(json.loads((ROOT/'release-manifest.json').read_text()), '45', M.platform.machine(), 1)
        for changed in ({'architectures':['aarch64']}, {'configSchema':2}, {'supportedFedora':['44']}):
            with self.assertRaises(M.Failure):
                M.compatible({**self.manifest, **changed}, '45', M.platform.machine(), 1)

    def test_source_inventory_must_agree_and_symlinks_cannot_escape(self):
        (self.source/'inventory/group_vars/all.yml').write_text('fedora_release: "44"\n')
        with self.assertRaisesRegex(M.Failure, 'disagree'):
            M.inspect_target('45', self.source)
        (self.source/'inventory/group_vars/all.yml').write_text('fedora_release: "45"\n')
        (self.source/'outside').symlink_to(self.root/'config.yml')
        with self.assertRaisesRegex(M.Failure, 'escapes'):
            M.inspect_target('45', self.source)

    def test_signed_rpm_requires_target_capability_and_architecture(self):
        rpm = self.root/'target.rpm'
        rpm.write_bytes(b'fixture')
        with patch.object(M, 'run', return_value='digests signatures NOT OK NOKEY'):
            with self.assertRaises(M.Failure):
                M.inspect_target('45', rpm=rpm)
        identity = 'cybexos-desktop\n1.fc45\n' + M.platform.machine() + '\n1.0.0'
        with patch.object(M, 'run', side_effect=['digests signatures OK', identity, 'cybexos-supported-fedora = 44']):
            with self.assertRaisesRegex(M.Failure, 'declare support'):
                M.inspect_target('45', rpm=rpm)
        with patch.object(M, 'run', side_effect=['digests signatures OK', identity, 'cybexos-supported-fedora = 45']):
            self.assertEqual(M.inspect_target('45', rpm=rpm)['kind'], 'rpm')

    def test_prepare_checkpoints_before_a_durable_download_and_preserves_configuration(self):
        before = M.CONFIG.read_bytes()
        record = self.prepared()
        self.assertEqual(record['state'], 'downloading')
        self.assertEqual([x[0] for x in self.transitions], ['begin'])
        self.assertFalse(any('download' in command and command[0]=='dnf5' for command in self.calls))
        self.assertEqual(self.calls[-1][0], 'systemd-run')
        self.assertIn('--property=KillMode=control-group', self.calls[-1])
        self.assertEqual(M.CONFIG.read_bytes(), before)
        self.assertEqual(M.tree_digest(Path(record['candidate']['path'])), record['candidate']['digest'])
        self.assertEqual((M.PAYLOADS/record['id']).stat().st_mode & 0o777, 0o755)

    def test_download_arms_only_after_success_and_never_reboots(self):
        record = self.ready()
        self.assertEqual(record['state'], 'ready')
        self.assertEqual(self.transitions[-1][0], 'arm-upgrade')
        command = next(x for x in self.calls if x[0]=='dnf5')
        self.assertIn('--releasever=45', command)
        self.assertIn('--setopt=gpgcheck=true', command)
        self.assertNotIn('--allowerasing', command)
        self.assertFalse(any('reboot' in x for x in self.calls))
        self.assertFalse(record['rebootRequested'])

    def test_cancel_cannot_interrupt_download_or_delete_replaced_offline_data(self):
        record = self.prepared()
        with self.assertRaises(M.Failure):
            M.ensure_ours(record)
        with patch.object(M, 'run', side_effect=self.command), patch.object(M, 'transaction', side_effect=self.transaction):
            record = M.download(record['id'])
        (M.OFFLINE/'transaction.json').write_text('someone else')
        with self.assertRaisesRegex(M.Failure, 'changed'):
            M.cancel()
        self.assertTrue((M.PAYLOADS/record['id']).exists())

    def test_cancel_only_cleans_its_completed_download(self):
        record = self.ready()
        with patch.object(M, 'run', side_effect=self.command), patch.object(M, 'transaction', side_effect=self.transaction):
            result = M.cancel()
        self.assertEqual(result['state'], 'cancelled')
        self.assertEqual(self.transitions[-1][0], 'abort')
        self.assertFalse((M.PAYLOADS/record['id']).exists())
        self.assertIn(['dnf5','offline','clean'], self.calls)

    def test_normal_reboot_preserves_safe_cancellation_of_owned_download(self):
        record = self.ready()
        with patch.object(M, 'boot_id', return_value='another-normal-boot'), patch.object(M, 'fedora_release', return_value='44'), patch.object(M, 'run', side_effect=self.command), patch.object(M, 'transaction', side_effect=self.transaction):
            result = M.cancel()
        self.assertEqual(result['state'], 'cancelled')
        self.assertIn(['dnf5', 'offline', 'clean'], self.calls)
        self.assertFalse((M.PAYLOADS/record['id']).exists())

    def test_failed_download_can_be_cleaned_after_boot_already_aborted_checkpoint(self):
        record = self.ready()
        record['state'] = 'download-failed'
        M.write(record)
        with patch.object(M, 'boot_id', return_value='another-normal-boot'), patch.object(M, 'fedora_release', return_value='44'), patch.object(M, 'run', side_effect=self.command), patch.object(M, 'transaction', return_value={'state':'aborted'}) as transaction:
            result = M.cancel()
        self.assertEqual(result['state'], 'cancelled')
        transaction.assert_called_once_with('status', record['id'])
        self.assertIn(['dnf5', 'offline', 'clean'], self.calls)
        self.assertFalse((M.PAYLOADS/record['id']).exists())

    def test_offline_reboot_rebases_boot_boundary_and_still_checks_ownership(self):
        record = self.ready()
        with patch.object(M, 'boot_id', return_value='another-normal-boot'), patch.object(M, 'fedora_release', return_value='45'):
            with self.assertRaisesRegex(M.Failure, 'release changed'):
                M.reboot()
        with patch.object(M, 'boot_id', return_value='another-normal-boot'), patch.object(M, 'fedora_release', return_value='44'), patch.object(M, 'run', side_effect=self.command):
            M.TRIGGER.symlink_to('/missing/offline/trigger')
            with self.assertRaisesRegex(M.Failure, 'already scheduled'):
                M.reboot()
            M.TRIGGER.unlink()
            result = M.reboot()
            self.assertEqual(result['bootId'], 'another-normal-boot')
            self.assertTrue(result['rebootRequested'])
            with patch.object(M, 'transaction', return_value={'state':'awaiting-upgrade'}), patch.object(M, 'converge') as converge:
                M.finalize(record['id'])
                converge.assert_not_called()
        self.assertIn(['dnf5', 'offline', 'reboot'], self.calls)

    def test_rpm_reconciliation_requires_current_ready_accounts(self):
        rpm = self.root/'target.rpm'
        rpm.write_bytes(b'fixture')
        record = {**self.baseline(), 'candidate':{'kind':'rpm', 'path':str(rpm), 'digest':M.digest(rpm)}}
        ready = {'state':'ready', 'pending':False, 'version':'new', 'desiredVersion':'new',
                 'accounts':{self.account.pw_name:{'state':'ready', 'version':'new', 'uid':self.account.pw_uid}}}
        cases = [ready, {**ready, 'pending':True}, {**ready, 'state':'pending'},
                 {**ready, 'version':'old'}, {**ready, 'accounts':{}},
                 {**ready, 'accounts':{'other':{'state':'ready', 'version':'new', 'uid':-1}}},
                 {**ready, 'accounts':{self.account.pw_name:{'state':'pending', 'version':'new', 'uid':self.account.pw_uid}}},
                 {**ready, 'accounts':{self.account.pw_name:{'state':'ready', 'version':'old', 'uid':self.account.pw_uid}}}]
        for value in cases:
            with self.subTest(status=value), patch.object(M, 'inspect_target'), patch.object(M, 'run', side_effect=lambda args, **kw: json.dumps(value) if '--status' in args else ''):
                if value == ready:
                    M.converge(record)
                else:
                    with self.assertRaisesRegex(M.Failure, 'reconciliation'):
                        M.converge(record)

    def test_preexisting_offline_data_is_never_claimed_by_failed_worker(self):
        record = self.prepared()
        M.OFFLINE.mkdir()
        (M.OFFLINE/'other.json').write_text('other transaction')
        with patch.object(M, 'run', side_effect=self.command), patch.object(M, 'transaction', side_effect=self.transaction):
            with self.assertRaises(M.Failure):
                M.download(record['id'])
        self.assertEqual(M.status()['state'], 'failed')
        self.assertEqual(self.transitions[-1][0], 'abort')
        self.assertTrue((M.OFFLINE/'other.json').exists())
        self.assertFalse(any(x[:3]==['dnf5','offline','clean'] for x in self.calls))

    def test_offline_failure_rolls_back_before_any_convergence(self):
        record = self.ready()
        record.update(rebootRequested=True, bootId='previous-boot')
        M.write(record)
        def transition(action, identifier, *args):
            return {'state':'awaiting-upgrade'} if action=='status' else self.transaction(action,identifier,*args)
        with patch.object(M, 'transaction', side_effect=transition), patch.object(M, 'fedora_release', return_value='44'), patch.object(M, 'converge') as converge:
            result, code = M.finalize(record['id'])
        self.assertEqual(code,75)
        self.assertEqual(result['state'],'rolled-back')
        converge.assert_not_called()
        self.assertEqual(self.transitions[-1][0], 'rollback')

    def test_root_validation_waits_for_real_desktop_before_commit(self):
        record = self.ready()
        record.update(rebootRequested=True, bootId='previous-boot')
        M.write(record)
        def transition(action, identifier, *args):
            return {'state':'awaiting-upgrade'} if action=='status' else self.transaction(action,identifier,*args)
        with patch.object(M, 'transaction', side_effect=transition), patch.object(M, 'fedora_release', return_value='45'), patch.object(M.platform, 'release', return_value='7.0.0-1.fc45.x86_64'), patch.object(M, 'converge'):
            result, code = M.finalize(record['id'])
        self.assertEqual(code,0)
        self.assertEqual(result['state'],'awaiting-desktop')
        self.assertEqual([x[0] for x in self.transitions[-2:]],['applying','await-desktop'])
        self.assertNotIn('commit',[x[0] for x in self.transitions])

    def test_desktop_validation_commits_or_selects_rollback_after_session_starts(self):
        record = self.ready()
        record['state'] = 'awaiting-desktop'
        M.write(record)
        original_exists = Path.exists
        def bus_exists(path):
            return str(path) == f'/run/user/{self.account.pw_uid}/bus' or original_exists(path)
        for healthy in (True, False):
            M.write(record)
            self.transitions.clear()
            def transition(action, identifier, *args):
                if action == 'status':
                    return {'state':'awaiting-desktop'}
                if action == 'commit' and not healthy:
                    raise M.Failure('Desktop failed its health check')
                return self.transaction(action,identifier,*args)
            with self.subTest(healthy=healthy), patch.object(Path, 'exists', bus_exists), patch.object(M, 'transaction', side_effect=transition), patch.object(M, 'run', side_effect=self.command):
                result, code = M.finalize(record['id'])
            self.assertEqual(code, 0 if healthy else 75)
            self.assertEqual(result['state'], 'committed' if healthy else 'rolled-back')
            self.assertEqual(self.transitions[-1][0], 'commit' if healthy else 'rollback')
            self.assertTrue((M.PAYLOADS/record['id']).exists())
            if not healthy:
                self.assertTrue(result['restartRequired'])

    def test_validation_timer_skips_busy_lock_without_failing_unit(self):
        record = self.ready()
        record['state'] = 'awaiting-desktop'
        M.write(record)
        with patch.object(M.os, 'geteuid', return_value=0), patch.object(M.os, 'umask'), patch.object(M.signal, 'signal'), patch.object(M, 'operation_lock', side_effect=M.Busy('busy')):
            self.assertEqual(M.main(['finalize-current']), 0)

    def test_post_commit_failures_retry_bookkeeping_without_rollback(self):
        for fault in ('status-write', 'payload-delete', 'command-output'):
            if M.OFFLINE.exists():
                M.shutil.rmtree(M.OFFLINE)
            record = self.ready()
            record['state'] = 'awaiting-desktop'
            record['candidate']['kind'] = 'rpm'
            M.write(record)
            durable = {'state':'awaiting-desktop', 'injected':False}
            original_write, original_delete, original_exists = M.write, M.shutil.rmtree, Path.exists
            def transition(action, identifier, *args):
                if action == 'rollback':
                    self.fail('A durable commit must never be rolled back after bookkeeping failure')
                if action == 'commit':
                    durable['state'] = 'committed'
                    if fault == 'command-output':
                        raise M.Failure('Lost command output after commit')
                return {'state':durable['state']}
            def write(value):
                if fault == 'status-write' and value['state'] == 'committed' and not durable['injected']:
                    durable['injected'] = True
                    raise OSError('Simulated status sync failure')
                return original_write(value)
            def delete(path, *args, **kwargs):
                if fault == 'payload-delete' and path == M.PAYLOADS/record['id'] and not durable['injected']:
                    durable['injected'] = True
                    raise OSError('Simulated payload cleanup failure')
                return original_delete(path, *args, **kwargs)
            def exists(path):
                return str(path) == f'/run/user/{self.account.pw_uid}/bus' or original_exists(path)
            with self.subTest(fault=fault), patch.object(M, 'transaction', side_effect=transition), patch.object(M, 'run', side_effect=self.command), patch.object(Path, 'exists', exists), patch.object(M, 'write', side_effect=write), patch.object(M.shutil, 'rmtree', side_effect=delete):
                if fault != 'command-output':
                    with self.assertRaises(OSError):
                        M.finalize(record['id'])
                    self.assertEqual(durable['state'], 'committed')
                    if fault == 'payload-delete':
                        self.assertTrue(M.status()['cleanupPending'])
                result, code = M.finalize(record['id'])
            self.assertEqual(code, 0)
            self.assertEqual(result['state'], 'committed')
            self.assertNotIn('cleanupPending', M.status())
            self.assertFalse((M.PAYLOADS/record['id']).exists())

    def test_backup_verification_checks_bytes_and_required_archive_contents(self):
        archive = self.root/'backup.tar'
        scopes = ['/home/fixture','/etc','/var/lib/xps-hardware','/etc/pki/akmods']
        content = self.root/'backup-content'
        for scope in scopes:
            directory = content/scope.lstrip('/')
            directory.mkdir(parents=True, exist_ok=True)
            (directory/'kept').write_text('data')
        with tarfile.open(archive,'w') as stream:
            for child in content.iterdir():
                stream.add(child, arcname=child.name)
        manifest = self.root/'backup.json'
        receipt = {'v':1,'createdAt':datetime.now(timezone.utc).isoformat(),
                   'archives':[{'path':archive.name,'sha256':M.digest(archive),'covers':scopes}]}
        manifest.write_text(json.dumps(receipt))
        actual_run=M.run
        def command(values, **kwargs):
            if values[0]=='findmnt':
                return 'root-device' if values[-1]=='/' else 'backup-device'
            return actual_run(values,**kwargs)
        with patch.object(M,'run',side_effect=command):
            checked=M.verify_backup(manifest,SimpleNamespace(pw_dir='/home/fixture'))
            self.assertEqual(checked['sha256'],M.digest(manifest))
            archive.write_bytes(b'corrupted')
            with self.assertRaisesRegex(M.Failure,'checksum'):
                M.verify_backup(manifest,SimpleNamespace(pw_dir='/home/fixture'))

    def test_timeout_stops_descendants_before_returning(self):
        pidfile=self.root/'child.pid'
        command=['/bin/sh','-c', 'sh -c \'trap "" TERM; exec sleep 60\' >/dev/null 2>&1 & echo $! > "$1"; wait', 'test', str(pidfile)]
        with self.assertRaises(subprocess.TimeoutExpired):
            M.run(command,timeout=0.1)
        child=int(pidfile.read_text())
        for _ in range(30):
            try:
                fields=Path(f'/proc/{child}/stat').read_text().split()
                if fields[2]=='Z':
                    break
            except FileNotFoundError:
                break
            time.sleep(0.01)
        else:
            self.fail('A command descendant survived timeout cleanup')


if __name__ == '__main__':
    unittest.main()
