#!/usr/bin/env python3
"""Focused HTTP security fixture for remote Hermes WebUI authentication."""

from __future__ import annotations

import asyncio
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
import io
import json
import logging
from pathlib import Path
import sys
import tempfile
import threading
import time
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
BRIDGE_PATH = ROOT / "roles/desktop/files/hermes-menubar-bridge/hermes_bridge.py"
sys.path.insert(0, str(BRIDGE_PATH.parent))
SPEC = importlib.util.spec_from_file_location("hermes_remote_auth_fixture", BRIDGE_PATH)
assert SPEC and SPEC.loader
BRIDGE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = BRIDGE
SPEC.loader.exec_module(BRIDGE)


class Fixture:
    password = "correct horse battery staple"
    cookie_value = "issued-session-token.signature"

    def __init__(self) -> None:
        self.mode = "normal"
        self.logout_cookie = ""
        self.cross_origin = ""
        self.cross_requests = 0
        # A held request parks on ``slow_release`` so a scenario can observe
        # the bridge while one remote call is still in flight.
        self.slow_entered = threading.Event()
        self.slow_release = threading.Event()
        self.slow_status = 200
        self.optional_release = threading.Event()
        self.optional_release.set()
        self.optional_entered = threading.Event()
        self.request_counts: dict[str, int] = {}
        self.request_lock = threading.Lock()
        self.model = "fixture-model"
        self.reasoning_effort = "high"

    def optional(self, path: str) -> None:
        with self.request_lock:
            self.request_counts[path] = self.request_counts.get(path, 0) + 1
        self.optional_entered.set()
        assert self.optional_release.wait(timeout=10), "fixture endpoint was not released"

    @staticmethod
    def has_session(handler: BaseHTTPRequestHandler) -> bool:
        return (
            f"hermes_session={Fixture.cookie_value}"
            in handler.headers.get("Cookie", "")
        )


FIXTURE = Fixture()


class HermesHandler(BaseHTTPRequestHandler):
    server_version = "HermesWebUIFixture/exp-v0.52.264"

    def log_message(self, _format: str, *_args: Any) -> None:
        return

    def reply(
        self,
        status: int,
        body: bytes,
        content_type: str,
        headers: dict[str, str] | None = None,
    ) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(body)

    def json_reply(
        self,
        value: dict[str, Any],
        status: int = 200,
        headers: dict[str, str] | None = None,
    ) -> None:
        self.reply(
            status,
            json.dumps(value, separators=(",", ":")).encode(),
            "application/json",
            headers,
        )

    def auth_status(self) -> None:
        self.json_reply(
            {
                "auth_enabled": True,
                "logged_in": FIXTURE.mode != "expired-auth" and FIXTURE.has_session(self),
                "password_auth_enabled": True,
                "oidc_enabled": False,
            }
        )

    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        if self.path in {
            "/api/models", "/api/reasoning", "/api/sessions/gateway/stream?probe=1",
            "/api/sessions?exclude_hidden=1",
        }:
            model = FIXTURE.model
            effort = FIXTURE.reasoning_effort
            FIXTURE.optional(self.path)
            if self.path == "/api/models":
                return self.json_reply({
                    "active_provider": "fixture", "default_model": model,
                    "groups": [{"provider_id": "fixture", "provider": "Fixture",
                                "models": [{"id": model, "name": model}]}],
                })
            if self.path == "/api/reasoning":
                return self.json_reply({"reasoning_effort": effort, "supports_reasoning_effort": True,
                                        "supported_efforts": ["low", "high"]})
            if self.path.startswith("/api/sessions?"):
                return self.json_reply({"sessions": []})
            return self.json_reply({"ok": True, "session_stream_available": True})
        if self.path == "/api/auth/status":
            with FIXTURE.request_lock:
                key = self.path
                FIXTURE.request_counts[key] = FIXTURE.request_counts.get(key, 0) + 1
            if FIXTURE.mode == "redirect-login":
                return self.reply(302, b"", "text/plain", {"Location": "/login"})
            if FIXTURE.mode == "html-login":
                return self.reply(
                    200,
                    b"<html><title>Hermes</title><body>Sign in<script src='login.js'></script></body></html>",
                    "text/html; charset=utf-8",
                )
            if FIXTURE.mode == "cross-origin":
                return self.reply(
                    302,
                    b"",
                    "text/plain",
                    {"Location": f"{FIXTURE.cross_origin}/capture"},
                )
            if FIXTURE.mode == "same-origin":
                return self.reply(
                    302, b"", "text/plain", {"Location": "/auth-status-final"}
                )
            return self.auth_status()
        if self.path == "/auth-status-final":
            return self.auth_status()
        if self.path == "/api/held":
            with FIXTURE.request_lock:
                key = self.path
                FIXTURE.request_counts[key] = FIXTURE.request_counts.get(key, 0) + 1
            FIXTURE.slow_entered.set()
            FIXTURE.slow_release.wait(timeout=10)
            if FIXTURE.slow_status == 401:
                return self.json_reply({"error": "unauthorized"}, status=401)
            return self.json_reply({"ok": True, "held": True})
        if self.path == "/api/quick":
            if not FIXTURE.has_session(self):
                return self.json_reply({"error": "unauthorized"}, status=401)
            return self.json_reply({"ok": True, "held": False})
        if self.path == "/api/sessions/events":
            with FIXTURE.request_lock:
                key = self.path
                FIXTURE.request_counts[key] = FIXTURE.request_counts.get(key, 0) + 1
        if self.path == "/login":
            return self.reply(
                200,
                b"<html><title>Hermes</title><body>Sign in</body></html>",
                "text/html; charset=utf-8",
            )
        self.json_reply({"error": "not found"}, status=404)

    def do_POST(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length)
        if self.path == "/api/reasoning":
            FIXTURE.reasoning_effort = json.loads(raw)["effort"]
            return self.json_reply({"reasoning_effort": FIXTURE.reasoning_effort,
                                    "supports_reasoning_effort": True,
                                    "supported_efforts": ["low", "high"]})
        if self.path in {"/api/upload", "/api/session/truncate", "/api/session/retry",
                         "/api/session/branch", "/api/session/duplicate"}:
            FIXTURE.optional(self.path)
            return self.json_reply({"error": "session required"}, status=400)
        if self.path == "/api/auth/login":
            try:
                password = json.loads(raw.decode()).get("password")
            except Exception:
                password = None
            if password != FIXTURE.password:
                return self.json_reply({"error": "Invalid password"}, status=401)
            return self.json_reply(
                {"ok": True},
                headers={
                    "Set-Cookie": (
                        f"hermes_session={FIXTURE.cookie_value}; Path=/; "
                        "HttpOnly; SameSite=Lax; Max-Age=2592000"
                    )
                },
            )
        if self.path == "/api/auth/logout":
            FIXTURE.logout_cookie = self.headers.get("Cookie", "")
            return self.json_reply(
                {"ok": True},
                headers={
                    "Set-Cookie": (
                        "hermes_session=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0"
                    )
                },
            )
        self.json_reply({"error": "not found"}, status=404)


