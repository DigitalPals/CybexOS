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

`scripts/theme_kitty.py` renders `kitty.conf`: foreground and background
(`text`, `background`), the selection (`accentContainer` with the ink the shell
draws on it), cursor and URLs (`accentText`, kept at 4.5:1 on the base), tabs
(the active one filled `accent`/`onAccent`, inactive ones `surface` with
`textMuted`), window borders, the three marker colours and `color0`–`color15`
from `ansi_palette()`. Fonts and opacity stay in the vendor fragment.

The vendor fragment, `roles/dotfiles/files/kitty.conf` (installed as
`~/.config/kitty/cybexos.conf` and included from the user's `kitty.conf`),
carries the same settings for the default dark theme as a fallback, and a test
keeps it equal to that render. Its last line,
`include ~/.local/state/cybexos/theme/kitty.conf`, loads the generated file
over it. kitty expands `~` in `include` and only logs a missing file, so a
terminal started before the shell's first export still opens with the
fallback. `globinclude` is not usable here: it globs relative to the including
file's directory, and kitty 0.47's Python refuses an absolute pattern, which
aborts loading the configuration.

Reload sends `SIGUSR1`, which makes kitty re-read its configuration and every
include, to the user's GUI kitty processes:
`pkill --signal USR1 --uid <uid> --full --exact '([^ ]*/)?kitty( \+open)?( [^+@].*)?'`.
The command-line match mirrors kitty's own `is_kitty_gui_cmdline()`; a plain
`pkill -x kitty` would also hit Python kittens (`kitty +runpy …`), which
SIGUSR1 terminates. No running kitty (pkill status 1) is not an error. kitty's
`auto_reload_config` watcher does not help: it watches only the top-level
`kitty.conf`.

User colours win when they come later: put them in `~/.config/kitty/kitty.conf`
after the `CYBEXOS MANAGED INCLUDE` block.

### Hyprland

(Target not yet documented.)

### GTK

`scripts/theme_gtk.py` sets three `org.gnome.desktop.interface` keys with
`gsettings`, and records them in `gtk.json`:

| Key | Value |
| --- | --- |
| `color-scheme` | `prefer-dark` or `prefer-light`, from `mode` |
| `gtk-theme` | `adw-gtk3-dark` or `adw-gtk3` (package `adw-gtk3-theme`), so GTK 3 applications match libadwaita ones |
| `accent-color` | the libadwaita accent (GNOME 47) nearest to `colors.accent` by hue; an accent with too little colour for a hue becomes `slate`. Skipped when the installed schema has no such key |

Running GTK 3 and libadwaita applications follow the change, and so do
Firefox, Chromium and Electron applications, which read the same keys through
the settings portal (xdg-desktop-portal-gtk). `gtk.json` is only the record of
what was last applied: the keys are set again only when it changes, so after
changing one by hand run `cybexos-runtime ipc theme apply` to restore the
shell's values.

The shell owns these keys. The converge only gives a key still at its schema
default (`color-scheme` `default`, `gtk-theme` `Adwaita`) the dark default a
fresh install's first session shows until the shell has applied its tokens,
so re-running Ansible never undoes a choice made in Settings.

`GTK_THEME` is no longer set in `~/.config/environment.d`: it overrides
`gtk-theme` for GTK 3 and forces libadwaita's stylesheet, so no mode change
could reach either. The user manager lingers and read that file when it
started, so the converge also removes the old `GTK_THEME=adw-gtk3-dark` from
it; the shell and the applications it starts lose the variable at the next
login (or `systemctl --user restart quickshell.service`). Until then those
applications stay dark whatever the mode.

### Lock screen (hyprlock)

(Target not yet documented.)

## Adding a target

A target is a `scripts/theme_<name>.py` module listed in `TARGETS` in
`theme-apply.py`, with `NAME`, a deterministic `render(tokens)` returning
`{file name: content}` (at least one file), and `reload(tokens, directory)`,
which raises with a short, readable message on failure. Reload commands must be
resolved through `PATH`: the tests run every target with a PATH of stub
commands, so they can never signal or reconfigure the real desktop.
