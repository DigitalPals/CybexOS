#!/usr/bin/env python3
"""Focused HTTP security fixture for remote Hermes WebUI authentication."""

from __future__ import annotations

import asyncio
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
                "logged_in": FIXTURE.has_session(self),
                "password_auth_enabled": True,
                "oidc_enabled": False,
            }
        )

    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        if self.path == "/api/auth/status":
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
            FIXTURE.slow_entered.set()
            FIXTURE.slow_release.wait(timeout=10)
            if FIXTURE.slow_status == 401:
                return self.json_reply({"error": "unauthorized"}, status=401)
            return self.json_reply({"ok": True, "held": True})
        if self.path == "/api/quick":
            if not FIXTURE.has_session(self):
                return self.json_reply({"error": "unauthorized"}, status=401)
            return self.json_reply({"ok": True, "held": False})
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


if __name__ == "__main__":
    asyncio.run(scenario())
    asyncio.run(concurrency_scenario())
    print(
        "Hermes WebUI auth keeps passwords ephemeral, confines redirects, "
        "persists 0600 cookies, normalizes expired sessions, and never "
        "blocks on a request in flight"
    )
