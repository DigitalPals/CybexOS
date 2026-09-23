#!/usr/bin/env python3
"""Resolve a web-notification origin to a browser-cached favicon."""

from __future__ import annotations

import hashlib
import ipaddress
import os
from pathlib import Path
import re
import sqlite3
import sys
import time


CACHE_MAX_AGE = 7 * 24 * 60 * 60
ROOTS_ENV = "QUICKSHELL_NOTIFICATION_ICON_CONFIG_ROOTS"
DNS_LABEL = re.compile(r"^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$")


def valid_origin(value: str) -> bool:
    if not value or value != value.lower() or len(value) > 253:
        return False
    if value.startswith("[") and value.endswith("]"):
        try:
            ipaddress.IPv6Address(value[1:-1])
            return True
        except ValueError:
            return False
    try:
        ipaddress.IPv4Address(value)
        return True
    except ValueError:
        pass
    if value == "localhost":
        return True
    labels = value.split(".")
    return len(labels) > 1 and all(DNS_LABEL.fullmatch(label) for label in labels)


def config_roots() -> list[Path]:
    override = os.environ.get(ROOTS_ENV)
    if override is not None:
        return [Path(value) for value in override.split(os.pathsep) if value]

    config = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config"))
    return [
        config / "BraveSoftware" / "Brave-Browser",
        config / "google-chrome",
        config / "chromium",
        config / "vivaldi",
        config / "microsoft-edge",
        config / "opera",
    ]


def favicon_databases() -> list[Path]:
    found: list[Path] = []
    seen: set[Path] = set()
    for root in config_roots():
        candidates = [root / "Favicons"]
        if root.is_dir():
            candidates.extend(sorted(root.glob("*/Favicons")))
        for candidate in candidates:
            if candidate.is_file() and candidate not in seen:
                found.append(candidate)
                seen.add(candidate)
    return found


FAVICON_QUERY = """
    SELECT b.image_data, b.width, b.height, b.last_updated
      FROM icon_mapping AS m
      JOIN favicon_bitmaps AS b ON b.icon_id = m.icon_id
     WHERE ({where})
       AND b.image_data IS NOT NULL
       AND length(b.image_data) > 0
     ORDER BY (b.width * b.height) DESC, b.last_updated DESC
     LIMIT 1
"""


def best_favicon(database: Path, origin: str) -> tuple[int, int, bytes] | None:
    prefixes = [f"https://{origin}", f"http://{origin}"]
    # The origin's own root page is almost always mapped, and an exact
    # `page_url IN (...)` is answered from the page_url index. The
    # case-insensitive LIKE scan of the whole table is only the fallback for
    # sites whose icon is known solely through deeper pages.
    exact = [value for prefix in prefixes for value in (prefix, prefix + "/")]
    params: list[str] = []
    clauses: list[str] = []
    for prefix in prefixes:
        clauses.extend(["m.page_url = ?", "m.page_url LIKE ?", "m.page_url LIKE ?"])
        params.extend([prefix, prefix + "/%", prefix + ":%"])

    uri = database.resolve().as_uri() + "?immutable=1"
    try:
        connection = sqlite3.connect(uri, uri=True, timeout=0.25)
        try:
            row = connection.execute(
                FAVICON_QUERY.format(where="m.page_url IN (" + ", ".join("?" * len(exact)) + ")"),
                exact).fetchone()
            if not row:
                row = connection.execute(
                    FAVICON_QUERY.format(where=" OR ".join(clauses)), params).fetchone()
        finally:
            connection.close()
    except (OSError, sqlite3.Error):
        return None
    if not row:
        return None
    data, width, height, updated = row
    return int(width or 0) * int(height or 0), int(updated or 0), bytes(data)


def cached_path(origin: str) -> Path:
    cache_root = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache"))
    digest = hashlib.sha256(origin.encode("ascii")).hexdigest()
    return cache_root / "quickshell" / "notification-icons" / f"{digest}.png"


def fresh(path: Path) -> bool:
    try:
        stat = path.stat()
        return stat.st_size > 0 and time.time() - stat.st_mtime < CACHE_MAX_AGE
    except OSError:
        return False


def write_cache(path: Path, data: bytes) -> bool:
    temporary = path.with_name(f".{path.name}.{os.getpid()}")
    try:
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        os.chmod(path.parent, 0o700)
        with temporary.open("xb") as output:
            output.write(data)
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
        return True
    except OSError:
        try:
            temporary.unlink()
        except OSError:
            pass
        return False


def resolve(origin: str) -> str:
    cache = cached_path(origin)
    if fresh(cache):
        return cache.resolve().as_uri()

    candidates: list[tuple[int, int, bytes]] = []
    for database in favicon_databases():
        candidate = best_favicon(database, origin)
        if candidate is not None:
            candidates.append(candidate)
    if candidates:
        data = max(candidates, key=lambda candidate: candidate[:2])[2]
        if write_cache(cache, data):
            return cache.resolve().as_uri()
    try:
        if cache.is_file() and cache.stat().st_size > 0:
            return cache.resolve().as_uri()
    except OSError:
        pass
    return f"https://{origin}/favicon.ico"


def main(argv: list[str]) -> int:
    if len(argv) != 2 or not valid_origin(argv[1]):
        return 2
    print(resolve(argv[1]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
