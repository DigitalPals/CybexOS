from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
import threading
import unittest
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest import mock

from test_backend import ROOT

SCRIPT = ROOT / "scripts/reset-credit.py"
spec = importlib.util.spec_from_file_location("reset_credit", SCRIPT)
reset = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reset)


def credit(identity="first", expiry="2030-02-01T00:00:00Z", **overrides):
    return dict({"id": identity, "status": "available", "reset_type": "codex_rate_limits",
                 "granted_at": "2030-01-01T00:00:00Z", "expires_at": expiry}, **overrides)


class ResetTests(unittest.TestCase):
    def setUp(self):
        self.entry = {"provider": "codex", "id": "credential", "auth_index": "selected-index",
                      "chatgpt_account_id": "selected-chatgpt", "email": "private@example.test"}
        self.account_id = reset.usage.cliproxy_account_record("codex", self.entry)["accountId"]
        self.client = mock.Mock()
        self.client.auth_files.return_value = [dict(self.entry, id="other", auth_index="other"), self.entry]
        self.client.usage.return_value = {"available_count": 1, "credits": [credit()]}

    def prepare(self):
        return reset.execute(self.client, "prepare", self.account_id)

    def consume(self, details, **kwargs):
        args = {"target": details["target"], "credit_id": "first", "request_id": details["requestId"]}
        args.update(kwargs)
        return reset.execute(self.client, "consume", self.account_id, **args)

    def test_earliest_expiry_then_grant_date_and_nonexpiring_last(self):
        details = reset.normalize_details({"available_count": 5, "applicable_available_count": 0, "credits": [
            credit("forever", None), credit("later", "2030-03-01T00:00:00Z"), credit("first"),
            credit("expired", "2020-01-01T00:00:00Z"), credit("redeemed", status="redeemed"),
            credit("unknown", reset_type="something_else")]}, now=1800000000)
        self.assertEqual([c["id"] for c in details["credits"]], ["first", "later", "forever"])
        self.assertEqual(details["applicableAvailableCount"], 0)
        self.assertEqual(details["availableCount"], 5)

    def test_malformed_details_fail_closed(self):
        for payload in (None, {}, {"available_count": True, "credits": []},
                        {"available_count": 1, "credits": [credit(expiry="bad")]},
                        {"available_count": 2, "credits": [credit(), credit()]},
                        {"available_count": 1, "credits": [credit(identity="")]},
                        {"available_count": 1, "credits": [credit(expiry="2030-01-01")]}):
            with self.subTest(payload=payload), self.assertRaises(reset.usage.ProviderFailure):
                reset.normalize_details(payload)
        self.assertEqual(reset.normalize_details({"available_count": 0, "credits": [credit()]})["credits"], [])

    def test_prepare_is_read_only_and_selects_exact_account(self):
        details = self.prepare()
        uuid.UUID(details["requestId"])
        args = self.client.usage.call_args
        self.assertEqual(args.args[0], self.entry)
        self.assertEqual(args.args[1], reset.RESET_URL)
        self.assertEqual(args.args[2]["ChatGPT-Account-Id"], "selected-chatgpt")
        self.assertEqual(args.kwargs, {})
        self.assertNotIn("private@example.test", json.dumps(details))

    def test_all_outcomes_and_retry_reuse_the_exact_credit_and_request(self):
        details = self.prepare()
        for outcome in ("reset", "nothing_to_reset", "no_credit", "already_redeemed"):
            self.client.usage.return_value = {"code": outcome}
            self.assertEqual(self.consume(details), {"outcome": outcome})
            self.assertEqual(self.client.usage.call_args.kwargs["data"], {
                "credit_id": "first", "redeem_request_id": details["requestId"]})

    def test_account_replacement_pause_missing_or_ambiguous_never_consumes(self):
        details = self.prepare()
        for entries in ([], [dict(self.entry, disabled=True)], [dict(self.entry, status="disabled")],
                        [dict(self.entry, chatgpt_account_id="changed")],
                        [dict(self.entry, auth_index="changed")], [self.entry, self.entry],
                        [dict(self.entry, provider="claude")]):
            self.client.auth_files.return_value = entries
            self.client.usage.reset_mock()
            with self.subTest(entries=entries), self.assertRaises(reset.usage.ProviderFailure):
                self.consume(details)
            self.client.usage.assert_not_called()

    def test_invalid_request_ids_and_target_never_consume(self):
        details = self.prepare()
        for values in ({"request_id": ""}, {"request_id": "not-uuid"}, {"target": "other"}, {"credit_id": ""}):
            self.client.usage.reset_mock()
            with self.subTest(values=values), self.assertRaises(reset.usage.ProviderFailure):
                self.consume(details, **values)
            self.client.usage.assert_not_called()

    def test_unknown_and_timeout_outcomes_remain_uncertain(self):
        details = self.prepare()
        for response in ({}, {"code": "new_future_outcome"}):
            self.client.usage.return_value = response
            with self.assertRaises(reset.usage.ProviderFailure) as raised:
                self.consume(details)
            self.assertTrue(raised.exception.submitted)
        self.client.usage.side_effect = reset.usage.ProviderFailure("timeout", "Timeout")
        with self.assertRaises(reset.usage.ProviderFailure) as raised:
            self.consume(details)
        self.assertTrue(raised.exception.submitted)

    def test_http_subprocess_prepare_consume_and_idempotent_retry(self):
        requests = []
        entry = self.entry
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass
            def reply(self, payload):
                self.send_response(200)
                self.end_headers()
                self.wfile.write(json.dumps(payload).encode())
            def do_GET(self):
                self.reply({"files": [entry]})
            def do_POST(self):
                payload = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                requests.append(payload)
                data = {"available_count": 1, "credits": [credit()]}
                if payload["method"] == "POST":
                    data = {"code": "already_redeemed" if len(requests) > 2 else "reset"}
                self.reply({"status_code": 200, "body": json.dumps(data)})
        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with tempfile.TemporaryDirectory() as temporary:
                key = Path(temporary) / "key"
                key.write_text("synthetic-management-key")
                key.chmod(0o600)
                command = [sys.executable, str(SCRIPT), "--account-id", self.account_id,
                           "--cliproxy-url", f"http://127.0.0.1:{server.server_port}", "--cliproxy-key-file", str(key)]
                details = json.loads(subprocess.check_output(command + ["--action", "prepare"]))
                consume = command + ["--action", "consume", "--target", details["target"],
                                     "--request-id", details["requestId"], "--credit-id", "first"]
                self.assertEqual(json.loads(subprocess.check_output(consume))["outcome"], "reset")
                self.assertEqual(json.loads(subprocess.check_output(consume))["outcome"], "already_redeemed")
            self.assertEqual(requests[1], requests[2])
            self.assertEqual(requests[1]["auth_index"], "selected-index")
            self.assertEqual(requests[1]["header"]["Authorization"], "Bearer $TOKEN$")
            self.assertEqual(requests[1]["header"]["ChatGPT-Account-Id"], "selected-chatgpt")
            self.assertEqual(requests[1]["url"], reset.RESET_URL + "/consume")
            self.assertNotIn("synthetic-management-key", json.dumps(requests))
        finally:
            server.shutdown()
            server.server_close()
            thread.join()
