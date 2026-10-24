import importlib.machinery
import importlib.util
from pathlib import Path
import unittest


loader = importlib.machinery.SourceFileLoader('image_parity', str(Path(__file__).resolve().parents[2] / 'scripts/check-image-parity'))
spec = importlib.util.spec_from_loader(loader.name, loader)
parity = importlib.util.module_from_spec(spec)
loader.exec_module(parity)


class BootMenuIdentityTests(unittest.TestCase):
    profiles = [
        {'kernel': '/boot/kernel-a', 'initrd': '/boot/initrd-a', 'system': '/nix/store/system-a'},
        {'kernel': '/boot/kernel-b', 'initrd': '/boot/initrd-b', 'system': '/nix/store/system-b'},
    ]

    @staticmethod
    def grub(profile):
        return f"menuentry 'live' {{\nlinux {profile['kernel']} init={profile['system']}/init\ninitrd {profile['initrd']}\n}}\n"

    def test_distinct_complete_graphics_profiles(self):
        parity.check_boot_menu(''.join(map(self.grub, self.profiles)), self.profiles, 'grub')

    def test_bios_append_can_precede_or_follow_initrd(self):
        for commands in ('APPEND init={system}/init\nINITRD {initrd}', 'INITRD {initrd}\nAPPEND init={system}/init'):
            menu = ''.join(('LABEL live\nLINUX {kernel}\n' + commands + '\n').format(**p) for p in self.profiles)
            parity.check_boot_menu(menu, self.profiles, 'isolinux')

    def test_rejects_mixed_profile_paths(self):
        menu = ''.join(map(self.grub, self.profiles)).replace('initrd /boot/initrd-a', 'initrd /boot/initrd-b')
        with self.assertRaises(parity.ParityFailure):
            parity.check_boot_menu(menu, self.profiles, 'grub')

    def test_rejects_a_second_initrd_after_valid_tuple(self):
        menu = self.grub(self.profiles[0]).replace('\n}', '\ninitrd /boot/unexpected\n}')
        with self.assertRaises(parity.ParityFailure):
            parity.check_boot_menu(menu, self.profiles[:1], 'grub')

    def test_rejects_fields_split_across_entries(self):
        menu = "menuentry 'one' {\nlinux /boot/kernel-a init=/nix/store/system-a/init\n}\nmenuentry 'two' {\ninitrd /boot/initrd-a\n}\n"
        with self.assertRaises(parity.ParityFailure):
            parity.check_boot_menu(menu, self.profiles[:1], 'grub')

    def test_rejects_duplicate_init_parameter(self):
        menu = self.grub(self.profiles[0]).replace('/system-a/init', '/system-a/init init=/nix/store/other/init')
        with self.assertRaises(parity.ParityFailure):
            parity.check_boot_menu(menu, self.profiles[:1], 'grub')

    def test_requires_all_profiles(self):
        with self.assertRaises(parity.ParityFailure):
            parity.check_boot_menu(self.grub(self.profiles[0]), self.profiles, 'grub')


if __name__ == '__main__':
    unittest.main()
