#!/usr/bin/env python3
"""Private notification history; one bounded JSON-lines process per shell.

Only a small inert whitelist reaches disk. Reads/writes use directory-relative
O_NOFOLLOW descriptors; an invalid, corrupt or oversized file restores empty.
"""
import json
import ipaddress
import math
import os
import re
import stat
import sys
import time
import unicodedata

HARD_BYTES = 1048576
MAX_REQUEST = 8388608
FIELDS = {"arrived", "appName", "desktopEntry", "webOrigin", "webSourceIdentity", "displayAppName",
          "displaySummary", "displayBody", "urgency", "occurrences"}
WORDS = re.compile(r"\b(verificatiecode|beveiligingscode|inlogcode|bevestigingscode|toegangscode|pincode|code|otp|one[\s-]?time|verification|verify|passcode|pin|2fa|two[\s-]factor|security key|confirm(?:ation)?)\b", re.I)
SHAPE = re.compile(r"(?<![\w-])(?:[A-Za-z]-)?(?:\d{2,4}[\s-]\d{2,5}|\d{4,8}|(?=[A-Z0-9]{5,8}(?![\w-]))(?=[A-Z0-9]*[A-Z])(?=[A-Z0-9]*\d)[A-Z0-9]{5,8})(?![\w-])")


def integer(value, lower, upper, default):
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        return default
    return max(lower, min(upper, round(value)))


def limits(request):
    return (integer(request.get("count"), 10, 200, 50),
            integer(request.get("hours"), 1, 168, 24),
            integer(request.get("bytes"), 16384, HARD_BYTES, 262144))


def text(value, size):
    if not isinstance(value, str):
        return ""
    # Strip control, bidi and zero-width formatting characters, preserving LF.
    return "".join(c for c in value[:size] if c == "\n" or not unicodedata.category(c).startswith("C"))


def secret(value, depth=0):
    """Also inspect alternate fields before whitelisting (never persist them)."""
    if depth > 4:
        return False
    if isinstance(value, str):
        import html
        candidate = value[:65536]
        for _ in range(3):
            candidate = html.unescape(candidate)
        candidate = re.sub(r"<[^>]*>", " ", candidate)
        candidate = text(candidate, 65536)
        # Storage is deliberately more conservative than the copy affordance.
        return bool(WORDS.search(candidate) and SHAPE.search(candidate))
    if isinstance(value, dict):
        if value.get("code") or value.get("codes") or value.get("redacted"):
            return True
        strings = [v for v in list(value.values())[:64] if isinstance(v, str)]
        if strings and secret(" ".join(strings), depth + 1):
            return True
        return any(secret(v, depth + 1) for v in list(value.values())[:64])
    if isinstance(value, list):
        return any(secret(v, depth + 1) for v in value[:64])
    return False


def origin_host(value, preserve_root_dot=False):
    if not isinstance(value, str) or not value.isascii() or len(value) > 253:
        return ""
    host = value.lower().removesuffix(".")
    root_dot = "." if preserve_root_dot and value.endswith(".") else ""
    if host.startswith("[") and host.endswith("]"):
        try:
            expanded = ipaddress.IPv6Address(host[1:-1]).exploded
            return "[" + ":".join(format(int(word, 16), "x") for word in expanded.split(":")) + "]"
        except ipaddress.AddressValueError:
            return ""
    if host == "localhost":
        return host + root_dot
    if re.fullmatch(r"(?:[0-9]+\.){3}[0-9]+", host):
        try:
            return str(ipaddress.IPv4Address(host))
        except ipaddress.AddressValueError:
            return ""
    label = r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?"
    if (not re.fullmatch(label + r"(?:\." + label + r")+", host)
            or re.fullmatch(r"(?:0x[0-9a-f]*|[0-9]+)", host.rsplit(".", 1)[-1])):
        return ""
    return host + root_dot


def source_identity(value, hostname):
    """Only canonical origin authorities; legacy hosts never acquire a scheme."""
    fallback = "unqualified:" + hostname if hostname else ""
    if not isinstance(value, str) or len(value) > 320 or not hostname:
        return fallback
    match = re.fullmatch(r"(https?://|unqualified:)(\[[0-9a-f:]+\]|[a-z0-9.-]+)(?::([0-9]{1,5}))?", value)
    if not match or origin_host(match[2]) != hostname:
        return fallback
    prefix, host, port_text = match.groups()
    port = int(port_text) if port_text else 0
    if (prefix != "unqualified:" and not port_text) or (port_text and not 1 <= port <= 65535):
        return fallback
    canonical = prefix + origin_host(host, preserve_root_dot=True) + (":" + str(port) if port_text else "")
    return canonical if canonical == value else fallback


