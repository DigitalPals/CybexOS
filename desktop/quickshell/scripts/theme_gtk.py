"""System theme target: GTK and libadwaita, through org.gnome.desktop.interface.

GTK 3 follows `gtk-theme` (the adw-gtk3 pair, so GTK 3 applications match
libadwaita ones), libadwaita follows `color-scheme` and `accent-color`, and
applications that ask the settings portal (Firefox, Chromium, Electron) read
the same keys through xdg-desktop-portal-gtk. `text-scaling-factor` sizes
their text with the shell's. All of them pick a change up while running.

gsettings holds the state, so the rendered gtk.json only records what was last
applied: an unchanged record is how the driver knows no call is needed.

The text scale is the one key people also set elsewhere (GNOME Tweaks, an
accessibility guide), so it is set only while it still holds the value this
target set last, or GNOME's default. A value of the user's own wins, as
user.lua does over the compositor colours, until
`gsettings reset org.gnome.desktop.interface text-scaling-factor` hands the
key back; `theme apply` does not override it either.
"""
import colorsys
import json
import os
import shutil
import subprocess
import tempfile

import theme_tokens

NAME = 'gtk'
SCHEMA = 'org.gnome.desktop.interface'
TIMEOUT = 10
TEXT_SCALE_KEY = 'text-scaling-factor'
# What reload() last set the text scale to; not a rendered file, so writing
# it never counts as a change.
APPLIED_FILE = 'gtk-text-scale'

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


def text_scaling_factor(tokens):
    """GNOME's text-scaling-factor: 1.00 at the shell's default text size."""
    return f'{theme_tokens.text_scale(tokens):.2f}'


def settings(tokens):
    """The org.gnome.desktop.interface values for tokens, in the order they are set."""
    mode = tokens['mode']
    return {
        'color-scheme': f'prefer-{mode}',
        'gtk-theme': GTK_THEMES[mode],
        'accent-color': accent_name(tokens['colors']['accent']),
        TEXT_SCALE_KEY: text_scaling_factor(tokens),
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


def _number(text):
    try:
        return float(text)
    except (TypeError, ValueError):
        return None


def _read_applied(directory):
    try:
        with open(os.path.join(directory, APPLIED_FILE), encoding='utf-8') as handle:
            return _number(handle.read(64).strip())
    except OSError:
        return None


def _write_applied(directory, value):
    descriptor, temporary = tempfile.mkstemp(dir=directory, prefix=f'.{APPLIED_FILE}.')
    try:
        with os.fdopen(descriptor, 'w', encoding='utf-8') as handle:
            handle.write(value + '\n')
        os.chmod(temporary, 0o644)
        os.replace(temporary, os.path.join(directory, APPLIED_FILE))
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def owns_text_scale(current, applied):
    """Whether the key still holds a value the shell may replace.

    GNOME's default (1.0) and the value this target set last are the shell's;
    anything else was set by someone else and is left alone.
    """
    value = _number(current)
    return value is None or any(abs(value - mine) < 0.005
                                for mine in (1.0, applied) if mine is not None)


def reload(tokens, directory):
    if shutil.which('gsettings') is None:
        # glib2 ships gsettings on every Cybex OS install, so a PATH without it
        # is a bare environment (the driver tests run with an empty one), not
        # a desktop with GTK applications to follow it.
        return
    # accent-color arrived with GNOME 47; an older schema simply lacks the key
    # and libadwaita keeps its default blue.
    keys = set(_gsettings('list-keys').split())
    for key, value in settings(tokens).items():
        if key == TEXT_SCALE_KEY:
            if key not in keys or not owns_text_scale(
                    _gsettings('get', key).strip(), _read_applied(directory)):
                continue
            _gsettings('set', key, value)
            _write_applied(directory, value)
        elif key != 'accent-color' or key in keys:
            _gsettings('set', key, value)