class CrossOriginHandler(BaseHTTPRequestHandler):
    def log_message(self, _format: str, *_args: Any) -> None:
        return

    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        FIXTURE.cross_requests += 1
        body = b"cross origin must not be reached"
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class RunningServer:
    def __init__(self, handler: type[BaseHTTPRequestHandler]):
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    @property
    def url(self) -> str:
        host, port = self.server.server_address
        return f"http://{host}:{port}"

    def __enter__(self) -> "RunningServer":
        self.thread.start()
        return self

    def __exit__(self, *_args: Any) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)


async def scenario() -> None:
    with RunningServer(CrossOriginHandler) as cross, RunningServer(HermesHandler) as remote:
        FIXTURE.cross_origin = cross.url
        with tempfile.TemporaryDirectory(prefix="hermes-remote-auth.") as temporary:
            credential_path = Path(temporary) / "remote-webui-auth.json"
            manager = BRIDGE.RemoteWebUIAuth(
                credential_path, environment_url=remote.url
            )
            assert manager.status["state"] == "disconnected"
            assert manager.status["source"] == "environment"

            status = await manager.probe()
            assert status["state"] == "expired", status
            assert status["statusCode"] == 0
            assert status["origin"] == remote.url
            assert not credential_path.exists()

            captured_logs = io.StringIO()
            log_handler = logging.StreamHandler(captured_logs)
            BRIDGE.LOG.addHandler(log_handler)
            try:
                try:
                    await manager.login(remote.url, FIXTURE.password + "-wrong")
                    raise AssertionError("wrong password unexpectedly authenticated")
                except BRIDGE.RemoteLoginFault as fault:
                    assert fault.data["state"] == "expired"
                    assert fault.data["statusCode"] == 401
            finally:
                BRIDGE.LOG.removeHandler(log_handler)
            assert FIXTURE.password not in captured_logs.getvalue()
            assert not credential_path.exists()

            status = await manager.login(remote.url, FIXTURE.password)
            assert status["state"] == "connected", status
            assert status["authenticated"] is True
            assert status["hasSessionCredential"] is True
            assert credential_path.stat().st_mode & 0o777 == 0o600
            persisted = credential_path.read_text(encoding="utf-8")
            assert FIXTURE.password not in persisted
            assert FIXTURE.cookie_value in persisted
            headers = manager.authenticated_headers("/api/chat/stream")
            assert FIXTURE.cookie_value in headers["Cookie"]

            restored = BRIDGE.RemoteWebUIAuth(
                credential_path, environment_url="http://127.0.0.1:1"
            )
            assert restored.status["source"] == "persisted"
            assert (await restored.probe())["state"] == "connected"

            FIXTURE.mode = "same-origin"
            assert (await restored.probe())["state"] == "connected"

            FIXTURE.mode = "cross-origin"
            status = await restored.probe()
            assert status["state"] == "error", status
            assert status["errorKind"] == "redirect"
            assert FIXTURE.cross_requests == 0

            FIXTURE.mode = "redirect-login"
            status = await restored.probe()
            assert status["state"] == "expired", status
            assert status["statusCode"] == 302
            assert FIXTURE.cookie_value not in credential_path.read_text(encoding="utf-8")

            FIXTURE.mode = "normal"
            await restored.login(remote.url, FIXTURE.password)
            FIXTURE.mode = "html-login"
            status = await restored.probe()
            assert status["state"] == "expired", status
            assert status["statusCode"] == 200

            FIXTURE.mode = "normal"
            await restored.login(remote.url, FIXTURE.password)
            status = await restored.logout()
            assert status["state"] == "disconnected"
            assert status["source"] == "environment"
            assert status["origin"] == "http://127.0.0.1:1"
            assert status["remoteLogout"] is True
            assert FIXTURE.cookie_value in FIXTURE.logout_cookie
            assert not credential_path.exists()

            try:
                BRIDGE.normalize_remote_url("http://remote.example/hermes")
                raise AssertionError("non-TLS remote URL was accepted")
            except BRIDGE.RpcFault:
                pass
            try:
                BRIDGE.normalize_remote_url("https://user:secret@remote.example")
                raise AssertionError("credential-bearing URL was accepted")
            except BRIDGE.RpcFault:
                pass

            secret_marker = "fixture-token-must-not-cross-rpc"
            sanitized_fault = BRIDGE.RemoteWebUIAuth._http_error_fault(
                {
                    "status": 409,
                    "body": json.dumps(
                        {
                            "error": f"token {secret_marker}",
                            "type": "unexpected_conflict",
                            "retryable": False,
                        }
                    ).encode(),
                }
            )
            serialized_fault = json.dumps(
                BRIDGE.rpc_error("sanitized", sanitized_fault)
            )
            assert secret_marker not in serialized_fault
            assert "remoteMessage" not in sanitized_fault.data
            assert sanitized_fault.data == {
                "statusCode": 409,
                "errorType": "unexpected_conflict",
                "retryable": False,
            }

            stale_fault = BRIDGE.RemoteWebUIAuth._http_error_fault(
                {
                    "status": 409,
                    "body": json.dumps(
                        {
                            "error": "restart required",
                            "type": "agent_runtime_stale",
                            "retryable": True,
                        }
                    ).encode(),
                }
            )
            assert stale_fault.message == (
                "Remote Hermes fell back to a stale in-process Agent runtime. "
                "Restore gateway-backed chat, then retry; this prompt was not accepted."
            )
            assert stale_fault.data == {
                "statusCode": 409,
                "errorType": "agent_runtime_stale",
                "retryable": True,
                "remoteMessage": "restart required",
            }


