"""Build the complete NerdOS brand package into out/nerdos-brand/."""
import io, os, json, shutil, struct
import resvg_py
from PIL import Image
from brand import *

OUT = os.environ.get("NERDOS_OUT", "build/nerdos-brand")
shutil.rmtree(OUT, ignore_errors=True)


def mk(*p):
    path = os.path.join(OUT, *p)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    return path


def png(svg, w=None, h=None):
    return Image.open(io.BytesIO(bytes(resvg_py.svg_to_bytes(svg_string=svg, width=w, height=h)))).convert("RGBA")


def r2(v):
    s = f"{v:.2f}".rstrip("0").rstrip(".")
    return "0" if s in ("-0", "") else s


def normalize(paths, box=None):
    """Translate a dict of paths so the art box starts at 0,0. Returns (paths, w, h)."""
    keys = [k for k, v in paths.items() if hasattr(v, "draw")]
    x0, y0, x1, y1 = box or bounds(union(*[paths[k] for k in keys]))
    out = {k: xform(paths[k], move(-x0, -y0)) for k in keys}
    return out, x1 - x0, y1 - y0


def svg_file(layers, w, h, title, desc=None, extra_head=""):
    """layers: list of (id, fill, path|[(id, path)])"""
    body = []
    for lid, fill, p in layers:
        if isinstance(p, list):
            inner = "".join(f'<path id="{i}" d="{d(pp)}"/>' for i, pp in p)
            body.append(f'  <g id="{lid}" fill="{fill}">{inner}</g>')
        else:
            body.append(f'  <path id="{lid}" fill="{fill}" d="{d(p)}"/>')
    dsc = f"<desc>{desc}</desc>" if desc else ""
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {r2(w)} {r2(h)}" width="{r2(w)}" height="{r2(h)}" '
            f'role="img" aria-labelledby="title">\n  <title id="title">{title}</title>{dsc}\n{extra_head}' + "\n".join(body) + "\n</svg>\n")


VARIANTS = {
    # name: (ink, tape)
    "on-light": (INK, LIME),
    "on-dark": (PAPER, LIME),
    "mono-black": (BLACK, BLACK),
    "mono-white": (WHITE, WHITE),
}

manifest = []


def save_svg(rel, text):
    p = mk(*rel.split("/"))
    open(p, "w").write(text)
    manifest.append(rel)
    return p


def save_png(rel, im):
    p = mk(*rel.split("/"))
    im.save(p, optimize=True)
    manifest.append(rel)
    return p


# ------------------------------------------------------------------ horizontal logos
for desc in (False, True):
    L = lockup(desc)
    keys = ["frames", "tape", "word"] + (["desc"] if desc else [])
    P, w, h = normalize({k: L[k] for k in keys})
    stem = "nerdos-logo-descriptor" if desc else "nerdos-logo"
    for vname, (ink, tape) in VARIANTS.items():
        layers = [("symbol", None, None)]
        layers = [("frames", ink, P["frames"]), ("tape", tape, P["tape"]), ("wordmark", ink, P["word"])]
        if desc:
            layers.append(("descriptor", ink, P["desc"]))
        # group the symbol for easy editing
        text = svg_file([], w, h, "NerdOS — Opinionated System" if desc else "NerdOS")
        sym = (f'  <g id="symbol">\n    <path id="frames" fill="{ink}" d="{d(P["frames"])}"/>\n'
               f'    <path id="tape" fill="{tape}" d="{d(P["tape"])}"/>\n  </g>\n'
               f'  <path id="wordmark" fill="{ink}" d="{d(P["word"])}"/>\n')
        if desc:
            sym += f'  <path id="descriptor" fill="{ink}" d="{d(P["desc"])}"/>\n'
        text = text.replace("</svg>\n", sym + "</svg>\n")
        save_svg(f"logo/svg/{stem}-{vname}.svg", text)
        for W in (512, 1024, 2048):
            save_png(f"logo/png/{stem}-{vname}-{W}.png", png(text, w=W))

