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

(Target not yet documented.)

### Lock screen (hyprlock)

(Target not yet documented.)

## Adding a target

A target is a `scripts/theme_<name>.py` module listed in `TARGETS` in
`theme-apply.py`, with `NAME`, a deterministic `render(tokens)` returning
`{file name: content}` (at least one file), and `reload(tokens, directory)`,
which raises with a short, readable message on failure. Reload commands must be
resolved through `PATH`: the tests run every target with a PATH of stub
commands, so they can never signal or reconfigure the real desktop.
