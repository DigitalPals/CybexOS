#!/usr/bin/env python3
"""Clipboard pins and image previews against fake cliphist, wl-copy and magick.

Pins must outlive cliphist (which prunes and can be wiped), stay bounded, and
name only files inside their own directory. Previews must stay bounded and
hold nothing the current history no longer shows.
"""

import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SHELL = ROOT / "roles/desktop/files/quickshell"
TOOL = SHELL / "scripts/clipboard-tool.py"
LOADER = importlib.machinery.SourceFileLoader("clipboard_tool", str(TOOL))
SPEC = importlib.util.spec_from_loader(LOADER.name, LOADER)
tool = importlib.util.module_from_spec(SPEC)
LOADER.exec_module(tool)

PNG = b"\x89PNG\r\n\x1a\n" + b"\x00" * 64
TEXT_LINE = "41\tdeploy token"
IMAGE_LINE = "42\t[[ binary data 72 B png 1x1 ]]"
OTHER_IMAGE = "43\t[[ binary data 72 B png 2x2 ]]"
BINARY_LINE = "44\t[[ binary data 9 B ]]"


class Fixture(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name)
        self.home = root / "home"
        self.runtime = root / "run"
        self.bin = root / "bin"
        for path in (self.home, self.runtime, self.bin):
            path.mkdir()
        # cliphist decode: the payload for each line comes from entries.json.
        self.entries = root / "entries.json"
        self.entries.write_text(json.dumps({
            TEXT_LINE: "deploy token\n  second line".encode().hex(),
            IMAGE_LINE: PNG.hex(),
            OTHER_IMAGE: (PNG + b"other").hex(),
            BINARY_LINE: b"\x00\x01binary".hex(),
        }))
        self.script("cliphist", f"""#!/usr/bin/env python3
import json, sys
line = sys.stdin.read()
entries = json.load(open({str(self.entries)!r}))
if sys.argv[1:] != ["decode"] or line not in entries:
    sys.exit(1)
sys.stdout.buffer.write(bytes.fromhex(entries[line]))
""")
        # magick: copy the decoded input to the png: output named last.
        self.script("magick", """#!/usr/bin/env python3
import sys
data = sys.stdin.buffer.read()
open(sys.argv[-1].split(":", 1)[1], "wb").write(b"thumb:" + data[:8])
""")
        self.copied = root / "copied"
        self.script("wl-copy", f"""#!/bin/sh
printf '%s\\n' "$*" > {str(self.copied)!r}.args
cat > {str(self.copied)!r}
""")
        environment = {"HOME": str(self.home), "XDG_RUNTIME_DIR": str(self.runtime),
                       "PATH": f"{self.bin}:/usr/bin:/bin"}
        patcher = patch.dict(os.environ, environment, clear=True)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.store = self.home / ".local/share/cybexos/clipboard"

    def script(self, name, body):
        path = self.bin / name
        path.write_text(body)
        path.chmod(0o755)

    def index(self):
        return json.loads((self.store / "pins.json").read_text())["pins"]