# ------------------------------------------------------------------ symbol
S = symbol()
P, w, h = normalize(S)
for vname, (ink, tape) in VARIANTS.items():
    text = svg_file([], w, h, "NerdOS glasses symbol")
    text = text.replace("</svg>\n", f'  <g id="symbol">\n    <path id="frames" fill="{ink}" d="{d(P["frames"])}"/>\n'
                                    f'    <path id="tape" fill="{tape}" d="{d(P["tape"])}"/>\n  </g>\n</svg>\n')
    save_svg(f"symbol/svg/nerdos-symbol-{vname}.svg", text)
    for W in (128, 256, 512, 1024):
        save_png(f"symbol/png/nerdos-symbol-{vname}-{W}.png", png(text, w=W))

# small-size symbol masters (pixel-hinted, for 16 / 32 px use)
for n, fn in ((16, symbol_px16), (32, symbol_px32)):
    sp = fn()
    for vname, (ink, tape) in (("on-light", (INK, LIME)), ("on-dark", (PAPER, LIME))):
        text = svg_file([("frames", ink, sp["frames"]), ("tape", tape, sp["tape"])], n, n,
                        f"NerdOS glasses symbol, {n}px-hinted")
        save_svg(f"symbol/svg/small/nerdos-symbol-{n}px-{vname}.svg", text)
        save_png(f"symbol/png/small/nerdos-symbol-{n}px-{vname}.png", png(text, w=n))

# ------------------------------------------------------------------ app icons
APP = {
    "dark": (INK, PAPER, LIME),
    "light": (PAPER, INK, LIME),
    "mono-black": (BLACK, WHITE, WHITE),
    "mono-white": (WHITE, BLACK, BLACK),
}


def app_svg(bg, fg, tape, size=1024, inset=0.13, shape="tile", title="NerdOS app icon"):
    sp = symbol_tile(size, inset)
    base = sp["tile"] if shape == "tile" else sp["square"]
    return svg_file([("background", bg, base), ("frames", fg, sp["frames"]), ("tape", tape, sp["tape"])],
                    size, size, title)


for vname, (bg, fg, tape) in APP.items():
    t = app_svg(bg, fg, tape)
    save_svg(f"app-icon/svg/nerdos-app-icon-{vname}.svg", t)
    for W in (64, 128, 256, 512, 1024):
        save_png(f"app-icon/png/nerdos-app-icon-{vname}-{W}.png", png(t, w=W))
    # full-bleed square master (for platforms that apply their own mask, e.g. iOS / Android adaptive)
    tq = app_svg(bg, fg, tape, inset=0.13, shape="square", title="NerdOS app icon (full-bleed)")
    save_svg(f"app-icon/svg/nerdos-app-icon-{vname}-square.svg", tq)
    save_png(f"app-icon/png/nerdos-app-icon-{vname}-square-1024.png", png(tq, w=1024))

# ------------------------------------------------------------------ favicon package
FAV = "favicon"
# favicon.svg — adaptive: charcoal on light tabs, off-white on dark tabs (32-grid hinted geometry)
p32 = symbol_px32()
fav_svg = (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32" width="32" height="32">\n'
           f'  <style>#frames{{fill:{INK}}}@media (prefers-color-scheme:dark){{#frames{{fill:{PAPER}}}}}</style>\n'
           f'  <path id="frames" d="{d(p32["frames"])}"/>\n'
           f'  <path id="tape" fill="{LIME}" d="{d(p32["tape"])}"/>\n</svg>\n')
save_svg(f"{FAV}/favicon.svg", fav_svg)

# hinted tiles for ICO + PNG favicons
tiles = {}
for n in (16, 32, 48):
    sp = tile_hinted(n)
    t = svg_file([("background", INK, sp["tile"]), ("frames", PAPER, sp["frames"]), ("tape", LIME, sp["tape"])],
                 n, n, f"NerdOS favicon {n}px")
    tiles[n] = png(t, w=n)
    save_svg(f"{FAV}/source/favicon-tile-{n}.svg", t)
    save_png(f"{FAV}/favicon-{n}x{n}.png", tiles[n])


