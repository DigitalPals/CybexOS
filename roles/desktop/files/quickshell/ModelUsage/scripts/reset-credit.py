#!/usr/bin/env python3
"""Explicit CLIProxyAPI reset actions; never invoked by quota polling."""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import re
import sys
import time
import uuid
from datetime import datetime
from pathlib import Path

SPEC = importlib.util.spec_from_file_location("reset_usage", Path(__file__).with_name("usage-fetch.py"))
assert SPEC and SPEC.loader
usage = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = usage
SPEC.loader.exec_module(usage)

RESET_URL = "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits"


def identifier(value):
    return isinstance(value, str) and 0 < len(value) <= 512 and not any(ord(c) < 33 or ord(c) == 127 for c in value)


def count(value):
    parsed = usage.number(value)
    return int(parsed) if parsed is not None and parsed >= 0 and parsed == int(parsed) else None


def timestamp(value):
    if not isinstance(value, str):
        raise ValueError("Invalid timestamp")
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError("Missing timezone")
    return parsed.timestamp()


def normalize_details(payload, now=None):
    now = time.time() if now is None else now
    if not isinstance(payload, dict) or not isinstance(payload.get("credits"), list):
        raise usage.ProviderFailure("malformed", "Reset details are unavailable. Refresh and try again.")
    available = count(payload.get("available_count"))
    if available is None or len(payload["credits"]) > 1024:
        raise usage.ProviderFailure("malformed", "The server returned invalid reset details.")
    credits = []
    seen = set()
    for credit in payload["credits"]:
        if not isinstance(credit, dict) or credit.get("status") != "available" or credit.get("reset_type") != "codex_rate_limits":
            continue
        credit_id = credit.get("id")
        if not identifier(credit_id) or credit_id in seen:
            raise usage.ProviderFailure("malformed", "The server returned invalid reset identifiers.")
        seen.add(credit_id)
        try:
            expiry = None if credit.get("expires_at") is None else timestamp(credit["expires_at"])
            granted = timestamp(credit["granted_at"])
        except (ValueError, TypeError, KeyError, OverflowError):
            raise usage.ProviderFailure("malformed", "The server returned invalid reset dates.") from None
        if expiry is not None and expiry <= now:
            continue
        credits.append({"id": credit_id, "expiresAt": expiry, "grantedAt": granted,
                        "title": usage.clean_message(credit.get("title") or "Full reset"),
                        "description": usage.clean_message(credit.get("description") or "Reset your current Codex usage limits.")})
    credits.sort(key=lambda c: (c["expiresAt"] if c["expiresAt"] is not None else float("inf"), c["grantedAt"], c["id"]))
    return {"availableCount": available, "applicableAvailableCount": count(payload.get("applicable_available_count")),
            "credits": credits if available > 0 else []}


def resolve_account(client, account_id, remaining):
    if not isinstance(account_id, str) or not re.fullmatch(r"[0-9a-f]{16}", account_id):
        raise usage.ProviderFailure("config", "Invalid reset account.")
    matches = [entry for entry in client.auth_files(remaining())
               if str(entry.get("provider") or entry.get("type") or "").lower() == "codex"
               and usage.cliproxy_account_record("codex", entry)["accountId"] == account_id]
    if len(matches) != 1:
        raise usage.ProviderFailure("config", "This account changed or is unavailable. Refresh its usage first.")
    entry = matches[0]
    if entry.get("disabled") is True or entry.get("status") == "disabled":
        raise usage.ProviderFailure("config", "This account is paused in CLIProxyAPI.")
    claims = entry.get("id_token") if isinstance(entry.get("id_token"), dict) else {}
    chatgpt_id = entry.get("chatgpt_account_id") or claims.get("chatgpt_account_id")
    index = entry.get("auth_index") or entry.get("authIndex")
    if not identifier(chatgpt_id) or not identifier(index):
        raise usage.ProviderFailure("config", "The managed account is missing its sign-in identifiers.")
    target = hashlib.sha256(json.dumps([account_id, index, chatgpt_id]).encode()).hexdigest()
    headers = {"ChatGPT-Account-Id": chatgpt_id, "User-Agent": "codex-cli",
               "OpenAI-Beta": "codex-1", "Content-Type": "application/json"}
    return entry, target, headers


def execute(client, action, account_id, target="", credit_id="", request_id="", timeout=12):
    deadline = time.monotonic() + timeout

    def remaining():
        seconds = deadline - time.monotonic()
        if seconds <= 0:
            raise usage.ProviderFailure("timeout", "The reset request timed out.")
        return seconds

    entry, current_target, headers = resolve_account(client, account_id, remaining)
    if action == "prepare":
        details = normalize_details(client.usage(entry, RESET_URL, headers, remaining()))
        return dict(details, target=current_target, requestId=str(uuid.uuid4()))
    if action != "consume" or target != current_target or not identifier(credit_id):
        raise usage.ProviderFailure("config", "The selected account changed. Open a new reset confirmation.")
    try:
        if str(uuid.UUID(request_id)) != request_id:
            raise ValueError()
    except (ValueError, TypeError, AttributeError):
        raise usage.ProviderFailure("config", "Invalid reset request identifier.") from None
    try:
        payload = client.usage(entry, RESET_URL + "/consume", headers, remaining(),
                              data={"credit_id": credit_id, "redeem_request_id": request_id})
    except usage.ProviderFailure as error:
        error.submitted = True
        raise
    outcome = payload.get("code") if isinstance(payload, dict) else None
    if outcome not in ("reset", "nothing_to_reset", "no_credit", "already_redeemed"):
        error = usage.ProviderFailure("malformed", "The server did not confirm the reset outcome.")
        error.submitted = True
        raise error
    return {"outcome": outcome}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--action", required=True, choices=("prepare", "consume"))
    parser.add_argument("--account-id", required=True)
    parser.add_argument("--cliproxy-url", required=True)
    parser.add_argument("--cliproxy-key-file", type=lambda p: Path(p).expanduser())
    parser.add_argument("--target", default="")
    parser.add_argument("--credit-id", default="")
    parser.add_argument("--request-id", default="")
    args = parser.parse_args()
    try:
        client = usage.CliProxyClient(args.cliproxy_url, usage.read_cliproxy_key(args.cliproxy_key_file or usage.cliproxy_key_path()))
        result = execute(client, args.action, args.account_id, args.target, args.credit_id, args.request_id)
        result.update(ok=True, schemaVersion=1)
    except usage.ProviderFailure as error:
        result = {"schemaVersion": 1, "ok": False, "message": error.message,
                  "uncertain": getattr(error, "submitted", False)}
    except Exception:
        result = {"schemaVersion": 1, "ok": False, "message": "Could not complete the reset request.",
                  "uncertain": args.action == "consume"}
    print(json.dumps(result))


if __name__ == "__main__":
    main()
