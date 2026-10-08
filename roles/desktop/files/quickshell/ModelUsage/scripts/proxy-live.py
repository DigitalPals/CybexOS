#!/usr/bin/env python3
"""One bounded Fusebox observer. Emit only account hashes and activity counts.

Inventory reads use Fusebox's cache; this collector never requests provider
quota refreshes. Request bodies, identities and credentials stay out of stdout.
"""
from __future__ import annotations

import argparse
import json
import time
from pathlib import Path
from urllib.parse import urlsplit, urlunsplit

import importlib.util

SPEC = importlib.util.spec_from_file_location("proxy_activity", Path(__file__).with_name("proxy-activity.py"))
assert SPEC and SPEC.loader
activity = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(activity)
usage = activity.usage

MAX_FRAME = 512 * 1024
INVENTORY_INTERVAL = 15
IDLE_INVENTORY_INTERVAL = 60
STALE_SECONDS = 15


def websocket_url(base):
    parts = urlsplit(usage.normalize_cliproxy_url(base))
    return urlunsplit(("wss" if parts.scheme == "https" else "ws", parts.netloc,
                      parts.path + "/api/live", "", ""))


class Tracker:
    def __init__(self):
        self.entries = []
        self.identities = {}
        self.load = None
        self.state = "reconnecting"
        self.message = "Connecting to live account activity…"
        self.last_payload = None

    def inventory(self, entries):
        identities = {}
        for entry in entries:
            native = entry["_native_id"]
            if native in identities:
                raise ValueError("ambiguous inventory")
            identities[native] = (entry["provider"], usage.cliproxy_account_record(entry["provider"], entry)["accountId"])
        self.entries, self.identities = entries, identities

    def accept_load(self, data):
        if not isinstance(data, dict) or len(data) > 4096:
            raise ValueError("invalid load")
        clean = {}
        for identity, counts in data.items():
            if not isinstance(identity, str) or len(identity) > 512 or not isinstance(counts, dict):
                raise ValueError("invalid load")
            values = [counts.get("in_flight"), counts.get("sessions")]
            if any(type(value) is not int or not 0 <= value <= 1000000 for value in values):
                raise ValueError("invalid count")
            clean[identity] = values
        self.load = clean
        self.state, self.message = "live", "Live account activity"
        return any(identity not in self.identities for identity in clean)

    def disconnect(self, state="reconnecting", message="Reconnecting to live account activity…"):
        self.load = None
        self.state, self.message = state, message

    def payload(self):
        accounts = []
        if self.state == "live" and self.load is not None:
            for native, (provider, account_id) in self.identities.items():
                requests, sessions = self.load.get(native, [0, 0])
                accounts.append({"provider": provider, "accountId": account_id,
                                 "inFlight": requests, "sessions": sessions})
        return {"schemaVersion": 1, "state": self.state, "message": self.message,
                "providers": activity.normalize_rust_activity(self.entries), "accounts": accounts}

    def publish(self):
        payload = self.payload()
        if payload != self.last_payload:
            print(json.dumps(payload, allow_nan=False, separators=(",", ":")), flush=True)
            self.last_payload = payload


def heartbeat():
    print('{"schemaVersion":1,"heartbeat":true}', flush=True)


def observe(args, connect):
    tracker = Tracker()
    delay = 2
    while True:
        tracker.publish()
        started = time.monotonic()
        unsupported = False
        try:
            key = usage.read_cliproxy_key(args.cliproxy_key_file or usage.cliproxy_key_path())
            proxy = usage.CliProxyClient(args.cliproxy_url, key)
            tracker.inventory(proxy.rust_accounts(8))
            tracker.publish()
            inventory_at = time.monotonic()
            if connect is None:
                unsupported = True
                raise RuntimeError("dependency")
            # Credentials are sent only in the upgrade header, never the URL.
            with connect(websocket_url(proxy.base_url), additional_headers={"Authorization": "Bearer " + key},
                         open_timeout=8, close_timeout=1, max_size=MAX_FRAME, max_queue=4,
                         ping_interval=None, proxy=None) as socket:
                heard_at = time.monotonic()
                heartbeat_at = heard_at
                snapshot_deadline = heard_at + STALE_SECONDS
                dirty = False
                while True:
                    now = time.monotonic()
                    if now - heard_at >= STALE_SECONDS:
                        raise TimeoutError("stale")
                    if tracker.load is None and now >= snapshot_deadline:
                        raise TimeoutError("missing snapshot")
                    if now - inventory_at >= (INVENTORY_INTERVAL if dirty else IDLE_INVENTORY_INTERVAL):
                        tracker.inventory(proxy.rust_accounts(8))
                        inventory_at = time.monotonic()
                        dirty = False
                        tracker.publish()
                    try:
                        raw = socket.recv(timeout=1)
                    except TimeoutError:
                        continue
                    if not isinstance(raw, str) or len(raw) > MAX_FRAME:
                        raise ValueError("invalid frame")
                    document = json.loads(raw)
                    if not isinstance(document, dict):
                        raise ValueError("invalid event")
                    kind = document.get("type")
                    if kind not in ("tick", "load", "request", "accounts"):
                        continue
                    heard_at = time.monotonic()
                    if kind == "load":
                        dirty = tracker.accept_load(document.get("data")) or dirty
                        tracker.publish()
                    elif kind in ("request", "accounts"):
                        dirty = True
                    if heard_at - heartbeat_at >= 5:
                        heartbeat()
                        heartbeat_at = heard_at
        except Exception as exc:
            # Never include exception text: libraries may embed headers or URLs.
            response = getattr(exc, "response", None)
            status = getattr(response, "status_code", None)
            unsupported = unsupported or status in (404, 405)
            tracker.disconnect("unavailable" if unsupported else "reconnecting",
                               "Live activity unavailable; last-used activity remains available."
                               if unsupported else "Reconnecting to live account activity…")
            tracker.publish()
        if time.monotonic() - started >= 30:
            delay = 2
        pause = max(60 if unsupported else 2, delay)
        deadline = time.monotonic() + pause
        while time.monotonic() < deadline:
            heartbeat()
            time.sleep(min(5, max(0, deadline - time.monotonic())))
        delay = min(60, delay * 2)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cliproxy-url", required=True)
    parser.add_argument("--cliproxy-key-file", type=Path)
    args = parser.parse_args()
    try:
        from websockets.sync.client import connect
    except ImportError:
        connect = None
    observe(args, connect)


if __name__ == "__main__":
    main()
