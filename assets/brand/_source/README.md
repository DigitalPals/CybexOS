# Regenerating the NerdOS assets

Everything in this package is generated from `brand.py` (geometry, colours, lockup ratios), so a change
there — tape angle, frame thickness, a colour — flows into every SVG, PNG, favicon and icon.

```sh
npm i @fontsource/space-grotesk @fontsource/jetbrains-mono      # font outlines (SIL OFL)
pip install fonttools brotli uharfbuzz skia-pathops resvg-py pillow
export FONTSOURCE_DIR=node_modules/@fontsource NERDOS_OUT=build/nerdos-brand
python3 export.py          # logo / symbol / app-icon / favicon
python3 ascii_export.py    # ascii/ (hand-drawn art lives in this file)
```

* `geo.py` — rounded rects, boolean ops (Skia path ops), SVG path output
* `glyphs.py` — HarfBuzz shaping + fontTools outlines for the wordmark and descriptor
* The 16/32/48 px favicons are hand-hinted pixel drawings (`symbol_px16`, `symbol_px32`, `tile_hinted`), not scaled masters.
