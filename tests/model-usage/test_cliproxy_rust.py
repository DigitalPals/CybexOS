from __future__ import annotations

import copy
import importlib.util
import json
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from contextlib import contextmanager
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest import mock

from test_backend import ROOT, BACKEND, fixture, usage

NOW = 1893456060


def account(**overrides):
    return dict(fixture("cliproxy-rust-accounts.json")[0], _rust=True, **overrides)


@contextmanager
def proxy_server(document=None, legacy_status=401, native_status=200):
    requests = []

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_GET(self):
            requests.append((self.command, self.path))
            if self.headers.get("Authorization") != "Bearer test-management-key":
                status, payload = 401, {"error": "unauthorized"}
            elif self.path == "/v0/management/auth-files":
                status, payload = legacy_status, {"error": "unsupported"}
            elif self.path == "/api/accounts":
                status, payload = native_status, document if document is not None else fixture("cliproxy-rust-accounts.json")
            else:
                status, payload = 404, {}
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(payload).encode())

        def do_POST(self):
            requests.append((self.command, self.path))
            self.send_error(500, "Actions must not be called")

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_port}", requests
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


class RustQuotaTests(unittest.TestCase):
    def setUp(self):
        patch = mock.patch.object(usage.time, "time", return_value=NOW)
        patch.start()
        self.addCleanup(patch.stop)

    def test_windows_plan_and_unavailable_credits(self):
        row = usage.fetch_rust_account("claude", account())
        self.assertEqual(row["status"], "ok")
        self.assertEqual([w["remaining"] for w in row["windows"]], [75, 50, 30])
        self.assertEqual([w["windowSeconds"] for w in row["windows"][:2]], [18000, 604800])
        self.assertIn("Opus", row["windows"][2]["label"])
        self.assertEqual(row["quotaUpdatedAt"], NOW - 60)
        self.assertFalse(row["stale"])
        self.assertFalse(row["supportsBankedReset"])
        self.assertIsNone(row["credits"])
        codex = dict(fixture("cliproxy-rust-accounts.json")[2], _rust=True)
        row = usage.fetch_rust_account("codex", codex)
        self.assertEqual(row["planType"], "pro")
        self.assertEqual(row["plan"], "ChatGPT Pro")
        self.assertEqual(len(row["windows"]), 1)
        self.assertEqual(row["windows"][0]["used"], 0)

    def test_missing_cache_expired_windows_and_invalid_times_do_not_claim_capacity(self):
        for quota in ({"windows": [], "updated_at": None},
                      {"windows": [], "updated_at": "2030-01-01T00:00:00Z"},
                      {"windows": [{"name": "5h", "used": 80, "resets_at": "2029-12-31T00:00:00Z"}], "updated_at": "2030-01-01T00:00:00Z"},
                      {"windows": [{"name": "5h", "used": 80}], "updated_at": "2030-01-01T00:00:00"},
                      {"windows": [{"name": "5h", "used": 80}], "updated_at": "2031-01-01T00:00:00Z"}):
            with self.subTest(quota=quota):
                row = usage.fetch_rust_account("claude", account(quota=quota))
                self.assertEqual(row["status"], "error")
                self.assertEqual(row["windows"], [])
                self.assertIsNone(row["credits"])

    def test_invalid_quota_numbers_windows_and_metadata_are_errors(self):
        for change in ({"used": True}, {"used": "20"}, {"used": -1}, {"used": 101},
                       {"used": float("nan")}, {"used": float("inf")}, {"used": None},
                       {"model": {}}, {"resets_at": "bad"}, {"name": ""}):
            quota = copy.deepcopy(account()["quota"])
            quota["windows"][0].update(change)
            with self.subTest(change=change):
                self.assertEqual(usage.fetch_rust_account("claude", account(quota=quota))["errorKind"], "malformed")
        for change in ({"plan": {}}, {"windows": [{}] * 129}, {"windows": [account()["quota"]["windows"][0]] * 2}):
            quota = dict(account()["quota"], **change)
            self.assertEqual(usage.fetch_rust_account("claude", account(quota=quota))["status"], "error")

    def test_disabled_and_unqueried_providers_stay_visible(self):
        self.assertEqual(usage.fetch_rust_account("claude", account(disabled=True))["status"], "disabled")
        self.assertEqual(usage.fetch_rust_account("gemini", account(provider="gemini"))["status"], "unsupported")
        self.assertEqual(usage.fetch_rust_account("codex", account(kind="api-key"))["status"], "unsupported")

    def test_stale_cache_and_repeated_observations_do_not_extend_history(self):
        row = usage.fetch_rust_account("claude", account())
        with tempfile.TemporaryDirectory() as temporary:
            state = Path(temporary)
            usage.update_and_attach_history([row], state, now=NOW)
            original = (state / "history.json").read_text()
            usage.update_and_attach_history([row], state, now=NOW + 120)
            self.assertEqual((state / "history.json").read_text(), original)
            with mock.patch.object(usage.time, "time", return_value=NOW + 601):
                stale = usage.fetch_rust_account("claude", account())
            self.assertTrue(stale["stale"])
            usage.update_and_attach_history([stale], state, now=NOW + 601)
            self.assertEqual((state / "history.json").read_text(), original)
            self.assertEqual(stale["fetchedAt"], row["fetchedAt"])


