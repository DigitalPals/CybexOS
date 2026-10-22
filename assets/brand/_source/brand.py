"""NerdOS identity — master geometry. All paths are pathops.Path in a y-down space."""
import pathops
from geo import *
from glyphs import font_path, load, shape, metrics
from fontTools.pens.transformPen import TransformPen

# ---------------------------------------------------------------- palette
INK = "#1A1B1E"      # Charcoal
PAPER = "#F3F2EC"    # Off-white
LIME = "#C8FF1F"     # Electric lime (tape)
GRAPHITE = "#5A5C61" # secondary text on light
FOG = "#A6A8A1"      # secondary text on dark
BLACK, WHITE = "#000000", "#FFFFFF"

# ---------------------------------------------------------------- symbol (master)
# Units: lens 204 x 152, frame 40. Overall symbol ≈ 504 x 152 incl. hinge stubs.
LW, LH, T, G = 204, 152, 40, 56
TAPE = dict(w=48, h=88, ang=30, r=5, gap=9)


def _tape(cx, cy, w, h, ang, r, gap):
    t = xform(rrect(cx - w / 2, cy - h / 2, w, h, r), rot(ang, cx, cy))
    g = xform(rrect(cx - w / 2 - gap, cy - h / 2 - gap, w + 2 * gap, h + 2 * gap, r + gap), rot(ang, cx, cy))
    return t, g


def symbol(stubs=True):
    lens = op(rrect(0, 0, LW, LH, (40, 40, 64, 64)), rrect(T, T, LW - 2 * T, LH - 2 * T, (16, 16, 36, 36)), D)
    right = xform(lens, move(LW + G, 0))
    bridge = rrect(LW - 20, 22, G + 40, 42, 0)
    parts = [lens, right, bridge]
    if stubs:
        parts += [rrect(-20, 18, 40, 36, (11, 0, 0, 11)), rrect(2 * LW + G - 20, 18, 40, 36, (0, 11, 11, 0))]
    frames = union(*parts)
    tape, gap = _tape(LW + G / 2, 43, **TAPE)
    return {"frames": op(frames, gap, D), "tape": tape}


# ---------------------------------------------------------------- pixel-tuned small symbols
def symbol_px16():
    """Hand-hinted 16x16 grid version (1 unit = 1 px). Glasses span the full width."""
    y0 = 5
    def lens(x):
        outer = rrect(x, y0, 7, 6, (1.2, 1.2, 2.2, 2.2), k=0.6)
        inner = rrect(x + 2, y0 + 2, 3, 2, 0)
        return op(outer, inner, D)
    frames = union(lens(0), lens(9), rrect(6, y0 + 1, 4, 2, 0))
    # tape: 2-px band stepping one column per row, '/' direction
    cells = [(9, y0 - 1), (10, y0 - 1), (8, y0), (9, y0), (8, y0 + 1), (9, y0 + 1), (7, y0 + 2), (8, y0 + 2), (6, y0 + 3), (7, y0 + 3)]
    tape = union(*[rrect(cx, cy, 1, 1, 0) for cx, cy in cells])
    return {"frames": op(frames, tape, D), "tape": tape, "box": (0, 0, 16, 16)}


def symbol_px16_tile():
    """16x16 app-tile favicon: charcoal tile, light frames 1px narrower lens openings."""
    y0 = 5
    def lens(x):
        outer = rrect(x, y0, 6, 6, (1, 1, 2, 2), k=0.6)
        inner = rrect(x + 2, y0 + 2, 2, 2, 0)
        return op(outer, inner, D)
    frames = union(lens(1), lens(9), rrect(6, y0 + 1, 4, 2, 0))
    cells = [(9, y0 - 1), (10, y0 - 1), (8, y0), (9, y0), (8, y0 + 1), (9, y0 + 1), (7, y0 + 2), (8, y0 + 2), (6, y0 + 3), (7, y0 + 3)]
    tape = union(*[rrect(cx, cy, 1, 1, 0) for cx, cy in cells])
    return {"frames": op(frames, tape, D), "tape": tape, "tile": rrect(0, 0, 16, 16, 3.5), "box": (0, 0, 16, 16)}


