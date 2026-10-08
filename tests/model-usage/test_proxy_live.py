from __future__ import annotations

import importlib.util
import json
import os
import select
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from types import SimpleNamespace
from unittest import mock
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
SPEC = importlib.util.spec_from_file_location("proxy_live", ROOT / "scripts/proxy-live.py")
live = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(live)


def entry(native, provider="codex"):
    return {"id": native.removeprefix("file:"), "_native_id": native,
            "provider": provider, "kind": "oauth", "disabled": False, "_rust": True}


class LiveNormalization(unittest.TestCase):
    def test_complete_snapshot_multi_account_idle_and_disconnect(self):
        tracker = live.Tracker()
        tracker.inventory([entry("file:private-a.json"), entry("file:private-b.json"),
                           entry("file:private-c.json", "claude")])
        self.assertEqual(tracker.payload()["accounts"], [])
        tracker.accept_load({"file:private-a.json": {"in_flight": 2, "sessions": 3},
                             "file:private-b.json": {"in_flight": 1, "sessions": 1}})
        payload = tracker.payload()
        self.assertEqual([row["inFlight"] for row in payload["accounts"]], [2, 1, 0])
        self.assertNotIn("private", json.dumps(payload))
        tracker.accept_load({})
        self.assertEqual([row["inFlight"] for row in tracker.payload()["accounts"]], [0, 0, 0])
        tracker.disconnect()
        self.assertEqual(tracker.payload()["accounts"], [])
        self.assertEqual(tracker.payload()["state"], "reconnecting")

    def test_unknown_and_removed_accounts_never_invent_identity(self):
        tracker = live.Tracker()
        tracker.inventory([entry("file:a.json")])
        self.assertTrue(tracker.accept_load({"file:new.json": {"in_flight": 2, "sessions": 1}}))
        tracker.inventory([entry("file:new.json")])
        self.assertEqual(len(tracker.payload()["accounts"]), 1)
        self.assertEqual(tracker.payload()["accounts"][0]["inFlight"], 2)

    def test_invalid_and_oversized_counts(self):
        for data in ([], {"a": {}}, {"a": {"in_flight": True, "sessions": 0}},
                     {"a": {"in_flight": -1, "sessions": 0}},
                     {"a": {"in_flight": 0, "sessions": 1000001}},
                     {str(i): {} for i in range(4097)}):
            with self.assertRaises(ValueError):
                live.Tracker().accept_load(data)

    def test_websocket_url_keeps_base_path_and_no_secrets(self):
        self.assertEqual(live.websocket_url("https://proxy.example/prefix/"),
                         "wss://proxy.example/prefix/api/live")


class LiveTransport(unittest.TestCase):
    def test_no_initial_snapshot_times_out_even_with_ticks_and_backs_off(self):
        class Done(BaseException):
            pass
        clock = [0.0]
        pauses = []
        connections = [0]
        def sleep(seconds):
            pauses.append(seconds)
            clock[0] += seconds
        class Socket:
            def __enter__(self): return self
            def __exit__(self, *_args): pass
            def recv(self, **_kwargs):
                clock[0] += 1
                return '{"type":"tick"}'
        def connect(*_args, **_kwargs):
            connections[0] += 1
            if connections[0] > 3: raise Done()
            return Socket()
        states = []
        with mock.patch.object(live.time, "monotonic", side_effect=lambda: clock[0]), \
                mock.patch.object(live.time, "sleep", side_effect=sleep), \
                mock.patch.object(live.usage, "read_cliproxy_key", return_value="key"), \
                mock.patch.object(live.usage.CliProxyClient, "rust_accounts", return_value=[entry("file:a.json")]), \
                mock.patch.object(live.Tracker, "publish", lambda tracker: states.append(tracker.payload())), \
                mock.patch.object(live, "heartbeat"):
            with self.assertRaises(Done):
                live.observe(SimpleNamespace(cliproxy_url="https://proxy.example", cliproxy_key_file=Path("key")), connect)
        self.assertEqual(pauses, [2, 4, 5, 3])  # delays 2, 4, 8 split into heartbeats
        self.assertTrue(all(state["state"] == "reconnecting" and not state["accounts"] for state in states))

    def test_real_upgrade_auth_events_and_disconnect(self):
        try:
            from websockets.sync.server import serve
            from websockets.http11 import Response
            from websockets.datastructures import Headers
        except ImportError:
            self.skipTest("optional websockets dependency")
        requests = []
        raw_accounts = [dict(entry("file:secret-account.json"), id="file:secret-account.json",
                             file="secret-account.json", last_used=None)]

        def route(connection, request):
            requests.append((request.path, request.headers.get("Authorization")))
            if request.path == "/api/accounts":
                body = json.dumps(raw_accounts).encode()
                return Response(200, "OK", Headers({"Content-Type": "application/json",
                                                     "Content-Length": str(len(body)), "Connection": "close"}), body)

        def handler(socket):
            socket.send(json.dumps({"type": "load", "data": {"file:secret-account.json":
                         {"in_flight": 2, "sessions": 4}}}))
            socket.send(json.dumps({"type": "request", "data": {"prompt": "private request", "email": "private@example.com"}}))
            time.sleep(0.15)
            socket.send('{"type":"load","data":{}}')
            time.sleep(0.15)

        with serve(handler, "127.0.0.1", 0, process_request=route) as server:
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            with tempfile.TemporaryDirectory() as temporary:
                key = Path(temporary) / "key"
                key.write_text("synthetic-key\n")
                key.chmod(0o600)
                port = server.socket.getsockname()[1]
                process = subprocess.Popen([sys.executable, "-u", str(ROOT / "scripts/proxy-live.py"),
                    "--cliproxy-url", f"http://127.0.0.1:{port}", "--cliproxy-key-file", str(key)],
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"})
                documents, body = [], b""
                try:
                    deadline = time.monotonic() + 8
                    while time.monotonic() < deadline:
                        if select.select([process.stdout], [], [], 0.2)[0]:
                            body += os.read(process.stdout.fileno(), 65536)
                            while b"\n" in body:
                                line, body = body.split(b"\n", 1)
                                documents.append(json.loads(line))
                        states = [d for d in documents if "state" in d]
                        if len(states) >= 4 and states[-1]["state"] == "reconnecting":
                            break
                    states = [d for d in documents if "state" in d]
                    counts = [d["accounts"][0]["inFlight"] for d in states if d["state"] == "live"]
                    self.assertEqual(counts, [2, 0])
                    self.assertEqual(states[-1]["accounts"], [])
                    output = json.dumps(documents)
                    for secret in ("secret-account", "private request", "private@example.com", "synthetic-key"):
                        self.assertNotIn(secret, output)
                    self.assertEqual(requests, [("/api/accounts", "Bearer synthetic-key"),
                                                ("/api/live", "Bearer synthetic-key")])
                finally:
                    process.terminate()
                    process.communicate(timeout=3)
            server.shutdown()
            thread.join(timeout=3)


if __name__ == "__main__":
    unittest.main()
