"""Bundled imports preserve user files; metering is conservative and offline."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


def load(name):
    spec = importlib.util.spec_from_file_location(name.replace('-', '_'),
        ROOT / 'desktop/quickshell/scripts' / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class WallpaperPickerTests(unittest.TestCase):
    def test_collection_layouts(self):
        helper = load('wallpaper-bundled')
        self.assertEqual(helper.collection_dir(ROOT / 'desktop/quickshell'), ROOT / 'assets/wallpapers')
        with tempfile.TemporaryDirectory() as temporary:
            runtime = Path(temporary)
            (runtime / 'wallpapers').mkdir()
            (runtime / 'wallpapers/moon-mountains.png').write_bytes(b'png')
            self.assertEqual(helper.collection_dir(runtime / 'quickshell'), runtime / 'wallpapers')

    def test_import_is_atomic_repeatable_and_preserves_collisions(self):
        helper = load('wallpaper-bundled')
        with tempfile.TemporaryDirectory() as temporary:
            destination = Path(temporary) / 'pictures'
            source = ROOT / 'assets/wallpapers'
            name = helper.import_image(source, 'moon-mountains.png', destination)
            self.assertEqual(name, 'cybexos-moon-mountains.png')
            self.assertEqual(helper.import_image(source, 'moon-mountains.png', destination), name)
            (destination / name).write_bytes(b'personal image')
            second = helper.import_image(source, 'moon-mountains.png', destination)
            self.assertNotEqual(second, name)
            self.assertEqual((destination / name).read_bytes(), b'personal image')
            self.assertEqual((destination / second).read_bytes(), (source / 'moon-mountains.png').read_bytes())
            self.assertFalse(list(destination.glob('.cybexos-import-*')))
            with self.assertRaises(ValueError):
                helper.import_image(source, '../moon-mountains.png', destination)

    def test_metering_includes_guesses_and_unknown_asks_first(self):
        parse = load('network-tool').parse_metered
        for state, expected in [('yes', True), ('yes (guessed)', True), ('no', False),
                                ('no (guessed)', False), ('unknown', True)]:
            result = parse(f'GENERAL.STATE:100 (connected)\nGENERAL.METERED:{state}\n')
            self.assertEqual(result['metered'], expected)
            self.assertEqual(result['known'], state != 'unknown')
        self.assertEqual(parse(''), {'known': False, 'metered': True})
        self.assertEqual(parse('GENERAL.STATE:30 (disconnected)\nGENERAL.METERED:yes\n'
                               'GENERAL.STATE:100 (connected)\nGENERAL.METERED:no\n'),
                         {'known': True, 'metered': False})
        self.assertEqual(parse('GENERAL.TYPE:loopback\nGENERAL.STATE:100 (connected externally)\n'
                               'GENERAL.METERED:unknown\nGENERAL.TYPE:ethernet\n'
                               'GENERAL.STATE:100 (connected)\nGENERAL.METERED:no\n'),
                         {'known': True, 'metered': False})
        self.assertTrue(parse('GENERAL.STATE:100 (connected)\nGENERAL.METERED:no\n'
                              'GENERAL.STATE:100 (connected)\nGENERAL.METERED:yes\n')['metered'])


if __name__ == '__main__':
    unittest.main()
