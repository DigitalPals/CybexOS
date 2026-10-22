"""Text → outlined SVG path helpers (harfbuzz shaping + fontTools outlines)."""
import io, functools
from fontTools.ttLib import TTFont
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from fontTools.pens.recordingPen import RecordingPen
import uharfbuzz as hb

import os
FS = os.environ.get("FONTSOURCE_DIR", "node_modules/@fontsource")


def font_path(family, weight):
    return f"{FS}/{family}/files/{family}-latin-{weight}-normal.woff2"


@functools.lru_cache(None)
def load(path):
    f = TTFont(path)
    f.flavor = None
    buf = io.BytesIO()
    f.save(buf)
    data = buf.getvalue()
    tt = TTFont(io.BytesIO(data))
    face = hb.Face(hb.Blob(data))
    hbfont = hb.Font(face)
    return tt, hbfont


def shape(path, text, features=None):
    tt, hbfont = load(path)
    buf = hb.Buffer()
    buf.add_str(text)
    buf.guess_segment_properties()
    hb.shape(hbfont, buf, features or {"kern": True, "liga": False})
    order = tt.getGlyphOrder()
    out = []
    for info, pos in zip(buf.glyph_infos, buf.glyph_positions):
        out.append((order[info.codepoint], pos.x_advance, pos.x_offset, pos.y_offset))
    return out


def metrics(path):
    tt, _ = load(path)
    os2 = tt["OS/2"]
    return {
        "upm": tt["head"].unitsPerEm,
        "cap": getattr(os2, "sCapHeight", 0) or 700,
        "xh": getattr(os2, "sxHeight", 0) or 500,
    }


def text_path(path, text, size, x=0.0, y=0.0, tracking=0.0, pair_adjust=None):
    """Return (svg_d, width). y is the baseline. tracking in em/1000.
    pair_adjust: dict index->extra units (font units) added after glyph i."""
    tt, _ = load(path)
    gs = tt.getGlyphSet()
    upm = tt["head"].unitsPerEm
    s = size / upm
    pen = SVGPathPen(gs)
    cx = 0.0
    glyphs = shape(path, text)
    for i, (name, adv, xo, yo) in enumerate(glyphs):
        tp = TransformPen(pen, (s, 0, 0, -s, x + (cx + xo) * s, y - yo * s))
        gs[name].draw(tp)
        cx += adv
        if i < len(glyphs) - 1:
            cx += tracking * upm / 1000.0
            if pair_adjust and i in pair_adjust:
                cx += pair_adjust[i]
    return pen.getCommands(), cx * s


def glyph_record(path, text):
    """Per-glyph RecordingPens in font units with x positions (for custom assembly)."""
    tt, _ = load(path)
    gs = tt.getGlyphSet()
    res = []
    cx = 0
    for name, adv, xo, yo in shape(path, text):
        rp = RecordingPen()
        gs[name].draw(rp)
        res.append({"name": name, "x": cx + xo, "adv": adv, "rec": rp})
        cx += adv
    return res