async def hold_request(manager: Any) -> asyncio.Task[Any]:
    FIXTURE.slow_entered.clear()
    FIXTURE.slow_release.clear()
    task = asyncio.create_task(manager.request_json("GET", "/api/held", timeout=10))
    entered = await asyncio.to_thread(FIXTURE.slow_entered.wait, 5)
    assert entered, "held request never reached the fixture"
    return task


async def concurrency_scenario() -> None:
    """A request in flight must not stall the event loop or other requests."""

    FIXTURE.mode = "normal"
    FIXTURE.slow_status = 200
    with RunningServer(HermesHandler) as remote, tempfile.TemporaryDirectory(
        prefix="hermes-remote-auth-concurrency."
    ) as temporary:
        credential_path = Path(temporary) / "remote-webui-auth.json"
        manager = BRIDGE.RemoteWebUIAuth(credential_path, environment_url="")
        await manager.login(remote.url, FIXTURE.password)

        # Release the held request after a bound, so a regression fails the
        # timing assertions below instead of hanging the suite.
        watchdog = threading.Timer(3.0, FIXTURE.slow_release.set)
        watchdog.start()
        try:
            held = await hold_request(manager)
            started = time.monotonic()
            status = manager.status
            assert time.monotonic() - started < 0.2, "status waited on a request"
            assert status["state"] == "connected", status
            started = time.monotonic()
            manager.connecting_status("fixture")
            assert time.monotonic() - started < 0.2, "status write waited on a request"
            # A second request and a probe finish while the first is still
            # parked: remote traffic is not serialized behind one slow call.
            quick = await asyncio.wait_for(
                manager.request_json("GET", "/api/quick"), timeout=2
            )
            assert quick == {"ok": True, "held": False}
            assert (await asyncio.wait_for(manager.probe(), timeout=2))[
                "state"
            ] == "connected"
            assert not held.done()
            FIXTURE.slow_release.set()
            assert (await held)["held"] is True
        finally:
            watchdog.cancel()
            FIXTURE.slow_release.set()

        # Even a successful response belongs to the session that requested it.
        # A replacement sign-in must not consume that old session's payload.
        old_session = manager.session_identity
        held = await hold_request(manager)
        await manager.login(remote.url, FIXTURE.password)
        FIXTURE.slow_release.set()
        try:
            await held
            raise AssertionError("stale successful response crossed sessions")
        except BRIDGE.RpcFault as fault:
            assert fault.code == -32042
        try:
            await manager.request_json("GET", "/api/quick", session=old_session)
            raise AssertionError("queued work adopted the replacement session")
        except BRIDGE.RpcFault as fault:
            assert fault.code == -32042

        # A challenge for a session that a newer sign-in replaced mid-request
        # must not clear the replacement's cookie or report it expired.
        FIXTURE.slow_status = 401
        held = await hold_request(manager)
        await manager.login(remote.url, FIXTURE.password)
        FIXTURE.slow_release.set()
        try:
            await held
            raise AssertionError("stale challenge unexpectedly succeeded")
        except BRIDGE.RemoteLoginFault:
            raise AssertionError("stale challenge expired the replacement session")
        except BRIDGE.RpcFault as fault:
            assert fault.code == -32042, fault.message
        assert manager.status["state"] == "connected", manager.status
        assert manager.status["hasSessionCredential"] is True
        assert FIXTURE.cookie_value in credential_path.read_text(encoding="utf-8")

        # The same challenge for the current session still expires it.
        held = await hold_request(manager)
        FIXTURE.slow_release.set()
        try:
            await held
            raise AssertionError("current-session challenge was ignored")
        except BRIDGE.RemoteLoginFault as fault:
            assert fault.data["state"] == "expired"
        assert manager.status["state"] == "expired"
        assert FIXTURE.cookie_value not in credential_path.read_text(encoding="utf-8")
        FIXTURE.slow_status = 200


