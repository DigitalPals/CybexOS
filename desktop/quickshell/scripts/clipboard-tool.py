#!/usr/bin/env python3
"""Pinned clipboard entries and image previews for the launcher's History tab.

  clipboard-tool.py previews [LINE...]     thumbnails for cliphist image lines
  clipboard-tool.py pin [--notify] LINE    keep a cliphist entry as a pin
  clipboard-tool.py unpin [--notify] ID    drop a pin
  clipboard-tool.py copy ID                put a pin back on the clipboard
  clipboard-tool.py pins                   print the pin index

`previews` prints one JSON object mapping each line it could decode to a file
URL, and deletes every cached preview not named this time: the cache only
ever holds what the current history shows. It lives in $XDG_RUNTIME_DIR, so
a logout clears it as well.

Pins are copies of the entry's bytes under ~/.local/share/cybexos/clipboard,
because cliphist prunes its database to the newest 500 entries and `cliphist
wipe` empties it. The store is bounded in count and size and refuses a new
pin rather than evicting one the user chose to keep. The launcher reads
pins.json directly; this helper is the only writer.
"""

from __future__ import annotations

import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import select
import shutil
import subprocess
import sys
import tempfile
import time

MAX_PINS = 50
MAX_TEXT_BYTES = 256 * 1024
MAX_IMAGE_BYTES = 10 * 1024 * 1024
MAX_PIN_STORE_BYTES = 64 * 1024 * 1024
PREVIEW_LIMIT = 48
MAX_DECODE_BYTES = 32 * 1024 * 1024
MAX_CACHE_FILES = 64
MAX_CACHE_BYTES = 48 * 1024 * 1024
THUMBNAIL = "512x512>"
DECODE_TIMEOUT = 10
MAGICK_TIMEOUT = 30
RAW_PREVIEW_LIMIT = 4 * 1024 * 1024

# Formats Qt and ImageMagick both read, recognized by their own bytes rather
# than by anything the clipboard owner claimed. The coder prefix pins
# ImageMagick to that decoder instead of letting it guess from the content.
FORMATS = (
    (b"\x89PNG\r\n\x1a\n", "png", "image/png"),
    (b"\xff\xd8\xff", "jpg", "image/jpeg"),
    (b"GIF87a", "gif", "image/gif"),
    (b"GIF89a", "gif", "image/gif"),
    (b"BM", "bmp", "image/bmp"),
)
CODERS = {"png": "png", "jpg": "jpeg", "gif": "gif", "bmp": "bmp", "webp": "webp"}
MIME = {"png": "image/png", "jpg": "image/jpeg", "gif": "image/gif", "bmp": "image/bmp",
        "webp": "image/webp", "txt": "text/plain;charset=utf-8"}


class ToolError(Exception):
    """A refusal the user should read, such as a full pin store."""


def image_format(data: bytes) -> str:
    if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return "webp"
    for magic, extension, _mime in FORMATS:
        if data.startswith(magic):
            return extension
    return ""


def display_of(line: str) -> str:
    _identifier, _tab, display = line.partition("\t")
    return " ".join((display if _tab else line).split())


def is_image_line(line: str) -> bool:
    return "binary data" in display_of(line).lower()


def data_home() -> Path:
    base = os.environ.get("XDG_DATA_HOME") or str(Path.home() / ".local/share")
    return Path(base)


def store_root() -> Path:
    return data_home() / "cybexos/clipboard"


def preview_root() -> Path:
    runtime = os.environ.get("XDG_RUNTIME_DIR")
    if runtime and Path(runtime).is_dir():
        return Path(runtime) / "cybexos/clipboard-previews"
    cache = os.environ.get("XDG_CACHE_HOME") or str(Path.home() / ".cache")
    return Path(cache) / "cybexos/clipboard-previews"


def private_directory(path: Path) -> Path:
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    if path.is_symlink() or not path.is_dir():
        raise ToolError(f"{path} is not a directory")
    return path


def read_limited(argv: list[str], payload: bytes, limit: int) -> bytes:
    """Run argv with payload on stdin and return at most `limit` bytes of output."""
    with tempfile.TemporaryFile() as source:
        source.write(payload)
        source.seek(0)
        process = subprocess.Popen(argv, stdin=source, stdout=subprocess.PIPE,
                                   stderr=subprocess.DEVNULL)
    deadline = time.monotonic() + DECODE_TIMEOUT
    chunks, size = [], 0
    try:
        while True:
            remaining = deadline - time.monotonic()
            ready = select.select([process.stdout], [], [], max(0, remaining))[0] if remaining > 0 else []
            if not ready:
                raise ToolError("Decoding the clipboard entry took too long")
            chunk = os.read(process.stdout.fileno(), 65536)
            if not chunk:
                break
            size += len(chunk)
            if size > limit:
                raise ToolError("The clipboard entry is too large")
            chunks.append(chunk)
        if process.wait(timeout=max(0.1, deadline - time.monotonic())) != 0:
            raise ToolError("The clipboard entry could not be decoded")
    except subprocess.TimeoutExpired as error:
        raise ToolError("Decoding the clipboard entry took too long") from error
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        process.stdout.close()
    return b"".join(chunks)


