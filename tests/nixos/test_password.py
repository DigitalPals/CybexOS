"""Password boundary and rollback fixtures; real LUKS/account checks run in VMs."""
import ctypes.util
import json
import os
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'lifecycle'))
from cybexos.common import Failure
from cybexos.credentials import validate_password
from cybexos import password


class PasswordTests(unittest.TestCase):
    def test_eight_characters_and_no_normalization(self):
        for value in ('Cybexos8!', 'abcdefgh', '        ', 'é' * 8):
            self.assertEqual(validate_password(value), value)
        for value in ('short', '1234567', '12345678\n', '12345678\x00', None):
            with self.subTest(value=value), self.assertRaises(Failure):
                validate_password(value)

    def setUp(self):
        self.env = patch.dict(os.environ, {'CYBEXOS_LIBCRYPT': os.environ.get('CYBEXOS_LIBCRYPT') or ctypes.util.find_library('crypt')})
        self.env.start(); self.addCleanup(self.env.stop)
        account = patch.object(password.pwd, 'getpwnam', return_value=SimpleNamespace(pw_uid=1000))
        account.start(); self.addCleanup(account.stop)
        self.current = 'old-password'
        self.shadow = password.crypt_hash(self.current, '$6$qualification$')
        self.calls = []
        self.slots = {'0': {}}
        self.fail_account = False
        self.partial_account = False
        def command(*args, **kwargs):
            self.calls.append((args, kwargs))
            if args[:2] == ('getent', 'shadow'):
                return ('tester:' + self.shadow + ':1:0:99999:7:::\n').encode()
            if args[:2] == ('cryptsetup', 'luksDump'):
                return json.dumps({'keyslots': self.slots}).encode()
            if args[0] == 'runuser' and self.fail_account:
                if self.partial_account:
                    self.shadow = password.crypt_hash('new-pass', '$6$qualification-new$')
                raise Failure('fixture account failure')
            return b''
        self.commands = patch.object(password, 'command', side_effect=command)
        self.commands.start(); self.addCleanup(self.commands.stop)
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        transaction = patch.object(password, 'TRANSACTION', Path(self.temporary.name) / 'change.json')
        transaction.start(); self.addCleanup(transaction.stop)
        for fixture in (patch.object(password, 'root_luks', return_value='/dev/fixture'),
                        patch.object(password, 'matching_slot', return_value='0')):
            fixture.start(); self.addCleanup(fixture.stop)
        self.changes = []
        def add(device, slot, old, new):
            self.changes.append(('add', device, slot, old, new))
            self.slots[slot] = {}
        def remove(device, slot, key):
            self.changes.append(('remove', device, slot, key))
            del self.slots[slot]
        for fixture in (patch.object(password, 'add_disk_key', side_effect=add),
                        patch.object(password, 'remove_disk_key', side_effect=remove)):
            fixture.start(); self.addCleanup(fixture.stop)
        self.metadata = {'username': 'tester', 'sharedPassword': True, 'encrypted': True}

    def test_wrong_account_or_password_never_changes_disk(self):
        for user, old in (('other', self.current), ('tester', 'wrong-password')):
            with self.assertRaises(Failure):
                password.change(user, old, 'new-pass', metadata=self.metadata)
        self.assertEqual(self.changes, [])
        self.assertFalse(any(args[0] == 'runuser' for args, _ in self.calls))

    def test_changes_one_disk_slot_and_uses_private_pam_input(self):
        result = password.change('tester', self.current, 'new-pass', metadata=self.metadata)
        self.assertTrue(result['success'])
        self.assertEqual(self.changes, [('add', '/dev/fixture', '1', self.current, 'new-pass'),
                                       ('remove', '/dev/fixture', '0', 'new-pass')])
        self.assertEqual(set(self.slots), {'1'})
        self.assertFalse(password.TRANSACTION.exists())
        account = next((args, kwargs) for args, kwargs in self.calls if args[0] == 'runuser')
        self.assertNotIn(self.current, account[0])
        self.assertIn('XDG_RUNTIME_DIR=/run/user/1000', account[0])
        self.assertIn('GNOME_KEYRING_CONTROL=/run/user/1000/keyring', account[0])
        self.assertEqual(account[1]['input'], b'old-password\nnew-pass\nnew-pass\n')

    def test_account_failure_restores_disk_password(self):
        self.fail_account = True
        with self.assertRaisesRegex(Failure, 'previous password was retained'):
            password.change('tester', self.current, 'new-pass', metadata=self.metadata)
        self.assertEqual(self.changes[-1], ('remove', '/dev/fixture', '1', self.current))
        self.assertEqual(set(self.slots), {'0'})

    def test_interrupted_passwd_after_shadow_commit_keeps_the_new_disk_key(self):
        self.fail_account = self.partial_account = True
        with self.assertRaisesRegex(Failure, 'new password was set for login and disk unlock'):
            password.change('tester', self.current, 'new-pass', metadata=self.metadata)
        self.assertEqual(set(self.slots), {'1'})
        self.assertFalse(password.TRANSACTION.exists())

    def test_interrupted_change_before_pam_keeps_old_key_and_can_be_retried(self):
        self.slots['1'] = {}
        password.atomic(password.TRANSACTION, {'username': 'tester', 'device': '/dev/fixture', 'oldSlot': '0', 'newSlot': '1'})
        password.change('tester', self.current, self.current, metadata=self.metadata)
        self.assertEqual(set(self.slots), {'0'})
        self.assertFalse(password.TRANSACTION.exists())

    def test_interrupted_change_after_pam_removes_the_old_disk_key(self):
        self.slots['1'] = {}
        password.atomic(password.TRANSACTION, {'username': 'tester', 'device': '/dev/fixture', 'oldSlot': '0', 'newSlot': '1'})
        with patch.object(password, 'matching_slot', return_value='1'):
            password.change('tester', self.current, self.current, metadata=self.metadata)
        self.assertEqual(set(self.slots), {'1'})
        self.assertFalse(password.TRANSACTION.exists())

    def test_unencrypted_account_does_not_touch_a_disk(self):
        self.metadata['encrypted'] = False
        self.assertTrue(password.change('tester', self.current, 'new-pass', metadata=self.metadata)['success'])
        self.assertEqual(self.changes, [])


if __name__ == '__main__':
    unittest.main()