async def eventually(condition: Any, timeout: float = 3.0) -> None:
    deadline = time.monotonic() + timeout
    while not condition():
        assert time.monotonic() < deadline, "fixture condition not reached"
        await asyncio.sleep(0.005)


def fixture_bridge(root: Path) -> Any:
    registry = BRIDGE.ConversationRegistry(root / "conversations.json")
    registry.save()
    bridge = BRIDGE.HermesBridge(registry, "http://127.0.0.1:1",
                                 root / "remote-auth.json", local_backend_enabled=False)
    bridge.remote_auth = BRIDGE.RemoteWebUIAuth(root / "remote-auth.json", environment_url="")
    return bridge


async def discovery_scenario() -> None:
    """Slow optional endpoints never delay auth or multiply on concurrent opens."""

    # This fixture deliberately parks every independent discovery endpoint at
    # once. Give those server holds enough workers on two-core CI machines;
    # the separate saturation scenario exercises a fully occupied small pool.
    asyncio.get_running_loop().set_default_executor(ThreadPoolExecutor(max_workers=16))
    FIXTURE.mode = "normal"
    FIXTURE.model = "fixture-original"
    FIXTURE.request_counts.clear()
    FIXTURE.optional_entered.clear()
    FIXTURE.optional_release.clear()
    with RunningServer(HermesHandler) as remote, RunningServer(HermesHandler) as replacement, \
            tempfile.TemporaryDirectory(prefix="hermes-discovery.") as temporary:
        bridge = fixture_bridge(Path(temporary))
        bridge.start()
        try:
            # Both the session list and every optional capability endpoint stay
            # parked until explicitly released. The auth RPC must still finish.
            status = await asyncio.wait_for(bridge.dispatch("remote.login", {
                "url": remote.url, "password": FIXTURE.password,
            }), timeout=2)
            assert status["state"] == "connected"
            await eventually(lambda: FIXTURE.request_counts.get("/api/models") == 1)
            assert not FIXTURE.optional_release.is_set()
            initial_probes = FIXTURE.request_counts["/api/auth/status"]
            statuses = await asyncio.wait_for(asyncio.gather(*(
                bridge.dispatch("remote.status", {}) for _ in range(12)
            )), timeout=2)
            assert all(status["state"] == "connected" for status in statuses)
            assert FIXTURE.request_counts["/api/auth/status"] == initial_probes + 1
            assert (await asyncio.wait_for(bridge.dispatch("bridge.ping", {}), 0.5))["ok"]

            catalogs = [asyncio.create_task(bridge.dispatch("models.catalog", {}))
                        for _ in range(8)]
            contracts = [asyncio.create_task(bridge.probe_remote_contract()) for _ in range(8)]
            await asyncio.sleep(0.05)
            catalogs[0].cancel()  # Closing one client cannot cancel the shared fetch.
            await asyncio.gather(catalogs[0], return_exceptions=True)
            assert not any(task.done() for task in catalogs[1:] + contracts)
            optional_paths = {
                "/api/models", "/api/reasoning", "/api/sessions/gateway/stream?probe=1",
                "/api/upload", "/api/session/truncate", "/api/session/retry",
                "/api/session/branch", "/api/session/duplicate",
            }
            await eventually(lambda: all(path in FIXTURE.request_counts for path in optional_paths))
            assert all(FIXTURE.request_counts[path] == 1 for path in optional_paths)
            # A write that supersedes a slow cached read must not let that old
            # result restore the prior effort or downgrade usable controls.
            reasoning = asyncio.create_task(bridge.dispatch("reasoning.get", {}))
            await asyncio.sleep(0.01)
            changed = await bridge.dispatch("reasoning.set", {"effort": "max"})
            assert changed["effort"] == "max"
            try:
                await reasoning
                raise AssertionError("superseded reasoning discovery was successful")
            except BRIDGE.RpcFault as fault:
                assert fault.code == -32042
            FIXTURE.optional_release.set()
            results = await asyncio.wait_for(asyncio.gather(*catalogs[1:], *contracts), timeout=3)
            assert all(result["defaultModel"] == "fixture-original" for result in results[:7])
            assert bridge.remote_contract["modelSelection"] is True
            assert bridge.remote_contract["attachments"] is True
            assert bridge.remote_contract["checked"] is True
            assert bridge.remote_contract["reasoningEffort"] is True
            assert (await bridge.dispatch("reasoning.get", {}))["effort"] == "max"

            counts = {path: FIXTURE.request_counts[path] for path in optional_paths}
            await bridge.dispatch("remote.status", {})
            await bridge.dispatch("models.catalog", {})
            await bridge.probe_remote_contract()
            assert counts == {path: FIXTURE.request_counts[path] for path in optional_paths}

            # A second sign-in on the same origin must invalidate the cache,
            # even if the server issues an identical cookie value. Then switch
            # origins while its successful model response is still in flight.
            FIXTURE.model = "fixture-stale"
            FIXTURE.optional_release.clear()
            await bridge.dispatch("remote.login", {"url": remote.url, "password": FIXTURE.password})
            stale = asyncio.create_task(bridge.dispatch("models.catalog", {}))
            await eventually(lambda: FIXTURE.request_counts["/api/models"] == 2)
            FIXTURE.model = "fixture-replacement"
            await asyncio.wait_for(bridge.dispatch("remote.login", {
                "url": replacement.url, "password": FIXTURE.password,
            }), timeout=2)
            try:
                await asyncio.wait_for(stale, timeout=2)
                raise AssertionError("stale discovery caller was left successful")
            except BRIDGE.RpcFault as fault:
                assert fault.code == -32042
            fresh = asyncio.create_task(bridge.dispatch("models.catalog", {}))
            await eventually(lambda: FIXTURE.request_counts["/api/models"] == 3)
            assert bridge.remote_contract["attachments"] is False
            FIXTURE.optional_release.set()
            assert (await asyncio.wait_for(fresh, 3))["defaultModel"] == "fixture-replacement"
            await bridge.probe_remote_contract()
            assert bridge.remote_auth.status["state"] == "connected"
            assert bridge.remote_auth.base_url == replacement.url
            assert (await bridge.dispatch("models.catalog", {}))["defaultModel"] == "fixture-replacement"
        finally:
            FIXTURE.optional_release.set()
            await bridge.stop()
            await eventually(lambda: not any(thread.is_alive()
                                             for thread in bridge.remote_auth._auth_executor._threads))