def decode(line: str, limit: int) -> bytes:
    if shutil.which("cliphist") is None:
        raise ToolError("cliphist is not installed")
    return read_limited(["cliphist", "decode"], line.encode("utf-8", "surrogateescape"), limit)


def write_atomic(path: Path, data: bytes, mode: int = 0o600) -> None:
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as output:
            output.write(data)
            output.flush()
            os.fchmod(output.fileno(), mode)
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def thumbnail(data: bytes, extension: str, output: Path) -> bool:
    """Write a PNG thumbnail of an image with ImageMagick under hard limits."""
    if shutil.which("magick") is None:
        return False
    descriptor, temporary = tempfile.mkstemp(prefix=f".{output.name}.", suffix=".png",
                                             dir=output.parent)
    os.close(descriptor)
    try:
        result = subprocess.run(
            ["magick", "-limit", "memory", "128MiB", "-limit", "map", "256MiB",
             "-limit", "width", "16KP", "-limit", "height", "16KP",
             "-limit", "area", "128MP", "-limit", "time", "20",
             f"{CODERS[extension]}:-[0]", "-auto-orient", "-thumbnail", THUMBNAIL,
             "-strip", f"png:{temporary}"],
            input=data, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            timeout=MAGICK_TIMEOUT, check=False)
        if result.returncode != 0 or os.path.getsize(temporary) == 0:
            return False
        os.chmod(temporary, 0o600)
        os.replace(temporary, output)
        return True
    except (OSError, subprocess.SubprocessError):
        return False
    finally:
        Path(temporary).unlink(missing_ok=True)


# ---- Previews -------------------------------------------------------------

def preview_key(line: str) -> str:
    return hashlib.sha256(line.encode("utf-8", "surrogateescape")).hexdigest()[:24]


def cached_preview(directory: Path, key: str) -> Path | None:
    for candidate in sorted(directory.glob(key + ".*")):
        if candidate.is_file() and not candidate.is_symlink():
            return candidate
    return None


def make_preview(directory: Path, line: str) -> Path | None:
    key = preview_key(line)
    existing = cached_preview(directory, key)
    if existing:
        with contextlib.suppress(OSError):
            os.utime(existing)
        return existing
    try:
        data = decode(line, MAX_DECODE_BYTES)
    except (ToolError, OSError):
        return None
    extension = image_format(data)
    if not extension:
        return None
    output = directory / f"{key}.png"
    if thumbnail(data, extension, output):
        return output
    # Without ImageMagick a small picture is still worth showing as it is.
    if len(data) <= RAW_PREVIEW_LIMIT:
        output = directory / f"{key}.{extension}"
        write_atomic(output, data)
        return output
    return None


def prune_previews(directory: Path, keep: set[str]) -> None:
    entries = []
    for entry in directory.iterdir():
        if not entry.is_file() or entry.is_symlink():
            continue
        if entry.name.startswith(".") or entry.name.split(".", 1)[0] not in keep:
            entry.unlink(missing_ok=True)
            continue
        entries.append(entry)
    entries.sort(key=lambda entry: entry.stat().st_mtime, reverse=True)
    total = 0
    for index, entry in enumerate(entries):
        total += entry.stat().st_size
        if index >= MAX_CACHE_FILES or total > MAX_CACHE_BYTES:
            entry.unlink(missing_ok=True)


def previews(lines: list[str]) -> dict[str, str]:
    directory = private_directory(preview_root())
    wanted = [line for line in lines if is_image_line(line)][:PREVIEW_LIMIT]
    made = {}
    for line in wanted:
        path = make_preview(directory, line)
        if path is not None:
            made[line] = path
    prune_previews(directory, {preview_key(line) for line in wanted})
    # The size bound may have dropped the oldest of this run's own previews.
    return {line: path.resolve().as_uri() for line, path in made.items() if path.exists()}


# ---- Pins -----------------------------------------------------------------

