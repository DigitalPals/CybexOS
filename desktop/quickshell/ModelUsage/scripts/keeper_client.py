"""Read-only CPA Usage Keeper transport for quota account activity."""
from __future__ import annotations

import http.client
import http.cookiejar
import json
import os
import stat
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

MAX_RESPONSE_BYTES = 32 * 1024 * 1024


class KeeperError(ValueError):
    pass


def normalize_url(value: str) -> str:
    try:
        if any(ord(c) < 32 or ord(c) == 127 for c in value):
            raise ValueError
        url = urllib.parse.urlsplit(value.strip())
        url.port
        if (url.scheme not in ("http", "https") or not url.hostname or url.username is not None
                or url.password is not None or url.query or url.fragment):
            raise ValueError
        path = url.path.rstrip("/")
        if path.endswith("/api/v1"):
            path = path[:-7]
        if any(p in (".", "..") for p in urllib.parse.unquote(path).split("/")):
            raise ValueError
        return urllib.parse.urlunsplit((url.scheme, url.netloc, path, "", ""))
    except (ValueError, TypeError, AttributeError):
        raise KeeperError("Set the CPA Usage Keeper HTTP(S) URL in widget settings.") from None


def read_password(path: Path) -> str:
    try:
        fd = os.open(path.expanduser(), os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
                raise ValueError
            raw = os.read(fd, 8193)
        finally:
            os.close(fd)
        value = raw.decode("utf-8").strip()
        if not value or len(raw) > 8192 or any(ord(c) < 32 for c in value):
            raise ValueError
        return value
    except (OSError, ValueError, UnicodeError):
        raise KeeperError("Keeper password file must be private (0600), owned by you, and contain the login password.") from None


class NoRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class Client:
    def __init__(self, url: str, timeout: float):
        self.url = normalize_url(url)
        self.deadline = time.monotonic() + timeout
        self.opener = urllib.request.build_opener(
            NoRedirects(), urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))

    def request(self, path: str, payload=None, limit=MAX_RESPONSE_BYTES):
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            raise KeeperError("Keeper activity request timed out.")
        headers = {"Accept": "application/json", "X-CPA-Usage-Keeper-Request": "fetch"}
        data = None
        if payload is not None:
            data = json.dumps(payload).encode()
            headers["Content-Type"] = "application/json"
        req = urllib.request.Request(self.url + "/api/v1/" + path, headers=headers, data=data)
        try:
            with self.opener.open(req, timeout=remaining) as response:
                chunks, size = [], 0
                while size <= limit:
                    if time.monotonic() > self.deadline:
                        raise KeeperError("Keeper activity request timed out.")
                    chunk = response.read1(min(65536, limit + 1 - size))
                    if not chunk:
                        break
                    chunks.append(chunk)
                    size += len(chunk)
                raw = b"".join(chunks)
            if len(raw) > limit:
                raise KeeperError("Keeper activity exceeds the download limit; check the server.")
            if time.monotonic() > self.deadline:
                raise KeeperError("Keeper activity request timed out.")
            return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as exc:
            code = exc.code
            exc.close()
            if code in (401, 403):
                raise KeeperError("Keeper rejected the login. Check its password in widget settings.") from None
            if code == 404:
                raise KeeperError("Keeper activity endpoint was not found. Use the Keeper URL, not the CLIProxyAPI URL.") from None
            raise KeeperError(f"Keeper activity returned HTTP {code}.") from None
        except (urllib.error.URLError, OSError, TimeoutError, http.client.HTTPException):
            raise KeeperError("Could not reach CPA Usage Keeper. Check the URL, connection, and certificate.") from None
        except (UnicodeError, json.JSONDecodeError):
            raise KeeperError("Keeper returned incomplete or unreadable history.") from None