async def auth_executor_scenario() -> None:
    """Authentication works while ordinary HTTP workers are all occupied."""

    asyncio.get_running_loop().set_default_executor(ThreadPoolExecutor(max_workers=2))
    FIXTURE.mode = "normal"
    FIXTURE.slow_status = 200
    FIXTURE.slow_release.clear()
    FIXTURE.request_counts.clear()
    with RunningServer(HermesHandler) as remote, tempfile.TemporaryDirectory(
        prefix="hermes-auth-workers."
    ) as temporary:
        manager = BRIDGE.RemoteWebUIAuth(Path(temporary) / "auth.json", environment_url="")
        held = []
        watchdog = threading.Timer(8, FIXTURE.slow_release.set)
        watchdog.start()
        try:
            await manager.login(remote.url, FIXTURE.password)
            held = [asyncio.create_task(manager.request_json("GET", "/api/held"))
                    for _ in range(2)]
            await eventually(lambda: FIXTURE.request_counts.get("/api/held") == 2)
            assert (await asyncio.wait_for(manager.probe(), 2))["state"] == "connected"
            assert (await asyncio.wait_for(manager.login(remote.url, FIXTURE.password), 2))[
                "state"] == "connected"
            signed_out = await asyncio.wait_for(manager.logout(), 2)
            assert signed_out["state"] == "disconnected" and signed_out["remoteLogout"]
            assert not manager.path.exists()
            assert not FIXTURE.slow_release.is_set()
            assert all(not task.done() for task in held)
        finally:
            watchdog.cancel()
            FIXTURE.slow_release.set()
            await asyncio.gather(*held, return_exceptions=True)
            manager.close()
            await eventually(lambda: not any(thread.is_alive()
                                             for thread in manager._auth_executor._threads))


