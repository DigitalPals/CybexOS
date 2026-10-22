#!/usr/bin/env python3
"""Scrolling-screenshot stitching on synthetic frames.

Frames are windows onto a synthetic "page" of distinct pixel rows, optionally
framed by a sticky header and footer, so every expected result is known
exactly. The end-to-end case drives the real capture loop with a stub grim
that serves PPM frames; nothing here touches a screen.
"""

import importlib.machinery
import importlib.util
import os
from pathlib import Path
import random
import shutil
import struct
import sys
import tempfile
import unittest
import zlib

ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / "assets/scripts/screenshot-stitch"
LOADER = importlib.machinery.SourceFileLoader("screenshot_stitch", str(HELPER))
SPEC = importlib.util.spec_from_loader(LOADER.name, LOADER)
stitch = importlib.util.module_from_spec(SPEC)
# dataclasses resolves the helper's annotations through sys.modules.
sys.modules[LOADER.name] = stitch
LOADER.exec_module(stitch)

WIDTH = 24


def page(rows, seed=1, blank_every=0):
    """Distinct, informative rows; every blank_every-th one a solid white line
    (a uniform row matches anywhere and must not mislead the matching)."""
    generator = random.Random(seed)
    lines = []
    for index in range(rows):
        if blank_every and index % blank_every == 0:
            lines.append(b"\xff" * WIDTH * 3)
        else:
            lines.append(generator.randbytes(WIDTH * 3))
    return lines


def window(lines, offset, height, header=(), footer=()):
    content = height - len(header) - len(footer)
    return stitch.Frame(WIDTH, [*header, *lines[offset:offset + content], *footer])


def stitched(frames, max_height=stitch.MAX_HEIGHT):
    writer = stitch.PngRows(WIDTH)
    stitcher = stitch.Stitcher(writer, max_height)
    for frame in frames:
        stitcher.add(frame)
    stitcher.finish()
    with tempfile.TemporaryDirectory(prefix="nerdos-stitch-test-") as directory:
        output = Path(directory) / "out.png"
        writer.save(output)
        width, height, decoded = decode_png(output.read_bytes())
    assert width == WIDTH and height == len(decoded)
    return decoded, stitcher


def decode_png(data):
    assert data[:8] == b"\x89PNG\r\n\x1a\n"
    index, idat, header = 8, b"", None
    while index < len(data):
        length, = struct.unpack(">I", data[index:index + 4])
        kind = data[index + 4:index + 8]
        payload = data[index + 8:index + 8 + length]
        crc, = struct.unpack(">I", data[index + 8 + length:index + 12 + length])
        assert crc == zlib.crc32(kind + payload), kind
        if kind == b"IHDR":
            header = struct.unpack(">IIBBBBB", payload)
        elif kind == b"IDAT":
            idat += payload
        index += 12 + length
    width, height, depth, colour, _, _, interlace = header
    assert (depth, colour, interlace) == (8, 2, 0)
    raw = zlib.decompress(idat)
    stride = width * 3 + 1
    assert len(raw) == stride * height
    rows = []
    for y in range(height):
        line = raw[y * stride:(y + 1) * stride]
        assert line[0] == 0, "rows are written unfiltered"
        rows.append(line[1:])
    return width, height, rows


def ppm(rows, comment=False):
    header = b"P6\n" + (b"# grim\n" if comment else b"") + f"{WIDTH} {len(rows)}\n255\n".encode()
    return header + b"".join(rows)


