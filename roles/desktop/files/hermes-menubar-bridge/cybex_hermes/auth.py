"""Origin-scoped HTTP credentials and authenticated remote transport."""

from __future__ import annotations

import asyncio
from contextlib import suppress
from http.cookiejar import Cookie, CookieJar
import json
import os
from pathlib import Path
import re
import threading
import time
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import urljoin, urlparse, urlunparse
from urllib.request import (
    HTTPRedirectHandler,
    HTTPCookieProcessor,
    Request,
    build_opener,
)
import uuid


from .protocol import (
    LOG,
    MAX_REMOTE_AUTH_RESPONSE,
    MAX_REMOTE_ATTACHMENT_BYTES,
    REMOTE_AUTH_VERSION,
    RpcFault,
    AmbiguousDelivery,
    utc_now,
    is_loopback,
)

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

    ``_lock`` guards only the in-memory configuration (origin, cookie jar,
    source, and status) and the credential file. It is never held across a
    network request: the event loop reads ``status`` constantly, so one slow
    or unreachable WebUI request would otherwise stall every local RPC,
    stream relay, and keepalive for its whole timeout, and serialize all
    remote traffic behind it. Requests snapshot the configuration, run
    unlocked, and apply an expiry only if that configuration is still current.
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
        # Writers replace ``_status`` wholesale under ``_lock``, so copying the
        # current reference always yields one complete status. Reading it
        # lock-free keeps the event loop off a writer's critical section.
        return dict(self._status)

    @staticmethod
    def _jar_cookies(jar: CookieJar) -> list[Cookie]:
        # Requests update a shared jar from worker threads under the jar's
        # own lock. Iterate under that lock as well, so a concurrent
        # Set-Cookie cannot resize its dictionaries mid-iteration.
        with jar._cookies_lock:
            return list(jar)

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
        source: str | None = None,
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
            "hasSessionCredential": bool(self._jar_cookies(self.cookie_jar)),
            "source": self.source if source is None else source,
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
        for cookie in self._jar_cookies(jar):
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
        # The source is passed through rather than set on ``self``: probes run
        # without ``_lock``, so shared state must not change for their sake.
        try:
            response = self._request(
                base_url, jar, "GET", "/api/auth/status", None, timeout
            )
            if not 200 <= response["status"] < 300:
                return self._make_status(
                    "error",
                    configured=configured,
                    url=base_url,
                    source=source,
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
                source=source,
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
                source=source,
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
                source=source,
                reachable=True,
                message="Remote Hermes attempted a cross-origin redirect",
                error_kind="redirect",
            )
        except _RemoteTransportError:
            return self._make_status(
                "error",
                configured=configured,
                url=base_url,
                source=source,
                reachable=False,
                message="Remote Hermes is unreachable",
                error_kind="offline",
            )
        except RpcFault as fault:
            return self._make_status(
                "error",
                configured=configured,
                url=base_url,
                source=source,
                reachable=True,
                message=fault.message,
                error_kind="protocol",
            )

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
        if not is_current:
            return status
        with self._lock:
            if self.base_url != base_url or self.cookie_jar is not jar:
                # A sign-in or sign-out replaced this session while it was
                # being probed; the replacement's status is authoritative.
                return dict(self._status)
            if status["state"] == "expired" and self._jar_cookies(jar):
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
        # The sign-in uses its own jar, so the requests need no shared state;
        # only committing the resulting session below takes the lock.
        base_url = normalize_remote_url(url)
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
            with self._lock:
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
        with self._lock:
            self.base_url = base_url
            self.cookie_jar = jar
            self.source = "persisted"
            status["source"] = self.source
            status["hasSessionCredential"] = bool(self._jar_cookies(jar))
            self._status = status
            self._save()
            return dict(status)

    async def logout(self, timeout: float = 10.0) -> dict[str, Any]:
        return await asyncio.to_thread(self._logout_sync, timeout)

    def _logout_sync(self, timeout: float) -> dict[str, Any]:
        with self._lock:
            base_url, jar = self.base_url, self.cookie_jar
        remote_logout = False
        if base_url:
            try:
                response = self._request(
                    base_url,
                    jar,
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
        with self._lock:
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
        base_url, jar = self._current_session()
        try:
            response = self._request(
                base_url,
                jar,
                "POST",
                path,
                None,
                timeout,
                encoded_body=encoded,
                content_type=f"multipart/form-data; boundary={boundary}",
            )
        except _RemoteAuthRequired as exc:
            raise self._session_fault(base_url, jar, exc.status_code) from None
        except _RemoteRedirectBlocked:
            raise RpcFault(
                -32041, "Remote Hermes attempted a cross-origin redirect"
            ) from None
        except _RemoteTransportError:
            raise RpcFault(-32042, "Remote Hermes is unreachable") from None
        if response["status"] == 401:
            raise self._session_fault(base_url, jar, 401)
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

        base_url, jar = self._current_session()
        try:
            response = self._request(
                base_url,
                jar,
                "POST",
                path,
                None,
                timeout,
                encoded_body=encoded,
                content_type=f"multipart/form-data; boundary={boundary}",
            )
        except _RemoteAuthRequired as exc:
            raise self._session_fault(base_url, jar, exc.status_code) from None
        except _RemoteRedirectBlocked:
            raise RpcFault(
                -32041, "Remote Hermes attempted a cross-origin redirect"
            ) from None
        except _RemoteTransportError:
            raise RpcFault(-32042, "Remote Hermes is unreachable") from None
        if response["status"] == 401:
            raise self._session_fault(base_url, jar, 401)
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
        base_url, jar = self._current_session()
        try:
            response = self._request(
                base_url,
                jar,
                method,
                path,
                payload,
                timeout,
            )
        except _RemoteAuthRequired as exc:
            raise self._session_fault(base_url, jar, exc.status_code) from None
        except _RemoteRedirectBlocked:
            raise RpcFault(
                -32041, "Remote Hermes attempted a cross-origin redirect"
            ) from None
        except _RemoteTransportError:
            if method.upper() == "POST" and path == "/api/chat/start":
                raise AmbiguousDelivery("remote prompt.submit") from None
            raise RpcFault(-32042, "Remote Hermes is unreachable") from None
        if response["status"] == 401:
            raise self._session_fault(base_url, jar, 401)
        if not 200 <= response["status"] < 300:
            raise self._http_error_fault(response)
        return self._json_response(response)

    async def probe_contract(self, timeout: float = 10.0) -> dict[str, Any]:
        """Read the WebUI's non-streaming SSE capability probe and server tag."""

        return await asyncio.to_thread(self._probe_contract_sync, timeout)

    def _probe_contract_sync(self, timeout: float) -> dict[str, Any]:
        base_url, jar = self._current_session()
        try:
            response = self._request(
                base_url,
                jar,
                "GET",
                "/api/sessions/gateway/stream?probe=1",
                None,
                timeout,
            )
        except _RemoteAuthRequired as exc:
            raise self._session_fault(base_url, jar, exc.status_code) from None
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

    def _current_session(self) -> tuple[str, CookieJar]:
        """Snapshot the origin and cookie jar one unlocked request will use."""

        with self._lock:
            if not self.base_url:
                raise RpcFault(-32040, "Remote Hermes is not configured")
            return self.base_url, self.cookie_jar

    def _session_fault(
        self, base_url: str, jar: CookieJar, status_code: int = 401
    ) -> RpcFault:
        """Expire the session a challenged request used, if it is still current."""

        with self._lock:
            if self.base_url == base_url and self.cookie_jar is jar:
                status = self._expire_session_locked(status_code)
            elif self._status.get("state") == "expired":
                # A concurrent request already expired this session.
                status = dict(self._status)
            else:
                # A sign-in, sign-out, or origin change finished while this
                # request was in flight. Its challenge describes a session that
                # is already gone, so it must neither clear the replacement's
                # cookies nor report the replacement as expired.
                return RpcFault(
                    -32042, "Remote Hermes session changed during the request"
                )
        return RemoteLoginFault(status["message"], status)

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

        base_url, jar = self._current_session()
        if not isinstance(path, str) or not path.startswith("/") or "://" in path:
            raise RpcFault(-32602, "Remote Hermes API path is invalid")
        headers = {
            "Accept": "text/event-stream",
            "Cache-Control": "no-cache",
            "User-Agent": "cybexos-hermes-menubar-bridge/1",
        }
        if last_event_id:
            headers["Last-Event-ID"] = str(last_event_id)[:1024]
        redirect_handler = _SameOriginRedirectHandler(_remote_origin(base_url))
        opener = build_opener(redirect_handler, HTTPCookieProcessor(jar))
        request = Request(f"{base_url}{path}", headers=headers, method="GET")
        try:
            response = opener.open(request, timeout=timeout)
        except _RemoteAuthRequired as exc:
            raise self._session_fault(base_url, jar, exc.status_code) from None
        except _RemoteRedirectBlocked:
            raise RpcFault(
                -32041, "Remote Hermes attempted a cross-origin redirect"
            ) from None
        except HTTPError as exc:
            status_code = int(exc.code)
            with suppress(Exception):
                exc.close()
            if status_code == 401:
                raise self._session_fault(base_url, jar, status_code) from None
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
            raise self._session_fault(base_url, jar, status_code or 302)
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
