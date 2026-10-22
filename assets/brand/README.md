# NerdOS artwork

The supplied NerdOS identity package is preserved here unchanged, including SVG
masters, outlined lettering, hinted small icons, ASCII art, usage rules and
generators. Read [USAGE.md](USAGE.md) before using a mark. NerdOS means the
**Opinionated System**, at **nerdos.org**.

Deployment copies from the rename kit:

| Destination | Kit source |
| --- | --- |
| `desktop/plymouth/logo{,@2x}.png` | `derived/plymouth/` |
| `desktop/quickshell/assets/nerdos{,-white}.svg` | `derived/quickshell/` |
| `desktop/icons/hicolor/` | `derived/hicolor/` |
| `desktop/fastfetch/` | `derived/fastfetch/` |
| `web/public/nerdos-logo.svg` | `derived/welcome/nerdos-logo.svg` |
| `web/public/nerdos{,-white}.svg` | `derived/quickshell/` |
| `web/public/` favicons and manifest | `derived/web/`, excluding the example HTML snippet |

Nix packages install the boot theme, hicolor icons, fastfetch files and canonical
brand sources. The same shared module selects them for the ISO and installed
system. No Fedora/Cockpit welcome or new-owner window exists in this NixOS tree;
the terminal installer and browser welcome carry the identity.

These marks are original project artwork supplied in October 2026, under the
repository MIT license. Space Grotesk and JetBrains Mono lettering is outlined
from SIL OFL 1.1 fonts; these SVGs have no live-text/font dependency. Their font
copyright and licence notices are in `FONT-LICENSES/`.
Trademark clearance for **NerdOS** remains an owner task.
