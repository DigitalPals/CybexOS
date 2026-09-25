#!/usr/bin/env python3
"""Match Keeper's last recorded requests to current CLIProxyAPI accounts.

Only account hashes and timestamps leave this process. Never consume CPA's
usage queue, fetch request contents, or run upstream quota calls here.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import re
import sys
import time
from datetime import datetime
from pathlib import Path

import keeper_client as keeper

SPEC = importlib.util.spec_from_file_location("activity_usage", Path(__file__).with_name("usage-fetch.py"))
assert SPEC and SPEC.loader
usage = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = usage
SPEC.loader.exec_module(usage)


def normalize_activity(entries, document, now=None):
    now = time.time() if now is None else now
    rows = document.get("identities") if isinstance(document, dict) else None
    if not isinstance(rows, list) or len(rows) > 4096:
        raise keeper.KeeperError("Keeper returned invalid account activity.")
    accounts = {}
    for entry in entries:
        provider = str(entry.get("provider") or entry.get("type") or "").lower()
        index = entry.get("auth_index") or entry.get("authIndex")
        if not re.fullmatch(r"[a-z0-9][a-z0-9_-]{0,63}", provider) or not isinstance(index, str) or not index:
            continue
        key = (provider, index)
        account_id = usage.cliproxy_account_record(provider, entry)["accountId"]
        if key in accounts and accounts[key] != account_id:
            raise keeper.KeeperError("Proxy account identifiers are ambiguous.")
        accounts[key] = account_id

    latest = {}
    for row in rows:
        if not isinstance(row, dict) or row.get("is_deleted") is True or row.get("auth_type") != 1:
            continue
        provider, index = row.get("provider"), row.get("identity")
        if not isinstance(provider, str) or not isinstance(index, str):
            continue
        provider = provider.lower()
        account_id = accounts.get((provider, index))
        if not account_id or row.get("last_used_at") is None:
            continue
        try:
            value = row["last_used_at"]
            if not isinstance(value, str) or len(value) > 64:
                raise ValueError
            value = re.sub(r"(\.\d{6})\d+(?=[+-]\d{2}:\d{2}$)", r"\1", value.replace("Z", "+00:00"))
            stamp = datetime.fromisoformat(value)
            if stamp.tzinfo is None or not 0 < stamp.timestamp() <= now + 60:
                raise ValueError
            timestamp = stamp.timestamp()
        except (ValueError, TypeError, OverflowError):
            raise keeper.KeeperError("Keeper returned an invalid last-request timestamp.") from None
        previous = latest.get(provider)
        if previous is None or timestamp > previous[0]:
            latest[provider] = (timestamp, {account_id})
        elif timestamp == previous[0]:
            previous[1].add(account_id)

    return [{"id": provider, "status": "ok" if len(ids) == 1 else "ambiguous",
             "accountId": next(iter(ids)) if len(ids) == 1 else "",
             "lastUsedAt": timestamp}
            for provider, (timestamp, ids) in sorted(latest.items())]


def collect(proxy_url, proxy_key_file, keeper_url, password_file, timeout):
    client = keeper.Client(keeper_url, timeout)
    proxy = usage.CliProxyClient(proxy_url, usage.read_cliproxy_key(proxy_key_file))
    entries = proxy.auth_files(max(0.1, client.deadline - time.monotonic()))
    logged_in = False
    try:
        if password_file:
            client.request("auth/login", {"password": keeper.read_password(password_file)}, limit=64 * 1024)
            logged_in = True
        status = client.request("status", limit=64 * 1024)
        if not isinstance(status, dict) or status.get("running") is not True:
            raise keeper.KeeperError("Keeper is not collecting requests; last-used account tracking is unavailable.")
        document = client.request("usage/identities", limit=2 * 1024 * 1024)
        return normalize_activity(entries, document)
    finally:
        if logged_in:
            client.deadline = time.monotonic() + 1
            try:
                client.request("auth/logout", {}, limit=64 * 1024)
            except keeper.KeeperError:
                pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cliproxy-url", required=True)
    parser.add_argument("--cliproxy-key-file", type=Path)
    parser.add_argument("--keeper-url", required=True)
    parser.add_argument("--keeper-password-file", type=Path)
    parser.add_argument("--timeout", type=float, default=10)
    args = parser.parse_args()
    payload = {"schemaVersion": 1, "providers": [], "error": ""}
    try:
        payload["providers"] = collect(args.cliproxy_url, args.cliproxy_key_file or usage.cliproxy_key_path(),
                                       args.keeper_url, args.keeper_password_file, max(1, min(12, args.timeout)))
    except usage.ProviderFailure as exc:
        payload["error"] = exc.message
    except keeper.KeeperError as exc:
        payload["error"] = str(exc)
    except Exception:
        payload["error"] = "Could not read last-used account activity."
    print(json.dumps(payload, allow_nan=False))


if __name__ == "__main__":
    main()
