#!/usr/bin/env python3
"""Durable loopback bridge between Quickshell and Hermes.

The normal workstation deployment is a remote-only client for an existing
Hermes WebUI.  A local ``hermes serve`` adapter remains available for protocol
fixtures and opt-in deployments, but is never started in remote-only mode.
Every conversation gets a stable ``id`` while the bridge translates the remote or
local session identity and never retries a prompt whose delivery is ambiguous.

Downstream frames are JSON-RPC 2.0.  Notifications always have this shape::

    {"jsonrpc":"2.0", "method":"event",
     "params":{"type":"message.delta", "payload":{...}}}

The listener is intentionally restricted to a loopback address and has no
authentication. Remote WebUI cookies stay inside the bridge and local upstream
tokens, when enabled, are never persisted or sent downstream.
"""

from __future__ import annotations

import argparse
import asyncio
from contextlib import suppress
from dataclasses import dataclass, field
from datetime import datetime, timezone
import hashlib
from http.cookiejar import Cookie, CookieJar
import ipaddress
import json
import logging
import mimetypes
import os
from pathlib import Path
import random
import re
import signal
import stat
import sys
import threading
import time
from typing import Any, Awaitable, Callable
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urljoin, urlparse, urlunparse
from urllib.request import (
    HTTPRedirectHandler,
    HTTPCookieProcessor,
    Request,
    build_opener,
    urlopen,
)
import uuid

import websockets
from websockets.asyncio.client import ClientConnection
from websockets.asyncio.server import ServerConnection
from websockets.exceptions import ConnectionClosed


LOG = logging.getLogger("hermes-menubar-bridge")
BRIDGE_VERSION = 1
MAX_DOWNSTREAM_MESSAGE = 2 * 1024 * 1024
MAX_UPSTREAM_MESSAGE = 384 * 1024 * 1024
MAX_PROVIDER_RESPONSE = 4 * 1024 * 1024
MAX_REMOTE_AUTH_RESPONSE = 2 * 1024 * 1024
MAX_REMOTE_SSE_EVENT = 4 * 1024 * 1024
MAX_REMOTE_STREAM_EVENT = 4 * 1024 * 1024
MAX_REMOTE_ATTACHMENT_BYTES = 20 * 1024 * 1024
MAX_REMOTE_ATTACHMENTS = 20
REMOTE_HISTORY_PAGE = 80
REMOTE_HISTORY_MAX_MESSAGES = 250
REMOTE_HISTORY_MAX_TOOLS = 250
MAX_REMOTE_TOOL_DETAIL = 4096
MAX_REMOTE_REASONING = 12000
DEFAULT_UPSTREAM = "http://127.0.0.1:9119"
DEFAULT_LISTEN = "127.0.0.1"
DEFAULT_PORT = 9120
DEFAULT_PATH = "/ws"
TOKEN_PATTERN = re.compile(
    r"window\.__HERMES_SESSION_TOKEN__\s*=\s*(\"(?:\\.|[^\"\\])*\")"
)
CONVERSATION_ID_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.:-]{0,255}$")
REMOTE_AUTH_VERSION = 1


class RpcFault(Exception):
    """A JSON-RPC error safe to return to the local client."""

    def __init__(self, code: int, message: str, data: Any = None):
        super().__init__(message)
        self.code = code
        self.message = message
        self.data = data


class UpstreamUnavailable(RpcFault):
    def __init__(self, message: str = "Hermes is offline"):
        super().__init__(-32010, message)


class AmbiguousDelivery(RpcFault):
    """The socket dropped after a write, so the server may have accepted it."""

    def __init__(self, method: str):
        super().__init__(
            -32011,
            f"Hermes disconnected while {method} was in flight; its outcome is "
            "unknown and the bridge did not retry it",
            {"method": method, "deliveryUnknown": True, "replayed": False},
        )


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace(
        "+00:00", "Z"
    )


def json_frame(frame: dict[str, Any]) -> str:
    return json.dumps(frame, ensure_ascii=False, separators=(",", ":"))


def rpc_result(request_id: Any, result: Any) -> dict[str, Any]:
    return {"jsonrpc": "2.0", "id": request_id, "result": result}


def rpc_error(request_id: Any, fault: RpcFault) -> dict[str, Any]:
    error: dict[str, Any] = {"code": fault.code, "message": fault.message}
    if fault.data is not None:
        error["data"] = fault.data
    return {"jsonrpc": "2.0", "id": request_id, "error": error}


def event_frame(event_type: str, payload: dict[str, Any]) -> dict[str, Any]:
    return {
        "jsonrpc": "2.0",
        "method": "event",
        "params": {"type": event_type, "payload": payload},
    }


def slugify(name: str) -> str:
    value = re.sub(r"[^a-z0-9]+", "-", name.strip().lower()).strip("-")
    return (value or "conversation")[:48]


def is_loopback(host: str) -> bool:
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return host.lower() == "localhost"


class _RemoteAuthRequired(Exception):
    """A remote response is an authentication challenge, not API data."""

    def __init__(self, status_code: int = 401):
        super().__init__("remote authentication required")
        self.status_code = status_code


class _RemoteRedirectBlocked(Exception):
    """A redirect attempted to leave the configured WebUI origin."""


class _RemoteTransportError(Exception):
    """The remote WebUI could not be reached."""


def _remote_origin(url: str) -> tuple[str, str, int]:
    parsed = urlparse(url)
    try:
        port = parsed.port
    except ValueError as exc:
        raise RpcFault(-32602, "Remote Hermes URL has an invalid port") from exc
    scheme = parsed.scheme.lower()
    hostname = (parsed.hostname or "").lower().rstrip(".")
    if not hostname or scheme not in {"http", "https"}:
        raise RpcFault(-32602, "Remote Hermes URL must use http:// or https://")
    return scheme, hostname, port or (443 if scheme == "https" else 80)


def normalize_remote_url(raw: Any) -> str:
    """Validate and canonicalize a user-provided Hermes WebUI base URL."""

    if not isinstance(raw, str) or not raw.strip():
        raise RpcFault(-32602, "Remote Hermes URL is required")
    value = raw.strip().rstrip("/")
    if len(value) > 2048 or any(ord(character) < 0x20 for character in value):
        raise RpcFault(-32602, "Remote Hermes URL is invalid")
    if any(character.isspace() or character == "\\" for character in value):
        raise RpcFault(-32602, "Remote Hermes URL must not contain whitespace")
    try:
        parsed = urlparse(value)
        hostname = parsed.hostname
        port = parsed.port
    except ValueError as exc:
        raise RpcFault(-32602, "Remote Hermes URL is invalid") from exc
    scheme = parsed.scheme.lower()
    if (
        scheme not in {"http", "https"}
        or not hostname
        or parsed.username is not None
        or parsed.password is not None
        or parsed.params
        or parsed.query
        or parsed.fragment
    ):
        raise RpcFault(
            -32602,
            "Use an http(s) Hermes URL without credentials, query, or fragment",
        )
    if scheme == "http" and not is_loopback(hostname):
        raise RpcFault(
            -32602,
            "Remote Hermes URLs must use HTTPS; HTTP is allowed only on loopback",
        )
    try:
        ascii_hostname = hostname.rstrip(".").encode("idna").decode("ascii").lower()
    except UnicodeError as exc:
        raise RpcFault(-32602, "Remote Hermes URL has an invalid hostname") from exc
    host_for_netloc = (
        f"[{ascii_hostname}]" if ":" in ascii_hostname else ascii_hostname
    )
    default_port = 443 if scheme == "https" else 80
    if port is not None and port != default_port:
        host_for_netloc = f"{host_for_netloc}:{port}"
    path = parsed.path.rstrip("/")
    decoded_segments = [
        segment.lower().replace("%2e", ".") for segment in path.split("/")
    ]
    if any(segment in {".", ".."} for segment in decoded_segments):
        raise RpcFault(-32602, "Remote Hermes URL path must not traverse directories")
    normalized = urlunparse((scheme, host_for_netloc, path, "", "", ""))
    _remote_origin(normalized)
    return normalized


def _is_login_url(url: str) -> bool:
    try:
        path = urlparse(url).path.rstrip("/").lower()
    except ValueError:
        return False
    if path.endswith("/api/auth/login") or path.endswith("/api/auth/passkey/login"):
        return False
    return path == "/login" or path.endswith("/login")


class _SameOriginRedirectHandler(HTTPRedirectHandler):
    """Follow only redirects that remain on the originally requested origin."""

    max_redirections = 5

    def __init__(self, allowed_origin: tuple[str, str, int]):
        super().__init__()
        self.allowed_origin = allowed_origin
        self.redirects: list[str] = []

    def redirect_request(
        self,
        request: Request,
        file_pointer: Any,
        code: int,
        message: str,
        headers: Any,
        new_url: str,
    ) -> Request | None:
        target = urljoin(request.full_url, new_url)
        # Login redirects are a normal expired-session signal. Do not follow
        # them, even when a reverse proxy points at a different origin.
        if _is_login_url(target):
            raise _RemoteAuthRequired(code)
        parsed = urlparse(target)
        if parsed.username is not None or parsed.password is not None:
            raise _RemoteRedirectBlocked()
        try:
            target_origin = _remote_origin(target)
        except RpcFault as exc:
            raise _RemoteRedirectBlocked() from exc
        if target_origin != self.allowed_origin:
            raise _RemoteRedirectBlocked()
        self.redirects.append(target)
        return super().redirect_request(
            request, file_pointer, code, message, headers, target
        )


class RemoteLoginFault(RpcFault):
    def __init__(self, message: str, status: dict[str, Any], code: int = -32040):
        super().__init__(code, message, status)


class RemoteWebUIAuth:
    """Origin-bound Hermes WebUI cookie session manager.

    The password is used only to build one in-memory login request. The file
    contains the normalized origin and cookies issued by that origin; it never
    contains a password, request body, or server response body.
    """

    def __init__(self, path: Path, environment_url: str | None = None):
        self.path = path
        self._lock = threading.RLock()
        self.cookie_jar = CookieJar()
        self.base_url = ""
        self.source = "none"
        self.environment_url = ""
        self._status = self._make_status(
            "disconnected", message="Remote Hermes is not configured"
        )
        configured_environment = (
            environment_url
            if environment_url is not None
            else os.environ.get("HERMES_REMOTE_URL", "")
        )
        if configured_environment:
            try:
                self.environment_url = normalize_remote_url(configured_environment)
            except RpcFault:
                self._status = self._make_status(
                    "error",
                    message="HERMES_REMOTE_URL is invalid",
                    error_kind="configuration",
                )
        file_exists = self.path.exists()
        if file_exists:
            self._load()
        elif self.environment_url:
            self.base_url = self.environment_url
            self.source = "environment"
            self._status = self._make_status(
                "disconnected",
                configured=True,
                url=self.base_url,
                message="Remote Hermes has not been checked",
            )

    @property
    def status(self) -> dict[str, Any]:
        with self._lock:
            return dict(self._status)

    def connecting_status(self, message: str, url: Any = None) -> dict[str, Any]:
        with self._lock:
            display_url = self.base_url
            if url:
                display_url = normalize_remote_url(url)
            self._status = self._make_status(
                "connecting",
                configured=bool(display_url),
                url=display_url,
                message=message,
            )
            return dict(self._status)

    def _make_status(
        self,
        state: str,
        *,
        configured: bool | None = None,
        url: str | None = None,
        reachable: bool = False,
        auth_enabled: bool = False,
        authenticated: bool = False,
        logged_in: bool = False,
        password_auth_enabled: bool = False,
        message: str = "",
        error_kind: str = "",
        status_code: int = 0,
    ) -> dict[str, Any]:
        selected_url = self.base_url if url is None else url
        selected_configured = bool(selected_url) if configured is None else configured
        return {
            "state": state,
            "configured": selected_configured,
            "url": selected_url,
            "origin": selected_url,
            "reachable": reachable,
            "authEnabled": auth_enabled,
            "authenticated": authenticated,
            "loggedIn": logged_in,
            "passwordAuthEnabled": password_auth_enabled,
            "authRequired": state == "expired",
            "hasSessionCredential": any(True for _ in self.cookie_jar),
            "source": self.source,
            "message": message,
            "error": message if state in {"expired", "error"} else "",
            "errorKind": error_kind,
            "statusCode": status_code,
            "updatedAt": utc_now(),
        }

    def _load(self) -> None:
        try:
            document = json.loads(self.path.read_text(encoding="utf-8"))
            if not isinstance(document, dict):
                raise ValueError("credential document is not an object")
            base_url = normalize_remote_url(document.get("base_url"))
            rows = document.get("cookies", [])
            if not isinstance(rows, list):
                raise ValueError("credential cookie list is invalid")
            jar = CookieJar()
            for row in rows:
                cookie = self._cookie_from_row(row, base_url)
                if cookie is not None:
                    jar.set_cookie(cookie)
            self.base_url = base_url
            self.cookie_jar = jar
            self.source = "persisted"
            with suppress(OSError):
                os.chmod(self.path, 0o600)
            self._status = self._make_status(
                "disconnected",
                configured=True,
                url=base_url,
                message="Saved remote session has not been checked",
            )
        except FileNotFoundError:
            return
        except (OSError, UnicodeDecodeError, json.JSONDecodeError, ValueError, RpcFault):
            # Never include credential document contents in diagnostics.
            LOG.warning("could not load remote Hermes credentials from %s", self.path)
            self.base_url = ""
            self.cookie_jar = CookieJar()
            self.source = "none"
            self._status = self._make_status(
                "error",
                configured=False,
                url="",
                message="Saved remote Hermes credentials are invalid",
                error_kind="credentials",
            )

    @staticmethod
    def _cookie_from_row(row: Any, base_url: str) -> Cookie | None:
        if not isinstance(row, dict):
            return None
        name = row.get("name")
        value = row.get("value")
        domain = str(row.get("domain") or "").lstrip(".").lower().rstrip(".")
        origin_host = (urlparse(base_url).hostname or "").lower().rstrip(".")
        path = str(row.get("path") or "/")
        if (
            not isinstance(name, str)
            or not name
            or len(name) > 256
            or not isinstance(value, str)
            or len(value) > 16384
            or any(ord(character) < 0x20 for character in name + value)
            or domain != origin_host
            or not path.startswith("/")
            or len(path) > 2048
        ):
            return None
        expires_raw = row.get("expires")
        try:
            expires = int(expires_raw) if expires_raw is not None else None
        except (TypeError, ValueError):
            return None
        if expires is not None and expires <= int(time.time()):
            return None
        return Cookie(
            version=0,
            name=name,
            value=value,
            port=None,
            port_specified=False,
            domain=domain,
            domain_specified=bool(row.get("domain_specified", False)),
            domain_initial_dot=False,
            path=path,
            path_specified=True,
            secure=bool(row.get("secure", False)),
            expires=expires,
            discard=expires is None,
            comment=None,
            comment_url=None,
            rest={"HttpOnly": None} if row.get("http_only", True) else {},
            rfc2109=False,
        )

    def _cookie_rows(self, base_url: str, jar: CookieJar) -> list[dict[str, Any]]:
        origin_host = (urlparse(base_url).hostname or "").lower().rstrip(".")
        now = time.time()
        rows: list[dict[str, Any]] = []
        for cookie in jar:
            if cookie.is_expired(now) or cookie.domain.lstrip(".").lower() != origin_host:
                continue
            rows.append(
                {
                    "name": cookie.name,
                    "value": cookie.value,
                    "domain": origin_host,
                    "domain_specified": cookie.domain_specified,
                    "path": cookie.path or "/",
                    "secure": cookie.secure,
                    "expires": cookie.expires,
                    "http_only": "HttpOnly" in cookie._rest,
                }
            )
        return rows

    def _save(self) -> None:
        if not self.base_url:
            self._delete_file()
            return
        self.path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        with suppress(OSError):
            os.chmod(self.path.parent, 0o700)
        document = {
            "version": REMOTE_AUTH_VERSION,
            "base_url": self.base_url,
            "cookies": self._cookie_rows(self.base_url, self.cookie_jar),
        }
        temporary = self.path.with_name(f".{self.path.name}.tmp.{os.getpid()}")
        descriptor = os.open(
            temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600
        )
        try:
            with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
                json.dump(document, stream, ensure_ascii=False, separators=(",", ":"))
                stream.write("\n")
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, self.path)
            os.chmod(self.path, 0o600)
        finally:
            with suppress(FileNotFoundError):
                temporary.unlink()

    def _delete_file(self) -> None:
        try:
            self.path.unlink()
        except FileNotFoundError:
            return
        except OSError as exc:
            raise RpcFault(-32043, "Could not remove saved remote session") from exc

    @staticmethod
    def _login_page_response(response: dict[str, Any]) -> bool:
        if response["status"] == 401 or _is_login_url(response["url"]):
            return True
        location = response["headers"].get("Location", "")
        if location and _is_login_url(urljoin(response["url"], location)):
            return True
        content_type = response["headers"].get("Content-Type", "").lower()
        if "text/html" not in content_type:
            return False
        sample = response["body"][:256 * 1024].decode("utf-8", errors="ignore").lower()
        return (
            "login.js" in sample
            or "/api/auth/login" in sample
            or ("sign in" in sample and "hermes" in sample)
        )

    def _request(
        self,
        base_url: str,
        jar: CookieJar,
        method: str,
        path: str,
        payload: dict[str, Any] | None,
        timeout: float,
        *,
        encoded_body: bytes | None = None,
        content_type: str = "",
    ) -> dict[str, Any]:
        if not path.startswith("/") or "://" in path:
            raise RpcFault(-32602, "Remote Hermes API path is invalid")
        body = encoded_body
        headers = {
            "Accept": "application/json",
            "User-Agent": "cybexos-hermes-menubar-bridge/1",
        }
        if encoded_body is not None:
            if not content_type:
                raise RpcFault(-32602, "Remote Hermes request content type is required")
            headers["Content-Type"] = content_type
        elif payload is not None:
            body = json.dumps(
                payload, ensure_ascii=False, separators=(",", ":")
            ).encode("utf-8")
            headers["Content-Type"] = "application/json"
        redirect_handler = _SameOriginRedirectHandler(_remote_origin(base_url))
        opener = build_opener(redirect_handler, HTTPCookieProcessor(jar))
        request = Request(
            f"{base_url}{path}", body, headers=headers, method=method.upper()
        )
        try:
            with opener.open(request, timeout=timeout) as response:
                raw = response.read(MAX_REMOTE_AUTH_RESPONSE + 1)
                result = {
                    "status": int(response.status),
                    "url": response.geturl(),
                    "headers": response.headers,
                    "body": raw,
                    "redirects": list(redirect_handler.redirects),
                }
        except (_RemoteAuthRequired, _RemoteRedirectBlocked):
            raise
        except HTTPError as exc:
            raw = exc.read(MAX_REMOTE_AUTH_RESPONSE + 1)
            result = {
                "status": int(exc.code),
                "url": exc.geturl(),
                "headers": exc.headers,
                "body": raw,
                "redirects": list(redirect_handler.redirects),
            }
        except (URLError, TimeoutError, OSError) as exc:
            raise _RemoteTransportError() from exc
        if len(result["body"]) > MAX_REMOTE_AUTH_RESPONSE:
            raise RpcFault(-32041, "Remote Hermes response is too large")
        if self._login_page_response(result):
            raise _RemoteAuthRequired(result["status"])
        return result

    @staticmethod
    def _json_response(response: dict[str, Any]) -> dict[str, Any]:
        try:
            value = json.loads(response["body"].decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError, TypeError) as exc:
            raise RpcFault(-32041, "Remote Hermes returned invalid JSON") from exc
        if not isinstance(value, dict):
            raise RpcFault(-32041, "Remote Hermes returned invalid JSON")
        return value

    @classmethod
    def _http_error_fault(cls, response: dict[str, Any]) -> RpcFault:
        """Translate a bounded WebUI error without reflecting secrets.

        Hermes WebUI returns typed JSON for recoverable conflicts. Only a
        small scalar allow-list crosses the loopback RPC boundary; arbitrary
        response objects, headers, cookies, and request content never do.
        """

        status_code = int(response.get("status") or 0)
        data: dict[str, Any] = {"statusCode": status_code}
        try:
            value = cls._json_response(response)
        except RpcFault:
            value = {}

        error_type = str(value.get("type") or "").strip().lower()
        if re.fullmatch(r"[a-z][a-z0-9_-]{0,63}", error_type):
            data["errorType"] = error_type
        else:
            error_type = ""

        error_code = str(value.get("code") or "").strip().lower()
        if re.fullmatch(r"[a-z][a-z0-9_-]{0,63}", error_code):
            data["errorCode"] = error_code
        else:
            error_code = ""

        if isinstance(value.get("retryable"), bool):
            data["retryable"] = value["retryable"]

        active_stream_id = str(value.get("active_stream_id") or "").strip()
        if re.fullmatch(r"[A-Za-z0-9_-]{1,128}", active_stream_id):
            data["activeStreamId"] = active_stream_id
        else:
            active_stream_id = ""

        raw_message = value.get("error")
        if not isinstance(raw_message, str):
            raw_message = value.get("message")
        if not isinstance(raw_message, str):
            raw_message = ""
        remote_message = re.sub(r"\s+", " ", "".join(
            character for character in raw_message
            if ord(character) >= 0x20 and ord(character) != 0x7f
        )).strip()[:500]
        sensitive_words = re.compile(
            r"password|passphrase|api[ _-]?key|authorization|cookie|secret|token",
            re.IGNORECASE,
        )
        if remote_message and not sensitive_words.search(remote_message):
            data["remoteMessage"] = remote_message

        if error_type == "agent_runtime_stale":
            message = (
                "Remote Hermes fell back to a stale in-process Agent runtime. "
                "Restore gateway-backed chat, then retry; this prompt was not accepted."
            )
        elif active_stream_id or error_type in {
            "active_stream",
            "chat_already_running",
            "session_busy",
            "stream_conflict",
        }:
            message = (
                "This Hermes session already has an active response; "
                "the new prompt was not accepted."
            )
        elif error_code == "stale_regeneration_revision":
            message = "This conversation changed; refresh it before regenerating"
        elif error_code == "unsupported_regeneration_backend":
            message = "Regeneration is unavailable on this Hermes backend"
        elif error_code == "invalid_regeneration_request":
            message = "Hermes rejected the regeneration request"
        else:
            message = f"Remote Hermes returned HTTP {status_code}"

        return RpcFault(-32041, message, data)

    def _probe_base(
        self,
        base_url: str,
        jar: CookieJar,
        *,
        configured: bool,
        source: str,
        timeout: float,
    ) -> dict[str, Any]:
        previous_source = self.source
        self.source = source
        try:
            response = self._request(
                base_url, jar, "GET", "/api/auth/status", None, timeout
            )
            if not 200 <= response["status"] < 300:
                return self._make_status(
                    "error",
                    configured=configured,
                    url=base_url,
                    reachable=True,
                    message=f"Remote Hermes returned HTTP {response['status']}",
                    error_kind="http",
                    status_code=response["status"],
                )
            value = self._json_response(response)
            if "auth_enabled" not in value or "logged_in" not in value:
                raise RpcFault(-32041, "Remote endpoint is not a compatible Hermes WebUI")
            auth_enabled = value.get("auth_enabled") is True
            logged_in = value.get("logged_in") is True
            connected = not auth_enabled or logged_in
            return self._make_status(
                "connected" if connected else "expired",
                configured=configured,
                url=base_url,
                reachable=True,
                auth_enabled=auth_enabled,
                authenticated=connected,
                logged_in=logged_in,
                password_auth_enabled=value.get("password_auth_enabled") is True,
                message=(
                    "Remote Hermes is connected"
                    if connected
                    else "Remote Hermes authentication is required"
                ),
            )
        except _RemoteAuthRequired as exc:
            return self._make_status(
                "expired",
                configured=configured,
                url=base_url,
                reachable=True,
                auth_enabled=True,
                message="Remote Hermes authentication is required",
                status_code=exc.status_code,
            )
        except _RemoteRedirectBlocked:
            return self._make_status(
                "error",
                configured=configured,
                url=base_url,
                reachable=True,
                message="Remote Hermes attempted a cross-origin redirect",
                error_kind="redirect",
            )
        except _RemoteTransportError:
            return self._make_status(
                "error",
                configured=configured,
                url=base_url,
                reachable=False,
                message="Remote Hermes is unreachable",
                error_kind="offline",
            )
        except RpcFault as fault:
            return self._make_status(
                "error",
                configured=configured,
                url=base_url,
                reachable=True,
                message=fault.message,
                error_kind="protocol",
            )
        finally:
            self.source = previous_source

    async def probe(self, url: Any = None, timeout: float = 10.0) -> dict[str, Any]:
        return await asyncio.to_thread(self._probe_sync, url, timeout)

    def _probe_sync(self, url: Any, timeout: float) -> dict[str, Any]:
        with self._lock:
            if url is not None and str(url).strip():
                base_url = normalize_remote_url(url)
            else:
                base_url = self.base_url
            if not base_url:
                self._status = self._make_status(
                    "disconnected", message="Remote Hermes is not configured"
                )
                return dict(self._status)
            is_current = base_url == self.base_url
            jar = self.cookie_jar if is_current else CookieJar()
            source = self.source if is_current else "candidate"
            status = self._probe_base(
                base_url,
                jar,
                configured=is_current,
                source=source,
                timeout=timeout,
            )
            if is_current:
                if status["state"] == "expired" and any(True for _ in jar):
                    self.cookie_jar = CookieJar()
                    if self.source == "persisted":
                        self._save()
                    status["hasSessionCredential"] = False
                self._status = status
            return dict(status)

    async def login(
        self, url: Any, password: Any, timeout: float = 15.0
    ) -> dict[str, Any]:
        if not isinstance(password, str) or not password:
            raise RpcFault(-32602, "Password is required")
        if len(password.encode("utf-8")) > 65536:
            raise RpcFault(-32602, "Password is too large")
        return await asyncio.to_thread(self._login_sync, url, password, timeout)

    def _login_sync(
        self, url: Any, password: str, timeout: float
    ) -> dict[str, Any]:
        base_url = normalize_remote_url(url)
        with self._lock:
            jar = CookieJar()
            try:
                response = self._request(
                    base_url,
                    jar,
                    "POST",
                    "/api/auth/login",
                    {"password": password},
                    timeout,
                )
            except _RemoteAuthRequired as exc:
                status = self._make_status(
                    "expired",
                    configured=base_url == self.base_url,
                    url=base_url,
                    reachable=True,
                    auth_enabled=True,
                    message="Remote Hermes rejected the sign-in",
                    status_code=exc.status_code,
                )
                if base_url == self.base_url or not self.base_url:
                    self._status = status
                raise RemoteLoginFault("Remote Hermes rejected the sign-in", status) from None
            except _RemoteRedirectBlocked:
                status = self._make_status(
                    "error",
                    configured=base_url == self.base_url,
                    url=base_url,
                    reachable=True,
                    message="Remote Hermes attempted a cross-origin redirect",
                    error_kind="redirect",
                )
                raise RemoteLoginFault(status["message"], status, -32041) from None
            except _RemoteTransportError:
                status = self._make_status(
                    "error",
                    configured=base_url == self.base_url,
                    url=base_url,
                    reachable=False,
                    message="Remote Hermes is unreachable",
                    error_kind="offline",
                )
                raise RemoteLoginFault(status["message"], status, -32042) from None
            if response["status"] == 429:
                status = self._make_status(
                    "error",
                    configured=base_url == self.base_url,
                    url=base_url,
                    reachable=True,
                    message="Remote Hermes temporarily rate-limited sign-in",
                    error_kind="rate-limit",
                )
                raise RemoteLoginFault(status["message"], status, -32044)
            if not 200 <= response["status"] < 300:
                status = self._make_status(
                    "error",
                    configured=base_url == self.base_url,
                    url=base_url,
                    reachable=True,
                    message=f"Remote Hermes returned HTTP {response['status']}",
                    error_kind="http",
                    status_code=response["status"],
                )
                raise RemoteLoginFault(status["message"], status, -32041)
            value = self._json_response(response)
            if value.get("ok") is not True:
                status = self._make_status(
                    "expired",
                    configured=base_url == self.base_url,
                    url=base_url,
                    reachable=True,
                    auth_enabled=True,
                    message="Remote Hermes rejected the sign-in",
                )
                raise RemoteLoginFault(status["message"], status)
            status = self._probe_base(
                base_url,
                jar,
                configured=True,
                source="persisted",
                timeout=timeout,
            )
            if status["state"] != "connected":
                message = (
                    "Remote Hermes rejected the sign-in"
                    if status["state"] == "expired"
                    else status["message"]
                )
                raise RemoteLoginFault(message, status)
            self.base_url = base_url
            self.cookie_jar = jar
            self.source = "persisted"
            status["source"] = self.source
            status["hasSessionCredential"] = any(True for _ in jar)
            self._status = status
            self._save()
            return dict(status)

    async def logout(self, timeout: float = 10.0) -> dict[str, Any]:
        return await asyncio.to_thread(self._logout_sync, timeout)

    def _logout_sync(self, timeout: float) -> dict[str, Any]:
        with self._lock:
            remote_logout = False
            if self.base_url:
                try:
                    response = self._request(
                        self.base_url,
                        self.cookie_jar,
                        "POST",
                        "/api/auth/logout",
                        {},
                        timeout,
                    )
                    remote_logout = 200 <= response["status"] < 300
                except (
                    _RemoteAuthRequired,
                    _RemoteRedirectBlocked,
                    _RemoteTransportError,
                    RpcFault,
                ):
                    # Local credential removal is authoritative even when the
                    # remote session has already expired or is unreachable.
                    remote_logout = False
            self.cookie_jar = CookieJar()
            self._delete_file()
            self.base_url = self.environment_url
            self.source = "environment" if self.environment_url else "none"
            self._status = self._make_status(
                "disconnected",
                configured=bool(self.base_url),
                url=self.base_url,
                message=(
                    "Remote Hermes signed out"
                    if remote_logout
                    else "Saved remote session was removed"
                ),
            )
            result = dict(self._status)
            result["remoteLogout"] = remote_logout
            return result

    async def request_json(
        self,
        method: str,
        path: str,
        payload: dict[str, Any] | None = None,
        timeout: float = 30.0,
    ) -> dict[str, Any]:
        """Reusable authenticated request primitive for the remote adapter."""

        return await asyncio.to_thread(
            self._request_json_sync, method, path, payload, timeout
        )

    async def upload_file(
        self,
        path: str,
        fields: dict[str, str],
        filename: str,
        data: bytes,
        mime_type: str,
        timeout: float = 60.0,
    ) -> dict[str, Any]:
        """Upload one bounded file with the saved WebUI session cookie."""

        return await asyncio.to_thread(
            self._upload_file_sync,
            path,
            fields,
            filename,
            data,
            mime_type,
            timeout,
        )

    async def probe_multipart_route(
        self, path: str, timeout: float = 15.0
    ) -> int:
        """Return a multipart route's status after a fully consumed empty form."""

        return await asyncio.to_thread(
            self._probe_multipart_route_sync, path, timeout
        )

    def _probe_multipart_route_sync(self, path: str, timeout: float) -> int:
        boundary = "----HermesMenubarProbe" + uuid.uuid4().hex
        encoded = (
            f"--{boundary}\r\n"
            'Content-Disposition: form-data; name="session_id"\r\n\r\n'
            "\r\n"
            f"--{boundary}--\r\n"
        ).encode("ascii")
        with self._lock:
            if not self.base_url:
                raise RpcFault(-32040, "Remote Hermes is not configured")
            try:
                response = self._request(
                    self.base_url,
                    self.cookie_jar,
                    "POST",
                    path,
                    None,
                    timeout,
                    encoded_body=encoded,
                    content_type=f"multipart/form-data; boundary={boundary}",
                )
            except _RemoteAuthRequired as exc:
                status = self._expire_session_locked(exc.status_code)
                raise RemoteLoginFault(status["message"], status) from None
            except _RemoteRedirectBlocked:
                raise RpcFault(
                    -32041, "Remote Hermes attempted a cross-origin redirect"
                ) from None
            except _RemoteTransportError:
                raise RpcFault(-32042, "Remote Hermes is unreachable") from None
            if response["status"] == 401:
                status = self._expire_session_locked(401)
                raise RemoteLoginFault(status["message"], status)
            return int(response["status"])

    def _upload_file_sync(
        self,
        path: str,
        fields: dict[str, str],
        filename: str,
        data: bytes,
        mime_type: str,
        timeout: float,
    ) -> dict[str, Any]:
        if len(data) > MAX_REMOTE_ATTACHMENT_BYTES:
            raise RpcFault(-32602, "Attachment is larger than 20 MiB")
        safe_name = re.sub(r"[^A-Za-z0-9._-]", "_", Path(filename).name)[:200]
        if not safe_name or safe_name.strip(".") == "":
            safe_name = "attachment"
        boundary = "----HermesMenubar" + uuid.uuid4().hex
        chunks: list[bytes] = []
        for name, value in fields.items():
            safe_field = re.sub(r"[^A-Za-z0-9_-]", "", str(name))[:80]
            if not safe_field:
                continue
            chunks.extend([
                f"--{boundary}\r\n".encode("ascii"),
                (
                    f'Content-Disposition: form-data; name="{safe_field}"\r\n\r\n'
                ).encode("ascii"),
                str(value).encode("utf-8"),
                b"\r\n",
            ])
        chunks.extend([
            f"--{boundary}\r\n".encode("ascii"),
            (
                'Content-Disposition: form-data; name="file"; '
                f'filename="{safe_name}"\r\n'
            ).encode("ascii"),
            f"Content-Type: {mime_type or 'application/octet-stream'}\r\n\r\n".encode(
                "ascii", errors="replace"
            ),
            data,
            b"\r\n",
            f"--{boundary}--\r\n".encode("ascii"),
        ])
        encoded = b"".join(chunks)

        with self._lock:
            if not self.base_url:
                raise RpcFault(-32040, "Remote Hermes is not configured")
            try:
                response = self._request(
                    self.base_url,
                    self.cookie_jar,
                    "POST",
                    path,
                    None,
                    timeout,
                    encoded_body=encoded,
                    content_type=f"multipart/form-data; boundary={boundary}",
                )
            except _RemoteAuthRequired as exc:
                status = self._expire_session_locked(exc.status_code)
                raise RemoteLoginFault(status["message"], status) from None
            except _RemoteRedirectBlocked:
                raise RpcFault(
                    -32041, "Remote Hermes attempted a cross-origin redirect"
                ) from None
            except _RemoteTransportError:
                raise RpcFault(-32042, "Remote Hermes is unreachable") from None
            if response["status"] == 401:
                status = self._expire_session_locked(401)
                raise RemoteLoginFault(status["message"], status)
            if not 200 <= response["status"] < 300:
                raise self._http_error_fault(response)
            return self._json_response(response)

    def _request_json_sync(
        self,
        method: str,
        path: str,
        payload: dict[str, Any] | None,
        timeout: float,
    ) -> dict[str, Any]:
        with self._lock:
            if not self.base_url:
                raise RpcFault(-32040, "Remote Hermes is not configured")
            try:
                response = self._request(
                    self.base_url,
                    self.cookie_jar,
                    method,
                    path,
                    payload,
                    timeout,
                )
            except _RemoteAuthRequired as exc:
                self.cookie_jar = CookieJar()
                if self.source == "persisted":
                    self._save()
                self._status = self._make_status(
                    "expired",
                    configured=True,
                    url=self.base_url,
                    reachable=True,
                    auth_enabled=True,
                    message="Remote Hermes authentication is required",
                    status_code=exc.status_code,
                )
                raise RemoteLoginFault(self._status["message"], self._status) from None
            except _RemoteRedirectBlocked:
                raise RpcFault(
                    -32041, "Remote Hermes attempted a cross-origin redirect"
                ) from None
            except _RemoteTransportError:
                if method.upper() == "POST" and path == "/api/chat/start":
                    raise AmbiguousDelivery("remote prompt.submit") from None
                raise RpcFault(-32042, "Remote Hermes is unreachable") from None
            if response["status"] == 401:
                self.cookie_jar = CookieJar()
                if self.source == "persisted":
                    self._save()
                self._status = self._make_status(
                    "expired",
                    configured=True,
                    url=self.base_url,
                    reachable=True,
                    auth_enabled=True,
                    message="Remote Hermes authentication is required",
                )
                raise RemoteLoginFault(self._status["message"], self._status)
            if not 200 <= response["status"] < 300:
                raise self._http_error_fault(response)
            return self._json_response(response)

    async def probe_contract(self, timeout: float = 10.0) -> dict[str, Any]:
        """Read the WebUI's non-streaming SSE capability probe and server tag."""

        return await asyncio.to_thread(self._probe_contract_sync, timeout)

    def _probe_contract_sync(self, timeout: float) -> dict[str, Any]:
        with self._lock:
            if not self.base_url:
                raise RpcFault(-32040, "Remote Hermes is not configured")
            try:
                response = self._request(
                    self.base_url,
                    self.cookie_jar,
                    "GET",
                    "/api/sessions/gateway/stream?probe=1",
                    None,
                    timeout,
                )
            except _RemoteAuthRequired as exc:
                status = self._expire_session_locked(exc.status_code)
                raise RemoteLoginFault(status["message"], status) from None
            except _RemoteRedirectBlocked:
                raise RpcFault(
                    -32041, "Remote Hermes attempted a cross-origin redirect"
                ) from None
            except _RemoteTransportError:
                raise RpcFault(-32042, "Remote Hermes is unreachable") from None

            server = re.sub(
                r"[^A-Za-z0-9._/ +()-]", "", str(response["headers"].get("Server", ""))
            ).strip()[:128]
            try:
                value = self._json_response(response)
            except RpcFault:
                value = {}
            session_path = str(value.get("session_stream_path") or "")
            if not session_path.startswith("/api/") or "://" in session_path:
                session_path = "/api/session/stream"
            try:
                fallback_poll_ms = int(value.get("fallback_poll_ms") or 30000)
            except (TypeError, ValueError):
                fallback_poll_ms = 30000
            return {
                "checked": True,
                "probeStatus": int(response.get("status") or 0),
                "server": server,
                "gatewaySessions": value.get("ok") is True,
                "gatewayWatcher": value.get("watcher_running") is True,
                "sessionStream": value.get("session_stream_available") is True,
                "sessionStreamPath": session_path,
                "fallbackPollMs": max(5000, min(300000, fallback_poll_ms)),
            }

    def _expire_session_locked(self, status_code: int = 401) -> dict[str, Any]:
        self.cookie_jar = CookieJar()
        if self.source == "persisted":
            self._save()
        self._status = self._make_status(
            "expired",
            configured=bool(self.base_url),
            url=self.base_url,
            reachable=True,
            auth_enabled=True,
            message="Remote Hermes authentication is required",
            status_code=status_code,
        )
        return dict(self._status)

    def open_sse(
        self,
        path: str,
        *,
        last_event_id: str = "",
        timeout: float = 45.0,
    ) -> Any:
        """Open one authenticated, same-origin WebUI SSE response.

        This synchronous primitive is intended to be called through
        ``asyncio.to_thread``. The caller owns and must close the returned
        response. Cookie values and redirect destinations never leave the
        bridge process.
        """

        with self._lock:
            if not self.base_url:
                raise RpcFault(-32040, "Remote Hermes is not configured")
            if not isinstance(path, str) or not path.startswith("/") or "://" in path:
                raise RpcFault(-32602, "Remote Hermes API path is invalid")
            headers = {
                "Accept": "text/event-stream",
                "Cache-Control": "no-cache",
                "User-Agent": "cybexos-hermes-menubar-bridge/1",
            }
            if last_event_id:
                headers["Last-Event-ID"] = str(last_event_id)[:1024]
            redirect_handler = _SameOriginRedirectHandler(
                _remote_origin(self.base_url)
            )
            opener = build_opener(
                redirect_handler, HTTPCookieProcessor(self.cookie_jar)
            )
            request = Request(
                f"{self.base_url}{path}", headers=headers, method="GET"
            )
            try:
                response = opener.open(request, timeout=timeout)
            except _RemoteAuthRequired as exc:
                status = self._expire_session_locked(exc.status_code)
                raise RemoteLoginFault(status["message"], status) from None
            except _RemoteRedirectBlocked:
                raise RpcFault(
                    -32041, "Remote Hermes attempted a cross-origin redirect"
                ) from None
            except HTTPError as exc:
                status_code = int(exc.code)
                with suppress(Exception):
                    exc.close()
                if status_code == 401:
                    status = self._expire_session_locked(status_code)
                    raise RemoteLoginFault(status["message"], status) from None
                raise RpcFault(
                    -32041, f"Remote Hermes returned HTTP {status_code}"
                ) from None
            except (URLError, TimeoutError, OSError):
                raise RpcFault(-32042, "Remote Hermes stream is unreachable") from None

            status_code = int(getattr(response, "status", 0) or 0)
            content_type = str(response.headers.get("Content-Type", "")).lower()
            final_url = str(response.geturl() or "")
            if _is_login_url(final_url) or "text/html" in content_type:
                with suppress(Exception):
                    response.close()
                status = self._expire_session_locked(status_code or 302)
                raise RemoteLoginFault(status["message"], status)
            if status_code != 200 or "text/event-stream" not in content_type:
                with suppress(Exception):
                    response.close()
                raise RpcFault(
                    -32041, "Remote Hermes returned an invalid event stream"
                )
            return response

    def authenticated_headers(self, path: str = "/") -> dict[str, str]:
        """Return an origin-scoped Cookie header for an internal SSE adapter.

        The returned value is a credential and must never be sent downstream or
        logged. Accepting only an absolute-path reference prevents callers from
        accidentally forwarding it to another origin.
        """

        with self._lock:
            if not self.base_url:
                raise RpcFault(-32040, "Remote Hermes is not configured")
            if not isinstance(path, str) or not path.startswith("/") or "://" in path:
                raise RpcFault(-32602, "Remote Hermes API path is invalid")
            request = Request(f"{self.base_url}{path}")
            self.cookie_jar.add_cookie_header(request)
            cookie = request.get_header("Cookie")
            return {"Cookie": cookie} if cookie else {}


