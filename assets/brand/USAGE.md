# Cybex OS identity

Write **Cybex OS** in interface text and documentation. Repository and machine
identifiers use `CybexOS` / `cybexos`, environment variables use `CYBEXOS_`, and
the user command is `cybex`.

Use `logo/svg/cybexos-logo-on-dark.svg` for the installer, welcome, lock and
about screens. Use the light variant on white backgrounds. Preserve the
wordmark's aspect ratio. For small menubar, assistant and application icons,
use the X from `symbol/svg/` rather than squeezing the whole wordmark.

| Role | Colour |
| --- | --- |
| Logo accent, matching the supplied SVG | Red `#DC1E37` |
| Primary accent, selected items, focus and progress | Blue `#60A5FA` |
| Hover / pressed | `#93C5FD` / `#3B82F6` |
| Accent text on light backgrounds | `#1D4ED8` |
| Text on blue controls and dark backgrounds | Charcoal `#1A1B1E` / off-white `#F3F2EC` |

Primary blue controls use charcoal text for readable contrast. The attached
master and coloured deployment copies retain the original red logo accent,
independent of the interface accent. Do not distort the paths or replace the
outlined lettering with a typed approximation. Desktop wallpaper palettes and
semantic warning, error and success colours remain independently configurable.
