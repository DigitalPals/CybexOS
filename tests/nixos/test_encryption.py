"""Exercise storage ancestry, including layouts that must refuse autologin."""
import importlib.machinery
import importlib.util
import json
from pathlib import Path
import stat
import unittest
from unittest.mock import patch


loader = importlib.machinery.SourceFileLoader('encryption_guard', str(
    Path(__file__).resolve().parents[2] / 'lifecycle/bin/cybexos-verify-encryption'))
spec = importlib.util.spec_from_loader(loader.name, loader)
guard = importlib.util.module_from_spec(spec)
loader.exec_module(guard)


class EncryptionTests(unittest.TestCase):
    def ancestry(self, nodes):
        return patch.object(guard, 'output', return_value=json.dumps({'blockdevices': nodes}))

    def test_crypt_and_lvm_above_crypt(self):
        for tree in ([{'type': 'crypt'}], [{'type': 'lvm', 'children': [{'type': 'crypt'}]}]):
            with self.ancestry(tree):
                self.assertTrue(guard.encrypted_device('/dev/mapper/root'))

    def test_plaintext_or_one_plain_raid_branch_refused(self):
        for tree in ([], [{'type': 'part', 'children': [{'type': 'disk'}]}],
                     [{'type': 'raid1', 'children': [{'type': 'crypt'}, {'type': 'part'}]}]):
            with self.ancestry(tree):
                self.assertFalse(guard.encrypted_device('/dev/md0'))

    def test_every_btrfs_member_must_be_encrypted(self):
        mount = json.dumps({'filesystems': [{'fstype': 'btrfs', 'source': '/dev/mapper/a[/home]'}]})
        members = 'devid 1 size 100 used 20 path /dev/mapper/a\ndevid 2 size 100 used 20 path /dev/sdb1'
        with patch.object(guard, 'output', side_effect=[mount, members]), \
                patch.object(guard, 'encrypted_device', side_effect=[True, False]) as prove:
            self.assertFalse(guard.encrypted('/home'))
            self.assertEqual(prove.call_count, 2)

    def test_btrfs_missing_members_refused(self):
        mount = json.dumps({'filesystems': [{'fstype': 'btrfs', 'source': '/dev/mapper/a'}]})
        with patch.object(guard, 'output', side_effect=[mount, 'missing devices']):
            self.assertFalse(guard.encrypted('/'))

    def test_extra_persistent_mount_refused_but_esp_exempt(self):
        mounts = {'filesystems': [{'target': '/boot', 'fstype': 'vfat'},
                                  {'target': '/srv/private', 'fstype': 'ext4'}]}
        with patch.object(guard, 'output', return_value=json.dumps(mounts)), \
                patch.object(guard, 'encrypted', side_effect=lambda p: p != '/srv/private') as prove:
            with self.assertRaisesRegex(ValueError, '/srv/private'):
                guard.verify()
            self.assertNotIn(unittest.mock.call('/boot'), prove.call_args_list)

    def test_swap_device_swapfile_and_zram(self):
        mounts = json.dumps({'filesystems': []})
        swaps = 'Filename Type Size Used Priority\n/dev/zram0 partition 1 0 1\n/dev/sda3 partition 1 0 1\n/swapfile file 1 0 1\n'
        with patch.object(guard, 'output', return_value=mounts), \
                patch.object(guard, 'encrypted', return_value=True) as filesystem, \
                patch.object(guard, 'encrypted_device', return_value=True) as device, \
                patch.object(Path, 'read_text', return_value=swaps), \
                patch.object(Path, 'stat', side_effect=[type('S', (), {'st_mode': stat.S_IFBLK})(),
                                                       type('S', (), {'st_mode': stat.S_IFREG})()]):
            guard.verify()
            device.assert_called_once_with('/dev/sda3')
            filesystem.assert_any_call('/swapfile')


if __name__ == '__main__':
    unittest.main()
