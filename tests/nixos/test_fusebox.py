#!/usr/bin/env python3
"""Fusebox widget transport: key custody, allowlisting, fault rules and the live stream."""
import gzip
import http.server
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "desktop/quickshell/scripts/fusebox.py"
KEY = "fbx-management-secret"

spec = importlib.util.spec_from_file_location("fusebox", SCRIPT)
fusebox = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fusebox)

try:
    from websockets.sync.client import connect as ws_connect
    from websockets.sync.server import serve as ws_serve
except ImportError:  # pragma: no cover - the Nix test environment supplies websockets
    ws_connect = ws_serve = None


def account(identity="file:claude-a.json", provider="claude", **extra):
    row = {"id": identity, "provider": provider, "label": "person@example.com", "email": "person@example.com",
           "kind": "oauth", "group": None, "file": identity[5:], "disabled": False, "cooldowns": {},
           "cooldown_kinds": {}, "last_error": None, "last_used": "2026-10-09T10:00:00.123456789+00:00",
           "expires_at": "2026-10-10T10:00:00Z", "counters": {"requests": 7, "failures": 1, "cancelled": 0},
           "quota": {"windows": [{"name": "5h", "used": 12.5, "resets_at": "2026-10-09T15:00:00Z"},
                                 {"name": "week", "used": 40, "resets_at": None}],
                     "updated_at": "2026-10-09T10:00:00Z", "plan": "max"},
           "banked_resets": {"inventory": {"available": 2}}, "models": ["a", "b"]}
    row.update(extra)
    return row


OVERVIEW = {"version": "0.3.2", "started_at": "2026-10-09T08:00:00Z", "uptime_secs": 7200,
            "base_url": "http://127.0.0.1:8317", "client_keys": ["fbx_client_secret"], "routing": "round-robin",
            "banked_resets": True, "session_affinity": True, "request_retry": 2, "management_key": True,
            "totals": {"requests": 10, "ok": 9, "failed": 1}, "active": 1,
            "series": [{"minute": 29_833_000, "requests": 3, "failed": 1, "tokens": 9}],
            "accounts": {"total": 1, "active": 1, "cooling": 0, "disabled": 0, "providers": {"claude": 1}},
            "models": 14, "config_path": "/etc/fusebox/config.yaml", "auth_dir": "/var/lib/fusebox/auth"}

QUOTE = "6f1c2d3e-4b5a-4c6d-8e7f-90a1b2c3d4e5"
GRANT = "grant_01HX9Z"
BANKED_VIEW = {"checked_at": "2026-10-09T10:00:00.123456789Z", "error": None, "quote": QUOTE, "retryable": False,
               "operation": None,
               "inventory": {"available": 2, "applicable": 1, "eligible": True, "reason": None, "selected_grant": GRANT,
                             "grants": [{"id": GRANT, "label": "Weekly reset", "remaining": 2,
                                         "expires_at": "2026-10-20T00:00:00Z", "starts_at": None,
                                         "clears": ["5-hour", "weekly"], "usable": True, "reason": None},
                                        {"id": "bad id!", "label": "x"}, "junk"]}}

CLIENTS_USAGE = {
    "clients": {"laptop": {"tokens_today": 1200, "usd_month": 3.456}}, "estimates": True,
    "last_used": {"laptop": "2026-10-09T09:59:00Z"}, "shared_last_used": [None],
    "addresses": {"laptop": [{"ip": "10.0.0.2", "via": "direct", "first": "2026-10-01T00:00:00Z"}]},
    "connected": [
        {"key": "laptop", "ip": "10.0.0.2", "via": "direct", "in_flight": 1, "sockets": 0,
         "last": "2026-10-09T10:00:00Z", "label": "Laptop"},
        {"key": "fbx_shared_secret_value", "ip": "10.0.0.7", "via": "proxy_protocol", "in_flight": 0, "sockets": 1,
         "last": "2026-10-09T09:58:00Z", "label": "Shared key 73d4…"},
        {"key": "app:Codex", "ip": "100.64.0.9", "via": "forwarded", "login": "me@github", "in_flight": 0,
         "sockets": 0, "last": "2026-10-09T09:57:00Z", "label": "Codex"},
        {"key": "laptop", "ip": "not-an-address", "via": "direct", "label": "Laptop"}]}

SETTINGS = {"revision": "r1", "path": "/etc/fusebox/config.yaml", "values": {
    "management-key": "mgmt-secret", "claude-api-key": [{"api-key": "sk-ant-provider"}],
    "named-clients": [
        {"id": "laptop", "label": "Laptop", "key": "fbx_laptop_key", "models": ["claude-*"],
         "addresses": ["10.0.0.0/24"], "requests-per-minute": 60, "tokens-per-day": 5000000,
         "usd-per-month": 100, "expires": "2026-12-31"},
        {"id": "ci", "label": "", "key": "fbx_ci_key", "usd-per-month": -5, "tokens-per-day": True,
         "expires": "soon"}, "junk"]}}

FAULT = {"key": "quota:file:claude-a.json", "kind": "quota", "level": "warn", "provider": "claude",
         "provider_name": "Claude", "account_id": "file:claude-a.json", "label": "person@example.com",
         "title": "Weekly limit used up", "detail": None, "until": "2026-10-12T09:00:00+00:00",
         "path": "#/accounts/file%3Aclaude-a.json"}


