"""Bounded downstream delivery and reconnecting local upstream transport."""

from __future__ import annotations

import asyncio
from contextlib import suppress
from dataclasses import dataclass, field
import json
import os
import random
from typing import Any, Awaitable, Callable
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlparse, urlunparse
from urllib.request import (
    Request,
    urlopen,
)

import websockets
from websockets.asyncio.client import ClientConnection
from websockets.asyncio.server import ServerConnection
from websockets.exceptions import ConnectionClosed


from .protocol import (
    LOG,
    MAX_UPSTREAM_MESSAGE,
    MAX_PROVIDER_RESPONSE,
    MAX_CLIENT_BACKLOG,
    TOKEN_PATTERN,
    RpcFault,
    UpstreamUnavailable,
    AmbiguousDelivery,
    json_frame,
)

@dataclass(eq=False)
class LocalClient:
    """One loopback shell connection with its own bounded outbound queue.

    Producers never await the socket: a dedicated writer task drains the
    queue, so one stalled client cannot block the upstream reader (and with
    it the gateway heartbeat) or delay delivery to other clients. A client
    that falls MAX_CLIENT_BACKLOG frames behind is disconnected; the shell
    reconnects and reconciles through its normal hello/list/history path.
    """

    websocket: ServerConnection
    tasks: set[asyncio.Task[Any]] = field(default_factory=set)
    backlog: int = MAX_CLIENT_BACKLOG
    closed: bool = False
    queue: asyncio.Queue[str] = field(init=False)
    writer: asyncio.Task[Any] | None = field(default=None, init=False)

    def __post_init__(self) -> None:
        self.queue = asyncio.Queue(maxsize=max(1, self.backlog))

    def start(self) -> None:
        if self.writer is None:
            self.writer = asyncio.create_task(
                self._write(), name="hermes-local-writer"
            )

    async def _write(self) -> None:
        try:
            while True:
                text = await self.queue.get()
                await self.websocket.send(text)
        except ConnectionClosed:
            pass
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            LOG.debug("local client write failed: %s", exc)
        finally:
            self.closed = True

    def enqueue_text(self, text: str) -> bool:
        if self.closed:
            return False
        try:
            self.queue.put_nowait(text)
        except asyncio.QueueFull:
            LOG.warning(
                "local Hermes client fell %d frames behind; disconnecting it",
                self.queue.maxsize,
            )
            self.abort("client too slow")
            return False
        return True

    def abort(self, reason: str) -> None:
        if self.closed:
            return
        self.closed = True
        if self.writer is not None:
            self.writer.cancel()
        closer = asyncio.create_task(
            self.websocket.close(code=1013, reason=reason),
            name="hermes-local-close",
        )
        self.tasks.add(closer)
        closer.add_done_callback(self._closed)

    def _closed(self, task: asyncio.Task[Any]) -> None:
        self.tasks.discard(task)
        if not task.cancelled():
            task.exception()

    async def stop(self) -> None:
        self.closed = True
        if self.writer is not None:
            self.writer.cancel()
            with suppress(asyncio.CancelledError, Exception):
                await self.writer

    async def send(self, frame: dict[str, Any]) -> None:
        self.enqueue_text(json_frame(frame))


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
