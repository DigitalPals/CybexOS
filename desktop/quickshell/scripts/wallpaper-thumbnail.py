#!/usr/bin/env python3
"""Create or reuse persistent, revisioned wallpaper thumbnails.

Takes one or more images and prints exactly one line per argument, in order
and flushed as each finishes: the thumbnail's file URL, or FAILED ("-") when
that image failed (the reason goes to stderr). One interpreter start then
serves a whole screenful of the wallpaper grid.
"""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
from urllib.parse import unquote, urlsplit


WIDTH = 640
HEIGHT = 384
QUALITY = 82
CACHE_VERSION = f"v2-jpeg-{WIDTH}x{HEIGHT}"
# One pathological image must not stall the grid's queue indefinitely.
MAGICK_TIMEOUT = 30
# Never an empty line: a line-splitting reader could drop it and misalign
# every answer after it.
FAILED = "-"


def source_path(value: str) -> Path:
    parsed = urlsplit(value)
    if parsed.scheme == "file":
        return Path(unquote(parsed.path))
    return Path(value).expanduser()


def cache_root() -> Path:
    base = os.environ.get("XDG_CACHE_HOME")
    if not base:
        base = str(Path.home() / ".cache")
    return Path(base) / "quickshell" / "wallpaper-thumbnails"


def cache_directory() -> Path:
    return cache_root() / CACHE_VERSION


def prune_stale_versions() -> None:
    """Drop thumbnail sets written under an older CACHE_VERSION."""
    try:
        entries = list(cache_root().iterdir())
    except OSError:
        return
    for entry in entries:
        if entry.name != CACHE_VERSION and entry.is_dir() and not entry.is_symlink():
            shutil.rmtree(entry, ignore_errors=True)


def source_identity(source: Path, stat: os.stat_result) -> dict[str, object]:
    return {
        "source": str(source),
        "size": stat.st_size,
        "mtime_ns": stat.st_mtime_ns,
        "version": CACHE_VERSION,
    }


def revision(identity: dict[str, object]) -> str:
    payload = json.dumps(identity, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(payload.encode()).hexdigest()[:16]


def read_metadata(path: Path) -> dict[str, object] | None:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
        return value if isinstance(value, dict) else None
    except (OSError, json.JSONDecodeError):
        return None


def write_metadata(path: Path, identity: dict[str, object]) -> None:
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    temporary.write_text(json.dumps(identity, sort_keys=True), encoding="utf-8")
    os.replace(temporary, path)


def thumbnail(source: Path) -> str:
    source = source.resolve(strict=True)
    stat = source.stat()
    identity = source_identity(source, stat)

    cache = cache_directory()
    cache.mkdir(parents=True, exist_ok=True)
    path_key = hashlib.sha256(str(source).encode()).hexdigest()[:32]
    output = cache / f"{path_key}.jpg"
    metadata = cache / f"{path_key}.json"

    if not output.is_file() or read_metadata(metadata) != identity:
        temporary = cache / f".{path_key}.{os.getpid()}.tmp.jpg"
        try:
            subprocess.run(
                [
                    "magick",
                    # Lets the JPEG decoder downscale while reading, instead
                    # of decoding a full-resolution photo only to shrink it;
                    # twice the target keeps the ^ fill crop sharp. Other
                    # formats ignore it.
                    "-define",
                    f"jpeg:size={WIDTH * 2}x{HEIGHT * 2}",
                    "-limit",
                    "memory",
                    "256MiB",
                    str(source),
                    "-auto-orient",
                    "-thumbnail",
                    f"{WIDTH}x{HEIGHT}^",
                    "-gravity",
                    "center",
                    "-extent",
                    f"{WIDTH}x{HEIGHT}",
                    "-strip",
                    "-quality",
                    str(QUALITY),
                    str(temporary),
                ],
                check=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
                text=True,
                timeout=MAGICK_TIMEOUT,
            )
            os.replace(temporary, output)
            write_metadata(metadata, identity)
        finally:
            temporary.unlink(missing_ok=True)

    return f"{output.resolve().as_uri()}?v={revision(identity)}"


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: wallpaper-thumbnail.py IMAGE...", file=sys.stderr)
        return 2
    prune_stale_versions()
    status = 0
    for value in sys.argv[1:]:
        try:
            line = thumbnail(source_path(value))
        except (OSError, subprocess.SubprocessError) as error:
            # TimeoutExpired and CalledProcessError are SubprocessErrors.
            print(f"wallpaper thumbnail failed for {value}: {error}", file=sys.stderr)
            line = FAILED
            status = 1
        print(line, flush=True)
    return status


if __name__ == "__main__":
    raise SystemExit(main())