class FakeFusebox:
    """Fusebox's management API on one port and its live socket on another."""

    def __init__(self, faults=True, redirect=False):
        self.faults = faults
        self.redirect = redirect
        self.calls = []
        self.accounts = [account()]
        self.frames = []
        self.hold = 0.0
        self.spend = "applied"   # applied | conflict | hang | crash | garbage
        self.spends = []
        self.gzip = False
        self.locked = 0          # answer 429 with this Retry-After
        self.clients = CLIENTS_USAGE   # None: a release without /api/clients/usage
        self.encodings = []
        fake = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def reply(self, status, body, headers=()):
                data = json.dumps(body).encode()
                encoded = fake.gzip and "gzip" in (self.headers.get("Accept-Encoding") or "")
                if encoded:
                    data = gzip.compress(data)
                fake.encodings.append("gzip" if encoded else None)
                self.send_response(status)
                for name, value in headers:
                    self.send_header(name, value)
                if encoded:
                    self.send_header("Content-Encoding", "gzip")
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                try:
                    self.wfile.write(data)
                except (BrokenPipeError, ConnectionResetError):
                    pass  # The client gave up first, as the timeout tests intend.

            def handle_any(self, method):
                length = int(self.headers.get("Content-Length") or 0)
                body = json.loads(self.rfile.read(length)) if length else None
                fake.calls.append((method, self.path, self.headers.get("Authorization"), body))
                route, _, query = self.path.partition("?")
                if fake.redirect:
                    return self.reply(302, {}, [("Location", "http://127.0.0.1:9/steal")])
                if fake.locked:
                    return self.reply(429, {"error": f"too many wrong keys; try again in {fake.locked}s"},
                                      [("Retry-After", str(fake.locked))])
                if self.headers.get("Authorization") != "Bearer " + KEY:
                    return self.reply(401, {"error": "unauthorized"})
                if method == "GET" and route == "/api/overview":
                    return self.reply(200, OVERVIEW)
                if method == "GET" and route == "/api/accounts":
                    return self.reply(200, fake.accounts)
                if method == "GET" and route == "/api/requests":
                    limit = int(query.partition("limit=")[2] or 300)
                    return self.reply(200, [{"id": n, "ts": "2026-10-09T10:00:00Z", "status": 200,
                                             "session_id": "private-session"} for n in range(90, 0, -1)][:limit])
                if method == "GET" and route == "/api/clients/usage":
                    # Older releases route unknown /api paths to client-key auth.
                    return self.reply(200, fake.clients) if fake.clients else self.reply(401, {"error": "invalid api key"})
                if method == "GET" and route == "/api/config/settings":
                    return self.reply(200, SETTINGS)
                if method == "GET" and self.path == "/api/faults":
                    # Older releases route unknown /api paths to client-key auth.
                    return self.reply(200, [FAULT]) if fake.faults else self.reply(401, {"error": "invalid api key"})
                if self.path == "/api/accounts/file%3Aclaude-a.json/banked-resets":
                    if method == "GET":
                        return self.reply(200, BANKED_VIEW)
                    fake.spends.append(body)
                    if fake.spend == "conflict":
                        return self.reply(409, {"error": "Reset inventory changed; refresh and confirm again"})
                    if fake.spend == "crash":
                        return self.reply(500, {"error": "Reset operation interrupted; refresh its status"})
                    if fake.spend == "hang":
                        time.sleep(1.5)
                        return self.reply(200, BANKED_VIEW)
                    if fake.spend == "garbage":
                        return self.reply(200, ["not", "a", "view"])
                    applied = {**BANKED_VIEW, "quote": None, "operation": {
                        "request_id": body["request_id"], "grant_id": body["grant_id"], "status": "applied",
                        "message": "One banked reset applied", "created_at": "2026-10-09T10:00:01Z",
                        "retry_until": "2026-10-09T10:10:01Z"}}
                    return self.reply(200, applied)
                if self.path == "/api/accounts/file%3Aclaude-a.json/quota/refresh":
                    return self.reply(200, BANKED_VIEW)
                if self.path.startswith("/api/accounts/file%3Aclaude-a.json/"):
                    if self.path.endswith("/activity"):
                        return self.reply(200, {"sessions": [{"session": "s1", "last_seen": "2026-10-09T10:00:00Z",
                                                              "active": True, "client_app": "Claude Code",
                                                              "model": "claude-x", "requests": 4,
                                                              "quota": {"week": 4.25, "5h": 0, "": 3},
                                                              "key_label": "Laptop",
                                                              "source": {"ip": "10.0.0.2", "via": "direct"}}],
                                                "series": [{"minute": 29833000, "requests": 3, "failed": 1,
                                                            "tokens": 99}, {"minute": True}, "junk"]})
                    return self.reply(200, {"ok": True})
                return self.reply(404, {"error": "unknown account"})

            def do_GET(self):
                self.handle_any("GET")

            def do_POST(self):
                self.handle_any("POST")

        self.http = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.base = "http://127.0.0.1:%d" % self.http.server_address[1]
        threading.Thread(target=self.http.serve_forever, daemon=True).start()
        self.socket_requests = []
        if ws_serve:
            self.ws = ws_serve(self.live, "127.0.0.1", 0)
            self.ws_port = self.ws.socket.getsockname()[1]
            threading.Thread(target=self.ws.serve_forever, daemon=True).start()

    def live(self, socket):
        self.socket_requests.append((socket.request.path, socket.request.headers.get("Authorization")))
        if socket.request.headers.get("Authorization") != "Bearer " + KEY:
            socket.close(4401)
            return
        for frame in self.frames:
            if isinstance(frame, (int, float)):
                time.sleep(frame)
            else:
                socket.send(frame if isinstance(frame, str) else json.dumps(frame))
        time.sleep(self.hold)

    def connect(self, url, **options):
        """The helper's connect, routed to this server's socket port."""
        self.connected_url = url
        self.connect_options = options
        return ws_connect(url.replace(self.base.replace("http", "ws"), "ws://127.0.0.1:%d" % self.ws_port),
                          **options)

    def close(self):
        self.http.shutdown()
        self.http.server_close()
        if ws_serve:
            self.ws.shutdown()


class Recorder(fusebox.Output):
    def __init__(self):
        super().__init__(io.StringIO())

    @property
    def lines(self):
        return [json.loads(line) for line in self.stream.getvalue().splitlines()]

    def of(self, kind):
        return [line for line in self.lines if line["type"] == kind]