def write_ico(path, images):
    """Multi-size ICO with PNG-compressed entries (supported by all current browsers and Windows Vista+)."""
    blobs = []
    for im in images:
        b = io.BytesIO()
        im.save(b, format="PNG", optimize=True)
        blobs.append((im.size[0], b.getvalue()))
    header = struct.pack("<HHH", 0, 1, len(blobs))
    offset = 6 + 16 * len(blobs)
    entries, data = b"", b""
    for size, blob in blobs:
        entries += struct.pack("<BBBBHHII", size % 256, size % 256, 0, 0, 1, 32, len(blob), offset + len(data))
        data += blob
    open(path, "wb").write(header + entries + data)


write_ico(mk(FAV, "favicon.ico"), [tiles[16], tiles[32], tiles[48]])
manifest.append(f"{FAV}/favicon.ico")

# transparent favicon PNGs (extras)
for n, fn in ((16, symbol_px16), (32, symbol_px32)):
    sp = fn()
    for vname, ink in (("on-light", INK), ("on-dark", PAPER)):
        t = svg_file([("frames", ink, sp["frames"]), ("tape", LIME, sp["tape"])], n, n, "NerdOS favicon")
        save_png(f"{FAV}/extras/favicon-transparent-{vname}-{n}x{n}.png", png(t, w=n))

# apple touch icon: full-bleed, opaque (iOS applies its own rounding)
at = app_svg(INK, PAPER, LIME, size=180, inset=0.13, shape="square", title="NerdOS")
save_png(f"{FAV}/apple-touch-icon.png", png(at, w=180).convert("RGB"))
save_svg(f"{FAV}/source/apple-touch-icon.svg", at)

# web app icons: "any" = rounded tile on transparent; "maskable" = full-bleed, art inside the 80% safe circle
for n in (192, 512):
    t = app_svg(INK, PAPER, LIME, size=n, inset=0.13, shape="tile")
    save_png(f"{FAV}/icon-{n}.png", png(t, w=n))
    m = app_svg(INK, PAPER, LIME, size=n, inset=0.19, shape="square", title="NerdOS (maskable)")
    save_png(f"{FAV}/icon-maskable-{n}.png", png(m, w=n).convert("RGB"))
save_svg(f"{FAV}/source/icon-maskable.svg", app_svg(INK, PAPER, LIME, size=512, inset=0.19, shape="square", title="NerdOS (maskable)"))

webmanifest = {
    "name": "NerdOS",
    "short_name": "NerdOS",
    "description": "NerdOS — Opinionated System",
    "start_url": "/",
    "display": "standalone",
    "theme_color": INK,
    "background_color": INK,
    "icons": [
        {"src": "/icon-192.png", "type": "image/png", "sizes": "192x192", "purpose": "any"},
        {"src": "/icon-512.png", "type": "image/png", "sizes": "512x512", "purpose": "any"},
        {"src": "/icon-maskable-192.png", "type": "image/png", "sizes": "192x192", "purpose": "maskable"},
        {"src": "/icon-maskable-512.png", "type": "image/png", "sizes": "512x512", "purpose": "maskable"},
    ],
}
open(mk(FAV, "site.webmanifest"), "w").write(json.dumps(webmanifest, indent=2) + "\n")
manifest.append(f"{FAV}/site.webmanifest")
open(mk(FAV, "head-snippet.html"), "w").write(
    """<!-- NerdOS favicons: copy the files in this folder to the web root of nerdos.org -->
<link rel="icon" href="/favicon.ico" sizes="32x32">
<link rel="icon" href="/favicon.svg" type="image/svg+xml">
<link rel="apple-touch-icon" href="/apple-touch-icon.png">
<link rel="manifest" href="/site.webmanifest">
<meta name="theme-color" content="#1A1B1E">
""")
manifest.append(f"{FAV}/head-snippet.html")

print(len(manifest), "files")
json.dump(manifest, open(os.path.join(OUT, "manifest.json"), "w"), indent=1)
