#!/usr/bin/env python3
"""URL, integrity and cleanup contracts for the Wallhaven download helper."""

from __future__ import annotations

import importlib.util
import io
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.error


ROOT = Path(__file__).resolve().parents[1]
PATH = ROOT / "roles/desktop/files/quickshell/scripts/wallpaper-download.py"
SPEC = importlib.util.spec_from_file_location("wallpaper_download", PATH)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)

URL = "https://w.wallhaven.cc/full/qr/wallhaven-qroy2d.png"
PNG = b"\x89PNG\r\n\x1a\n" + bytes(range(256)) * 700
JPEG = b"\xff\xd8\xff\xe0" + b"\x00" * 5000


class Response:
    def __init__(self, body: bytes, content_type: str = "image/png",
                 length: str | None = "auto", status: int = 200) -> None:
        self.stream = io.BytesIO(body)
        self.status = status
        self.headers = {"Content-Type": content_type}
        if length == "auto":
            self.headers["Content-Length"] = str(len(body))
        elif length is not None:
            self.headers["Content-Length"] = length

    def read(self, size: int) -> bytes:
        return self.stream.read(size)

    def __enter__(self):
        return self

    def __exit__(self, *exc) -> None:
        self.stream.close()


def opener_for(response):
    calls = []

    def opener(url):
        calls.append(url)
        if isinstance(response, BaseException):
            raise response
        return response

    return opener, calls


