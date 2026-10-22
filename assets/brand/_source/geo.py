"""Vector geometry helpers: rounded rects, booleans (skia-pathops), transforms, SVG output."""
import math
import pathops
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from fontTools.pens.boundsPen import ControlBoundsPen

K = 0.5522847498
U, D, I = pathops.PathOp.UNION, pathops.PathOp.DIFFERENCE, pathops.PathOp.INTERSECTION


def _r4(r):
    return (r, r, r, r) if isinstance(r, (int, float)) else tuple(r)


def rrect(x, y, w, h, r=0, k=K):
    """Rounded rect, y-down. r = radius or (tl, tr, br, bl)."""
    tl, tr, br, bl = _r4(r)
    p = pathops.Path()
    pen = p.getPen()
    pen.moveTo((x + tl, y))
    pen.lineTo((x + w - tr, y))
    if tr:
        pen.curveTo((x + w - tr + k * tr, y), (x + w, y + tr - k * tr), (x + w, y + tr))
    pen.lineTo((x + w, y + h - br))
    if br:
        pen.curveTo((x + w, y + h - br + k * br), (x + w - br + k * br, y + h), (x + w - br, y + h))
    pen.lineTo((x + bl, y + h))
    if bl:
        pen.curveTo((x + bl - k * bl, y + h), (x, y + h - bl + k * bl), (x, y + h - bl))
    pen.lineTo((x, y + tl))
    if tl:
        pen.curveTo((x, y + tl - k * tl), (x + tl - k * tl, y), (x + tl, y))
    pen.closePath()
    return p


def poly(pts):
    p = pathops.Path()
    pen = p.getPen()
    pen.moveTo(pts[0])
    for q in pts[1:]:
        pen.lineTo(q)
    pen.closePath()
    return p


def xform(path, m):
    out = pathops.Path()
    path.draw(TransformPen(out.getPen(), m))
    return out


def rot(deg, cx=0, cy=0):
    a = math.radians(deg)
    c, s = math.cos(a), math.sin(a)
    # rotate about (cx,cy), y-down so positive = clockwise visually
    return (c, s, -s, c, cx - c * cx + s * cy, cy - s * cx - c * cy)


def move(dx, dy, s=1.0):
    return (s, 0, 0, s, dx, dy)


def op(a, b, kind):
    return pathops.op(a, b, kind)


def union(*ps):
    out = pathops.Path()
    for p in ps:
        out = pathops.op(out, p, U)
    return out


def simplify(p):
    return pathops.simplify(p)


def bounds(p):
    return p.bounds  # xmin, ymin, xmax, ymax


def _ntos(v):
    s = f"{v:.2f}".rstrip("0").rstrip(".")
    return "0" if s in ("-0", "") else s


def d(path):
    pen = SVGPathPen(None, ntos=_ntos)
    path.draw(pen)
    return pen.getCommands()


def from_pen_drawing(draw_fn):
    p = pathops.Path()
    draw_fn(p.getPen())
    return p
