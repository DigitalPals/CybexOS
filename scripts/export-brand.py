#!/usr/bin/env python3
"""Export Cybex OS artwork from the supplied outlined SVG.

Requires rsvg-convert and Pillow (available from the locked Nixpkgs).
The source is kept byte-for-byte; deployment variants change paint only.
The compact X uses the two X paths from the same wordmark.
"""
import hashlib
import io
import json
from pathlib import Path
import shutil
import subprocess
import xml.etree.ElementTree as ET

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'assets/brand/source/cybex_white.svg'
LOGO_ACCENT = '#DC1E37'  # Original .cls-1 paint in cybex_white.svg.
UI_ACCENT = '#60A5FA'
INK = '#F3F2EC'
CHARCOAL = '#1A1B1E'
SVG = '{http://www.w3.org/2000/svg}'
PATHS = ET.parse(SOURCE).getroot().findall(SVG + 'path')
RENDERER = shutil.which('rsvg-convert')
if not RENDERER:
    raise SystemExit('rsvg-convert is required; use the locked Nixpkgs librsvg package')
files = {}


def write(name, data):
    path = ROOT / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data.encode() if isinstance(data, str) else data)
    files[name] = {'source': str(SOURCE.relative_to(ROOT)),
                   'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}


def svg(*, symbol=False, ink=INK, accent=LOGO_ACCENT, tile=False):
    paths = PATHS[4:6] if symbol else PATHS
    viewbox = '147 3 44 44' if symbol else '0 0 198 46.6'
    content = ''.join(f'<path fill="{accent if p.attrib["class"] == "cls-1" else ink}" '
                      f'fill-rule="evenodd" d="{p.attrib["d"]}"/>' for p in paths)
    if tile:
        content = (f'<rect width="64" height="64" rx="12" fill="{CHARCOAL}"/>'
                   f'<svg x="6" y="6" width="52" height="52" viewBox="{viewbox}">{content}</svg>')
        viewbox = '0 0 64 64'
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{viewbox}">{content}</svg>\n'


def raster(source, width, height=None):
    args = [RENDERER, '--width', str(width)]
    if height:
        args.extend(['--height', str(height)])
    return subprocess.run(args, input=source.encode(), check=True, capture_output=True).stdout


def png(image):
    output = io.BytesIO()
    image.save(output, format='PNG')
    return output.getvalue()


wordmark = svg()
symbol = svg(symbol=True)
white = svg(symbol=True, ink='#FFFFFF', accent='#FFFFFF')
highlight = svg(symbol=True, ink='#FFFFFF')
tile = svg(symbol=True, tile=True)
write('assets/brand/source/cybex_white.svg', SOURCE.read_bytes())
for name, data in {
    'logo/svg/cybexos-logo-on-dark.svg': wordmark,
    'logo/svg/cybexos-logo-on-light.svg': svg(ink=CHARCOAL),
    'logo/svg/cybexos-logo-mono-white.svg': svg(ink='#FFFFFF', accent='#FFFFFF'),
    'symbol/svg/cybexos-symbol-on-dark.svg': symbol,
    'symbol/svg/cybexos-symbol-mono-white.svg': white,
    'app-icon/svg/cybexos-app-icon-dark.svg': tile,
}.items():
    write('assets/brand/' + name, data)
for name in ('desktop/quickshell/assets/cybexos.svg', 'web/public/cybexos.svg', 'installer/kiosk/assets/symbol.svg'):
    write(name, symbol)
for name in ('desktop/quickshell/assets/cybexos-white.svg', 'web/public/cybexos-white.svg'):
    write(name, highlight)
for name in ('web/public/cybexos-logo.svg', 'installer/kiosk/assets/logo.svg'):
    write(name, wordmark)
write('desktop/icons/hicolor/scalable/apps/cybexos.svg', tile)
for size in (16, 32, 48, 64, 128, 256, 512):
    write(f'desktop/icons/hicolor/{size}x{size}/apps/cybexos.png', raster(tile, size, size))

# Use 66% of the password field's width and retain the wordmark's aspect ratio.
entry_width = Image.open(ROOT / 'desktop/plymouth/entry.png').width
logo_width = round(entry_width * 0.66)
wordmark_box = [float(value) for value in ET.parse(SOURCE).getroot().attrib['viewBox'].split()]
logo_height = round(logo_width * wordmark_box[3] / wordmark_box[2])
write('desktop/plymouth/logo.png', raster(wordmark, logo_width, logo_height))
write('desktop/plymouth/logo@2x.png', raster(wordmark, logo_width * 2, logo_height * 2))
splash = Image.new('RGB', (640, 480), '#0d0d0d')
logo = Image.open(io.BytesIO(raster(wordmark, 360, 85))).convert('RGBA')
splash.paste(logo, (140, 58), logo)
write('desktop/boot/splash.png', png(splash))
# Preserve the existing entry/masking geometry and use blue for boot progress.
progress_path = ROOT / 'desktop/plymouth/progress_bar.png'
progress = Image.open(progress_path).convert('RGBA')
alpha = progress.getchannel('A')
progress = Image.new('RGBA', progress.size, UI_ACCENT)
progress.putalpha(alpha)
write('desktop/plymouth/progress_bar.png', png(progress))

for name, size in [('favicon-16x16.png', 16), ('favicon-32x32.png', 32), ('favicon-48x48.png', 48),
                   ('apple-touch-icon.png', 180), ('icon-192.png', 192), ('icon-512.png', 512),
                   ('icon-maskable-192.png', 192), ('icon-maskable-512.png', 512)]:
    image = raster(tile, size, size)
    write('assets/brand/favicon/' + name, image)
    write('web/public/' + name, image)
for prefix in ('assets/brand/favicon/', 'web/public/'):
    write(prefix + 'favicon.svg', tile)
    icon = Image.open(io.BytesIO(raster(tile, 256, 256)))
    output = io.BytesIO()
    icon.save(output, format='ICO', sizes=[(16, 16), (32, 32), (48, 48)])
    write(prefix + 'favicon.ico', output.getvalue())
    manifest = {'name': 'Cybex OS', 'short_name': 'Cybex OS', 'description': 'Cybex OS desktop preview',
                'start_url': '/', 'display': 'standalone', 'background_color': CHARCOAL, 'theme_color': CHARCOAL,
                'icons': [{'src': f'/icon{suffix}-{size}.png', 'sizes': f'{size}x{size}', 'type': 'image/png',
                           'purpose': 'maskable' if suffix else 'any'}
                          for suffix in ('', '-maskable') for size in (192, 512)]}
    write(prefix + 'site.webmanifest', json.dumps(manifest, indent=2) + '\n')

# Braille samples preserve the supplied wordmark's geometry in a text terminal.
def ascii_logo(width):
    image = Image.open(io.BytesIO(raster(wordmark, width * 2))).convert('RGBA')
    height = (image.height + 3) // 4 * 4
    padded = Image.new('RGBA', (image.width, height))
    padded.paste(image, (0, 0))
    rows = []
    dots = [(0, 0, 1), (0, 1, 2), (0, 2, 4), (1, 0, 8), (1, 1, 16), (1, 2, 32), (0, 3, 64), (1, 3, 128)]
    for y in range(0, height, 4):
        row = ''
        for x in range(0, padded.width, 2):
            bits = 0
            accented = False
            for dx, dy, bit in dots:
                r, g, b, alpha = padded.getpixel((x + dx, y + dy))
                if alpha > 96:
                    bits |= bit
                    accented |= r > max(g, b) + 40
            row += ('$2' if accented else '$1') + (chr(0x2800 + bits) if bits else ' ')
        rows.append(row.rstrip())
    return '\n'.join(rows) + '\n'


for kind, width in [('compact', 40), ('large', 64), ('banner', 80)]:
    colored = ascii_logo(width)
    plain = '\n'.join(line.rstrip() for line in colored.replace('$1', '').replace('$2', '').splitlines()) + '\n'
    for prefix in ('assets/brand/ascii/', 'desktop/fastfetch/'):
        write(prefix + f'cybexos-{kind}.fastfetch.txt', colored)
        write(prefix + f'cybexos-{kind}.txt', plain)
    if kind == 'compact':
        terminal = ROOT / 'web/lib/terminal.ts'
        text = terminal.read_text()
        start = text.index('export const CYBEXOS_LOGO_COLORED = ')
        end = text.index(';', start)
        terminal.write_text(text[:start] + 'export const CYBEXOS_LOGO_COLORED = '
                            + json.dumps(colored.rstrip('\n'), ensure_ascii=False) + text[end:])

write('assets/brand/kit-sha256.json', json.dumps({'schema': 1, 'files': files}, indent=2) + '\n')
print(f'Exported {len(files)} Cybex OS assets from {SOURCE.relative_to(ROOT)}')