async def auth_recovery_scenario() -> None:
    """Saved auth recovers offline -> online, without a shell or status RPC."""

    delays = [BRIDGE.remote_auth_retry_delay(n) for n in range(1, 15)]
    assert min(delays) >= 2.0 and max(delays) <= 300.0, delays
    assert delays[-1] == 300.0, delays
    real_delay = BRIDGE.remote_auth_retry_delay
    recorded: list[int] = []

    def short_delay(failures: int) -> float:
        recorded.append(failures)
        return 0.02

    BRIDGE.remote_auth_retry_delay = short_delay
    FIXTURE.optional_release.set()
    try:
        with RunningServer(HermesHandler) as remote:
            for expires in (False, True):
                FIXTURE.mode = "normal"
                FIXTURE.request_counts.clear()
                recorded.clear()
                with tempfile.TemporaryDirectory(prefix="hermes-auth-recovery.") as temporary:
                    root = Path(temporary)
                    seed = BRIDGE.RemoteWebUIAuth(root / "remote-auth.json", environment_url="")
                    await seed.login(remote.url, FIXTURE.password)
                    bridge = fixture_bridge(root)
                    online = threading.Event()
                    attempts = 0
                    original_request = bridge.remote_auth._request

                    def request(*args: Any, **kwargs: Any) -> Any:
                        nonlocal attempts
                        if args[3] == "/api/auth/status":
                            attempts += 1
                            if not online.is_set():
                                raise BRIDGE._RemoteTransportError()
                        return original_request(*args, **kwargs)

                    bridge.remote_auth._request = request
                    bridge.start()
                    try:
                        await eventually(lambda: len(recorded) >= 3)
                        assert recorded[:3] == [1, 2, 3], recorded
                        assert bridge.remote_auth.status["errorKind"] == "offline"
                        try:
                            await bridge.dispatch("remote.login", {"url": "invalid"})
                            raise AssertionError("invalid login URL was accepted")
                        except BRIDGE.RpcFault:
                            pass
                        assert not bridge.remote_background_suspended
                        if expires:
                            FIXTURE.mode = "expired-auth"
                        online.set()
                        expected = "expired" if expires else "connected"
                        await eventually(lambda: bridge.remote_auth.status["state"] == expected)
                        if not expires:
                            await eventually(lambda: FIXTURE.request_counts.get("/api/sessions/events") == 1)
                            await eventually(lambda: bridge.remote_contract["checked"])
                        else:
                            assert bridge.remote_auth.status["hasSessionCredential"] is False
                            assert "/api/sessions/events" not in FIXTURE.request_counts
                            assert "/api/models" not in FIXTURE.request_counts
                        checked = attempts
                        await asyncio.sleep(0.12)
                        assert attempts == checked, "auth kept polling after a conclusive result"
                        assert not bridge.remote_observer_tasks if expires else bridge.remote_background_ready
                        if expires:
                            # Losing connectivity after an explicit check must
                            # retain the now-known missing-auth requirement.
                            online.clear()
                            status = await bridge.dispatch("remote.status", {})
                            assert status["errorKind"] == "offline"
                            assert status["authEnabled"] and not status["hasSessionCredential"]
                            checked = attempts
                            await asyncio.sleep(0.12)
                            assert attempts == checked, "missing credentials caused automatic retries"
                    finally:
                        online.set()
                        await bridge.stop()

            # No configured origin means no auth, discovery or observer traffic.
            with tempfile.TemporaryDirectory(prefix="hermes-auth-missing.") as temporary:
                bridge = fixture_bridge(Path(temporary))
                FIXTURE.request_counts.clear()
                recorded.clear()
                bridge.start()
                try:
                    await asyncio.sleep(0.08)
                    assert not FIXTURE.request_counts and not recorded
                    assert not bridge.remote_observer_tasks
                finally:
                    await bridge.stop()
    finally:
        FIXTURE.mode = "normal"
        BRIDGE.remote_auth_retry_delay = real_delay