class KeyCustody(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.path = Path(self.temporary.name) / "nerdos/fusebox/management.key"

    def test_store_is_private_atomic_and_replaces(self):
        fusebox.store_key("  first-key \n", self.path)
        self.assertEqual(stat.S_IMODE(self.path.parent.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(self.path.stat().st_mode), 0o600)
        self.assertEqual(fusebox.read_key(self.path), "first-key")
        fusebox.store_key("second-key", self.path)
        self.assertEqual(fusebox.read_key(self.path), "second-key")
        self.assertEqual(sorted(p.name for p in self.path.parent.iterdir()), ["management.key"],
                         "no temporary file is left behind")

    def test_rejects_unusable_keys_and_unsafe_files(self):
        for bad in ("", "has space", "line\nbreak", "é", "x" * 9000):
            with self.assertRaises(fusebox.Failure):
                fusebox.store_key(bad, self.path)
        self.assertFalse(self.path.exists())
        with self.assertRaises(fusebox.Failure) as missing:
            fusebox.read_key(self.path)
        self.assertEqual(missing.exception.state, "setup")
        fusebox.store_key("good", self.path)
        os.chmod(self.path, 0o640)
        with self.assertRaises(fusebox.Failure):
            fusebox.read_key(self.path)
        os.chmod(self.path, 0o600)
        link = self.path.with_name("link.key")
        link.symlink_to(self.path)
        with self.assertRaises(fusebox.Failure):
            fusebox.read_key(link)
        fusebox.forget_key(self.path)
        self.assertFalse(self.path.exists())
        fusebox.forget_key(self.path)

    def test_cli_never_echoes_the_key(self):
        environment = dict(os.environ, XDG_CONFIG_HOME=self.temporary.name)

        def run(*args, data=None):
            return subprocess.run([sys.executable, "-B", str(SCRIPT), *args], input=data,
                                  capture_output=True, text=True, env=environment, timeout=20)

        self.assertEqual(json.loads(run("key-status").stdout), {"saved": False})
        stored = run("store-key", data=KEY + "\n")
        self.assertEqual((stored.returncode, json.loads(stored.stdout)), (0, {"saved": True}))
        self.assertEqual(json.loads(run("key-status").stdout), {"saved": True})
        self.assertEqual(self.path.read_text().strip(), KEY)
        refused = run("store-key", data="two words\n")
        self.assertEqual(refused.returncode, 1)
        self.assertEqual(fusebox.read_key(self.path), KEY, "a refused key leaves the saved one alone")
        os.chmod(self.path, 0o644)
        unsafe = json.loads(run("key-status").stdout)
        self.assertFalse(unsafe["saved"])
        self.assertIn("private", unsafe["error"])
        self.assertEqual(json.loads(run("forget-key").stdout), {"saved": False})
        for result in (stored, refused):
            self.assertNotIn(KEY, result.stdout + result.stderr)


class Normalizing(unittest.TestCase):
    def test_urls(self):
        for given, expected in [("https://fuse.example.ts.net", "https://fuse.example.ts.net"),
                                ("https://fuse.example.ts.net/", "https://fuse.example.ts.net"),
                                ("https://fuse.example.ts.net/#/accounts", "https://fuse.example.ts.net"),
                                ("http://10.0.0.5:8317/api", "http://10.0.0.5:8317"),
                                (" https://example.com/fusebox/ ", "https://example.com/fusebox")]:
            self.assertEqual(fusebox.normalize_url(given), expected)
        for bad in ("", "ftp://example.com", "https://user:pw@example.com", "https://example.com/?key=1",
                    "https://example.com/../x", "https://exa mple.com\x00", "example.com"):
            with self.assertRaises(fusebox.Failure, msg=bad):
                fusebox.normalize_url(bad)
        self.assertEqual(fusebox.websocket_url("https://example.com/fusebox"), "wss://example.com/fusebox/api/live")
        self.assertEqual(fusebox.websocket_url("http://127.0.0.1:8317"), "ws://127.0.0.1:8317/api/live")

    def test_times_accept_fusebox_nanoseconds(self):
        self.assertEqual(fusebox.epoch_ms("2026-10-09T10:00:00Z"), 1791540000000)
        self.assertEqual(fusebox.epoch_ms("2026-10-09T10:00:00.123456789+00:00"), 1791540000123)
        self.assertEqual(fusebox.epoch_ms("2026-10-09T12:00:00+02:00"), 1791540000000)
        for bad in (None, 5, "yesterday", "2026-10-09T10:00:00", "x" * 100):
            self.assertIsNone(fusebox.epoch_ms(bad))

    def test_accounts_keep_only_what_the_widget_shows(self):
        rows = fusebox.accounts([account(), {"id": "bad"}, account(), "junk",
                                 account("k1", "codex", kind="api-key", label=None,
                                         cooldowns={"*": "2026-10-09T11:00:00Z", "gpt": "garbage"},
                                         cooldown_kinds={"*": "Quota!"},
                                         quota={"windows": [{"name": "5h", "used": 150}, {"name": "BAD", "used": 1},
                                                            {"name": "week", "used": float("nan")}]})])
        self.assertEqual([r["id"] for r in rows], ["file:claude-a.json", "k1"], "duplicates and invalid rows drop")
        first, key = rows
        self.assertEqual(first["lastUsed"], 1791540000123)
        self.assertEqual((first["plan"], first["banked"], first["models"]), ("max", 2, 2))
        self.assertEqual(first["windows"][0], {"name": "5h", "used": 12.5, "resetsAt": 1791558000000, "model": None})
        self.assertNotIn("file", first)
        self.assertEqual(key["label"], "k1", "a missing label falls back to the id")
        self.assertEqual(key["cooldowns"], [{"model": "*", "until": 1791543600000, "kind": "rate_limit"}])
        self.assertEqual(key["windows"], [{"name": "5h", "used": 100.0, "resetsAt": None, "model": None}])
        with self.assertRaises(fusebox.Failure):
            fusebox.accounts({"not": "a list"})

    def test_accounts_carry_plans_priority_reset_plans_and_attribution(self):
        row = account("file:codex.json", "codex", priority=10,
                      quota={"windows": [], "plan": "pro", "subscription_plan": "chatgptpromax"},
                      banked_reset_plan={"expires_at": "2026-10-12T00:00:00Z",
                                         "expiry_redeem_at": "2026-10-11T23:00:00Z", "prioritized": True,
                                         "auto_redeem": True, "due": "yes", "message": "server copy"},
                      quota_attribution={"basis": "estimate", "previous": [{"name": "week", "used": 80}], "current": [
                          {"key": "week", "name": "week", "model": None, "resets_at": "2026-10-12T00:00:00Z",
                           "used": 62.5, "before": 1, "outside": 4, "by_tokens": float("inf"), "sessions": 3,
                           "attributed": 57, "clients": [{"id": "laptop", "label": "Laptop", "points": 30.25},
                                                         {"id": "app:Codex", "label": "Codex", "points": 0},
                                                         {"id": "x", "label": "X", "points": "lots"}, "junk"],
                           "models": [{"id": "gpt", "points": 9}]},
                          {"key": "bad", "name": "Not A Window", "used": 1}]})
        entry = fusebox.account(row)
        self.assertEqual((entry["plan"], entry["subscriptionPlan"], entry["priority"]), ("pro", "chatgptpromax", 10))
        self.assertEqual(entry["bankedPlan"], {"expiresAt": 1791763200000, "redeemAt": 1791759600000,
                                               "prioritized": True, "auto": True, "due": False})
        self.assertEqual(entry["attribution"], {"current": [{
            "key": "week", "name": "week", "model": None, "resetsAt": 1791763200000, "used": 62.5, "before": 1.0,
            "outside": 4.0, "byTokens": 0.0, "clients": [{"id": "laptop", "label": "Laptop", "points": 30.25}]}]})
        odd = fusebox.account(account(priority=10 ** 6, banked_reset_plan={"expires_at": None},
                                      quota_attribution="junk"))
        self.assertEqual((odd["priority"], odd["bankedPlan"], odd["attribution"]), (0, None, None))

    def test_overview_drops_keys_and_paths(self):
        summary = fusebox.overview(OVERVIEW)
        text = json.dumps(summary)
        for secret in ("fbx_client_secret", "/etc/fusebox", "/var/lib", "127.0.0.1:8317"):
            self.assertNotIn(secret, text)
        self.assertEqual(summary["version"], "0.3.2")
        self.assertEqual(summary["totals"]["failed"], 1)
        self.assertEqual(summary["series"], [{"minute": 29_833_000, "requests": 3, "failed": 1, "cancelled": 0,
                                              "input_tokens": 0, "output_tokens": 0, "cache_tokens": 0}])

    def test_faults_from_the_server(self):
        rows = fusebox.faults([FAULT, {**FAULT, "key": "error:x", "kind": "error", "level": "err",
                                       "path": "javascript:alert(1)"},
                               {**FAULT, "kind": "unknown"}, {**FAULT, "level": "info"}, None])
        self.assertEqual([r["key"] for r in rows], ["error:x", "quota:file:claude-a.json"], "errors come first")
        self.assertEqual(rows[0]["path"], "", "only dashboard hash routes are kept")
        self.assertEqual(rows[1]["until"], 1791795600000)
        self.assertEqual(rows[1]["providerName"], "Claude")
        self.assertTrue(rows[1]["badge"])

    def test_pace_and_storage_faults_are_kept_and_pace_stays_off_the_badge(self):
        pace = {**FAULT, "key": "pace:file:claude-a.json:week", "kind": "pace", "badge": False,
                "title": "Weekly limit runs out early at this pace", "detail": "Laptop used 48% of it."}
        storage = {"key": "storage:usage", "kind": "storage", "level": "err", "provider": "", "provider_name": "Usage",
                   "title": "Disk almost full", "detail": "80 MB left", "until": None, "path": "#/usage"}
        rows = fusebox.faults([pace, storage, {**pace, "key": "pace:x", "badge": True}])
        self.assertEqual([(r["kind"], r["badge"]) for r in rows], [("storage", True), ("pace", False), ("pace", False)])
        self.assertEqual(rows[0]["path"], "#/usage")

    def test_derived_faults_follow_the_server_rules(self):
        now = fusebox.epoch_ms("2026-10-09T10:00:00Z")
        later = "2026-10-09T13:00:00Z"
        spent = account(cooldowns={"*": later}, cooldown_kinds={"*": "quota"},
                        quota={"windows": [{"name": "5h", "used": 100, "resets_at": "2026-10-09T12:00:00Z"},
                                           {"name": "week", "used": 30}]})
        limited = account("file:b.json", cooldowns={"claude-opus": "2026-10-09T10:05:00Z"},
                          cooldown_kinds={"claude-opus": "rate_limit"}, last_error="429 slow down")
        signin = account("file:c.json", last_error="token refresh failed: invalid_grant")
        key = account("key", kind="api-key", last_error="401 Unauthorized")
        checking = account("file:d.json", cooldowns={"*": later}, cooldown_kinds={"*": "checking"},
                           last_error="boom")
        off = account("file:e.json", disabled=True, last_error="invalid_grant")
        expired = account("file:f.json", cooldowns={"*": "2026-10-09T09:00:00Z"}, cooldown_kinds={"*": "quota"})
        rows = fusebox.derived_faults(fusebox.accounts([spent, limited, signin, key, checking, off, expired]), now)
        self.assertEqual([r["key"] for r in rows],
                         ["signin:file:c.json", "error:key", "quota:file:claude-a.json", "rate:file:b.json"])
        by_kind = {r["kind"]: r for r in rows}
        self.assertEqual(by_kind["quota"]["title"], "5-hour limit used up")
        self.assertEqual(by_kind["quota"]["until"], fusebox.epoch_ms("2026-10-09T12:00:00Z"),
                         "back when the spent window resets")
        self.assertEqual(by_kind["rate_limit"]["detail"], "claude-opus is paused.")
        self.assertEqual(by_kind["error"]["title"], "Account error", "an API key's 401 is not a sign-in")
        self.assertEqual(by_kind["signin"]["path"], "#/accounts/file%3Ac.json")

    def test_requests_and_load(self):
        row = fusebox.request({"id": 4, "ts": "2026-10-09T10:00:00Z", "status": 200, "client": "messages",
                               "client_app": "Claude Code", "provider": "claude", "model": "claude-x",
                               "account": "person@example.com", "account_id": "file:a.json", "latency_ms": 900,
                               "ttft_ms": 300, "input_tokens": 10, "output_tokens": 5, "cache_tokens": 2,
                               "session_id": "secret-session", "routing_attempts": [{"x": 1}]})
        self.assertEqual((row["at"], row["ttft"], row["usage"]), (1791540000000, 300, "partial"))
        self.assertEqual((row["transport"], row["attempts"]), ("http", 1))
        tagged = fusebox.request({"id": 5, "ts": "2026-10-09T10:00:00Z", "status": 200, "transport": "ws", "attempts": 3})
        self.assertEqual((tagged["transport"], tagged["attempts"]), ("ws", 3))
        odd = fusebox.request({"id": 6, "ts": "2026-10-09T10:00:00Z", "status": 200, "transport": "carrier-pigeon",
                               "attempts": 10 ** 9})
        self.assertEqual((odd["transport"], odd["attempts"]), ("http", 99))
        self.assertNotIn("secret-session", json.dumps(row))
        self.assertEqual((row["keyLabel"], row["source"]), (None, None))
        sourced = fusebox.request({"id": 7, "ts": "2026-10-09T10:00:00Z", "status": 200, "key_label": "Laptop",
                                   "key": "fbx_raw", "source": {"ip": "100.64.0.3", "via": "forwarded",
                                                                "login": "me@github"}})
        self.assertEqual((sourced["keyLabel"], sourced["source"]),
                         ("Laptop", {"ip": "100.64.0.3", "via": "forwarded", "login": "me@github"}))
        self.assertNotIn("fbx_raw", json.dumps(sourced))
        for bad in ({"ip": "100.64.0.3", "via": "carrier"}, {"ip": "nope", "via": "direct"}, {"via": "direct"}, "x"):
            self.assertIsNone(fusebox.source(bad), bad)
        self.assertEqual(fusebox.source({"ip": "::ffff:10.0.0.1", "via": "direct"})["ip"], "::ffff:10.0.0.1")
        self.assertIsNone(fusebox.request({"id": 1, "ts": "bad", "status": 200}))
        self.assertIsNone(fusebox.request({"id": True, "ts": "2026-10-09T10:00:00Z", "status": 200}))
        self.assertEqual(fusebox.load({"a": {"in_flight": 2, "sessions": 3}, "b": {"in_flight": -1}, 5: {}}),
                         {"a": {"inFlight": 2, "sessions": 3}, "b": {"inFlight": 0, "sessions": 0}})
        # The five-minute count, as the dashboard shows: a session last seen 14 minutes
        # ago is still in the half-hour count but no longer reads as a session.
        self.assertEqual(fusebox.load({"a": {"in_flight": 0, "sessions": 1, "ongoing_sessions": 2},
                                       "b": {"in_flight": 0, "sessions": 0, "ongoing_sessions": 3}}),
                         {"a": {"inFlight": 0, "sessions": 1}, "b": {"inFlight": 0, "sessions": 0}})


class ClientsAndHttp(unittest.TestCase):
    def test_clients_keep_names_limits_and_use_but_no_keys(self):
        limits = fusebox.named_limits(SETTINGS)
        self.assertEqual(limits, {
            "laptop": {"label": "Laptop", "requestsPerMinute": 60, "tokensPerDay": 5000000, "usdPerMonth": 100.0,
                       "expires": "2026-12-31"},
            "ci": {"label": None, "requestsPerMinute": None, "tokensPerDay": None, "usdPerMonth": None,
                   "expires": None}})
        view = fusebox.clients_view(CLIENTS_USAGE, limits)
        self.assertEqual(view["named"][0], {"id": "laptop", "label": "Laptop", "tokensToday": 1200, "usdMonth": 3.46,
                                            "tokensPerDay": 5000000, "usdPerMonth": 100.0, "requestsPerMinute": 60,
                                            "expires": "2026-12-31", "lastUsed": 1791539940000})
        self.assertEqual(view["named"][1]["label"], "ci", "a client without a label goes by its id")
        self.assertEqual([(c["id"], c["label"], c["ip"], c["via"]) for c in view["connected"]], [
            ("laptop", "Laptop", "10.0.0.2", "direct"), ("", "Shared key 73d4…", "10.0.0.7", "proxy_protocol"),
            ("app:Codex", "Codex", "100.64.0.9", "forwarded")], "unreadable addresses drop; shared keys lose their id")
        text = json.dumps(view)
        for secret in ("fbx_laptop_key", "fbx_ci_key", "fbx_shared_secret_value", "mgmt-secret", "sk-ant-provider"):
            self.assertNotIn(secret, text)
        self.assertEqual(fusebox.clients_view({"clients": {"x": {}}}, None)["named"][0]["tokensPerDay"], None,
                         "use without the configuration still shows")

    def test_gzip_answers_are_read_and_bounded(self):
        fake = FakeFusebox()
        self.addCleanup(fake.close)
        fake.gzip = True
        self.assertEqual(fusebox.Client(fake.base, KEY).request("accounts")[0]["id"], "file:claude-a.json")
        self.assertEqual(fake.encodings, ["gzip"], "the helper asks for gzip")
        with self.assertRaises(fusebox.Failure) as refused:
            fusebox.Client(fake.base, KEY).request("accounts/file%3Amissing.json/refresh", method="POST")
        self.assertIsNotNone(refused.exception.message)
        with self.assertRaises(fusebox.Failure) as bomb:
            fusebox.decoded(gzip.compress(b"0" * (fusebox.MAX_RESPONSE + 10)), "gzip")
        self.assertIn("large", bomb.exception.message)
        with self.assertRaises(fusebox.Failure):
            fusebox.decoded(b"not gzip", "gzip")
        with self.assertRaises(fusebox.Failure):
            fusebox.decoded(b"{}", "br")
        self.assertEqual(fusebox.decoded(b"{}", None), b"{}")

    def test_a_lockout_reads_as_one_with_its_wait(self):
        failure = fusebox.http_failure(429, "too many wrong keys; try again in 240s", fusebox.retry_after("240"))
        self.assertEqual((failure.state, failure.retry), ("locked", 240))
        self.assertIn("about 4 minutes", failure.message)
        self.assertEqual(fusebox.http_failure(429).retry, 60, "no header: a minute")
        self.assertEqual([fusebox.retry_after(v) for v in ("30", " 9 ", "0", "-1", "soon", None, "999999")],
                         [30, 9, None, None, None, None, None])

        class Response:
            status_code = 429
            headers = {"Retry-After": "90"}

        class Refused(Exception):
            response = Response()

        self.assertEqual((fusebox.socket_failure(Refused()).state, fusebox.socket_failure(Refused()).retry),
                         ("locked", 90), "the WebSocket upgrade is locked out the same way")

        class Close:
            code = 1001

        class Closed(Exception):
            rcvd = Close()

        self.assertEqual(fusebox.socket_failure(Closed()).state, "restarting")

    def test_a_restart_reconnects_quickly_and_reads_as_a_restart(self):
        out, sleeps = Recorder(), []
        failures = iter([fusebox.Failure("restarting", "Fusebox is restarting. Reconnecting…"),
                         fusebox.Failure("offline", "Can't reach Fusebox."),
                         fusebox.Failure("offline", "Can't reach Fusebox.")])

        def stream(*args, **kwargs):
            raise next(failures)

        def sleep(seconds):
            sleeps.append(seconds)

        with patch.object(fusebox, "stream", stream), self.assertRaises(StopIteration):
            fusebox.live("https://fusebox.example", out, object(), sleep=sleep, clock=lambda: sum(sleeps))
        self.assertEqual([s["state"] for s in out.of("state")], ["restarting", "restarting", "restarting"])
        # A second after the notice, then 2 and 4 seconds: one-second naps.
        self.assertEqual(sleeps, [1] * 7)


@unittest.skipIf(ws_serve is None, "python3-websockets is required")
class LiveStream(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.environment = patch.dict(os.environ, {"XDG_CONFIG_HOME": self.temporary.name})
        self.environment.start()
        self.addCleanup(self.environment.stop)
        fusebox.store_key(KEY)

    def server(self, **options):
        fake = FakeFusebox(**options)
        self.addCleanup(fake.close)
        return fake

    def run_stream(self, fake):
        out = Recorder()
        with self.assertRaises(fusebox.Failure) as ended:
            fusebox.stream(fake.base, out, fake.connect)
        return out, ended.exception

    def test_snapshot_then_live_events_with_header_authentication(self):
        fake = self.server()
        fake.frames = [{"type": "load", "data": {"file:claude-a.json": {"in_flight": 1, "sessions": 2}}},
                       {"type": "faults", "data": []},
                       {"type": "request", "data": {"id": 1, "ts": "2026-10-09T10:00:00Z", "status": 503,
                                                    "error": "upstream overloaded"}},
                       {"type": "tick", "data": {"active": 0, "totals": {"requests": 11}}},
                       {"type": "login", "data": {}}, {"type": "future-event", "data": [1]}, "[1, 2]"]
        out, ended = self.run_stream(fake)
        self.assertEqual(ended.state, "offline", "a closed socket reconnects")
        kinds = [line["type"] for line in out.lines if line["type"] != "heartbeat"]
        self.assertEqual(kinds, ["state", "overview", "accounts", "requests", "faults", "state", "clients", "load",
                                 "faults", "request", "tick"])
        seeded = out.of("requests")[0]["data"]
        self.assertEqual((len(seeded), seeded[0]["id"], seeded[-1]["id"]), (40, 90, 51), "the newest 40, newest first")
        self.assertEqual(out.of("faults")[0], {"type": "faults", "data": fusebox.faults([FAULT]), "source": "server"})
        self.assertEqual(out.of("faults")[1]["data"], [])
        self.assertEqual(out.of("load")[0]["data"], {"file:claude-a.json": {"inFlight": 1, "sessions": 2}})
        self.assertEqual(out.of("tick")[0]["totals"]["requests"], 11)
        self.assertEqual(fake.connected_url, fake.base.replace("http", "ws") + "/api/live")
        self.assertEqual(fake.socket_requests, [("/api/live", "Bearer " + KEY)], "the key is a header, not the URL")
        self.assertEqual([call[1] for call in fake.calls],
                         ["/api/overview", "/api/accounts", "/api/requests?limit=40", "/api/faults",
                          "/api/clients/usage", "/api/config/settings"])
        everything = out.stream.getvalue()
        for secret in (KEY, "fbx_client_secret", "/etc/fusebox", "private-session", "mgmt-secret", "sk-ant-provider",
                       "fbx_laptop_key", "fbx_shared_secret_value", "10.0.0.0/24", "claude-*"):
            self.assertNotIn(secret, everything)

    def test_account_events_coalesce_into_one_refetch(self):
        fake = self.server()
        fake.frames = [{"type": "accounts", "data": None}, {"type": "accounts", "data": None},
                       {"type": "accounts", "data": None}, {"type": "tick", "data": {}}]
        fake.hold = 1.5
        with patch.object(fusebox, "COALESCE", 0.3):
            out, _ = self.run_stream(fake)
        self.assertEqual([call[1] for call in fake.calls].count("/api/accounts"), 2, "snapshot plus one refetch")
        self.assertEqual(len(out.of("accounts")), 2)

    def test_older_servers_get_faults_from_account_state(self):
        fake = self.server(faults=False)
        fake.accounts = [account(last_error="token refresh failed: invalid_grant")]
        fake.frames = [{"type": "faults", "data": [FAULT]}]
        out, _ = self.run_stream(fake)
        faults = out.of("faults")
        self.assertEqual(len(faults), 1, "server fault events are ignored once derived")
        self.assertEqual(faults[0]["source"], "accounts")
        self.assertEqual(faults[0]["data"][0]["kind"], "signin")

    def test_a_rejected_key_is_reported_without_retrying_fast(self):
        fake = self.server()
        fusebox.store_key("wrong-key")
        out = Recorder()
        with self.assertRaises(fusebox.Failure) as ended:
            fusebox.stream(fake.base, out, fake.connect)
        self.assertEqual(ended.exception.state, "auth")
        sleeps = []

        def sleep(seconds):
            sleeps.append(seconds)
            if sum(sleeps) > 5:
                raise KeyboardInterrupt

        with self.assertRaises(KeyboardInterrupt):
            fusebox.live(fake.base, out, fake.connect, sleep=sleep, clock=lambda: sum(sleeps))
        self.assertEqual(out.of("state")[-1], {"type": "state", "state": "auth",
                                               "message": "Fusebox rejected the management key."})

    def test_a_rejected_key_is_not_tried_again_until_it_changes(self):
        fake = self.server()
        fusebox.store_key("wrong-key")
        out, sleeps = Recorder(), []

        def sleep(seconds):
            sleeps.append(seconds)
            if len(sleeps) == 600:
                fusebox.store_key(KEY)
            if len(sleeps) > 610:
                raise KeyboardInterrupt

        with self.assertRaises(KeyboardInterrupt):
            fusebox.live(fake.base, out, fake.connect, sleep=sleep, clock=lambda: sum(sleeps))
        overviews = [call[2] for call in fake.calls if call[1] == "/api/overview"]
        self.assertEqual(overviews[:2], ["Bearer wrong-key", "Bearer " + KEY],
                         "ten minutes without a retry, then the new key at once")
        self.assertEqual(overviews.count("Bearer wrong-key"), 1)
        self.assertIn("live", [line["state"] for line in out.of("state")])

    def test_a_lockout_waits_as_long_as_fusebox_asks(self):
        fake = self.server()
        fake.locked = 240
        out, sleeps = Recorder(), []

        def sleep(seconds):
            sleeps.append(seconds)
            if sum(sleeps) > 300:
                raise KeyboardInterrupt

        with self.assertRaises(KeyboardInterrupt):
            fusebox.live(fake.base, out, fake.connect, sleep=sleep, clock=lambda: sum(sleeps),
                         wall=lambda: 1000.0 + sum(sleeps))
        locked = out.of("state")[1]
        self.assertEqual((locked["state"], locked["until"]), ("locked", 1_241_000))
        self.assertIn("about 4 minutes", locked["message"])
        self.assertEqual([call[1] for call in fake.calls].count("/api/overview"), 2, "one try per lockout")

    def test_a_quiet_server_is_pinged_rather_than_dropped(self):
        # Fusebox 0.7 ticks only when something changed: silence alone is not a dead socket.
        fake = self.server()
        fake.hold = 4.5
        started = time.monotonic()
        # The loop waits up to a second for a frame, so allow two for the pong.
        with patch.object(fusebox, "PING_AFTER", 0.3), patch.object(fusebox, "STALE", 2.0):
            out, ended = self.run_stream(fake)
        self.assertGreaterEqual(time.monotonic() - started, 4.4, "it stayed until the server closed it")
        self.assertEqual(ended.message, "The live connection to Fusebox closed. Reconnecting…")

    def test_a_socket_that_stops_answering_pings_is_dropped(self):
        fake = self.server()

        class Silent:
            def __enter__(self):
                return self

            def __exit__(self, *exc):
                return False

            def recv(self, timeout=None):
                time.sleep(0.05)
                raise TimeoutError

            def ping(self):
                self.pinged = True
                return threading.Event()   # never answered

        silent = Silent()
        with patch.object(fusebox, "PING_AFTER", 0.2), patch.object(fusebox, "STALE", 0.6), \
                patch.object(fusebox, "CLIENTS_EVERY", 60):
            with self.assertRaises(fusebox.Failure) as ended:
                fusebox.stream(fake.base, Recorder(), lambda *a, **k: silent)
        self.assertEqual(ended.exception.message, "Fusebox stopped answering. Reconnecting…")
        self.assertTrue(silent.pinged)

    def test_releases_without_clients_leave_them_out_after_one_try(self):
        fake = self.server()
        fake.clients = None
        fake.hold = 1.2
        with patch.object(fusebox, "CLIENTS_EVERY", 0.2):
            out, _ = self.run_stream(fake)
        self.assertEqual(out.of("clients"), [{"type": "clients", "data": None}])
        self.assertEqual([call[1] for call in fake.calls].count("/api/clients/usage"), 1)
        self.assertNotIn("/api/config/settings", [call[1] for call in fake.calls])

    def test_a_url_without_fusebox_says_so(self):
        fake = self.server()
        with self.assertRaises(fusebox.Failure) as wrong:
            fusebox.stream(fake.base + "/elsewhere", Recorder(), fake.connect)
        self.assertEqual(wrong.exception.message, "No Fusebox management API answers at this URL.")

    def test_redirects_are_refused_so_the_key_never_follows(self):
        fake = self.server(redirect=True)
        with self.assertRaises(fusebox.Failure) as refused:
            fusebox.Client(fake.base, KEY).request("accounts")
        self.assertIn("redirected", refused.exception.message)
        self.assertEqual(len(fake.calls), 1)

    def test_missing_key_waits_for_setup(self):
        fusebox.forget_key()
        out = Recorder()
        sleeps = []

        def sleep(seconds):
            sleeps.append(seconds)
            raise KeyboardInterrupt

        with self.assertRaises(KeyboardInterrupt):
            fusebox.live("https://fusebox.invalid", out, lambda *a, **k: None, sleep=sleep, clock=time.monotonic)
        self.assertEqual(out.of("state")[0]["state"], "setup")


class BankedResets(unittest.TestCase):
    """Spending can't be undone: every POST goes once, with the confirmed quote."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        environment = patch.dict(os.environ, {"XDG_CONFIG_HOME": self.temporary.name})
        environment.start()
        self.addCleanup(environment.stop)
        fusebox.store_key(KEY)
        self.fake = FakeFusebox()
        self.addCleanup(self.fake.close)

    def test_status_keeps_what_the_panel_shows_and_valid_tokens_only(self):
        for read in (fusebox.run_banked, fusebox.run_banked_refresh):
            view = read(self.fake.base, "file:claude-a.json")["view"]
            self.assertEqual((view["quote"], view["inventory"]["selectedGrant"], view["checkedAt"]),
                             (QUOTE, GRANT, 1791540000123))
            self.assertEqual(view["inventory"]["grants"], [{
                "id": GRANT, "label": "Weekly reset", "remaining": 2, "expiresAt": 1792454400000, "startsAt": None,
                "clears": ["5-hour", "weekly"], "usable": True, "reason": None}], "invalid grants are dropped")
        self.assertEqual(self.fake.spends, [], "reading status never spends")
        broken = fusebox.banked_view({**BANKED_VIEW, "quote": "x y", "operation": {"status": "exploded",
                                                                                "request_id": QUOTE}})
        self.assertIsNone(broken["quote"])
        self.assertEqual(broken["operation"]["status"], "unknown", "an unknown state fails closed, as needing review")
        with self.assertRaises(fusebox.Failure):
            fusebox.banked_view({"inventory": {}})

    def test_redeem_sends_the_confirmed_quote_and_grant_once(self):
        result = fusebox.run_banked_action(self.fake.base, "file:claude-a.json", "redeem", QUOTE, GRANT)
        self.assertEqual(self.fake.spends, [{"action": "redeem", "request_id": QUOTE, "grant_id": GRANT,
                                             "confirmed": True}])
        self.assertEqual(result["view"]["operation"]["status"], "applied")
        self.assertEqual(result["view"]["operation"]["message"], "One banked reset applied")
        self.assertIsNone(result["view"]["quote"], "a used confirmation is gone")

    def test_a_changed_inventory_is_refused_by_fusebox_and_reported(self):
        self.fake.spend = "conflict"
        with self.assertRaises(fusebox.Failure) as refused:
            fusebox.run_banked_action(self.fake.base, "file:claude-a.json", "redeem", QUOTE, "")
        self.assertEqual(refused.exception.message, "Reset inventory changed; refresh and confirm again")
        self.assertEqual(len(self.fake.spends), 1)

    def test_an_unanswered_spend_is_uncertain_and_never_resent(self):
        for mode in ("hang", "crash", "garbage"):
            self.fake.spends.clear()
            self.fake.spend = mode
            with patch.object(fusebox, "SPEND_TIMEOUT", 0.5), self.assertRaises(fusebox.Failure) as unclear:
                fusebox.run_banked_action(self.fake.base, "file:claude-a.json", "redeem", QUOTE, GRANT)
            self.assertEqual(unclear.exception.state, "uncertain", mode)
            self.assertIn("may have been used", unclear.exception.message)
            time.sleep(1.2 if mode == "hang" else 0)
            self.assertEqual(len(self.fake.spends), 1, f"{mode}: sent exactly once")

    def test_recovery_actions_and_invalid_requests(self):
        for action in ("retry", "resolve-used", "resolve-unused"):
            fusebox.run_banked_action(self.fake.base, "file:claude-a.json", action, QUOTE)
        self.assertEqual([(b["action"], b["grant_id"]) for b in self.fake.spends],
                         [("retry", ""), ("resolve-used", ""), ("resolve-unused", "")])
        for action, request, grant in (("spend-all", QUOTE, ""), ("redeem", "", ""), ("redeem", "a b", ""),
                                       ("redeem", QUOTE, "../x")):
            with self.assertRaises(fusebox.Failure):
                fusebox.run_banked_action(self.fake.base, "file:claude-a.json", action, request, grant)
        self.assertEqual(len(self.fake.spends), 3, "invalid requests never reach Fusebox")

    def test_cli_requires_an_explicit_action_and_request(self):
        environment = dict(os.environ, XDG_CONFIG_HOME=self.temporary.name)
        missing = subprocess.run([sys.executable, "-B", str(SCRIPT), "banked-action", "--url", self.fake.base,
                                  "file:claude-a.json"], capture_output=True, text=True, timeout=20, env=environment)
        self.assertEqual(missing.returncode, 2)
        self.assertEqual(self.fake.spends, [])
        read = subprocess.run([sys.executable, "-B", str(SCRIPT), "banked", "--url", self.fake.base,
                               "file:claude-a.json"], capture_output=True, text=True, timeout=20, env=environment)
        self.assertEqual(json.loads(read.stdout)["view"]["quote"], QUOTE)

    def test_live_accounts_flag_an_unresolved_spend(self):
        pending = {**account(), "banked_resets": {"operation": {"status": "pending"}, "inventory": {"available": 1}}}
        settled = {**account(), "banked_resets": {"operation": {"status": "applied"}}}
        odd = {**account(), "banked_resets": {"operation": {"status": "something-new"}}}
        flags = [fusebox.account(row)["bankedReview"] for row in (pending, settled, odd, account())]
        self.assertEqual(flags, [True, False, True, False])


class OneShot(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        environment = patch.dict(os.environ, {"XDG_CONFIG_HOME": self.temporary.name})
        environment.start()
        self.addCleanup(environment.stop)
        fusebox.store_key(KEY)
        self.fake = FakeFusebox()
        self.addCleanup(self.fake.close)

    def test_actions_quote_the_account_and_send_only_toggle_bodies(self):
        self.assertEqual(fusebox.run_action(self.fake.base, "toggle", "file:claude-a.json", True), {"ok": True})
        self.assertEqual(fusebox.run_action(self.fake.base, "reset", "file:claude-a.json"), {"ok": True})
        self.assertEqual([(c[0], c[1], c[3]) for c in self.fake.calls], [
            ("POST", "/api/accounts/file%3Aclaude-a.json/toggle", {"disabled": True}),
            ("POST", "/api/accounts/file%3Aclaude-a.json/reset", None)])
        with self.assertRaises(fusebox.Failure) as unknown:
            fusebox.run_action(self.fake.base, "refresh", "file:missing.json")
        self.assertEqual(unknown.exception.message, "unknown account", "the server's own reason is shown")
        with self.assertRaises(fusebox.Failure):
            fusebox.run_action(self.fake.base, "reset", "bad\nid")

    def test_priority_sends_only_the_dashboards_choices(self):
        self.assertEqual(fusebox.run_action(self.fake.base, "priority", "file:claude-a.json", priority=-10),
                         {"ok": True})
        self.assertEqual([(c[0], c[1], c[3]) for c in self.fake.calls],
                         [("POST", "/api/accounts/file%3Aclaude-a.json/priority", {"priority": -10})])
        with self.assertRaises(fusebox.Failure):
            fusebox.run_action(self.fake.base, "priority", "file:claude-a.json", priority=5)
        self.assertEqual(len(self.fake.calls), 1, "an unknown priority is never sent")
        result = subprocess.run([sys.executable, "-B", str(SCRIPT), "action", "--url", self.fake.base, "priority",
                                 "file:claude-a.json"], capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 2, "priority needs an explicit value")

    def test_activity_is_bounded_to_what_the_details_show(self):
        details = fusebox.run_activity(self.fake.base, "file:claude-a.json")
        self.assertEqual(details, {"sessions": [{"lastSeen": 1791540000000, "since": None, "active": True,
                                                 "client": "Claude Code", "model": "claude-x", "requests": 4,
                                                 "quota": {"week": 4.25}, "keyLabel": "Laptop",
                                                 "source": {"ip": "10.0.0.2", "via": "direct", "login": None}}],
                                   "series": [{"minute": 29833000, "requests": 3, "failed": 1}]})

    def test_cli_reports_failures_as_json(self):
        result = subprocess.run([sys.executable, "-B", str(SCRIPT), "action", "--url", self.fake.base, "toggle",
                                 "file:claude-a.json"], capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 2, "toggle needs an explicit direction")
        result = subprocess.run([sys.executable, "-B", str(SCRIPT), "activity", "--url", self.fake.base,
                                 "file:claude-a.json"], capture_output=True, text=True, timeout=20,
                                env=dict(os.environ, XDG_CONFIG_HOME=self.temporary.name + "/empty"))
        self.assertEqual(result.returncode, 1)
        self.assertEqual(json.loads(result.stdout)["state"], "setup")


if __name__ == "__main__":
    unittest.main()
