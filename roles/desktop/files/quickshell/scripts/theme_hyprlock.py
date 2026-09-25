"""System theme target: the hyprlock lock screen.

Renders hyprlock.conf: the vendor lock screen's layout (clock, date and
password field) in the shell's font and colours, over the current wallpaper.
`cybexos-runtime exec hyprlock` prefers this file to the vendor one unless the
user has their own ~/.config/cybexos/hypr/hyprlock.conf, and only while its
first line is HEADER, so a file this module did not write is never used.

The wallpaper is blurred and covered by a scrim of the base colour. The blur
turns detail into soft fields of colour; the scrim alone does the dimming,
because hyprlock's `brightness` only darkens (it would sink the dark text of
the light mode) and its `contrast` curve never moves pure black or white. So
the backdrop behind every label lies between the scrim over black and over
white, and each text colour is checked, and if needed moved, to 4.5:1 against
the worse of the two. Without a wallpaper the background is the base colour.

reload() does nothing: hyprlock reads its configuration each time the lock
starts, and a lock that is already up keeps the look it started with.
"""
from theme_tokens import contrast, ensure_contrast, mix, rgba

NAME = 'hyprlock'
# The resolver compares the first line verbatim (assets/scripts/cybexos-runtime).
HEADER = '# CybexOS lock screen, rendered by the system theme (theme_hyprlock.py).'

# Scrim opacity: the least in SCRIM_STEPS that keeps the body text at 4.5:1
# over a pure white or black wallpaper. The floor keeps a busy wallpaper calm.
SCRIM_STEPS = tuple(step / 100 for step in range(50, 95, 5))
BLUR_PASSES = 3
BLUR_SIZE = 8
# The password field's fill over whatever is behind it: opaque enough that its
# copy reads against the fill, as it did in the vendor file.
FIELD_ALPHA = 0.85
TEXT_CONTRAST = 4.5


def _color(value, alpha=1.0):
    return f'rgba({rgba(value, alpha)})'


def _readable(value, backdrops):
    """`value`, moved toward black or white until it reads on every backdrop."""
    worst = min(backdrops, key=lambda backdrop: contrast(value, backdrop))
    return ensure_contrast(value, worst, TEXT_CONTRAST)


def _scrim_alpha(text, base):
    for alpha in SCRIM_STEPS:
        if all(contrast(text, mix(extreme, base, alpha)) >= TEXT_CONTRAST
               for extreme in ('#000000', '#ffffff')):
            return alpha
    return SCRIM_STEPS[-1]


def render(tokens):
    colors = tokens['colors']
    base = colors['background']
    # A '#' would start a hyprlang comment ('##' is its escape), and a '$'
    # could expand $font; rather than rely on more escaping, such a name,
    # or one hyprlang would trim, shows the solid background.
    wallpaper = tokens['wallpaper']
    if any(ch in wallpaper for ch in '#${}') or wallpaper != wallpaper.strip():
        wallpaper = ''

    if wallpaper:
        scrim = _scrim_alpha(colors['text'], base)
        backdrops = [mix(extreme, base, scrim) for extreme in ('#000000', '#ffffff')]
        background = [
            'background {',
            '  monitor =',
            f'  path = {wallpaper}',
            f'  color = {_color(base)}',
            f'  blur_passes = {BLUR_PASSES}',
            f'  blur_size = {BLUR_SIZE}',
            # Neutral, so the scrim above does all of the dimming.
            '  brightness = 1.0',
            '  contrast = 1.0',
            # hyprlock sorts widgets by zindex with an unstable sort: distinct
            # values keep the scrim above the wallpaper and below the text.
            '  zindex = -2',
            '}',
            '',
            'shape {',
            '  monitor =',
            '  size = 100%, 100%',
            f'  color = {_color(base, scrim)}',
            '  zindex = -1',
            '}',
        ]
    else:
        backdrops = [base]
        background = [
            'background {',
            '  monitor =',
            f'  color = {_color(base)}',
            '}',
        ]
    field = [mix(backdrop, colors['surface'], FIELD_ALPHA) for backdrop in backdrops]

    lines = [
        HEADER,
        '# Edits are overwritten; ~/.config/cybexos/hypr/hyprlock.conf replaces it.',
        f'$font = {tokens["font"]["ui"]}',
        '',
        'general {',
        '  hide_cursor = true',
        '  ignore_empty_input = true',
        '}',
        '',
        'animations {',
        '  enabled = true',
        '  bezier = ease, 0.25, 0.1, 0.25, 1.0',
        '  animation = fadeIn, 1, 3, ease',
        '  animation = fadeOut, 1, 3, ease',
        '  animation = inputFieldDots, 1, 2, ease',
        '}',
        '',
        *background,
        '',
        'label {',
        '  monitor =',
        '  text = $TIME',
        f'  color = {_color(_readable(colors["text"], backdrops))}',
        '  font_size = 84',
        '  font_family = $font',
        '  position = 0, 150',
        '  halign = center',
        '  valign = center',
        '}',
        '',
        'label {',
        '  monitor =',
        '  text = cmd[update:60000] date +"%A, %d %B"',
        f'  color = {_color(_readable(colors["textMuted"], backdrops))}',
        '  font_size = 24',
        '  font_family = $font',
        '  position = 0, 85',
        '  halign = center',
        '  valign = center',
        '}',
        '',
        'input-field {',
        '  monitor =',
        '  size = 300, 54',
        '  outline_thickness = 2',
        '  dots_size = 0.28',
        '  dots_spacing = 0.22',
        '  dots_center = true',
        f'  outer_color = {_color(colors["stroke"])}',
        f'  inner_color = {_color(colors["surface"], FIELD_ALPHA)}',
        f'  font_color = {_color(_readable(colors["text"], field))}',
        '  fade_on_empty = false',
        # Pango markup; '##' is hyprlang's escape for a literal '#'.
        '  placeholder_text = <span foreground="#'
        + _readable(colors['textMuted'], field) + '">Password</span>',
        '  fail_text = <span foreground="#'
        + _readable(colors['red'], field) + '">$PAMFAIL</span>',
        f'  check_color = {_color(colors["accent"])}',
        f'  fail_color = {_color(colors["red"])}',
        '  rounding = 12',
        '  font_family = $font',
        '  position = 0, -18',
        '  halign = center',
        '  valign = center',
        '}',
    ]
    return {'hyprlock.conf': '\n'.join(lines) + '\n'}


def reload(tokens, directory):
    # Nothing to signal: hyprlock only runs while the session is locked and
    # reads the file afresh at every lock.
    pass