def sanitize(row, now, hours):
    if not isinstance(row, dict):
        return None
    at = row.get("arrived")
    if isinstance(at, bool) or not isinstance(at, (int, float)) or not math.isfinite(at):
        return None
    if at <= now - hours * 3600000 or at > now + 60000:
        return None
    clean = {"arrived": int(at), "urgency": integer(row.get("urgency"), 0, 2, 1),
             "occurrences": integer(row.get("occurrences"), 1, 9999, 1)}
    if secret(row):
        clean.update(appName="Notification", desktopEntry="", webOrigin="", webSourceIdentity="",
                     displayAppName="Notification", displaySummary="Verification notification",
                     displayBody="Content redacted")
    else:
        for name, size in (("appName", 256), ("desktopEntry", 256), ("webOrigin", 253),
                           ("displayAppName", 256), ("displaySummary", 2048), ("displayBody", 4096)):
            clean[name] = text(row.get(name), size)
        if not re.fullmatch(r"[A-Za-z0-9_.-]{1,256}", clean["desktopEntry"]):
            clean["desktopEntry"] = ""
        clean["webOrigin"] = origin_host(clean["webOrigin"])
        clean["webSourceIdentity"] = source_identity(row.get("webSourceIdentity"), clean["webOrigin"])
    return clean


def bounded_rows(rows, request, now=None):
    count, hours, budget = limits(request)
    now = time.time() * 1000 if now is None else now
    if not isinstance(rows, list):
        return []
    clean = [entry for row in rows[:200] if (entry := sanitize(row, now, hours)) is not None]
    clean.sort(key=lambda row: row["arrived"], reverse=True)
    clean = clean[:count]
    while len(encode(clean)) > budget:
        clean.pop()
    return clean


def encode(rows):
    return (json.dumps({"v": 1, "entries": rows}, ensure_ascii=True, separators=(",", ":")) + "\n").encode()


def state_dir(create):
    base = os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state")
    if not os.path.isabs(base):
        base = os.path.expanduser("~/.local/state")
    if create:
        os.makedirs(base, mode=0o700, exist_ok=True)
    # The XDG root is user configured; owned descendants may never be symlinks.
    fd = os.open(base, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        for part in ("nerdos", "notifications"):
            if create:
                try:
                    os.mkdir(part, mode=0o700, dir_fd=fd)
                except FileExistsError:
                    pass
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = child
            st = os.fstat(fd)
            if st.st_uid != os.getuid():
                raise PermissionError("notification directory owner")
        os.fchmod(fd, 0o700)
        return fd
    except BaseException:
        os.close(fd)
        raise


def load(request):
    try:
        directory = state_dir(False)
    except FileNotFoundError:
        return []
    try:
        try:
            fd = os.open("history.json", os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
        except (FileNotFoundError, OSError):
            return []
        with os.fdopen(fd, "rb") as stream:
            st = os.fstat(stream.fileno())
            if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid() or st.st_size > HARD_BYTES:
                return []
            # Never read history that another user could have read or modified.
            if st.st_mode & 0o077:
                return []
            value = json.loads(stream.read(HARD_BYTES + 1))
            if not isinstance(value, dict) or value.get("v") != 1:
                return []
            return bounded_rows(value.get("entries"), request)
    except (ValueError, UnicodeError):
        return []
    finally:
        os.close(directory)


def save(request):
    rows = bounded_rows(request.get("entries"), request)
    directory = state_dir(True)
    temp = ".history-" + str(os.getpid()) + "-" + str(time.monotonic_ns())
    try:
        fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=directory)
        with os.fdopen(fd, "wb") as stream:
            stream.write(encode(rows))
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temp, "history.json", src_dir_fd=directory, dst_dir_fd=directory)
        os.fsync(directory)
    finally:
        try:
            os.unlink(temp, dir_fd=directory)
        except FileNotFoundError:
            pass
        os.close(directory)
    return rows


def clear():
    try:
        directory = state_dir(False)
    except FileNotFoundError:
        return
    try:
        try:
            os.unlink("history.json", dir_fd=directory)
            os.fsync(directory)
        except FileNotFoundError:
            pass
    finally:
        os.close(directory)


def main():
    while True:
        line = sys.stdin.buffer.readline(MAX_REQUEST + 1)
        if not line:
            return
        if len(line) > MAX_REQUEST:
            # A framing error cannot safely be recovered; never parse a tail.
            return
        request = {}
        try:
            request = json.loads(line)
            if not isinstance(request, dict):
                raise ValueError("request shape")
            op = request.get("op")
            if op == "read":
                rows = load(request)
                # Repair corrupt/expired/legacy files atomically after reading.
                save(dict(request, entries=rows))
            elif op == "write":
                rows = save(request)
            elif op == "clear":
                clear()
                rows = []
            else:
                raise ValueError("operation")
            reply = {"id": request.get("id"), "ok": True, "op": op}
            if op == "read":
                reply["entries"] = rows
        except (OSError, ValueError, TypeError, RecursionError):
            reply = {"id": request.get("id"), "ok": False, "op": request.get("op")}
        print(json.dumps(reply, separators=(",", ":")), flush=True)


if __name__ == "__main__":
    main()
