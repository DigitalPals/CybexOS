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

`theme_hyprland.py` renders `hyprland.lua`: a data-only `return { ... }` of
`hl.config` colours.

| Key | Colour |
| --- | --- |
| `general.col.active_border`, `inactive_border` | `accent`, `stroke` |
| `group.col.border_active`, `border_inactive` | `accent`, `stroke` |
| `group.col.border_locked_active`, `border_locked_inactive` | `red`, `stroke` |
| `group.groupbar.col.active`, `inactive`, `locked_active`, `locked_inactive` | `accent`, `stroke`, `red`, `stroke` |
| `group.groupbar.text_color`, `text_color_locked_active` | `text` |
| `group.groupbar.text_color_inactive`, `text_color_locked_inactive` | `textMuted` |
| `decoration.shadow.color` | dark: `background` at 0xee; light: `text` at 0x30 |

Window borders are 0 px in the vendor look, so their colours only show once
`user.lua` sets a `border_size`. Rounding is not a theme value: it stays 16 px
to match `Theme.surfaceRadius`, whatever the panel corner setting. Blur, the
glass layer rule and power saver are untouched.

`looknfeel.lua` applies the file right after its vendor `hl.config`, whose
colours are this renderer's output for the default dark tokens (a test keeps
them equal). A missing file keeps those colours. The file is read as text,
loaded in an empty environment and checked key by key: a syntax error, a call,
a value that is not `rgb(rrggbb)`/`rgba(rrggbbaa)` or an oversized file leaves
the vendor colours in place and is reported by

```bash
hyprctl repl 'return __cybexos_system_theme.error'
```

Keys the compositor config does not know are ignored, so a newer renderer never
costs an older config the whole theme.

A theme change reaches the running compositor through
`hyprctl eval 'cybexos_system_theme("<state dir>/hyprland.lua")'`, which
applies the same checks and raises instead of half-applying. Without
`HYPRLAND_INSTANCE_SIGNATURE` reload does nothing and the next compositor start
reads the file. A full `hyprctl reload` was rejected: it re-reads glass from
the saved setting (turning blur back on under high contrast), drops an
unconfirmed display arrangement, and would run on every wallpaper change in
wallpaper mode.

**`user.lua` keeps winning.** It loads after `looknfeel.lua`, so at config load
its colours override the theme's. For the live path, `looknfeel.lua` records
what each theme key holds (`hl.get_config`) straight after it applies the
theme, before `user.lua` runs. A live change applies a key only if it still
holds that value; a key that `user.lua` — or a manual `hyprctl eval` — has set
since is left alone until the next config reload, which takes a fresh
baseline. A user value identical to the theme's is indistinguishable from it
and follows the theme.

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
