#!/usr/bin/env python3
"""Deterministic auth, cache, and concurrency contracts for usage-fetch."""

from __future__ import annotations

import importlib.util
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
import stat
import subprocess
import threading
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
PATH = ROOT / "roles/desktop/files/quickshell/scripts/usage-fetch.py"
SPEC = importlib.util.spec_from_file_location("usage_fetch", PATH)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)

CREDENTIAL_PATH = (ROOT / "roles/desktop/files/quickshell/scripts/"
                   "usage-credential.py")


class FetchAllTests(unittest.TestCase):
    def test_providers_start_concurrently_and_keep_declared_order(self):
        barrier = threading.Barrier(3, timeout=1)

        def provider(name):
            def fetch():
                barrier.wait()
                return {"status": "ok", "name": name}

            return fetch

        providers = tuple((name, provider(name)) for name in ("a", "b", "c"))
        result = MODULE.fetch_all(providers)

        self.assertEqual(list(result), ["a", "b", "c"])
        self.assertEqual([value["status"] for value in result.values()], ["ok"] * 3)

    def test_one_provider_failure_does_not_hide_the_others(self):
        def broken():
            raise ValueError("malformed credentials")

        result = MODULE.fetch_all((
            ("good", lambda: {"status": "ok"}),
            ("bad", broken),
        ))

        self.assertEqual(result["good"], {"status": "ok"})
        self.assertEqual(result["bad"]["status"], "error")
        self.assertEqual(result["bad"]["kind"], "parse")
        self.assertIn("malformed credentials", result["bad"]["message"])


