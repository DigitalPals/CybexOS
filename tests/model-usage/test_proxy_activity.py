from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
SPEC = importlib.util.spec_from_file_location("proxy_activity", ROOT / "scripts/proxy-activity.py")
activity = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(activity)

ENTRIES = [{"provider": "codex", "auth_index": "secret-index-1", "id": "secret-file-1", "email": "one@example.invalid"},
           {"provider": "codex", "auth_index": "secret-index-2", "id": "secret-file-2", "email": "two@example.invalid"}]
ROWS = [{"provider": "codex", "auth_type": 1, "identity": "secret-index-1", "last_used_at": "2026-01-01T12:00:00Z"},
        {"provider": "codex", "auth_type": 1, "identity": "secret-index-2", "last_used_at": "2026-01-01T13:00:00.123456789+00:00"}]


class ActivityTests(unittest.TestCase):
    def test_latest_request_matches_account_and_never_exposes_raw_identities(self):
        rows = activity.normalize_activity(ENTRIES, {"identities": ROWS})
        self.assertEqual(rows[0]["accountId"], activity.usage.cliproxy_account_record("codex", ENTRIES[1])["accountId"])
        self.assertEqual(rows[0]["status"], "ok")
        for secret in ("secret-index", "secret-file", "example.invalid"):
            self.assertNotIn(secret, json.dumps(rows))
        switched = [{**ROWS[0], "last_used_at": "2026-01-02T00:00:00Z"}, ROWS[1]]
        self.assertEqual(activity.normalize_activity(ENTRIES, {"identities": switched})[0]["accountId"],
                         activity.usage.cliproxy_account_record("codex", ENTRIES[0])["accountId"])

    def test_unknown_deleted_and_other_provider_identities_cannot_select_an_account(self):
        for change in ({"identity": "unmatched"}, {"is_deleted": True}, {"provider": "claude"},
                       {"auth_type": 2}, {"last_used_at": None}):
            self.assertEqual(activity.normalize_activity(ENTRIES, {"identities": [{**ROWS[0], **change}]}), [])
        self.assertEqual(activity.normalize_activity(ENTRIES, {"identities": []}), [])

    def test_tied_requests_are_ambiguous_and_duplicate_rows_are_not(self):
        tied = [ROWS[0], {**ROWS[1], "last_used_at": ROWS[0]["last_used_at"]}]
        result = activity.normalize_activity(ENTRIES, {"identities": tied})[0]
        self.assertEqual(result["status"], "ambiguous")
        self.assertEqual(result["accountId"], "")
        self.assertEqual(activity.normalize_activity(ENTRIES, {"identities": [ROWS[0], ROWS[0]]})[0]["status"], "ok")

    def test_bad_timestamps_and_oversized_or_malformed_payloads_fail_closed(self):
        for value in ("bad", "2026-01-01T12:00:00", "2099-01-01T00:00:00Z", [], 123):
            with self.subTest(value=value), self.assertRaises(activity.keeper.KeeperError):
                activity.normalize_activity(ENTRIES, {"identities": [{**ROWS[0], "last_used_at": value}]})
        for doc in ([], {}, {"identities": {}}, {"identities": [{}] * 4097}):
            with self.assertRaises(activity.keeper.KeeperError):
                activity.normalize_activity(ENTRIES, doc)

    def test_paused_last_account_is_preserved_as_last_used_not_replaced(self):
        rows = activity.normalize_activity([ENTRIES[0], {**ENTRIES[1], "disabled": True}], {"identities": ROWS})
        self.assertEqual(rows[0]["accountId"], activity.usage.cliproxy_account_record("codex", ENTRIES[1])["accountId"])

    def test_http_collection_reads_summary_and_logs_out_even_after_failure(self):
        requests = []
        healthy = [True]

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def reply(self, payload, cookie=False):
                self.send_response(200)
                if cookie:
                    self.send_header("Set-Cookie", "session=synthetic; Path=/")
                self.end_headers()
                self.wfile.write(json.dumps(payload).encode())

            def do_GET(self):
                requests.append(self.path)
                if self.path == "/v0/management/auth-files":
                    assert self.headers["Authorization"] == "Bearer management-secret"
                    self.reply({"files": ENTRIES})
                elif self.path in ("/api/v1/status", "/api/v1/usage/identities"):
                    assert "session=synthetic" in self.headers["Cookie"]
                    self.reply({"running": healthy[0]} if self.path.endswith("status") else {"identities": ROWS})
                else:
                    self.send_error(404)

            def do_POST(self):
                requests.append(self.path)
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                assert self.path in ("/api/v1/auth/login", "/api/v1/auth/logout")
                if self.path.endswith("login"):
                    assert body == {"password": "keeper-secret"}
                self.reply({}, cookie=True)

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with tempfile.TemporaryDirectory() as tmp:
                key, password = Path(tmp) / "key", Path(tmp) / "password"
                key.write_text("management-secret"); key.chmod(0o600)
                password.write_text("keeper-secret"); password.chmod(0o600)
                url = f"http://127.0.0.1:{server.server_port}"
                self.assertEqual(len(activity.collect(url, key, url, password, 3)), 1)
                self.assertEqual(requests, ["/v0/management/auth-files", "/api/v1/auth/login", "/api/v1/status",
                                            "/api/v1/usage/identities", "/api/v1/auth/logout"])
                healthy[0] = False
                with self.assertRaises(activity.keeper.KeeperError):
                    activity.collect(url, key, url, password, 3)
                self.assertEqual(requests[-1], "/api/v1/auth/logout")
        finally:
            server.shutdown(); server.server_close(); thread.join()
