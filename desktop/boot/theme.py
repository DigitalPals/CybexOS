#!/usr/bin/env python3
"""Build the GRUB theme shared by the installation ISO and installed systems.

nix/packages/boot-theme.nix runs this with resvg and grub-mkfont on PATH.
GRUB draws entry titles and the countdown in 1-bit PF2 fonts at one fixed
size. Every other text is static, so it is rendered here with anti-aliasing
into a PNG. GRUB reads only 8-bit RGBA PNGs, which is what resvg writes.

The logo stays where Plymouth draws it, 38% from the top, so it does not move
when an entry starts: GRUB then clears only its terminal window, which covers
everything below the logo. GRUB sizes a list from its theme, so each list
comes in variants by row count; GRUB scripts choose one (nix/modules/iso-boot.nix,
lifecycle/cybexos/boot.py).
"""
import argparse
import base64
import json
from pathlib import Path
import shutil
import subprocess
from xml.sax.saxutils import escape

from fontTools.ttLib import TTFont

# Black, as firmware logo screens and GRUB's plain terminal are.
BACKGROUND = '#000000'
CARD, CARD_LINE = '#141518', '#26282d'
INK, TEXT, FOG, MUTED, FAINT = '#f3f2ec', '#e4e3dd', '#9a9c95', '#9c9e97', '#7f817a'
KEY_LINE, KEY_TEXT = '#34363c', '#c9c8c2'
ACCENT, AMBER = '#60a5fa', '#f2c14e'
ANCHOR = '38%'
CANVAS = 900
# Rows are 42 px high on a 44 px pitch. GRUB draws the selection's padding
# outside item_height, so unselected rows get the same, transparent padding.
CARD_PAD, SEL_X, SEL_Y = 12, 14, 7
ITEM_HEIGHT, ITEM_SPACING = 42 - 2 * SEL_Y, 2 + 2 * SEL_Y
MAX_ROWS = 6
GLYPHS = '0x20-0x7E,0xA0-0x24F,0x2010-0x2027,0x2030-0x203A,0x2190-0x2193'


