# NerdOS identity — usage guide

**NerdOS** (formerly CybexOS) · **OS = Opinionated System** · nerdos.org

The mark is a pair of chunky, softly rounded glasses with a strip of repair tape across the bridge.
The glasses carry the identity on their own; the lime tape is the single accent.

---

## 1. Logo versions

| Version | File | Use |
|---|---|---|
| Horizontal logo | `logo/svg/nerdos-logo-*.svg` | Default. Website header, docs, slides, packaging |
| Horizontal + descriptor | `logo/svg/nerdos-logo-descriptor-*.svg` | Where the name needs explaining: landing hero, installer, press |
| Glasses symbol | `symbol/svg/nerdos-symbol-*.svg` | Avatars, stickers, boot splash, loading states, anywhere the name is already present |
| App icon | `app-icon/svg/nerdos-app-icon-*.svg` | Launchers, docks, stores, social avatars |
| Favicon set | `favicon/` | Browser tabs, bookmarks, home-screen installs |
| ASCII | `ascii/` | fastfetch, MOTD, terminal splash, README headers |

Each graphic version comes in four colourways:

| Suffix | Ink | Tape | Background it is made for |
|---|---|---|---|
| `on-light` | Charcoal | Lime | Off-white, white, light greys |
| `on-dark` | Off-white | Lime | Charcoal, black, dark photos |
| `mono-black` | Black | Black | One-colour print, fax, embossing, laser etching |
| `mono-white` | White | White | One-colour reversed, dark single-colour print |

In one-colour versions the tape is drawn in the ink colour and separated from the frames by a thin knockout gap,
so it still reads as tape. The mono files can be recoloured to any single solid colour.

App icons come as rounded tiles (`*-{dark,light,mono-black,mono-white}.svg`) and as full-bleed squares
(`*-square.svg`) for platforms that apply their own mask.

## 2. Colour

| Name | Hex | RGB | Role |
|---|---|---|---|
| **Charcoal** | `#1A1B1E` | 26 27 30 | Primary ink on light; primary background on dark |
| **Off-white** | `#F3F2EC` | 243 242 236 | Primary background on light; ink on dark |
| **Electric lime** | `#C8FF1F` | 200 255 31 | The tape. Accent only |
| Graphite | `#5A5C61` | 90 92 97 | Secondary text on light |
| Fog | `#A6A8A1` | 166 168 161 | Secondary text on dark |
| Lime deep | `#4A7300` | 74 115 0 | Lime-family text/links on light backgrounds (5:1 on off-white) |

Rules:

* Lime is a highlight, not a fill. Keep it to roughly 5–10% of any layout. It belongs on the tape, on
  focus states, and on small accents against charcoal.
* Never set lime text on off-white or white: contrast is about 1.05:1. Use **Lime deep** for lime-family text on light grounds.
* Lime on charcoal is about 15:1, so it is fine for text and UI on dark grounds.
* No gradients, glows or shadows on the mark.

Print: electric lime sits outside the CMYK gamut. For print, match a spot (or fluorescent) ink to the hex by eye
with your printer, or accept a slightly duller green in process colour. Charcoal prints well as a rich black.

## 3. Typography

| Role | Typeface | Notes |
|---|---|---|
| Wordmark | Space Grotesk Bold, customised | Emboldened ~2.4% of em on stems, optically re-spaced. Always use the outlined SVG; never retype the wordmark |
| Descriptor | JetBrains Mono Bold, uppercase | Tracked +90, justified to the wordmark width |
| Headlines (UI, web, slides) | Space Grotesk 600–700 | Tight tracking (−1% to −2%) at large sizes |
| Body | Space Grotesk 400 / system UI | 16 px minimum on the web |
| Code, terminal, labels | JetBrains Mono 400–700 | Same family as the descriptor and the ASCII art |

Both families are open-source (SIL Open Font License) and available on Google Fonts.

## 4. Construction, clear space and alignment