class Pins(Fixture):
    def test_a_text_pin_keeps_the_bytes_and_survives_a_wiped_history(self):
        record = tool.pin(TEXT_LINE)
        self.assertEqual(record["kind"], "text")
        self.assertEqual(record["preview"], "deploy token second line")
        self.assertEqual((self.store / "pins" / record["file"]).read_bytes(),
                         b"deploy token\n  second line")
        self.assertEqual(self.store.stat().st_mode & 0o777, 0o700)
        # cliphist forgets everything; the pin does not depend on it.
        self.entries.write_text("{}")
        self.assertEqual([pin["id"] for pin in self.index()], [record["id"]])
        tool.copy(record["id"])
        self.assertEqual(self.copied.read_bytes(), b"deploy token\n  second line")
        self.assertEqual(Path(str(self.copied) + ".args").read_text().strip(),
                         "--type text/plain;charset=utf-8")

    def test_pinning_the_same_content_again_moves_it_to_the_top(self):
        first = tool.pin(TEXT_LINE)
        tool.pin(IMAGE_LINE)
        again = tool.pin(TEXT_LINE)
        self.assertEqual(again["id"], first["id"])
        self.assertEqual([pin["id"] for pin in self.index()][0], first["id"])
        self.assertEqual(len(self.index()), 2)

    def test_an_image_pin_gets_a_thumbnail_and_copies_as_an_image(self):
        record = tool.pin(IMAGE_LINE)
        self.assertEqual(record["kind"], "image")
        self.assertEqual(record["file"], record["id"] + ".png")
        self.assertEqual(record["thumb"], record["id"] + "-thumb.png")
        self.assertTrue((self.store / "pins" / record["thumb"]).read_bytes().startswith(b"thumb:"))
        tool.copy(record["id"])
        self.assertEqual(self.copied.read_bytes(), PNG)
        self.assertIn("image/png", Path(str(self.copied) + ".args").read_text())

    def test_unrecognized_binary_data_is_refused(self):
        with self.assertRaisesRegex(tool.ToolError, "cannot be pinned"):
            tool.pin(BINARY_LINE)
        with self.assertRaisesRegex(tool.ToolError, "not a clipboard history entry"):
            tool.pin("no tab here")

    def test_the_store_is_bounded_and_refuses_instead_of_evicting(self):
        with patch.object(tool, "MAX_PINS", 1):
            tool.pin(TEXT_LINE)
            with self.assertRaisesRegex(tool.ToolError, "Unpin one first"):
                tool.pin(IMAGE_LINE)
        with patch.object(tool, "MAX_PIN_STORE_BYTES", 40):
            with self.assertRaisesRegex(tool.ToolError, "space"):
                tool.pin(IMAGE_LINE)
        with patch.object(tool, "MAX_TEXT_BYTES", 4):
            self.entries.write_text(json.dumps({"9\tbig": b"0123456789".hex()}))
            with self.assertRaisesRegex(tool.ToolError, "too large"):
                tool.pin("9\tbig")
        self.assertEqual(len(self.index()), 1)

    def test_unpin_removes_the_files_and_crafted_names_are_ignored(self):
        record = tool.pin(IMAGE_LINE)
        self.assertTrue(tool.unpin(record["id"]))
        self.assertEqual(self.index(), [])
        self.assertEqual(list((self.store / "pins").iterdir()), [])
        self.assertFalse(tool.unpin(record["id"]))
        (self.store / "pins.json").write_text(json.dumps({"pins": [
            {"id": "a" * 16, "kind": "text", "file": "../../../../etc/passwd"},
            {"id": "b" * 16, "kind": "text", "file": "bbbbbbbbbbbbbbbb.txt"},
        ]}))
        (self.store / "pins/bbbbbbbbbbbbbbbb.txt").write_text("kept")
        self.assertEqual([pin["id"] for pin in tool.read_index(self.store)], ["b" * 16])

    def test_failures_are_reported_as_a_notification_when_asked(self):
        notes = []
        with patch.object(tool, "notify", notes.append), \
                patch("sys.stderr"):
            self.assertEqual(tool.main(["pin", "--notify", BINARY_LINE]), 1)
            self.assertEqual(tool.main(["unpin", "--notify", "0" * 16]), 1)
            self.assertEqual(tool.main(["bogus"]), 2)
        self.assertEqual(len(notes), 2)


class Previews(Fixture):
    def test_previews_cover_image_lines_only_and_drop_what_history_lost(self):
        result = tool.previews([TEXT_LINE, IMAGE_LINE, OTHER_IMAGE, BINARY_LINE])
        self.assertEqual(sorted(result), sorted([IMAGE_LINE, OTHER_IMAGE]))
        cache = self.runtime / "cybexos/clipboard-previews"
        self.assertEqual(cache.stat().st_mode & 0o777, 0o700)
        for uri in result.values():
            self.assertTrue(uri.startswith("file://" + str(cache)))
        self.assertEqual(len(list(cache.iterdir())), 2)
        # The newer history no longer has OTHER_IMAGE: its preview goes.
        result = tool.previews([IMAGE_LINE])
        self.assertEqual(list(result), [IMAGE_LINE])
        self.assertEqual(len(list(cache.iterdir())), 1)
        # An empty history leaves an empty cache.
        self.assertEqual(tool.previews([]), {})
        self.assertEqual(list(cache.iterdir()), [])

    def test_the_cache_is_bounded(self):
        with patch.object(tool, "MAX_CACHE_FILES", 1):
            result = tool.previews([IMAGE_LINE, OTHER_IMAGE])
        self.assertEqual(len(result), 1)
        self.assertEqual(len(list((self.runtime / "cybexos/clipboard-previews").iterdir())), 1)

    def test_without_imagemagick_a_small_image_is_shown_as_it_is(self):
        (self.bin / "magick").unlink()
        with patch.object(tool.shutil, "which",
                          lambda name: None if name == "magick" else str(self.bin / name)):
            result = tool.previews([IMAGE_LINE])
        path = Path(result[IMAGE_LINE][len("file://"):])
        self.assertEqual(path.read_bytes(), PNG)

    def test_the_command_line_prints_one_json_object(self):
        output = subprocess.run(["python3", "-I", str(TOOL), "previews", IMAGE_LINE],
                                capture_output=True, text=True, timeout=30,
                                env=dict(os.environ, PYTHONDONTWRITEBYTECODE="1"))
        self.assertEqual(output.returncode, 0, output.stderr)
        self.assertEqual(list(json.loads(output.stdout)), [IMAGE_LINE])


class LauncherContract(unittest.TestCase):
    def test_the_launcher_accepts_the_same_pin_file_names(self):
        source = (SHELL / "Common/LauncherProviders.js").read_text()
        self.assertIn(r"/^[0-9a-f]{16}(?:-thumb)?\.(?:txt|png|jpg|gif|webp|bmp)$/", source)
        self.assertEqual(tool.PIN_NAME.pattern,
                         r"[0-9a-f]{16}(?:-thumb)?\.(?:txt|png|jpg|gif|webp|bmp)")
        self.assertIn("var PIN_LIMIT = 50;", source)
        self.assertEqual(tool.MAX_PINS, 50)


if __name__ == "__main__":
    unittest.main()