class Matching(unittest.TestCase):
    def test_scrolled_frames_join_into_the_page(self):
        lines = page(400)
        frames = [window(lines, offset, 100) for offset in (0, 30, 75, 120, 121)]
        result, stitcher = stitched(frames)
        self.assertEqual(result, lines[:221])
        self.assertEqual(stitcher.gaps, 0)

    def test_sticky_header_and_footer_appear_once(self):
        lines = page(400)
        header, footer = page(10, seed=7), page(8, seed=8)
        frames = [window(lines, offset, 100, header, footer) for offset in (0, 25, 60)]
        match = stitch.compare(frames[0], frames[1])
        self.assertEqual((match.kind, match.shift, match.header, match.footer),
                         ("scrolled", 25, 10, 8))
        result, _ = stitched(frames)
        self.assertEqual(result, header + lines[:60 + 82] + footer)

    def test_identical_frames_add_nothing(self):
        lines = page(200)
        frame = window(lines, 0, 100)
        self.assertEqual(stitch.compare(frame, frame).kind, "identical")
        result, stitcher = stitched([frame, window(lines, 0, 100), window(lines, 0, 100)])
        self.assertEqual(result, lines[:100])
        self.assertEqual(stitcher.frames, 1)

    def test_a_jump_without_overlap_is_kept_after_a_gap(self):
        lines = page(600)
        frames = [window(lines, 0, 100), window(lines, 300, 100), window(lines, 330, 100)]
        self.assertEqual(stitch.compare(frames[0], frames[1]).kind, "unmatched")
        result, stitcher = stitched(frames)
        self.assertEqual(result, lines[:100] + lines[300:430])
        self.assertEqual(stitcher.gaps, 1)

    def test_content_that_never_settles_is_not_stitched_frame_by_frame(self):
        # A playing video: every frame differs from the last. Only the state
        # at the end is kept, not a strip per frame.
        first = window(page(100, seed=1), 0, 100)
        changing = [window(page(100, seed=seed), 0, 100) for seed in range(2, 7)]
        result, stitcher = stitched([first, *changing])
        self.assertEqual(result, first.rows + changing[-1].rows)
        self.assertEqual(stitcher.gaps, 1)

    def test_a_change_in_place_is_not_a_scroll(self):
        lines = page(200)
        before = window(lines, 0, 100)
        after_rows = list(before.rows)
        after_rows[50] = page(1, seed=99)[0]
        after = stitch.Frame(WIDTH, after_rows)
        self.assertEqual(stitch.compare(before, after).kind, "still")
        result, _ = stitched([before, after])
        self.assertEqual(result, after_rows, "the region as it last looked")

    def test_blank_lines_in_the_content_do_not_mislead_the_offset(self):
        lines = page(400, blank_every=5)
        frames = [window(lines, offset, 100) for offset in (0, 40, 95, 150)]
        result, _ = stitched(frames)
        self.assertEqual(result, lines[:250])

    def test_rounding_noise_between_frames_still_matches(self):
        lines = [bytes(value & 0xF8 for value in line) for line in page(300)]
        noisy = [bytes(value | random.Random(index).randrange(2) for value in line)
                 for index, line in enumerate(lines)]
        first = window(lines, 0, 100)
        second = window(noisy, 35, 100)
        match = stitch.compare(first, second)
        self.assertEqual((match.kind, match.shift), ("scrolled", 35))

    def test_scrolling_back_up_adds_nothing(self):
        lines = page(400)
        match = stitch.compare(window(lines, 50, 100), window(lines, 20, 100))
        self.assertEqual((match.kind, match.shift), ("backward", -30))
        frames = [window(lines, offset, 100) for offset in (0, 40, 20, 10, 60, 90)]
        result, _ = stitched(frames)
        self.assertEqual(result, lines[:190])

    def test_the_height_limit_stops_the_capture(self):
        lines = page(600)
        writer = stitch.PngRows(WIDTH)
        stitcher = stitch.Stitcher(writer, max_height=230)
        for offset in (0, 50, 100, 150, 200):
            stitcher.add(window(lines, offset, 100))
        self.assertTrue(stitcher.full)
        stitcher.finish()
        self.assertEqual(writer.height, 230)

    def test_a_resized_region_is_rejected(self):
        stitcher = stitch.Stitcher(stitch.PngRows(WIDTH))
        stitcher.add(window(page(200), 0, 100))
        with self.assertRaises(ValueError):
            stitcher.add(window(page(200), 0, 90))