class ClaudeRefreshTests(unittest.TestCase):
    def test_refresh_is_delegated_to_cli_without_putting_token_in_arguments(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / ".credentials.json"
            oauth = {
                "accessToken": "expired-access",
                "expiresAt": 1,
                "refreshToken": "private-refresh-token",
                "refreshTokenExpiresAt": (time.time() + 3600) * 1000,
                "scopes": ["user:profile", "user:inference"],
            }
            path.write_text(json.dumps({"claudeAiOauth": oauth}))

            def run(command, **kwargs):
                self.assertEqual(command,
                                 ["/test/bin/claude", "auth", "login", "--claudeai"])
                self.assertNotIn("private-refresh-token", " ".join(command))
                self.assertEqual(kwargs["env"]["CLAUDE_CODE_OAUTH_REFRESH_TOKEN"],
                                 "private-refresh-token")
                self.assertEqual(kwargs["env"]["CLAUDE_CODE_OAUTH_SCOPES"],
                                 "user:profile user:inference")
                refreshed = dict(oauth, accessToken="fresh-access",
                                 expiresAt=(time.time() + 3600) * 1000)
                path.write_text(json.dumps({"claudeAiOauth": refreshed}))
                return mock.Mock(returncode=0, stdout=b"", stderr=b"")

            with mock.patch.object(MODULE.shutil, "which", return_value="/test/bin/claude"), \
                    mock.patch.object(MODULE.subprocess, "run", side_effect=run):
                refreshed, error = MODULE.refresh_claude_oauth(str(path), oauth)

            self.assertIsNone(error)
            self.assertEqual(refreshed["accessToken"], "fresh-access")

    def test_cli_failure_does_not_surface_captured_auth_output(self):
        oauth = {
            "accessToken": "expired-access",
            "refreshToken": "private-refresh-token",
            "refreshTokenExpiresAt": (time.time() + 3600) * 1000,
            "scopes": ["user:profile"],
        }
        completed = mock.Mock(returncode=1, stdout=b"private-refresh-token",
                              stderr=b"sensitive diagnostic")
        with mock.patch.object(MODULE.shutil, "which", return_value="/test/bin/claude"), \
                mock.patch.object(MODULE.subprocess, "run", return_value=completed):
            refreshed, error = MODULE.refresh_claude_oauth("/unused", oauth)

        self.assertIsNone(refreshed)
        self.assertEqual(error["kind"], "refresh")
        self.assertNotIn("private-refresh-token", json.dumps(error))
        self.assertNotIn("sensitive diagnostic", json.dumps(error))

    def test_expiring_access_token_uses_refresh_before_usage_request(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / ".credentials.json"
            expired = {"accessToken": "old", "expiresAt": 1,
                       "subscriptionType": "pro"}
            fresh = dict(expired, accessToken="fresh",
                         expiresAt=(time.time() + 3600) * 1000)
            path.write_text(json.dumps({"claudeAiOauth": expired}))

            def request(provider, url, headers):
                self.assertEqual(provider, "claude")
                self.assertEqual(headers["Authorization"], "Bearer fresh")
                return {"limits": []}, None

            with mock.patch.dict(os.environ, {
                    "CLAUDE_CONFIG_DIR": temporary, "HOME": temporary
                 }), \
                    mock.patch.object(MODULE, "refresh_claude_oauth",
                                      return_value=(fresh, None)) as refresh, \
                    mock.patch.object(MODULE, "http_json", side_effect=request):
                result = MODULE.fetch_claude(auto_refresh=True)

            refresh.assert_called_once_with(str(path), expired)
            self.assertEqual(result["status"], "ok")
            self.assertEqual(result["plan"], "Claude Pro")


class ClaudeFableTests(unittest.TestCase):
    def test_legacy_fable_limit_retains_weekly_percentage_and_reset(self):
        data = {"seven_day": {"utilization": 26},
                "seven_day_fable": {"utilization": 51, "resets_at": "2030-01-01T00:00:00Z"}}
        result = MODULE.parse_claude_usage(data)
        self.assertEqual([row["label"] for row in result["windows"]],
                         ["Weekly limit", "Weekly (Fable)"])
        self.assertEqual(result["windows"][1]["used"], 51)
        self.assertEqual(result["windows"][1]["windowSecs"], MODULE.SEVEN_DAYS)
        self.assertEqual(result["windows"][1]["resetsAt"], 1893456000)


class ClaudePlanTests(unittest.TestCase):
    def test_max_tier_includes_its_usage_multiplier(self):
        self.assertEqual(MODULE.claude_plan({
            "subscriptionType": "max",
            "rateLimitTier": "default_claude_max_20x",
        }), "Claude Max 20x")
        self.assertEqual(MODULE.claude_plan({
            "subscriptionType": "max",
            "rateLimitTier": "default-claude-max-5x",
        }), "Claude Max 5x")

    def test_non_max_and_unknown_tiers_fall_back_to_subscription(self):
        self.assertEqual(MODULE.claude_plan({
            "subscriptionType": "pro",
            "rateLimitTier": "default_claude_pro",
        }), "Claude Pro")
        self.assertEqual(MODULE.claude_plan({
            "subscriptionType": "max",
            "rateLimitTier": "future_tier_name",
        }), "Claude Max")

    def test_cached_label_updates_and_identity_metadata_is_removed(self):
        state = {
            "version": MODULE.STATE_VERSION,
            "providers": {"claude": {"lastOk": {
                "status": "ok",
                "plan": "Claude Max",
                "account": "private@example.test",
                "source": "claude-oauth",
            }}},
        }
        with tempfile.TemporaryDirectory() as temporary:
            credential_dir = Path(temporary) / ".claude"
            credential_dir.mkdir()
            credential_dir.joinpath(".credentials.json").write_text(json.dumps({
                "claudeAiOauth": {
                    "accessToken": "unused",
                    "subscriptionType": "max",
                    "rateLimitTier": "default_claude_max_20x",
                }
            }))
            with mock.patch.dict(os.environ, {"HOME": temporary}, clear=False):
                MODULE.update_cached_claude_metadata(state)

        cached = state["providers"]["claude"]["lastOk"]
        self.assertEqual(cached["plan"], "Claude Max 20x")
        self.assertNotIn("account", cached)
        self.assertNotIn("source", cached)


class XaiUsageTests(unittest.TestCase):
    def test_weekly_period_without_percentage_remains_unknown(self):
        result = MODULE.parse_xai_usage({"config": {
            "currentPeriod": {
                "type": "USAGE_PERIOD_TYPE_WEEKLY",
                "start": "2026-09-03T05:37:29+00:00",
                "end": "2026-09-10T05:37:29+00:00",
            },
        }}, {"config": {
            "monthlyLimit": {"val": 0},
            "used": {"val": 0},
            "onDemandCap": {"val": 0},
        }})

        self.assertEqual(result["status"], "ok")
        self.assertEqual(len(result["windows"]), 1)
        self.assertIsNone(result["windows"][0]["used"])
        self.assertEqual(result["windows"][0]["windowSecs"], MODULE.SEVEN_DAYS)
        self.assertEqual(result["windows"][0]["resetsAt"],
                         MODULE.parse_rfc3339("2026-09-10T05:37:29+00:00"))
        self.assertIsNone(result["credits"])

    def test_percent_products_plan_and_monthly_credits_are_normalized(self):
        result = MODULE.parse_xai_usage({"config": {
            "current_period": {
                "type": "weekly",
                "start": "2026-09-03T05:37:29Z",
                "end": "2026-09-10T05:37:29Z",
            },
            "credit_usage_percent": "31.25",
            "product_usage": [
                {"product": "Grok Code", "usage_percent": "80"},
            ],
        }}, {"config": {
            "monthly_limit": {"val": 15_000},
            "used": {"val": 2_500},
        }})

        self.assertEqual(result["plan"], "SuperGrok")
        self.assertEqual([row["used"] for row in result["windows"]],
                         [31.25, 80.0])
        self.assertEqual(result["windows"][1]["label"], "Grok Code usage")
        self.assertEqual(result["credits"]["label"], "Monthly credits")
        self.assertEqual(result["credits"]["used"], 25)
        self.assertEqual(result["credits"]["limit"], 150)


class CliProxyTests(unittest.TestCase):
    def test_dashboard_and_management_urls_normalize_to_server_base(self):
        self.assertEqual(MODULE.normalize_cliproxy_url(
            "https://10.10.0.235:8317/management.html"),
            "https://10.10.0.235:8317")
        self.assertEqual(MODULE.normalize_cliproxy_url(
            "https://proxy.test/prefix/v0/management/"),
            "https://proxy.test/prefix")
        with self.assertRaises(ValueError):
            MODULE.normalize_cliproxy_url("https://user:secret@proxy.test")

    def test_management_key_reader_rejects_broad_permissions(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "key"
            path.write_text("management-secret\n")
            path.chmod(0o600)
            key, failure = MODULE.read_cliproxy_key(str(path))
            self.assertEqual(key, "management-secret")
            self.assertIsNone(failure)

            path.chmod(0o644)
            key, failure = MODULE.read_cliproxy_key(str(path))
            self.assertIsNone(key)
            self.assertEqual(failure["kind"], "config")

    def test_api_call_uses_auth_index_and_token_placeholder(self):
        calls = []

        def request(url, headers, method, body, ssl_context):
            calls.append((url, headers, method, json.loads(body)))
            response = {"status_code": 200, "body": json.dumps({"limits": []})}
            return 200, json.dumps(response).encode(), {}

        client = MODULE.CliProxyClient("https://proxy.test/management.html",
                                       "management-secret", verify_tls=False)
        with mock.patch.object(MODULE, "http_request", side_effect=request):
            data, failure = client.api_json("auth-17", "https://upstream.test/usage", {
                "Authorization": "Bearer $TOKEN$",
            })

        self.assertIsNone(failure)
        self.assertEqual(data, {"limits": []})
        url, headers, method, payload = calls[0]
        self.assertEqual(url, "https://proxy.test/v0/management/api-call")
        self.assertEqual(method, "POST")
        self.assertEqual(headers["Authorization"], "Bearer management-secret")
        self.assertEqual(payload["auth_index"], "auth-17")
        self.assertEqual(payload["header"]["Authorization"], "Bearer $TOKEN$")

    def test_account_pool_keeps_every_subscription_and_best_summary(self):
        entries = [
            {"provider": "codex", "auth_index": "full",
             "email": "first@example.test", "label": "first@example.test"},
            {"provider": "codex", "auth_index": "open",
             "email": "second@example.test", "label": "second@example.test"},
            {"provider": "codex", "auth_index": "broken",
             "email": "third@example.test", "label": "third@example.test"},
        ]

        def account(provider, entry, client):
            if entry["auth_index"] == "broken":
                return MODULE.err("expired", "rejected")
            used = 90 if entry["auth_index"] == "full" else 20
            return {"status": "ok", "plan": "ChatGPT Plus",
                    "account": "private@example.test",
                    "windows": [{"label": "5 hour limit", "used": used}],
                    "credits": None}

        with mock.patch.object(MODULE, "fetch_cliproxy_account", side_effect=account):
            result = MODULE.fetch_cliproxy_provider("codex", entries, object())

        self.assertEqual(result["windows"][0]["used"], 20)
        self.assertEqual(result["source"], "cliproxy")
        self.assertEqual(result["accountCount"], 3)
        self.assertEqual(result["availableCount"], 2)
        self.assertEqual(result["plan"], "ChatGPT Plus")
        self.assertEqual(len(result["accounts"]), 3)
        self.assertEqual([account["status"] for account in result["accounts"]],
                         ["ok", "ok", "error"])
        self.assertEqual([account["label"] for account in result["accounts"]],
                         ["f•••@example.test", "s•••@example.test",
                          "t•••@example.test"])
        self.assertEqual(result["bestAccountId"], result["accounts"][1]["id"])
        self.assertNotIn("account", result)
        serialized = json.dumps(result)
        for private in ("private@example.test", "first@example.test",
                        "second@example.test", "third@example.test",
                        "full", "open", "broken"):
            self.assertNotIn(private, serialized)

    def test_account_pool_preserves_each_failure_when_all_accounts_fail(self):
        entries = [
            {"provider": "claude", "auth_index": "one",
             "email": "one@example.test"},
            {"provider": "claude", "auth_index": "two",
             "email": "two@example.test"},
        ]

        def account(provider, entry, client):
            kind = "expired" if entry["auth_index"] == "one" else "rate"
            return MODULE.err(kind, kind + " account")

        with mock.patch.object(MODULE, "fetch_cliproxy_account", side_effect=account):
            result = MODULE.fetch_cliproxy_provider("claude", entries, object())

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["kind"], "expired")
        self.assertEqual(result["source"], "cliproxy")
        self.assertEqual(result["accountCount"], 2)
        self.assertEqual(result["availableCount"], 0)
        self.assertEqual([account["kind"] for account in result["accounts"]],
                         ["expired", "rate"])

    def test_absent_provider_is_not_marked_as_managed_by_cliproxy(self):
        result = MODULE.fetch_cliproxy_provider("kimi", [{
            "provider": "codex", "auth_index": "codex-only",
        }], object())

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["kind"], "nocreds")
        self.assertNotIn("source", result)

    def test_custom_account_label_is_kept_but_email_labels_are_masked(self):
        self.assertEqual(MODULE.cliproxy_account_label({
            "email": "private@example.test", "label": "Work subscription",
        }, 0), "Work subscription")
        self.assertEqual(MODULE.cliproxy_account_label({
            "label": "private@example.test",
        }, 0), "p•••@example.test")
        self.assertEqual(MODULE.cliproxy_account_label({}, 1), "Account 2")

        readings = [{"label": "Shared"}, {"label": "Shared"},
                    {"label": "Personal"}]
        MODULE.disambiguate_cliproxy_labels(readings)
        self.assertEqual([reading["label"] for reading in readings],
                         ["Shared · 1", "Shared · 2", "Personal"])

    def test_xai_account_uses_only_the_two_read_only_billing_endpoints(self):
        calls = []

        class Client:
            def api_json(self, auth_index, url, headers):
                calls.append((auth_index, url, dict(headers)))
                if url == MODULE.XAI_BILLING_WEEKLY_URL:
                    return {"config": {
                        "currentPeriod": {"type": "weekly"},
                        "creditUsagePercent": 12,
                    }}, None
                return {"config": {
                    "monthlyLimit": {"val": 15_000},
                    "used": {"val": 3_000},
                }}, None

        result = MODULE.fetch_cliproxy_account(
            "xai", {"auth_index": "xai-9"}, Client())

        self.assertEqual(result["status"], "ok")
        self.assertEqual({call[1] for call in calls}, {
            MODULE.XAI_BILLING_WEEKLY_URL,
            MODULE.XAI_BILLING_MONTHLY_URL,
        })
        self.assertTrue(all(call[0] == "xai-9" for call in calls))
        self.assertTrue(all(call[2]["Authorization"] == "Bearer $TOKEN$"
                            for call in calls))
        self.assertTrue(all("chat/completions" not in call[1] for call in calls))


class CliProxyCredentialHelperTests(unittest.TestCase):
    def test_store_status_and_clear_keep_the_key_private_and_out_of_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "private" / "management.key"
            environment = dict(os.environ,
                QUICKSHELL_USAGE_CLIPROXY_KEY_PATH=str(path))
            secret = b"not-a-real-management-secret"
            stored = subprocess.run(
                [str(CREDENTIAL_PATH), "store"], input=secret,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                env=environment, check=False)
            self.assertEqual(stored.returncode, 0, stored.stderr)
            self.assertNotIn(secret, stored.stdout)
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            self.assertEqual(json.loads(stored.stdout),
                             {"success": True, "configured": True})

            cleared = subprocess.run(
                [str(CREDENTIAL_PATH), "clear"], stdout=subprocess.PIPE,
                stderr=subprocess.PIPE, env=environment, check=False)
            self.assertEqual(cleared.returncode, 0, cleared.stderr)
            self.assertFalse(path.exists())


class Sub2ApiTests(unittest.TestCase):
    def test_url_normalization_preserves_reverse_proxy_prefix(self):
        for suffix in ("", "/", "/admin/accounts", "/admin/dashboard",
                       "/api/v1", "/api/v1/admin"):
            self.assertEqual(MODULE.normalize_sub2api_url(
                "https://proxy.test/sub2api" + suffix), "https://proxy.test/sub2api")
        for url in ("", "file:///tmp/key", "https://user:secret@proxy.test",
                    "https://proxy.test?key=secret", "https://proxy.test/../admin"):
            with self.assertRaises(ValueError):
                MODULE.normalize_sub2api_url(url)

    def test_pagination_and_partial_inventory_failure(self):
        client = MODULE.Sub2ApiClient("https://proxy.test", "private")
        client.api_json = mock.Mock(side_effect=[
            ({"items": [{"id": 1}], "total": 2}, None),
            ({"items": [{"id": 2}], "total": 2}, None)])
        accounts, failure = client.accounts()
        self.assertIsNone(failure)
        self.assertEqual([row["id"] for row in accounts], [1, 2])
        self.assertIn("page=2", client.api_json.call_args.args[0])
        client.api_json = mock.Mock(side_effect=[
            ({"items": [{"id": 1}], "total": 2}, None),
            (None, MODULE.err("network"))])
        self.assertEqual(client.accounts(), (None, MODULE.err("network")))

    def test_quota_units_unknown_values_and_expired_windows(self):
        with mock.patch.object(MODULE.time, "time", return_value=1000):
            result = MODULE.parse_sub2api_usage({
                "five_hour": {"utilization": 25, "resets_at": "1970-01-01T01:00:00Z"},
                "seven_day": {"utilization": 150},
                "seven_day_sonnet": {"utilization": "NaN"},
                "seven_day_fable": {"utilization": True},
                "thirty_day": {"utilization": 80, "resets_at": "1970-01-01T00:01:00Z"},
                "gemini_pro_daily": {"utilization": 40},
                "antigravity_quota": {"gemini-flash": {"utilization": 12}},
                "grok_request_quota": {"limit": 100, "remaining": 75, "reset_unix": 2000},
            })
        self.assertEqual(result["status"], "ok")
        self.assertEqual([row["used"] for row in result["windows"]],
                         [25, 100, None, None, 40, 12, 25])
        self.assertEqual(result["windows"][0]["windowSecs"], MODULE.FIVE_HOURS)
        self.assertEqual(result["windows"][-1]["resetsAt"], 2000)
        self.assertEqual(MODULE.parse_sub2api_usage({})["kind"], "wait")
        self.assertEqual(MODULE.parse_sub2api_usage([])["kind"], "parse")

    def test_account_errors_do_not_expose_upstream_diagnostics(self):
        result = MODULE.parse_sub2api_usage({
            "error_code": "unauthenticated", "error": "secret-token",
            "five_hour": {"utilization": 10}})
        self.assertEqual(result["kind"], "expired")
        self.assertNotIn("secret-token", json.dumps(result))

    def test_codex_reads_saved_snapshot_without_an_inference_probe(self):
        client = mock.Mock()
        entries = [{"id": 1, "platform": "openai", "status": "active",
                    "name": "test@example.com", "credentials": {"token": "secret"},
                    "extra": {"codex_5h_used_percent": 30,
                              "codex_usage_updated_at": "1970-01-01T00:16:40Z",
                              "codex_5h_reset_after_seconds": 3600}}]
        with mock.patch.object(MODULE.time, "time", return_value=1000):
            result = MODULE.fetch_sub2api_provider("codex", entries, client)
        client.api_json.assert_not_called()
        self.assertEqual(result["source"], "sub2api")
        self.assertEqual(result["windows"][0]["resetsAt"], 4600)
        self.assertEqual(result["windows"][0]["used"], 30)
        self.assertEqual(result["accounts"][0]["label"], "t•••@example.com")
        self.assertNotIn("secret", json.dumps(result))
        self.assertNotIn("test@example.com", json.dumps(result))

    def test_best_account_summary_keeps_failures_and_excludes_disabled(self):
        client = mock.Mock()
        client.api_json.side_effect = [
            ({"five_hour": {"utilization": 75}}, None),
            (None, MODULE.err("expired", "Rejected")),
            ({"five_hour": {"utilization": 20}}, None)]
        entries = [{"id": n, "name": "Team", "platform": "anthropic",
                    "status": "disabled" if n == 4 else "active"}
                   for n in range(1, 5)]
        result = MODULE.fetch_sub2api_provider("claude", entries, client)
        self.assertEqual(result["accountCount"], 3)
        self.assertEqual(result["availableCount"], 2)
        self.assertEqual(result["windows"][0]["used"], 20)
        self.assertEqual(result["bestAccountId"], result["accounts"][2]["id"])
        self.assertEqual(result["accounts"][1]["kind"], "expired")
        self.assertEqual(result["accounts"][2]["label"], "Team · 3")
        absent = MODULE.fetch_sub2api_provider("gemini", entries, client)
        self.assertEqual(absent["kind"], "nocreds")
        self.assertNotIn("source", absent)

    def test_recent_account_drives_quota_and_follows_rotation(self):
        entries = [{"id": n, "platform": "openai", "name": "test@example.com",
                    "last_used_at": f"2026-01-0{n}T12:00:00Z",
                    "extra": {"codex_5h_used_percent": used}}
                   for n, used in [(1, 10), (2, 80)]]
        client = mock.Mock()
        result = MODULE.fetch_sub2api_provider("codex", entries, client)
        self.assertEqual(result["windows"][0]["used"], 80)
        self.assertEqual(result["selectedAccountId"], result["accounts"][1]["id"])
        self.assertEqual(result["bestAccountId"], result["accounts"][0]["id"])
        self.assertEqual(result["selectionReason"], "last-used")
        self.assertNotIn("test@example.com", json.dumps(result))
        entries[0]["last_used_at"] = "2026-01-03T12:00:00Z"
        rotated = MODULE.fetch_sub2api_provider("codex", entries, client)
        self.assertEqual(rotated["selectedAccountId"], result["accounts"][0]["id"])
        self.assertEqual(rotated["windows"][0]["used"], 10)
        client.api_json.assert_not_called()

    def test_missing_invalid_and_future_activity_falls_back_to_quota(self):
        for timestamp in [None, "invalid", True, 123, "9999-01-01T00:00:00Z",
                          "0001-01-01T00:00:00Z"]:
            with self.subTest(timestamp=timestamp):
                entries = [{"id": n, "platform": "openai", "last_used_at": timestamp,
                            "extra": {"codex_5h_used_percent": used}}
                           for n, used in [(1, 10), (2, 80)]]
                result = MODULE.fetch_sub2api_provider("codex", entries, mock.Mock())
                self.assertNotIn("selectedAccountId", result)
                self.assertEqual(result["windows"][0]["used"], 10)

    def test_recent_unavailable_account_is_not_replaced_by_cached_quota(self):
        entries = [{"id": 1, "platform": "openai",
                    "last_used_at": "2026-01-01T12:00:00Z",
                    "extra": {"codex_5h_used_percent": 10}},
                   {"id": 2, "platform": "openai", "extra": {}}]
        def fetch():
            return MODULE.fetch_sub2api_provider("codex", entries, mock.Mock())
        state = {}
        MODULE.fetch_all_resilient((("codex", fetch),), state, now=1000)
        entries[1]["last_used_at"] = "2026-01-02T12:00:00Z"
        result = MODULE.fetch_all_resilient((("codex", fetch),), state, now=1001)["codex"]
        self.assertEqual(result["status"], "error")
        self.assertEqual(result["selectedAccountId"], result["accounts"][1]["id"])
        self.assertEqual(result["availableCount"], 1)
        self.assertNotIn("windows", result)
        skipped = MODULE.fetch_all_resilient((("codex", fetch),), state, now=1002)["codex"]
        self.assertEqual(skipped["selectedAccountId"], result["selectedAccountId"])
        self.assertEqual(skipped["status"], "error")
        offline = MODULE.fetch_all_resilient(
            (("codex", lambda: MODULE.err("network")),), state, now=2000)["codex"]
        self.assertEqual(offline["status"], "error")
        self.assertNotIn("windows", offline)

    def test_activity_ties_are_stable_and_disabled_accounts_are_ignored(self):
        entries = [{"id": n, "platform": "openai",
                    "last_used_at": "2026-01-01T12:00:00Z",
                    "extra": {"codex_5h_used_percent": 20}}
                   for n in (1, 2)]
        result = MODULE.fetch_sub2api_provider("codex", entries, mock.Mock())
        reversed_result = MODULE.fetch_sub2api_provider("codex", entries[::-1], mock.Mock())
        self.assertEqual(result["selectedAccountId"], reversed_result["selectedAccountId"])
        entries.append({"id": 3, "platform": "openai", "status": "disabled",
                        "last_used_at": "2026-01-02T12:00:00Z"})
        filtered = MODULE.fetch_sub2api_provider("codex", entries, mock.Mock())
        self.assertEqual(filtered["accountCount"], 2)
        self.assertEqual(filtered["selectedAccountId"], result["selectedAccountId"])

    def test_connection_checks_inventory_without_reading_quotas_or_cache(self):
        with mock.patch.object(MODULE, "read_cliproxy_key", return_value=("private", None)), \
                mock.patch.object(MODULE.Sub2ApiClient, "accounts", return_value=([
                    {"platform": "openai", "status": "active"},
                    {"platform": "anthropic", "status": "disabled"},
                    {"platform": "unknown", "status": "active"}], None)), \
                mock.patch.object(MODULE, "load_state") as load, \
                mock.patch.object(MODULE, "save_state") as save, \
                mock.patch.object(MODULE.Sub2ApiClient, "api_json") as usage:
            result = MODULE.test_connection("sub2api", "https://proxy.test")
        self.assertTrue(result["success"])
        self.assertEqual(result["accountCount"], 1)
        self.assertIn("Admin access verified", result["message"])
        load.assert_not_called()
        save.assert_not_called()
        usage.assert_not_called()
        self.assertNotIn("private", json.dumps(result))

    def test_connection_reports_auth_failure_and_empty_inventory(self):
        with mock.patch.object(MODULE, "read_cliproxy_key", return_value=("private", None)), \
                mock.patch.object(MODULE.Sub2ApiClient, "accounts", side_effect=[
                    (None, MODULE.err("config", "Admin key rejected")), ([], None)]):
            rejected = MODULE.test_connection("sub2api", "https://proxy.test")
            empty = MODULE.test_connection("sub2api", "https://proxy.test")
        self.assertFalse(rejected["success"])
        self.assertEqual(rejected["message"], "Admin key rejected")
        self.assertTrue(empty["success"])
        self.assertEqual(empty["accountCount"], 0)
        self.assertIn("No supported enabled accounts", empty["message"])

    def test_connection_supports_cliproxy_and_invalid_urls(self):
        with mock.patch.object(MODULE, "read_cliproxy_key", return_value=("private", None)), \
                mock.patch.object(MODULE.CliProxyClient, "auth_files", return_value=([
                    {"provider": "codex"}, {"provider": "xai", "disabled": True}], None)):
            result = MODULE.test_connection("cliproxy", "https://proxy.test")
            invalid = MODULE.test_connection("sub2api", "not-a-url")
        self.assertTrue(result["success"])
        self.assertEqual(result["accountCount"], 1)
        self.assertFalse(invalid["success"])
        self.assertEqual(invalid["kind"], "config")

    def test_private_key_errors_stay_visible_and_fingerprints_change(self):
        with mock.patch.object(MODULE, "read_cliproxy_key", return_value=(None, MODULE.err(
                "config", "CLIProxyAPI management key is not configured."))):
            providers, first = MODULE.make_sub2api_providers("https://one.test", True)
            _, second = MODULE.make_sub2api_providers("https://two.test", True)
        result = MODULE.fetch_all(providers)
        self.assertNotEqual(first, second)
        self.assertTrue(all(row["source"] == "sub2api" for row in result.values()))
        self.assertIn("Sub2API admin API key", result["claude"]["message"])

    def test_http_admin_auth_envelope_rate_limit_and_redirect_safety(self):
        requests = []

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                requests.append((self.path, self.headers.get("x-api-key")))
                if self.path.endswith("/redirect"):
                    self.send_response(302)
                    self.send_header("Location", "/leaked-key")
                    self.end_headers()
                    return
                if self.path.endswith("/rate"):
                    self.send_response(429)
                    self.send_header("Retry-After", "120")
                    self.end_headers()
                    return
                if self.path.endswith("/auth"):
                    self.send_response(401)
                    self.end_headers()
                    return
                self.send_response(200)
                self.end_headers()
                self.wfile.write(json.dumps({"code": 0, "data": {"ok": True}}).encode())

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        worker = threading.Thread(target=server.serve_forever)
        worker.start()
        try:
            client = MODULE.Sub2ApiClient(f"http://127.0.0.1:{server.server_port}/prefix", "private")
            self.assertEqual(client.api_json("/success"), ({"ok": True}, None))
            self.assertEqual(client.api_json("/redirect")[1]["kind"], "http")
            self.assertEqual(client.api_json("/rate")[1]["retryAfter"], 120)
            self.assertEqual(client.api_json("/auth")[1]["kind"], "config")
        finally:
            server.shutdown()
            server.server_close()
            worker.join()
        self.assertEqual(len(requests), 4)
        self.assertTrue(all(path.startswith("/prefix/api/v1/admin/") and key == "private"
                            for path, key in requests))

    def test_sub2api_key_storage_is_separate_and_newline_does_not_wait_for_eof(self):
        with tempfile.TemporaryDirectory(prefix="cybexos-sub2api-test-") as temporary:
            environment = dict(os.environ, XDG_STATE_HOME=temporary)
            process = subprocess.Popen([str(CREDENTIAL_PATH), "store", "--source", "sub2api"],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                env=environment)
            try:
                process.stdin.write(b"sub2api-test-key\n")
                process.stdin.flush()
                process.wait(timeout=3)
                self.assertEqual(process.returncode, 0)
                self.assertNotIn(b"sub2api-test-key", process.stdout.read())
            finally:
                if process.poll() is None:
                    process.kill()
                process.communicate()
            key = Path(temporary) / "quickshell/model-usage-sub2api.key"
            self.assertEqual(stat.S_IMODE(key.stat().st_mode), 0o600)
            self.assertEqual(MODULE.read_cliproxy_key(str(key)), ("sub2api-test-key", None))
            self.assertFalse((key.parent / "model-usage-cliproxy.key").exists())


class ResilientFetchTests(unittest.TestCase):
    @staticmethod
    def reading(reset=10_000):
        return {
            "status": "ok",
            "plan": "Test Pro",
            "windows": [{"label": "5 hour limit", "used": 25,
                         "resetsAt": reset}],
            "credits": None,
        }

    def test_success_is_cached_and_claude_observes_five_minute_floor(self):
        state = MODULE.empty_state()
        calls = 0

        def fetch():
            nonlocal calls
            calls += 1
            return self.reading()

        first = MODULE.fetch_all_resilient(
            (("claude", fetch),), state, now=1_000,
            min_intervals={"claude": 300})
        second = MODULE.fetch_all_resilient(
            (("claude", fetch),), state, now=1_100,
            min_intervals={"claude": 300})

        self.assertEqual(calls, 1)
        self.assertFalse(first["claude"]["stale"])
        self.assertFalse(second["claude"]["stale"])
        self.assertEqual(second["claude"]["observedAt"], 1_000)

    def test_failure_retains_last_good_and_honors_retry_after(self):
        state = MODULE.empty_state()
        MODULE.fetch_all_resilient(
            (("claude", lambda: self.reading()),), state, now=1_000,
            min_intervals={"claude": 300})
        calls = 0

        def limited():
            nonlocal calls
            calls += 1
            return MODULE.err("rate", "limited", retryAfter=600)

        failed = MODULE.fetch_all_resilient(
            (("claude", limited),), state, now=1_301,
            min_intervals={"claude": 300})
        backed_off = MODULE.fetch_all_resilient(
            (("claude", limited),), state, now=1_500,
            min_intervals={"claude": 300})

        self.assertEqual(calls, 1)
        self.assertEqual(failed["claude"]["status"], "ok")
        self.assertTrue(failed["claude"]["stale"])
        self.assertEqual(failed["claude"]["staleKind"], "rate")
        self.assertEqual(failed["claude"]["retryAt"], 1_901)
        self.assertEqual(backed_off["claude"]["retryAt"], 1_901)

    def test_stale_windows_are_removed_after_their_reset(self):
        entry = {
            "observedAt": 1_000,
            "lastOk": {
                "status": "ok",
                "windows": [
                    {"label": "old", "used": 99, "resetsAt": 1_100},
                    {"label": "current", "used": 20, "resetsAt": 2_000},
                ],
                "credits": None,
            },
        }
        failure = MODULE.err("network", "offline")
        cached = MODULE.cached_provider(entry, 1_200, failure, 1_500)
        self.assertEqual([window["label"] for window in cached["windows"]],
                         ["current"])

        entry["lastOk"]["windows"][1]["resetsAt"] = 1_150
        self.assertIsNone(MODULE.cached_provider(entry, 1_200, failure, 1_500))

    def test_cached_pool_marks_accounts_stale_and_prunes_their_windows(self):
        entry = {
            "observedAt": 1_000,
            "lastOk": {
                "status": "ok",
                "windows": [{"label": "summary", "used": 20,
                             "resetsAt": 2_000}],
                "credits": None,
                "accounts": [{
                    "id": "account-safe", "label": "p•••@example.test",
                    "status": "ok", "windows": [
                        {"label": "old", "used": 90, "resetsAt": 1_100},
                        {"label": "current", "used": 25,
                         "resetsAt": 2_000},
                    ],
                    "credits": None,
                }],
            },
        }
        failure = MODULE.err("network", "offline")

        cached = MODULE.cached_provider(entry, 1_200, failure, 1_500)

        account = cached["accounts"][0]
        self.assertEqual([window["label"] for window in account["windows"]],
                         ["current"])
        self.assertTrue(account["stale"])
        self.assertEqual(account["staleKind"], "network")
        self.assertEqual(account["observedAt"], 1_000)

    def test_retry_after_supports_seconds_and_http_dates(self):
        self.assertEqual(MODULE.retry_after_seconds({"Retry-After": "12"}, 1_000), 12)
        self.assertEqual(MODULE.retry_after_seconds(
            {"Retry-After": "Thu, 01 Jan 1970 00:17:00 GMT"}, 1_000), 20)
        self.assertEqual(MODULE.backoff_seconds(1, 300, {}), 300)
        self.assertEqual(MODULE.backoff_seconds(2, 0, {}), 120)
        self.assertEqual(MODULE.backoff_seconds(20, 0, {}), 900)

    def test_state_cache_is_private(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "nested" / "state.json"
            MODULE.save_state(str(path), MODULE.empty_state())
            self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o600)
            self.assertEqual(MODULE.load_state(str(path)), MODULE.empty_state())


if __name__ == "__main__":
    unittest.main()