async def selected_observer_discovery_scenario() -> None:
    """Late stream-path discovery replaces the selected observer exactly once."""

    discovery_entered = threading.Event()
    discovery_release = threading.Event()
    advertised_path = "/api/fixture/session-events"
    opened: list[str] = []

    class SelectedObserverHandler(HermesHandler):
        def do_GET(self) -> None:  # noqa: N802
            if self.path == "/api/sessions/gateway/stream?probe=1":
                discovery_entered.set()
                assert discovery_release.wait(timeout=10)
                return self.json_reply({
                    "ok": True, "session_stream_available": True,
                    "session_stream_path": advertised_path,
                })
            if self.path == "/api/sessions?exclude_hidden=1":
                return self.json_reply({"sessions": [{
                    "session_id": "selected", "title": "Selected", "message_count": 0,
                }]})
            if self.path.startswith(("/api/session/stream?", "/api/fixture/")):
                path = self.path.split("?", 1)[0]
                opened.append(path)
                if path == "/api/session/stream":
                    return self.json_reply({"error": "not found"}, status=404)
                return self.reply(200, b": ready\n\n", "text/event-stream")
            super().do_GET()

    FIXTURE.mode = "normal"
    FIXTURE.optional_release.set()
    with RunningServer(SelectedObserverHandler) as remote, \
            tempfile.TemporaryDirectory(prefix="hermes-selected-observer.") as temporary:
        bridge = fixture_bridge(Path(temporary))
        consuming = asyncio.Event()
        parked = asyncio.Event()

        async def hold_observer(_response: Any, _handle: Any) -> None:
            # Keep the accepted HTTP stream owned by its production observer
            # task, without introducing a blocking network reader in this test.
            consuming.set()
            await parked.wait()

        bridge._consume_observer_sse = hold_observer
        bridge.start()
        try:
            await bridge.dispatch("remote.login", {"url": remote.url, "password": FIXTURE.password})
            await eventually(discovery_entered.is_set)
            bridge.registry.conversations["selected"] = bridge.remote_conversation_record({
                "session_id": "selected", "title": "Selected", "message_count": 0,
            })
            bridge.registry.selected_conversation_id = "selected"
            await bridge.observe_remote_conversation("selected")
            await eventually(lambda: opened == ["/api/session/stream"]
                             and "session" not in bridge.remote_observer_tasks)
            assert not discovery_release.is_set()
            discovery_release.set()
            await eventually(consuming.is_set)
            await bridge.probe_remote_contract()
            observer = bridge.remote_observer_tasks["session"]
            assert opened == ["/api/session/stream", advertised_path], opened
            assert bridge.remote_observed_conversation_id == "selected"
            assert list(bridge.remote_observer_responses) == ["session"]
            await bridge.probe_remote_contract()
            assert bridge.remote_observer_tasks["session"] is observer
            assert opened.count(advertised_path) == 1

            # Rediscovery can also change an already working stream's path.
            consuming.clear()
            advertised_path = "/api/fixture/replacement-events"
            await bridge._discover_remote_contract(bridge.remote_auth.session_identity)
            await eventually(consuming.is_set)
            replacement = bridge.remote_observer_tasks["session"]
            assert observer.done() and replacement is not observer
            assert opened == ["/api/session/stream", "/api/fixture/session-events", advertised_path]
            assert list(bridge.remote_observer_responses) == ["session"]

            # Authentication may change while discovery publishes capabilities.
            # Its old continuation must not stop or restart the new selection.
            publishing = asyncio.Event()
            publish_release = asyncio.Event()
            original_publish = bridge.publish_remote_contract
            advertised_path = "/api/fixture/stale-events"

            async def hold_publish() -> None:
                if bridge.remote_contract.get("sessionStreamPath") == advertised_path:
                    publishing.set()
                    await publish_release.wait()
                await original_publish()

            bridge.publish_remote_contract = hold_publish
            stale_session = bridge.remote_auth.session_identity
            stale = asyncio.create_task(bridge._discover_remote_contract(stale_session))
            try:
                await asyncio.wait_for(publishing.wait(), 3)
                await bridge.remote_auth.login(remote.url, FIXTURE.password)
                assert not bridge.remote_auth.is_current_session(stale_session)
                publish_release.set()
                await asyncio.wait_for(stale, 3)
                assert bridge.remote_observer_tasks["session"] is replacement
                assert len(opened) == 3, opened
                await bridge.observe_remote_conversation("selected", session=stale_session, restart=True)
                assert bridge.remote_observer_tasks["session"] is replacement
            finally:
                publish_release.set()
                stale.cancel()
                await asyncio.gather(stale, return_exceptions=True)

            # The same session fence must hold after awaiting old-stream close.
            stopped = asyncio.Event()
            stop_release = asyncio.Event()
            original_stop = bridge.stop_remote_observer

            async def hold_stop(key: str) -> None:
                await original_stop(key)
                if key == "session":
                    stopped.set()
                    await stop_release.wait()

            bridge.stop_remote_observer = hold_stop
            restarting = asyncio.create_task(bridge.observe_remote_conversation(
                "selected", session=bridge.remote_auth.session_identity, restart=True,
            ))
            try:
                await asyncio.wait_for(stopped.wait(), 3)
                await bridge.remote_auth.login(remote.url, FIXTURE.password)
                stop_release.set()
                await asyncio.wait_for(restarting, 3)
                assert "session" not in bridge.remote_observer_tasks
                assert len(opened) == 3, opened
            finally:
                stop_release.set()
                restarting.cancel()
                await asyncio.gather(restarting, return_exceptions=True)
                bridge.stop_remote_observer = original_stop
        finally:
            discovery_release.set()
            await bridge.stop()


