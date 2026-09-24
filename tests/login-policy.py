#!/usr/bin/env python3
"""Exercise the login boot guard without touching the machine or credentials."""
import configparser
from concurrent.futures import ThreadPoolExecutor
from importlib.machinery import SourceFileLoader
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

REPO = Path(__file__).resolve().parents[1]
login = SourceFileLoader('login_policy', str(REPO / 'roles/desktop/files/login/cybexos-login-prepare')).load_module()


class LoginPolicy(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        account = Mock(pw_uid=os.getuid(), pw_gid=os.getgid())
        self.account = patch.object(login.pwd, 'getpwnam', return_value=account)
        self.account.start()
        self.addCleanup(self.account.stop)
        for name in ('etc/cybexos', 'proc', 'run'):
            (self.root / name).mkdir(parents=True)
        (self.root / 'etc/passwd').write_text('owner:x:1000:1000::/home/owner:/bin/bash\nliveuser:x:1001:1001::/home/liveuser:/bin/bash\nroot:x:0:0::/root:/bin/bash\n')
        self.write_policy()

    def write_policy(self, **values):
        self.values = dict(version=1, user='owner', autologin=True, live=False)
        self.values.update(values)
        self.path = self.root / 'etc/cybexos/login.json'
        self.path.write_text(json.dumps(self.values))
        self.path.chmod(0o644)

    def prepare(self, encrypted=True):
        result = login.prepare(self.root, os.getuid(), lambda: encrypted)
        parsed = configparser.ConfigParser()
        parsed.read(self.root / 'etc/sddm.conf')
        self.assertFalse(parsed.getboolean('Autologin', 'Relogin'))
        self.assertEqual(parsed.get('Autologin', 'User'), result['user'])
        return result

    def test_first_boot_only_and_restart_requires_authentication(self):
        self.assertTrue(self.prepare()['autologin'])
        self.assertEqual(self.prepare()['reason'], 'autologin-already-used')
        self.assertFalse(self.prepare()['autologin'])
        (self.root / 'run/cybexos-login/autologin-used').unlink()
        self.assertTrue(self.prepare()['autologin'])

    def test_unencrypted_or_unknown_root_never_autologins(self):
        result = self.prepare(False)
        self.assertFalse(result['autologin'])
        self.assertFalse((self.root / 'run/cybexos-login/autologin-used').exists())

    def test_password_greeter_defaults_to_cybexos_and_preserves_user_choice(self):
        self.prepare(False)
        state = self.root / 'var/lib/sddm/state.conf'
        self.assertEqual(state.read_text(), '[Last]\nSession=hyprland-quickshell.desktop\n')
        self.assertEqual(state.stat().st_uid, os.getuid())
        self.assertEqual(state.stat().st_mode & 0o777, 0o600)
        state.write_text('[Last]\nSession=another.desktop\nUser=owner\n')
        self.prepare(False)
        self.assertEqual(state.read_text(), '[Last]\nSession=another.desktop\nUser=owner\n')

    def test_session_seed_rejects_symlinked_state_without_reading_target(self):
        self.prepare(False)
        state = self.root / 'var/lib/sddm/state.conf'
        state.unlink()
        secret = self.root / 'untouched'
        secret.write_text('unchanged')
        state.symlink_to(secret)
        with self.assertRaises(ValueError):
            self.prepare()
        self.assertEqual(secret.read_text(), 'unchanged')
        self.assertFalse((self.root / 'run/cybexos-login/autologin-used').exists())

    def test_session_seed_rejects_symlinked_parent(self):
        outside = self.root / 'untouched-directory'
        outside.mkdir()
        (self.root / 'var').symlink_to(outside)
        with self.assertRaises(ValueError):
            self.prepare()
        self.assertEqual(list(outside.iterdir()), [])

    def test_concurrent_preparations_cannot_authorize_two_sessions(self):
        # Exercise the actual file lock/O_EXCL sequence, not a mocked counter.
        with ThreadPoolExecutor(max_workers=4) as pool:
            results = list(pool.map(lambda _: login.prepare(self.root, os.getuid(), lambda: True), range(4)))
        self.assertEqual(sum(result['autologin'] for result in results), 1)
        self.assertFalse(self.prepare()['autologin'])

    def test_disabled_autologin_does_not_consume_boot_attempt(self):
        self.write_policy(autologin=False)
        self.assertFalse(self.prepare()['autologin'])
        self.write_policy()
        self.assertTrue(self.prepare()['autologin'])

    def test_bad_policy_replaces_stale_autologin_with_password_login(self):
        self.prepare()
        self.path.write_text('{broken')
        self.assertEqual(self.prepare()['reason'], 'invalid-or-missing-policy')

    def test_only_regular_installed_owner_with_boolean_flags(self):
        for values in [dict(user='root'), dict(user='absent'), dict(user='owner\n[Autologin]'),
                       dict(autologin='true'), dict(live=1), dict(version=4), dict(version=True)]:
            with self.subTest(values=values):
                self.write_policy(**values)
                self.assertFalse(self.prepare()['autologin'])

    def test_untrusted_policy_permissions_or_symlink_are_rejected(self):
        self.path.chmod(0o666)
        self.assertFalse(self.prepare()['autologin'])
        self.path.unlink()
        target = self.root / 'policy'
        target.write_text(json.dumps(self.values))
        self.path.symlink_to(target)
        self.assertFalse(self.prepare()['autologin'])

    def test_live_policy_requires_root_marker_boot_argument_and_live_owner(self):
        self.write_policy(user='liveuser', live=True)
        (self.root / 'proc/cmdline').write_text('quiet rd.live.image')
        self.assertFalse(self.prepare(False)['autologin'])
        (self.root / 'run/cybexos-live-session').write_text('liveuser\n')
        (self.root / 'proc/cmdline').write_text('quiet')
        self.assertFalse(self.prepare(False)['autologin'])
        (self.root / 'proc/cmdline').write_text('quiet rd.live.image=1')
        self.assertTrue(self.prepare(False)['autologin'])

    def test_symlinked_marker_cannot_be_followed_or_overwritten(self):
        self.write_policy(autologin=False)
        self.prepare()
        target = self.root / 'untouched'
        target.write_text('original')
        (self.root / 'run/cybexos-login/autologin-used').symlink_to(target)
        self.write_policy()
        self.assertFalse(self.prepare()['autologin'])
        self.assertEqual(target.read_text(), 'original')

    def test_runtime_directory_cannot_be_user_writable(self):
        (self.root / 'run/cybexos-login').mkdir(mode=0o777)
        (self.root / 'run/cybexos-login').chmod(0o777)
        with self.assertRaises(ValueError):
            self.prepare()

    def test_failed_config_write_consumes_attempt_before_retry(self):
        original = login.atomic_write
        def fail_final(path, text, mode=0o644):
            if path.name == 'sddm.conf' and 'User=owner\n' in text:
                raise OSError('simulated storage error')
            original(path, text, mode)
        with patch.object(login, 'atomic_write', side_effect=fail_final), self.assertRaises(OSError):
            self.prepare()
        self.assertFalse(self.prepare()['autologin'])


class Encryption(unittest.TestCase):
    def test_all_backing_paths_must_be_encrypted(self):
        crypt = dict(type='crypt', children=[dict(type='part')])
        self.assertTrue(login.encrypted_paths([dict(type='lvm', children=[crypt, crypt])]))
        self.assertFalse(login.encrypted_paths([dict(type='lvm', children=[crypt, dict(type='part')])]))
        self.assertFalse(login.encrypted_paths([]))

    def test_single_device_and_failures(self):
        run = Mock(side_effect=[json.dumps({'filesystems': [{'source': '/dev/mapper/root', 'target': '/', 'fstype': 'ext4'}]}),
                                json.dumps({'blockdevices': [{'type': 'crypt'}]})])
        self.assertTrue(login.encrypted_root(run))
        self.assertIn('--tree', run.call_args.args[0])
        self.assertEqual(run.call_args.args[0][-1], '/dev/mapper/root')
        self.assertFalse(login.encrypted_root(Mock(side_effect=OSError())))
        self.assertFalse(login.encrypted_root(Mock(return_value='null')))

    def test_btrfs_verifies_every_member_including_subvolumes(self):
        mount = json.dumps({'filesystems': [{'source': '/dev/mapper/root[/root]', 'target': '/', 'fstype': 'btrfs'}]})
        report = ("Label: none  uuid: 12345678-1234-1234-1234-123456789abc\n"
                  "\tTotal devices 2 FS bytes used 4096\n"
                  "\tdevid 1 size 1048576 used 4096 path /dev/mapper/root\n"
                  "\tdevid 2 size 1048576 used 4096 path /dev/mapper/second\n")
        for second, expected in [('crypt', True), ('part', False)]:
            run = Mock(side_effect=[mount, report,
                json.dumps({'blockdevices': [{'type': 'crypt'}]}),
                json.dumps({'blockdevices': [{'type': second}]})])
            self.assertEqual(login.encrypted_root(run), expected)
            self.assertEqual(run.call_args.args[0][-1], '/dev/mapper/second')
        for broken in [report.replace('Total devices 2', 'Total devices 3'),
                       report.replace('/dev/mapper/second', 'missing'),
                       report.replace('devid 2', 'devid 1'), report + 'Some devices missing\n', '']:
            with self.subTest(report=broken):
                run = Mock(side_effect=[mount, broken])
                self.assertFalse(login.encrypted_root(run))
                self.assertEqual(run.call_count, 2)


class PamPackaging(unittest.TestCase):
    def test_repeated_updates_preserve_original_and_never_own_sddm_rpm_file(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / 'usr/share/cybexos/login/sddm-autologin'
            target = root / 'etc/pam.d/sddm-autologin'
            source.parent.mkdir(parents=True)
            target.parent.mkdir(parents=True)
            source.write_text('first managed policy')
            target.write_text('original policy')
            original = login.trusted_file
            with patch.object(login, 'trusted_file', side_effect=lambda path: original(path, os.getuid())):
                login.install_pam(root)
                source.write_text('updated policy')
                login.install_pam(root)
            self.assertEqual(target.read_text(), 'updated policy')
            self.assertEqual((root / 'var/lib/cybexos/backups/login-pam/sddm-autologin').read_text(), 'original policy')


if __name__ == '__main__':
    unittest.main()
