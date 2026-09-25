"""System theme target: GTK and libadwaita, through org.gnome.desktop.interface.

GTK 3 follows `gtk-theme` (the adw-gtk3 pair, so GTK 3 applications match
libadwaita ones), libadwaita follows `color-scheme` and `accent-color`, and
applications that ask the settings portal (Firefox, Chromium, Electron) read
the same keys through xdg-desktop-portal-gtk. All of them pick a change up
while running.

gsettings holds the state, so the rendered gtk.json only records what was last
applied: an unchanged record is how the driver knows no call is needed.
"""
import colorsys
import json
import shutil
import subprocess

import theme_tokens

NAME = 'gtk'
SCHEMA = 'org.gnome.desktop.interface'
TIMEOUT = 10

GTK_THEMES = {'dark': 'adw-gtk3-dark', 'light': 'adw-gtk3'}

# libadwaita's named accents (GNOME 47) by the hue of the colour it draws for
# each. Slate is the grey-blue one: it takes accents with too little colour to
# have a meaningful hue.
ACCENT_HUES = (
    ('blue', theme_tokens.rgb('#3584e4')),
    ('teal', theme_tokens.rgb('#2190a4')),
    ('green', theme_tokens.rgb('#3a944a')),
    ('yellow', theme_tokens.rgb('#c88800')),
    ('orange', theme_tokens.rgb('#ed5b00')),
    ('red', theme_tokens.rgb('#e62d42')),
    ('pink', theme_tokens.rgb('#d56199')),
    ('purple', theme_tokens.rgb('#9141ac')),
)
# Chroma (max - min channel) below which an accent reads as grey. libadwaita's
# own slate, #6f8396, sits just under it.
SLATE_CHROMA = 0.16


def _hue(channels):
    return colorsys.rgb_to_hsv(*channels)[0] * 360


def accent_name(value):
    """The libadwaita accent nearest to a "#rrggbb" colour by hue."""
    channels = theme_tokens.rgb(value)
    if max(channels) - min(channels) < SLATE_CHROMA:
        return 'slate'
    hue = _hue(channels)

    def distance(entry):
        gap = abs(hue - _hue(entry[1])) % 360
        return min(gap, 360 - gap)
    return min(ACCENT_HUES, key=distance)[0]


def settings(tokens):
    """The org.gnome.desktop.interface values for tokens, in the order they are set."""
    mode = tokens['mode']
    return {
        'color-scheme': f'prefer-{mode}',
        'gtk-theme': GTK_THEMES[mode],
        'accent-color': accent_name(tokens['colors']['accent']),
    }


def render(tokens):
    return {'gtk.json': json.dumps(settings(tokens), indent=2, sort_keys=True) + '\n'}


def _gsettings(action, *args):
    """Runs `gsettings action SCHEMA args...` and returns its output."""
    what = ' '.join(('gsettings', action, *args[:1]))  # the key, never the value
    try:
        result = subprocess.run(['gsettings', action, SCHEMA, *args], stdin=subprocess.DEVNULL,
                                capture_output=True, text=True, timeout=TIMEOUT, check=False)
    except subprocess.TimeoutExpired:
        raise RuntimeError(f'{what} timed out') from None
    if result.returncode != 0:
        lines = (result.stderr or result.stdout).strip().splitlines()
        detail = lines[0] if lines else f'exit status {result.returncode}'
        raise RuntimeError(f'{what} failed: {detail}')
    return result.stdout


def reload(tokens, directory):
    if shutil.which('gsettings') is None:
        # glib2 ships gsettings on every Fedora install, so a PATH without it
        # is a bare environment (the driver tests run with an empty one), not
        # a desktop with GTK applications to follow it.
        return
    # accent-color arrived with GNOME 47; an older schema simply lacks the key
    # and libadwaita keeps its default blue.
    keys = set(_gsettings('list-keys').split())
    for key, value in settings(tokens).items():
        if key != 'accent-color' or key in keys:
            _gsettings('set', key, value)
