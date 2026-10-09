#!/usr/bin/env python3
"""Fusebox widget transport.

`live` holds one authenticated WebSocket to Fusebox's management API and
prints newline-delimited JSON for Common/Fusebox.qml: a snapshot of the
server, its accounts and its faults on every connect, then each change.
`action` and `activity` are one-shot requests for the dashboard's breaker
buttons and account details. `store-key`, `forget-key` and `key-status` own
the private management key file.

The key is read from that file, sent only in an Authorization header and
never printed, logged, or put in argv or a URL. Only allowlisted fields reach
QML: /api/overview also carries client API keys and server paths, which are
dropped here.
"""
from __future__ import annotations

import argparse
from datetime import datetime
import json
import math
import os
from pathlib import Path
import re
import stat
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

MAX_RESPONSE = 2 * 1024 * 1024
MAX_FRAME = 1024 * 1024
MAX_ACCOUNTS = 512
MAX_FAULTS = 128
MAX_KEY = 8192
HEARTBEAT = 5       # seconds between heartbeat lines, so QML can tell a stalled helper
STALE = 20          # Fusebox ticks every 5 s; this long without a frame is a dead socket
COALESCE = 3        # at most one account refetch this often after `accounts` events
IDLE_REFRESH = 60   # quota and token state also change without an event
DERIVE_EVERY = 5    # older servers: re-derive faults so expired pauses clear
SETUP_RECHECK = 5   # waiting for a key: look for it this often

ACCOUNT_KINDS = ("oauth", "api-key", "service-account")
FAULT_KINDS = ("signin", "quota", "rate_limit", "error", "failures", "provider")
# The dashboard's SIGNIN_ERR (ui/app.js) and push/faults.rs signin_error().
SIGNIN_ERROR = re.compile(r"invalid_grant|refresh token|sign in again|re-?authenticat|unauthori[sz]ed"
                          r"|\b401\b|token (?:has )?expired|expired token|revoked", re.I)
IDENT = re.compile(r"[a-z0-9][a-z0-9_.:-]{0,95}")
WINDOW = re.compile(r"[a-z0-9]{1,16}")
CONTROL = re.compile(r"[\x00-\x1f\x7f]")


class Failure(Exception):
    """A user-presentable failure. Never carries exception text, headers or the key."""

    def __init__(self, state: str, message: str, status: int | None = None):
        super().__init__(message)
        self.state = state
        self.message = message
        self.status = status


# ---------------------------------------------------------------- the key


def key_path() -> Path:
    config = os.environ.get("XDG_CONFIG_HOME", "")
    base = Path(config) if config.startswith("/") else Path.home() / ".config"
    return base / "cybexos" / "fusebox" / "management.key"


def valid_key(text: str) -> bool:
    return 0 < len(text) <= MAX_KEY and all(32 < ord(char) < 127 for char in text)


def read_key(path: Path | None = None) -> str:
    path = path or key_path()
    try:
        # NONBLOCK keeps a misplaced FIFO from stalling the widget.
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        raise Failure("setup", "Enter the management key in Fusebox settings.") from None
    except OSError:
        raise Failure("setup", "The saved management key can't be read. Enter it again in Fusebox settings.") from None
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise Failure("setup", "The management key file must be a private file you own. Enter the key again.")
        raw = os.read(fd, MAX_KEY + 2)
    finally:
        os.close(fd)
    try:
        key = raw.decode("ascii").strip()
    except UnicodeDecodeError:
        key = ""
    if not valid_key(key):
        raise Failure("setup", "The saved management key is not valid. Enter it again in Fusebox settings.")
    return key


