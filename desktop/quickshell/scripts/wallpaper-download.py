#!/usr/bin/env python3
"""Download one Wallhaven wallpaper into the wallpaper folder.

usage: wallpaper-download.py URL DIRECTORY EXPECTED_BYTES

Prints "progress N" (whole percent) while the image arrives, then exactly one
of "done PATH" or "failed CODE"; the reason for a failure goes to stderr. The
codes are the keys of WallhavenHelpers.DOWNLOAD_ERRORS.

Only https://w.wallhaven.cc/full/ images are fetched, and the saved name comes
from that validated URL. The bytes land in a hidden .part file beside the
destination and are renamed into place only once their length and signature
check out, so the folder never shows a half-written or non-image file, and a
cancelled download (SIGTERM) leaves nothing behind.
"""

from __future__ import annotations

import os
from pathlib import Path
import re
import signal
import sys
from typing import Callable
import urllib.error
import urllib.request
from urllib.parse import urlsplit


HOST = "w.wallhaven.cc"
PATH = re.compile(r"^/full/([a-z0-9]{2})/(wallhaven-([a-z0-9]{1,16})\.(jpg|png))$")
TYPES = {"jpg": "image/jpeg", "png": "image/png"}
SIGNATURES = {"jpg": b"\xff\xd8\xff", "png": b"\x89PNG\r\n\x1a\n"}
# Wallhaven's upload limit is well under this; it bounds disk use if the
# listing's size is wrong or the server misbehaves.
MAX_BYTES = 64 * 1024 * 1024
CHUNK = 64 * 1024
TIMEOUT = 30
USER_AGENT = "CybexOS-wallpaper-picker/1"


class Failure(Exception):
    def __init__(self, code: str, detail: str) -> None:
        super().__init__(detail)
        self.code = code


def validate(url: str) -> tuple[str, str]:
    """Returns (file name, extension) for a Wallhaven full-size image URL."""
    parts = urlsplit(url)
    if (parts.scheme != "https" or parts.netloc != HOST or parts.query
            or parts.fragment):
        raise Failure("url", f"not a Wallhaven image URL: {url}")
    match = PATH.match(parts.path)
    if not match or not match.group(3).startswith(match.group(1)):
        raise Failure("url", f"not a Wallhaven image path: {parts.path}")
    return match.group(2), match.group(4)


def emit(line: str) -> None:
    print(line, flush=True)


def open_url(url: str):
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    return urllib.request.urlopen(request, timeout=TIMEOUT)


def download(url: str, directory: Path, expected: int,
             opener: Callable[[str], object] = open_url) -> Path:
    name, extension = validate(url)
    if not 0 < expected <= MAX_BYTES:
        raise Failure("size", f"unexpected size {expected}")
    try:
        directory.mkdir(parents=True, exist_ok=True)
    except OSError as error:
        raise Failure("write", str(error)) from error
    target = directory / name
    # A file already saved from an earlier pick is used again as is.
    try:
        if target.is_file() and target.stat().st_size == expected:
            return target
    except OSError as error:
        raise Failure("write", str(error)) from error

    temporary = directory / f".{name}.{os.getpid()}.part"
    try:
        # 0o666 leaves the permissions to the caller's umask, as for any
        # other file the shell writes.
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o666)
    except OSError as error:
        raise Failure("write", str(error)) from error
    try:
        with os.fdopen(descriptor, "wb") as output:
            try:
                response = opener(url)
            except urllib.error.HTTPError as error:
                raise Failure("http", f"HTTP {error.code}") from error
            except (urllib.error.URLError, OSError) as error:
                raise Failure("network", str(error)) from error
            with response:
                status = getattr(response, "status", 200)
                if status != 200:
                    raise Failure("http", f"HTTP {status}")
                content_type = (response.headers.get("Content-Type") or "").split(";")[0].strip()
                if content_type != TYPES[extension]:
                    raise Failure("type", f"content type {content_type!r}")
                length = response.headers.get("Content-Length")
                if length is not None and (not length.isdigit() or int(length) != expected):
                    raise Failure("size", f"content length {length}, expected {expected}")
                received = 0
                reported = -1
                head = b""
                while True:
                    try:
                        chunk = response.read(CHUNK)
                    except OSError as error:
                        raise Failure("network", str(error)) from error
                    if not chunk:
                        break
                    received += len(chunk)
                    if received > expected:
                        raise Failure("size", f"more than {expected} bytes")
                    if len(head) < 8:
                        head += chunk[:8 - len(head)]
                    try:
                        output.write(chunk)
                    except OSError as error:
                        raise Failure("write", str(error)) from error
                    percent = received * 100 // expected
                    if percent >= reported + 5 or percent == 100:
                        reported = percent
                        emit(f"progress {percent}")
                if received != expected:
                    raise Failure("size", f"received {received} of {expected} bytes")
                if not head.startswith(SIGNATURES[extension]):
                    raise Failure("type", "file signature does not match its type")
            try:
                output.flush()
                os.fsync(output.fileno())
            except OSError as error:
                raise Failure("write", str(error)) from error
        try:
            os.replace(temporary, target)
        except OSError as error:
            raise Failure("write", str(error)) from error
        return target
    finally:
        temporary.unlink(missing_ok=True)


def terminate(signum, frame) -> None:
    # Unwinds through download()'s finally, which removes the .part file.
    raise Failure("interrupted", f"signal {signum}")


def main(argv: list[str]) -> int:
    if len(argv) != 4 or not argv[3].isdigit():
        print("usage: wallpaper-download.py URL DIRECTORY EXPECTED_BYTES", file=sys.stderr)
        return 2
    signal.signal(signal.SIGTERM, terminate)
    try:
        target = download(argv[1], Path(argv[2]).expanduser(), int(argv[3]))
    except Failure as failure:
        print(f"wallpaper download failed: {failure}", file=sys.stderr)
        emit(f"failed {failure.code}")
        return 1
    emit(f"done {target}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
