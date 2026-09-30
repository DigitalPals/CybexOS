"""Shared wire errors, limits and serialization; no bridge state."""

from __future__ import annotations

from datetime import datetime, timezone
import ipaddress
import json
import logging
import re
from typing import Any


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
# Live status churn (thinking/tool progress) is coalesced into one registry
# write per window; explicit saves and shutdown still write immediately.
REGISTRY_SAVE_DELAY = 1.0
# Frames buffered per local client. A shell that stops reading falls behind
# by this many frames and is disconnected rather than stalling the event
# fan-out that also carries the upstream heartbeat.
MAX_CLIENT_BACKLOG = 2048
TOKEN_PATTERN = re.compile(
    r"window\.__HERMES_SESSION_TOKEN__\s*=\s*(\"(?:\\.|[^\"\\])*\")"
)
CONVERSATION_ID_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.:-]{0,255}$")
REMOTE_AUTH_VERSION = 1
# Remote observer streams (the session list and the selected session) are
# long-lived. Only one that stayed open this long proves the server healthy
# and resets reconnect backoff; a server that accepts and promptly closes, or
# fails, is retried with jittered exponential delays between the floor and
# the cap instead of at a fixed sub-second rate.
REMOTE_OBSERVER_HEALTHY_SECONDS = 60.0
REMOTE_OBSERVER_RETRY_FLOOR = 3.0
REMOTE_OBSERVER_RETRY_CAP = 120.0
# Session-list invalidations arrive in bursts. They share one in-flight list
# refresh plus at most one trailing refresh, started at least this far apart.
REMOTE_REFRESH_SPACING = 1.0


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