def private_directory(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        os.mkdir(path, 0o700)
    except FileExistsError:
        pass
    info = os.lstat(path)
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
        raise Failure("setup", "The Fusebox settings folder is not a folder you own.")
    if info.st_mode & 0o077:
        os.chmod(path, 0o700)


def store_key(text: str, path: Path | None = None) -> None:
    path = path or key_path()
    key = text.strip()
    if not valid_key(key):
        raise Failure("setup", "A management key is one line of printable characters without spaces.")
    private_directory(path.parent)
    fd, temporary = tempfile.mkstemp(prefix=".management.", dir=path.parent)  # created 0600
    try:
        with os.fdopen(fd, "w", encoding="ascii") as stream:
            stream.write(key + "\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise


def forget_key(path: Path | None = None) -> None:
    path = path or key_path()
    try:
        info = os.lstat(path)
    except FileNotFoundError:
        return
    if stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode):
        os.unlink(path)


# ---------------------------------------------------------------- HTTP


def normalize_url(address: str) -> str:
    """The server's base URL. Dashboard links are accepted; credentials and queries are not."""
    text = (address or "").strip()
    if not text:
        raise Failure("setup", "Enter the Fusebox server URL in Fusebox settings.")
    try:
        if CONTROL.search(text):
            raise ValueError
        parts = urllib.parse.urlsplit(text)
        parts.port  # Validates the port.
        if (parts.scheme not in ("http", "https") or not parts.hostname
                or parts.username is not None or parts.password is not None or parts.query):
            raise ValueError
        path = parts.path.rstrip("/")
        if path.endswith("/api"):
            path = path[:-4]
        if any(segment in (".", "..") for segment in urllib.parse.unquote(path).split("/")):
            raise ValueError
        return urllib.parse.urlunsplit((parts.scheme, parts.netloc, path, "", ""))
    except ValueError:
        raise Failure("setup", "The Fusebox URL must be an http(s) address without a user name, password or query.") from None


def websocket_url(base: str) -> str:
    parts = urllib.parse.urlsplit(base)
    return urllib.parse.urlunsplit(("wss" if parts.scheme == "https" else "ws", parts.netloc,
                                    parts.path + "/api/live", "", ""))


class NoRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        # The key must never follow a redirect to another origin.
        return None


def server_message(body: bytes) -> str:
    try:
        value = json.loads(body).get("error")
    except (ValueError, AttributeError, UnicodeDecodeError, RecursionError):
        return ""
    return clean(value, 300) or ""


class Client:
    def __init__(self, base: str, key: str):
        self.base = base
        self.key = key
        self.opener = urllib.request.build_opener(NoRedirects(), urllib.request.ProxyHandler({}))

    def request(self, path: str, *, method: str = "GET", payload: dict | None = None, timeout: float = 10):
        headers = {"Authorization": "Bearer " + self.key, "Accept": "application/json"}
        data = None
        if payload is not None:
            headers["Content-Type"] = "application/json"
            data = json.dumps(payload).encode()
        request = urllib.request.Request(self.base + "/api/" + path, data=data, headers=headers, method=method)
        try:
            with self.opener.open(request, timeout=timeout) as response:
                raw = response.read(MAX_RESPONSE + 1)
        except urllib.error.HTTPError as error:
            body = error.read(65536) if error.fp else b""
            error.close()
            raise http_failure(error.code, server_message(body)) from None
        except (TimeoutError, urllib.error.URLError, OSError):
            raise Failure("offline", "Can't reach Fusebox. Check the URL, the network and its TLS certificate.") from None
        if len(raw) > MAX_RESPONSE:
            raise Failure("offline", "Fusebox sent an unexpectedly large response.")
        try:
            return json.loads(raw)
        except (ValueError, UnicodeDecodeError, RecursionError):
            raise Failure("offline", "Fusebox sent a response the widget can't read.") from None


def http_failure(status: int, message: str = "") -> Failure:
    if status == 401:
        return Failure("auth", "Fusebox rejected the management key.", status)
    if status == 403:
        return Failure("auth", "Fusebox refused remote management. Set management-key on the server.", status)
    if 300 <= status < 400:
        return Failure("offline", "Fusebox redirected the request. Enter the server's own URL.", status)
    if status == 404:
        return Failure("missing", message or "Fusebox doesn't have this feature.", status)
    return Failure("offline", message or f"Fusebox answered HTTP {status}.", status)


# ---------------------------------------------------------------- normalizing


def clean(value, limit: int):
    if not isinstance(value, str):
        return None
    text = CONTROL.sub(" ", value).strip()
    return text[:limit] if text else None


def mapping(value) -> dict:
    return value if isinstance(value, dict) else {}


def count(value) -> int:
    return value if isinstance(value, int) and not isinstance(value, bool) and 0 <= value < 2 ** 53 else 0


def epoch_ms(value):
    """RFC 3339 to epoch milliseconds. Fusebox sends nanoseconds, which Python 3.9 can't parse."""
    if not isinstance(value, str) or len(value) > 64:
        return None
    text = value.strip()
    if text.endswith(("Z", "z")):
        text = text[:-1] + "+00:00"
    match = re.fullmatch(r"(\d{4}-\d\d-\d\d[T ]\d\d:\d\d:\d\d)(?:\.(\d{1,9}))?([+-]\d\d:\d\d)", text)
    if not match:
        return None
    fraction = (match.group(2) or "")[:6].ljust(6, "0")
    try:
        moment = datetime.fromisoformat(f"{match.group(1)}.{fraction}{match.group(3)}")
    except ValueError:
        return None
    return int(moment.timestamp() * 1000)


def window(row):
    if not isinstance(row, dict) or not isinstance(row.get("name"), str) or not WINDOW.fullmatch(row["name"]):
        return None
    used = row.get("used")
    if isinstance(used, bool) or not isinstance(used, (int, float)) or not math.isfinite(used):
        return None
    return {"name": row["name"], "used": max(0.0, min(100.0, float(used))),
            "resetsAt": epoch_ms(row.get("resets_at")), "model": clean(row.get("model"), 160)}


def account(row):
    if (not isinstance(row, dict) or not isinstance(row.get("id"), str) or not 0 < len(row["id"]) <= 512
            or CONTROL.search(row["id"]) or not isinstance(row.get("provider"), str)
            or not IDENT.fullmatch(row["provider"]) or row.get("kind") not in ACCOUNT_KINDS
            or not isinstance(row.get("disabled"), bool)):
        return None
    kinds = mapping(row.get("cooldown_kinds"))
    cooldowns = []
    for model, until in list(mapping(row.get("cooldowns")).items())[:64]:
        at, name, kind = epoch_ms(until), clean(model, 160), kinds.get(model)
        if at is not None and name:
            # As in the dashboard, a pause of unknown kind is a rate limit.
            known = isinstance(kind, str) and re.fullmatch(r"[a-z_]{1,24}", kind)
            cooldowns.append({"model": name, "until": at, "kind": kind if known else "rate_limit"})
    quota = mapping(row.get("quota"))
    rows = quota.get("windows") if isinstance(quota.get("windows"), list) else []
    windows = [w for w in map(window, rows[:16]) if w]
    counters = mapping(row.get("counters"))
    inventory = mapping(mapping(row.get("banked_resets")).get("inventory"))
    return {
        "id": row["id"],
        "provider": row["provider"],
        "group": clean(row.get("group"), 64),
        "label": clean(row.get("label"), 200) or row["id"][:200],
        "email": clean(row.get("email"), 320),
        "kind": row["kind"],
        "disabled": row["disabled"],
        "cooldowns": cooldowns,
        "lastError": clean(row.get("last_error"), 300),
        "lastUsed": epoch_ms(row.get("last_used")),
        "expiresAt": epoch_ms(row.get("expires_at")),
        "requests": count(counters.get("requests")),
        "failures": count(counters.get("failures")),
        "plan": clean(quota.get("plan"), 32),
        "quotaAt": epoch_ms(quota.get("updated_at")),
        "windows": windows,
        "banked": count(inventory.get("available")),
        "models": len(row["models"]) if isinstance(row.get("models"), list) else 0,
    }


def accounts(payload):
    if not isinstance(payload, list) or len(payload) > MAX_ACCOUNTS:
        raise Failure("offline", "Fusebox sent an account list the widget can't read.")
    seen, out = set(), []
    for row in payload:
        entry = account(row)
        if entry and entry["id"] not in seen:
            seen.add(entry["id"])
            out.append(entry)
    return out


def fault(row):
    if (not isinstance(row, dict) or row.get("kind") not in FAULT_KINDS or row.get("level") not in ("err", "warn")
            or not clean(row.get("key"), 600) or not clean(row.get("title"), 200)):
        return None
    path = clean(row.get("path"), 600) or ""
    return {
        "key": clean(row["key"], 600),
        "kind": row["kind"],
        "level": row["level"],
        "provider": clean(row.get("provider"), 96) or "",
        "providerName": clean(row.get("provider_name"), 64) or "",
        "accountId": clean(row.get("account_id"), 512),
        "label": clean(row.get("label"), 200),
        "title": clean(row["title"], 200),
        "detail": clean(row.get("detail"), 300),
        "until": epoch_ms(row.get("until")),
        "path": path if path.startswith("#/") else "",
    }


def faults(payload):
    if not isinstance(payload, list):
        raise Failure("offline", "Fusebox sent a fault list the widget can't read.")
    out = [f for f in map(fault, payload[:MAX_FAULTS]) if f]
    return sorted(out, key=lambda f: f["level"] != "err")


PROVIDER_NAMES = {"claude": "Claude", "codex": "Codex", "gemini": "Gemini", "vertex": "Vertex AI",
                  "antigravity": "Antigravity", "kimi": "Kimi", "xai": "Grok", "meta": "Meta",
                  "devin": "Devin", "openai-compat": "Compatible"}


def provider_name(entry) -> str:
    if entry["provider"] == "openai-compat":
        return entry["group"] or "Compatible"
    if entry["kind"] == "api-key" and entry["provider"] in ("xai", "codex"):
        return "xAI" if entry["provider"] == "xai" else "OpenAI"
    return PROVIDER_NAMES.get(entry["provider"], entry["provider"])


def window_title(name: str) -> str:
    if name == "5h":
        return "5-hour"
    if name == "day":
        return "Daily"
    return "Short" if re.fullmatch(r"\d+h", name) else "Weekly"


def spent_window(windows, now_ms):
    live = [w for w in windows if not w["model"] and (w["resetsAt"] is None or w["resetsAt"] > now_ms)]
    for short in (True, False):
        group = [w for w in live if bool(re.fullmatch(r"\d+h", w["name"])) == short]
        if group:
            top = max(group, key=lambda w: w["used"])
            if top["used"] >= 100:
                return top
    return None


def derived_faults(entries, now_ms):
    """Account faults for Fusebox releases without /api/faults: the same rules as
    push/faults.rs, without the request-failure and whole-provider faults, which
    need the server's request history."""
    out = []
    for a in entries:
        if a["disabled"]:
            continue

        def item(kind, level, title, detail=None, until=None):
            out.append({"key": f"{'rate' if kind == 'rate_limit' else kind}:{a['id']}", "kind": kind,
                        "level": level, "provider": a["provider"], "providerName": provider_name(a),
                        "accountId": a["id"], "label": a["label"], "title": title, "detail": detail,
                        "until": until, "path": "#/accounts/" + urllib.parse.quote(a["id"], safe="")})

        pauses = [c for c in a["cooldowns"] if c["until"] > now_ms]
        latest = max(pauses, key=lambda c: c["until"]) if pauses else None
        if latest and latest["kind"] == "quota":
            spent = spent_window(a["windows"], now_ms)
            item("quota", "warn", (window_title(spent["name"]) if spent else "Usage") + " limit used up",
                 until=(spent and spent["resetsAt"]) or latest["until"])
        elif latest and latest["kind"] == "rate_limit":
            what = "Every model" if latest["model"] == "*" else latest["model"]
            item("rate_limit", "warn", "Rate limited", f"{what} is paused.", latest["until"])
        if latest is None and a["lastError"]:
            if a["kind"] != "api-key" and SIGNIN_ERROR.search(a["lastError"]):
                item("signin", "err", "Sign-in expired", "Sign in again to put it back in rotation.")
            else:
                item("error", "err", "Account error", a["lastError"][:160])
    return sorted(out, key=lambda f: f["level"] != "err")


TOTALS = ("requests", "ok", "failed", "cancelled", "input_tokens", "output_tokens", "cache_tokens")
BUCKET = ("requests", "failed", "cancelled", "input_tokens", "output_tokens", "cache_tokens")


def totals(value):
    value = value if isinstance(value, dict) else {}
    return {key: count(value.get(key)) for key in TOTALS}


def overview(payload):
    if not isinstance(payload, dict):
        raise Failure("offline", "Fusebox sent a summary the widget can't read.")
    series = []
    for bucket in (payload.get("series") or [])[-120:] if isinstance(payload.get("series"), list) else []:
        if isinstance(bucket, dict) and isinstance(bucket.get("minute"), int) and not isinstance(bucket["minute"], bool):
            series.append({"minute": bucket["minute"], **{key: count(bucket.get(key)) for key in BUCKET}})
    summary = payload.get("accounts") if isinstance(payload.get("accounts"), dict) else {}
    # Deliberately not copied: client_keys, base_url, config_path, auth_dir.
    return {
        "version": clean(payload.get("version"), 64),
        "startedAt": epoch_ms(payload.get("started_at")),
        "routing": clean(payload.get("routing"), 32),
        "sessionAffinity": payload.get("session_affinity") is True,
        "bankedResets": payload.get("banked_resets") is True,
        "totals": totals(payload.get("totals")),
        "active": count(payload.get("active")),
        "series": series,
        "models": count(payload.get("models")),
        "accounts": {key: count(summary.get(key)) for key in ("total", "active", "cooling", "disabled")},
    }


def request(row):
    if not isinstance(row, dict) or not isinstance(row.get("id"), int) or isinstance(row["id"], bool):
        return None
    at = epoch_ms(row.get("ts"))
    status = row.get("status")
    if at is None or not isinstance(status, int) or isinstance(status, bool) or not 0 <= status < 1000:
        return None
    completeness = row.get("usage_completeness")
    tokens = [count(row.get(key)) for key in ("input_tokens", "output_tokens", "cache_tokens")]
    if completeness not in ("complete", "partial", "missing"):
        completeness = "partial" if any(tokens) else "missing"
    ttft = row.get("ttft_ms")
    return {
        "id": count(row["id"]), "at": at, "status": status,
        "client": clean(row.get("client"), 32) or "", "clientApp": clean(row.get("client_app"), 48),
        "provider": clean(row.get("provider"), 64) or "", "model": clean(row.get("model"), 160) or "",
        "account": clean(row.get("account"), 200) or "", "accountId": clean(row.get("account_id"), 512) or "",
        "latency": count(row.get("latency_ms")), "ttft": count(ttft) if ttft is not None else None,
        "input": tokens[0], "output": tokens[1], "cached": tokens[2], "usage": completeness,
        "stream": row.get("stream") is True, "error": clean(row.get("error"), 200),
        "transport": row.get("transport") if row.get("transport") in ("http", "ws", "images", "video") else "http",
        "attempts": max(1, min(count(row.get("attempts")), 99)),
    }


def recent(payload, limit=40):
    """The newest finished requests, newest first, as Fusebox lists them."""
    rows = payload if isinstance(payload, list) else []
    return [entry for entry in map(request, rows[:limit * 2]) if entry][:limit]


def load(payload):
    """Requests in flight and sessions per account. Sessions are the ones still going
    on (seen in the last half hour); releases without that count report only those
    seen in the last five minutes, which drops a session waiting on its user."""
    out = {}
    if isinstance(payload, dict):
        for identity, value in list(payload.items())[:4096]:
            if isinstance(identity, str) and 0 < len(identity) <= 512 and isinstance(value, dict):
                ongoing = value.get("ongoing_sessions", value.get("sessions"))
                out[identity] = {"inFlight": count(value.get("in_flight")), "sessions": count(ongoing)}
    return out


def activity(payload):
    rows = payload.get("sessions") if isinstance(payload, dict) else None
    sessions = []
    for row in (rows or [])[:50] if isinstance(rows, list) else []:
        if isinstance(row, dict):
            sessions.append({"lastSeen": epoch_ms(row.get("last_seen")), "since": epoch_ms(row.get("since")),
                             "active": row.get("active") is True, "client": clean(row.get("client_app"), 48)
                             or clean(row.get("client"), 32), "model": clean(row.get("model"), 160),
                             "requests": count(row.get("requests"))})
    # The account's own minutes of the last hour, for its load chart.
    buckets = payload.get("series") if isinstance(payload, dict) else None
    series = [{"minute": b["minute"], "requests": count(b.get("requests")), "failed": count(b.get("failed"))}
              for b in (buckets or [])[-120:] if isinstance(buckets, list)
              if isinstance(b, dict) and isinstance(b.get("minute"), int) and not isinstance(b["minute"], bool)]
    return {"sessions": sessions, "series": series}


# ---------------------------------------------------------------- live stream


class Output:
    def __init__(self, stream=None, clock=time.monotonic):
        self.stream = stream or sys.stdout
        self.clock = clock
        self.last = -math.inf

    def emit(self, kind: str, **fields):
        self.stream.write(json.dumps({"type": kind, **fields}, separators=(",", ":"), allow_nan=False) + "\n")
        self.stream.flush()
        self.last = self.clock()

    def heartbeat(self):
        if self.clock() - self.last >= HEARTBEAT:
            self.emit("heartbeat")


def snapshot(client: Client, out: Output, now_ms: int):
    """Everything a fresh view needs. Returns the accounts, and the faults derived
    from them when the server has no /api/faults (None when it has)."""
    try:
        summary = overview(client.request("overview"))
    except Failure as failure:
        if failure.status in (404, 405):
            raise Failure("offline", "No Fusebox management API answers at this URL.", failure.status) from None
        raise
    out.emit("overview", data=summary)
    entries = accounts(client.request("accounts"))
    out.emit("accounts", data=entries)
    # The server keeps its latest few hundred requests; the dashboard opens on them too.
    out.emit("requests", data=recent(client.request("requests")))
    try:
        out.emit("faults", data=faults(client.request("faults")), source="server")
        return entries, None
    except Failure as failure:
        # The key was just accepted for /api/accounts. Releases without /api/faults
        # pass unknown /api paths to client-key authentication, which answers 401.
        if failure.status not in (401, 403, 404, 405):
            raise
    derived = derived_faults(entries, now_ms)
    out.emit("faults", data=derived, source="accounts")
    return entries, derived


def socket_failure(error) -> Failure:
    response = getattr(error, "response", None)
    status = getattr(response, "status_code", None)
    if isinstance(status, int):
        return http_failure(status)
    if isinstance(error, (TimeoutError, OSError)):
        return Failure("offline", "Can't reach Fusebox. Check the URL, the network and its TLS certificate.")
    return Failure("offline", "The live connection to Fusebox closed. Reconnecting…")


def stream(base: str, out: Output, connect, clock=time.monotonic, wall=time.time):
    """One connection, until it fails: always raises the reason."""
    client = Client(base, read_key())
    out.emit("state", state="connecting")
    try:
        # The key travels only in the upgrade request's header, never the URL.
        connection = connect(websocket_url(base), additional_headers={"Authorization": "Bearer " + client.key},
                             open_timeout=8, close_timeout=1, max_size=MAX_FRAME, max_queue=64,
                             ping_interval=None, proxy=None)
    except Exception as error:  # websockets raises several types; never echo their text.
        raise socket_failure(error) from None
    with connection as socket:
        entries, derived = snapshot(client, out, int(wall() * 1000))
        server_faults = derived is None
        out.emit("state", state="live")
        heard = fetched = derived_at = clock()
        refetch_at = None
        while True:
            now = clock()
            if now - heard > STALE:
                raise Failure("offline", "Fusebox stopped sending updates. Reconnecting…")
            if (refetch_at is not None and now >= refetch_at) or now - fetched >= IDLE_REFRESH:
                entries = accounts(client.request("accounts"))
                out.emit("accounts", data=entries)
                fetched, refetch_at, derived_at = clock(), None, -math.inf
            if not server_faults and now - derived_at >= DERIVE_EVERY:
                current = derived_faults(entries, int(wall() * 1000))
                if current != derived:
                    out.emit("faults", data=current, source="accounts")
                    derived = current
                derived_at = now
            out.heartbeat()
            try:
                raw = socket.recv(timeout=1)
            except TimeoutError:
                continue
            except Exception as error:
                raise socket_failure(error) from None
            if not isinstance(raw, str) or len(raw) > MAX_FRAME:
                raise Failure("offline", "Fusebox sent a live update the widget can't read.")
            try:
                message = json.loads(raw)
            except (ValueError, RecursionError):
                raise Failure("offline", "Fusebox sent a live update the widget can't read.") from None
            if not isinstance(message, dict):
                continue
            heard = clock()
            kind, data = message.get("type"), message.get("data")
            if kind == "load":
                out.emit("load", data=load(data))
            elif kind == "faults" and server_faults:
                out.emit("faults", data=faults(data), source="server")
            elif kind == "request":
                entry = request(data)
                if entry:
                    out.emit("request", data=entry)
            elif kind == "tick" and isinstance(data, dict):
                out.emit("tick", active=count(data.get("active")), totals=totals(data.get("totals")))
            elif kind == "accounts" and refetch_at is None:
                refetch_at = max(heard, fetched + COALESCE)


def live(address: str, out: Output, connect, clock=time.monotonic, sleep=time.sleep):
    try:
        base = normalize_url(address)
    except Failure as failure:
        out.emit("state", state=failure.state, message=failure.message)
        return 2
    if connect is None:
        out.emit("state", state="unsupported", message="Install python3-websockets for live Fusebox updates.")
        return 3
    delay = 2
    while True:
        started = clock()
        try:
            stream(base, out, connect, clock=clock)
        except Failure as failure:
            out.emit("state", state=failure.state, message=failure.message)
            if failure.state == "setup":
                pause = SETUP_RECHECK
            elif failure.state == "auth":
                pause = 60
            else:
                if clock() - started >= 30:
                    delay = 2
                pause = delay
                delay = min(60, delay * 2)
        deadline = clock() + pause
        while clock() < deadline:
            out.heartbeat()
            sleep(min(1, max(0, deadline - clock())))


# ---------------------------------------------------------------- one-shot


ACTIONS = {"toggle": "toggle", "refresh": "refresh", "reset": "reset", "quota": "quota/refresh"}


def account_path(identity: str) -> str:
    if not isinstance(identity, str) or not 0 < len(identity) <= 512 or CONTROL.search(identity):
        raise Failure("invalid", "Unknown account.")
    return "accounts/" + urllib.parse.quote(identity, safe="")


def run_action(address: str, name: str, identity: str, disabled: bool | None = None):
    client = Client(normalize_url(address), read_key())
    payload = {"disabled": bool(disabled)} if name == "toggle" else None
    # Refreshing a sign-in also polls the provider's quota, which can take a while.
    client.request(account_path(identity) + "/" + ACTIONS[name], method="POST", payload=payload, timeout=45)
    return {"ok": True}


def run_activity(address: str, identity: str):
    client = Client(normalize_url(address), read_key())
    return activity(client.request(account_path(identity) + "/activity"))


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest="command", required=True)
    live_parser = commands.add_parser("live")
    live_parser.add_argument("--url", required=True)
    action_parser = commands.add_parser("action")
    action_parser.add_argument("--url", required=True)
    action_parser.add_argument("name", choices=sorted(ACTIONS))
    action_parser.add_argument("account")
    action_parser.add_argument("--disabled", choices=("true", "false"))
    activity_parser = commands.add_parser("activity")
    activity_parser.add_argument("--url", required=True)
    activity_parser.add_argument("account")
    commands.add_parser("store-key", help="read the key from stdin")
    commands.add_parser("forget-key")
    commands.add_parser("key-status")
    args = parser.parse_args(argv)

    def reply(value) -> None:
        print(json.dumps(value, separators=(",", ":")), flush=True)

    try:
        if args.command == "live":
            try:
                from websockets.sync.client import connect
            except ImportError:
                connect = None
            return live(args.url, Output(), connect)
        try:
            if args.command == "action":
                if args.name == "toggle" and args.disabled is None:
                    parser.error("toggle needs --disabled")
                reply(run_action(args.url, args.name, args.account, args.disabled == "true"))
            elif args.command == "activity":
                reply(run_activity(args.url, args.account))
            elif args.command == "store-key":
                store_key(sys.stdin.readline(MAX_KEY + 2))
                reply({"saved": True})
            elif args.command == "forget-key":
                forget_key()
                reply({"saved": False})
            else:
                try:
                    read_key()
                    reply({"saved": True})
                except Failure as failure:
                    reply({"saved": False, "error": failure.message} if os.path.lexists(key_path())
                          else {"saved": False})
            return 0
        except Failure as failure:
            reply({"ok": False, "state": failure.state, "error": failure.message})
        except BrokenPipeError:
            raise
        except OSError:
            reply({"ok": False, "state": "setup", "error": "The Fusebox key file couldn't be saved."})
        return 1
    except (BrokenPipeError, KeyboardInterrupt):
        # The shell went away; nothing is left to tell.
        return 0


if __name__ == "__main__":
    sys.exit(main())
