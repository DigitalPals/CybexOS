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

The seven native wallpapers and three responsive web variants are original
procedural landscapes. `python3 -B scripts/generate-wallpapers.py` recreates
them from geometric shapes using Python's standard library, without input
images, downloaded assets, or generative image services. `--check` compares all
rendered pixels and recorded artifact digests/provenance; zlib implementations
can encode identical pixels into different PNG bytes. `assets/PROVENANCE.json` records every native and web
wallpaper regardless of size, its dimensions, byte digest, generator digest,
palette and authorship method. Newly authored files do not claim a historical
introduction commit. These original assets use the repository's MIT license.

The former undocumented bundled JPEGs and web derivatives have been removed
from the distributable tree. Installers copy new wallpapers only when absent
and retain saved selections and user-owned files, including earlier wallpapers
already in a user's home. This replacement does not rewrite Git history or
assert rights in earlier distributions.

`tests/repository-policy.py` verifies complete native/web wallpaper coverage,
checksums and generator identity. This is distinct from the owner review of
other third-party software and marks needed for public distribution.

## Redistribution audit

[The redistribution audit](licensing-audit.md) inventories the third-party
packages, applications, fonts, wallpapers, marks, and firmware in each release
channel, records what could and could not be verified, and lists the blockers
before a public ISO. It is an engineering inventory for owner and legal review,
not a legal opinion. Public publication additionally requires a channel-specific,
reviewed distribution manifest bound to the actual artifact inventories; see
[the distribution review process](licensing-audit.md#public-distribution-gate).
Internal builds, fixture tests and ISO qualification remain available while
review is unresolved.

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
