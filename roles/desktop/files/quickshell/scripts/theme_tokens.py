"""The shell's resolved appearance, as handed to the system theme targets.

Common/SystemTheme.qml exports the colours Theme.qml has already resolved —
the fixed palette or the wallpaper's, with the shell's contrast floors applied
— so no target recomputes the shell's design. This module validates that
export and holds the colour arithmetic the targets share. Every value that
reaches a rendered file passes through validate() first, so targets may embed
them in config syntax without further escaping.
"""
import os
import re

VERSION = 1

# Opaque semantic colours, all "#rrggbb". SystemTheme.qml flattens the
# shell's translucent tokens over `background` before exporting them.
COLOR_KEYS = (
    'background',       # Theme.background: the base panels and dialogs rest on
    'surface',          # Theme.popBg: one step up from the base
    'surfaceRaised',    # Theme.menuBg: menus and other small raised things
    'bar',              # Theme.barBg: the user's bar colour
    'text',             # Theme.textHi
    'textMuted',        # Theme.textMid
    'textDim',          # Theme.textDim, still >= 4.5:1 on the panels
    'accent',           # Theme.accent: fills and state marks
    'onAccent',         # Theme.accentFg: copy drawn on the accent
    'accentText',       # Theme.accentText: the accent as readable copy
    'accentContainer',  # Theme.accentContainer: a calm selected fill
    'stroke',           # Theme.stroke flattened over background
    'red',              # Theme.redText
    'amber',            # Theme.amber
    'green',            # Theme.ok
)

HEX = re.compile(r'^#[0-9a-f]{6}$')
# Font families end up inside quoted config values. Letters, digits, spaces
# and a little punctuation cover every family the shell offers.
FONT = re.compile(r'^[A-Za-z0-9 ._+-]{1,64}$')
MAX_PATH = 4096


class TokenError(ValueError):
    pass


def _color(value, key):
    if not isinstance(value, str) or not HEX.match(value.lower()):
        raise TokenError(f'colour {key} is not #rrggbb')
    return value.lower()


def _font(value, key):
    if not isinstance(value, str) or not FONT.match(value):
        raise TokenError(f'font {key} is not a plain family name')
    return value


def _path(value):
    # A wallpaper whose name cannot be embedded safely is dropped rather than
    # failing the whole export: the targets that show it fall back to colour.
    if (not isinstance(value, str) or len(value) > MAX_PATH or not value.startswith('/')
            or any(ord(ch) < 32 or ch in '"\\' for ch in value)):
        return ''
    return value


def validate(raw):
    """Returns a normalized copy of an export, or raises TokenError."""
    if not isinstance(raw, dict):
        raise TokenError('tokens are not an object')
    if raw.get('v') != VERSION:
        raise TokenError(f'unsupported tokens version {raw.get("v")!r}')
    mode = raw.get('mode')
    if mode not in ('dark', 'light'):
        raise TokenError('mode is neither dark nor light')
    source = raw.get('source')
    if source not in ('fixed', 'wallpaper'):
        raise TokenError('source is neither fixed nor wallpaper')
    colors = raw.get('colors')
    if not isinstance(colors, dict):
        raise TokenError('colors are missing')
    font = raw.get('font')
    if not isinstance(font, dict):
        raise TokenError('font is missing')
    radius = raw.get('radius')
    if type(radius) is not int or not 0 <= radius <= 64:
        raise TokenError('radius is not an integer from 0 to 64')
    glass = raw.get('glass')
    if not isinstance(glass, bool):
        raise TokenError('glass is not a boolean')
    return {
        'v': VERSION,
        'mode': mode,
        'source': source,
        'colors': {key: _color(colors.get(key), key) for key in COLOR_KEYS},
        'font': {'ui': _font(font.get('ui'), 'ui'), 'mono': _font(font.get('mono'), 'mono')},
        'radius': radius,
        'glass': glass,
        'wallpaper': _path(raw.get('wallpaper', '')),
    }


