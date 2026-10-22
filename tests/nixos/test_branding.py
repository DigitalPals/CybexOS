"""Verify delivered art integrity, boot-image geometry and readable brand colours."""
import hashlib
import json
from pathlib import Path
import struct
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]


class BrandAssets(unittest.TestCase):
    def test_supplied_masters_and_every_deployment_copy_are_unmodified(self):
        manifest = json.loads((ROOT / 'assets/brand/kit-sha256.json').read_text())
        self.assertEqual(manifest['schema'], 1)
        for name, record in manifest['files'].items():
            with self.subTest(asset=name, source=record['source']):
                self.assertEqual(hashlib.sha256((ROOT / name).read_bytes()).hexdigest(), record['sha256'])

    def test_plymouth_and_hinted_icon_dimensions(self):
        paths = {'desktop/plymouth/logo.png': (360, 48), 'desktop/plymouth/logo@2x.png': (720, 96),
                 'desktop/boot/splash.png': (640, 480)}
        paths.update({f'desktop/icons/hicolor/{size}x{size}/apps/nerdos.png': (size, size)
                      for size in (16, 32, 48, 64, 128, 256, 512)})
        for name, dimensions in paths.items():
            with self.subTest(asset=name):
                data = (ROOT / name).read_bytes()
                self.assertEqual(data[:8], b'\x89PNG\r\n\x1a\n')
                self.assertEqual(struct.unpack('!II', data[16:24]), dimensions)

    def test_paint_variants_preserve_glasses_geometry(self):
        def geometry(name):
            svg = ET.parse(ROOT / 'desktop/quickshell/assets' / name).getroot()
            return svg.attrib['viewBox'], [path.attrib['d'] for path in svg.findall('{http://www.w3.org/2000/svg}path')]
        self.assertEqual(geometry('nerdos.svg'), geometry('nerdos-white.svg'))

    def test_lime_buttons_have_accessible_charcoal_contrast(self):
        def luminance(rgb):
            channels = [c / 255 for c in rgb]
            channels = [c / 12.92 if c <= .04045 else ((c + .055) / 1.055) ** 2.4 for c in channels]
            return sum(c * w for c, w in zip(channels, (.2126, .7152, .0722)))
        ink = luminance((26, 27, 30))
        for background in ((200, 255, 31), (215, 255, 87), (166, 217, 0)):
            self.assertGreater((luminance(background) + .05) / (ink + .05), 7)


if __name__ == '__main__':
    unittest.main()
