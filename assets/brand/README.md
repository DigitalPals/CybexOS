# Cybex OS artwork

The master is [source/cybex_white.svg](source/cybex_white.svg), supplied by the
project owner in `cybex_white.zip`. Its bytes are unchanged (SHA-256
`8c3adcb92102d29f08f25d5c63d8f402afb0c789708d88e27291b5bbb3f4e0b5`).

Deployment artwork uses the same outlined paths with the original red accent
(`#DC1E37`). Interface controls use blue independently. Small
icons use the two paths forming the X in the supplied wordmark, with a square
viewBox and clear space. No font is required to display the artwork.

`scripts/export-brand.py` exports the logo, icons, favicons, terminal art,
installer and Plymouth/ISO images, plus a SHA-256 manifest of deployed assets.
It requires Python with Pillow and `rsvg-convert` from the locked Nixpkgs.
See [USAGE.md](USAGE.md) for the palette and intended uses.
