# Shared shell appearance

Settings → Appearance owns the base font size (10–24 logical pixels), UI scale
(75–200%), font family, accessibility text scale, spacing density and panel
borders/corners. These feed native panels, notifications, launcher and the
Omarchy compatibility components. Bar corner geometry remains separately
configurable; panel corners no longer inherit the bar radius. Attached drawers
and sheets use the same radius on all four corners, without square edge
overrides or concave bridges to the bar.

`Common/ShellMetrics.js` calculates a rounded effective font size once from
base size × UI scale × accessibility scale. Typography uses this size relative
to a 12px reference. Geometry and padding additionally multiply by density
(Compact 0.92, Default 1, Comfortable 1.16). Compact changes geometry without
shrinking text. Panel widths track that shared geometry scale without the old 115% cap and
clamp to output bounds. The launcher reduces its scrolling results viewport
when vertical space is limited. Settings fields and narrow rows grow with text.
Qt/Wayland alone applies output device scaling; these are logical pixels.

Omarchy Style receives the same effective font and density, plus the optional
plugin scale. Advanced Omarchy tokens can intentionally diverge from the shared
settings. Existing explicit plugin border overrides remain valid; choose
**Shell** under Settings → Plugins to inherit shared surface borders.

The default and both **Omarchy** and **Cybex** presets select JetBrainsMono Nerd
Font, a 12px base font, 100% UI scale,
standard spacing, accent borders (2px, fully opaque) and 16px panel corners.
Both reset plugin appearance overrides and preserve text accessibility size,
accounts, plugin enablement, wallpaper/palette and bar layout. The eight-second
Undo action restores every preference changed by the preset.

The shared library and usage rules are documented in [Shell typography](shell-typography.md).

Typography follows [Omarchy's default scale](https://github.com/omacom/omarchy/blob/quattro/default/themed/shell.toml.tpl)
and [default monospace family](https://github.com/omacom/omarchy/blob/quattro/default/fontconfig/conf.avail/50-omarchy.conf):
10px captions, 11px secondary copy, 12px body/control/bar text, 14px titles,
16px headings, and 24/28px display values. Settings labels, inputs, pickers,
and actions use the same body role as plugin controls. Regular copy uses
weight 400; headings can use medium, semibold or bold.

Native body/caption and plugin body/caption share the same reference sizes.
Other semantic roles (headings and hero values) can have distinct sizes
while deriving from that common scale. Fixed-format numerical content follows
the monospace family when the monospace preset is selected.

## Verification

The appearance unit matrix covers all density/accessibility combinations,
base-font and UI-scale boundaries, output width clamping, preset persistence,
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
custom border color/opacity, light/dark updates and both presets against the
same Model Usage data. Launcher, Settings, audio and notification surfaces
were checked live, including enlarged text with comfortable spacing. Both
connected outputs used 2× device scaling; fractional output scaling was not
tested live. The isolated QML lifecycle test was skipped while the managed
desktop was active; managed-service checks confirmed a single Quickshell
process and no QML errors in its current invocation.