@contextlib.contextmanager
def locked_store():
    root = private_directory(store_root())
    private_directory(root / "pins")
    descriptor = os.open(root / ".lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield root


# The same names the launcher accepts (LauncherProviders.js parsePins).
PIN_NAME = re.compile(r"[0-9a-f]{16}(?:-thumb)?\.(?:txt|png|jpg|gif|webp|bmp)")


def valid_name(name: object) -> bool:
    return isinstance(name, str) and PIN_NAME.fullmatch(name) is not None


def read_index(root: Path) -> list[dict]:
    try:
        value = json.loads((root / "pins.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return []
    pins = value.get("pins") if isinstance(value, dict) else None
    result = []
    for pin in pins if isinstance(pins, list) else []:
        if not isinstance(pin, dict) or pin.get("kind") not in ("text", "image"):
            continue
        if not valid_name(pin.get("file")) or not (root / "pins" / pin["file"]).is_file():
            continue
        if pin.get("thumb") and not valid_name(pin["thumb"]):
            pin["thumb"] = ""
        result.append(pin)
    return result[:MAX_PINS]


def write_index(root: Path, pins: list[dict]) -> None:
    payload = json.dumps({"version": 1, "pins": pins}, ensure_ascii=False, indent=1)
    write_atomic(root / "pins.json", payload.encode("utf-8") + b"\n")
    # Files no pin names any more (an interrupted pin, an unpin) go too.
    referenced = {pin["file"] for pin in pins} | {pin.get("thumb") for pin in pins}
    for entry in (root / "pins").iterdir():
        if entry.name not in referenced and (entry.is_file() or entry.is_symlink()):
            entry.unlink(missing_ok=True)


def preview_text(data: bytes) -> str:
    text = data[:4096].decode("utf-8", "replace")
    return " ".join(text.split())[:200]


def pin(line: str) -> dict:
    if "\t" not in line:
        raise ToolError("This is not a clipboard history entry")
    image = is_image_line(line)
    data = decode(line, MAX_IMAGE_BYTES if image else MAX_TEXT_BYTES)
    if not data:
        raise ToolError("The clipboard entry is empty")
    extension = image_format(data) if image else "txt"
    if not extension:
        raise ToolError("This kind of clipboard entry cannot be pinned")
    identifier = hashlib.sha256(data).hexdigest()[:16]
    with locked_store() as root:
        pins = read_index(root)
        existing = next((entry for entry in pins if entry["id"] == identifier), None)
        if existing:
            # Pinning the same content again only moves it to the top.
            pins.remove(existing)
            existing["source"] = line[:400]
            pins.insert(0, existing)
            write_index(root, pins)
            return existing
        if len(pins) >= MAX_PINS:
            raise ToolError(f"Up to {MAX_PINS} entries can be pinned. Unpin one first.")
        used = sum((root / "pins" / entry["file"]).stat().st_size for entry in pins)
        if used + len(data) > MAX_PIN_STORE_BYTES:
            raise ToolError("Pinned entries are using all of their space. Unpin one first.")
        name = f"{identifier}.{extension}"
        write_atomic(root / "pins" / name, data)
        thumb = ""
        if image and thumbnail(data, extension, root / "pins" / f"{identifier}-thumb.png"):
            thumb = f"{identifier}-thumb.png"
        record = {
            "id": identifier,
            "kind": "image" if image else "text",
            "file": name,
            "thumb": thumb,
            "preview": "" if image else preview_text(data),
            "source": line[:400],
            "created": int(time.time()),
        }
        pins.insert(0, record)
        write_index(root, pins)
        return record


def unpin(identifier: str) -> bool:
    with locked_store() as root:
        pins = read_index(root)
        kept = [entry for entry in pins if entry["id"] != identifier]
        write_index(root, kept)
        return len(kept) != len(pins)


def copy(identifier: str) -> None:
    root = store_root()
    entry = next((pin for pin in read_index(root) if pin["id"] == identifier), None)
    if entry is None:
        raise ToolError("That pinned entry no longer exists")
    path = root / "pins" / entry["file"]
    mime = MIME[path.suffix.lstrip(".")]
    with path.open("rb") as source:
        # wl-copy keeps serving the selection from a forked child after it
        # returns; that child must not hold this process's output open.
        result = subprocess.run(["wl-copy", "--type", mime], stdin=source,
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                timeout=DECODE_TIMEOUT, check=False)
    if result.returncode != 0:
        raise ToolError("The pinned entry could not be copied")


def notify(message: str) -> None:
    if shutil.which("notify-send"):
        with contextlib.suppress(OSError, subprocess.SubprocessError):
            subprocess.run(["notify-send", "--app-name=Cybex OS", "Clipboard", message],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                           timeout=3, check=False)


def main(argv: list[str]) -> int:
    if not argv:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    command, arguments = argv[0], argv[1:]
    announce = "--notify" in arguments
    arguments = [argument for argument in arguments if argument != "--notify"]
    try:
        if command == "previews":
            print(json.dumps(previews(arguments)))
        elif command == "pins":
            print(json.dumps({"version": 1, "pins": read_index(store_root())}))
        elif command == "pin" and len(arguments) == 1:
            print(json.dumps(pin(arguments[0])))
        elif command == "unpin" and len(arguments) == 1:
            if not unpin(arguments[0]):
                raise ToolError("That pinned entry no longer exists")
        elif command == "copy" and len(arguments) == 1:
            copy(arguments[0])
        else:
            print(__doc__.strip(), file=sys.stderr)
            return 2
    except ToolError as error:
        print(f"clipboard-tool: {error}", file=sys.stderr)
        if announce:
            notify(str(error))
        return 1
    except OSError as error:
        print(f"clipboard-tool: {error}", file=sys.stderr)
        if announce:
            notify("The clipboard store could not be updated")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
