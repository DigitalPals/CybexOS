# Licensing and asset provenance

There is currently no repository-root `LICENSE` or `COPYING` file. Repository
visibility and a Git commit history do not themselves grant permission to copy,
modify, or redistribute the original configuration code. This document records
that boundary; it does not choose a software license on the owner's behalf.

## Repository code and configuration

The owner must choose the intended terms, confirm that every contributor can
license their contribution on those terms, and add the corresponding canonical
license text at the repository root. If different directories need different
terms, add unambiguous per-directory notices and a root summary. Until then,
downstream users should not infer an open-source license.

Files copied or downloaded from other projects remain under their upstream
terms. In particular:

- pinned single-file fonts install their verified upstream license text beside
  the font;
- the OPPO Sans archive supplies its own font license agreement, which the role
  preserves beside the installation;
- the Cybex role checks out a pinned upstream artwork revision and then overlays
  repository-local theme files; and
- product names, logos, and brand SVGs may also be subject to trademark rules,
  independently of any software license eventually selected here.

A repository-wide software license must not be presented as relicensing those
third-party materials.

## Repository assets

The bundled wallpaper collection is installed into `~/Pictures/Wallpapers`.
The installer selects the mountain wallpaper when no wallpaper is configured,
while preserving existing wallpaper selections and custom folders.

`assets/PROVENANCE.json` records the bundled images, their checksums, and the
available provenance. Unknown creator, source, and license fields remain
explicitly unset. `tests/repository-policy.py` verifies the inventory, file
sizes, and checksums; it does not establish or grant redistribution rights.
