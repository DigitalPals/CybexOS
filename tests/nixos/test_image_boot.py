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


class KeyboardShortcutsRuntimeTests(unittest.TestCase):
    @staticmethod
    def bind(modmask, key, description, keycode=0, submap=''):
        return {'modmask': modmask, 'key': key, 'keycode': keycode, 'description': description, 'submap': submap}

    def live(self):
        rows = [{'id': name, 'group': 'G', 'label': name, 'keys': ['SUPER + code:%d' % (100 + index)],
                 'defaultKeys': []} for index, name in enumerate(qualification.REQUIRED_ACTIONS)]
        rows.append({'id': 'windows.move-window', 'group': 'Windows', 'label': 'Move window',
                     'keys': ['SUPER + mouse:272'], 'defaultKeys': []})
        rows[0]['keys'] = ['SUPER + SPACE']
        binds = [self.bind(64, '', 'G: ' + row['label'], 100 + index) for index, row in enumerate(rows[:-1])]
        binds[0] = self.bind(64, 'space', 'G: ' + rows[0]['label'])
        return {'v': 1, 'error': None, 'actions': rows, 'custom': [], 'diagnostics': []}, binds

    def test_bound_matches_modifiers_keys_case_insensitively_and_keycodes(self):
        binds = [self.bind(72, 'b', 'Apps: Browser'), self.bind(65, '', 'Workspaces: Move', 10)]
        self.assertTrue(qualification.bound(binds, 'Apps: Browser', 'SUPER + ALT + B'))
        self.assertTrue(qualification.bound(binds, 'Workspaces: Move', 'SUPER + SHIFT + code:10'))
        self.assertFalse(qualification.bound(binds, 'Apps: Browser', 'SUPER + B'))
        self.assertFalse(qualification.bound(binds, 'Apps: Files', 'SUPER + ALT + B'))
        self.assertFalse(qualification.bound([self.bind(72, 'B', 'Apps: Browser', submap='resize')],
                                             'Apps: Browser', 'SUPER + ALT + B'))

    def test_complete_live_state_passes_and_skips_mouse_keys(self):
        state, binds = self.live()
        rows = qualification.check_shortcut_state(state, binds)
        self.assertIn('workspaces.move.10', rows)

    def test_state_error_missing_action_or_unbound_key_fails(self):
        state, binds = self.live()
        for change in (lambda s, b: s.update(error='bad file'),
                       lambda s, b: s['actions'].pop(3),
                       lambda s, b: s['actions'][3].update(keys=[]),
                       lambda s, b: b.pop(3),
                       lambda s, b: s['custom'].append({'id': 'custom.x', 'group': 'Web', 'label': 'X',
                                                         'keys': ['SUPER + ALT + D']})):
            state, binds = self.live()
            change(state, binds)
            with self.subTest(change=change), self.assertRaises(AssertionError):
                qualification.check_shortcut_state(state, binds)

    def test_only_onboarding_qml_errors_fail_the_journal(self):
        lines = ['file:///nix/store/x/Welcome/HelloStep.qml:9: TypeError: Cannot read property',
                 'file:///nix/store/x/Settings/ShortcutRow.qml:4: Binding loop detected for property "width"',
                 'file:///nix/store/x/Bar/Clock.qml:3: ReferenceError: foo is not defined',
                 'qt.qpa.wayland: harmless warning']
        onboarding, other = qualification.onboarding_qml_errors(lines)
        self.assertEqual(onboarding, lines[:2])
        self.assertEqual(other, lines[2:3])

    def test_guest_script_compiles_with_its_checks(self):
        source = qualification.shortcuts_script()
        compile(source, 'qa-script.py', 'exec')
        self.assertIn('def check_shortcut_state', source)
        self.assertIn("SHORTCUT_REMAP = 'SUPER + ALT + B'", source)


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
