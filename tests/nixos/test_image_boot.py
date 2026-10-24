import importlib.machinery
import importlib.util
from pathlib import Path
import unittest


loader = importlib.machinery.SourceFileLoader('image_parity', str(Path(__file__).resolve().parents[2] / 'scripts/check-image-parity'))
spec = importlib.util.spec_from_loader(loader.name, loader)
parity = importlib.util.module_from_spec(spec)
loader.exec_module(parity)

loader = importlib.machinery.SourceFileLoader('installation_qualification', str(Path(__file__).resolve().parents[2] / 'scripts/qualify-installations'))
spec = importlib.util.spec_from_loader(loader.name, loader)
qualification = importlib.util.module_from_spec(spec)
loader.exec_module(qualification)


class InstalledSourceIdentityTests(unittest.TestCase):
    media = {'version': '1.0.0-beta.2', 'revision': 'a' * 40, 'narHash': 'sha256-' + 'A' * 43 + '='}
    path_source = {'type': 'path', 'path': '/nix/store/bundled-source', 'narHash': media['narHash']}
    installed = dict(media, revision='uncommitted')

    def test_committed_medium_keeps_exact_content_identity_through_a_bundled_path(self):
        evidence = qualification.check_installed_identity(self.media, self.installed, self.path_source)
        self.assertEqual(evidence['result'], 'passed')
        self.assertEqual(evidence['isoRelease']['revision'], 'a' * 40)
        self.assertEqual(evidence['installedRelease']['revision'], 'uncommitted')
        self.assertEqual(evidence['installedSource']['narHash'], self.media['narHash'])

    def test_uncommitted_medium_keeps_exact_content_identity(self):
        qualification.check_installed_identity(self.installed, self.installed, self.path_source)

    def test_git_input_requires_both_the_revision_and_content_identity(self):
        source = {'type': 'git', 'rev': self.media['revision'], 'narHash': self.media['narHash']}
        qualification.check_installed_identity(self.media, self.media, source)
        for installed, locked in ((self.installed, source), (self.media, dict(source, rev='b' * 40))):
            with self.subTest(installed=installed, locked=locked), self.assertRaises(RuntimeError):
                qualification.check_installed_identity(self.media, installed, locked)

    def test_rejects_different_installed_bytes_or_version(self):
        for change in ({'narHash': 'sha256-' + 'B' * 43 + '='}, {'version': '1.0.0'}):
            with self.subTest(change=change), self.assertRaises(RuntimeError):
                qualification.check_installed_identity(self.media, dict(self.installed, **change), self.path_source)

    def test_matching_release_labels_cannot_hide_a_different_locked_source(self):
        with self.assertRaises(RuntimeError):
            qualification.check_installed_identity(self.media, self.installed,
                                                   dict(self.path_source, narHash='sha256-' + 'B' * 43 + '='))

    def test_rejects_missing_identities_and_unexpected_path_revision(self):
        with self.assertRaises(RuntimeError):
            qualification.check_installed_identity({}, {}, {'type': 'path'})
        with self.assertRaises(RuntimeError):
            qualification.check_installed_identity(self.media, dict(self.installed, revision='b' * 40), self.path_source)


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
