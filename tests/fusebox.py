#!/usr/bin/env python3
"""Fusebox widget transport: key custody, allowlisting, fault rules and the live stream."""
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
ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "roles/desktop/files/quickshell/scripts/fusebox.py"
KEY = "fbx-management-secret"

spec = importlib.util.spec_from_file_location("fusebox", SCRIPT)
fusebox = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fusebox)

try:
    from websockets.sync.client import connect as ws_connect
    from websockets.sync.server import serve as ws_serve
except ImportError:  # pragma: no cover - both install paths ship python3-websockets
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
        fake = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def reply(self, status, body, headers=()):
                data = json.dumps(body).encode()
                self.send_response(status)
                for name, value in headers:
                    self.send_header(name, value)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def handle_any(self, method):
                length = int(self.headers.get("Content-Length") or 0)
                body = json.loads(self.rfile.read(length)) if length else None
                fake.calls.append((method, self.path, self.headers.get("Authorization"), body))
                if fake.redirect:
                    return self.reply(302, {}, [("Location", "http://127.0.0.1:9/steal")])
                if self.headers.get("Authorization") != "Bearer " + KEY:
                    return self.reply(401, {"error": "unauthorized"})
                if method == "GET" and self.path == "/api/overview":
                    return self.reply(200, OVERVIEW)
                if method == "GET" and self.path == "/api/accounts":
                    return self.reply(200, fake.accounts)
                if method == "GET" and self.path == "/api/requests":
                    return self.reply(200, [{"id": n, "ts": "2026-10-09T10:00:00Z", "status": 200,
                                             "session_id": "private-session"} for n in range(90, 0, -1)])
                if method == "GET" and self.path == "/api/faults":
                    # Older releases route unknown /api paths to client-key auth.
                    return self.reply(200, [FAULT]) if fake.faults else self.reply(401, {"error": "invalid api key"})
                if self.path.startswith("/api/accounts/file%3Aclaude-a.json/"):
                    if self.path.endswith("/activity"):
                        return self.reply(200, {"sessions": [{"session": "s1", "last_seen": "2026-10-09T10:00:00Z",
                                                              "active": True, "client_app": "Claude Code",
                                                              "model": "claude-x", "requests": 4}]})
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
        self.path = Path(self.temporary.name) / "cybexos/fusebox/management.key"

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
        self.assertNotIn("secret-session", json.dumps(row))
        self.assertIsNone(fusebox.request({"id": 1, "ts": "bad", "status": 200}))
        self.assertIsNone(fusebox.request({"id": True, "ts": "2026-10-09T10:00:00Z", "status": 200}))
        self.assertEqual(fusebox.load({"a": {"in_flight": 2, "sessions": 3}, "b": {"in_flight": -1}, 5: {}}),
                         {"a": {"inFlight": 2, "sessions": 3}, "b": {"inFlight": 0, "sessions": 0}},
                         "older releases report only the five-minute count")
        # A session waiting on its user is still going on: the half-hour count wins.
        self.assertEqual(fusebox.load({"a": {"in_flight": 0, "sessions": 1, "ongoing_sessions": 2},
                                       "b": {"in_flight": 0, "sessions": 0, "ongoing_sessions": 1}}),
                         {"a": {"inFlight": 0, "sessions": 2}, "b": {"inFlight": 0, "sessions": 1}})


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
        self.assertEqual(kinds, ["state", "overview", "accounts", "requests", "faults", "state", "load", "faults",
                                 "request", "tick"])
        seeded = out.of("requests")[0]["data"]
        self.assertEqual((len(seeded), seeded[0]["id"], seeded[-1]["id"]), (40, 90, 51), "the newest 40, newest first")
        self.assertEqual(out.of("faults")[0], {"type": "faults", "data": fusebox.faults([FAULT]), "source": "server"})
        self.assertEqual(out.of("faults")[1]["data"], [])
        self.assertEqual(out.of("load")[0]["data"], {"file:claude-a.json": {"inFlight": 1, "sessions": 2}})
        self.assertEqual(out.of("tick")[0]["totals"]["requests"], 11)
        self.assertEqual(fake.connected_url, fake.base.replace("http", "ws") + "/api/live")
        self.assertEqual(fake.socket_requests, [("/api/live", "Bearer " + KEY)], "the key is a header, not the URL")
        self.assertEqual([call[1] for call in fake.calls],
                         ["/api/overview", "/api/accounts", "/api/requests", "/api/faults"])
        everything = out.stream.getvalue()
        for secret in (KEY, "fbx_client_secret", "/etc/fusebox", "private-session"):
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

    def test_activity_is_bounded_to_what_the_details_show(self):
        details = fusebox.run_activity(self.fake.base, "file:claude-a.json")
        self.assertEqual(details, {"sessions": [{"lastSeen": 1791540000000, "since": None, "active": True,
                                                 "client": "Claude Code", "model": "claude-x", "requests": 4}]})

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