* **X** = the frame thickness of the glasses at the size used.
* **Clear space:** keep at least **2X** free on every side of every lockup and of the symbol. Nothing (text, edges,
  other logos) enters that zone.
* The glasses frame height is **1.22 × the cap height** of the wordmark. The gap between symbol and wordmark is
  **0.46 × cap height**. The glasses are centred on the cap height (or on the text block when the descriptor is present).
* Don't rebuild lockups by hand; use the supplied SVGs.

## 5. Minimum sizes

| Asset | Digital | Print |
|---|---|---|
| Horizontal logo | 96 px wide | 20 mm wide |
| Horizontal + descriptor | 200 px wide | 40 mm wide |
| Glasses symbol (master) | 24 px wide | 8 mm wide |
| Glasses symbol, below 24 px | use `symbol/svg/small/` 16 px / 32 px hinted versions | — |
| App icon | 32 px; under 48 px use the hinted favicon tiles | 10 mm |

Below these sizes, switch to the next simpler version: horizontal logo → symbol → hinted favicon.

## 6. Favicons and web app icons

Copy everything in `favicon/` to the web root of nerdos.org and paste `favicon/head-snippet.html` into `<head>`:

```html
<link rel="icon" href="/favicon.ico" sizes="32x32">
<link rel="icon" href="/favicon.svg" type="image/svg+xml">
<link rel="apple-touch-icon" href="/apple-touch-icon.png">
<link rel="manifest" href="/site.webmanifest">
<meta name="theme-color" content="#1A1B1E">
```

* `favicon.svg` is drawn on a 32 px grid and switches automatically: charcoal glasses on light tabs, off-white on
  dark tabs (`prefers-color-scheme`).
* `favicon.ico` holds pixel-hinted 16, 32 and 48 px charcoal tiles that read on any tab colour.
* `apple-touch-icon.png` (180 px) is opaque and full-bleed; iOS rounds the corners.
* `icon-192.png` / `icon-512.png` are rounded tiles for the manifest's `any` purpose.
* `icon-maskable-192.png` / `icon-maskable-512.png` are full-bleed, with the glasses inside the central 80% safe circle.

## 7. ASCII

See `ascii/README.md`. Frames and lettering use `$1`, the tape uses `$2` (lime). On light terminals switch
`$1` to charcoal and `$2` to Lime deep (`#4A7300`).

## 8. Don't

* Don't add eyes, faces, pupils or reflections to the lenses.
* Don't fill the lenses.
* Don't change the tape colour, angle or position, and don't add more tape.
* Don't rotate, skew, outline or add effects (gradients, shadows, glows) to the mark.
* Don't place the colour logo on busy photos or mid-tone backgrounds; use mono or a solid charcoal/off-white panel.
* Don't use the lime as a background behind the full-colour logo.
* Don't typeset "NerdOS" in another font to imitate the wordmark. In running text, write **NerdOS** (capital N, capital O, capital S).

## Package contents

```
logo/       horizontal logo ± descriptor · SVG masters + PNG (512/1024/2048 px wide)
symbol/     glasses symbol · SVG + PNG (128–1024) · small/ hinted 16 & 32 px masters
app-icon/   rounded tile + full-bleed square · dark, light, mono-black, mono-white · SVG + PNG (64–1024)
favicon/    favicon.svg, favicon.ico (16/32/48), apple-touch-icon, 192/512 + maskable, webmanifest, head snippet
ascii/      compact, large, banner · plain + fastfetch placeholder versions · fastfetch config · colour guide
_concepts/  the three explored directions (A Tape Job — selected; B Browline; C Pixel)
```

All SVGs are outlined (no live text, no font dependency), use named layers (`symbol` › `frames`, `tape`,
`wordmark`, `descriptor`), and have transparent backgrounds unless they are app icons.
Fonts: Space Grotesk and JetBrains Mono, SIL Open Font License 1.1.
