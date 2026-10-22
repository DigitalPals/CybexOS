#!/usr/bin/env python3
"""Original CybexOS landscapes, drawn from geometry; no external artwork.

Only Python's standard library is needed. Recreate native and responsive web
PNGs and their provenance with `python3 -B scripts/generate-wallpapers.py`.
Pixel generation is deterministic. PNG compression can differ across zlib
implementations; --check validates pixels and the recorded on-disk digests.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import struct
import zlib

ROOT = Path(__file__).resolve().parents[1]
# RGB sky endpoints, mountain silhouettes and moon position (thousandths).
PALETTES = {
    "moon-mountains": ((14, 22, 38), (48, 65, 85), (154, 177, 192), 730, 235),
    "quiet-fjord": ((15, 29, 38), (48, 75, 83), (137, 167, 169), 290, 260),
    "dusk-ridges": ((31, 24, 41), (83, 60, 76), (190, 159, 164), 740, 280),
    "winter-silence": ((20, 30, 45), (67, 86, 106), (179, 197, 203), 390, 220),
    "copper-horizon": ((36, 26, 30), (94, 64, 55), (209, 171, 132), 700, 295),
    "forest-distance": ((17, 32, 31), (47, 76, 66), (155, 178, 148), 340, 250),
    "blue-hour": ((16, 23, 42), (47, 60, 95), (155, 174, 206), 660, 210),
}
RIDGES = (
    ((0, 690), (145, 480), (235, 575), (365, 360), (525, 585), (680, 450), (850, 625), (1000, 500)),
    ((0, 735), (170, 620), (310, 740), (490, 550), (655, 735), (820, 590), (1000, 750)),
    ((0, 850), (200, 780), (420, 870), (610, 730), (820, 850), (1000, 790)),
)


def chunk(kind, data):
    return struct.pack('!I', len(data)) + kind + data + struct.pack('!I', zlib.crc32(kind + data))


def render(name, width):
    height = width * 9 // 16
    top, bottom, moon, mx, my = PALETTES[name]
    layers = []
    for index, ridge in enumerate(RIDGES):
        points = [(x * width // 1000, y * height // 1000) for x, y in ridge]
        colour = tuple(max(0, c * (55 - index * 16) // 100) for c in bottom)
        layers.append((points, bytes(colour)))
    compressor = zlib.compressobj(9)
    compressed = bytearray()
    for y in range(height):
        sky = bytes(a + (b - a) * y // height for a, b in zip(top, bottom))
        row = bytearray(sky * width)
        cx, cy, radius = mx * width // 1000, my * height // 1000, 35 * height // 1000
        if abs(y - cy) <= radius:
            half = math.isqrt(radius * radius - (y - cy) ** 2)
            row[3 * (cx - half):3 * (cx + half + 1)] = bytes(moon) * (2 * half + 1)
        for points, colour in layers:
            for (x1, y1), (x2, y2) in zip(points, points[1:]):
                for x in range(x1, min(width, x2)):
                    edge = y1 + (y2 - y1) * (x - x1) // (x2 - x1)
                    if y >= edge:
                        row[x * 3:x * 3 + 3] = colour
        compressed.extend(compressor.compress(b'\0' + row))
    compressed.extend(compressor.flush())
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('!IIBBBBB', width, height, 8, 2, 0, 0, 0))
            + chunk(b'IDAT', bytes(compressed)) + chunk(b'IEND', b''))


def pixels(data):
    """Compare rendered RGB scanlines independently of the zlib encoder."""
    if not data.startswith(b'\x89PNG\r\n\x1a\n'):
        raise ValueError('Expected a generated PNG')
    position, compressed, header = 8, bytearray(), None
    while position < len(data):
        length = struct.unpack('!I', data[position:position + 4])[0]
        kind = data[position + 4:position + 8]
        payload = data[position + 8:position + 8 + length]
        if kind == b'IHDR':
            header = payload
        elif kind == b'IDAT':
            compressed.extend(payload)
        position += length + 12
    return header, zlib.decompress(compressed)


def generate(root=ROOT, check=False):
    generator = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    outputs = [(f'assets/wallpapers/{name}.png', name, 2560) for name in PALETTES]
    outputs += [(f'web/public/wallpapers/moon-mountains-{width}.png', 'moon-mountains', width)
                for width in (1280, 2560, 5120)]
    records = []
    for relative, name, width in outputs:
        data = render(name, width)
        path = root / relative
        if check:
            existing = path.read_bytes()
            if pixels(existing) != pixels(data):
                raise ValueError(f'Generated wallpaper pixels differ: {relative}')
            data = existing
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        records.append({'path': relative, 'sha256': hashlib.sha256(data).hexdigest(),
                        'bytes': len(data), 'mediaType': 'image/png',
                        'dimensions': [width, width * 9 // 16], 'rightsStatus': 'documented',
                        'creator': 'CybexOS contributors (procedural artwork authored for this change)',
                        'sourceUrl': 'scripts/generate-wallpapers.py', 'license': 'MIT',
                        'creation': {'method': 'Original geometric landscape; no input images',
                                     'generatorSha256': generator, 'palette': name, 'width': width}})
    document = {'schemaVersion': 2, 'scope': 'All bundled native and web wallpapers, regardless of size',
                'rightsPolicy': {'status': 'documented-original-artwork',
                                 'meaning': 'New original procedural art under the repository MIT license; no third-party rights inferred.'},
                'assets': records}
    path = root / 'assets/PROVENANCE.json'
    if check:
        if json.loads(path.read_text()) != document:
            raise ValueError('Wallpaper provenance differs from generator')
    else:
        path.write_text(json.dumps(document, indent=2) + '\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    generate(check=parser.parse_args().check)
