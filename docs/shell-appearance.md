# Shared shell appearance

Settings → Appearance owns the font family, text size, interface scale
(75–200%), density and panel borders/corners; the base font size (10–24
logical pixels) sits under **Advanced text options**. These feed native panels, notifications, launcher and the
Omarchy compatibility components. Bar corner geometry remains separately
configurable; panel corners no longer inherit the bar radius. Attached drawers
and sheets use the same radius on all four corners, without square edge
overrides or concave bridges to the bar.

The **Text & size → Interface font** dropdown is near the top of Appearance,
draws each family in its own face, and can also be reached by searching for
“font”. A preview above it shows the size text renders at. It includes the current default,
JetBrainsMono Nerd Font, and applies immediately across the shell. The installer
ships every offered family: JetBrainsMono Nerd Font, Figtree, Google Sans Flex,
Urbanist, OPPO Sans 4.0 and IBM Plex Sans. System/browser fallbacks include
Liberation Sans, Serif and Mono, the full Noto family, CJK, emoji, Font Awesome
and iA Writer (Mono, Duo, Quattro and Duospace), matching Omarchy’s base font
coverage. These use the managed
Fontconfig defaults independently of the shell font choice.

Dark or light mode, the palette, the accent, the font and the text size also
reach the desktop outside the shell: the terminal, window borders, GTK
applications and the lock screen follow them (see
[System theme](system-theme.md)).

## Themes

A theme is a named set of appearance choices applied in one step: dark or
light, the accent and where it comes from, the bar colour, optionally a font
and a wallpaper, and optionally its own palette — background, panel and menu
surfaces, three text tones, and red, amber and green. **Theme** is the first
row of Settings → Appearance. Its dropdown previews every theme in three dots
(base, accent, text); picking one applies it at once, with the footer's Undo
for eight seconds. Changing anything a theme set afterwards (the mode, the
accent, the bar colour…) shows it as “Nord (modified)”; settings that match no
theme show “Custom”. A fresh installation shows **CybexOS**, the default look,
and existing settings are untouched until a theme is picked. The row's reset
returns every value a theme sets to that default; the wallpaper stays.

The save button beside the dropdown opens **Theme name**: **Save** stores the
current mode, colours, bar and font as a user theme and selects it. The
wallpaper is not included.

