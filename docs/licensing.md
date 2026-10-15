# Licensing and asset provenance

The repository's original code and configuration are licensed under the MIT
License; see the repository-root `LICENSE`. That grant applies to CybexOS
copyrighted code and does not replace licenses or permissions for third-party
software, assets, product names, or marks included in a source archive, ISO, or
RPM.

## Third-party software and branding

Files copied or downloaded from other projects remain under their upstream
terms. In particular:

- pinned single-file fonts install their verified upstream license text beside
  the font;
- the OPPO Sans archive supplies its own font license agreement, which the role
  preserves beside the installation;
- the Cybex role checks out a pinned upstream artwork revision and then overlays
  repository-local theme files; and
- product names, logos, and brand SVGs may also be subject to trademark rules,
  independently of the MIT License.

A public source archive, desktop RPM, or ISO bundles more than original CybexOS
code. Complete and document the software and asset redistribution audit for the
actual release payload before public distribution. The MIT License does not
itself grant rights to redistribute third-party packages, artwork, fonts,
wallpapers, or trademarks.

## Repository assets

The bundled wallpaper collection is installed into `~/Pictures/Wallpapers`.
The installer selects the mountain wallpaper when no wallpaper is configured,
while preserving existing wallpaper selections and custom folders.

`assets/PROVENANCE.json` records the bundled images, their checksums, and the
available provenance. Unknown creator, source, and license fields remain
explicitly unset. `tests/repository-policy.py` verifies the inventory, file
sizes, and checksums; it does not establish or grant redistribution rights.

## Redistribution audit

[The redistribution audit](licensing-audit.md) inventories the third-party
packages, applications, fonts, wallpapers, marks, and firmware in each release
channel, records what could and could not be verified, and lists the blockers
before a public ISO. It is an engineering inventory for owner and legal review,
not a legal opinion.

## Built-in theme palettes

The [built-in themes](shell-appearance.md#themes) under
`roles/desktop/files/quickshell/themes/` are data files: the colour values
of published palettes, mapped onto the shell's roles, with no code, artwork
or images from those projects. Each `theme.json` names its source in its
`author`, `license` and `source` fields; `tests/theme-packs.py` requires an
MIT license and an https source for every built-in theme.

| Theme | Palette | Author | License | Source |
| --- | --- | --- | --- | --- |
| CybexOS | The shell's own defaults | CybexOS | MIT | this repository |
| Nord | Polar Night, Snow Storm, Frost, Aurora | Arctic Ice Studio and Sven Greb | MIT | <https://github.com/nordtheme/nord> |
| Gruvbox | gruvbox dark (medium) | Pavel Pertsev | MIT | <https://github.com/morhetz/gruvbox> |
| Tokyo Night | Tokyo Night (night) | Enkia | MIT | <https://github.com/enkia/tokyo-night-vscode-theme> |
| Catppuccin Mocha | Mocha | Catppuccin | MIT | <https://github.com/catppuccin/palette> |
| Catppuccin Latte | Latte | Catppuccin | MIT | <https://github.com/catppuccin/palette> |
| Rosé Pine | Rosé Pine (main) | Rosé Pine | MIT | <https://github.com/rose-pine/palette> |
| Everforest | Everforest dark (medium) | Sainnhe Park | MIT | <https://github.com/sainnhe/everforest> |
| Kanagawa | Kanagawa wave | Tommaso Laurenzi | MIT | <https://github.com/rebelot/kanagawa.nvim> |

Where a palette has no colour for a role (Rosé Pine has no green; it uses
foam), the nearest named colour of the same palette is used. Roles a theme
leaves out are derived by the shell and are not part of the upstream palette.
Theme names identify the palettes they reproduce; they are their projects'
names, used descriptively. User themes installed with `cybex theme install`
keep their own license terms; the installer records where each came from but
does not establish redistribution rights.