def symbol_px32():
    """Hinted 32x32 version (1 unit = 1 px): frame 4 px, opening 6x4, 3-px tape with 1-px knockout."""
    y0 = 9
    def lens(x):
        outer = rrect(x, y0, 14, 12, (3, 3, 5, 5))
        inner = rrect(x + 4, y0 + 4, 6, 4, (1, 1, 1.5, 1.5))
        return op(outer, inner, D)
    frames = union(lens(0), lens(18), rrect(12, y0 + 2, 8, 4, 0))
    # 3-px band, slope 2 rows : 1 col, pixel aligned
    rows = [(y0 - 2, 18), (y0 - 1, 18), (y0, 17), (y0 + 1, 17), (y0 + 2, 16), (y0 + 3, 16), (y0 + 4, 15), (y0 + 5, 15), (y0 + 6, 14), (y0 + 7, 14)]
    tape = union(*[rrect(x, y, 3, 1, 0) for y, x in rows])
    gap = union(*[rrect(x - 1, y, 5, 1, 0) for y, x in rows], rrect(17, y0 - 3, 4, 1, 0), rrect(13, y0 + 8, 4, 1, 0))
    return {"frames": op(frames, gap, D), "tape": tape, "box": (0, 0, 32, 32)}


def tile_hinted(n):
    """Pixel-hinted app-tile favicons (charcoal tile, light frames, lime tape, 1-px knockout)."""
    if n == 16:
        return symbol_px16_tile()
    if n == 32:
        lw, lh, x, gap, y0, f = 11, 10, 2, 6, 11, 3
        ro, ri, by, bh, r = (2, 2, 4, 4), (0.8, 0.8, 1.5, 1.5), 1, 3, 7.2
        tw = 2
        rows = [(9, 17), (10, 17), (11, 16), (12, 16), (13, 15), (14, 15), (15, 14), (16, 14)]
    else:  # 48
        lw, lh, x, gap, y0, f = 16, 14, 4, 8, 17, 4
        ro, ri, by, bh, r = (3, 3, 6, 6), (1.2, 1.2, 2.5, 2.5), 2, 4, 10.8
        tw = 3
        rows = [(14, 25), (15, 25), (16, 24), (17, 24), (18, 23), (19, 23), (20, 22), (21, 22), (22, 21), (23, 21), (24, 20)]
    def lens(xx):
        return op(rrect(xx, y0, lw, lh, ro), rrect(xx + f, y0 + f, lw - 2 * f, lh - 2 * f, ri), D)
    xr = x + lw + gap
    frames = union(lens(x), lens(xr), rrect(x + lw - 1, y0 + by, gap + 2, bh, 0))
    tape = union(*[rrect(xx, yy, tw, 1, 0) for yy, xx in rows])
    (ty0, tx0), (ty1, tx1) = rows[0], rows[-1]
    knock = union(*[rrect(xx - 1, yy, tw + 2, 1, 0) for yy, xx in rows],
                  rrect(tx0 - 1, ty0 - 1, tw + 2, 1, 0), rrect(tx1 - 1, ty1 + 1, tw + 2, 1, 0))
    return {"frames": op(frames, knock, D), "tape": tape, "tile": rrect(0, 0, n, n, r), "box": (0, 0, n, n)}


def symbol_tile(size, inset=0.14):
    """App-icon composition on a square of side `size`: returns frames/tape/tile paths."""
    s0 = symbol()
    x0, y0, x1, y1 = bounds(union(s0["frames"], s0["tape"]))
    fx0, fy0, fx1, fy1 = bounds(s0["frames"])
    w = size * (1 - 2 * inset)
    k = w / (fx1 - fx0)
    m = (k, 0, 0, k, size * inset - fx0 * k, size / 2 - (fy0 + fy1) / 2 * k)
    return {"frames": xform(s0["frames"], m), "tape": xform(s0["tape"], m),
            "tile": rrect(0, 0, size, size, size * 0.225), "square": rrect(0, 0, size, size, 0), "box": (0, 0, size, size)}