def default_conversations() -> list[dict[str, Any]]:
    # New chat is a client-side virtual selection, not a persisted session.
    # Historical rows are hydrated from the WebUI's native /api/sessions list.
    return []


class ConversationRegistry:
    """Small atomic JSON registry; prompts and Hermes credentials never enter it."""

    def __init__(self, path: Path):
        self.path = path
        self.conversations: dict[str, dict[str, Any]] = {}
        self.selected_conversation_id = ""
        self._load()

    def _load(self) -> None:
        document: dict[str, Any] | None = None
        try:
            document = json.loads(self.path.read_text(encoding="utf-8"))
        except FileNotFoundError:
            pass
        except (OSError, json.JSONDecodeError, TypeError) as exc:
            LOG.error("could not load conversation registry %s: %s", self.path, exc)

        rows = document.get("conversations") if isinstance(document, dict) else None
        if isinstance(rows, list):
            for row in rows:
                conversation = self._coerce_conversation(row)
                if conversation is not None and conversation["id"] not in self.conversations:
                    self.conversations[conversation["id"]] = conversation

        # Selection intentionally never survives a bridge restart. The widget
        # always opens on a fresh chat while the list remains available.
        self.selected_conversation_id = ""

    @staticmethod
    def _coerce_conversation(row: Any) -> dict[str, Any] | None:
        if not isinstance(row, dict):
            return None
        conversation_id = str(
            row.get("session_id") or row.get("sessionId") or row.get("id") or ""
        ).strip()
        title = str(row.get("title") or row.get("name") or "Untitled chat").strip()
        if not CONVERSATION_ID_PATTERN.fullmatch(conversation_id):
            return None
        status = str(row.get("status") or "idle")
        if status not in {
            "idle",
            "working",
            "waiting",
            "done",
            "error",
            "offline",
            "reconnecting",
        }:
            status = "idle"
        stored_session_id = str(
            row.get("stored_session_id") or row.get("storedSessionId") or ""
        )[:256]
        remote_origin = str(
            row.get("remote_origin") or row.get("remoteOrigin") or ""
        )[:2048]
        remote_session_id = str(
            row.get("remote_session_id") or row.get("remoteSessionId") or ""
        )[:256]
        return {
            "id": conversation_id,
            "name": title[:160],
            "title": title[:160] or "Untitled chat",
            "brief": str(row.get("brief") or "")[:4000],
            "profile": str(row.get("profile") or "")[:128],
            "cwd": str(row.get("cwd") or "")[:4096],
            "stored_session_id": stored_session_id,
            "remote_origin": remote_origin,
            "remote_session_id": remote_session_id,
            # Missing on old registries: be conservative and assume a durable
            # id may contain user history. Only known-empty lazy sessions are
            # safe to recreate after a session-not-found resume.
            "has_messages": bool(
                row.get("has_messages", bool(stored_session_id or remote_session_id))
            ),
            "status": status,
            "status_text": str(row.get("status_text") or "Ready")[:240],
            "unread": bool(row.get("unread", False)),
            "updated_at": str(row.get("updated_at") or utc_now()),
            "created_at": str(row.get("created_at") or ""),
            "model": str(row.get("model") or "")[:256],
            "model_provider": str(
                row.get("model_provider") or row.get("modelProvider") or ""
            )[:128],
            "source": str(
                row.get("source")
                or row.get("source_label")
                or row.get("sourceLabel")
                or row.get("session_source")
                or row.get("sessionSource")
                or ""
            )[:128],
            "read_only": bool(row.get("read_only", row.get("readOnly", False))),
            "message_count": ConversationRegistry._message_count(
                row.get("message_count")
            ),
        }

    @staticmethod
    def _message_count(value: Any) -> int:
        try:
            return max(0, int(value or 0))
        except (TypeError, ValueError, OverflowError):
            return 0

    def save(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        with suppress(OSError):
            os.chmod(self.path.parent, 0o700)
        document = {
            "version": BRIDGE_VERSION,
            "selected_conversation_id": self.selected_conversation_id,
            "conversations": list(self.conversations.values()),
        }
        temporary = self.path.with_name(f".{self.path.name}.tmp.{os.getpid()}")
        descriptor = os.open(
            temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600
        )
        try:
            with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
                json.dump(document, stream, ensure_ascii=False, indent=2)
                stream.write("\n")
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, self.path)
            os.chmod(self.path, 0o600)
        finally:
            with suppress(FileNotFoundError):
                temporary.unlink()


@dataclass(eq=False)
class LocalClient:
    websocket: ServerConnection
    send_lock: asyncio.Lock = field(default_factory=asyncio.Lock)
    tasks: set[asyncio.Task[Any]] = field(default_factory=set)

    async def send(self, frame: dict[str, Any]) -> None:
        async with self.send_lock:
            await self.websocket.send(json_frame(frame))


@dataclass
class PendingUpstream:
    method: str
    future: asyncio.Future[Any]
    written: bool = False


class HermesGateway:
    """Authenticated, reconnecting JSON-RPC client for ``hermes serve``."""

    def __init__(
        self,
        base_url: str,
        on_event: Callable[[dict[str, Any]], Awaitable[None]],
        on_state: Callable[[str, str], Awaitable[None]],
        on_ready: Callable[[str], Awaitable[None]],
    ):
        self.base_url = base_url.rstrip("/")
        self.on_event = on_event
        self.on_state = on_state
        self.on_ready = on_ready
        self.websocket: ClientConnection | None = None
        self.connected = asyncio.Event()
        self.ready_epoch = ""
        self._pending: dict[str, PendingUpstream] = {}
        self._next_id = 0
        self._send_lock = asyncio.Lock()
        self._stop = asyncio.Event()
        self._runner: asyncio.Task[Any] | None = None

    def start(self) -> None:
        if self._runner is None:
            self._runner = asyncio.create_task(self._run(), name="hermes-upstream")

    async def stop(self) -> None:
        self._stop.set()
        websocket = self.websocket
        if websocket is not None:
            with suppress(Exception):
                await websocket.close(code=1001, reason="bridge stopping")
        if self._runner is not None:
            self._runner.cancel()
            with suppress(asyncio.CancelledError):
                await self._runner

    async def request(
        self, method: str, params: dict[str, Any] | None = None, timeout: float = 30.0
    ) -> Any:
        if not self.connected.is_set() or self.websocket is None:
            raise UpstreamUnavailable()
        self._next_id += 1
        request_id = f"menubar-{self._next_id}"
        future = asyncio.get_running_loop().create_future()
        pending = PendingUpstream(method=method, future=future)
        self._pending[request_id] = pending
        frame = {
            "jsonrpc": "2.0",
            "id": request_id,
            "method": method,
            "params": params or {},
        }
        try:
            async with self._send_lock:
                websocket = self.websocket
                if websocket is None:
                    raise UpstreamUnavailable()
                await websocket.send(json_frame(frame))
                pending.written = True
            return await asyncio.wait_for(future, timeout=timeout)
        except asyncio.TimeoutError as exc:
            self._pending.pop(request_id, None)
            if method == "prompt.submit" and pending.written:
                raise AmbiguousDelivery(method) from exc
            raise RpcFault(
                -32012,
                f"Hermes did not answer {method} within {int(timeout)} seconds",
                {"method": method},
            ) from exc
        except ConnectionClosed as exc:
            self._pending.pop(request_id, None)
            if pending.written:
                raise AmbiguousDelivery(method) from exc
            raise UpstreamUnavailable() from exc
        finally:
            self._pending.pop(request_id, None)

    async def api_request(
        self,
        method: str,
        path: str,
        payload: dict[str, Any] | None = None,
        timeout: float = 20.0,
    ) -> Any:
        """Call an authenticated Hermes dashboard API without exposing its token.

        Provider setup is a dashboard REST API rather than a gateway RPC.  The
        bridge obtains the same private session token it already uses for the
        upstream WebSocket and keeps both that token and submitted credentials
        out of downstream responses and logs.
        """
        return await asyncio.to_thread(
            self._api_request_sync, method, path, payload, timeout
        )

    def _api_request_sync(
        self,
        method: str,
        path: str,
        payload: dict[str, Any] | None,
        timeout: float,
    ) -> Any:
        if not path.startswith("/api/") or "://" in path:
            raise RpcFault(-32602, "invalid Hermes API path")
        try:
            token = self._fetch_token()
        except Exception as exc:
            raise UpstreamUnavailable("Hermes provider API is unavailable") from exc
        body = (
            json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode(
                "utf-8"
            )
            if payload is not None
            else None
        )
        headers = {
            "Accept": "application/json",
            "User-Agent": "cybexos-hermes-menubar-bridge/1",
            "X-Hermes-Session-Token": token,
        }
        if body is not None:
            headers["Content-Type"] = "application/json"
        request = Request(
            f"{self.base_url}{path}",
            data=body,
            method=method.upper(),
            headers=headers,
        )
        try:
            with urlopen(request, timeout=timeout) as response:
                raw = response.read(MAX_PROVIDER_RESPONSE + 1)
        except HTTPError as exc:
            raw = exc.read(MAX_PROVIDER_RESPONSE + 1)
            message = self._api_error_message(raw)
            raise RpcFault(
                -32030,
                message or f"Hermes provider API returned HTTP {exc.code}",
            ) from exc
        except (URLError, TimeoutError, OSError) as exc:
            raise UpstreamUnavailable("Hermes provider API is unavailable") from exc
        if len(raw) > MAX_PROVIDER_RESPONSE:
            raise RpcFault(-32030, "Hermes provider API response is too large")
        if not raw:
            return {}
        try:
            return json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError, TypeError) as exc:
            raise RpcFault(-32030, "Hermes provider API returned invalid JSON") from exc

    @staticmethod
    def _api_error_message(raw: bytes) -> str:
        try:
            value = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError, TypeError):
            return ""
        if not isinstance(value, dict):
            return ""
        detail = value.get("detail") or value.get("message") or value.get("error")
        return str(detail)[:500] if isinstance(detail, (str, int, float)) else ""

    async def _run(self) -> None:
        backoff = 0.5
        while not self._stop.is_set():
            await self.on_state("connecting", "Connecting to Hermes…")
            receiver: asyncio.Task[Any] | None = None
            heartbeat: asyncio.Task[Any] | None = None
            try:
                token = await asyncio.to_thread(self._fetch_token)
                websocket_url = self._websocket_url(token)
                async with websockets.connect(
                    websocket_url,
                    open_timeout=15,
                    close_timeout=5,
                    max_size=MAX_UPSTREAM_MESSAGE,
                    ping_interval=20,
                    ping_timeout=45,
                ) as websocket:
                    self.websocket = websocket
                    receiver = asyncio.create_task(
                        self._receive(websocket), name="hermes-upstream-receive"
                    )
                    await asyncio.wait_for(self.connected.wait(), timeout=30)
                    backoff = 0.5
                    await self.on_state("connected", "Hermes connected")
                    ready_task = asyncio.create_task(
                        self.on_ready(self.ready_epoch), name="hermes-reconcile"
                    )
                    ready_task.add_done_callback(self._log_background_failure)
                    heartbeat = asyncio.create_task(
                        self._heartbeat(websocket), name="hermes-upstream-heartbeat"
                    )
                    await receiver
            except asyncio.CancelledError:
                raise
            except Exception as exc:
                if not self._stop.is_set():
                    LOG.warning("Hermes connection unavailable: %s", exc)
            finally:
                self.connected.clear()
                self.websocket = None
                for task in (receiver, heartbeat):
                    if task is not None and not task.done():
                        task.cancel()
                self._reject_pending()

            if self._stop.is_set():
                break
            await self.on_state("reconnecting", "Reconnecting to Hermes…")
            try:
                await asyncio.wait_for(
                    self._stop.wait(), timeout=backoff + random.random() * 0.25
                )
            except asyncio.TimeoutError:
                pass
            backoff = min(backoff * 2, 15.0)

    @staticmethod
    def _log_background_failure(task: asyncio.Task[Any]) -> None:
        if task.cancelled():
            return
        exc = task.exception()
        if exc is not None:
            LOG.error("Hermes reconciliation failed: %s", exc)

    def _fetch_token(self) -> str:
        configured = os.environ.get("HERMES_DASHBOARD_SESSION_TOKEN", "").strip()
        if configured:
            return configured
        request = Request(
            f"{self.base_url}/",
            headers={"User-Agent": "cybexos-hermes-menubar-bridge/1"},
        )
        with urlopen(request, timeout=10) as response:
            body = response.read(1024 * 1024).decode("utf-8", errors="replace")
        match = TOKEN_PATTERN.search(body)
        if not match:
            raise RuntimeError("Hermes headless token was not present at the root URL")
        token = json.loads(match.group(1))
        if not isinstance(token, str) or not token:
            raise RuntimeError("Hermes returned an invalid headless token")
        return token

    def _websocket_url(self, token: str) -> str:
        parsed = urlparse(self.base_url)
        if parsed.scheme not in {"http", "https"}:
            raise RuntimeError("Hermes upstream must use http:// or https://")
        scheme = "wss" if parsed.scheme == "https" else "ws"
        path = f"{parsed.path.rstrip('/')}/api/ws"
        return urlunparse(
            (scheme, parsed.netloc, path, "", f"token={quote(token, safe='')}", "")
        )

    async def _receive(self, websocket: ClientConnection) -> None:
        async for raw in websocket:
            if not isinstance(raw, str):
                continue
            try:
                frame = json.loads(raw)
            except (json.JSONDecodeError, TypeError):
                LOG.warning("Hermes sent malformed JSON")
                continue
            if not isinstance(frame, dict):
                continue
            request_id = frame.get("id")
            if request_id is not None:
                pending = self._pending.get(str(request_id))
                if pending is None or pending.future.done():
                    continue
                error = frame.get("error")
                if isinstance(error, dict):
                    pending.future.set_exception(
                        RpcFault(
                            int(error.get("code") or -32000),
                            str(error.get("message") or "Hermes RPC failed"),
                            error.get("data"),
                        )
                    )
                else:
                    pending.future.set_result(frame.get("result"))
                continue
            if frame.get("method") != "event" or not isinstance(
                frame.get("params"), dict
            ):
                continue
            event = frame["params"]
            if event.get("type") == "gateway.ready":
                payload = event.get("payload")
                self.ready_epoch = (
                    str(payload.get("replay_epoch") or "")
                    if isinstance(payload, dict)
                    else ""
                )
                self.connected.set()
            await self.on_event(event)

    async def _heartbeat(self, websocket: ClientConnection) -> None:
        while websocket is self.websocket and not self._stop.is_set():
            await asyncio.sleep(15)
            try:
                await self.request("gateway.ping", {}, timeout=10)
            except RpcFault:
                with suppress(Exception):
                    await websocket.close(code=1011, reason="heartbeat failed")
                return

    def _reject_pending(self) -> None:
        for pending in list(self._pending.values()):
            if pending.future.done():
                continue
            if pending.written:
                pending.future.set_exception(AmbiguousDelivery(pending.method))
            else:
                pending.future.set_exception(UpstreamUnavailable())