Built-in themes ship with the shell runtime (`themes/` beside `scripts/`):
CybexOS, Catppuccin Latte and Mocha, Everforest, Gruvbox, Kanagawa, Nord,
Rosé Pine and Tokyo Night, from their published MIT-licensed palettes (see
[Licensing](licensing.md#built-in-theme-palettes)). User themes live in
`~/.local/share/cybexos/themes/<id>/`, a user-owned root that updates never
prune ([ownership](architecture/ownership.md)); a theme folder added or
removed there by hand appears in the dropdown without a restart.

### Palettes and readability

Applying a theme copies its palette into the settings (`themePalette`), so the
look loads with the shell and survives the theme's removal. `Common/Theme.qml`
draws it only while its mode is the shell's mode and the accent source is
Fixed; switching to the wallpaper palette or the other mode falls back to the
shell's own references. Colours a theme leaves out are derived from the ones
it sets. The shell's floors still apply to every theme: panel surfaces are
held to their mode (7.5:1 against white in dark mode, 9:1 against black in
light mode), primary text to 7:1 and every quieter tone, status colour and
the accent's text to 4.5:1 against the theme's least favourable backdrop. A
theme's own colours are kept wherever they already read; the floors only lift
the others (`SettingsHelpers.themeTextPalette`, tested against every
built-in theme and a sweep of random palettes).

### Sharing themes

```bash
cybex theme list [--json]                  # built-in and user themes
cybex theme apply nord                     # apply now, or at the next shell start
cybex theme install ~/Downloads/harbour    # a folder, .tar.gz/.zip, or https:// Git URL
cybex theme install https://github.com/someone/harbour-theme
cybex theme export nord ~/Desktop          # writes ~/Desktop/nord/
cybex theme export CURRENT ~/share.tar.gz --name "Night shift"
cybex theme remove harbour                 # user themes only
```

`apply` hands the running shell the theme over its `theme` IPC target
(`cybexos-runtime ipc theme use …`), where it is checked against the settings
schema again and applied with Undo. Without a running shell it writes the same
values to `~/.config/cybexos/shell.json` through the shell's own transactional
writer, keeping every other value and refusing a file from a newer release.
`export CURRENT` describes the current appearance and includes the current
wallpaper; exporting a theme includes its own wallpaper, if it has one.

A theme is data only:

```json
{
  "schema": 1,
  "name": "Harbour",
  "mode": "dark",
  "accent": "#5e81ac",
  "bar": "#202830",
  "font": "plex",
  "palette": {"background": "#202830", "surface": "#28323c", "text": "#e6ecf2"},
  "wallpaper": "harbour.jpg",
  "author": "Someone", "license": "CC-BY-4.0", "source": "https://example.com"
}
```

`name`, `mode` and `accent` are required. `accentSource` is `fixed` (the
default) or `wallpaper`, which takes no palette. `bar` is a Bar page preset
(`default`, `macos`, `black`, `graphite`, `slate`, `white`), a `#rrggbb` colour
or `{"hue", "saturation", "lightness"}`; `font` is a shell font id (`figtree`,
`google`, `urbanist`, `oppo`, `plex`, `mono`). `palette` takes `background`,
`surface`, `surfaceRaised`, `text`, `textMuted`, `textDim`, `red`, `amber` and
`green`. `id` defaults to one made from the name. Unknown keys are refused.

`install` is deliberately strict. A theme holds `theme.json` and the one PNG,
JPEG or WebP image it names, checked by content; a README, LICENSE or
`.gitignore` beside them is tolerated and not copied. Anything else — scripts,
QML, other dotfiles, folders, symbolic or hard links, device files, paths that
leave the theme, submodules — refuses the whole source, as do files over the
size limits (64 KiB for `theme.json`, 16 MiB for an image, 64 entries).
Archives are read member by member without extracting them. Git sources must
be `https://` URLs without credentials; the helper makes a shallow,
blob-less clone with hooks disabled and only https allowed, checks the whole
tree listing, and then reads the two files it needs with `git cat-file`, so
nothing from the repository is checked out. The installed folder records its
source in `.source.json` (the URL and commit for Git). An existing user theme
is replaced only with `--replace`; a built-in id cannot be taken.

The command is `assets/scripts/cybexos-theme` on both installation paths
(`~/.local/bin` on a checkout, `/usr/share/cybexos/bin` from the RPM). It
runs the active runtime's `scripts/theme-packs.py`, which Settings uses too,
so the schema and the theme-to-settings mapping (`theme_packs.settings_patch`)
exist once.

Fresh installations leave **System tray** disabled. Add it from Settings →
Bar when wanted; existing saved widget choices are preserved.

`Common/ShellMetrics.js` calculates a rounded effective font size once from
base size × interface scale × accessibility (text size) scale. Typography uses this size relative
to a 12px reference. Geometry and padding additionally multiply by density
(Compact 0.92, Default 1, Comfortable 1.16). Compact changes geometry without
shrinking text. Panel widths track that shared geometry scale without the old 115% cap and
clamp to output bounds. The launcher reduces its scrolling results viewport
when vertical space is limited. Settings fields and narrow rows grow with text.
Qt/Wayland alone applies output device scaling; these are logical pixels.

Omarchy Style receives the same effective font and density, plus the optional
plugin scale. Advanced Omarchy tokens can intentionally diverge from the shared
settings. Existing explicit plugin border overrides remain valid; choose
**Shell** under Settings → Appearance → Omarchy plugins to inherit shared
surface borders.

The defaults use Dark mode, a Hug bar, wallpaper colors, opaque surfaces and
numbered workspaces. Typography uses JetBrainsMono Nerd Font at 14px, 100% UI
scale and standard spacing. Panels have 16px corners and no border (width 0);
plugins inherit the shared appearance. Appearance has no preset actions.
Existing saved preferences remain in effect; section resets use these defaults.
New ISO-installed accounts explicitly seed the same JetBrainsMono font choice.
Empty or older settings without a font also inherit this default; the historical
Google Sans migration applies only to a stored pre-schema-7 Urbanist value.

The shared library and usage rules are documented in [Shell typography](shell-typography.md).

Typography derives from [Omarchy's scale](https://github.com/omacom/omarchy/blob/quattro/default/themed/shell.toml.tpl)
and [default monospace family](https://github.com/omacom/omarchy/blob/quattro/default/fontconfig/conf.avail/50-omarchy.conf),
with a larger default base: 12px captions, 13px secondary copy,
14px body/control/bar text, 16px titles, 18px headings, and 28/33px display
values. The heading multiplier is tuned to 18px at the new base.
Settings labels, inputs, pickers and actions use the same body role as plugin
controls. Regular copy uses
weight 400; headings can use medium, semibold or bold.

Native body/caption and plugin body/caption share the same reference sizes.
Other semantic roles (headings and hero values) can have distinct sizes
while deriving from that common scale. Fixed-format numerical content follows
the monospace family when the monospace font is selected.

## Verification

The appearance unit matrix covers all density/accessibility combinations,
base-font and UI-scale boundaries, output width clamping, settings persistence,
shared/plugin border precedence and one-time opacity application. Existing
launcher, Settings and notification contracts check their scalable controls
and bounds. Live checks use `tests/lib/quickshell-live` around the managed
service and compare `shell debugPluginTheme` with screenshots of the same
Model Usage tab/data, native Settings, popovers and a local test notification.
The diagnostic reports native and plugin body, caption, title, heading and
display sizes so their equality can be checked directly. No second live
Quickshell process is needed.

Validated on 2026-09-21: the full repository gate passed, including 744 unit
tests. Live checks passed all nine density/accessibility combinations, shared
custom border color/opacity, light/dark updates and the then-available presets against the
same Model Usage data. Launcher, Settings, audio and notification surfaces
were checked live, including enlarged text with comfortable spacing. Both
connected outputs used 2× device scaling; fractional output scaling was not
tested live. The isolated QML lifecycle test was skipped while the managed
desktop was active; managed-service checks confirmed a single Quickshell
process and no QML errors in its current invocation.
