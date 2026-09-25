from __future__ import annotations

import contextlib
import json
import os
import subprocess
import sys
import tempfile
import threading
import unittest
import urllib.error
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest import mock

from test_backend import BACKEND, fixture, usage


class CliProxyTests(unittest.TestCase):
    def test_antigravity_model_groups_keep_unknown_separate_from_exhausted(self):
        windows = usage.parse_antigravity_usage({"groups": [{"displayName": "Gemini", "buckets": [
            {"window": "Weekly", "remainingFraction": 0.75, "resetTime": "2030-01-01T00:00:00Z"},
            {"window": "Daily", "remainingFraction": 0}, {"window": "Unknown"}]}]})
        self.assertEqual([row["remaining"] for row in windows], [75, 0, None])
        self.assertEqual(windows[0]["resetsAt"], 1893456000)
        self.assertEqual(windows[2]["used"], None)
        client = mock.Mock()
        client.usage.return_value = {"groups": []}
        row = usage.fetch_cliproxy_account("antigravity", {"auth_index": "a", "project_id": "project"}, client, 2)
        self.assertEqual(row["status"], "ok")
        self.assertEqual(client.usage.call_args.kwargs["data"], {"project": "project"})
        missing = usage.fetch_cliproxy_account("antigravity", {"auth_index": "a"}, client, 2)
        self.assertEqual(missing["status"], "error")
        self.assertIn("project ID", missing["message"])

    def test_discovery_ignores_local_filters_and_keeps_unqueried_accounts(self):
        entries = [{"provider": "new-provider", "auth_index": "a"},
                   {"provider": "antigravity", "auth_index": "b", "disabled": True}]
        with mock.patch.object(usage, "read_cliproxy_key", return_value="key"), \
                mock.patch.object(usage.CliProxyClient, "auth_files", return_value=entries), \
                mock.patch.object(usage.CliProxyClient, "usage") as upstream:
            rows = usage.collect_cliproxy([], 1, "https://proxy.test", Path("key"), discover=True)
        self.assertEqual([row["id"] for row in rows], ["antigravity", "new-provider"])
        self.assertEqual([row["status"] for row in rows], ["disabled", "unsupported"])
        upstream.assert_not_called()

    def test_new_provider_history_survives_reload(self):
        with tempfile.TemporaryDirectory() as temporary:
            provider = usage.base_provider("antigravity")
            provider["windows"] = [usage.make_window("model", "Models", 25)]
            usage.update_and_attach_history([provider], Path(temporary), now=1900000000)
            loaded = usage.load_history(usage.history_path(Path(temporary)))
            self.assertEqual(loaded["providers"]["antigravity"], [[1900000000, 25]])

    def test_urls_accept_dashboard_management_and_reverse_proxy_prefix(self):
        for suffix in ("", "/", "/management.html", "/v0/management", "/v0/management/auth-files"):
            self.assertEqual(usage.normalize_cliproxy_url("https://proxy.test/prefix" + suffix), "https://proxy.test/prefix")
        for address in ("file:///tmp/key", "https://user:secret@proxy.test", "https://proxy.test?key=secret",
                        "https://proxy.test#secret", "https://proxy.test:bad", "https://proxy.test/%2e%2e",
                        "https://proxy.test\n/secret", ""):
            with self.subTest(address=address), self.assertRaises(usage.ProviderFailure) as raised:
                usage.normalize_cliproxy_url(address)
            self.assertEqual(raised.exception.kind, "config")
            self.assertNotIn("secret", raised.exception.message)

    def test_key_file_is_private_bounded_and_regular(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "key"
            path.write_text("management-secret\n")
            path.chmod(0o600)
            self.assertEqual(usage.read_cliproxy_key(path), "management-secret")
            path.chmod(0o644)
            with self.assertRaises(usage.ProviderFailure):
                usage.read_cliproxy_key(path)
            path.chmod(0o600)
            link = Path(temporary) / "link"
            link.symlink_to(path)
            with self.assertRaises(usage.ProviderFailure):
                usage.read_cliproxy_key(link)
            fifo = Path(temporary) / "fifo"
            os.mkfifo(fifo, 0o600)
            with self.assertRaises(usage.ProviderFailure):
                usage.read_cliproxy_key(fifo)
            for raw in (b"", b"secret\nsecond", b"x" * 8193, b"\xff", b"secret\x7f"):
                path.write_bytes(raw)
                with self.assertRaises(usage.ProviderFailure):
                    usage.read_cliproxy_key(path)

    def test_xdg_key_location_and_override(self):
        with mock.patch.dict(os.environ, {"XDG_CONFIG_HOME": "/config", "CLIPROXY_API_KEY_FILE": ""}):
            self.assertEqual(usage.cliproxy_key_path(), Path("/config/omarchy/model-usage/cliproxy.key"))
            with mock.patch.dict(os.environ, {"CLIPROXY_API_KEY_FILE": "/private/proxy.key"}):
                self.assertEqual(usage.cliproxy_key_path(), Path("/private/proxy.key"))

    def test_codex_scoped_windows_credits_and_relative_resets(self):
        with mock.patch.object(usage.time, "time", return_value=1_900_000_000):
            windows, credits, plan = usage.parse_cliproxy_codex(fixture("cliproxy-codex-usage.json"))
        self.assertEqual(plan, "ChatGPT Pro")
        by_id = {row["id"]: row for row in windows}
        self.assertEqual(by_id["codex-primary"]["remaining"], 58)
        self.assertEqual(by_id["codex-secondary"]["windowSeconds"], usage.SEVEN_DAYS)
        self.assertEqual(by_id["additional-0-primary"]["used"], 0.5)
        self.assertEqual(by_id["additional-0-primary"]["resetsAt"], 1_900_000_600)
        self.assertEqual(credits["remaining"], 17.5)
        self.assertEqual(credits["resetCreditsAvailable"], 2)
        with self.assertRaises(usage.ProviderFailure):
            usage.parse_cliproxy_codex([])

    def test_codex_banked_resets_are_per_account_and_work_without_paid_credits(self):
        client = mock.Mock()
        for count in (0, 1, 3):
            payload = fixture("cliproxy-codex-usage.json")
            payload.pop("credits")
            payload["rate_limit_reset_credits"] = {"available_count": count, "applicable_available_count": 0}
            client.usage.return_value = payload
            row = usage.fetch_cliproxy_account("codex", {"auth_index": str(count), "chatgpt_account_id": "account"}, client, 2)
            self.assertEqual(row["status"], "ok")
            self.assertEqual(row["credits"]["resetCreditsAvailable"], count)
            self.assertIsNone(row["credits"]["remaining"])

    def test_codex_missing_or_invalid_banked_resets_are_unknown(self):
        for reset_credits in (None, {}, {"applicable_available_count": 1},
                              *({"available_count": count} for count in (None, True, -1, 1.5, "bad"))):
            with self.subTest(reset_credits=reset_credits):
                payload = fixture("cliproxy-codex-usage.json")
                payload["rate_limit_reset_credits"] = reset_credits
                _, credits, _ = usage.parse_cliproxy_codex(payload)
                self.assertIsNone(credits["resetCreditsAvailable"])

    def test_management_errors_are_safe_and_bounded(self):
        client = usage.CliProxyClient("https://proxy.test", "private-key")
        cases = [
            (urllib.error.HTTPError("https://proxy.test", 401, "private-key", {}, None), "config"),
            (urllib.error.HTTPError("https://proxy.test", 403, "private-key", {}, None), "config"),
            (urllib.error.HTTPError("https://proxy.test", 429, "private-key", {}, None), "rate_limited"),
            (urllib.error.HTTPError("https://proxy.test", 500, "private-key", {}, None), "http"),
            (TimeoutError("private-key timed out"), "timeout"),
            (urllib.error.URLError("private-key"), "network"),
        ]
        for error, kind in cases:
            try:
                with mock.patch.object(usage.urllib.request, "build_opener") as opener:
                    opener.return_value.open.side_effect = error
                    with self.assertRaises(usage.ProviderFailure) as raised:
                        client.auth_files(1)
                self.assertEqual(raised.exception.kind, kind)
                self.assertNotIn("private-key", raised.exception.message)
            finally:
                if hasattr(error, "close"):
                    error.close()
        for raw in (b"bad-json", b"{}", b"x" * (usage.MAX_HTTP_RESPONSE_BYTES + 1)):
            with mock.patch.object(usage.urllib.request, "build_opener") as opener:
                reader = opener.return_value.open.return_value.__enter__.return_value.read
                reader.return_value = raw
                with self.assertRaises(usage.ProviderFailure) as raised:
                    client.auth_files(1)
                self.assertEqual(raised.exception.kind, "malformed")
                reader.assert_called_once_with(usage.MAX_HTTP_RESPONSE_BYTES + 1)

    def test_upstream_errors_and_malformed_envelopes(self):
        client = usage.CliProxyClient("https://proxy.test", "private-key")
        for envelope, kind in (({"status_code": 401}, "expired"), ({"statusCode": 429}, "rate_limited"),
                               ({"status_code": 502}, "http"), ({"body": "{}"}, "malformed"),
                               ({"status_code": 200, "body": "secret"}, "malformed"), ([], "malformed")):
            with mock.patch.object(client, "request", return_value=envelope):
                with self.assertRaises(usage.ProviderFailure) as raised:
                    client.usage({"auth_index": "index"}, "https://usage.test", {}, 1)
                self.assertEqual(raised.exception.kind, kind)
                self.assertNotIn("secret", raised.exception.message)

    def test_account_errors_do_not_suggest_local_login(self):
        client = mock.Mock()
        missing = usage.fetch_cliproxy_account("codex", {"auth_index": "index"}, client, 1)
        self.assertEqual(missing["errorKind"], "config")
        self.assertEqual(missing["authCommand"], "")
        client.usage.assert_not_called()
        client.usage.side_effect = RuntimeError("private-key")
        failed = usage.fetch_cliproxy_account("kimi", {}, client, 1)
        self.assertNotIn("private-key", json.dumps(failed))

    def test_no_enabled_providers_skips_management_entirely(self):
        with mock.patch.object(usage, "read_cliproxy_key") as key:
            self.assertEqual(usage.collect_cliproxy([], 1, "invalid", Path("missing")), [])
        key.assert_not_called()

    def test_missing_accounts_and_failed_configuration_keep_provider_contract(self):
        with mock.patch.object(usage, "read_cliproxy_key", return_value="private-key"), \
                mock.patch.object(usage.CliProxyClient, "auth_files", return_value=[]):
            results = usage.collect_cliproxy(["claude", "kimi"], 1, "https://proxy.test", Path("key"))
        self.assertEqual([row["id"] for row in results], ["claude", "kimi"])
        self.assertTrue(all(row["errorKind"] == "no_credentials" and row["authCommand"] == "" for row in results))
        with tempfile.TemporaryDirectory() as temporary:
            results = usage.collect_cliproxy(["codex"], 1, "https://proxy.test", Path(temporary) / "absent")
        self.assertEqual(results[0]["errorKind"], "config")

    def test_account_limit_and_shared_deadline(self):
        entries = [{"provider": "kimi", "auth_index": str(i)} for i in range(40)]
        with mock.patch.object(usage, "read_cliproxy_key", return_value="key"), \
                mock.patch.object(usage.CliProxyClient, "auth_files", return_value=entries), \
                mock.patch.object(usage, "fetch_cliproxy_account", side_effect=lambda *args: usage.base_provider("kimi")) as fetch:
            result = usage.collect_cliproxy(["kimi"], 1, "https://proxy.test", Path("key"))[0]
        self.assertEqual(fetch.call_count, usage.MAX_CLIPROXY_ACCOUNTS)
        self.assertIn("first 32", result["notice"])
        with mock.patch.object(usage, "read_cliproxy_key", return_value="key"), \
                mock.patch.object(usage.CliProxyClient, "auth_files", return_value=entries[:1]), \
                mock.patch.object(usage.time, "monotonic", side_effect=[0, 2]), \
                mock.patch.object(usage, "fetch_cliproxy_account") as fetch:
            result = usage.collect_cliproxy(["kimi"], 1, "https://proxy.test", Path("key"))[0]
        self.assertEqual(result["errorKind"], "timeout")
        fetch.assert_not_called()


@contextlib.contextmanager
def proxy_server(redirect=False):
    calls = []

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_GET(self):
            calls.append((self.path, self.headers.get("Authorization"), None))
            if redirect:
                self.send_response(302)
                self.send_header("Location", "/redirected")
                self.end_headers()
                return
            if self.path != "/v0/management/auth-files":
                self.send_error(404)
                return
            self.reply(fixture("cliproxy-auth-files.json"))

        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            calls.append((self.path, self.headers.get("Authorization"), body))
            index = body["auth_index"]
            if index == "claude-expired":
                self.reply({"status_code": 401, "body": "private-token"})
                return
            if index.startswith("claude"):
                data = {"five_hour": {"utilization": 100 if index == "claude-exhausted" else 25},
                        "seven_day": {"utilization": 10}}
            elif index == "codex-account":
                data = fixture("cliproxy-codex-usage.json")
            else:
                data = fixture("kimi-usage.json")
            self.reply({"status_code": 200, "body": json.dumps(data)})

        def reply(self, payload):
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(payload).encode())

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_port}", calls
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