class HermesBridge:
    def __init__(
        self,
        registry: ConversationRegistry,
        upstream_url: str,
        remote_auth_path: Path | None = None,
        local_backend_enabled: bool = True,
    ):
        self.registry = registry
        self.clients: set[LocalClient] = set()
        self.local_backend_enabled = local_backend_enabled
        self.connection = "offline" if local_backend_enabled else "disabled"
        self.connection_text = (
            "Hermes offline" if local_backend_enabled else "Remote-only mode"
        )
        self.runtime_by_conversation: dict[str, str] = {}
        self.conversation_by_runtime: dict[str, str] = {}
        self.conversation_by_remote_session: dict[str, str] = {}
        self.remote_stream_by_conversation: dict[str, str] = {}
        self.remote_stream_tasks: dict[str, asyncio.Task[Any]] = {}
        self.remote_stream_responses: dict[str, Any] = {}
        self.remote_stream_event_ids: dict[str, str] = {}
        self.remote_stream_text: dict[str, str] = {}
        self.remote_stream_reasoning: dict[str, str] = {}
        self.remote_stream_completed: dict[str, str] = {}
        self.remote_stream_response_lock = threading.Lock()
        self.remote_observer_tasks: dict[str, asyncio.Task[Any]] = {}
        self.remote_observer_responses: dict[str, Any] = {}
        self.remote_observer_response_lock = threading.Lock()
        self.remote_observed_conversation_id = ""
        self.remote_contract: dict[str, Any] = {
            "checked": False,
            "transport": "webui",
            "contractVersion": 1,
            "historyPagination": False,
            "chatEventReplay": True,
            "globalSessionEvents": False,
            "sessionStream": False,
            "sessionRunEvents": False,
            "gatewaySessions": False,
            "attachments": False,
            "branches": False,
            "nativeBranches": False,
            "duplicateSessions": False,
            "messageEditing": False,
            "regeneration": False,
            "modelSelection": False,
            "reasoningEffort": False,
            "eventCatalog": [
                "token",
                "reasoning",
                "tool",
                "tool_complete",
                "interim_assistant",
                "approval",
                "clarify",
                "compressing",
                "compressed",
                "title",
                "title_status",
                "warning",
                "apperror",
                "cancel",
                "done",
                "stream_end",
                "metering",
                "context_status",
                "goal",
                "goal_continue",
                "pending_steer_leftover",
                "state_saved",
                "todo_state",
            ],
        }
        self.watermarks: dict[str, int] = {}
        self.replay_epoch = ""
        self.conversation_locks: dict[str, asyncio.Lock] = {}
        self.provider_state: dict[str, Any] = {
            "checked": not local_backend_enabled,
            "ready": False,
            "setupRequired": False,
            "provider": "",
            "providerName": "",
            "model": "",
            "error": "",
            "updatedAt": utc_now() if not local_backend_enabled else "",
        }
        self.provider_checked_at = 0.0
        self.provider_lock = asyncio.Lock()
        self.remote_auth = RemoteWebUIAuth(
            remote_auth_path
            if remote_auth_path is not None
            else registry.path.with_name("remote-webui-auth.json")
        )
        self.gateway = HermesGateway(
            upstream_url,
            on_event=self.handle_upstream_event,
            on_state=self.handle_upstream_state,
            on_ready=self.reconcile,
        )

    def start(self) -> None:
        if self.local_backend_enabled:
            self.gateway.start()

    async def stop(self) -> None:
        await self.stop_remote_observers()
        await self.stop_remote_streams()
        await self.gateway.stop()
        for client in list(self.clients):
            with suppress(Exception):
                await client.websocket.close(code=1001, reason="bridge stopping")

    def public_conversation(self, conversation: dict[str, Any]) -> dict[str, Any]:
        # A WebUI conversation is identified directly by its native session id.
        conversation_id = conversation["id"]
        remote_mode = bool(self.remote_auth.base_url)
        remote_session = (
            conversation["remote_session_id"]
            if conversation["remote_origin"] == self.remote_auth.base_url
            else ""
        )
        runtime = remote_session if remote_mode else (
            self.runtime_by_conversation.get(conversation_id) or ""
        )
        return {
            "id": conversation_id,
            "sessionId": runtime,
            "title": conversation["title"],
            "profile": conversation["profile"] or None,
            "model": conversation.get("model") or None,
            "modelProvider": conversation.get("model_provider") or None,
            "workspace": conversation.get("cwd") or None,
            "source": conversation.get("source") or None,
            "readOnly": bool(conversation.get("read_only", False)),
            "messageCount": int(conversation.get("message_count", 0)),
            "unread": 1 if conversation["unread"] else 0,
            "status": conversation["status"],
            "statusText": conversation["status_text"],
            "updatedAt": conversation["updated_at"],
            "createdAt": conversation.get("created_at") or None,
            "upstreamSessionId": runtime or None,
            "backendMode": (
                "remote-webui"
                if remote_mode
                else "local-gateway" if self.local_backend_enabled else "remote-required"
            ),
            "remoteOrigin": self.remote_auth.base_url if remote_mode else None,
        }

    def snapshot(self) -> dict[str, Any]:
        return {
            "version": BRIDGE_VERSION,
            "connection": self.connection,
            "connectionText": self.connection_text,
            "agentReady": (
                self.remote_auth.status.get("state") == "connected"
                if self.remote_auth.base_url
                else bool(self.provider_state["ready"])
            ),
            "providerStatus": dict(self.provider_state),
            "remoteStatus": self.remote_auth.status,
            "remoteContract": dict(self.remote_contract),
            "selectedConversationId": self.registry.selected_conversation_id,
            "conversations": [
                self.public_conversation(conversation)
                for conversation in self.registry.conversations.values()
            ],
        }

    def bridge_capabilities(self) -> dict[str, Any]:
        remote = self.remote_contract
        return {
            "conversations": True,
            "streaming": True,
            "tools": True,
            "requests": True,
            "eventReplay": True,
            "historyPagination": remote.get("historyPagination") is True,
            "sessionEvents": remote.get("sessionStream") is True,
            "globalSessionEvents": remote.get("globalSessionEvents") is True,
            "reasoning": True,
            "goals": True,
            "todos": True,
            "usage": True,
            "contextStatus": True,
            "attachments": remote.get("attachments") is True,
            "branches": remote.get("branches") is True,
            "messageEditing": remote.get("messageEditing") is True,
            "regeneration": remote.get("regeneration") is True,
            "modelSelection": remote.get("modelSelection") is True,
            "reasoningEffort": remote.get("reasoningEffort") is True,
            "rawProxy": self.local_backend_enabled,
            "providerSetup": self.local_backend_enabled,
            "localBackend": self.local_backend_enabled,
            "remoteWebUIAuth": True,
        }

    def bridge_features(self) -> list[str]:
        features = [
            "conversations",
            "history",
            "streaming",
            "tool-progress",
            "interactive-requests",
            "event-replay",
            "remote-webui-auth",
            "structured-transcript",
            "session-state",
        ]
        if self.remote_contract.get("historyPagination") is True:
            features.append("history-pagination")
        if self.remote_contract.get("sessionStream") is True:
            features.append("persistent-session-events")
        if self.remote_contract.get("globalSessionEvents") is True:
            features.append("session-list-events")
        for enabled, feature in (
            (self.remote_contract.get("attachments"), "attachments"),
            (self.remote_contract.get("branches"), "session-branches"),
            (self.remote_contract.get("messageEditing"), "message-editing"),
            (self.remote_contract.get("regeneration"), "regeneration"),
            (self.remote_contract.get("modelSelection"), "model-selection"),
            (self.remote_contract.get("reasoningEffort"), "reasoning-effort"),
        ):
            if enabled is True:
                features.append(feature)
        if self.local_backend_enabled:
            features.extend(
                ["raw-proxy", "provider-readiness", "custom-provider-setup"]
            )
        return features

    async def client_handler(self, websocket: ServerConnection) -> None:
        request_path = getattr(getattr(websocket, "request", None), "path", "")
        if request_path.split("?", 1)[0] != DEFAULT_PATH:
            await websocket.close(code=1008, reason="use /ws")
            return
        remote = getattr(websocket, "remote_address", None)
        if remote and not is_loopback(str(remote[0])):
            await websocket.close(code=1008, reason="loopback clients only")
            return

        client = LocalClient(websocket)
        self.clients.add(client)
        try:
            async for raw in websocket:
                if not isinstance(raw, str):
                    continue
                try:
                    frame = json.loads(raw)
                except (json.JSONDecodeError, TypeError):
                    await client.send(
                        rpc_error(None, RpcFault(-32700, "Invalid JSON"))
                    )
                    continue
                task = asyncio.create_task(
                    self._serve_client_frame(client, frame),
                    name="hermes-local-request",
                )
                client.tasks.add(task)
                task.add_done_callback(client.tasks.discard)
        except ConnectionClosed:
            pass
        finally:
            self.clients.discard(client)
            for task in list(client.tasks):
                task.cancel()

    async def _serve_client_frame(self, client: LocalClient, frame: Any) -> None:
        if not isinstance(frame, dict):
            await client.send(rpc_error(None, RpcFault(-32600, "Invalid request")))
            return
        request_id = frame.get("id")
        method = frame.get("method")
        params = frame.get("params", {})
        if not isinstance(method, str) or not method:
            await client.send(
                rpc_error(request_id, RpcFault(-32600, "method is required"))
            )
            return
        if not isinstance(params, dict):
            await client.send(
                rpc_error(request_id, RpcFault(-32602, "params must be an object"))
            )
            return
        try:
            result = await self.dispatch(method, params)
            if request_id is not None:
                await client.send(rpc_result(request_id, result))
        except RpcFault as fault:
            if request_id is not None:
                with suppress(ConnectionClosed):
                    await client.send(rpc_error(request_id, fault))
        except Exception:
            LOG.exception("local RPC %s failed", method)
            if request_id is not None:
                with suppress(ConnectionClosed):
                    await client.send(
                        rpc_error(request_id, RpcFault(-32603, "Internal error"))
                    )

    async def dispatch(self, method: str, params: dict[str, Any]) -> Any:
        if method == "bridge.hello":
            provider_status = await self.refresh_provider_status()
            return {
                **self.snapshot(),
                "server": "cybexos-hermes-menubar-bridge",
                "bridgeVersion": str(BRIDGE_VERSION),
                "backendStatus": self.connection,
                "capabilities": self.bridge_capabilities(),
                "models": [],
                "features": self.bridge_features(),
                "agentReady": (
                    self.remote_auth.status.get("state") == "connected"
                    if self.remote_auth.base_url
                    else bool(provider_status["ready"])
                ),
                "providerStatus": provider_status,
                "remoteStatus": self.remote_auth.status,
            }
        if method == "bridge.ping":
            return {
                "ok": True,
                "time": utc_now(),
                "connection": self.connection,
            }
        if method in {"bridge.snapshot", "state.get"}:
            return self.snapshot()
        if method in {"remote.status", "webui.auth.status", "auth.status"}:
            if params.get("probe") is False:
                return self.remote_auth.status
            previous = self.remote_auth.status
            status = await self.remote_auth.probe(params.get("url"))
            candidate = bool(params.get("url")) and status["url"] != self.remote_auth.base_url
            if not candidate:
                await self.publish_remote_status(status, previous)
                if status.get("state") == "connected":
                    with suppress(RpcFault, RemoteLoginFault):
                        await self.probe_remote_contract()
                    await self.start_remote_observers()
            return status
        if method in {"remote.probe", "webui.auth.probe", "auth.probe"}:
            previous = self.remote_auth.status
            status = await self.remote_auth.probe(params.get("url"))
            candidate = bool(params.get("url")) and status["url"] != self.remote_auth.base_url
            if not candidate:
                await self.publish_remote_status(status, previous)
            return status
        if method in {"remote.login", "webui.auth.login", "auth.login"}:
            previous = self.remote_auth.status
            connecting = self.remote_auth.connecting_status(
                "Signing in to remote Hermes…", params.get("url")
            )
            await self.publish_remote_status(connecting, previous)
            try:
                status = await self.remote_auth.login(
                    params.get("url"), params.get("password")
                )
            except RemoteLoginFault as fault:
                failure = fault.data if isinstance(fault.data, dict) else {
                    **self.remote_auth.status,
                    "state": "error",
                    "error": fault.message,
                    "message": fault.message,
                }
                await self.publish_remote_status(failure, connecting)
                raise
            await self.refresh_remote_conversations()
            with suppress(RpcFault, RemoteLoginFault):
                await self.probe_remote_contract()
            await self.start_remote_observers()
            await self.publish_remote_status(status, connecting)
            return status
        if method in {"remote.logout", "webui.auth.logout", "auth.logout"}:
            previous = self.remote_auth.status
            await self.stop_remote_observers()
            await self.stop_remote_streams()
            status = await self.remote_auth.logout()
            await self.publish_remote_status(status, previous)
            return status
        if method == "provider.status":
            return await self.refresh_provider_status(
                force=params.get("force") is True
            )
        if method == "provider.custom.validate":
            return await self.validate_custom_provider(params)
        if method == "provider.custom.configure":
            return await self.configure_custom_provider(params)
        if method == "models.catalog":
            if self.remote_auth.base_url:
                return await self.remote_model_catalog()
            return {"groups": [], "defaultModel": self.provider_state.get("model", ""),
                    "activeProvider": self.provider_state.get("provider", "")}
        if method == "reasoning.get":
            if not self.remote_auth.base_url:
                raise RpcFault(-32601, "Reasoning controls require a remote Hermes WebUI")
            return await self.remote_reasoning_state(params)
        if method == "reasoning.set":
            if not self.remote_auth.base_url:
                raise RpcFault(-32601, "Reasoning controls require a remote Hermes WebUI")
            effort = str(params.get("effort") or "").strip().lower()
            if effort not in {"", "none", "minimal", "low", "medium", "high",
                              "xhigh", "max", "ultra"}:
                raise RpcFault(-32602, "Unsupported reasoning effort")
            body: dict[str, Any] = {"effort": effort}
            model = params.get("model")
            provider = params.get("modelProvider", params.get("model_provider",
                                                              params.get("provider")))
            if isinstance(model, str) and model.strip():
                body["model"] = model.strip()[:256]
            if isinstance(provider, str) and provider.strip():
                body["provider"] = provider.strip()[:128]
            result = await self.remote_request(
                "POST", "/api/reasoning", body, timeout=30
            )
            state = self.sanitize_remote_reasoning(result)
            await self.update_remote_contract(reasoningEffort=len(state["options"]) > 1)
            return state
        if method == "conversations.list":
            if (
                self.remote_auth.base_url
                and self.remote_auth.status.get("state") == "connected"
            ):
                return await self.refresh_remote_conversations()
            if self.gateway.connected.is_set() and self.provider_state["ready"]:
                warm = asyncio.create_task(
                    self.warm_conversations(), name="hermes-warm-conversations"
                )
                warm.add_done_callback(HermesGateway._log_background_failure)
            return {
                "conversations": [
                    self.public_conversation(conversation)
                    for conversation in self.registry.conversations.values()
                ],
                "selectedConversationId": self.registry.selected_conversation_id,
            }
        if method == "conversations.create":
            return await self.create_conversation(params)
        if method == "conversations.update":
            return await self.update_conversation(params)
        if method == "conversations.delete":
            return await self.delete_conversation(params)
        if method in {"conversations.select", "conversation.select"}:
            if not str(params.get("sessionId") or params.get("session_id") or ""):
                self.registry.selected_conversation_id = ""
                self.registry.save()
                await self.observe_remote_conversation("")
                return {"selectedConversationId": ""}
            conversation = self.resolve_conversation(params)
            await self.select_conversation(conversation)
            return self.public_conversation(conversation)
        if method == "session.history":
            conversation = self.resolve_conversation(params)
            await self.select_conversation(conversation)
            if self.remote_auth.base_url:
                return await self.remote_history(conversation, params)
            runtime = await self.ensure_runtime(conversation)
            result = await self.gateway.request(
                "session.history", {"session_id": runtime}, timeout=30
            )
            messages = self.display_messages(
                conversation,
                result.get("messages", []) if isinstance(result, dict) else [],
            )
            if messages and not conversation["has_messages"]:
                conversation["has_messages"] = True
                self.registry.save()
            payload = self.routed_payload(conversation, {"messages": messages})
            await self.broadcast_event("message.snapshot", payload)
            return payload
        if method == "session.status":
            conversation = self.resolve_conversation(params)
            if self.remote_auth.base_url:
                return await self.remote_session_status(conversation)
            runtime = await self.ensure_runtime(conversation)
            upstream = await self.gateway.request(
                "session.status", {"session_id": runtime}, timeout=30
            )
            return self.routed_payload(
                conversation,
                {
                    "status": conversation["status"],
                    "statusText": conversation["status_text"],
                    "upstream": upstream,
                },
            )
        if method == "session.configure":
            conversation = self.resolve_conversation(params)
            if not self.remote_auth.base_url:
                raise RpcFault(-32601, "Session model controls require a remote Hermes WebUI")
            return await self.remote_session_configure(conversation, params)
        if method in {"session.branch", "conversations.branch"}:
            conversation = self.resolve_conversation(params)
            if not self.remote_auth.base_url:
                raise RpcFault(-32601, "Session branches require a remote Hermes WebUI")
            if conversation.get("read_only"):
                raise RpcFault(-32046, "This conversation is read-only")
            return await self.remote_branch_conversation(conversation, params)
        if method == "message.edit":
            conversation = self.resolve_conversation(params)
            if not self.remote_auth.base_url:
                raise RpcFault(-32601, "Message editing requires a remote Hermes WebUI")
            if conversation.get("read_only"):
                raise RpcFault(-32046, "This conversation is read-only")
            return await self.remote_edit_message(conversation, params)
        if method in {"message.regenerate", "session.regenerate"}:
            conversation = self.resolve_conversation(params)
            if not self.remote_auth.base_url:
                raise RpcFault(-32601, "Regeneration requires a remote Hermes WebUI")
            if conversation.get("read_only"):
                raise RpcFault(-32046, "This conversation is read-only")
            return await self.remote_regenerate(conversation)
        if method == "prompt.submit":
            conversation = self.resolve_conversation(params)
            if conversation.get("read_only"):
                raise RpcFault(-32046, "This conversation is read-only")
            text = params.get("text", "")
            if text is None:
                text = ""
            attachments = params.get("attachments")
            has_attachments = isinstance(attachments, list) and bool(attachments)
            if not isinstance(text, str) or (not text.strip() and not has_attachments):
                raise RpcFault(-32602, "text or an attachment is required")
            if len(text.encode("utf-8")) > MAX_DOWNSTREAM_MESSAGE:
                raise RpcFault(-32602, "prompt is too large")
            if self.remote_auth.base_url:
                return await self.remote_prompt_submit(conversation, text, params)
            if has_attachments:
                raise RpcFault(-32601, "Attachments require a remote Hermes WebUI")
            if not text.strip():
                raise RpcFault(-32602, "text is required")
            runtime = await self.ensure_runtime(conversation)
            await self.set_conversation_status(conversation, "working", "Hermes is working…")
            upstream_params = {"session_id": runtime, "text": text}
            if params.get("queued") is True:
                upstream_params["queued"] = True
            previously_had_messages = conversation["has_messages"]
            conversation["has_messages"] = True
            self.registry.save()
            try:
                result = await self.gateway.request(
                    "prompt.submit", upstream_params, timeout=1800
                )
                return self.routed_payload(conversation, {"accepted": True, "upstream": result})
            except AmbiguousDelivery as fault:
                await self.set_conversation_status(
                    conversation, "reconnecting", "Checking Hermes after disconnect…"
                )
                await self.broadcast_event(
                    "session.error",
                    self.routed_payload(
                        conversation,
                        {
                            "message": fault.message,
                            "deliveryUnknown": True,
                            "replayed": False,
                        },
                    ),
                )
                raise
            except RpcFault:
                # A definitive pre-accept/rejection leaves a newly-created
                # lazy conversation empty. AmbiguousDelivery is handled above and
                # intentionally retains the conservative true marker.
                conversation["has_messages"] = previously_had_messages
                self.registry.save()
                raise
        if method == "session.interrupt":
            conversation = self.resolve_conversation(params)
            if self.remote_auth.base_url:
                return await self.remote_interrupt(conversation)
            runtime = await self.ensure_runtime(conversation)
            result = await self.gateway.request(
                "session.interrupt", {"session_id": runtime}, timeout=30
            )
            await self.set_conversation_status(conversation, "idle", "Interrupted")
            return self.routed_payload(conversation, {"upstream": result})
        if method in {
            "approval.respond",
            "clarify.respond",
            "sudo.respond",
            "secret.respond",
        }:
            if self.remote_auth.base_url:
                return await self.remote_respond_to_request(method, params)
            return await self.respond_to_request(method, params)
        if self.remote_auth.base_url and method == "commands.catalog":
            # The WebUI accepts slash invocations as ordinary chat input but
            # does not expose the headless gateway's command catalog RPC.
            return {"commands": [], "items": [], "models": []}
        if self.remote_auth.base_url and method == "session.compress":
            conversation = self.resolve_conversation(params)
            session_id = await self.ensure_remote_session(conversation)
            body: dict[str, Any] = {"session_id": session_id}
            topic = str(params.get("focusTopic") or params.get("focus_topic") or "").strip()
            if topic:
                body["focus_topic"] = topic[:500]
            await self.set_conversation_status(
                conversation, "working", "Hermes is compressing context…"
            )
            try:
                result = await self.remote_request(
                    "POST", "/api/session/compress", body, timeout=110
                )
            except RpcFault as fault:
                await self.set_conversation_status(conversation, "error", fault.message)
                raise
            returned_session = result.get("session")
            if isinstance(returned_session, dict):
                await self.apply_remote_session_snapshot(
                    conversation, returned_session
                )
            else:
                with suppress(RpcFault):
                    snapshot = await self.remote_request(
                        "GET",
                        "/api/session?session_id=" + quote(session_id, safe="")
                        + "&messages=1&expand_renderable=1&msg_limit="
                        + str(REMOTE_HISTORY_PAGE),
                        timeout=30,
                    )
                    await self.apply_remote_session_snapshot(
                        conversation, snapshot.get("session")
                    )
            await self.set_conversation_status(conversation, "idle", "Ready")
            return self.routed_payload(conversation, {"upstream": result, **result})
        if self.remote_auth.base_url and method in {
            "slash.exec",
            "command.dispatch",
            "commands.execute",
        }:
            command = str(
                params.get("command")
                or params.get("name")
                or ""
            ).strip().lstrip("/")
            argument = str(params.get("arg") or "").strip()
            if not command:
                raise RpcFault(-32602, "command is required")
            invocation = "/" + command + (f" {argument}" if argument else "")
            return {"type": "send", "message": invocation, "display": invocation}
        if self.remote_auth.base_url and method == "session.steer":
            conversation = self.resolve_conversation(params)
            text = str(params.get("text") or "").strip()
            if not text:
                raise RpcFault(-32602, "text is required")
            return await self.remote_steer(conversation, text)
        if method == "commands.execute":
            command = str(params.get("command") or "").strip()
            if not command.startswith("/"):
                raise RpcFault(-32602, "command must begin with /")
            head, _, argument = command[1:].partition(" ")
            proxy_params = {
                **self._routing_keys(params),
                "name": head,
                "arg": argument,
            }
            return await self.proxy("command.dispatch", proxy_params)
        if method in {"hermes.request", "conversation.rpc"}:
            if self.remote_auth.base_url:
                raise RpcFault(
                    -32601,
                    "Raw headless RPC is unavailable while remote Hermes is selected",
                )
            raw_method = params.get("method")
            raw_params = params.get("params", {})
            if not isinstance(raw_method, str) or not raw_method:
                raise RpcFault(-32602, "method is required")
            if not isinstance(raw_params, dict):
                raise RpcFault(-32602, "params.params must be an object")
            return await self.proxy(raw_method, {**raw_params, **self._routing_keys(params)})

        # Preserve the rest of Hermes's method catalog without requiring a
        # bridge release for each new interactive feature. If a stable local
        # sessionId is supplied it is translated; global calls pass unchanged.
        if "." in method:
            if self.remote_auth.base_url:
                raise RpcFault(
                    -32601,
                    f"Remote Hermes WebUI does not expose {method}",
                )
            return await self.proxy(method, params)
        raise RpcFault(-32601, f"Unknown method: {method}")

    async def refresh_provider_status(
        self, force: bool = False
    ) -> dict[str, Any]:
        """Return inference readiness, distinct from local socket health."""
        if not self.local_backend_enabled:
            return dict(self.provider_state)
        now = time.monotonic()
        if not force and self.provider_checked_at and now - self.provider_checked_at < 5:
            return dict(self.provider_state)
        async with self.provider_lock:
            now = time.monotonic()
            if (
                not force
                and self.provider_checked_at
                and now - self.provider_checked_at < 5
            ):
                return dict(self.provider_state)
            try:
                options = await self.gateway.api_request(
                    "GET", "/api/model/options?explicit_only=1", timeout=30
                )
                if not isinstance(options, dict):
                    raise RpcFault(-32030, "Hermes returned invalid provider status")
                provider = str(
                    options.get("current_provider") or options.get("provider") or ""
                ).strip()
                model = str(
                    options.get("current_model") or options.get("model") or ""
                ).strip()
                current: dict[str, Any] = {}
                rows = options.get("providers")
                if isinstance(rows, list):
                    for row in rows:
                        if not isinstance(row, dict):
                            continue
                        slug = str(
                            row.get("slug") or row.get("provider") or row.get("id") or ""
                        ).strip()
                        if row.get("is_current") is True or (
                            provider and slug.casefold() == provider.casefold()
                        ):
                            current = row
                            break
                authenticated = current.get("authenticated") if current else None
                ready = bool(
                    current
                    and provider
                    and provider.casefold() != "auto"
                    and model
                    and authenticated is not False
                )
                self.provider_state = {
                    "checked": True,
                    "ready": ready,
                    "setupRequired": not ready,
                    "provider": provider,
                    "providerName": str(current.get("name") or provider).strip(),
                    "model": model,
                    "error": "",
                    "updatedAt": utc_now(),
                }
            except RpcFault as fault:
                self.provider_state = {
                    "checked": False,
                    "ready": False,
                    "setupRequired": False,
                    "provider": "",
                    "providerName": "",
                    "model": "",
                    "error": fault.message[:500],
                    "updatedAt": utc_now(),
                }
            self.provider_checked_at = time.monotonic()
            return dict(self.provider_state)

    @staticmethod
    def _custom_provider_url(params: dict[str, Any]) -> str:
        raw = params.get("url", params.get("baseUrl", params.get("base_url")))
        if not isinstance(raw, str) or not raw.strip():
            raise RpcFault(-32602, "Endpoint URL is required")
        value = raw.strip().rstrip("/")
        if len(value) > 2048:
            raise RpcFault(-32602, "Endpoint URL is too long")
        parsed = urlparse(value)
        if (
            parsed.scheme not in {"http", "https"}
            or not parsed.hostname
            or parsed.username is not None
            or parsed.password is not None
            or parsed.query
            or parsed.fragment
        ):
            raise RpcFault(
                -32602,
                "Use an http(s) endpoint URL without credentials, query, or fragment",
            )
        if parsed.scheme == "http" and not is_loopback(parsed.hostname):
            raise RpcFault(
                -32602,
                "Remote provider URLs must use HTTPS; HTTP is allowed only on loopback",
            )
        return value

    @staticmethod
    def _custom_provider_password(params: dict[str, Any]) -> str:
        raw = params.get("password", params.get("apiKey", params.get("api_key", "")))
        if raw is None:
            return ""
        if not isinstance(raw, str):
            raise RpcFault(-32602, "Password / API key must be text")
        if len(raw.encode("utf-8")) > 65536:
            raise RpcFault(-32602, "Password / API key is too large")
        return raw.strip()

    @staticmethod
    def _provider_validation_result(raw: Any, url: str) -> dict[str, Any]:
        if not isinstance(raw, dict):
            raise RpcFault(-32030, "Hermes returned invalid endpoint validation")
        models: list[str] = []
        seen: set[str] = set()
        for candidate in raw.get("models", []) if isinstance(raw.get("models"), list) else []:
            model = str(candidate).strip()[:512]
            if model and model not in seen and len(models) < 1000:
                models.append(model)
                seen.add(model)
        return {
            "ok": raw.get("ok") is True,
            "reachable": raw.get("reachable") is True,
            "message": str(raw.get("message") or "")[:500],
            "models": models,
            "url": url,
        }

    async def validate_custom_provider(
        self, params: dict[str, Any]
    ) -> dict[str, Any]:
        if not self.local_backend_enabled:
            raise RpcFault(-32601, "Local Hermes is disabled in remote-only mode")
        url = self._custom_provider_url(params)
        password = self._custom_provider_password(params)
        raw = await self.gateway.api_request(
            "POST",
            "/api/providers/custom-endpoints/validate",
            {
                "name": "Quickshell endpoint",
                "base_url": url,
                "model": "pending-validation",
                "api_key": password,
            },
            timeout=20,
        )
        return self._provider_validation_result(raw, url)

    async def configure_custom_provider(
        self, params: dict[str, Any]
    ) -> dict[str, Any]:
        if not self.local_backend_enabled:
            raise RpcFault(-32601, "Local Hermes is disabled in remote-only mode")
        url = self._custom_provider_url(params)
        password = self._custom_provider_password(params)
        raw_model = params.get("model")
        if not isinstance(raw_model, str) or not raw_model.strip():
            raise RpcFault(-32602, "Model is required")
        model = raw_model.strip()
        if len(model) > 512:
            raise RpcFault(-32602, "Model name is too long")

        validation = await self.validate_custom_provider(
            {"url": url, "password": password}
        )
        if not validation["ok"]:
            raise RpcFault(
                -32031,
                validation["message"]
                or "The endpoint could not be authenticated",
            )
        discovered = validation["models"]
        if discovered and model not in discovered:
            raise RpcFault(-32602, "Select a model returned by this endpoint")

        parsed = urlparse(url)
        endpoint_seed = f"{parsed.netloc}{parsed.path}"
        digest = hashlib.sha256(url.encode("utf-8")).hexdigest()[:8]
        endpoint_id = f"menubar-{slugify(endpoint_seed)[:36]}-{digest}"
        display_host = parsed.hostname or "Custom endpoint"
        saved = await self.gateway.api_request(
            "POST",
            "/api/providers/custom-endpoints",
            {
                "id": endpoint_id,
                "name": f"{display_host} via Quickshell",
                "base_url": url,
                "model": model,
                "api_key": password,
                "models": discovered or [model],
                "discover_models": True,
                "make_default": True,
            },
            timeout=30,
        )
        if not isinstance(saved, dict) or saved.get("ok") is not True:
            raise RpcFault(-32030, "Hermes did not save the provider")

        self.provider_checked_at = 0
        status = await self.refresh_provider_status(force=True)
        if not status["ready"]:
            raise RpcFault(
                -32030,
                status["error"] or "Hermes saved the endpoint but is not model-ready",
            )

        # Provider-less first boot can leave lazy, message-free conversations in an
        # error state. Recreate only those empty contexts after authentication;
        # never discard a conversation that contains user-visible conversation.
        for conversation in self.registry.conversations.values():
            if conversation["status"] == "error" and not conversation["has_messages"]:
                await self.reset_conversation(conversation)
        await self.broadcast_event("provider.status", status)
        return {"ok": True, "providerStatus": status}

    @staticmethod
    def _routing_keys(params: dict[str, Any]) -> dict[str, Any]:
        return {
            key: params[key]
            for key in ("sessionId", "session_id", "conversationId", "conversation_id")
            if key in params
        }

    def resolve_conversation(self, params: dict[str, Any]) -> dict[str, Any]:
        conversation_id = str(
            params.get("conversationId")
            or params.get("conversation_id")
            or params.get("sessionId")
            or params.get("session_id")
            or ""
        )
        conversation = self.registry.conversations.get(conversation_id)
        if conversation is None:
            # Diagnostic compatibility: accept a current Hermes runtime id,
            # but never expose it as the normal routing contract.
            mapped = self.conversation_by_runtime.get(conversation_id)
            if not mapped:
                mapped = self.conversation_by_remote_session.get(conversation_id)
            conversation = self.registry.conversations.get(mapped or "")
        if conversation is None:
            raise RpcFault(-32602, "unknown conversation/sessionId")
        return conversation

    async def create_conversation(self, params: dict[str, Any]) -> dict[str, Any]:
        if self.remote_auth.base_url:
            if self.remote_auth.status.get("state") != "connected":
                raise RemoteLoginFault(
                    "Remote Hermes authentication is required",
                    self.remote_auth.status,
                )
            body: dict[str, Any] = {"worktree": False}
            for key, source_keys in (
                ("profile", ("profile",)),
                ("workspace", ("workspace",)),
                ("model", ("model",)),
                ("model_provider", ("modelProvider", "model_provider", "provider")),
            ):
                value = next((params.get(source) for source in source_keys
                              if params.get(source) is not None), None)
                if isinstance(value, str) and value.strip():
                    body[key] = value.strip()
            result = await self.remote_request(
                "POST", "/api/session/new", body, timeout=30
            )
            session = result.get("session")
            if not isinstance(session, dict):
                raise RpcFault(-32045, "Remote Hermes returned no conversation")
            normalized = dict(session)
            if "message_count" not in normalized:
                messages = normalized.get("messages")
                normalized["message_count"] = len(messages) if isinstance(messages, list) else 0
            conversation = self.remote_conversation_record(normalized)
            self.registry.conversations[conversation["id"]] = conversation
            self.registry.selected_conversation_id = conversation["id"]
            self.conversation_by_remote_session[conversation["id"]] = conversation["id"]
            self.registry.save()
            public = self.public_conversation(conversation)
            await self.broadcast_event(
                "conversation.created", {"conversation": public, **public}
            )
            return public

        name = str(params.get("name") or "").strip().lstrip("#")
        if not name:
            raise RpcFault(-32602, "name is required")
        if len(name) > 80:
            raise RpcFault(-32602, "name is too long")
        if any(
            row["name"].casefold() == name.casefold()
            for row in self.registry.conversations.values()
        ):
            raise RpcFault(-32020, f"Conversation #{name} already exists")
        base = slugify(name)
        conversation_id = base
        while conversation_id in self.registry.conversations:
            conversation_id = f"{base[:54]}-{uuid.uuid4().hex[:6]}"
        conversation = ConversationRegistry._coerce_conversation(
            {
                "id": conversation_id,
                "name": name,
                "title": str(params.get("title") or f"#{name}"),
                "brief": str(params.get("brief") or ""),
                "profile": str(params.get("profile") or ""),
                "cwd": str(params.get("cwd") or ""),
                "updated_at": utc_now(),
            }
        )
        assert conversation is not None
        self.registry.conversations[conversation_id] = conversation
        self.registry.save()
        if (
            self.remote_auth.base_url
            and self.remote_auth.status.get("state") == "connected"
        ):
            try:
                await self.ensure_remote_session(conversation)
            except RpcFault as fault:
                LOG.warning("new remote conversation is not ready yet: %s", fault.message)
        elif self.gateway.connected.is_set() and self.provider_state["ready"]:
            try:
                await self.ensure_runtime(conversation)
            except RpcFault as fault:
                LOG.warning("new conversation runtime is not ready yet: %s", fault.message)
        public = self.public_conversation(conversation)
        await self.broadcast_event("conversation.created", {"conversation": public, **public})
        return public

    async def update_conversation(self, params: dict[str, Any]) -> dict[str, Any]:
        conversation = self.resolve_conversation(params)
        if "name" in params:
            name = str(params["name"] or "").strip().lstrip("#")
            if not name:
                raise RpcFault(-32602, "name cannot be empty")
            duplicate = any(
                row is not conversation and row["name"].casefold() == name.casefold()
                for row in self.registry.conversations.values()
            )
            if duplicate:
                raise RpcFault(-32020, f"Conversation #{name} already exists")
            conversation["name"] = name[:80]
            if "title" not in params:
                conversation["title"] = f"#{name}"
        for source, target, limit in (
            ("title", "title", 160),
            ("brief", "brief", 4000),
            ("profile", "profile", 128),
            ("cwd", "cwd", 4096),
        ):
            if source in params:
                conversation[target] = str(params[source] or "")[:limit]
        if "unread" in params:
            raw_unread = params["unread"]
            if isinstance(raw_unread, bool):
                conversation["unread"] = raw_unread
            elif isinstance(raw_unread, (int, float)):
                conversation["unread"] = raw_unread > 0
        conversation["updated_at"] = utc_now()
        self.registry.save()
        runtime = self.runtime_by_conversation.get(conversation["id"])
        if runtime and "title" in params:
            with suppress(RpcFault):
                await self.gateway.request(
                    "session.title",
                    {"session_id": runtime, "title": conversation["title"]},
                    timeout=15,
                )
        if (
            self.remote_auth.base_url
            and conversation["remote_origin"] == self.remote_auth.base_url
            and conversation["remote_session_id"]
            and "title" in params
        ):
            with suppress(RpcFault):
                await self.remote_auth.request_json(
                    "POST",
                    "/api/session/rename",
                    {
                        "session_id": conversation["remote_session_id"],
                        "title": conversation["title"],
                    },
                    timeout=15,
                )
        public = self.public_conversation(conversation)
        await self.broadcast_event("conversation.updated", {"conversation": public, **public})
        return public

    async def delete_conversation(self, params: dict[str, Any]) -> dict[str, Any]:
        conversation = self.resolve_conversation(params)
        conversation_id = conversation["id"]
        if self.remote_auth.base_url:
            if conversation.get("read_only"):
                raise RpcFault(-32046, "This conversation is read-only")
            await self.remote_request(
                "POST",
                "/api/session/delete",
                {"session_id": conversation_id},
                timeout=30,
            )
        runtime = self.runtime_by_conversation.pop(conversation_id, "")
        if runtime:
            self.conversation_by_runtime.pop(runtime, None)
            with suppress(RpcFault):
                await self.gateway.request(
                    "session.close", {"session_id": runtime}, timeout=15
                )
        remote_session = conversation.get("remote_session_id", "")
        if remote_session:
            self.conversation_by_remote_session.pop(remote_session, None)
        await self.stop_remote_stream(conversation_id)
        if self.remote_observed_conversation_id == conversation_id:
            await self.observe_remote_conversation("")
        self.registry.conversations.pop(conversation_id)
        if self.registry.selected_conversation_id == conversation_id:
            self.registry.selected_conversation_id = ""
        self.registry.save()
        await self.broadcast_event(
            "conversation.deleted",
            {
                "conversationId": conversation_id,
                "sessionId": conversation_id,
                "selectedConversationId": self.registry.selected_conversation_id,
            },
        )
        return {"deleted": conversation_id}

    async def select_conversation(self, conversation: dict[str, Any]) -> None:
        self.registry.selected_conversation_id = conversation["id"]
        conversation["unread"] = False
        self.registry.save()
        if (
            self.remote_auth.base_url
            and self.remote_auth.status.get("state") == "connected"
        ):
            with suppress(RpcFault):
                await self.ensure_remote_session(conversation)
        elif self.gateway.connected.is_set() and self.provider_state["ready"]:
            with suppress(RpcFault):
                await self.ensure_runtime(conversation)
        public = self.public_conversation(conversation)
        await self.broadcast_event("conversation.selected", {"conversation": public, **public})
        if self.remote_auth.base_url:
            await self.observe_remote_conversation(conversation["id"])

    async def reset_conversation(self, conversation: dict[str, Any]) -> None:
        await self.stop_remote_stream(conversation["id"])
        remote_session = conversation.get("remote_session_id", "")
        if remote_session:
            self.conversation_by_remote_session.pop(remote_session, None)
        runtime = self.runtime_by_conversation.pop(conversation["id"], "")
        if runtime:
            self.conversation_by_runtime.pop(runtime, None)
            with suppress(RpcFault):
                await self.gateway.request(
                    "session.close", {"session_id": runtime}, timeout=15
                )
        if self.remote_auth.base_url:
            conversation["remote_origin"] = ""
            conversation["remote_session_id"] = ""
        else:
            conversation["stored_session_id"] = ""
        conversation["has_messages"] = False
        conversation["status"] = "idle"
        conversation["status_text"] = "New conversation"
        conversation["unread"] = False
        conversation["updated_at"] = utc_now()
        self.registry.save()
        if (
            self.remote_auth.base_url
            and self.remote_auth.status.get("state") == "connected"
        ):
            with suppress(RpcFault):
                await self.ensure_remote_session(conversation)
        elif self.gateway.connected.is_set() and self.provider_state["ready"]:
            with suppress(RpcFault):
                await self.ensure_runtime(conversation)
        public = self.public_conversation(conversation)
        await self.broadcast_event("conversation.updated", {"conversation": public, **public})

    def remote_mode(self) -> bool:
        """Return whether a remote WebUI is the selected conversation backend."""

        return bool(self.remote_auth.base_url)

    async def remote_request(
        self,
        method: str,
        path: str,
        payload: dict[str, Any] | None = None,
        timeout: float = 30.0,
    ) -> dict[str, Any]:
        previous = self.remote_auth.status
        try:
            return await self.remote_auth.request_json(
                method, path, payload, timeout=timeout
            )
        except RemoteLoginFault:
            await self.publish_remote_status(self.remote_auth.status, previous)
            raise

    async def update_remote_contract(self, **patch: Any) -> None:
        changed = False
        for key, value in patch.items():
            if self.remote_contract.get(key) != value:
                self.remote_contract[key] = value
                changed = True
        if not changed:
            return
        await self.broadcast_event(
            "bridge.capabilities",
            {
                "capabilities": self.bridge_capabilities(),
                "features": self.bridge_features(),
                "remoteContract": dict(self.remote_contract),
            },
        )

    @staticmethod
    def sanitize_remote_model_catalog(raw: Any) -> dict[str, Any]:
        """Expose models only for the provider configured as active in WebUI."""

        value = raw if isinstance(raw, dict) else {}
        default_model = str(
            value.get("default_model") or value.get("defaultModel") or ""
        ).strip()[:256]
        active_provider = str(
            value.get("active_provider") or value.get("activeProvider") or ""
        ).strip()[:128]
        badges = value.get(
            "configured_model_badges", value.get("configuredModelBadges", [])
        )
        for badge in badges if isinstance(badges, list) else []:
            if not isinstance(badge, dict):
                continue
            badge_model = str(
                badge.get("model") or badge.get("model_id") or ""
            ).strip()[:256]
            badge_provider = str(
                badge.get("provider") or badge.get("provider_id") or ""
            ).strip()[:128]
            primary = str(badge.get("role") or "").strip().lower() == "primary"
            if not default_model and primary:
                default_model = badge_model
            if not active_provider and badge_provider and (
                primary or badge_model == default_model
            ):
                active_provider = badge_provider
        groups: list[dict[str, Any]] = []
        model_count = 0
        raw_groups = value.get("groups", [])
        for candidate in raw_groups if isinstance(raw_groups, list) else []:
            if not isinstance(candidate, dict) or groups:
                continue
            provider_id = str(
                candidate.get("provider_id") or candidate.get("providerId")
                or candidate.get("id") or ""
            ).strip()[:128]
            provider = str(
                candidate.get("provider") or candidate.get("display_name")
                or candidate.get("displayName") or provider_id
            ).strip()[:160]
            if not provider_id or (
                active_provider and provider_id != active_provider
            ):
                continue
            models: list[dict[str, Any]] = []
            rows: list[Any] = []
            for key in ("models", "extra_models", "extraModels"):
                source = candidate.get(key)
                if isinstance(source, list):
                    rows.extend(source)
            seen: set[str] = set()
            for row in rows:
                if not isinstance(row, dict) or model_count >= 1000:
                    continue
                model_id = str(
                    row.get("id") or row.get("model") or row.get("slug") or ""
                ).strip()[:256]
                if not model_id or model_id in seen:
                    continue
                seen.add(model_id)
                model: dict[str, Any] = {
                    "id": model_id,
                    "label": str(
                        row.get("label") or row.get("name") or model_id
                    ).strip()[:160] or model_id,
                }
                if isinstance(row.get("supports_fast_tier"), bool):
                    model["supportsFastTier"] = row["supports_fast_tier"]
                models.append(model)
                model_count += 1
            if default_model and default_model not in seen:
                models.insert(0, {
                    "id": default_model,
                    "label": default_model,
                })
            if models:
                if not active_provider:
                    active_provider = provider_id
                groups.append({
                    "providerId": provider_id,
                    "provider": provider or provider_id,
                    "models": models,
                })
        if not groups and active_provider and default_model:
            groups.append({
                "providerId": active_provider,
                "provider": active_provider,
                "models": [{"id": default_model, "label": default_model}],
            })
        return {
            "groups": groups,
            "defaultModel": default_model,
            "activeProvider": active_provider,
        }

    @staticmethod
    def sanitize_remote_reasoning(raw: Any) -> dict[str, Any]:
        value = raw if isinstance(raw, dict) else {}
        valid = {"", "none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"}
        effort = str(value.get("reasoning_effort") or "").strip().lower()
        if effort not in valid:
            effort = ""
        supported: list[str] = []
        for candidate in value.get("supported_efforts", []):
            normalized = str(candidate or "").strip().lower()
            if normalized in valid and normalized not in {"", "none"} \
                    and normalized not in supported:
                supported.append(normalized)
        supports_effort = value.get("supports_reasoning_effort") is True
        supports_toggle = value.get("supports_thinking_toggle") is True
        options = [""]
        if supports_toggle or supports_effort:
            options.append("none")
        if supports_effort:
            options.extend(supported)
        return {
            "effort": effort,
            "options": options,
            "supportedEfforts": supported,
            "supportsReasoningEffort": supports_effort,
            "supportsThinkingToggle": supports_toggle,
            "showReasoning": value.get("show_reasoning") is not False,
        }

    @staticmethod
    def remote_reasoning_path(params: dict[str, Any]) -> str:
        pairs: list[str] = []
        for source, target in (("model", "model"), ("modelProvider", "provider"),
                               ("model_provider", "provider"), ("provider", "provider")):
            value = params.get(source)
            if not isinstance(value, str) or not value.strip():
                continue
            if any(pair.startswith(target + "=") for pair in pairs):
                continue
            pairs.append(target + "=" + quote(value.strip()[:256], safe=""))
        return "/api/reasoning" + ("?" + "&".join(pairs) if pairs else "")

    async def remote_model_catalog(self) -> dict[str, Any]:
        result = await self.remote_request("GET", "/api/models", timeout=45)
        catalog = self.sanitize_remote_model_catalog(result)
        await self.update_remote_contract(modelSelection=bool(catalog["groups"]))
        return catalog

    async def remote_reasoning_state(self, params: dict[str, Any]) -> dict[str, Any]:
        result = await self.remote_request(
            "GET", self.remote_reasoning_path(params), timeout=20
        )
        state = self.sanitize_remote_reasoning(result)
        await self.update_remote_contract(
            reasoningEffort=bool(state["options"] and len(state["options"]) > 1)
        )
        return state

    async def remote_route_supported(
        self, path: str, *, multipart: bool = False
    ) -> bool:
        """Probe a write route with an invalid, guaranteed non-mutating body."""

        if multipart:
            previous = self.remote_auth.status
            try:
                status_code = await self.remote_auth.probe_multipart_route(path)
            except RemoteLoginFault:
                await self.publish_remote_status(self.remote_auth.status, previous)
                raise
            return status_code in {200, 400, 409, 415, 422}
        try:
            await self.remote_request("POST", path, {}, timeout=15)
            return True
        except RpcFault as fault:
            details = fault.data if isinstance(fault.data, dict) else {}
            status_code = int(details.get("statusCode") or 0)
            # These responses mean routing and validation both ran. The empty
            # object cannot identify a session, file, or prompt to mutate.
            return status_code in {400, 409, 415, 422}

    async def downgrade_remote_action(self, capability: str, fault: RpcFault) -> None:
        details = fault.data if isinstance(fault.data, dict) else {}
        if int(details.get("statusCode") or 0) in {404, 405, 410, 501}:
            await self.update_remote_contract(**{capability: False})

    async def probe_remote_contract(self) -> dict[str, Any]:
        """Negotiate the read-only WebUI stream contract without guessing writes."""

        try:
            probe = await self.remote_auth.probe_contract()
        except RemoteLoginFault:
            await self.publish_remote_status(self.remote_auth.status)
            raise
        except RpcFault:
            await self.update_remote_contract(checked=True)
            return dict(self.remote_contract)
        await self.update_remote_contract(
            checked=True,
            server=str(probe.get("server") or "")[:128],
            probeStatus=int(probe.get("probeStatus") or 0),
            gatewaySessions=probe.get("gatewaySessions") is True,
            gatewayWatcher=probe.get("gatewayWatcher") is True,
            sessionStream=probe.get("sessionStream") is True,
            sessionStreamPath=str(
                probe.get("sessionStreamPath") or "/api/session/stream"
            ),
            fallbackPollMs=int(probe.get("fallbackPollMs") or 30000),
        )
        try:
            await self.remote_model_catalog()
        except RpcFault:
            await self.update_remote_contract(modelSelection=False)
        try:
            await self.remote_reasoning_state({})
        except RpcFault:
            await self.update_remote_contract(reasoningEffort=False)
        route_support: dict[str, bool] = {
            "attachments": await self.remote_route_supported(
                "/api/upload", multipart=True
            ),
            "messageEditing": await self.remote_route_supported(
                "/api/session/truncate"
            ),
            "regeneration": await self.remote_route_supported(
                "/api/session/retry"
            ),
        }
        native_branch = await self.remote_route_supported("/api/session/branch")
        duplicate = await self.remote_route_supported("/api/session/duplicate")
        route_support["nativeBranches"] = native_branch
        route_support["duplicateSessions"] = duplicate
        route_support["branches"] = native_branch or (
            duplicate and route_support["messageEditing"]
        )
        await self.update_remote_contract(**route_support)
        return dict(self.remote_contract)

    async def start_remote_observers(self) -> None:
        if (
            not self.remote_auth.base_url
            or self.remote_auth.status.get("state") != "connected"
        ):
            return
        task = self.remote_observer_tasks.get("global")
        if task is None or task.done():
            task = asyncio.create_task(
                self._remote_global_events_loop(self.remote_auth.base_url),
                name="hermes-remote-session-list-events",
            )
            self.remote_observer_tasks["global"] = task
            task.add_done_callback(HermesGateway._log_background_failure)
        await self.observe_remote_conversation(
            self.registry.selected_conversation_id
        )

    async def stop_remote_observer(self, key: str) -> None:
        task = self.remote_observer_tasks.pop(key, None)
        with self.remote_observer_response_lock:
            response = self.remote_observer_responses.pop(key, None)
        current = asyncio.current_task()
        if task is not None and task is not current and not task.done():
            task.cancel()
        # Mark the asyncio reader cancelled before closing the blocking urllib
        # response. Closing first can make its worker thread race through
        # http.client with a cleared file pointer and surface a spurious
        # ``NoneType.peek`` failure during an otherwise clean service stop.
        if response is not None:
            with suppress(Exception):
                await asyncio.to_thread(response.close)
        if task is not None and task is not current:
            with suppress(asyncio.CancelledError, Exception):
                await task

    async def stop_remote_observers(self) -> None:
        keys = set(self.remote_observer_tasks)
        with self.remote_observer_response_lock:
            keys.update(self.remote_observer_responses)
        for key in keys:
            await self.stop_remote_observer(key)
        self.remote_observed_conversation_id = ""

    async def observe_remote_conversation(self, conversation_id: str) -> None:
        conversation_id = str(conversation_id or "")
        if conversation_id == self.remote_observed_conversation_id:
            task = self.remote_observer_tasks.get("session")
            if not conversation_id or (task is not None and not task.done()):
                return
        await self.stop_remote_observer("session")
        self.remote_observed_conversation_id = conversation_id
        if (
            not conversation_id
            or self.remote_auth.status.get("state") != "connected"
        ):
            return
        conversation = self.registry.conversations.get(conversation_id)
        if conversation is None:
            return
        session_id = str(conversation.get("remote_session_id") or conversation_id)
        task = asyncio.create_task(
            self._remote_session_events_loop(
                conversation_id, session_id, self.remote_auth.base_url
            ),
            name=f"hermes-remote-session-events-{conversation_id}",
        )
        self.remote_observer_tasks["session"] = task
        task.add_done_callback(HermesGateway._log_background_failure)

    async def _consume_observer_sse(
        self,
        response: Any,
        callback: Callable[[str, str, dict[str, Any]], Awaitable[None]],
    ) -> None:
        event_name = "message"
        event_id = ""
        data_lines: list[str] = []
        event_size = 0

        async def dispatch_event() -> None:
            nonlocal event_name, event_id, data_lines, event_size
            if data_lines:
                try:
                    parsed = json.loads("\n".join(data_lines))
                except json.JSONDecodeError as exc:
                    raise RpcFault(
                        -32045, "Remote Hermes sent invalid observer event data"
                    ) from exc
                data = parsed if isinstance(parsed, dict) else {"value": parsed}
                await callback(event_name, event_id, data)
            event_name = "message"
            event_id = ""
            data_lines = []
            event_size = 0

        while True:
            raw = await asyncio.to_thread(response.readline, MAX_REMOTE_SSE_EVENT + 1)
            if not raw:
                await dispatch_event()
                return
            if len(raw) > MAX_REMOTE_SSE_EVENT:
                raise RpcFault(-32045, "Remote Hermes observer event is too large")
            try:
                line = raw.decode("utf-8").rstrip("\r\n")
            except UnicodeDecodeError as exc:
                raise RpcFault(-32045, "Remote Hermes observer event is not UTF-8") from exc
            if not line:
                await dispatch_event()
                continue
            if line.startswith(":"):
                continue
            field, separator, value = line.partition(":")
            if not separator:
                value = ""
            elif value.startswith(" "):
                value = value[1:]
            if field == "event":
                event_name = value[:256] or "message"
            elif field == "id" and "\x00" not in value:
                event_id = value[:1024]
            elif field == "data":
                event_size += len(raw)
                if event_size > MAX_REMOTE_SSE_EVENT:
                    raise RpcFault(-32045, "Remote Hermes observer event is too large")
                data_lines.append(value)

    async def _remote_global_events_loop(self, origin: str) -> None:
        failures = 0
        key = "global"
        try:
            while (
                self.remote_auth.base_url == origin
                and self.remote_auth.status.get("state") == "connected"
            ):
                response: Any = None
                try:
                    response = await asyncio.to_thread(
                        self.remote_auth.open_sse,
                        "/api/sessions/events",
                        timeout=45,
                    )
                    with self.remote_observer_response_lock:
                        self.remote_observer_responses[key] = response
                    await self.update_remote_contract(globalSessionEvents=True)
                    failures = 0

                    async def handle(event: str, _event_id: str, _data: dict[str, Any]) -> None:
                        if event.strip().lower().replace("-", "_") != "sessions_changed":
                            return
                        with suppress(RpcFault):
                            await self.refresh_remote_conversations()

                    await self._consume_observer_sse(response, handle)
                except asyncio.CancelledError:
                    raise
                except RemoteLoginFault:
                    await self.publish_remote_status(self.remote_auth.status)
                    return
                except RpcFault as fault:
                    if "HTTP 404" in fault.message or "invalid event stream" in fault.message:
                        await self.update_remote_contract(globalSessionEvents=False)
                        return
                    failures += 1
                except (OSError, TimeoutError, UnicodeDecodeError):
                    failures += 1
                finally:
                    with self.remote_observer_response_lock:
                        if self.remote_observer_responses.get(key) is response:
                            self.remote_observer_responses.pop(key, None)
                    if response is not None:
                        with suppress(Exception):
                            await asyncio.to_thread(response.close)
                await asyncio.sleep(min(30.0, 0.5 * (2 ** min(failures, 6))))
        finally:
            if self.remote_observer_tasks.get(key) is asyncio.current_task():
                self.remote_observer_tasks.pop(key, None)

    async def _remote_session_events_loop(
        self, conversation_id: str, session_id: str, origin: str
    ) -> None:
        failures = 0
        key = "session"
        seen_background: list[str] = []
        try:
            while (
                self.remote_observed_conversation_id == conversation_id
                and self.remote_auth.base_url == origin
                and self.remote_auth.status.get("state") == "connected"
            ):
                conversation = self.registry.conversations.get(conversation_id)
                if conversation is None:
                    return
                response: Any = None
                path = str(
                    self.remote_contract.get("sessionStreamPath")
                    or "/api/session/stream"
                )
                path += "?session_id=" + quote(session_id, safe="")
                path += "&known_count=" + str(
                    max(0, int(conversation.get("message_count") or 0))
                )
                try:
                    response = await asyncio.to_thread(
                        self.remote_auth.open_sse, path, timeout=45
                    )
                    with self.remote_observer_response_lock:
                        self.remote_observer_responses[key] = response
                    await self.update_remote_contract(sessionStream=True)
                    failures = 0

                    async def handle(event: str, event_id: str, data: dict[str, Any]) -> None:
                        normalized = event.strip().lower().replace("-", "_")
                        active = self.registry.conversations.get(conversation_id)
                        if active is None:
                            return
                        if normalized == "server_turn_started":
                            stream_id = str(data.get("stream_id") or data.get("streamId") or "")
                            if stream_id:
                                await self.set_conversation_status(
                                    active, "working", "Hermes is working…"
                                )
                                await self.start_remote_stream(
                                    active, session_id, stream_id
                                )
                            return
                        if normalized in {
                            "session_updated",
                            "bg_task_complete",
                            "process_complete",
                        }:
                            dedupe = str(
                                data.get("event_id")
                                or data.get("process_id")
                                or event_id
                                or f"{normalized}:{data.get('message_count', '')}"
                            )
                            if dedupe in seen_background:
                                return
                            seen_background.append(dedupe)
                            del seen_background[:-64]
                            if normalized != "session_updated":
                                await self.broadcast_event(
                                    "session.background",
                                    self.routed_payload(
                                        active,
                                        {**data, "kind": normalized},
                                    ),
                                )
                            with suppress(RpcFault):
                                await self.remote_history(
                                    active, {"limit": REMOTE_HISTORY_PAGE}
                                )

                    await self._consume_observer_sse(response, handle)
                except asyncio.CancelledError:
                    raise
                except RemoteLoginFault:
                    await self.publish_remote_status(self.remote_auth.status)
                    return
                except RpcFault as fault:
                    if "HTTP 404" in fault.message or "invalid event stream" in fault.message:
                        await self.update_remote_contract(sessionStream=False)
                        return
                    failures += 1
                except (OSError, TimeoutError, UnicodeDecodeError):
                    failures += 1
                finally:
                    with self.remote_observer_response_lock:
                        if self.remote_observer_responses.get(key) is response:
                            self.remote_observer_responses.pop(key, None)
                    if response is not None:
                        with suppress(Exception):
                            await asyncio.to_thread(response.close)
                await asyncio.sleep(min(30.0, 0.5 * (2 ** min(failures, 6))))
        finally:
            if self.remote_observer_tasks.get(key) is asyncio.current_task():
                self.remote_observer_tasks.pop(key, None)

    @staticmethod
    def _remote_time(value: Any) -> str:
        if isinstance(value, (int, float)):
            try:
                return datetime.fromtimestamp(
                    float(value), timezone.utc
                ).isoformat(timespec="milliseconds").replace("+00:00", "Z")
            except (OverflowError, OSError, ValueError):
                return ""
        return str(value or "")[:64]

    def remote_conversation_record(
        self,
        raw: Any,
        current: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        if not isinstance(raw, dict):
            raise RpcFault(-32045, "Remote Hermes returned an invalid conversation")
        session_id = str(
            raw.get("session_id") or raw.get("sessionId") or raw.get("id") or ""
        ).strip()
        if not CONVERSATION_ID_PATTERN.fullmatch(session_id):
            raise RpcFault(-32045, "Remote Hermes returned an invalid session id")
        active_stream = str(
            raw.get("active_stream_id") or raw.get("activeStreamId") or ""
        )
        attention = raw.get("attention")
        if attention:
            status = "waiting"
            status_text = "Hermes needs you"
        elif active_stream or raw.get("is_streaming") is True:
            status = "working"
            status_text = "Hermes is working…"
        else:
            status = "idle"
            status_text = "Ready"
        try:
            message_count = max(0, int(raw.get("message_count") or 0))
        except (TypeError, ValueError):
            message_count = 0
        title = str(raw.get("title") or "Untitled chat").strip()[:160]
        record = ConversationRegistry._coerce_conversation(
            {
                "id": session_id,
                "title": title or "Untitled chat",
                "profile": raw.get("profile") or "",
                "cwd": raw.get("workspace") or "",
                "remote_origin": self.remote_auth.base_url,
                "remote_session_id": session_id,
                "has_messages": message_count > 0,
                "status": status,
                "status_text": status_text,
                "unread": bool((current or {}).get("unread", False)),
                "updated_at": self._remote_time(
                    raw.get("last_message_at") or raw.get("updated_at")
                    or raw.get("created_at")
                ) or utc_now(),
                "created_at": self._remote_time(raw.get("created_at")),
                "model": raw.get("model") or "",
                "model_provider": raw.get("model_provider") or raw.get("provider") or "",
                "source": raw.get("source_label") or raw.get("session_source")
                    or raw.get("source_tag") or "",
                "read_only": bool(raw.get("read_only", False)),
                "message_count": message_count,
            }
        )
        if record is None:
            raise RpcFault(-32045, "Remote Hermes returned an invalid conversation")
        record["active_stream_id"] = active_stream
        return record

    async def refresh_remote_conversations(self) -> dict[str, Any]:
        if self.remote_auth.status.get("state") != "connected":
            raise RemoteLoginFault(
                "Remote Hermes authentication is required", self.remote_auth.status
            )
        result = await self.remote_request(
            "GET", "/api/sessions?exclude_hidden=1", timeout=45
        )
        rows = result.get("sessions")
        if not isinstance(rows, list):
            raise RpcFault(-32045, "Remote Hermes returned no conversation list")

        previous = self.registry.conversations
        incoming: dict[str, dict[str, Any]] = {}
        for raw in rows:
            try:
                session_id = str(
                    raw.get("session_id") if isinstance(raw, dict) else ""
                )
                record = self.remote_conversation_record(
                    raw, previous.get(session_id)
                )
            except RpcFault:
                LOG.warning("ignoring an invalid remote Hermes conversation row")
                continue
            incoming[record["id"]] = record

        # A just-created first turn can be absent from the sidebar snapshot for
        # a few milliseconds. Keep only that selected/active transient row;
        # settled history is always authoritative from the WebUI response.
        for session_id, record in previous.items():
            if session_id in incoming:
                continue
            if (
                session_id == self.registry.selected_conversation_id
                and record.get("status") in {"working", "waiting"}
            ):
                incoming[session_id] = record

        self.registry.conversations = incoming
        if self.registry.selected_conversation_id not in incoming:
            self.registry.selected_conversation_id = ""
            await self.observe_remote_conversation("")
        self.conversation_by_remote_session = {
            session_id: session_id for session_id in incoming
        }
        self.registry.save()

        for conversation in incoming.values():
            stream_id = str(conversation.get("active_stream_id") or "")
            if stream_id:
                await self.start_remote_stream(
                    conversation, conversation["id"], stream_id
                )

        payload = {
            "conversations": [
                self.public_conversation(conversation)
                for conversation in incoming.values()
            ],
            "selectedConversationId": self.registry.selected_conversation_id,
        }
        await self.broadcast_event("conversations.snapshot", payload)
        return payload

    async def ensure_remote_session(self, conversation: dict[str, Any]) -> str:
        status = self.remote_auth.status
        if status.get("state") != "connected" or not self.remote_auth.base_url:
            raise RemoteLoginFault(
                "Remote Hermes authentication is required", status
            )
        conversation_id = conversation["id"]
        origin = self.remote_auth.base_url
        session_id = (
            conversation["remote_session_id"]
            if conversation["remote_origin"] == origin
            else ""
        )
        if session_id and self.conversation_by_remote_session.get(session_id) == conversation_id:
            return session_id

        lock = self.conversation_locks.setdefault(conversation_id, asyncio.Lock())
        async with lock:
            session_id = (
                conversation["remote_session_id"]
                if conversation["remote_origin"] == origin
                else ""
            )
            if session_id:
                try:
                    remote_status = await self.remote_request(
                        "GET",
                        "/api/session/status?session_id="
                        + quote(session_id, safe=""),
                        timeout=20,
                    )
                except RpcFault as fault:
                    if "HTTP 404" not in fault.message or conversation["has_messages"]:
                        raise
                    session_id = ""
                    conversation["remote_origin"] = ""
                    conversation["remote_session_id"] = ""
                else:
                    active_stream = str(remote_status.get("active_stream_id") or "")
                    if active_stream:
                        await self.start_remote_stream(
                            conversation, session_id, active_stream
                        )

            if not session_id:
                session_id = await self.create_remote_session(conversation)

            conversation["remote_origin"] = origin
            conversation["remote_session_id"] = session_id
            self.conversation_by_remote_session[session_id] = conversation_id
            conversation["updated_at"] = utc_now()
            self.registry.save()
            public = self.public_conversation(conversation)
            await self.broadcast_event(
                "conversation.updated", {"conversation": public, **public}
            )
            return session_id

    async def create_remote_session(self, conversation: dict[str, Any]) -> str:
        body: dict[str, Any] = {"worktree": False}
        if conversation["profile"]:
            body["profile"] = conversation["profile"]
        result = await self.remote_request(
            "POST", "/api/session/new", body, timeout=30
        )
        session = result.get("session")
        if not isinstance(session, dict) or not session.get("session_id"):
            raise RpcFault(-32045, "Remote Hermes returned no session id")
        return str(session["session_id"])

    async def warm_remote_conversations(self) -> None:
        if self.remote_auth.status.get("state") != "connected":
            return
        await self.refresh_remote_conversations()

    @classmethod
    def _remote_content_text(cls, value: Any, depth: int = 0) -> str:
        """Project structured message content without serializing protocol data.

        Hermes accepts OpenAI and Anthropic content-part shapes.  Tool-use and
        tool-result parts are intentionally excluded here: they are projected
        into activity cards by :meth:`project_remote_transcript` instead of
        becoming JSON chat bubbles.
        """

        if depth > 5:
            return ""
        if isinstance(value, str):
            return value
        if isinstance(value, (int, float, bool)):
            return str(value)
        if isinstance(value, list):
            parts = [cls._remote_content_text(part, depth + 1) for part in value]
            return "\n".join(part for part in parts if part.strip())
        if not isinstance(value, dict):
            return ""

        part_type = str(value.get("type") or "").strip().lower()
        if part_type in {
            "tool_use",
            "tool_result",
            "function_call",
            "function_result",
        }:
            return ""
        if part_type in {"image", "image_url", "input_image"}:
            return "[Image attachment]"
        if part_type in {"file", "input_file", "attachment"}:
            name = str(
                value.get("filename") or value.get("name") or value.get("file_name") or ""
            ).strip()
            return f"[File attachment: {name}]" if name else "[File attachment]"

        for key in ("text", "content", "value", "input_text", "output_text"):
            if key not in value:
                continue
            text = cls._remote_content_text(value[key], depth + 1)
            if text.strip():
                return text
        return ""

    @staticmethod
    def _remote_tool_text(value: Any, limit: int = MAX_REMOTE_TOOL_DETAIL) -> str:
        """Return a bounded, readable tool argument/result preview."""

        def bounded(text: str) -> str:
            if len(text) <= limit:
                return text
            if limit <= 0:
                return ""
            if limit == 1:
                return "…"
            return text[: limit - 1] + "…"

        parsed = value
        if isinstance(value, str):
            candidate = value.strip()
            if candidate and candidate[0] in "[{":
                with suppress(json.JSONDecodeError, TypeError):
                    parsed = json.loads(candidate)
        if isinstance(parsed, dict):
            for key in ("summary", "message", "result", "output", "error"):
                scalar = parsed.get(key)
                if isinstance(scalar, str) and scalar.strip():
                    text = scalar.strip()
                    return bounded(text)
        if isinstance(parsed, (dict, list)):
            try:
                text = json.dumps(parsed, ensure_ascii=False, indent=2, sort_keys=True)
            except (TypeError, ValueError):
                text = str(parsed)
        elif parsed is None:
            text = ""
        else:
            text = str(parsed)
        text = text.strip()
        return bounded(text)

    @staticmethod
    def _remote_attachments(value: Any) -> list[dict[str, Any]]:
        rows: list[dict[str, Any]] = []
        if not isinstance(value, list):
            return rows
        for item in value[:MAX_REMOTE_ATTACHMENTS]:
            source = item if isinstance(item, dict) else {}
            raw_name = (
                source.get("name") or source.get("filename") or source.get("path")
                if source else item
            )
            name = Path(str(raw_name or "attachment")).name.strip()[:200]
            if not name:
                name = "attachment"
            mime_type = str(source.get("mime") or "").strip()[:160]
            try:
                size = max(0, min(MAX_REMOTE_ATTACHMENT_BYTES, int(source.get("size") or 0)))
            except (TypeError, ValueError):
                size = 0
            rows.append({
                "name": name,
                "mime": mime_type,
                "size": size,
                "isImage": source.get("is_image") is True
                or mime_type.startswith("image/"),
            })
        return rows

    @staticmethod
    def _remote_tool_id(value: dict[str, Any]) -> str:
        return str(
            value.get("tool_call_id")
            or value.get("toolCallId")
            or value.get("tool_use_id")
            or value.get("tid")
            or value.get("call_id")
            or value.get("id")
            or ""
        ).strip()

    @classmethod
    def _remote_tool_call(cls, value: Any) -> tuple[str, str, Any]:
        if not isinstance(value, dict):
            return "", "", None
        function = value.get("function")
        nested = function if isinstance(function, dict) else {}
        tool_id = cls._remote_tool_id(value)
        name = str(
            nested.get("name")
            or value.get("name")
            or value.get("tool_name")
            or value.get("function_name")
            or "Tool"
        ).strip()
        arguments = value.get("args", value.get("input", value.get("arguments")))
        if arguments is None:
            arguments = nested.get("arguments")
        if isinstance(arguments, str):
            with suppress(json.JSONDecodeError, TypeError):
                arguments = json.loads(arguments)
        return tool_id, name or "Tool", arguments

    @classmethod
    def project_remote_transcript(
        cls,
        session_id: str,
        messages: Any,
        session_tool_calls: Any = None,
        *,
        offset: int = 0,
    ) -> dict[str, list[dict[str, Any]]]:
        """Split persisted history into prose messages and bounded tool cards."""

        source = cls.display_messages({}, messages)
        results: dict[str, dict[str, Any]] = {}
        orphan_results: list[dict[str, Any]] = []

        def note_result(
            tool_id: str,
            raw: Any,
            source_index: int,
            *,
            name: str = "",
            failed: bool = False,
        ) -> None:
            record = {
                "id": tool_id,
                "name": name,
                "output": cls._remote_tool_text(raw),
                "failed": failed,
                "order": (offset + source_index) * 1000 + 900,
                "sourceIndex": offset + source_index,
            }
            if tool_id:
                results[tool_id] = record
            else:
                orphan_results.append(record)

        for index, message in enumerate(source):
            role = str(message.get("role") or "").strip().lower()
            if role == "tool":
                note_result(
                    cls._remote_tool_id(message),
                    message.get("content", message.get("result", message.get("output"))),
                    index,
                    name=str(message.get("name") or message.get("tool_name") or ""),
                    failed=message.get("is_error") is True or bool(message.get("error")),
                )
            content = message.get("content")
            if not isinstance(content, list):
                continue
            for part in content:
                if not isinstance(part, dict) or str(part.get("type") or "").lower() != "tool_result":
                    continue
                note_result(
                    str(part.get("tool_use_id") or part.get("tool_call_id") or ""),
                    part.get("content", part.get("result", part.get("output"))),
                    index,
                    failed=part.get("is_error") is True or bool(part.get("error")),
                )

        projected_messages: list[dict[str, Any]] = []
        tools_by_id: dict[str, dict[str, Any]] = {}
        tool_order: list[str] = []

        def upsert_tool(tool: dict[str, Any]) -> None:
            tool_id = str(tool.get("id") or "")
            if not tool_id:
                return
            current = tools_by_id.get(tool_id)
            if current is None:
                tools_by_id[tool_id] = tool
                tool_order.append(tool_id)
                return
            merged = dict(current)
            for key, value in tool.items():
                if value not in (None, "", [], {}):
                    merged[key] = value
            tools_by_id[tool_id] = merged

        for index, message in enumerate(source):
            raw_role = str(
                message.get("role") or message.get("author") or message.get("sender") or ""
            ).strip().lower().replace("-", "_")
            role = {
                "human": "user",
                "me": "user",
                "agent": "assistant",
                "hermes": "assistant",
                "model": "assistant",
            }.get(raw_role, raw_role)
            content = message.get(
                "text",
                message.get("content", message.get("delta", message.get("message"))),
            )
            text = cls._remote_content_text(content).strip()
            streaming = message.get("streaming") is True or message.get("partial") is True
            pending = message.get("pending") is True
            error = str(message.get("error") or "").strip()[:500]
            order = (offset + index) * 1000
            message_id = str(
                message.get("id")
                or message.get("message_id")
                or message.get("turn_id")
                or message.get("item_id")
                or f"remote-{session_id}-{offset + index}"
            )

            calls: list[Any] = []
            for key in ("tool_calls", "_partial_tool_calls"):
                value = message.get(key)
                if isinstance(value, list):
                    calls.extend(value)
            if isinstance(content, list):
                calls.extend(
                    part
                    for part in content
                    if isinstance(part, dict)
                    and str(part.get("type") or "").lower() == "tool_use"
                )
            for call_index, call in enumerate(calls):
                tool_id, name, arguments = cls._remote_tool_call(call)
                if not tool_id:
                    tool_id = f"remote-tool-{session_id}-{offset + index}-{call_index}"
                result = results.get(tool_id, {})
                failed = bool(result.get("failed")) or (
                    isinstance(call, dict)
                    and (call.get("is_error") is True or bool(call.get("error")))
                )
                partial = isinstance(call, dict) and call.get("done") is False
                upsert_tool(
                    {
                        "id": tool_id,
                        "toolCallId": tool_id,
                        "name": name,
                        "label": str(call.get("label") or "") if isinstance(call, dict) else "",
                        "status": "error" if failed else "interrupted" if partial else "completed",
                        "input": cls._remote_tool_text(arguments),
                        "output": str(result.get("output") or ""),
                        "detail": str(result.get("output") or ""),
                        "error": str(call.get("error") or "")[:500]
                        if isinstance(call, dict) and failed
                        else "",
                        "order": order + 100 + call_index,
                        "sourceIndex": offset + index,
                        "historical": True,
                        "terminal": True,
                    }
                )

            if role not in {"user", "assistant", "system"}:
                continue
            # Empty assistant carrier rows exist solely to anchor tool_calls.
            if not text and not streaming and not pending and not error:
                continue
            projected_messages.append(
                {
                    "id": message_id,
                    "role": role,
                    "text": text,
                    "createdAt": cls._remote_time(
                        message.get("created_at")
                        or message.get("timestamp")
                        or message.get("time")
                    ),
                    "updatedAt": cls._remote_time(
                        message.get("updated_at")
                        or message.get("timestamp")
                        or message.get("time")
                    ),
                    "streaming": streaming,
                    "pending": pending,
                    "error": error,
                    "model": str(message.get("model") or "")[:256],
                    "attachments": cls._remote_attachments(
                        message.get("attachments")
                    ),
                    "order": order,
                    "sourceIndex": offset + index,
                }
            )

        sidecars = session_tool_calls if isinstance(session_tool_calls, list) else []
        for sidecar_index, call in enumerate(sidecars):
            if not isinstance(call, dict):
                continue
            tool_id, name, arguments = cls._remote_tool_call(call)
            if not tool_id:
                tool_id = f"remote-sidecar-tool-{session_id}-{sidecar_index}"
            try:
                assistant_index = int(call.get("assistant_msg_idx"))
            except (TypeError, ValueError):
                assistant_index = -1
            result = results.get(tool_id, {})
            output = call.get(
                "snippet",
                call.get("preview", call.get("result", call.get("output"))),
            )
            if not output:
                output = result.get("output", "")
            failed = call.get("is_error") is True or bool(call.get("error")) or bool(
                result.get("failed")
            )
            sidecar_order = (
                assistant_index * 1000 + 100 + sidecar_index
                if assistant_index >= 0
                else int(result.get("order") or (offset + len(source)) * 1000 + sidecar_index)
            )
            upsert_tool(
                {
                    "id": tool_id,
                    "toolCallId": tool_id,
                    "name": name,
                    "label": str(call.get("label") or ""),
                    "status": "error" if failed else "completed",
                    "input": cls._remote_tool_text(arguments),
                    "output": cls._remote_tool_text(output),
                    "detail": cls._remote_tool_text(output),
                    "error": str(call.get("error") or "")[:500] if failed else "",
                    "order": sidecar_order,
                    "sourceIndex": assistant_index,
                    "historical": True,
                    "terminal": True,
                }
            )

        # Keep an unmatched role:tool result visible as an activity card rather
        # than losing potentially useful history or rendering it as agent prose.
        for orphan_index, result in enumerate(orphan_results):
            tool_id = f"remote-orphan-tool-{session_id}-{result['sourceIndex']}-{orphan_index}"
            upsert_tool(
                {
                    "id": tool_id,
                    "toolCallId": tool_id,
                    "name": result.get("name") or "Tool result",
                    "label": "",
                    "status": "error" if result.get("failed") else "completed",
                    "input": "",
                    "output": result.get("output") or "",
                    "detail": result.get("output") or "",
                    "error": "Tool failed" if result.get("failed") else "",
                    "order": result.get("order") or 0,
                    "sourceIndex": result.get("sourceIndex", -1),
                    "historical": True,
                    "terminal": True,
                }
            )

        # A result can have a stable id while its assistant carrier was omitted
        # by an older server. Preserve it as a named card as a final fallback.
        for tool_id, result in results.items():
            if tool_id in tools_by_id:
                continue
            upsert_tool(
                {
                    "id": tool_id,
                    "toolCallId": tool_id,
                    "name": result.get("name") or "Tool result",
                    "label": "",
                    "status": "error" if result.get("failed") else "completed",
                    "input": "",
                    "output": result.get("output") or "",
                    "detail": result.get("output") or "",
                    "error": "Tool failed" if result.get("failed") else "",
                    "order": result.get("order") or 0,
                    "sourceIndex": result.get("sourceIndex", -1),
                    "historical": True,
                    "terminal": True,
                }
            )

        projected_messages.sort(key=lambda row: (row.get("order", 0), row["id"]))
        tools = [tools_by_id[tool_id] for tool_id in tool_order]
        tools.sort(key=lambda row: (row.get("order", 0), row["id"]))

        if len(projected_messages) > REMOTE_HISTORY_MAX_MESSAGES:
            projected_messages = projected_messages[-REMOTE_HISTORY_MAX_MESSAGES:]
            floor = int(projected_messages[0].get("order") or 0)
            tools = [tool for tool in tools if int(tool.get("order") or 0) >= floor]
        if len(tools) > REMOTE_HISTORY_MAX_TOOLS:
            tools = tools[-REMOTE_HISTORY_MAX_TOOLS:]
        return {"messages": projected_messages, "tools": tools}

    def remote_display_messages(
        self, session_id: str, messages: Any
    ) -> list[dict[str, Any]]:
        """Compatibility wrapper returning only renderable prose messages."""

        return self.project_remote_transcript(session_id, messages)["messages"]

    @staticmethod
    def remote_session_state(session: dict[str, Any]) -> dict[str, Any]:
        """Extract the bounded, presentation-safe state attached to a session GET."""

        state: dict[str, Any] = {}
        todo_state = session.get("todo_state")
        if isinstance(todo_state, dict):
            todos = todo_state.get("todos")
            summary = todo_state.get("summary")
            state["todos"] = todos[:100] if isinstance(todos, list) else []
            state["todoSummary"] = summary if isinstance(summary, dict) else {}
            state["todoVersion"] = todo_state.get("version")
            state["todoUpdatedAt"] = todo_state.get("ts")

        context: dict[str, Any] = {}
        for source, target in (
            ("context_length", "contextLength"),
            ("threshold_tokens", "thresholdTokens"),
            ("last_prompt_tokens", "lastPromptTokens"),
            ("post_compression_context_tokens_estimate", "postCompressionTokens"),
        ):
            value = session.get(source)
            if isinstance(value, (int, float)) and value >= 0:
                context[target] = value
        if context:
            state["context"] = context

        journal = session.get("runtime_journal")
        if isinstance(journal, dict):
            state["runtimeJournal"] = {
                key: journal[key]
                for key in (
                    "run_id",
                    "stream_id",
                    "status",
                    "active",
                    "started_at",
                    "updated_at",
                    "last_event_id",
                )
                if key in journal
            }
        active_stream = str(session.get("active_stream_id") or "")
        if active_stream:
            state["activeStreamId"] = active_stream[:1024]
        pending_steer = session.get("pending_steer")
        if isinstance(pending_steer, str) and pending_steer.strip():
            state["pendingSteer"] = pending_steer.strip()[:2000]
        regeneration_revision = session.get("regeneration_revision")
        if isinstance(regeneration_revision, str) and regeneration_revision.strip():
            state["regenerationRevision"] = regeneration_revision.strip()[:512]
        return state

    async def apply_remote_session_snapshot(
        self,
        conversation: dict[str, Any],
        session: Any,
        *,
        history_mode: str = "replace",
        requested_limit: int = REMOTE_HISTORY_PAGE,
    ) -> dict[str, Any]:
        if not isinstance(session, dict):
            raise RpcFault(-32045, "Remote Hermes returned an invalid session")
        old_session_id = conversation.get("remote_session_id", "")
        session_id = str(session.get("session_id") or old_session_id)
        if session_id and session_id != old_session_id:
            if old_session_id:
                self.conversation_by_remote_session.pop(old_session_id, None)
            conversation["remote_session_id"] = session_id
            conversation["remote_origin"] = self.remote_auth.base_url
            self.conversation_by_remote_session[session_id] = conversation["id"]
        try:
            message_offset = max(0, int(session.get("_messages_offset") or 0))
        except (TypeError, ValueError):
            message_offset = 0
        projection = self.project_remote_transcript(
            session_id,
            session.get("messages", []),
            session.get("tool_calls", []),
            offset=message_offset,
        )
        messages = projection["messages"]
        tools = projection["tools"]
        if any(
            str(row.get("role") or "") in {"user", "assistant"}
            for row in messages
        ):
            conversation["has_messages"] = True
        raw_message_rows = session.get("messages")
        raw_message_count = len(raw_message_rows) if isinstance(raw_message_rows, list) else 0
        try:
            conversation["message_count"] = max(
                0, int(session.get("message_count", raw_message_count))
            )
        except (TypeError, ValueError):
            conversation["message_count"] = raw_message_count
        conversation["title"] = str(
            session.get("title") or conversation.get("title") or "Untitled chat"
        )[:160]
        conversation["name"] = conversation["title"]
        conversation["model"] = str(
            session.get("model") or conversation.get("model") or ""
        )[:256]
        conversation["model_provider"] = str(
            session.get("model_provider") or session.get("provider")
            or conversation.get("model_provider") or ""
        )[:128]
        conversation["profile"] = str(
            session.get("profile") or conversation.get("profile") or ""
        )[:128]
        conversation["cwd"] = str(
            session.get("workspace") or conversation.get("cwd") or ""
        )[:4096]
        conversation["read_only"] = bool(
            session.get("read_only", conversation.get("read_only", False))
        )
        conversation["created_at"] = self._remote_time(
            session.get("created_at")
        ) or conversation.get("created_at", "")
        conversation["updated_at"] = self._remote_time(
            session.get("last_message_at") or session.get("updated_at")
        ) or conversation.get("updated_at", "") or utc_now()
        self.registry.save()
        if any(
            key in session
            for key in ("_messages_truncated", "_messages_offset", "_msg_limit_max")
        ):
            await self.update_remote_contract(historyPagination=True)
        truncated = session.get("_messages_truncated") is True or message_offset > 0
        payload = self.routed_payload(
            conversation,
            {
                "messages": messages,
                "tools": tools,
                "history": {
                    "mode": "prepend" if history_mode == "prepend" else "replace",
                    "hasMore": truncated,
                    "offset": message_offset,
                    "limit": requested_limit,
                    "messageCount": conversation["message_count"],
                    "serverLimit": session.get("_msg_limit_max"),
                },
                "sessionState": self.remote_session_state(session),
            },
        )
        await self.broadcast_event(
            "message.page" if history_mode == "prepend" else "message.snapshot",
            payload,
        )
        public = self.public_conversation(conversation)
        await self.broadcast_event(
            "conversation.updated", {"conversation": public, **public}
        )
        return payload

    async def remote_history(
        self, conversation: dict[str, Any], params: dict[str, Any] | None = None
    ) -> dict[str, Any]:
        session_id = await self.ensure_remote_session(conversation)
        values = params or {}
        try:
            requested_limit = int(values.get("limit") or REMOTE_HISTORY_PAGE)
        except (TypeError, ValueError):
            requested_limit = REMOTE_HISTORY_PAGE
        requested_limit = max(1, min(requested_limit, REMOTE_HISTORY_PAGE))
        before_value = values.get(
            "before", values.get("messageBefore", values.get("message_before"))
        )
        try:
            before = max(0, int(before_value)) if before_value is not None else None
        except (TypeError, ValueError):
            before = None
        path = (
            "/api/session?session_id="
            + quote(session_id, safe="")
            + "&messages=1&expand_renderable=1&msg_limit="
            + str(requested_limit)
        )
        if before is not None:
            path += "&msg_before=" + str(before)
        result = await self.remote_request(
            "GET",
            path,
            timeout=30,
        )
        session = result.get("session")
        if self.remote_session_needs_import(session):
            # Hermes exposes CLI and messaging history as a read-only import
            # until a WebUI client claims it. Mirror the WebUI sidebar's
            # import_cli step before publishing the snapshot; otherwise QML
            # sees readOnly=true and permanently disables the composer.
            try:
                await self.remote_request(
                    "POST",
                    "/api/session/import_cli",
                    {"session_id": session_id},
                    timeout=30,
                )
            except RpcFault:
                # Import is a compatibility upgrade, not a prerequisite for
                # reading history. Older WebUIs and genuinely non-importable
                # transcripts must still open in their read-only form.
                pass
            else:
                result = await self.remote_request(
                    "GET",
                    path,
                    timeout=30,
                )
                session = result.get("session")
        payload = await self.apply_remote_session_snapshot(
            conversation,
            session,
            history_mode="prepend" if before is not None else "replace",
            requested_limit=requested_limit,
        )
        if isinstance(session, dict):
            active_stream = str(session.get("active_stream_id") or "")
            if active_stream:
                await self.start_remote_stream(conversation, session_id, active_stream)
        return payload

    @staticmethod
    def remote_session_needs_import(session: Any) -> bool:
        """Match the WebUI's writable-import gate for external transcripts."""

        if not isinstance(session, dict) or not bool(
            session.get("read_only", session.get("is_read_only", False))
        ):
            return False
        session_source = str(session.get("session_source") or "").strip().lower()
        if session_source == "webui":
            return False
        if session.get("is_cli_session") is True or session_source == "cli":
            return True
        if session_source == "messaging":
            return True
        source = str(
            session.get("raw_source")
            or session.get("source_tag")
            or session.get("source")
            or ""
        ).strip().lower()
        return source in {
            "weixin",
            "telegram",
            "discord",
            "slack",
            "email",
            "wecom",
            "wecom_callback",
            "matrix",
        }

    async def remote_session_status(
        self, conversation: dict[str, Any]
    ) -> dict[str, Any]:
        session_id = await self.ensure_remote_session(conversation)
        result = await self.remote_request(
            "GET",
            "/api/session/status?session_id=" + quote(session_id, safe=""),
            timeout=20,
        )
        active_stream = str(result.get("active_stream_id") or "")
        turn_complete = (
            bool(active_stream)
            and self.remote_stream_completed.get(conversation["id"]) == active_stream
        )
        running = (
            result.get("agent_running") is True or bool(active_stream)
        ) and not turn_complete
        if active_stream:
            await self.start_remote_stream(conversation, session_id, active_stream)
        # This endpoint is authoritative after a reconnect/restart. A remote
        # session with no run and no active stream has recovered even when the
        # last persisted client state was a definitive prompt error.
        desired = "working" if running else "idle"
        text = "Hermes is working…" if running else "Ready"
        if desired != conversation["status"] or text != conversation["status_text"]:
            await self.set_conversation_status(conversation, desired, text)
        return self.routed_payload(
            conversation,
            {
                "status": desired,
                "statusText": text,
                "upstream": result,
            },
        )

    async def remote_session_configure(
        self, conversation: dict[str, Any], params: dict[str, Any]
    ) -> dict[str, Any]:
        session_id = await self.ensure_remote_session(conversation)
        model = str(params.get("model") or "").strip()[:256]
        provider = str(
            params.get("modelProvider") or params.get("model_provider")
            or params.get("provider") or ""
        ).strip()[:128]
        if not model:
            raise RpcFault(-32602, "model is required")
        body: dict[str, Any] = {
            "session_id": session_id,
            "workspace": conversation.get("cwd") or "",
            "model": model,
            "model_provider": provider or None,
        }
        result = await self.remote_request(
            "POST", "/api/session/update", body, timeout=30
        )
        session = result.get("session") if isinstance(result, dict) else None
        accepted_model = str(
            (session.get("model") or model)
            if isinstance(session, dict) else model
        ).strip()[:256] or model
        accepted_provider = str(
            (session.get("model_provider") or session.get("provider") or provider)
            if isinstance(session, dict) else provider
        ).strip()[:128] or provider
        conversation["model"] = accepted_model
        conversation["model_provider"] = accepted_provider
        conversation["updated_at"] = utc_now()
        self.registry.save()
        public = self.public_conversation(conversation)
        await self.update_remote_contract(modelSelection=True)
        await self.broadcast_event(
            "conversation.updated", {"conversation": public, **public}
        )
        return self.routed_payload(
            conversation, {"conversation": public, "upstream": result, **public}
        )

    @staticmethod
    def local_attachment(path_value: Any) -> tuple[str, bytes, str]:
        """Read one user-selected regular file without following a final symlink."""

        if not isinstance(path_value, str) or not path_value.strip():
            raise RpcFault(-32602, "Attachment path is invalid")
        candidate = Path(path_value).expanduser()
        if not candidate.is_absolute():
            raise RpcFault(-32602, "Attachment path must be absolute")
        try:
            resolved = candidate.resolve(strict=True)
            descriptor = os.open(
                resolved, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
            )
        except (OSError, RuntimeError) as exc:
            raise RpcFault(-32602, "Attachment could not be opened") from exc
        try:
            details = os.fstat(descriptor)
            if not stat.S_ISREG(details.st_mode):
                raise RpcFault(-32602, "Attachment must be a regular file")
            if details.st_size > MAX_REMOTE_ATTACHMENT_BYTES:
                raise RpcFault(-32602, "Attachment is larger than 20 MiB")
            chunks: list[bytes] = []
            remaining = MAX_REMOTE_ATTACHMENT_BYTES + 1
            while remaining > 0:
                chunk = os.read(descriptor, min(1024 * 1024, remaining))
                if not chunk:
                    break
                chunks.append(chunk)
                remaining -= len(chunk)
            data = b"".join(chunks)
            if len(data) > MAX_REMOTE_ATTACHMENT_BYTES:
                raise RpcFault(-32602, "Attachment is larger than 20 MiB")
        finally:
            os.close(descriptor)
        mime_type = mimetypes.guess_type(resolved.name)[0] or "application/octet-stream"
        return resolved.name[:200], data, mime_type[:160]

    async def remote_upload_attachments(
        self, session_id: str, raw_paths: Any
    ) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
        if raw_paths in (None, []):
            return [], []
        if not isinstance(raw_paths, list):
            raise RpcFault(-32602, "attachments must be a list")
        if len(raw_paths) > MAX_REMOTE_ATTACHMENTS:
            raise RpcFault(-32602, "A prompt can contain at most 20 attachments")

        uploads: list[dict[str, Any]] = []
        public: list[dict[str, Any]] = []
        seen: set[str] = set()
        for raw_path in raw_paths:
            path_text = str(raw_path) if isinstance(raw_path, str) else ""
            if not path_text or path_text in seen:
                continue
            seen.add(path_text)
            filename, data, mime_type = self.local_attachment(path_text)
            previous_status = self.remote_auth.status
            try:
                result = await self.remote_auth.upload_file(
                    "/api/upload",
                    {"session_id": session_id},
                    filename,
                    data,
                    mime_type,
                    timeout=90,
                )
            except RemoteLoginFault:
                await self.publish_remote_status(
                    self.remote_auth.status, previous_status
                )
                raise
            except RpcFault as fault:
                await self.downgrade_remote_action("attachments", fault)
                raise
            server_path = str(result.get("path") or "").strip()
            uploaded_name = str(result.get("filename") or filename).strip()[:200]
            if not server_path or len(server_path) > 4096:
                raise RpcFault(-32045, "Remote Hermes returned an invalid upload")
            try:
                size = max(0, min(MAX_REMOTE_ATTACHMENT_BYTES, int(result.get("size") or len(data))))
            except (TypeError, ValueError):
                size = len(data)
            uploaded_mime = str(result.get("mime") or mime_type).strip()[:160]
            is_image = result.get("is_image") is True or uploaded_mime.startswith("image/")
            uploads.append({
                "name": uploaded_name or filename,
                "filename": uploaded_name or filename,
                "path": server_path,
                "size": size,
                "mime": uploaded_mime,
                "is_image": is_image,
            })
            public.append({
                "name": uploaded_name or filename,
                "size": size,
                "mime": uploaded_mime,
                "isImage": is_image,
            })
        if uploads:
            await self.update_remote_contract(attachments=True)
        return uploads, public

    async def remote_branch_conversation(
        self, conversation: dict[str, Any], params: dict[str, Any]
    ) -> dict[str, Any]:
        session_id = await self.ensure_remote_session(conversation)
        body: dict[str, Any] = {"session_id": session_id}
        keep_value = params.get("keepCount", params.get("keep_count"))
        if keep_value is not None:
            try:
                keep_count = int(keep_value)
            except (TypeError, ValueError) as exc:
                raise RpcFault(-32602, "keepCount must be an integer") from exc
            if keep_count < 0:
                raise RpcFault(-32602, "keepCount must be non-negative")
            body["keep_count"] = keep_count
        title = params.get("title")
        if isinstance(title, str) and title.strip():
            body["title"] = title.strip()[:80]
        result: dict[str, Any] | None = None
        native_branch = self.remote_contract.get("nativeBranches") is True
        if native_branch:
            try:
                result = await self.remote_request(
                    "POST", "/api/session/branch", body, timeout=45
                )
            except RpcFault as fault:
                details = fault.data if isinstance(fault.data, dict) else {}
                if int(details.get("statusCode") or 0) not in {404, 405, 410, 501}:
                    raise
                await self.update_remote_contract(nativeBranches=False)
        if result is None:
            if self.remote_contract.get("duplicateSessions") is not True \
                    or self.remote_contract.get("messageEditing") is not True:
                await self.update_remote_contract(branches=False)
                raise RpcFault(-32601, "This Hermes WebUI does not support branches")
            try:
                duplicate = await self.remote_request(
                    "POST",
                    "/api/session/duplicate",
                    {"session_id": session_id},
                    timeout=60,
                )
            except RpcFault as fault:
                details = fault.data if isinstance(fault.data, dict) else {}
                if int(details.get("statusCode") or 0) in {404, 405, 410, 501}:
                    await self.update_remote_contract(
                        duplicateSessions=False, branches=False
                    )
                raise
            duplicate_session = duplicate.get("session")
            branch_id = str(
                duplicate_session.get("session_id")
                if isinstance(duplicate_session, dict) else ""
            ).strip()
            if not CONVERSATION_ID_PATTERN.fullmatch(branch_id):
                raise RpcFault(-32045, "Remote Hermes returned an invalid branch")
            try:
                if "keep_count" in body:
                    await self.remote_request(
                        "POST",
                        "/api/session/truncate",
                        {
                            "session_id": branch_id,
                            "keep_count": body["keep_count"],
                        },
                        timeout=60,
                    )
                branch_title = str(
                    body.get("title")
                    or f"{conversation.get('title') or 'Untitled chat'} (fork)"
                )[:80]
                await self.remote_request(
                    "POST",
                    "/api/session/rename",
                    {"session_id": branch_id, "title": branch_title},
                    timeout=30,
                )
            except RpcFault:
                with suppress(RpcFault):
                    await self.remote_request(
                        "POST",
                        "/api/session/delete",
                        {"session_id": branch_id},
                        timeout=30,
                    )
                raise
            result = {
                "session_id": branch_id,
                "title": branch_title,
                "parent_session_id": session_id,
                "fallback": "duplicate_truncate",
            }
        branch_id = str(result.get("session_id") or "").strip()
        if not CONVERSATION_ID_PATTERN.fullmatch(branch_id):
            raise RpcFault(-32045, "Remote Hermes returned an invalid branch")
        snapshot = await self.remote_request(
            "GET",
            "/api/session?session_id=" + quote(branch_id, safe="")
            + "&messages=1&expand_renderable=1&msg_limit="
            + str(REMOTE_HISTORY_PAGE),
            timeout=30,
        )
        session = snapshot.get("session")
        if not isinstance(session, dict):
            raise RpcFault(-32045, "Remote Hermes returned an invalid branch")
        branch = self.remote_conversation_record(session)
        self.registry.conversations[branch["id"]] = branch
        self.conversation_by_remote_session[branch_id] = branch["id"]
        await self.update_remote_contract(branches=True)
        await self.select_conversation(branch)
        await self.apply_remote_session_snapshot(branch, session)
        public = self.public_conversation(branch)
        await self.broadcast_event(
            "conversation.created", {"conversation": public, **public}
        )
        return self.routed_payload(
            branch,
            {
                "conversation": public,
                "parentSessionId": session_id,
                "upstream": result,
                **public,
            },
        )

    async def remote_edit_message(
        self, conversation: dict[str, Any], params: dict[str, Any]
    ) -> dict[str, Any]:
        text = params.get("text")
        if not isinstance(text, str) or not text.strip():
            raise RpcFault(-32602, "Edited message text is required")
        if len(text.encode("utf-8")) > MAX_DOWNSTREAM_MESSAGE:
            raise RpcFault(-32602, "Edited message is too large")
        source_value = params.get("sourceIndex", params.get("source_index"))
        try:
            keep_count = int(source_value)
        except (TypeError, ValueError) as exc:
            raise RpcFault(-32602, "Message source index is required") from exc
        if keep_count < 0:
            raise RpcFault(-32602, "Message source index is invalid")
        session_id = await self.ensure_remote_session(conversation)
        try:
            truncated = await self.remote_request(
                "POST",
                "/api/session/truncate",
                {"session_id": session_id, "keep_count": keep_count},
                timeout=45,
            )
        except RpcFault as fault:
            await self.downgrade_remote_action("messageEditing", fault)
            raise
        session = truncated.get("session")
        if isinstance(session, dict):
            await self.apply_remote_session_snapshot(conversation, session)
        await self.update_remote_contract(messageEditing=True)
        submit_params = dict(params)
        submit_params["displayText"] = text.strip()
        return await self.remote_prompt_submit(conversation, text, submit_params)

    async def remote_regenerate(
        self, conversation: dict[str, Any]
    ) -> dict[str, Any]:
        session_id = await self.ensure_remote_session(conversation)
        snapshot = await self.remote_request(
            "GET",
            "/api/session?session_id=" + quote(session_id, safe="")
            + "&messages=1&expand_renderable=1&msg_limit=1",
            timeout=30,
        )
        session = snapshot.get("session")
        revision = str(
            session.get("regeneration_revision") if isinstance(session, dict) else ""
            or ""
        ).strip()
        if not revision:
            raise RpcFault(-32046, "This conversation has no response to regenerate")
        await self.set_conversation_status(
            conversation, "working", "Regenerating Hermes response…"
        )
        try:
            result = await self.remote_request(
                "POST",
                "/api/chat/start",
                {
                    "session_id": session_id,
                    "regenerate": True,
                    "regeneration_revision": revision[:512],
                },
                timeout=45,
            )
        except AmbiguousDelivery as fault:
            await self.set_conversation_status(
                conversation,
                "reconnecting",
                "Checking Hermes after regeneration disconnected…",
            )
            await self.broadcast_event(
                "session.error",
                self.routed_payload(
                    conversation,
                    {
                        "message": fault.message,
                        "deliveryUnknown": True,
                        "replayed": False,
                    },
                ),
            )
            raise
        except RpcFault as fault:
            await self.downgrade_remote_action("regeneration", fault)
            await self.set_conversation_status(conversation, "error", fault.message)
            raise
        stream_id = str(result.get("stream_id") or "")
        if not stream_id:
            await self.set_conversation_status(conversation, "error", "Regeneration failed")
            raise RpcFault(-32045, "Remote Hermes did not start regeneration")
        await self.update_remote_contract(regeneration=True)
        await self.broadcast_event(
            "message.start",
            self.routed_payload(
                conversation,
                {
                    "id": f"remote-assistant-{stream_id}",
                    "role": "assistant",
                    "text": "",
                    "streamId": stream_id,
                },
            ),
        )
        await self.start_remote_stream(conversation, session_id, stream_id)
        with suppress(RpcFault):
            await self.remote_history(conversation, {"limit": REMOTE_HISTORY_PAGE})
        return self.routed_payload(
            conversation,
            {"accepted": True, "streamId": stream_id, "upstream": result},
        )

    async def remote_prompt_submit(
        self,
        conversation: dict[str, Any],
        text: str,
        params: dict[str, Any],
    ) -> dict[str, Any]:
        session_id = await self.ensure_remote_session(conversation)
        uploaded: list[dict[str, Any]] = []
        public_attachments: list[dict[str, Any]] = []
        raw_attachments = params.get("attachments")
        if isinstance(raw_attachments, list) and raw_attachments:
            await self.set_conversation_status(
                conversation, "working", "Uploading attachments…"
            )
            try:
                uploaded, public_attachments = await self.remote_upload_attachments(
                    session_id, raw_attachments
                )
            except RpcFault as fault:
                await self.set_conversation_status(conversation, "error", fault.message)
                raise
        attachment_names = [str(row.get("name") or "Attachment") for row in uploaded]
        agent_text = text.strip()
        if uploaded:
            attachment_note = ", ".join(attachment_names)
            if agent_text:
                agent_text += "\n\n[Attached files: " + attachment_note + "]"
            else:
                agent_text = (
                    f"I've attached {len(uploaded)} file(s): {attachment_note}"
                )
        await self.set_conversation_status(conversation, "working", "Hermes is working…")
        previously_had_messages = conversation["has_messages"]
        body: dict[str, Any] = {
            "session_id": session_id,
            "message": agent_text,
        }
        if uploaded:
            body["attachments"] = uploaded
        model = str(params.get("model") or conversation.get("model") or "").strip()
        provider = str(
            params.get("modelProvider") or params.get("model_provider")
            or params.get("provider") or conversation.get("model_provider") or ""
        ).strip()
        if model:
            body["model"] = model[:256]
        if provider:
            body["model_provider"] = provider[:128]
        if conversation.get("cwd"):
            body["workspace"] = str(conversation["cwd"])[:4096]
        if conversation.get("profile"):
            body["profile"] = str(conversation["profile"])[:128]
        if params.get("explicitModelPick") is True \
                or params.get("explicit_model_pick") is True:
            body["explicit_model_pick"] = True
        try:
            result = await self.remote_request(
                "POST",
                "/api/chat/start",
                body,
                timeout=45,
            )
        except AmbiguousDelivery as fault:
            conversation["has_messages"] = True
            self.registry.save()
            await self.set_conversation_status(
                conversation, "reconnecting", "Checking remote Hermes after disconnect…"
            )
            await self.broadcast_event(
                "session.error",
                self.routed_payload(
                    conversation,
                    {
                        "message": fault.message,
                        "deliveryUnknown": True,
                        "replayed": False,
                    },
                ),
            )
            raise
        except RpcFault as fault:
            details = dict(fault.data) if isinstance(fault.data, dict) else {}
            details["promptAccepted"] = False
            fault.data = details
            active_stream_id = str(details.get("activeStreamId") or "")
            if active_stream_id:
                conversation["has_messages"] = True
                self.registry.save()
                await self.set_conversation_status(
                    conversation,
                    "working",
                    "Following the existing Hermes response…",
                )
                await self.start_remote_stream(
                    conversation, session_id, active_stream_id
                )
            else:
                conversation["has_messages"] = previously_had_messages
                self.registry.save()
                await self.set_conversation_status(conversation, "error", fault.message)
            await self.broadcast_event(
                "session.error",
                self.routed_payload(
                    conversation,
                    {
                        "message": fault.message,
                        "promptAccepted": False,
                        "errorType": str(details.get("errorType") or ""),
                        "retryable": details.get("retryable") is True,
                        "activeStreamId": active_stream_id or None,
                    },
                ),
            )
            raise
        stream_id = str(result.get("stream_id") or "")
        if not stream_id:
            raise RpcFault(-32045, "Remote Hermes did not start a response stream")
        conversation["has_messages"] = True
        self.registry.save()
        display_text = str(params.get("displayText") or text).strip()
        if not display_text and public_attachments:
            display_text = "Attached " + ", ".join(
                str(row.get("name") or "file") for row in public_attachments
            )
        await self.broadcast_event(
            "message.created",
            self.routed_payload(
                conversation,
                {
                    "id": f"remote-user-{stream_id}",
                    "role": "user",
                    "text": display_text,
                    "attachments": public_attachments,
                    "createdAt": utc_now(),
                },
            ),
        )
        await self.broadcast_event(
            "message.start",
            self.routed_payload(
                conversation,
                {
                    "id": f"remote-assistant-{stream_id}",
                    "role": "assistant",
                    "text": "",
                    "streamId": stream_id,
                },
            ),
        )
        await self.start_remote_stream(conversation, session_id, stream_id)
        return self.routed_payload(
            conversation,
            {"accepted": True, "streamId": stream_id, "upstream": result},
        )

    async def remote_interrupt(self, conversation: dict[str, Any]) -> dict[str, Any]:
        session_id = await self.ensure_remote_session(conversation)
        stream_id = self.remote_stream_by_conversation.get(conversation["id"], "")
        if not stream_id:
            status = await self.remote_request(
                "GET",
                "/api/session/status?session_id=" + quote(session_id, safe=""),
                timeout=20,
            )
            stream_id = str(status.get("active_stream_id") or "")
        if not stream_id:
            await self.set_conversation_status(conversation, "idle", "Ready")
            return self.routed_payload(conversation, {"cancelled": False})
        result = await self.remote_request(
            "GET",
            "/api/chat/cancel?stream_id=" + quote(stream_id, safe=""),
            timeout=30,
        )
        await self.set_conversation_status(conversation, "idle", "Interrupted")
        return self.routed_payload(
            conversation,
            {
                "cancelled": result.get("cancelled") is not False,
                "streamId": stream_id,
                "upstream": result,
            },
        )

    async def remote_steer(
        self, conversation: dict[str, Any], text: str
    ) -> dict[str, Any]:
        session_id = await self.ensure_remote_session(conversation)
        result = await self.remote_request(
            "POST",
            "/api/chat/steer",
            {"session_id": session_id, "text": text},
            timeout=30,
        )
        if result.get("accepted") is not True:
            raise RpcFault(-32046, "Remote Hermes could not apply that guidance")
        return self.routed_payload(conversation, {"upstream": result})

    async def remote_respond_to_request(
        self, method: str, params: dict[str, Any]
    ) -> dict[str, Any]:
        conversation = self.resolve_conversation(params)
        session_id = await self.ensure_remote_session(conversation)
        request_id = str(params.get("requestId") or params.get("request_id") or "")
        if method == "approval.respond":
            decision = str(params.get("choice") or params.get("decision") or "deny")
            choice = {
                "allow": "once",
                "allow_once": "once",
                "allow-once": "once",
                "allow_session": "session",
                "allow-session": "session",
                "allow_always": "always",
                "allow-always": "always",
            }.get(decision, decision)
            body: dict[str, Any] = {
                "session_id": session_id,
                "choice": choice,
                "approval_id": request_id,
            }
            result = await self.remote_request(
                "POST", "/api/approval/respond", body, timeout=30
            )
        elif method == "clarify.respond":
            answer = params.get("answer", params.get("choice", params.get("value", "")))
            if isinstance(answer, list):
                answer = ", ".join(str(item) for item in answer)
            result = await self.remote_request(
                "POST",
                "/api/clarify/respond",
                {
                    "session_id": session_id,
                    "response": str(answer),
                    "clarify_id": request_id,
                },
                timeout=30,
            )
        else:
            raise RpcFault(
                -32601,
                "This remote Hermes WebUI does not expose that credential prompt",
            )
        await self.broadcast_event(
            "request.resolved",
            self.routed_payload(conversation, {"requestId": request_id}),
        )
        await self.set_conversation_status(conversation, "working", "Hermes is working…")
        return self.routed_payload(conversation, {"upstream": result})

    async def start_remote_stream(
        self,
        conversation: dict[str, Any],
        session_id: str,
        stream_id: str,
    ) -> None:
        """Attach one supervised SSE reader to a remote WebUI run.

        Reattaching a stream is safe because the WebUI journal accepts both an
        ``after_event_id`` query parameter and the standard ``Last-Event-ID``
        header. Starting a prompt is deliberately *not* part of this method:
        reconnects can only resume observation and can never replay a prompt.
        """

        conversation_id = conversation["id"]
        session_id = str(session_id or "")
        stream_id = str(stream_id or "")
        if not session_id or not stream_id:
            raise RpcFault(-32045, "Remote Hermes returned an invalid stream")
        if len(session_id) > 1024 or len(stream_id) > 1024:
            raise RpcFault(-32045, "Remote Hermes returned an invalid stream id")

        current_task = self.remote_stream_tasks.get(conversation_id)
        if (
            self.remote_stream_by_conversation.get(conversation_id) == stream_id
            and current_task is not None
            and not current_task.done()
        ):
            return
        if current_task is not None or conversation_id in self.remote_stream_by_conversation:
            await self.stop_remote_stream(conversation_id)

        self.remote_stream_by_conversation[conversation_id] = stream_id
        self.remote_stream_event_ids[conversation_id] = ""
        self.remote_stream_text[conversation_id] = ""
        self.remote_stream_reasoning[conversation_id] = ""
        self.remote_stream_completed.pop(conversation_id, None)
        task = asyncio.create_task(
            self._remote_stream_loop(conversation_id, session_id, stream_id),
            name=f"hermes-remote-stream-{conversation_id}",
        )
        self.remote_stream_tasks[conversation_id] = task
        task.add_done_callback(HermesGateway._log_background_failure)

    async def stop_remote_stream(self, conversation_id: str) -> None:
        """Stop one SSE reader and release its blocking HTTP response."""

        task = self.remote_stream_tasks.pop(conversation_id, None)
        self.remote_stream_by_conversation.pop(conversation_id, None)
        with self.remote_stream_response_lock:
            response = self.remote_stream_responses.pop(conversation_id, None)

        current = asyncio.current_task()
        if task is not None and task is not current and not task.done():
            task.cancel()
        if response is not None:
            with suppress(Exception):
                await asyncio.to_thread(response.close)
        if task is not None and task is not current:
            with suppress(asyncio.CancelledError, Exception):
                await task

        # Do not erase a newer stream that won a race while the old response
        # was closing. In normal operation the conversation has no replacement yet.
        if conversation_id not in self.remote_stream_by_conversation:
            self.remote_stream_event_ids.pop(conversation_id, None)
            self.remote_stream_text.pop(conversation_id, None)
            self.remote_stream_reasoning.pop(conversation_id, None)
            self.remote_stream_completed.pop(conversation_id, None)

    async def stop_remote_streams(self) -> None:
        """Stop every remote reader during logout and bridge shutdown."""

        conversation_ids = set(self.remote_stream_by_conversation)
        conversation_ids.update(self.remote_stream_tasks)
        with self.remote_stream_response_lock:
            conversation_ids.update(self.remote_stream_responses)
        if conversation_ids:
            await asyncio.gather(
                *(self.stop_remote_stream(conversation_id) for conversation_id in conversation_ids)
            )

    async def _remote_stream_loop(
        self, conversation_id: str, session_id: str, stream_id: str
    ) -> None:
        """Consume, reconnect, and finally reconcile one WebUI SSE run."""

        failures = 0
        terminal = False
        try:
            while self.remote_stream_by_conversation.get(conversation_id) == stream_id:
                conversation = self.registry.conversations.get(conversation_id)
                if conversation is None:
                    return
                cursor = self.remote_stream_event_ids.get(conversation_id, "")
                path = "/api/chat/stream?stream_id=" + quote(stream_id, safe="")
                if cursor:
                    path += "&after_event_id=" + quote(cursor, safe="")
                response: Any = None
                saw_event = False
                prior_auth = self.remote_auth.status
                stream_fault: RpcFault | None = None
                try:
                    response = await asyncio.to_thread(
                        self.remote_auth.open_sse,
                        path,
                        last_event_id=cursor,
                        timeout=45,
                    )
                    if self.remote_stream_by_conversation.get(conversation_id) != stream_id:
                        return
                    with self.remote_stream_response_lock:
                        self.remote_stream_responses[conversation_id] = response
                    terminal, saw_event = await self._consume_remote_sse(
                        response, conversation, session_id, stream_id
                    )
                except asyncio.CancelledError:
                    raise
                except RemoteLoginFault as fault:
                    status = (
                        fault.data
                        if isinstance(fault.data, dict)
                        else self.remote_auth.status
                    )
                    await self.publish_remote_status(status, prior_auth)
                    await self.set_conversation_status(
                        conversation, "error", "Remote Hermes sign-in required"
                    )
                    await self.broadcast_event(
                        "session.error",
                        self.routed_payload(
                            conversation,
                            {
                                "message": "Remote Hermes sign-in required",
                                "authenticationRequired": True,
                                "streamId": stream_id,
                            },
                        ),
                    )
                    return
                except RpcFault as fault:
                    stream_fault = fault
                except (OSError, TimeoutError, UnicodeDecodeError) as exc:
                    LOG.debug(
                        "remote Hermes stream %s disconnected: %s",
                        stream_id,
                        type(exc).__name__,
                    )
                    stream_fault = RpcFault(
                        -32042, "Remote Hermes response stream disconnected"
                    )
                finally:
                    with self.remote_stream_response_lock:
                        if self.remote_stream_responses.get(conversation_id) is response:
                            self.remote_stream_responses.pop(conversation_id, None)
                    if response is not None:
                        with suppress(Exception):
                            await asyncio.to_thread(response.close)

                if terminal or self.remote_stream_by_conversation.get(conversation_id) != stream_id:
                    return

                # An EOF or transport fault is not a reason to replay a prompt.
                # Ask the authoritative run state whether journal reattachment
                # is useful or whether the persisted session can be settled.
                try:
                    status = await self.remote_request(
                        "GET",
                        "/api/chat/stream/status?stream_id="
                        + quote(stream_id, safe=""),
                        timeout=20,
                    )
                except RemoteLoginFault:
                    # remote_request published the sanitized expiry transition.
                    await self.set_conversation_status(
                        conversation, "error", "Remote Hermes sign-in required"
                    )
                    return
                except RpcFault as fault:
                    stream_fault = stream_fault or fault
                    status = {}

                active = status.get("active") is True
                replay_available = status.get("replay_available") is True
                if not active and status:
                    if self.remote_stream_completed.get(conversation_id) != stream_id:
                        await self._complete_remote_stream(
                            conversation,
                            session_id,
                            stream_id,
                            status="complete",
                        )
                    return

                failures = 0 if saw_event else failures + 1
                if saw_event and (active or replay_available):
                    failures = 0
                if failures >= 8 and not active and not replay_available:
                    message = (
                        stream_fault.message
                        if stream_fault is not None
                        else "Remote Hermes response stream is unavailable"
                    )
                    await self.set_conversation_status(conversation, "error", message)
                    await self.broadcast_event(
                        "session.error",
                        self.routed_payload(
                            conversation,
                            {
                                "message": message,
                                "streamId": stream_id,
                                "replayed": False,
                            },
                        ),
                    )
                    return

                if self.remote_stream_completed.get(conversation_id) != stream_id:
                    await self.set_conversation_status(
                        conversation,
                        "reconnecting",
                        "Reconnecting to remote Hermes…",
                    )
                delay = min(5.0, 0.25 * (2 ** min(failures, 5)))
                await asyncio.sleep(delay + random.random() * 0.15)
        finally:
            current = asyncio.current_task()
            if self.remote_stream_tasks.get(conversation_id) is current:
                self.remote_stream_tasks.pop(conversation_id, None)
            if self.remote_stream_by_conversation.get(conversation_id) == stream_id:
                self.remote_stream_by_conversation.pop(conversation_id, None)
                self.remote_stream_event_ids.pop(conversation_id, None)
                self.remote_stream_text.pop(conversation_id, None)
                self.remote_stream_reasoning.pop(conversation_id, None)
                self.remote_stream_completed.pop(conversation_id, None)
            with self.remote_stream_response_lock:
                self.remote_stream_responses.pop(conversation_id, None)

    async def _consume_remote_sse(
        self,
        response: Any,
        conversation: dict[str, Any],
        session_id: str,
        stream_id: str,
    ) -> tuple[bool, bool]:
        """Parse a standard SSE response, including multi-line data fields."""

        event_name = "message"
        data_lines: list[str] = []
        event_id = ""
        event_size = 0
        saw_event = False

        async def dispatch_event() -> bool:
            nonlocal event_name, data_lines, event_id, event_size, saw_event
            if not data_lines:
                if event_id:
                    self.remote_stream_event_ids[conversation["id"]] = event_id
                event_name = "message"
                event_id = ""
                event_size = 0
                return False
            raw_data = "\n".join(data_lines)
            try:
                parsed = json.loads(raw_data)
            except json.JSONDecodeError as exc:
                raise RpcFault(-32045, "Remote Hermes sent invalid event data") from exc
            data = parsed if isinstance(parsed, dict) else {"value": parsed}
            if event_id:
                self.remote_stream_event_ids[conversation["id"]] = event_id
            saw_event = True
            terminal_event = await self._handle_remote_sse_event(
                conversation,
                session_id,
                stream_id,
                event_name,
                event_id,
                data,
            )
            event_name = "message"
            data_lines = []
            event_id = ""
            event_size = 0
            return terminal_event

        while self.remote_stream_by_conversation.get(conversation["id"]) == stream_id:
            raw = await asyncio.to_thread(
                response.readline, MAX_REMOTE_SSE_EVENT + 1
            )
            if not raw:
                terminal = await dispatch_event()
                return terminal, saw_event
            if len(raw) > MAX_REMOTE_SSE_EVENT:
                raise RpcFault(-32045, "Remote Hermes event line is too large")
            try:
                line = raw.decode("utf-8")
            except UnicodeDecodeError as exc:
                raise RpcFault(-32045, "Remote Hermes event is not UTF-8") from exc
            line = line.rstrip("\r\n")
            if not line:
                if await dispatch_event():
                    return True, saw_event
                continue
            if line.startswith(":"):
                continue
            field, separator, value = line.partition(":")
            if not separator:
                value = ""
            elif value.startswith(" "):
                value = value[1:]
            if field == "event":
                event_name = value[:256] or "message"
            elif field == "data":
                event_size += len(raw)
                if event_size > MAX_REMOTE_SSE_EVENT:
                    raise RpcFault(-32045, "Remote Hermes event is too large")
                data_lines.append(value)
            elif field == "id" and "\x00" not in value:
                event_id = value[:1024]
        return False, saw_event

    def _append_remote_stream_text(self, conversation_id: str, text: str) -> str:
        current = self.remote_stream_text.get(conversation_id, "")
        remaining = max(0, MAX_REMOTE_STREAM_EVENT - len(current))
        if remaining:
            current += text[:remaining]
            self.remote_stream_text[conversation_id] = current
        return current

    def _remote_sse_payload(
        self,
        conversation: dict[str, Any],
        session_id: str,
        stream_id: str,
        event_name: str,
        event_id: str,
        data: dict[str, Any],
    ) -> dict[str, Any]:
        upstream_session = str(
            data.get("session_id") or data.get("sessionId") or session_id
        )
        return self.routed_payload(
            conversation,
            {
                **data,
                "streamId": stream_id,
                "eventId": event_id or None,
                "upstreamType": event_name,
                "upstreamSessionId": upstream_session,
            },
        )

    @staticmethod
    def _remote_tool_data(data: dict[str, Any]) -> dict[str, Any]:
        nested = data.get("tool")
        return {**nested, **data} if isinstance(nested, dict) else dict(data)

    async def _handle_remote_sse_event(
        self,
        conversation: dict[str, Any],
        session_id: str,
        stream_id: str,
        event_name: str,
        event_id: str,
        data: dict[str, Any],
    ) -> bool:
        """Normalize the WebUI event catalog into the stable QML contract."""

        event = event_name.strip().lower().replace("-", "_")
        base = self._remote_sse_payload(
            conversation, session_id, stream_id, event_name, event_id, data
        )
        assistant_id = f"remote-assistant-{stream_id}"

        if event in {"token", "text", "assistant_delta"}:
            chunk = str(data.get("text") or data.get("token") or "")
            if chunk:
                self._append_remote_stream_text(conversation["id"], chunk)
                await self.broadcast_event(
                    "message.delta",
                    {
                        **base,
                        "id": assistant_id,
                        "role": "assistant",
                        "text": chunk,
                        "delta": chunk,
                    },
                )
            return False

        if event == "interim_assistant":
            if data.get("already_streamed") is not True:
                chunk = str(data.get("text") or data.get("content") or "")
                if chunk:
                    self._append_remote_stream_text(conversation["id"], chunk)
                    await self.broadcast_event(
                        "message.delta",
                        {
                            **base,
                            "id": assistant_id,
                            "role": "assistant",
                            "text": chunk,
                            "delta": chunk,
                        },
                    )
            return False

        if event == "reasoning":
            chunk = str(data.get("text") or data.get("reasoning") or "")
            current = self.remote_stream_reasoning.get(conversation["id"], "")
            remaining = max(0, MAX_REMOTE_REASONING - len(current))
            if remaining:
                current += chunk[:remaining]
                self.remote_stream_reasoning[conversation["id"]] = current
            await self.broadcast_event(
                "session.reasoning",
                {
                    **base,
                    "kind": "reasoning",
                    "reasoning": chunk,
                    "status": "working",
                    "statusText": "Hermes is thinking…",
                },
            )
            return False

        if event == "warning":
            await self.broadcast_event(
                "session.warning",
                {
                    **base,
                    "kind": "warning",
                    "message": str(
                        data.get("message") or data.get("warning") or data.get("detail")
                        or "Hermes reported a warning"
                    )[:1000],
                },
            )
            return False

        if event == "context_status":
            await self.broadcast_event(
                "session.context", {**base, "kind": "context_status"}
            )
            return False

        if event == "todo_state":
            await self.broadcast_event(
                "session.todos", {**base, "kind": "todo_state"}
            )
            return False

        if event in {"goal", "goal_continue"}:
            await self.broadcast_event(
                "session.goal", {**base, "kind": event}
            )
            return False

        if event == "pending_steer_leftover":
            await self.broadcast_event(
                "session.pending_steer",
                {**base, "kind": "pending_steer_leftover"},
            )
            return False

        if event in {"tool", "tool_start"}:
            tool = self._remote_tool_data(data)
            tool_id = str(
                tool.get("tool_call_id")
                or tool.get("toolCallId")
                or tool.get("tid")
                or tool.get("call_id")
                or tool.get("id")
                or f"remote-tool-{stream_id}-{event_id or uuid.uuid4().hex}"
            )
            name = str(
                tool.get("name") or tool.get("tool_name") or tool.get("function") or "Tool"
            )
            await self.set_conversation_status(
                conversation, "working", self.tool_status_text(name)
            )
            await self.broadcast_event(
                "tool.start",
                {
                    **base,
                    **tool,
                    "id": tool_id,
                    "toolCallId": tool_id,
                    "name": name,
                    "status": "running",
                },
            )
            return False

        if event in {"tool_complete", "tool_completed", "tool_end"}:
            tool = self._remote_tool_data(data)
            tool_id = str(
                tool.get("tool_call_id")
                or tool.get("toolCallId")
                or tool.get("tid")
                or tool.get("call_id")
                or tool.get("id")
                or f"remote-tool-{stream_id}-{event_id or uuid.uuid4().hex}"
            )
            name = str(
                tool.get("name") or tool.get("tool_name") or tool.get("function") or "Tool"
            )
            failed = tool.get("is_error") is True or bool(tool.get("error"))
            await self.broadcast_event(
                "tool.complete",
                {
                    **base,
                    **tool,
                    "id": tool_id,
                    "toolCallId": tool_id,
                    "name": name,
                    "status": "error" if failed else "completed",
                },
            )
            await self.set_conversation_status(conversation, "working", "Hermes is working…")
            return False

        if event in {"approval", "approval_request"}:
            request_id = str(
                data.get("approval_id")
                or data.get("request_id")
                or data.get("id")
                or f"remote-approval-{stream_id}-{event_id or uuid.uuid4().hex}"
            )
            await self.set_conversation_status(conversation, "waiting", "Hermes needs approval")
            await self.broadcast_event(
                "request.approval",
                {
                    **base,
                    "id": request_id,
                    "requestId": request_id,
                    "kind": "approval",
                },
            )
            return False

        if event in {"clarify", "clarify_request"}:
            request_id = str(
                data.get("clarify_id")
                or data.get("request_id")
                or data.get("id")
                or f"remote-clarify-{stream_id}-{event_id or uuid.uuid4().hex}"
            )
            await self.set_conversation_status(conversation, "waiting", "Hermes has a question")
            await self.broadcast_event(
                "request.clarify",
                {
                    **base,
                    "id": request_id,
                    "requestId": request_id,
                    "kind": "clarify",
                    "options": data.get("options")
                    or data.get("choices")
                    or data.get("choices_offered")
                    or [],
                },
            )
            return False

        if event in {"compressing", "compression_start"}:
            await self.set_conversation_status(
                conversation, "working", "Hermes is compressing context…"
            )
            await self.broadcast_event(
                "session.info",
                {
                    **base,
                    "kind": "compressing",
                    "status": "working",
                    "statusText": "Hermes is compressing context…",
                },
            )
            return False

        if event in {"compressed", "compression_complete"}:
            await self.set_conversation_status(
                conversation, "working", "Hermes compressed context; finishing…"
            )
            await self.broadcast_event(
                "session.info",
                {
                    **base,
                    "kind": "compressed",
                    "status": "working",
                    "statusText": "Hermes compressed context; finishing…",
                },
            )
            return False

        if event in {"usage", "metering"}:
            await self.broadcast_event(
                "session.usage", {**base, "kind": event}
            )
            return False

        if event == "done":
            usage = data.get("usage")
            if isinstance(usage, dict):
                await self.broadcast_event(
                    "session.usage", {**base, **usage, "usage": usage}
                )
            if self.remote_stream_completed.get(conversation["id"]) != stream_id:
                await self._complete_remote_stream(
                    conversation,
                    session_id,
                    stream_id,
                    status=str(data.get("status") or "complete"),
                    session=data.get("session"),
                )
                self.remote_stream_completed[conversation["id"]] = stream_id
            # `done` is the turn-completion fence, not the transport fence.
            # WebUI publishes generated title metadata after it and closes the
            # journal only with `stream_end`.
            return False

        if event in {"cancel", "cancelled"}:
            await self._complete_remote_stream(
                conversation,
                session_id,
                stream_id,
                status="cancelled",
                session=data.get("session"),
                cancelled=True,
            )
            return True

        if event in {"apperror", "error"}:
            message = str(
                data.get("message")
                or data.get("error")
                or "Remote Hermes response failed"
            )[:500]
            text = self.remote_stream_text.get(conversation["id"], "")
            await self.broadcast_event(
                "message.complete",
                {
                    **base,
                    "id": assistant_id,
                    "role": "assistant",
                    "text": text,
                    "status": "error",
                    "error": message,
                },
            )
            session = data.get("session")
            if isinstance(session, dict):
                with suppress(RpcFault):
                    await self.apply_remote_session_snapshot(conversation, session)
            await self.set_conversation_status(conversation, "error", message, unread=True)
            await self.broadcast_event(
                "session.error", {**base, "message": message, "error": message}
            )
            return True

        if event == "stream_end":
            if self.remote_stream_completed.get(conversation["id"]) != stream_id:
                await self._complete_remote_stream(
                    conversation, session_id, stream_id, status="complete"
                )
            return True

        if event in {"title", "title_status", "state_saved"}:
            generated_title = str(
                data.get("title") or data.get("session_title") or ""
            ).strip()
            if generated_title:
                conversation["title"] = generated_title[:160]
                conversation["name"] = conversation["title"]
                self.registry.save()
                public = self.public_conversation(conversation)
                await self.broadcast_event(
                    "conversation.updated", {"conversation": public, **public}
                )
            metadata = {**base, "kind": event or "event"}
            # These are post-turn transport metadata. Their upstream fields
            # describe title generation or persistence, not agent activity;
            # keep them observable without letting QML reinterpret e.g.
            # ``status: generated`` as a conversation-state transition.
            for source, target in (
                ("status", "upstreamStatus"),
                ("state", "upstreamState"),
                ("statusText", "upstreamStatusText"),
                ("activity", "upstreamActivity"),
            ):
                if source in metadata:
                    metadata[target] = metadata.pop(source)
            await self.broadcast_event(
                "session.info", metadata
            )
            return False

        # Preserve useful upstream activity without inventing transcript
        # messages for metadata such as title, context_status, goal, and
        # background-task updates.
        metadata = {**base, "kind": event or "event"}
        if self.remote_stream_completed.get(conversation["id"]) != stream_id:
            metadata.update(
                {"status": "working", "statusText": "Hermes is working…"}
            )
        await self.broadcast_event("session.info", metadata)
        return False

    async def _complete_remote_stream(
        self,
        conversation: dict[str, Any],
        session_id: str,
        stream_id: str,
        *,
        status: str,
        session: Any = None,
        cancelled: bool = False,
    ) -> None:
        """Publish completion, then replace it with authoritative history."""

        text = self.remote_stream_text.get(conversation["id"], "")
        completion = self.routed_payload(
            conversation,
            {
                "id": f"remote-assistant-{stream_id}",
                "role": "assistant",
                "text": text,
                "streamId": stream_id,
                "status": status,
                "cancelled": cancelled,
                "upstreamSessionId": session_id,
            },
        )
        await self.broadcast_event("message.complete", completion)

        snapshot = session
        if not isinstance(snapshot, dict):
            try:
                result = await self.remote_request(
                    "GET",
                    "/api/session?session_id=" + quote(session_id, safe="")
                    + "&messages=1&expand_renderable=1&msg_limit="
                    + str(REMOTE_HISTORY_PAGE),
                    timeout=30,
                )
                snapshot = result.get("session")
            except RpcFault as fault:
                LOG.debug(
                    "remote session reconciliation failed for %s: %s",
                    conversation["id"],
                    fault.message,
                )
        if isinstance(snapshot, dict):
            with suppress(RpcFault):
                await self.apply_remote_session_snapshot(conversation, snapshot)

        if cancelled:
            await self.set_conversation_status(conversation, "idle", "Interrupted")
            return
        unread = (
            conversation["unread"]
            or self.registry.selected_conversation_id != conversation["id"]
        )
        await self.set_conversation_status(
            conversation,
            "done" if unread else "idle",
            "Done" if unread else "Ready",
            unread=unread,
        )

    async def ensure_runtime(self, conversation: dict[str, Any]) -> str:
        if not self.provider_state["ready"]:
            raise RpcFault(-32032, "Hermes needs a model sign-in first")
        conversation_id = conversation["id"]
        existing = self.runtime_by_conversation.get(conversation_id)
        if existing:
            return existing
        lock = self.conversation_locks.setdefault(conversation_id, asyncio.Lock())
        async with lock:
            existing = self.runtime_by_conversation.get(conversation_id)
            if existing:
                return existing
            profile = conversation["profile"]
            if conversation["stored_session_id"]:
                resume_params: dict[str, Any] = {
                    "session_id": conversation["stored_session_id"],
                    "omit_messages": True,
                }
                if profile:
                    resume_params["profile"] = profile
                try:
                    result = await self.gateway.request(
                        "session.resume", resume_params, timeout=120
                    )
                except RpcFault as fault:
                    if fault.code not in {4001, 4007} or conversation["has_messages"]:
                        raise
                    # An opened-but-never-used session.create has no DB row by
                    # design. After a backend restart its durable-looking key
                    # cannot be resumed; recreating this known-empty conversation is
                    # safe. An ambiguous submit marks has_messages first, so it
                    # can never take this context-losing fallback.
                    conversation["stored_session_id"] = ""
                    self.registry.save()
                    result = await self._create_runtime(conversation, profile)
            else:
                result = await self._create_runtime(conversation, profile)
            if not isinstance(result, dict) or not result.get("session_id"):
                raise RpcFault(-32013, "Hermes returned no runtime session id")
            runtime = str(result["session_id"])
            stored = str(
                result.get("stored_session_id") or conversation["stored_session_id"] or ""
            )
            self._bind_runtime(conversation, runtime, stored)
            public = self.public_conversation(conversation)
            await self.broadcast_event(
                "conversation.updated", {"conversation": public, **public}
            )
            return runtime

    async def _create_runtime(
        self, conversation: dict[str, Any], profile: str
    ) -> Any:
        create_params: dict[str, Any] = {
            "title": conversation["title"] or f"#{conversation['name']}",
            "source": "quickshell",
            "close_on_disconnect": False,
        }
        if conversation["brief"]:
            create_params["messages"] = [
                {
                    "role": "system",
                    "content": (
                        f"Conversation #{conversation['name']} context:\n"
                        f"{conversation['brief']}"
                    ),
                }
            ]
        if conversation["cwd"]:
            create_params["cwd"] = conversation["cwd"]
        if profile:
            create_params["profile"] = profile
        return await self.gateway.request("session.create", create_params, timeout=120)

    def _bind_runtime(
        self, conversation: dict[str, Any], runtime: str, stored: str = ""
    ) -> None:
        old = self.runtime_by_conversation.get(conversation["id"])
        if old and old != runtime:
            self.conversation_by_runtime.pop(old, None)
            self.watermarks.pop(old, None)
        self.runtime_by_conversation[conversation["id"]] = runtime
        self.conversation_by_runtime[runtime] = conversation["id"]
        if stored:
            conversation["stored_session_id"] = stored
        conversation["updated_at"] = utc_now()
        self.registry.save()

    async def respond_to_request(
        self, method: str, params: dict[str, Any]
    ) -> dict[str, Any]:
        conversation = self.resolve_conversation(params)
        runtime = await self.ensure_runtime(conversation)
        request_id = params.get("requestId") or params.get("request_id")
        upstream: dict[str, Any] = {"session_id": runtime}
        if request_id:
            upstream["request_id"] = request_id
        question_id = params.get("questionId") or params.get("question_id")
        if question_id:
            upstream["question_id"] = question_id
        if method == "approval.respond":
            decision = str(params.get("choice") or params.get("decision") or "deny")
            upstream["choice"] = {
                "allow": "once",
                "allow_once": "once",
                "allow-once": "once",
                "allow_session": "session",
                "allow-session": "session",
                "allow_always": "always",
                "allow-always": "always",
            }.get(decision, decision)
            if "all" in params:
                upstream["all"] = bool(params["all"])
        elif method == "clarify.respond":
            upstream["answer"] = params.get(
                "answer", params.get("choice", params.get("value", ""))
            )
        elif method == "sudo.respond":
            upstream["password"] = params.get("password", "")
        elif method == "secret.respond":
            upstream["value"] = params.get("value", "")
        result = await self.gateway.request(method, upstream, timeout=30)
        await self.set_conversation_status(conversation, "working", "Hermes is working…")
        return self.routed_payload(conversation, {"upstream": result})

    async def proxy(self, method: str, params: dict[str, Any]) -> Any:
        routed = any(
            key in params
            for key in ("sessionId", "session_id", "conversationId", "conversation_id")
        )
        conversation: dict[str, Any] | None = None
        upstream_params = dict(params)
        if routed:
            conversation = self.resolve_conversation(params)
            runtime = await self.ensure_runtime(conversation)
            for key in ("sessionId", "conversationId", "conversation_id"):
                upstream_params.pop(key, None)
            upstream_params["session_id"] = runtime
        result = await self.gateway.request(method, upstream_params, timeout=120)
        return self.routed_payload(conversation, {"upstream": result}) if conversation else result

    async def handle_upstream_state(self, state: str, text: str) -> None:
        self.connection = state
        self.connection_text = text
        if state in {"reconnecting", "offline"} and not self.remote_mode():
            for conversation in self.registry.conversations.values():
                if conversation["status"] in {"working", "waiting"}:
                    conversation["status"] = "reconnecting"
                    conversation["status_text"] = "Checking Hermes after disconnect…"
            self.registry.save()
        await self.broadcast_event(
            "bridge.connection",
            {"connection": state, "connectionText": text},
        )
        if state == "connected":
            self.provider_checked_at = 0
            refresh = asyncio.create_task(
                self.refresh_and_broadcast_provider(),
                name="hermes-provider-readiness",
            )
            refresh.add_done_callback(HermesGateway._log_background_failure)

    async def refresh_and_broadcast_provider(self) -> None:
        status = await self.refresh_provider_status(force=True)
        await self.broadcast_event("provider.status", status)

    async def reconcile(self, epoch: str) -> None:
        if self.remote_mode():
            return
        provider = await self.refresh_provider_status()
        if not provider["ready"]:
            changed: list[dict[str, Any]] = []
            for conversation in self.registry.conversations.values():
                if conversation["status"] in {"error", "reconnecting", "offline"}:
                    conversation["status"] = "idle"
                    conversation["status_text"] = "Model sign-in required"
                    conversation["unread"] = False
                    conversation["updated_at"] = utc_now()
                    changed.append(conversation)
            if changed:
                self.registry.save()
                for conversation in changed:
                    public = self.public_conversation(conversation)
                    await self.broadcast_event(
                        "conversation.updated", {"conversation": public, **public}
                    )
            return
        old_epoch = self.replay_epoch
        epoch_changed = bool(old_epoch and epoch and old_epoch != epoch)
        self.replay_epoch = epoch

        old_runtimes = dict(self.runtime_by_conversation)
        if epoch_changed:
            self.runtime_by_conversation.clear()
            self.conversation_by_runtime.clear()
            self.watermarks.clear()
        elif old_epoch and epoch == old_epoch:
            # Ask Hermes for bounded event gaps before rebinding sessions. A
            # truncated ring is harmless because history reconciliation below
            # is authoritative for transcript content.
            for conversation_id, runtime in old_runtimes.items():
                last_seen = self.watermarks.get(runtime, 0)
                if not last_seen:
                    continue
                try:
                    replay = await self.gateway.request(
                        "session.events.since",
                        {"session_id": runtime, "last_seen": last_seen},
                        timeout=10,
                    )
                    for event in replay.get("events", []) if isinstance(replay, dict) else []:
                        if isinstance(event, dict):
                            await self.handle_upstream_event(event)
                except RpcFault:
                    LOG.debug("event replay unavailable for conversation %s", conversation_id)

        semaphore = asyncio.Semaphore(3)

        async def one(conversation: dict[str, Any]) -> None:
            async with semaphore:
                try:
                    # Force a durable rebind even if the old runtime happens to
                    # remain in our map; session.resume is the ownership claim
                    # Hermes expects after a WebSocket reconnect.
                    old_runtime = self.runtime_by_conversation.pop(conversation["id"], "")
                    if old_runtime:
                        self.conversation_by_runtime.pop(old_runtime, None)
                    runtime = await self.ensure_runtime(conversation)
                    history, status = await asyncio.gather(
                        self.gateway.request(
                            "session.history", {"session_id": runtime}, timeout=30
                        ),
                        self.gateway.request(
                            "session.status", {"session_id": runtime}, timeout=30
                        ),
                        return_exceptions=True,
                    )
                    if isinstance(history, dict):
                        messages = self.display_messages(
                            conversation, history.get("messages", [])
                        )
                        await self.broadcast_event(
                            "message.snapshot",
                            self.routed_payload(
                                conversation, {"messages": messages}
                            ),
                        )
                    running = isinstance(status, dict) and "Agent Running: Yes" in str(
                        status.get("output") or ""
                    )
                    if running:
                        await self.set_conversation_status(
                            conversation, "working", "Hermes is working…"
                        )
                    elif conversation["status"] == "reconnecting":
                        await self.set_conversation_status(conversation, "idle", "Ready")
                except RpcFault as fault:
                    conversation["status"] = "error"
                    conversation["status_text"] = "Could not restore conversation"
                    conversation["updated_at"] = utc_now()
                    self.registry.save()
                    await self.broadcast_event(
                        "session.error",
                        self.routed_payload(conversation, {"message": fault.message}),
                    )

        await asyncio.gather(*(one(row) for row in self.registry.conversations.values()))

    async def warm_conversations(self) -> None:
        """Give fresh lazy conversations a live id without creating durable DB rows."""
        semaphore = asyncio.Semaphore(3)

        async def one(conversation: dict[str, Any]) -> None:
            if self.runtime_by_conversation.get(conversation["id"]):
                return
            async with semaphore:
                with suppress(RpcFault):
                    await self.ensure_runtime(conversation)

        await asyncio.gather(*(one(row) for row in self.registry.conversations.values()))

    async def handle_upstream_event(self, event: dict[str, Any]) -> None:
        upstream_type = str(event.get("type") or "")
        runtime = str(event.get("session_id") or "")
        seq = event.get("seq")
        if runtime and isinstance(seq, (int, float)):
            previous = self.watermarks.get(runtime, 0)
            if int(seq) <= previous:
                return
            self.watermarks[runtime] = int(seq)
        conversation_id = self.conversation_by_runtime.get(runtime)
        conversation = self.registry.conversations.get(conversation_id or "")
        payload = event.get("payload")
        raw_payload = dict(payload) if isinstance(payload, dict) else {"value": payload}

        if upstream_type == "gateway.ready":
            await self.broadcast_event(
                "hermes.gateway.ready",
                {"connection": self.connection, "replayEpoch": self.replay_epoch},
            )
            return
        if conversation is None:
            # Global Hermes notifications are still exposed for future UI
            # features; session-scoped events cannot be routed until resume.
            if not runtime:
                await self.broadcast_event(
                    f"hermes.{upstream_type or 'event'}",
                    {"upstreamType": upstream_type, "upstream": raw_payload},
                )
            return

        normalized = self.normalize_event_type(upstream_type)
        routed = self.routed_payload(
            conversation,
            {
                **raw_payload,
                "upstreamType": upstream_type,
                "upstreamSessionId": runtime,
                **({"seq": int(seq)} if isinstance(seq, (int, float)) else {}),
            },
        )

        request_kind = {
            "approval.request": "approval",
            "clarify.request": "clarify",
            "sudo.request": "sudo",
            "secret.request": "secret",
            "clarify.expire": "clarify",
            "sudo.expire": "sudo",
            "secret.expire": "secret",
        }.get(upstream_type)
        if request_kind:
            routed["kind"] = request_kind

        if upstream_type in {"message.start", "thinking.delta", "reasoning.delta"}:
            await self.set_conversation_status(conversation, "working", "Hermes is working…")
        elif upstream_type in {"tool.start", "tool.generating"}:
            tool_name = str(raw_payload.get("name") or "tool")
            await self.set_conversation_status(
                conversation, "working", self.tool_status_text(tool_name)
            )
        elif upstream_type == "tool.progress":
            tool_name = str(raw_payload.get("name") or "tool")
            await self.set_conversation_status(
                conversation, "working", self.tool_status_text(tool_name)
            )
        elif upstream_type in {
            "approval.request",
            "clarify.request",
            "sudo.request",
            "secret.request",
        }:
            label = {
                "approval.request": "Hermes needs approval",
                "clarify.request": "Hermes has a question",
                "sudo.request": "Hermes needs sudo",
                "secret.request": "Hermes needs a secret",
            }[upstream_type]
            await self.set_conversation_status(conversation, "waiting", label, unread=True)
        elif upstream_type == "status.update":
            kind = str(raw_payload.get("kind") or "working").lower()
            text = str(raw_payload.get("text") or "Hermes is working…")[:240]
            status = "idle" if kind in {"idle", "ready"} else "working"
            if kind in {"error", "failed"}:
                status = "error"
            await self.set_conversation_status(conversation, status, text)
            routed["status"] = status
            routed["statusText"] = text
        elif upstream_type == "message.complete":
            unread = conversation["id"] != self.registry.selected_conversation_id
            await self.set_conversation_status(
                conversation, "done" if unread else "idle", "Done", unread=unread
            )
        elif upstream_type in {"error", "gateway.protocol_error"}:
            error_text = str(
                raw_payload.get("message")
                or raw_payload.get("error")
                or "Hermes reported an error"
            ).strip()
            await self.set_conversation_status(
                conversation,
                "error",
                error_text or "Hermes reported an error",
                unread=True,
            )

        await self.broadcast_event(normalized, routed)

    @staticmethod
    def normalize_event_type(upstream_type: str) -> str:
        direct = {
            "message.start",
            "message.delta",
            "message.complete",
            "session.info",
            "session.usage",
            "tool.start",
            "tool.generating",
            "tool.progress",
            "tool.complete",
        }
        if upstream_type in direct:
            return upstream_type
        if upstream_type == "message.interim":
            return "message.delta"
        if upstream_type == "status.update":
            return "session.status"
        if upstream_type in {"error", "gateway.protocol_error"}:
            return "session.error"
        request_types = {
            "approval.request": "request.approval",
            "clarify.request": "request.clarify",
            "sudo.request": "request.sudo",
            "secret.request": "request.secret",
        }
        if upstream_type in request_types:
            return request_types[upstream_type]
        if upstream_type in {"clarify.expire", "sudo.expire", "secret.expire"}:
            return "request.resolved"
        return f"hermes.{upstream_type or 'event'}"

    @staticmethod
    def tool_status_text(name: str) -> str:
        lower = name.lower()
        if lower.startswith("ha_") or "home_assistant" in lower:
            return "Working with Home Assistant…"
        if any(word in lower for word in ("read", "get", "list", "search", "find")):
            return "Hermes is reading…"
        if any(word in lower for word in ("write", "edit", "patch", "replace")):
            return "Hermes is editing…"
        if any(word in lower for word in ("shell", "terminal", "exec", "command")):
            return "Hermes is running a command…"
        if "browser" in lower:
            return "Hermes is browsing…"
        return "Hermes is using a tool…"

    def routed_payload(
        self, conversation: dict[str, Any] | None, payload: dict[str, Any]
    ) -> dict[str, Any]:
        if conversation is None:
            return payload
        runtime = ""
        if (
            self.remote_auth.base_url
            and conversation.get("remote_origin") == self.remote_auth.base_url
        ):
            runtime = str(conversation.get("remote_session_id") or "")
        if not runtime:
            runtime = self.runtime_by_conversation.get(conversation["id"]) or ""
        return {
            **payload,
            "conversationId": conversation["id"],
            "sessionId": runtime,
        }

    @staticmethod
    def display_messages(
        _conversation: dict[str, Any], messages: Any
    ) -> list[dict[str, Any]]:
        """Return valid messages from the native Hermes transcript."""
        if not isinstance(messages, list):
            return []
        return [message for message in messages if isinstance(message, dict)]

    async def set_conversation_status(
        self,
        conversation: dict[str, Any],
        status: str,
        text: str,
        unread: bool | None = None,
    ) -> None:
        conversation["status"] = status
        conversation["status_text"] = text[:240]
        if unread is not None:
            conversation["unread"] = unread
        conversation["updated_at"] = utc_now()
        self.registry.save()
        public = self.public_conversation(conversation)
        await self.broadcast_event(
            "session.status",
            self.routed_payload(
                conversation,
                {
                    "status": status,
                    "statusText": conversation["status_text"],
                    "unread": 1 if conversation["unread"] else 0,
                },
            ),
        )
        await self.broadcast_event("conversation.updated", {"conversation": public, **public})

    async def publish_remote_status(
        self, status: dict[str, Any], previous: dict[str, Any] | None = None
    ) -> None:
        """Publish only the sanitized auth state, never cookies or credentials."""

        await self.broadcast_event("remote.status", dict(status))
        if status.get("state") == "expired" and (
            not previous or previous.get("state") != "expired"
        ):
            await self.broadcast_event("remote.session_expired", dict(status))

    async def broadcast_event(self, event_type: str, payload: dict[str, Any]) -> None:
        frame = event_frame(event_type, payload)
        stale: list[LocalClient] = []
        for client in list(self.clients):
            try:
                await client.send(frame)
            except ConnectionClosed:
                stale.append(client)
            except Exception as exc:
                LOG.debug("local event delivery failed: %s", exc)
                stale.append(client)
        for client in stale:
            self.clients.discard(client)


def state_path(argument: str | None) -> Path:
    if argument:
        return Path(argument).expanduser()
    state_home = os.environ.get("XDG_STATE_HOME")
    root = Path(state_home).expanduser() if state_home else Path.home() / ".local/state"
    return root / "hermes-menubar/conversations.json"


def remote_auth_path(argument: str | None, registry_path: Path) -> Path:
    if argument:
        return Path(argument).expanduser()
    return registry_path.with_name("remote-webui-auth.json")


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--listen", default=DEFAULT_LISTEN)
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument("--upstream", default=DEFAULT_UPSTREAM)
    parser.add_argument(
        "--remote-only",
        action="store_true",
        help="disable all attempts to connect to a local Hermes backend",
    )
    parser.add_argument("--state", default=None)
    parser.add_argument("--remote-auth-state", default=None)
    parser.add_argument("--verbose", action="store_true")
    return parser.parse_args(argv)


async def async_main(args: argparse.Namespace) -> None:
    if not is_loopback(args.listen):
        raise SystemExit("refusing non-loopback --listen address")
    if not 1 <= args.port <= 65535:
        raise SystemExit("--port must be between 1 and 65535")

    registry = ConversationRegistry(state_path(args.state))
    # Materialize a private cache file before accepting local clients.
    registry.save()
    bridge = HermesBridge(
        registry,
        args.upstream,
        remote_auth_path(args.remote_auth_state, registry.path),
        local_backend_enabled=not args.remote_only,
    )
    bridge.start()

    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for signum in (signal.SIGINT, signal.SIGTERM):
        with suppress(NotImplementedError):
            loop.add_signal_handler(signum, stop.set)

    async with websockets.serve(
        bridge.client_handler,
        args.listen,
        args.port,
        max_size=MAX_DOWNSTREAM_MESSAGE,
        ping_interval=20,
        ping_timeout=45,
        close_timeout=5,
    ):
        LOG.info(
            "Hermes menubar bridge listening on ws://%s:%d%s",
            args.listen,
            args.port,
            DEFAULT_PATH,
        )
        await stop.wait()
    await bridge.stop()


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    try:
        asyncio.run(async_main(args))
    except KeyboardInterrupt:
        return 130
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
