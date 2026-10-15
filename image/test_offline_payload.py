"""Independent offline package identity and canonical font admission."""
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from desktop_payload import prepare_font_licenses
import offline_payload as offline


class OfflinePayload(unittest.TestCase):
    def test_reviewed_inputs_fail_closed_and_exclude_desktop_shell_changes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in offline.INPUTS:
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('reviewed input')
            config = root / 'image/offline-payload.json'
            config.write_text(json.dumps({'version': '1.0.0', 'inputs_sha256': offline.input_digest(root)}))
            self.assertEqual(offline.configuration(root)['version'], '1.0.0')
            shell = root / 'roles/desktop/files/quickshell/shell.qml'
            shell.parent.mkdir(parents=True)
            shell.write_text('desktop-only change')
            self.assertEqual(offline.configuration(root)['version'], '1.0.0')
            (root / 'image/applications').write_text('changed application recipe')
            with self.assertRaisesRegex(ValueError, 'inputs changed'):
                offline.configuration(root)

    def test_selected_payload_has_no_overlap_or_builder_cache(self):
        self.assertEqual(len(offline.PREFIXES), len(set(offline.PREFIXES)))
        for name in offline.PREFIXES:
            self.assertFalse(any(name.startswith(other + '/') for other in offline.PREFIXES if other != name))
            self.assertFalse(name.startswith('var/cache'))
        with tempfile.TemporaryDirectory() as directory:
            payload = Path(directory)
            app = payload / 'usr/share/cybexos/user-seed/.rustup/bin/rustc'
            app.parent.mkdir(parents=True)
            app.write_bytes(b'compiler')
            app.with_name('link').symlink_to('rustc')
            metrics = offline.inventory(payload)
            self.assertEqual(metrics['bytes'], 8)
            self.assertEqual(metrics['files'], 1)
            self.assertEqual(offline.file_lists(payload), ['/usr/share/cybexos/user-seed'])

    def test_fonts_verify_prepared_inputs_and_only_copy_license(self):
        with tempfile.TemporaryDirectory() as directory:
            payload = Path(directory)
            base = payload / 'usr/local/share/fonts/demo/1'
            base.mkdir(parents=True)
            (base / 'demo.ttf').write_bytes(b'font bytes')
            (base / 'LICENSE').write_bytes(b'license bytes')
            font = {'name': 'demo', 'version': '1', 'filename': 'demo.ttf', 'license_filename': 'LICENSE',
                    'checksum': 'sha256:' + hashlib.sha256(b'font bytes').hexdigest(),
                    'license_checksum': 'sha256:' + hashlib.sha256(b'license bytes').hexdigest()}
            inventory = {'pinned_font_files': [font]}
            prepare_font_licenses(payload, inventory)
            self.assertEqual(list(payload.rglob('*.ttf')), [base / 'demo.ttf'])
            self.assertEqual((payload / 'usr/share/licenses/cybexos-fonts/demo-LICENSE').read_bytes(), b'license bytes')
            (base / 'demo.ttf').write_bytes(b'corrupt')
            with self.assertRaisesRegex(ValueError, 'corrupt'):
                prepare_font_licenses(payload, inventory)
            (base / 'demo.ttf').unlink()
            (base / 'demo.ttf').symlink_to('LICENSE')
            with self.assertRaisesRegex(ValueError, 'corrupt'):
                prepare_font_licenses(payload, inventory)


if __name__ == '__main__':
    unittest.main()