class CliProxyIntegrationTests(unittest.TestCase):
    def test_direct_provider_redirect_does_not_forward_signin_token(self):
        with proxy_server(redirect=True) as (address, calls):
            with self.assertRaises(usage.ProviderFailure) as raised:
                usage.http_json(address + "/usage", {"Authorization": "Bearer synthetic-signin"}, 1)
        self.assertEqual(raised.exception.kind, "http")
        self.assertEqual(len(calls), 1)

    def test_real_http_cli_pool_selection_and_separate_private_history(self):
        with tempfile.TemporaryDirectory() as temporary, proxy_server() as (address, calls):
            root = Path(temporary)
            key = root / "management.key"
            key.write_text("private-management-key")
            key.chmod(0o600)
            state = root / "state"
            state.mkdir()
            direct_history = state / "history.json"
            direct_history.write_text('{"direct":"untouched"}')
            command = [sys.executable, str(BACKEND), "--source", "cliproxy", "--cliproxy-url", address + "/management.html",
                       "--cliproxy-key-file", str(key), "--state-dir", str(state), "--timeout", "2"]
            process = subprocess.run(command, capture_output=True, text=True, timeout=10, check=True)
            payload = json.loads(process.stdout)
            claude, codex, gemini, kimi = payload["providers"]
            self.assertTrue(all(row["status"] == "ok" for row in (claude, codex, kimi)))
            self.assertEqual(gemini["status"], "unsupported")
            self.assertEqual(gemini["windows"], [])
            self.assertEqual(len(claude["accounts"]), 4)
            self.assertEqual(claude["accounts"][3]["status"], "disabled")
            self.assertEqual(claude["account"], "free@example.invalid")
            self.assertEqual(claude["windows"][0]["remaining"], 75)
            self.assertEqual((claude["availableCount"], claude["accountCount"]), (2, 4))
            self.assertIn("2 of 4", claude["notice"])
            self.assertEqual(codex["plan"], "ChatGPT Pro")
            self.assertEqual(kimi["credits"]["remaining"], 100)
            self.assertEqual(direct_history.read_text(), '{"direct":"untouched"}')
            histories = list(state.glob("cliproxy-*/history.json"))
            self.assertEqual(len(histories), 1)
            history = histories[0]
            self.assertEqual(history.stat().st_mode & 0o777, 0o600)
            self.assertEqual(history.parent.stat().st_mode & 0o777, 0o700)
            self.assertEqual(json.loads(history.read_text())["providers"]["claude"][-1][1], 25)
            for secret in ("private-management-key", "private-client-key", "private-token", "claude-available", "chatgpt-account"):
                self.assertNotIn(secret, process.stdout + process.stderr + history.read_text())
            self.assertEqual(len(calls), 6)  # Account list and five quota reads; no model or client-key requests.
            for path, authorization, body in calls:
                self.assertEqual(authorization, "Bearer private-management-key")
                if body:
                    self.assertEqual(path, "/v0/management/api-call")
                    self.assertEqual(body["method"], "GET")
                    self.assertEqual(body["header"]["Authorization"], "Bearer $TOKEN$")
                    if body["auth_index"] == "codex-account":
                        self.assertEqual(body["header"]["ChatGPT-Account-Id"], "chatgpt-account")

    def test_management_redirect_does_not_forward_key(self):
        with proxy_server(redirect=True) as (address, calls):
            client = usage.CliProxyClient(address, "private-key")
            with self.assertRaises(usage.ProviderFailure) as raised:
                client.auth_files(1)
        self.assertEqual(raised.exception.kind, "http")
        self.assertEqual(len(calls), 1)


if __name__ == "__main__":
    unittest.main()