class HelperCase(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.directory = Path(self.temporary.name) / "Wallpapers"

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def entries(self) -> list[str]:
        if not self.directory.exists():
            return []
        return sorted(entry.name for entry in self.directory.iterdir())

    def assertFails(self, code: str, response, expected: int = len(PNG), url: str = URL) -> None:
        opener, _ = opener_for(response)
        with self.assertRaises(MODULE.Failure) as caught:
            MODULE.download(url, self.directory, expected, opener)
        self.assertEqual(caught.exception.code, code)
        self.assertEqual(self.entries(), [], "a failure leaves no file or .part behind")


class UrlTests(HelperCase):
    def test_accepts_wallhaven_full_images_and_names_them_from_the_id(self):
        self.assertEqual(MODULE.validate(URL), ("wallhaven-qroy2d.png", "png"))
        self.assertEqual(MODULE.validate("https://w.wallhaven.cc/full/rd/wallhaven-rdwjj7.jpg"),
                         ("wallhaven-rdwjj7.jpg", "jpg"))

    def test_rejects_every_other_origin_path_and_type(self):
        for url in (
            "http://w.wallhaven.cc/full/qr/wallhaven-qroy2d.png",
            "https://wallhaven.cc/full/qr/wallhaven-qroy2d.png",
            "https://w.wallhaven.cc.example/full/qr/wallhaven-qroy2d.png",
            "https://w.wallhaven.cc:8443/full/qr/wallhaven-qroy2d.png",
            "https://user@w.wallhaven.cc/full/qr/wallhaven-qroy2d.png",
            "https://w.wallhaven.cc/full/qr/wallhaven-qroy2d.png?x=1",
            "https://w.wallhaven.cc/full/qr/wallhaven-qroy2d.png#x",
            "https://w.wallhaven.cc/full/qr/../../etc/passwd",
            "https://w.wallhaven.cc/full/qr/wallhaven-qroy2d.gif",
            "https://w.wallhaven.cc/full/ab/wallhaven-qroy2d.png",
            "https://w.wallhaven.cc/full/QR/wallhaven-QROY2D.png",
            "https://w.wallhaven.cc/full/qr/.wallhaven-qroy2d.png",
            "file:///etc/passwd",
        ):
            with self.subTest(url=url):
                with self.assertRaises(MODULE.Failure) as caught:
                    MODULE.validate(url)
                self.assertEqual(caught.exception.code, "url")

    def test_a_rejected_url_is_never_fetched(self):
        opener, calls = opener_for(Response(PNG))
        with self.assertRaises(MODULE.Failure):
            MODULE.download("https://evil.example/full/qr/wallhaven-qroy2d.png",
                            self.directory, len(PNG), opener)
        self.assertEqual(calls, [])


class DownloadTests(HelperCase):
    def test_saves_the_exact_bytes_atomically_with_the_umask(self):
        opener, calls = opener_for(Response(PNG))
        previous = os.umask(0o027)
        try:
            target = MODULE.download(URL, self.directory, len(PNG), opener)
        finally:
            os.umask(previous)
        self.assertEqual(calls, [URL])
        self.assertEqual(target, self.directory / "wallhaven-qroy2d.png")
        self.assertEqual(target.read_bytes(), PNG)
        self.assertEqual(self.entries(), ["wallhaven-qroy2d.png"])
        self.assertEqual(target.stat().st_mode & 0o777, 0o640)

    def test_a_saved_image_of_the_listed_size_is_reused_without_a_request(self):
        self.directory.mkdir()
        (self.directory / "wallhaven-qroy2d.png").write_bytes(PNG)
        opener, calls = opener_for(Response(PNG))
        MODULE.download(URL, self.directory, len(PNG), opener)
        self.assertEqual(calls, [])

    def test_a_saved_file_of_another_size_is_replaced(self):
        self.directory.mkdir()
        (self.directory / "wallhaven-qroy2d.png").write_bytes(b"stale")
        opener, calls = opener_for(Response(PNG))
        target = MODULE.download(URL, self.directory, len(PNG), opener)
        self.assertEqual(len(calls), 1)
        self.assertEqual(target.read_bytes(), PNG)

    def test_a_failed_replacement_keeps_the_previous_file(self):
        self.directory.mkdir()
        (self.directory / "wallhaven-qroy2d.png").write_bytes(b"stale")
        opener, _ = opener_for(Response(PNG[:-1], length=None))
        with self.assertRaises(MODULE.Failure):
            MODULE.download(URL, self.directory, len(PNG), opener)
        self.assertEqual(self.entries(), ["wallhaven-qroy2d.png"])
        self.assertEqual((self.directory / "wallhaven-qroy2d.png").read_bytes(), b"stale")

    def test_integrity_failures_leave_nothing_behind(self):
        self.assertFails("type", Response(PNG, content_type="text/html"))
        self.assertFails("type", Response(JPEG, content_type="image/png"), expected=len(JPEG))
        self.assertFails("size", Response(PNG, length=str(len(PNG) + 1)))
        self.assertFails("size", Response(PNG, length="lots"))
        self.assertFails("size", Response(PNG + b"extra", length=None))
        self.assertFails("size", Response(PNG[:-10], length=None))
        self.assertFails("size", Response(PNG), expected=0)
        self.assertFails("size", Response(PNG), expected=MODULE.MAX_BYTES + 1)
        self.assertFails("http", Response(PNG, status=204))

    def test_transport_failures_are_named(self):
        self.assertFails("http", urllib.error.HTTPError(URL, 404, "Not Found", {}, None))
        self.assertFails("network", urllib.error.URLError("offline"))
        self.assertFails("network", TimeoutError("timed out"))

    def test_an_unusable_folder_is_a_write_failure(self):
        # A file where the folder should be fails even for root, which
        # ignores permission bits (CI runs these fixtures as root).
        self.directory.write_bytes(b"not a folder")
        opener, calls = opener_for(Response(PNG))
        with self.assertRaises(MODULE.Failure) as caught:
            MODULE.download(URL, self.directory, len(PNG), opener)
        self.assertEqual(caught.exception.code, "write")
        self.assertEqual(calls, [])

    def test_progress_is_whole_percent_and_ends_at_one_hundred(self):
        opener, _ = opener_for(Response(PNG))
        lines = []
        original = MODULE.emit
        MODULE.emit = lines.append
        try:
            MODULE.download(URL, self.directory, len(PNG), opener)
        finally:
            MODULE.emit = original
        values = [int(line.split()[1]) for line in lines]
        self.assertTrue(all(line.startswith("progress ") for line in lines))
        self.assertEqual(values, sorted(values))
        self.assertEqual(values[-1], 100)

    def test_main_reports_one_verdict_line(self):
        self.assertEqual(MODULE.main(["x"]), 2)
        self.assertEqual(MODULE.main(["x", URL, str(self.directory), "abc"]), 2)


# Runs the helper's own main() in a child whose opener trickles the image, so
# SIGTERM arrives mid-download the way Quickshell delivers it on a new pick.
CHILD = r"""
import importlib.util, sys, time
spec = importlib.util.spec_from_file_location("wallpaper_download", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class Slow:
    status = 200
    headers = {"Content-Type": "image/png", "Content-Length": "1000000"}
    def __init__(self):
        self.sent = 0
    def read(self, size):
        time.sleep(0.05)
        if self.sent >= 1000000:
            return b""
        chunk = (b"\x89PNG\r\n\x1a\n" if self.sent == 0 else b"") + b"\x00" * 1000
        self.sent += len(chunk)
        return chunk
    def __enter__(self):
        return self
    def __exit__(self, *exc):
        pass

module.open_url = lambda url: Slow()
module.download.__defaults__ = (module.open_url,)
raise SystemExit(module.main(sys.argv[1:1] + ["helper", sys.argv[2], sys.argv[3], "1000000"]))
"""


class CancelTests(HelperCase):
    def test_sigterm_mid_download_removes_the_partial_file(self):
        child = subprocess.Popen(
            [sys.executable, "-c", CHILD, str(PATH), URL, str(self.directory)],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                if any(name.endswith(".part") for name in self.entries()):
                    break
                time.sleep(0.02)
            else:
                self.fail("the helper never started writing")
            child.send_signal(signal.SIGTERM)
            stdout, _ = child.communicate(timeout=10)
        finally:
            if child.poll() is None:
                child.kill()
                child.wait()
        self.assertEqual(child.returncode, 1)
        self.assertEqual(stdout.strip().splitlines()[-1], "failed interrupted")
        self.assertEqual(self.entries(), [])


if __name__ == "__main__":
    unittest.main()