def state_dir():
    """Where rendered files live: ~/.local/state/cybexos/theme."""
    override = os.environ.get('CYBEXOS_THEME_STATE_DIR')
    if override:
        return override
    base = os.environ.get('XDG_STATE_HOME') or os.path.join(os.path.expanduser('~'),
                                                            '.local/state')
    return os.path.join(base, 'cybexos/theme')


# ---- colour arithmetic ------------------------------------------------------
# These mirror Common/SettingsHelpers.js so a target that derives a colour
# lands where the shell would.

def rgb(value):
    return tuple(int(value[i:i + 2], 16) / 255 for i in (1, 3, 5))


def hex_color(channels):
    return '#' + ''.join(f'{max(0, min(255, int(c * 255 + 0.5))):02x}' for c in channels)


def mix(start, end, amount):
    t = min(1.0, max(0.0, amount))
    a, b = rgb(start), rgb(end)
    return hex_color(tuple(x + (y - x) * t for x, y in zip(a, b)))


def luminance(value):
    def linear(channel):
        return channel / 12.92 if channel <= 0.04045 else ((channel + 0.055) / 1.055) ** 2.4
    r, g, b = (linear(c) for c in rgb(value))
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def contrast(a, b):
    first, second = luminance(a), luminance(b)
    return (max(first, second) + 0.05) / (min(first, second) + 0.05)


def foreground_for(background):
    return ('#ffffff' if contrast('#ffffff', background) >= contrast('#000000', background)
            else '#000000')


def ensure_contrast(value, background, target):
    """The least move of `value` toward black or white that reaches `target`."""
    if contrast(value, background) >= target:
        return value
    foreground = foreground_for(background)
    low, high = 0.0, 1.0
    for _ in range(16):
        mid = (low + high) / 2
        if contrast(mix(value, foreground, mid), background) >= target:
            high = mid
        else:
            low = mid
    return mix(value, foreground, high)


def rgba(value, alpha=1.0):
    """"rrggbbaa" without the hash, the form Hyprland's rgba() takes."""
    return value[1:] + f'{max(0, min(255, int(alpha * 255 + 0.5))):02x}'


# ---- terminal palette ---------------------------------------------------------
# The sixteen ANSI colours. Hues are fixed per mode (the dark set is the one
# the terminal has shipped since the menubar redesign) and only pushed toward
# the ink colour where the base would fall below 4.5:1, so a pale or tinted
# wallpaper base never makes red or blue unreadable. Black, white and their
# bright pairs come from the shell's own text ladder.
ANSI_HUES = {
    'dark': (
        ('#e8837a', '#a3c98f', '#d3b47e', '#9ecbeb', '#c0a8dc', '#6ec2b2'),
        ('#ffb3ab', '#b8dba5', '#e5cb98', '#b6dcf6', '#d4c0ec', '#8fd8ca'),
    ),
    'light': (
        ('#b3261e', '#2e7d32', '#8a5a00', '#1f5fbf', '#7a3fc0', '#0f766e'),
        ('#d1242f', '#1a7f37', '#9a6700', '#0969da', '#8250df', '#1b7c83'),
    ),
}


def ansi_palette(tokens):
    """Returns sixteen "#rrggbb" colours, color0 through color15."""
    colors = tokens['colors']
    background, text = colors['background'], colors['text']
    normal, bright = ANSI_HUES[tokens['mode']]
    normal = [ensure_contrast(c, background, 4.5) for c in normal]
    bright = [ensure_contrast(c, background, 4.5) for c in bright]
    if tokens['mode'] == 'dark':
        black = mix(background, text, 0.10)
        bright_black = ensure_contrast(mix(background, text, 0.40), background, 3.0)
        white, bright_white = colors['textMuted'], text
    else:
        black, bright_black = text, colors['textDim']
        white = ensure_contrast(mix(background, text, 0.45), background, 3.0)
        bright_white = mix(background, text, 0.25)
    return [black, *normal, white, bright_black, *bright, bright_white]