# ---------------------------------------------------------------- type
WORD_FONT = ("space-grotesk", 700)
DESC_FONT = ("jetbrains-mono", 700)
EMBOLDEN = 24  # per-mille of em: custom heavier cut of Space Grotesk Bold


def _outline(fam, wt, text, size, tracking=0, adjust=None):
    p_ = font_path(fam, wt)
    tt, _ = load(p_)
    gs = tt.getGlyphSet()
    upm = tt["head"].unitsPerEm
    s = size / upm
    out = pathops.Path()
    pen = out.getPen()
    cx = 0
    gl = shape(p_, text)
    for i, (name, adv, xo, yo) in enumerate(gl):
        gs[name].draw(TransformPen(pen, (s, 0, 0, -s, (cx + xo) * s, -yo * s)))
        cx += adv + (tracking * upm / 1000 if i < len(gl) - 1 else 0)
        if adjust and i in adjust:
            cx += adjust[i]
    return simplify(out), cx * s, metrics(p_)["cap"] * s


def wordmark(size=200):
    """'NerdOS' — Space Grotesk Bold, emboldened + optically spaced. Baseline y=0."""
    # per-pair spacing in font units (N-e, e-r, r-d, d-O, O-S)
    adj = {0: 6, 1: 6, 2: -10, 3: 22, 4: 10}
    p, w, cap = _outline(*WORD_FONT, "NerdOS", size, tracking=0, adjust=adj)
    sw = EMBOLDEN * size / 1000
    st = pathops.Path(p)
    st.stroke(sw, pathops.LineCap.BUTT_CAP, pathops.LineJoin.MITER_JOIN, 4)
    p = simplify(union(p, st))
    # restore cap height / baseline so weight is added mainly to stems
    x0, y0, x1, y1 = bounds(p)
    k = cap / (cap + sw)
    p = xform(p, (1, 0, 0, k, 0, -k * sw / 2))
    x0, y0, x1, y1 = bounds(p)
    p = xform(p, move(-x0, 0))
    return p, x1 - x0, cap


def descriptor(width):
    p, w, cap = _outline(*DESC_FONT, "OPINIONATED SYSTEM", 200, tracking=90)
    x0, y0, x1, y1 = bounds(p)
    s = width / (x1 - x0)
    p = xform(p, (s, 0, 0, s, -x0 * s, 0))
    return p, cap * s


# ---------------------------------------------------------------- lockups
SYM_RATIO = 1.22   # symbol height / cap height
GAP_RATIO = 0.46   # symbol→wordmark gap / cap height


def lockup(desc=False):
    """Returns dict of paths: frames, tape, word, (desc). Origin = top-left of art box."""
    wp, ww, cap = wordmark(200)
    s0 = symbol()
    x0, y0, x1, y1 = bounds(union(s0["frames"], s0["tape"]))
    fx0, fy0, fx1, fy1 = bounds(s0["frames"])
    # scale symbol by FRAME height (tape overhang excluded) so lens frame aligns optically to cap height
    sh = cap * SYM_RATIO
    s = sh / (fy1 - fy0)
    gap = cap * GAP_RATIO
    out = {}
    if desc:
        dp, dcap = descriptor(ww)
        dgap = cap * 0.36
        block_top, block_bot = -cap, dgap + dcap
        out["desc"] = xform(dp, move(0, dgap + dcap))
    else:
        block_top, block_bot = -cap, 0
    cy = (block_top + block_bot) / 2
    m = (s, 0, 0, s, -fx0 * s, cy - (fy0 + fy1) / 2 * s)
    out["frames"] = xform(s0["frames"], m)
    out["tape"] = xform(s0["tape"], m)
    symw = (fx1 - fx0) * s
    out["word"] = xform(wp, move(symw + gap, 0))
    if desc:
        out["desc"] = xform(out["desc"], move(symw + gap, 0))
    out["X"] = T * s  # clear-space unit = lens frame thickness at this scale
    out["cap"] = cap
    return out