class RustIntegrationTests(unittest.TestCase):
    def test_legacy_auth_failures_and_missing_paths_detect_rust_with_same_key(self):
        for status in (401, 403, 404, 405):
            with self.subTest(status=status), proxy_server(legacy_status=status) as (url, requests):
                client = usage.CliProxyClient(url, "test-management-key")
                rows = client.auth_files(2)
                self.assertEqual(client.implementation, "rust")
                self.assertEqual(len(rows), 4)
                self.assertEqual(rows[0]["id"], "claude-one.json")
                self.assertEqual(usage.cliproxy_account_record("claude", rows[0])["accountId"],
                                 usage.cliproxy_account_record("claude", {"id": "claude-one.json"})["accountId"])
                client.auth_files(2)
                self.assertEqual(requests[-1], ("GET", "/api/accounts"))
                with self.assertRaises(usage.ProviderFailure):
                    client.usage(rows[0], "https://upstream.invalid/action", {}, 1, data={})
                self.assertTrue(all(method == "GET" for method, _ in requests))

    def test_wrong_key_and_invalid_native_shape_never_succeed(self):
        with proxy_server() as (url, requests):
            client = usage.CliProxyClient(url, "wrong-key")
            with self.assertRaises(usage.ProviderFailure) as error:
                client.auth_files(2)
            self.assertEqual(error.exception.kind, "config")
            self.assertEqual(client.implementation, "auto")
        for document in ({"files": []}, [None], [{"id": "x", "provider": "codex"}],
                         [dict(account(), disabled="false")], [dict(account(), file="mismatch.json")],
                         [account(), account()], [{}] * 4097):
            with self.subTest(document=str(document)[:80]), proxy_server(document=document) as (url, requests):
                client = usage.CliProxyClient(url, "test-management-key")
                with self.assertRaises(usage.ProviderFailure) as error:
                    client.auth_files(2)
                self.assertEqual(error.exception.kind, "malformed")
                self.assertEqual(client.implementation, "auto")

    def test_empty_inventory_is_valid_and_legacy_outages_are_not_reinterpreted(self):
        with proxy_server(document=[]) as (url, requests):
            client = usage.CliProxyClient(url, "test-management-key")
            self.assertEqual(client.auth_files(2), [])
            self.assertEqual(client.implementation, "rust")
        with proxy_server(legacy_status=500) as (url, requests):
            with self.assertRaises(usage.ProviderFailure):
                usage.CliProxyClient(url, "test-management-key").auth_files(2)
            self.assertEqual(requests, [("GET", "/v0/management/auth-files")])

    def test_detection_shares_a_deadline(self):
        client = usage.CliProxyClient("https://proxy.invalid", "key")
        failure = usage.ProviderFailure("config", "Rejected")
        failure.http_status = 401
        with mock.patch.object(client, "request", side_effect=failure) as request, \
                mock.patch.object(usage.time, "monotonic", side_effect=[100, 102]):
            with self.assertRaises(usage.ProviderFailure) as error:
                client.auth_files(1)
        self.assertEqual(error.exception.kind, "timeout")
        self.assertEqual(request.call_count, 1)

    def test_native_response_limit_is_enforced(self):
        with proxy_server(document=[{"padding": "x" * (usage.MAX_HTTP_RESPONSE_BYTES + 1)}]) as (url, requests):
            with self.assertRaises(usage.ProviderFailure) as error:
                usage.CliProxyClient(url, "test-management-key").auth_files(2)
            self.assertEqual(error.exception.kind, "malformed")

    def test_subprocess_discovery_and_native_activity_only_read_account_api(self):
        document = fixture("cliproxy-rust-accounts.json")
        now = time.time()
        for row in document:
            row["last_used"] = datetime.fromtimestamp(now - 30, timezone.utc).isoformat() if row["last_used"] else None
            if row["quota"]["updated_at"]:
                row["quota"]["updated_at"] = datetime.fromtimestamp(now - 20, timezone.utc).isoformat()
        with proxy_server(document=document) as (url, requests), tempfile.TemporaryDirectory() as temporary:
            key = Path(temporary) / "key"
            key.write_text("test-management-key")
            key.chmod(0o600)
            args = ["--cliproxy-url", url, "--cliproxy-key-file", str(key), "--timeout", "2"]
            output = subprocess.check_output([sys.executable, "-B", str(BACKEND), "--source", "cliproxy",
                                              "--state-dir", temporary, *args], text=True)
            result = json.loads(output)
            self.assertEqual(result["proxyImplementation"], "rust")
            self.assertEqual(len(result["providers"]), 3)
            self.assertEqual(next(p for p in result["providers"] if p["id"] == "codex")["status"], "ok")
            activity = json.loads(subprocess.check_output([sys.executable, "-B", str(ROOT / "scripts/proxy-activity.py"), *args]))
            self.assertEqual(activity["error"], "")
            self.assertEqual(len(activity["providers"]), 2)
            self.assertEqual(next(p for p in activity["providers"] if p["id"] == "claude")["status"], "ambiguous")
            self.assertNotIn("test-management-key", output)
            self.assertNotIn("file:", output)
            self.assertTrue(all(method == "GET" and path in ("/api/accounts", "/v0/management/auth-files") for method, path in requests))

    def test_reset_script_rejects_native_account_before_any_action(self):
        document = fixture("cliproxy-rust-accounts.json")
        with proxy_server(document=document) as (url, requests), tempfile.TemporaryDirectory() as temporary:
            key = Path(temporary) / "key"
            key.write_text("test-management-key")
            key.chmod(0o600)
            account_id = usage.cliproxy_account_record("codex", {"id": "codex-one.json"})["accountId"]
            args = [sys.executable, "-B", str(ROOT / "scripts/reset-credit.py"), "--action", "prepare",
                    "--cliproxy-url", url, "--cliproxy-key-file", str(key), "--account-id", account_id]
            result = json.loads(subprocess.check_output(args))
            self.assertFalse(result["ok"])
            self.assertIn("unavailable through Fusebox", result["message"])
            self.assertTrue(all(method == "GET" for method, _ in requests))


class RustActivityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location("rust_activity_test", ROOT / "scripts/proxy-activity.py")
        cls.activity = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.activity)

    def test_activity_is_private_preserves_paused_latest_and_clears_after_restart(self):
        entries = [dict(row, _rust=True) for row in fixture("cliproxy-rust-accounts.json")]
        result = self.activity.normalize_rust_activity(entries, now=NOW)
        claude = next(p for p in result if p["id"] == "claude")
        self.assertEqual(claude["accountId"], self.activity.usage.cliproxy_account_record("claude", entries[1])["accountId"])
        self.assertNotIn("example.invalid", json.dumps(result))
        self.assertNotIn("claude-two.json", json.dumps(result))
        for entry in entries:
            entry["last_used"] = None
        self.assertEqual(self.activity.normalize_rust_activity(entries, now=NOW), [])

    def test_bad_activity_timestamps_are_not_accepted(self):
        for value in ("2030-01-01T00:00:00", "bad", "2031-01-01T00:00:00Z", 123):
            with self.subTest(value=value), self.assertRaises(self.activity.usage.ProviderFailure):
                self.activity.normalize_rust_activity([account(last_used=value)], now=NOW)

    def test_activity_timestamps_accept_rust_fractional_precision(self):
        for fraction in ("1", "12", "123", "1234", "12345", "123456", "123456789"):
            for timestamp in (f"2030-01-01T00:00:30.{fraction}Z",
                              f"2030-01-01T01:00:30.{fraction}+01:00"):
                with self.subTest(timestamp=timestamp):
                    expected = NOW - 30 + int((fraction + "000000")[:6]) / 1_000_000
                    self.assertEqual(self.activity.usage.rust_timestamp(timestamp, observed=True, now=NOW), expected)
