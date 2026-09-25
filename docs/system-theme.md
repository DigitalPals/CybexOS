# System theme

The shell's appearance settings — dark or light, the fixed or wallpaper
palette, the accent, the bar colour and the font — reach the rest of the
desktop, not just the Quickshell surfaces. Changing any of them in Settings →
Appearance, or a wallpaper change in wallpaper mode, recolours the terminal,
the compositor, GTK applications and the lock screen within about a second.

## How it works

1. `Common/SystemTheme.qml` exports the colours `Theme.qml` has already
   resolved as one JSON object (the *tokens*). Nothing is recomputed: the
   wallpaper palette, the contrast floors and the bar colour are exactly the
   ones the shell draws. Translucent tokens are flattened over the base, so
   every exported colour is an opaque `#rrggbb`.
2. When the tokens change (debounced by 400 ms, and never while a wallpaper
   palette is still being generated), the shell pipes them to
   `scripts/theme-apply.py apply`.
3. The renderer validates them (`scripts/theme_tokens.py`), saves them to
   `~/.local/state/cybexos/theme/tokens.json`, and lets each target module
   render its files into the same directory. A target reloads its application
   only when one of its files changed.

| Token | Source in `Theme.qml` |
| --- | --- |
| `mode` | `dark` or `light` |
| `source` | `wallpaper` when the wallpaper palette is active, else `fixed` |
| `colors.background`, `surface`, `surfaceRaised`, `bar` | `background`, `popBg`, `menuBg`, `barBg` |
| `colors.text`, `textMuted`, `textDim` | `textHi`, `textMid`, `textDim` |
| `colors.accent`, `onAccent`, `accentText`, `accentContainer` | `accent`, `accentFg`, `accentText`, `accentContainer` |
| `colors.stroke` | `stroke` flattened over `background` |
| `colors.red`, `amber`, `green` | `redText`, `amber`, `ok` |
| `font.ui`, `font.mono` | `fontMenu`, `fontMono` |
| `radius` | `surfaceRadius` (the compositor's window rounding) |
| `glass` | `glassActive` |
| `wallpaper` | absolute path of the current wallpaper, or empty |

The sixteen terminal colours are derived by `theme_tokens.ansi_palette()`:
fixed hues per mode, pushed toward the ink colour only where a hue would fall
below 4.5:1 on the base, with black and white taken from the shell's text
ladder.

## Diagnostics

```bash
cybexos-runtime ipc theme status   # last report per target, and any error
cybexos-runtime ipc theme apply    # re-render and reload every target
```

`theme-apply.py render` rewrites the files from the saved tokens without
reloading anything.

## Ownership

Everything the renderer writes lives in `~/.local/state/cybexos/theme/`
(state, not configuration). User overrides keep winning: a user
`~/.config/cybexos/hypr/hyprlock.conf` replaces the generated lock screen, and
`~/.config/cybexos/hypr/user.lua` loads after the generated compositor
colours.

## Targets

### Kitty

(Target not yet documented.)

### Hyprland

(Target not yet documented.)

### GTK

(Target not yet documented.)

### Lock screen (hyprlock)

`scripts/theme_hyprlock.py` renders `hyprlock.conf`: the vendor layout (clock,
date and password field) in `font.ui`, with the clock in `text`, the date and
the field's placeholder in `textMuted`, the field filled with `surface` at 85%
and ringed with `stroke`, turning `accent` while checking and `red` on a
failure.

With a wallpaper, the background is that image, blurred (3 passes of size 8,
enough to reduce it to soft fields of colour) under a full-screen scrim of
`background`, with `background` as the colour hyprlock falls back to if the
image cannot be loaded. The scrim does all of the dimming: hyprlock's
`brightness` only darkens, which would sink the light mode's dark text, and
its `contrast` curve never moves pure black or white, so both are set to 1.0.
The scrim's opacity is the least step from 50% to 90% that keeps `text` at
4.5:1 over a pure black *and* a pure white wallpaper (65% for the fixed dark
palette, 60% for the light one), and every text colour is then moved toward
black or white where needed to reach 4.5:1 on the worse of those two
backdrops, and on the field's fill over them. In the dark mode that lifts the
date nearly to `text`; the size difference carries the hierarchy. Without a
wallpaper, or with a file name hyprlang would misread (`#`, `$`, braces or
edge spaces), the background is plain `background`.

`reload` does nothing: hyprlock runs only while the session is locked and reads
its configuration at every lock, so the next lock shows the new look and one
already on screen keeps the look it started with.

`cybexos-runtime exec hyprlock` (the `cybexos-session-lock.service` command)
picks the configuration in this order:

1. `~/.config/cybexos/hypr/hyprlock.conf`, when it is a regular file;
2. the rendered `$XDG_STATE_HOME/cybexos/theme/hyprlock.conf` (default
   `~/.local/state/…`), when it is a non-empty regular file, not a link, whose
   first line is the renderer's header;
3. the vendor `~/.local/share/cybexos/runtime/hypr/hyprlock.conf`.

The vendor file is the renderer's output for the fixed dark palette without a
wallpaper, so the lock screen looks the same before the shell's first export;
`tests/quickshell/system-theme-hyprlock.test.cjs` keeps the two equal. A
damaged rendered file cannot prevent locking: the renderer replaces it
atomically, and hyprlock ignores entries it cannot parse rather than refusing
to lock.

## Adding a target

A target is a `scripts/theme_<name>.py` module listed in `TARGETS` in
`theme-apply.py`, with `NAME`, a deterministic `render(tokens)` returning
`{file name: content}` (at least one file), and `reload(tokens, directory)`,
which raises with a short, readable message on failure. Reload commands must be
resolved through `PATH`: the tests run every target with a PATH of stub
commands, so they can never signal or reconfigure the real desktop.