class Formats(unittest.TestCase):
    def test_ppm_header_with_comment(self):
        rows = page(5)
        width, height, raster = stitch.parse_ppm(ppm(rows, comment=True))
        self.assertEqual((width, height, raster), (WIDTH, 5, b"".join(rows)))
        frame = stitch.frame_from_ppm(ppm(rows))
        self.assertEqual(frame.rows, rows)

    def test_malformed_ppm_is_refused(self):
        for data in (b"P3\n1 1\n255\n000", b"P6\n2 2\n255\n" + b"\0" * 5, b"P6\n2 2\n65535\n"):
            with self.assertRaises(ValueError):
                stitch.parse_ppm(data)

    def test_png_needs_rows(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(stitch.CaptureError):
                stitch.PngRows(WIDTH).save(Path(directory) / "empty.png")
            self.assertEqual(os.listdir(directory), [])


class CaptureLoop(unittest.TestCase):
    def test_capture_stitches_grim_frames_until_stopped(self):
        lines = page(400)
        offsets = (0, 0, 30, 30, 70, 110)
        with tempfile.TemporaryDirectory(prefix="nerdos-stitch-test-") as directory:
            base = Path(directory)
            frames = base / "frames"
            frames.mkdir()
            for index, offset in enumerate(offsets):
                (frames / f"{index}.ppm").write_bytes(ppm(window(lines, offset, 100).rows))
            stop = base / "stop"
            bin_dir = base / "bin"
            bin_dir.mkdir()
            grim = bin_dir / "grim"
            # Serves the frames in order, repeats the last one, and asks to
            # stop once all have been served, as the stop keys would.
            grim.write_text(f"""#!{shutil.which('bash')}
[[ "$*" == "-t ppm -g 10,20 24x100 -" ]] || exit 9
count=$(cat {base}/count 2>/dev/null || echo 0)
next=$((count + 1))
[ -e {frames}/$count.ppm ] || {{ count=$((count - 1)); touch {stop}; }}
echo "$next" > {base}/count
cat {frames}/$count.ppm
""")
            grim.chmod(0o755)
            output = base / "out.png"
            path = os.environ["PATH"]
            os.environ["PATH"] = f"{bin_dir}:{path}"
            try:
                summary = stitch.capture("10,20 24x100", output, stop, interval=0.01)
            finally:
                os.environ["PATH"] = path
            width, height, rows = decode_png(output.read_bytes())
            self.assertEqual(rows, lines[:210])
            self.assertEqual(summary["stopped"], "user")
            self.assertEqual((summary["width"], summary["height"], summary["gaps"]),
                             (WIDTH, 210, 0))
            self.assertEqual(sorted(path.name for path in base.iterdir()),
                             ["bin", "count", "frames", "out.png", "stop"],
                             "no temporary file may be left beside the output")

    def test_failing_grim_reports_an_error(self):
        with tempfile.TemporaryDirectory(prefix="nerdos-stitch-test-") as directory:
            base = Path(directory)
            (base / "grim").write_text(f"#!{shutil.which('bash')}\nexit 1\n")
            (base / "grim").chmod(0o755)
            path = os.environ["PATH"]
            os.environ["PATH"] = f"{base}:{path}"
            try:
                with self.assertRaises(stitch.CaptureError):
                    stitch.capture("0,0 10x10", base / "out.png", base / "stop", interval=0.01)
            finally:
                os.environ["PATH"] = path
            self.assertFalse((base / "out.png").exists())

    def test_command_line_validates_its_input(self):
        for argv in (["--geometry", "10,20 300x200;rm", "--output", "x", "--stop-file", "y"],
                     ["--geometry", "10,20 300x200", "--output", "x", "--stop-file", "y",
                      "--max-seconds", "100000"]):
            with self.assertRaises(SystemExit) as raised:
                with open(os.devnull, "w") as sink:
                    stderr, sys.stderr = sys.stderr, sink
                    try:
                        stitch.main(argv)
                    finally:
                        sys.stderr = stderr
            self.assertEqual(raised.exception.code, 2)
        with tempfile.TemporaryDirectory(prefix="nerdos-stitch-test-") as directory:
            base = Path(directory)
            (base / "grim").write_text(f"#!{shutil.which('bash')}\nexit 1\n")
            (base / "grim").chmod(0o755)
            path = os.environ["PATH"]
            os.environ["PATH"] = f"{base}:{path}"
            try:
                with open(os.devnull, "w") as sink:
                    stderr, sys.stderr = sys.stderr, sink
                    try:
                        status = stitch.main(["--geometry", "0,0 10x10", "--output",
                                              str(base / "out.png"), "--stop-file",
                                              str(base / "stop"), "--interval", "0.01"])
                    finally:
                        sys.stderr = stderr
            finally:
                os.environ["PATH"] = path
            self.assertEqual(status, 1)


if __name__ == "__main__":
    unittest.main()