class Theme:
    def __init__(self, out, fonts, version):
        self.out, self.fonts, self.version = Path(out), Path(fonts), version
        self.sans = self.fonts / 'SpaceGrotesk-Medium.ttf'
        self.bold = self.fonts / 'SpaceGrotesk-Bold.ttf'
        self.mono = self.fonts / 'JetBrainsMono-Medium.ttf'
        self.metrics = {}
        self.work = self.out / '.work'
        (self.out / 'icons').mkdir(parents=True)
        self.work.mkdir()

    # ── rendering ────────────────────────────────────────────────────────────
    def render(self, name, svg, target, *extra):
        source = self.work / f'{name}.svg'
        source.write_text(svg)
        subprocess.run(['resvg', '--skip-system-fonts', '--use-font-file', self.sans, '--use-font-file', self.bold,
                        '--use-font-file', self.mono, *extra, source, target], check=True)

    def width(self, font, size, text, spacing=0.0):
        if font not in self.metrics:
            face = TTFont(font)
            self.metrics[font] = (face.getBestCmap(), face['hmtx'], face['head'].unitsPerEm)
        cmap, advances, units = self.metrics[font]
        return sum(advances[cmap[ord(c)]][0] for c in text) * size / units + spacing * size * len(text)

    def pf2(self, size, name):
        target = self.out / f'{name}.pf2'
        subprocess.run(['grub-mkfont', '-s', str(size), '-r', GLYPHS, '-o', target, self.sans], check=True)
        data = target.read_bytes()
        start = data.index(b'NAME') + 8
        return data[start:data.index(b'\0', start)].decode()

    def nine(self, prefix, size, pad, shape):
        """A GRUB styled box: nine PNGs cut from one drawing."""
        (w, h), (px, py) = size, pad
        columns = [(0, px), (px, w - 2 * px), (w - px, px)]
        rows = [(0, py), (py, h - 2 * py), (h - py, py)]
        for row, (y, ph) in zip(('n', '', 's'), rows):
            for column, (x, pw) in zip(('w', '', 'e'), columns):
                piece = (row + column) or 'c'
                self.render(f'{prefix}-{piece}', f'<svg xmlns="http://www.w3.org/2000/svg" width="{pw}" height="{ph}" '
                            f'viewBox="{x} {y} {pw} {ph}">{shape}</svg>', self.out / f'{prefix}_{piece}.png')

    def text_image(self, name, content, height):
        self.render(name, f'<svg xmlns="http://www.w3.org/2000/svg" width="{CANVAS}" height="{height}">{content}</svg>',
                    self.out / f'{name}.png')

    def label(self, x, y, text, size, color, font='sans', anchor='middle', spacing=0.0):
        family = {'sans': 'Space Grotesk', 'bold': 'Space Grotesk', 'mono': 'JetBrains Mono'}[font]
        weight = 700 if font == 'bold' else 500
        return (f'<text x="{x:.1f}" y="{y:.1f}" text-anchor="{anchor}" dominant-baseline="central" font-family="{family}" '
                f'font-weight="{weight}" font-size="{size}" letter-spacing="{spacing}em" fill="{color}">{escape(text)}</text>')

    def icon(self, d, x, y, size, color, width=1.5):
        paths = ''.join(f'<path d="{part}"/>' for part in d)
        return (f'<svg x="{x:.1f}" y="{y:.1f}" width="{size}" height="{size}" viewBox="0 0 24 24" fill="none" stroke="{color}" '
                f'stroke-width="{width}" stroke-linecap="round" stroke-linejoin="round">{paths}</svg>')

    # ── pieces ───────────────────────────────────────────────────────────────
    def eyebrow(self, name, text):
        self.text_image(f'eyebrow-{name}', self.label(CANVAS / 2, 10, text.upper(), 14, FAINT, 'mono', spacing=0.18), 20)

    def hints(self, name, groups):
        """Key caps and their actions, centred."""
        items, x = [], 0.0
        for keys, action in groups:
            for key in keys:
                w = max(24, self.width(self.mono, 12.5, key) + 14)
                items.append(('key', x, w, key))
                x += w + 4
            items.append(('action', x + 4, 0, action))
            x += 4 + self.width(self.sans, 15, action) + 26
        left = (CANVAS - (x - 26)) / 2
        parts = []
        for kind, x, w, text in items:
            if kind == 'key':
                parts.append(f'<rect x="{left + x + .5:.1f}" y="2.5" width="{w - 1:.1f}" height="23" rx="6" fill="none" '
                             f'stroke="{KEY_LINE}"/>' + self.label(left + x + w / 2, 14, text, 12.5, KEY_TEXT, 'mono'))
            else:
                parts.append(self.label(left + x, 14, text, 15, FAINT, anchor='start'))
        self.text_image(f'hints-{name}', ''.join(parts), 28)

    def notice(self, alert):
        title = 'The last start didn’t finish'
        span = 18 + 8 + self.width(self.sans, 17, title)
        left = (CANVAS - span) / 2
        content = (self.icon(alert, left, 2, 18, AMBER, 1.75) + self.label(left + 26, 11, title, 17, AMBER, anchor='start')
                   + self.label(CANVAS / 2, 38, 'Choose an earlier version, or wait and Cybex OS starts as usual.', 15, FOG))
        self.text_image('notice', content, 50)

    def background(self):
        self.render('background', f'<svg xmlns="http://www.w3.org/2000/svg" width="8" height="8">'
                    f'<rect width="8" height="8" fill="{BACKGROUND}"/></svg>', self.out / 'background.png')

    def boxes(self):
        self.nine('menu', (40, 40), (CARD_PAD, CARD_PAD),
                  f'<rect x=".5" y=".5" width="39" height="39" rx="12" fill="{CARD}" stroke="{CARD_LINE}"/>')
        self.nine('select', (40, 30), (SEL_X, SEL_Y),
                  f'<rect x=".5" y=".5" width="39" height="29" rx="7" fill="{ACCENT}" fill-opacity="0.16" '
                  f'stroke="{ACCENT}" stroke-opacity="0.6"/>')
        self.nine('item', (40, 30), (SEL_X, SEL_Y), '')
        # The thumb overlays an empty frame in the card's right padding.
        self.nine('frame', (3, 3), (1, 1), '')
        self.nine('thumb', (4, 12), (1, 2), '<rect width="4" height="12" rx="2" fill="#3a3c42"/>')

    def icons(self, paths, symbol):
        for name, d in paths.items():
            if name != 'alert':
                self.render(f'icon-{name}', '<svg xmlns="http://www.w3.org/2000/svg" width="22" height="22">'
                            + self.icon(d, 0, 0, 22, MUTED) + '</svg>', self.out / 'icons' / f'{name}.png')
        subprocess.run(['resvg', '-w', '22', '-h', '22', symbol, self.out / 'icons' / 'cybexos.png'], check=True)

    def bios(self, logo):
        """The legacy BIOS screen's 800×600 background; isolinux draws only its three entries."""
        body = ('This computer started the installer in legacy BIOS mode. Cybex OS installs only in UEFI mode. '
                'Restart, open the boot menu (often F12, F11 or Esc) and choose the entry for this drive that '
                'starts with “UEFI”.')
        lines, line = [], ''
        for word in body.split():
            candidate = f'{line} {word}'.strip()
            if line and self.width(self.sans, 16, candidate) > 540:
                lines.append(line)
                line = word
            else:
                line = candidate
        lines.append(line)
        image = base64.b64encode(Path(logo).read_bytes()).decode()
        content = (f'<rect width="800" height="600" fill="{BACKGROUND}"/>'
                   f'<image x="305.5" y="72" width="189" height="44" href="data:image/png;base64,{image}"/>'
                   + self.label(400, 184, 'Start this USB drive in UEFI mode', 26, INK, 'bold')
                   + ''.join(self.label(400, 228 + 24 * index, text, 16, FOG) for index, text in enumerate(lines))
                   + self.label(400, 564, f'Cybex OS {self.version}', 14, '#5d5f59'))
        self.render('bios', f'<svg xmlns="http://www.w3.org/2000/svg" width="800" height="600">{content}</svg>',
                    self.out / 'bios.png')

    # ── layouts ──────────────────────────────────────────────────────────────
    def layout(self, name, rows, width, fonts, heading='eyebrow-startup', hints='hints-nav', countdown=None, note=None):
        """A theme file: logo, heading, one card of `rows` rows and key hints."""
        notice = heading == 'notice'
        top = 93 if notice else 69
        height = rows * (ITEM_HEIGHT + ITEM_SPACING) - ITEM_SPACING + 2 * SEL_Y + 2 * CARD_PAD
        below = top + height
        heading_height = 50 if notice else 20
        lines = [
            f'# Generated by desktop/boot/theme.py: {rows} row{"s" if rows > 1 else ""}.',
            f'desktop-color: "{BACKGROUND}"',
            # GRUB 2.12 scales the desktop image without checking that there is
            # one; the error it leaves is printed over a submenu.
            'desktop-image: "background.png"',
            'title-text: ""',
            'terminal-font: "Unifont Regular 16"',
            # GRUB clears this window while an entry loads, so the logo stays.
            'terminal-left: "0"',
            f'terminal-top: "{ANCHOR}+30"',
            'terminal-width: "100%"',
            'terminal-height: "62%-30"',
            'terminal-border: "0"',
            '',
            f'+ image {{ left = 50%-94 top = {ANCHOR}-22 width = 189 height = 44 file = "logo.png" }}',
            f'+ image {{ left = 50%-{CANVAS // 2} top = {ANCHOR}+31 width = {CANVAS} height = {heading_height} file = "{heading}.png" }}',
            '+ boot_menu {',
            f'  left = 50%-{width // 2}',
            f'  top = {ANCHOR}+{top}',
            f'  width = {width}',
            f'  height = {height}',
            f'  item_font = "{fonts["item"]}"',
            f'  selected_item_font = "{fonts["item"]}"',
            f'  item_color = "{TEXT}"',
            f'  selected_item_color = "{INK}"',
            f'  item_height = {ITEM_HEIGHT}',
            '  item_padding = 0',
            f'  item_spacing = {ITEM_SPACING}',
            '  icon_width = 22',
            '  icon_height = 22',
            '  item_icon_space = 14',
            '  menu_pixmap_style = "menu_*.png"',
            '  item_pixmap_style = "item_*.png"',
            '  selected_item_pixmap_style = "select_*.png"',
            '  scrollbar = true',
            '  scrollbar_frame = "frame_*.png"',
            '  scrollbar_thumb = "thumb_*.png"',
            '  scrollbar_thumb_overlay = true',
            '  scrollbar_width = 4',
            '}',
        ]
        if countdown:
            lines.append(f'+ label {{ id = "__timeout__" left = 0 top = {ANCHOR}+{below + 16} width = 100% height = 18 '
                         f'align = "center" color = "{FOG}" font = "{fonts["count"]}" text = "{countdown}" }}')
        if note:
            lines.append(f'+ image {{ left = 50%-{CANVAS // 2} top = {ANCHOR}+{below + 12} width = {CANVAS} height = 22 '
                         f'file = "{note}.png" }}')
        lines.append(f'+ image {{ left = 50%-{CANVAS // 2} top = 100%-40 width = {CANVAS} height = 28 file = "{hints}.png" }}')
        (self.out / f'{name}.txt').write_text('\n'.join(lines) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n', 1)[0])
    parser.add_argument('--out', required=True)
    parser.add_argument('--version', required=True)
    parser.add_argument('--fonts', required=True, help='Directory with Space Grotesk and JetBrains Mono')
    parser.add_argument('--logo', required=True, help='The Plymouth wordmark, 189×44')
    parser.add_argument('--symbol', required=True, help='The Cybex X, for the operating system entries')
    parser.add_argument('--icons', required=True, help='Tabler paths from scripts/update-installer-icons')
    parser.add_argument('--unifont', required=True, help="GRUB's unicode.pf2, for the terminal and missing glyphs")
    options = parser.parse_args()

    theme = Theme(options.out, options.fonts, options.version)
    fonts = {'item': theme.pf2(21, 'entries'), 'count': theme.pf2(15, 'countdown')}
    shutil.copy(options.unifont, theme.out / 'unicode.pf2')
    shutil.copy(options.logo, theme.out / 'logo.png')
    paths = json.loads(Path(options.icons).read_text())['paths']
    theme.icons(paths, options.symbol)
    theme.background()
    theme.boxes()
    theme.eyebrow('installer', f'Cybex OS Installer · {options.version}')
    theme.eyebrow('troubleshooting', 'Troubleshooting')
    theme.eyebrow('rotate', 'Rotate the screen')
    theme.eyebrow('startup', 'Startup options')
    theme.eyebrow('earlier', 'Earlier versions')
    theme.notice(paths['alert'])
    theme.text_image('note-earlier', theme.label(CANVAS / 2, 11, 'Starts the chosen version once. '
                                                 'The next start uses your usual version.', 15, FAINT), 22)
    nav = [(['↑', '↓'], 'Select'), (['Enter'], 'Start'), (['E'], 'Edit')]
    theme.hints('nav', nav)
    theme.hints('back', nav[:2] + [(['Esc'], 'Back')])
    theme.hints('once', [(['↑', '↓'], 'Select'), (['Enter'], 'Start once'), (['Esc'], 'Back')])
    theme.bios(options.logo)

    for rows in range(1, MAX_ROWS + 1):
        theme.layout(f'startup-{rows}', rows, 520, fonts, countdown='Starting Cybex OS in %d s')
        theme.layout(f'notice-{rows}', rows, 520, fonts, heading='notice', countdown='Starting Cybex OS in %d s')
        theme.layout(f'earlier-{rows}', rows, 560, fonts, heading='eyebrow-earlier', hints='hints-once', note='note-earlier')
        theme.layout(f'installer-{rows}', rows, 520, fonts, heading='eyebrow-installer',
                     countdown='Starting the installer in %d s')
        theme.layout(f'troubleshooting-{rows}', rows, 580, fonts, heading='eyebrow-troubleshooting', hints='hints-back')
    theme.layout('rotate', 3, 520, fonts, heading='eyebrow-rotate', hints='hints-back')
    # NixOS loads theme.txt; the installed menu's usual four rows.
    shutil.copy(theme.out / 'startup-4.txt', theme.out / 'theme.txt')
    shutil.rmtree(theme.work)


if __name__ == '__main__':
    main()