async def observer_cancellation_scenario() -> None:
    """A cancelled urllib open still owns and closes its eventual SSE response."""

    with tempfile.TemporaryDirectory(prefix="hermes-observer-cancellation.") as temporary:
        bridge = fixture_bridge(Path(temporary))
        entered = threading.Event()
        released = threading.Event()
        response = io.BytesIO()

        def open_sse(_path: str, **_kwargs: Any) -> Any:
            entered.set()
            assert released.wait(timeout=3)
            return response

        bridge.remote_auth.open_sse = open_sse
        opening = asyncio.create_task(bridge.open_remote_observer(
            "/api/sessions/events", bridge.remote_auth.session_identity
        ))
        try:
            await eventually(entered.is_set)
            opening.cancel()
            await asyncio.gather(opening, return_exceptions=True)
            assert not response.closed
            released.set()
            await eventually(lambda: response.closed)
            await eventually(lambda: not bridge.remote_observer_cleanup_tasks)
        finally:
            released.set()
            await bridge.stop()


if __name__ == "__main__":
    asyncio.run(scenario())
    asyncio.run(concurrency_scenario())
    asyncio.run(auth_executor_scenario())
    asyncio.run(discovery_scenario())
    asyncio.run(auth_recovery_scenario())
    asyncio.run(selected_observer_discovery_scenario())
    asyncio.run(observer_cancellation_scenario())
    print(
        "Hermes WebUI auth keeps passwords ephemeral, confines redirects, "
        "persists 0600 cookies, normalizes expired sessions, and never "
        "blocks on a request in flight or optional discovery; saved auth recovers "
        "offline without a UI and stops retrying expired sessions"
    )
