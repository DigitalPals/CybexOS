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
