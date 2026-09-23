#!/usr/bin/env python3
"""End-to-end fixture for the Hermes WebUI remote runtime adapter.

The fake HTTP server deliberately implements the small subset of the official
WebUI API used by the menubar bridge.  The test drives that adapter only through
the bridge's loopback JSON-RPC WebSocket, including its SSE relay.
"""

from __future__ import annotations

import asyncio
from contextlib import asynccontextmanager
from email import policy
from email.parser import BytesParser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import threading
import time
from typing import Any
from urllib.parse import parse_qs, urlsplit

import websockets


ROOT = Path(__file__).resolve().parents[1]
BRIDGE_PATH = ROOT / "roles/desktop/files/hermes-menubar-bridge/hermes_bridge.py"
SPEC = importlib.util.spec_from_file_location(
    "hermes_remote_runtime_fixture", BRIDGE_PATH
)
assert SPEC and SPEC.loader
BRIDGE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = BRIDGE
SPEC.loader.exec_module(BRIDGE)


class FakeRemote:
    password = "runtime-password-must-never-persist"
    cookie = "remote-runtime-cookie.signature"
    cancel_prompt = "Wait until I cancel this fixture turn"

    def __init__(self) -> None:
        self.lock = threading.RLock()
        self.session_valid = False
        self.session_counter = 0
        self.stream_counter = 0
        self.sessions: dict[str, dict[str, Any]] = {}
        self.streams: dict[str, dict[str, Any]] = {}
        self.import_requests: list[dict[str, Any]] = []
        self.external_import_requests: list[dict[str, Any]] = []
        self.new_requests: list[dict[str, Any]] = []
        self.rename_requests: list[dict[str, Any]] = []
        self.compress_requests: list[dict[str, Any]] = []
        self.session_update_requests: list[dict[str, Any]] = []
        self.reasoning_requests: list[dict[str, Any]] = []
        self.upload_requests: list[dict[str, Any]] = []
        self.branch_requests: list[dict[str, Any]] = []
        self.duplicate_requests: list[dict[str, Any]] = []
        self.truncate_requests: list[dict[str, Any]] = []
        self.chat_start_requests: list[dict[str, Any]] = []
        self.approval_responses: list[dict[str, Any]] = []
        self.clarify_responses: list[dict[str, Any]] = []
        self.cancelled_streams: list[str] = []
        self.protected_cookies: list[str] = []
        self.chat_start_faults: dict[str, dict[str, Any]] = {}
        self.session_queries: list[dict[str, list[str]]] = []
        self.global_event_connections = 0
        self.session_event_connections = 0

    def authenticated(self, handler: BaseHTTPRequestHandler) -> bool:
        cookie = handler.headers.get("Cookie", "")
        with self.lock:
            valid = self.session_valid and f"hermes_session={self.cookie}" in cookie
            if valid:
                self.protected_cookies.append(cookie)
            return valid

    def expire(self) -> None:
        with self.lock:
            self.session_valid = False

    def create_session(
        self, title: str, messages: list[dict[str, Any]]
    ) -> dict[str, Any]:
        with self.lock:
            self.session_counter += 1
            session_id = f"remote-session-{self.session_counter}"
            self.sessions[session_id] = {
                "session_id": session_id,
                "title": title,
                "messages": [dict(message) for message in messages],
                "active_stream_id": None,
                "agent_running": False,
                "created_at": 1787999000 + self.session_counter,
            }
            return self.session_snapshot(session_id)

    def session_snapshot(self, session_id: str) -> dict[str, Any]:
        with self.lock:
            session = self.sessions[session_id]
            snapshot = {
                "session_id": session_id,
                "title": session["title"],
                "messages": [dict(message) for message in session["messages"]],
                "message_count": len(session["messages"]),
                "active_stream_id": session["active_stream_id"],
                "agent_running": session["agent_running"],
                "is_streaming": bool(session["active_stream_id"]),
                "created_at": session["created_at"],
                "updated_at": session["created_at"] + len(session["messages"]),
                "last_message_at": (
                    session["created_at"] + len(session["messages"])
                    if session["messages"] else None
                ),
                "model": session.get("model", "fixture/model"),
                "model_provider": session.get("model_provider", "fixture-provider"),
                "read_only": bool(session.get("read_only", False)),
                "regeneration_revision": "fixture-revision-"
                + str(len(session["messages"])),
            }
            for key in (
                "session_source",
                "source_label",
                "source_tag",
                "raw_source",
                "is_cli_session",
            ):
                if key in session:
                    snapshot[key] = session[key]
            return snapshot

    def start_stream(
        self,
        session_id: str,
        message: str,
        attachments: list[dict[str, Any]] | None = None,
        *,
        regeneration: bool = False,
    ) -> str:
        with self.lock:
            session = self.sessions[session_id]
            self.stream_counter += 1
            stream_id = f"remote-stream-{self.stream_counter}"
            stream = {
                "stream_id": stream_id,
                "session_id": session_id,
                "mode": "cancel" if message == self.cancel_prompt
                    else "simple" if regeneration
                    or message.startswith("Edited fixture")
                    or message.startswith("Inspect attachment")
                    else "interactive",
                "approval": threading.Event(),
                "clarify": threading.Event(),
                "cancel": threading.Event(),
                "finished": threading.Event(),
            }
            self.streams[stream_id] = stream
            if regeneration:
                assistant_index = next(
                    (
                        index for index in range(len(session["messages"]) - 1, -1, -1)
                        if session["messages"][index].get("role") == "assistant"
                    ),
                    -1,
                )
                user_index = next(
                    (
                        index for index in range(assistant_index - 1, -1, -1)
                        if session["messages"][index].get("role") == "user"
                    ),
                    -1,
                )
                if user_index >= 0:
                    session["messages"] = session["messages"][: user_index + 1]
            else:
                user_message: dict[str, Any] = {"role": "user", "content": message}
                if attachments:
                    user_message["attachments"] = [dict(row) for row in attachments]
                session["messages"].append(user_message)
            session["active_stream_id"] = stream_id
            session["agent_running"] = True
            return stream_id

    def finish_stream(self, stream_id: str, assistant_text: str = "") -> None:
        with self.lock:
            stream = self.streams[stream_id]
            session = self.sessions[stream["session_id"]]
            if assistant_text:
                session["messages"].append(
                    {"role": "assistant", "content": assistant_text}
                )
            session["active_stream_id"] = None
            session["agent_running"] = False
            stream["finished"].set()


FAKE = FakeRemote()


class HermesRemoteHandler(BaseHTTPRequestHandler):
    server_version = "HermesWebUIFixture/exp-v0.52.264"
    protocol_version = "HTTP/1.1"

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
            json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode(),
            "application/json",
            headers,
        )

    def read_json(self) -> dict[str, Any]:
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length)
        try:
            value = json.loads(raw.decode("utf-8")) if raw else {}
        except (UnicodeDecodeError, json.JSONDecodeError):
            value = {}
        return value if isinstance(value, dict) else {}

    def read_multipart_upload(self) -> tuple[dict[str, str], str, bytes]:
        length = int(self.headers.get("Content-Length", "0") or 0)
        raw = self.rfile.read(length)
        header = (
            "Content-Type: " + self.headers.get("Content-Type", "")
            + "\r\nMIME-Version: 1.0\r\n\r\n"
        ).encode("utf-8")
        document = BytesParser(policy=policy.default).parsebytes(header + raw)
        fields: dict[str, str] = {}
        filename = ""
        file_bytes = b""
        for part in document.iter_parts():
            name = str(part.get_param("name", header="content-disposition") or "")
            candidate = part.get_filename()
            payload = part.get_payload(decode=True) or b""
            if candidate is not None:
                filename = str(candidate)
                file_bytes = payload
            elif name:
                fields[name] = payload.decode("utf-8", errors="replace")
        return fields, filename, file_bytes

    def require_auth(self) -> bool:
        if FAKE.authenticated(self):
            return True
        self.json_reply({"error": "authentication required"}, status=401)
        return False

    @staticmethod
    def query_value(query: dict[str, list[str]], name: str) -> str:
        values = query.get(name, [])
        return values[0] if values else ""

    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        parsed = urlsplit(self.path)
        query = parse_qs(parsed.query)
        if parsed.path == "/api/auth/status":
            return self.json_reply(
                {
                    "auth_enabled": True,
                    "logged_in": FAKE.authenticated(self),
                    "password_auth_enabled": True,
                    "oidc_enabled": False,
                }
            )
        if not self.require_auth():
            return
        if parsed.path == "/api/sessions":
            with FAKE.lock:
                rows = []
                for session_id in FAKE.sessions:
                    snapshot = FAKE.session_snapshot(session_id)
                    snapshot.pop("messages", None)
                    # The real sidebar projection does not advertise that an
                    # external transcript needs importing. That flag first
                    # appears in the detailed session response.
                    snapshot.pop("read_only", None)
                    rows.append(snapshot)
            return self.json_reply({"sessions": rows})
        if parsed.path == "/api/models":
            return self.json_reply({
                "active_provider": "openai-codex",
                "default_model": "gpt-5.6-sol",
                "configured_model_badges": [{
                    "model": "gpt-5.6-sol",
                    "provider": "openai-codex",
                    "role": "Primary",
                }],
                "groups": [
                    {
                        "provider": "OpenAI Codex",
                        "provider_id": "openai-codex",
                        "models": [
                            {"id": "gpt-5.6-sol", "label": "GPT-5.6 Sol"},
                            {"id": "gpt-5.4", "label": "GPT-5.4"},
                        ],
                    },
                    {
                        "provider": "Anthropic",
                        "provider_id": "anthropic",
                        "models": [{
                            "id": "claude-opus-4-1",
                            "label": "Claude Opus 4.1",
                        }],
                    },
                ],
            })
        if parsed.path == "/api/reasoning":
            FAKE.reasoning_requests.append({
                "method": "GET",
                "model": self.query_value(query, "model"),
                "provider": self.query_value(query, "provider"),
            })
            return self.json_reply({
                "show_reasoning": False,
                "reasoning_effort": "high",
                "supported_efforts": [
                    "minimal", "low", "medium", "high", "xhigh", "max"
                ],
                "supports_reasoning_effort": True,
                "supports_thinking_toggle": True,
            })
        if parsed.path == "/api/sessions/gateway/stream":
            return self.json_reply({
                "enabled": False,
                "ok": False,
                "watcher_running": False,
                "fallback_poll_ms": 30000,
                "scope": "gateway_sessions",
                "session_stream_available": True,
                "session_stream_path": "/api/session/stream",
            }, status=404)
        if parsed.path == "/api/sessions/events":
            FAKE.global_event_connections += 1
            return self.observer_stream("sessions_changed", {"reason": "fixture"})
        if parsed.path == "/api/session/stream":
            FAKE.session_event_connections += 1
            return self.observer_stream("initial", {
                "session_id": self.query_value(query, "session_id"),
            })
        if parsed.path == "/api/session":
            session_id = self.query_value(query, "session_id")
            with FAKE.lock:
                if session_id not in FAKE.sessions:
                    return self.json_reply({"error": "not found"}, status=404)
                snapshot = FAKE.session_snapshot(session_id)
                FAKE.session_queries.append(dict(query))
                full_messages = snapshot["messages"]
                try:
                    limit = max(1, min(500, int(self.query_value(query, "msg_limit"))))
                except ValueError:
                    limit = len(full_messages) or 1
                before_raw = self.query_value(query, "msg_before")
                try:
                    before = max(0, min(len(full_messages), int(before_raw)))
                except ValueError:
                    before = len(full_messages)
                start = max(0, before - limit)
                snapshot["messages"] = full_messages[start:before]
                snapshot["_messages_offset"] = start
                snapshot["_messages_truncated"] = start > 0
                snapshot["_msg_limit_max"] = 500
            return self.json_reply({"session": snapshot})
        if parsed.path == "/api/session/status":
            session_id = self.query_value(query, "session_id")
            with FAKE.lock:
                if session_id not in FAKE.sessions:
                    return self.json_reply({"error": "not found"}, status=404)
                session = FAKE.sessions[session_id]
                status = {
                    "session_id": session_id,
                    "agent_running": session["agent_running"],
                    "active_stream_id": session["active_stream_id"],
                }
            return self.json_reply(status)
        if parsed.path == "/api/chat/stream/status":
            stream_id = self.query_value(query, "stream_id")
            with FAKE.lock:
                stream = FAKE.streams.get(stream_id)
                if stream is None:
                    return self.json_reply({"error": "not found"}, status=404)
                finished = stream["finished"].is_set()
            return self.json_reply(
                {
                    "stream_id": stream_id,
                    "active": not finished,
                    "done": finished,
                    "status": "complete" if finished else "running",
                }
            )
        if parsed.path == "/api/chat/cancel":
            stream_id = self.query_value(query, "stream_id")
            with FAKE.lock:
                stream = FAKE.streams.get(stream_id)
                if stream is None:
                    return self.json_reply({"error": "not found"}, status=404)
                FAKE.cancelled_streams.append(stream_id)
                stream["cancel"].set()
            return self.json_reply({"ok": True, "cancelled": True})
        if parsed.path == "/api/chat/stream":
            stream_id = self.query_value(query, "stream_id")
            with FAKE.lock:
                stream = FAKE.streams.get(stream_id)
            if stream is None:
                return self.json_reply({"error": "not found"}, status=404)
            return self.stream_events(stream)
        self.json_reply({"error": "not found"}, status=404)

    def observer_stream(self, event: str, data: dict[str, Any]) -> None:
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True
        try:
            self.wfile.write(
                (f"event: {event}\ndata: " + json.dumps(data) + "\n\n").encode()
            )
            self.wfile.flush()
            for _tick in range(8):
                time.sleep(0.025)
                self.wfile.write(b": keepalive\n\n")
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            return

    def do_POST(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        parsed = urlsplit(self.path)
        if parsed.path == "/api/upload":
            if not self.require_auth():
                return
            if "multipart/form-data" not in self.headers.get("Content-Type", ""):
                return self.json_reply({"error": "No boundary in Content-Type"}, status=400)
            fields, filename, file_bytes = self.read_multipart_upload()
            if not filename:
                return self.json_reply({"error": "No file field in request"}, status=400)
            session_id = fields.get("session_id", "")
            with FAKE.lock:
                if session_id not in FAKE.sessions:
                    return self.json_reply({"error": "not found"}, status=404)
                FAKE.upload_requests.append({
                    "session_id": session_id,
                    "filename": filename,
                    "content": file_bytes,
                })
            return self.json_reply({
                "filename": filename,
                "path": "/fixture/attachments/" + filename,
                "size": len(file_bytes),
                "mime": "text/plain",
                "is_image": False,
            })
        body = self.read_json()
        if parsed.path == "/api/auth/login":
            password = body.get("password")
            if password != FAKE.password:
                return self.json_reply({"error": "Invalid password"}, status=401)
            with FAKE.lock:
                FAKE.session_valid = True
            return self.json_reply(
                {"ok": True},
                headers={
                    "Set-Cookie": (
                        f"hermes_session={FAKE.cookie}; Path=/; HttpOnly; "
                        "SameSite=Lax; Max-Age=2592000"
                    )
                },
            )
        if parsed.path == "/api/auth/logout":
            with FAKE.lock:
                FAKE.session_valid = False
            return self.json_reply(
                {"ok": True},
                headers={
                    "Set-Cookie": (
                        "hermes_session=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0"
                    )
                },
            )
        if not self.require_auth():
            return
        if parsed.path == "/api/session/import_cli":
            session_id = str(body.get("session_id") or "")
            with FAKE.lock:
                if session_id not in FAKE.sessions:
                    return self.json_reply({"error": "not found"}, status=404)
                FAKE.external_import_requests.append(dict(body))
                FAKE.sessions[session_id]["read_only"] = False
                session = FAKE.session_snapshot(session_id)
            return self.json_reply({"session": session})
        if parsed.path == "/api/session/import":
            messages = body.get("messages")
            safe_messages = messages if isinstance(messages, list) else []
            FAKE.import_requests.append(dict(body))
            session = FAKE.create_session(
                str(body.get("title") or "Imported conversation"), safe_messages
            )
            return self.json_reply({"session": session})
        if parsed.path == "/api/session/new":
            FAKE.new_requests.append(dict(body))
            session = FAKE.create_session("New conversation", [])
            with FAKE.lock:
                stored = FAKE.sessions[str(session["session_id"])]
                stored["model"] = str(body.get("model") or "fixture/model")
                stored["model_provider"] = str(
                    body.get("model_provider") or "fixture-provider"
                )
                session = FAKE.session_snapshot(str(session["session_id"]))
            return self.json_reply({"session": session})
        if parsed.path == "/api/session/delete":
            session_id = str(body.get("session_id") or "")
            with FAKE.lock:
                if session_id not in FAKE.sessions:
                    return self.json_reply({"error": "not found"}, status=404)
                del FAKE.sessions[session_id]
            return self.json_reply({"ok": True, "deleted": session_id})
        if parsed.path == "/api/session/rename":
            session_id = str(body.get("session_id") or "")
            with FAKE.lock:
                if session_id not in FAKE.sessions:
                    return self.json_reply({"error": "not found"}, status=404)
                FAKE.sessions[session_id]["title"] = str(body.get("title") or "")
                FAKE.rename_requests.append(dict(body))
                session = FAKE.session_snapshot(session_id)
            return self.json_reply({"session": session})
        if parsed.path == "/api/session/compress":
            session_id = str(body.get("session_id") or "")
            with FAKE.lock:
                if session_id not in FAKE.sessions:
                    return self.json_reply({"error": "not found"}, status=404)
                FAKE.compress_requests.append(dict(body))
                session = FAKE.sessions[session_id]
                seed = [
                    dict(message)
                    for message in session["messages"]
                    if message.get("role") == "system"
                ]
                session["messages"] = seed + [
                    {
                        "role": "user",
                        "content": "Retain the compressed fixture context",
                    },
                    {
                        "role": "assistant",
                        "content": "Compressed remote fixture history",
                    },
                ]
            return self.json_reply(
                {
                    "ok": True,
                    "compressed": True,
                    "session_id": session_id,
                }
            )
        if parsed.path == "/api/session/update":
            session_id = str(body.get("session_id") or "")
            with FAKE.lock:
                if session_id not in FAKE.sessions:
                    return self.json_reply({"error": "not found"}, status=404)
                FAKE.session_update_requests.append(dict(body))
                FAKE.sessions[session_id]["model"] = str(body.get("model") or "")
                FAKE.sessions[session_id]["model_provider"] = str(
                    body.get("model_provider") or ""
                )
                session = FAKE.session_snapshot(session_id)
            return self.json_reply({"session": session})
        if parsed.path == "/api/session/branch":
            session_id = str(body.get("session_id") or "")
            if not session_id:
                return self.json_reply({"error": "session_id is required"}, status=400)
            with FAKE.lock:
                if session_id not in FAKE.sessions:
                    return self.json_reply({"error": "not found"}, status=404)
                source = FAKE.sessions[session_id]
                keep_value = body.get("keep_count")
                keep_count = len(source["messages"]) if keep_value is None else int(keep_value)
                messages = [dict(row) for row in source["messages"][:keep_count]]
                FAKE.branch_requests.append(dict(body))
                branch = FAKE.create_session(
                    str(body.get("title") or source["title"] + " (fork)"),
                    messages,
                )
                stored = FAKE.sessions[str(branch["session_id"])]
                stored["model"] = source.get("model", "fixture/model")
                stored["model_provider"] = source.get(
                    "model_provider", "fixture-provider"
                )
            return self.json_reply({
                "session_id": branch["session_id"],
                "title": branch["title"],
                "parent_session_id": session_id,
            })
        if parsed.path == "/api/session/duplicate":
            session_id = str(body.get("session_id") or "")
            if not session_id:
                return self.json_reply({"error": "session_id is required"}, status=400)
            with FAKE.lock:
                if session_id not in FAKE.sessions:
                    return self.json_reply({"error": "not found"}, status=404)
                source = FAKE.sessions[session_id]
                FAKE.duplicate_requests.append(dict(body))
                duplicate = FAKE.create_session(
                    source["title"] + " (copy)",
                    [dict(row) for row in source["messages"]],
                )
                stored = FAKE.sessions[str(duplicate["session_id"])]
                stored["model"] = source.get("model", "fixture/model")
                stored["model_provider"] = source.get(
                    "model_provider", "fixture-provider"
                )
                duplicate = FAKE.session_snapshot(str(duplicate["session_id"]))
            return self.json_reply({"session": duplicate})
        if parsed.path == "/api/session/truncate":
            session_id = str(body.get("session_id") or "")
            if not session_id:
                return self.json_reply({"error": "session_id is required"}, status=400)
            with FAKE.lock:
                if session_id not in FAKE.sessions:
                    return self.json_reply({"error": "not found"}, status=404)
                keep_count = int(body.get("keep_count", -1))
                if keep_count < 0:
                    return self.json_reply({"error": "invalid keep_count"}, status=400)
                FAKE.truncate_requests.append(dict(body))
                FAKE.sessions[session_id]["messages"] = FAKE.sessions[session_id][
                    "messages"
                ][:keep_count]
                session = FAKE.session_snapshot(session_id)
            return self.json_reply({"ok": True, "session": session})
        if parsed.path == "/api/session/retry":
            session_id = str(body.get("session_id") or "")
            if not session_id:
                return self.json_reply({"error": "session_id is required"}, status=400)
            return self.json_reply({"ok": True})
        if parsed.path == "/api/reasoning":
            FAKE.reasoning_requests.append({"method": "POST", **dict(body)})
            return self.json_reply({
                "show_reasoning": body.get("effort") not in {"", "none"},
                "reasoning_effort": str(body.get("effort") or ""),
                "supported_efforts": [
                    "minimal", "low", "medium", "high", "xhigh", "max"
                ],
                "supports_reasoning_effort": True,
                "supports_thinking_toggle": True,
            })
        if parsed.path == "/api/chat/start":
            session_id = str(body.get("session_id") or "")
            regenerate = body.get("regenerate") is True
            message = str(body.get("message") or "")
            with FAKE.lock:
                if session_id not in FAKE.sessions:
                    return self.json_reply({"error": "not found"}, status=404)
                if FAKE.sessions[session_id].get("read_only") is True:
                    return self.json_reply(
                        {"error": "read-only imported session"}, status=409
                    )
                if regenerate:
                    expected = "fixture-revision-" + str(
                        len(FAKE.sessions[session_id]["messages"])
                    )
                    if body.get("regeneration_revision") != expected:
                        return self.json_reply(
                            {"error": "stale regeneration revision"}, status=409
                        )
                    assistant_index = next(
                        (
                            index
                            for index in range(
                                len(FAKE.sessions[session_id]["messages"]) - 1,
                                -1,
                                -1,
                            )
                            if FAKE.sessions[session_id]["messages"][index].get("role")
                            == "assistant"
                        ),
                        -1,
                    )
                    user_index = next(
                        (
                            index
                            for index in range(assistant_index - 1, -1, -1)
                            if FAKE.sessions[session_id]["messages"][index].get("role")
                            == "user"
                        ),
                        -1,
                    )
                    message = (
                        str(FAKE.sessions[session_id]["messages"][user_index].get("content") or "")
                        if user_index >= 0 else ""
                    )
                fault = FAKE.chat_start_faults.pop(message, None)
                FAKE.chat_start_requests.append(dict(body))
            if fault is not None:
                return self.json_reply(fault, status=409)
            stream_id = FAKE.start_stream(
                session_id,
                message,
                body.get("attachments") if isinstance(body.get("attachments"), list)
                else None,
                regeneration=regenerate,
            )
            return self.json_reply(
                {
                    "ok": True,
                    "accepted": True,
                    "session_id": session_id,
                    "stream_id": stream_id,
                }
            )
        if parsed.path == "/api/approval/respond":
            FAKE.approval_responses.append(dict(body))
            session_id = str(body.get("session_id") or "")
            self.release_stream_waiter(session_id, "approval")
            return self.json_reply({"ok": True, "resolved": True})
        if parsed.path == "/api/clarify/respond":
            FAKE.clarify_responses.append(dict(body))
            session_id = str(body.get("session_id") or "")
            self.release_stream_waiter(session_id, "clarify")
            return self.json_reply({"ok": True, "resolved": True})
        self.json_reply({"error": "not found"}, status=404)

    @staticmethod
    def release_stream_waiter(session_id: str, field: str) -> None:
        with FAKE.lock:
            for stream in reversed(list(FAKE.streams.values())):
                if stream["session_id"] == session_id and not stream["finished"].is_set():
                    stream[field].set()
                    return

    def send_sse(
        self, stream_id: str, sequence: int, event: str, data: dict[str, Any]
    ) -> None:
        # Pretty JSON exercises the bridge's standard multi-line ``data:``
        # handling instead of relying only on the one-line happy path.
        document = json.dumps(data, ensure_ascii=False, indent=2)
        lines = [f"id: {stream_id}:{sequence}", f"event: {event}"]
        lines.extend(f"data: {line}" for line in document.splitlines())
        self.wfile.write(("\n".join(lines) + "\n\n").encode("utf-8"))
        self.wfile.flush()

    def stream_events(self, stream: dict[str, Any]) -> None:
        stream_id = stream["stream_id"]
        session_id = stream["session_id"]
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True
        sequence = 0

        def emit(event: str, data: dict[str, Any]) -> None:
            nonlocal sequence
            sequence += 1
            self.send_sse(stream_id, sequence, event, data)
            time.sleep(0.015)

        try:
            if stream["mode"] == "cancel":
                emit("token", {"text": "Waiting for cancellation…"})
                if not stream["cancel"].wait(timeout=8):
                    raise AssertionError("fixture stream was not cancelled")
                FAKE.finish_stream(stream_id)
                emit("cancel", {"session_id": session_id, "cancelled": True})
                return

            if stream["mode"] == "simple":
                emit("token", {"text": "Updated fixture reply"})
                FAKE.finish_stream(stream_id, "Updated fixture reply")
                emit(
                    "done",
                    {
                        "session_id": session_id,
                        "status": "complete",
                        "usage": {"input_tokens": 2, "output_tokens": 3},
                        "session": FAKE.session_snapshot(session_id),
                    },
                )
                emit("stream_end", {"session_id": session_id})
                return

            emit("token", {"text": "Fixture "})
            emit("reasoning", {"text": "Checking fixture entities. "})
            emit("context_status", {
                "session_id": session_id,
                "context_length": 100000,
                "last_prompt_tokens": 25000,
            })
            emit(
                "tool",
                {
                    "tid": "tool-remote-1",
                    "name": "ha_list_entities",
                    "args": {"domain": "light"},
                },
            )
            emit("todo_state", {
                "session_id": session_id,
                "todos": [{
                    "id": "fixture-todo",
                    "content": "List fixture lights",
                    "status": "completed",
                }],
                "summary": {"total": 1, "completed": 1, "pending": 0},
            })
            emit("warning", {
                "type": "fixture",
                "message": "Fixture fallback warning",
            })
            emit(
                "tool_complete",
                {
                    "tid": "tool-remote-1",
                    "name": "ha_list_entities",
                    "preview": "2 lights",
                    "is_error": False,
                },
            )
            emit(
                "approval",
                {
                    "session_id": session_id,
                    "approval_id": "approval-remote-1",
                    "description": "Approve the fixture Home Assistant action?",
                    "command": "ha.turn_on",
                    "choices": ["once", "session", "always", "deny"],
                },
            )
            if not stream["approval"].wait(timeout=8):
                raise AssertionError("fixture approval was not answered")
            emit(
                "clarify",
                {
                    "session_id": session_id,
                    "clarify_id": "clarify-remote-1",
                    "question": "Which fixture room?",
                    "choices_offered": ["Kitchen", "Office"],
                    "multi_select": True,
                },
            )
            if not stream["clarify"].wait(timeout=8):
                raise AssertionError("fixture clarification was not answered")
            emit("token", {"text": "reply"})
            emit("goal", {
                "session_id": session_id,
                "state": "continuing",
                "message": "Fixture goal continues",
            })
            emit("pending_steer_leftover", {
                "session_id": session_id,
                "text": "Use the fixture office next",
            })
            emit("metering", {
                "session_id": session_id,
                "usage": {"input_tokens": 4, "output_tokens": 2},
            })
            FAKE.finish_stream(stream_id, "Fixture reply")
            emit(
                "done",
                {
                    "session_id": session_id,
                    "status": "complete",
                    "usage": {"input_tokens": 4, "output_tokens": 2},
                    "session": FAKE.session_snapshot(session_id),
                },
            )
            with FAKE.lock:
                FAKE.sessions[session_id]["title"] = "Fixture Lights"
            emit(
                "title",
                {"session_id": session_id, "title": "Fixture Lights"},
            )
            emit(
                "title_status",
                {
                    "session_id": session_id,
                    "status": "generated",
                    "reason": "fixture",
                    "title": "Fixture Lights",
                },
            )
            emit("stream_end", {"session_id": session_id})
        except (BrokenPipeError, ConnectionResetError):
            return


class RunningServer:
    def __init__(self) -> None:
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), HermesRemoteHandler)
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


@asynccontextmanager
async def bridge_lifetime(bridge: Any) -> Any:
    try:
        yield bridge
    finally:
        await bridge.stop()


def event_type(frame: dict[str, Any]) -> str:
    if frame.get("method") != "event":
        return ""
    params = frame.get("params")
    return str(params.get("type") or "") if isinstance(params, dict) else ""


def event_payload(frame: dict[str, Any]) -> dict[str, Any]:
    params = frame.get("params")
    payload = params.get("payload") if isinstance(params, dict) else None
    return payload if isinstance(payload, dict) else {}


async def rpc_frame(
    websocket: Any,
    request_id: str,
    method: str,
    params: dict[str, Any],
    events: list[dict[str, Any]],
) -> dict[str, Any]:
    await websocket.send(
        json.dumps(
            {
                "jsonrpc": "2.0",
                "id": request_id,
                "method": method,
                "params": params,
            }
        )
    )
    while True:
        frame = json.loads(await asyncio.wait_for(websocket.recv(), timeout=10))
        if str(frame.get("id", "")) == request_id:
            return frame
        events.append(frame)


async def rpc(
    websocket: Any,
    request_id: str,
    method: str,
    params: dict[str, Any],
    events: list[dict[str, Any]],
) -> Any:
    frame = await rpc_frame(websocket, request_id, method, params, events)
    assert "error" not in frame, frame
    return frame["result"]


async def wait_for_event(
    websocket: Any,
    wanted: str,
    events: list[dict[str, Any]],
    predicate: Any = None,
) -> dict[str, Any]:
    def matches(frame: dict[str, Any]) -> bool:
        return event_type(frame) == wanted and (
            predicate is None or predicate(event_payload(frame))
        )

    for frame in events:
        if matches(frame):
            return frame
    while True:
        frame = json.loads(await asyncio.wait_for(websocket.recv(), timeout=10))
        events.append(frame)
        if matches(frame):
            return frame


async def wait_for_stream_closed(
    bridge: Any, conversation_id: str, stream_id: str
) -> None:
    for _attempt in range(100):
        active = bridge.remote_stream_by_conversation.get(conversation_id)
        task = bridge.remote_stream_tasks.get(conversation_id)
        if active != stream_id and (task is None or task.done()):
            return
        await asyncio.sleep(0.01)
    raise AssertionError(f"remote stream {stream_id} did not close")


def events_of_type(
    events: list[dict[str, Any]], wanted: str, conversation_id: str = ""
) -> list[dict[str, Any]]:
    matches = [frame for frame in events if event_type(frame) == wanted]
    if conversation_id:
        matches = [
            frame
            for frame in matches
            if event_payload(frame).get("conversationId") == conversation_id
        ]
    return matches


async def scenario() -> None:
    """Exercise the deployed remote-only, native WebUI conversation path."""

    global FAKE
    FAKE = FakeRemote()
    historical = FAKE.create_session(
        "Historical climate check",
        [
            {
                "id": "history-user",
                "role": "user",
                "content": [{"type": "input_text", "text": "Climate?"}],
            },
            {
                "id": "history-tool-carrier",
                "role": "assistant",
                "content": "",
                "tool_calls": [{
                    "id": "history-tool-1",
                    "type": "function",
                    "function": {
                        "name": "ha_get_state",
                        "arguments": "{\"entity_id\":\"climate.office\"}",
                    },
                }],
            },
            {
                "role": "tool",
                "tool_call_id": "history-tool-1",
                "content": "{\"result\":\"comfortable\",\"temperature\":21}",
            },
            {
                "role": "session_meta",
                "content": "{\"title\":\"protocol-only\"}",
            },
            {
                "id": "history-assistant",
                "role": "assistant",
                "content": "The office is comfortable.",
            },
        ],
    )
    historical_id = str(historical["session_id"])
    with FAKE.lock:
        FAKE.sessions[historical_id].update({
            "session_source": "messaging",
            "source_label": "Slack",
            "source_tag": "slack",
            "read_only": True,
        })
    previous_remote_url = os.environ.get("HERMES_REMOTE_URL")
    try:
        with RunningServer() as remote, tempfile.TemporaryDirectory(
            prefix="cybexos-hermes-native-runtime."
        ) as temporary:
            os.environ["HERMES_REMOTE_URL"] = remote.url
            temporary_path = Path(temporary)
            state_path = temporary_path / "conversations.json"
            credential_path = temporary_path / "remote-webui-auth.json"
            registry = BRIDGE.ConversationRegistry(state_path)
            registry.save()
            bridge = BRIDGE.HermesBridge(
                registry,
                "http://127.0.0.1:1",
                remote_auth_path=credential_path,
                local_backend_enabled=False,
            )
            local_gateway_calls: list[tuple[str, dict[str, Any]]] = []

            async def reject_local_gateway(
                method: str,
                params: dict[str, Any] | None = None,
                _timeout: float = 30.0,
                **_kwargs: Any,
            ) -> Any:
                local_gateway_calls.append((method, dict(params or {})))
                raise AssertionError(
                    f"remote runtime called local gateway method {method}"
                )

            bridge.gateway.request = reject_local_gateway

            async with bridge_lifetime(bridge), websockets.serve(
                bridge.client_handler, "127.0.0.1", 0
            ) as downstream:
                port = downstream.sockets[0].getsockname()[1]
                async with websockets.connect(
                    f"ws://127.0.0.1:{port}/ws"
                ) as client:
                    events: list[dict[str, Any]] = []

                    hello = await rpc(
                        client, "hello", "bridge.hello", {}, events
                    )
                    assert hello["selectedConversationId"] == ""
                    assert hello["conversations"] == []
                    assert hello["capabilities"]["conversations"] is True
                    assert hello["capabilities"]["localBackend"] is False
                    assert hello["agentReady"] is False
                    assert not credential_path.exists()

                    unauthenticated = await rpc(
                        client, "prelogin", "remote.status", {}, events
                    )
                    assert unauthenticated["state"] == "expired"
                    assert unauthenticated["authenticated"] is False

                    authenticated = await rpc(
                        client,
                        "login",
                        "remote.login",
                        {"url": remote.url, "password": FAKE.password},
                        events,
                    )
                    assert authenticated["state"] == "connected"
                    assert authenticated["authenticated"] is True
                    assert bridge.snapshot()["agentReady"] is True
                    credentials = credential_path.read_text(encoding="utf-8")
                    assert credential_path.stat().st_mode & 0o777 == 0o600
                    assert FAKE.cookie in credentials
                    assert FAKE.password not in credentials
                    assert FAKE.password not in state_path.read_text(encoding="utf-8")

                    catalog = await rpc(
                        client, "models", "models.catalog", {}, events
                    )
                    assert catalog == {
                        "groups": [{
                            "providerId": "openai-codex",
                            "provider": "OpenAI Codex",
                            "models": [
                                {"id": "gpt-5.6-sol", "label": "GPT-5.6 Sol"},
                                {"id": "gpt-5.4", "label": "GPT-5.4"},
                            ],
                        }],
                        "defaultModel": "gpt-5.6-sol",
                        "activeProvider": "openai-codex",
                    }
                    reasoning = await rpc(
                        client,
                        "reasoning-get",
                        "reasoning.get",
                        {"model": "gpt-5.6-sol", "modelProvider": "openai-codex"},
                        events,
                    )
                    assert reasoning["effort"] == "high"
                    assert reasoning["options"] == [
                        "", "none", "minimal", "low", "medium", "high",
                        "xhigh", "max",
                    ]
                    changed_reasoning = await rpc(
                        client,
                        "reasoning-set",
                        "reasoning.set",
                        {
                            "model": "gpt-5.6-sol",
                            "modelProvider": "openai-codex",
                            "effort": "max",
                        },
                        events,
                    )
                    assert changed_reasoning["effort"] == "max"
                    assert FAKE.reasoning_requests[-1] == {
                        "method": "POST",
                        "model": "gpt-5.6-sol",
                        "provider": "openai-codex",
                        "effort": "max",
                    }

                    listed = await rpc(
                        client,
                        "list-history",
                        "conversations.list",
                        {},
                        events,
                    )
                    assert listed["selectedConversationId"] == ""
                    assert [row["id"] for row in listed["conversations"]] == [
                        historical_id
                    ]
                    row = listed["conversations"][0]
                    assert row["sessionId"] == historical_id
                    assert row["title"] == "Historical climate check"
                    assert row["messageCount"] == 5
                    assert row["model"] == "fixture/model"

                    history = await rpc(
                        client,
                        "historical-transcript",
                        "session.history",
                        {"sessionId": historical_id},
                        events,
                    )
                    assert history["sessionId"] == historical_id
                    assert [message["role"] for message in history["messages"]] == [
                        "user",
                        "assistant",
                    ]
                    assert [message["id"] for message in history["messages"]] == [
                        "history-user",
                        "history-assistant",
                    ]
                    assert len(history["tools"]) == 1
                    assert history["tools"][0]["id"] == "history-tool-1"
                    assert history["tools"][0]["name"] == "ha_get_state"
                    assert history["tools"][0]["output"] == "comfortable"
                    assert history["history"]["limit"] == 80
                    assert history["history"]["hasMore"] is False
                    assert FAKE.session_queries[-1]["msg_limit"] == ["80"]
                    assert FAKE.external_import_requests == [{
                        "session_id": historical_id
                    }]
                    assert registry.conversations[historical_id]["read_only"] is False

                    continued = await rpc(
                        client,
                        "continue-historical",
                        "prompt.submit",
                        {
                            "sessionId": historical_id,
                            "text": "Edited fixture history continuation",
                        },
                        events,
                    )
                    assert continued["accepted"] is True
                    historical_stream = continued["streamId"]
                    await wait_for_event(
                        client,
                        "message.complete",
                        events,
                        lambda payload: payload.get("streamId")
                        == historical_stream,
                    )
                    await wait_for_stream_closed(
                        bridge, historical_id, historical_stream
                    )
                    assert FAKE.chat_start_requests[-1]["session_id"] == historical_id
                    assert FAKE.chat_start_requests[-1]["message"] == (
                        "Edited fixture history continuation"
                    )

                    new_default = await rpc(
                        client,
                        "new-default",
                        "conversations.select",
                        {"sessionId": ""},
                        events,
                    )
                    assert new_default == {"selectedConversationId": ""}
                    created = await rpc(
                        client,
                        "create",
                        "conversations.create",
                        {
                            "model": "gpt-5.6-sol",
                            "modelProvider": "openai-codex",
                        },
                        events,
                    )
                    conversation_id = created["id"]
                    assert conversation_id.startswith("remote-session-")
                    assert conversation_id != historical_id
                    assert created["sessionId"] == conversation_id
                    assert registry.selected_conversation_id == conversation_id
                    assert FAKE.new_requests[-1] == {
                        "worktree": False,
                        "model": "gpt-5.6-sol",
                        "model_provider": "openai-codex",
                    }
                    assert FAKE.import_requests == []
                    assert FAKE.rename_requests == []

                    configured = await rpc(
                        client,
                        "configure-model",
                        "session.configure",
                        {
                            "sessionId": conversation_id,
                            "model": "gpt-5.4",
                            "modelProvider": "openai-codex",
                        },
                        events,
                    )
                    assert configured["model"] == "gpt-5.4"
                    assert configured["modelProvider"] == "openai-codex"
                    assert FAKE.session_update_requests[-1] == {
                        "session_id": conversation_id,
                        "workspace": "",
                        "model": "gpt-5.4",
                        "model_provider": "openai-codex",
                    }

                    accepted = await rpc(
                        client,
                        "prompt",
                        "prompt.submit",
                        {
                            "sessionId": conversation_id,
                            "text": "List the fixture lights",
                            "model": "gpt-5.4",
                            "modelProvider": "openai-codex",
                            "explicitModelPick": True,
                        },
                        events,
                    )
                    assert accepted["accepted"] is True
                    assert accepted["sessionId"] == conversation_id
                    stream_id = accepted["streamId"]
                    assert FAKE.chat_start_requests[-1] == {
                        "session_id": conversation_id,
                        "message": "List the fixture lights",
                        "model": "gpt-5.4",
                        "model_provider": "openai-codex",
                        "explicit_model_pick": True,
                    }

                    approval = await wait_for_event(
                        client,
                        "request.approval",
                        events,
                        lambda payload: payload.get("conversationId")
                        == conversation_id,
                    )
                    approval_payload = event_payload(approval)
                    assert approval_payload["requestId"] == "approval-remote-1"
                    await rpc(
                        client,
                        "approve",
                        "approval.respond",
                        {
                            "sessionId": conversation_id,
                            "requestId": approval_payload["requestId"],
                            "decision": "allow_always",
                        },
                        events,
                    )

                    clarification = await wait_for_event(
                        client,
                        "request.clarify",
                        events,
                        lambda payload: payload.get("conversationId")
                        == conversation_id,
                    )
                    clarification_payload = event_payload(clarification)
                    assert clarification_payload["options"] == [
                        "Kitchen",
                        "Office",
                    ]
                    await rpc(
                        client,
                        "clarify",
                        "clarify.respond",
                        {
                            "sessionId": conversation_id,
                            "requestId": clarification_payload["requestId"],
                            "answer": ["Kitchen", "Office"],
                        },
                        events,
                    )

                    completion = await wait_for_event(
                        client,
                        "message.complete",
                        events,
                        lambda payload: payload.get("streamId") == stream_id,
                    )
                    assert event_payload(completion)["text"] == "Fixture reply"
                    title = await wait_for_event(
                        client,
                        "session.info",
                        events,
                        lambda payload: payload.get("streamId") == stream_id
                        and payload.get("kind") == "title_status",
                    )
                    assert event_payload(title)["upstreamStatus"] == "generated"
                    await wait_for_stream_closed(
                        bridge, conversation_id, stream_id
                    )

                    deltas = events_of_type(
                        events, "message.delta", conversation_id
                    )
                    tool_starts = events_of_type(
                        events, "tool.start", conversation_id
                    )
                    tool_completions = events_of_type(
                        events, "tool.complete", conversation_id
                    )
                    assert "".join(
                        str(event_payload(frame).get("text") or "")
                        for frame in deltas
                    ).endswith("Fixture reply")
                    assert event_payload(tool_starts[-1])["name"] == (
                        "ha_list_entities"
                    )
                    assert event_payload(tool_completions[-1])["toolCallId"] == (
                        "tool-remote-1"
                    )
                    reasoning = events_of_type(
                        events, "session.reasoning", conversation_id
                    )
                    warnings = events_of_type(
                        events, "session.warning", conversation_id
                    )
                    contexts = events_of_type(
                        events, "session.context", conversation_id
                    )
                    todos = events_of_type(
                        events, "session.todos", conversation_id
                    )
                    goals = events_of_type(
                        events, "session.goal", conversation_id
                    )
                    pending_steers = events_of_type(
                        events, "session.pending_steer", conversation_id
                    )
                    usage_events = events_of_type(
                        events, "session.usage", conversation_id
                    )
                    assert event_payload(reasoning[-1])["reasoning"] == (
                        "Checking fixture entities. "
                    )
                    assert event_payload(warnings[-1])["message"] == (
                        "Fixture fallback warning"
                    )
                    assert event_payload(contexts[-1])["context_length"] == 100000
                    assert event_payload(todos[-1])["todos"][0]["id"] == (
                        "fixture-todo"
                    )
                    assert event_payload(goals[-1])["kind"] == "goal"
                    assert event_payload(pending_steers[-1])["text"] == (
                        "Use the fixture office next"
                    )
                    assert any(
                        event_payload(frame).get("kind") == "metering"
                        for frame in usage_events
                    )
                    for frame in deltas + tool_starts + tool_completions:
                        payload = event_payload(frame)
                        assert payload["conversationId"] == conversation_id
                        assert payload["sessionId"] == conversation_id
                        assert "channelId" not in payload
                    assert FAKE.approval_responses[-1]["choice"] == "always"
                    assert FAKE.clarify_responses[-1]["response"] == (
                        "Kitchen, Office"
                    )
                    assert local_gateway_calls == []
                    for _attempt in range(100):
                        if (FAKE.global_event_connections > 0
                                and FAKE.session_event_connections > 0):
                            break
                        await asyncio.sleep(0.01)
                    assert FAKE.global_event_connections > 0
                    assert FAKE.session_event_connections > 0
                    assert bridge.remote_contract["checked"] is True
                    assert bridge.remote_contract["historyPagination"] is True
                    assert bridge.remote_contract["sessionStream"] is True
                    assert bridge.remote_contract["globalSessionEvents"] is True
                    assert bridge.remote_contract["modelSelection"] is True
                    assert bridge.remote_contract["reasoningEffort"] is True
                    assert bridge.remote_contract["attachments"] is True
                    assert bridge.remote_contract["branches"] is True
                    assert bridge.remote_contract["messageEditing"] is True
                    assert bridge.remote_contract["regeneration"] is True

                    settled = await rpc(
                        client,
                        "settled-history",
                        "session.history",
                        {"sessionId": conversation_id},
                        events,
                    )
                    assert [message["role"] for message in settled["messages"]] == [
                        "user",
                        "assistant",
                    ]

                    # Exercise the compatibility path used by WebUI releases
                    # that have duplicate+truncate but no native branch route.
                    bridge.remote_contract["nativeBranches"] = False
                    branch_result = await rpc(
                        client,
                        "branch",
                        "session.branch",
                        {"sessionId": conversation_id},
                        events,
                    )
                    branch_id = branch_result["sessionId"]
                    assert branch_id != conversation_id
                    assert branch_result["parentSessionId"] == conversation_id
                    assert registry.selected_conversation_id == branch_id
                    assert branch_result["upstream"]["fallback"] == (
                        "duplicate_truncate"
                    )
                    assert FAKE.duplicate_requests[-1] == {
                        "session_id": conversation_id
                    }

                    attachment_path = temporary_path / "fixture-note.txt"
                    attachment_path.write_text(
                        "attachment body from the runtime fixture\n",
                        encoding="utf-8",
                    )
                    attachment_turn = await rpc(
                        client,
                        "attachment-prompt",
                        "prompt.submit",
                        {
                            "sessionId": branch_id,
                            "text": "Inspect attachment fixture",
                            "attachments": [str(attachment_path)],
                        },
                        events,
                    )
                    attachment_stream = attachment_turn["streamId"]
                    await wait_for_event(
                        client,
                        "message.complete",
                        events,
                        lambda payload: payload.get("streamId")
                        == attachment_stream,
                    )
                    await wait_for_stream_closed(
                        bridge, branch_id, attachment_stream
                    )
                    assert FAKE.upload_requests[-1] == {
                        "session_id": branch_id,
                        "filename": "fixture-note.txt",
                        "content": b"attachment body from the runtime fixture\n",
                    }
                    attachment_request = FAKE.chat_start_requests[-1]
                    assert attachment_request["session_id"] == branch_id
                    assert attachment_request["message"] == (
                        "Inspect attachment fixture\n\n"
                        "[Attached files: fixture-note.txt]"
                    )
                    assert attachment_request["attachments"][0]["path"] == (
                        "/fixture/attachments/fixture-note.txt"
                    )
                    assert str(attachment_path) not in json.dumps(
                        attachment_request
                    )

                    branch_history = await rpc(
                        client,
                        "branch-history",
                        "session.history",
                        {"sessionId": branch_id},
                        events,
                    )
                    branch_users = [
                        message for message in branch_history["messages"]
                        if message["role"] == "user"
                    ]
                    assert branch_users[-1]["attachments"] == [{
                        "name": "fixture-note.txt",
                        "mime": "text/plain",
                        "size": 41,
                        "isImage": False,
                    }]
                    edited = await rpc(
                        client,
                        "edit-message",
                        "message.edit",
                        {
                            "sessionId": branch_id,
                            "sourceIndex": branch_users[-1]["sourceIndex"],
                            "text": "Edited fixture request",
                        },
                        events,
                    )
                    edited_stream = edited["streamId"]
                    assert FAKE.truncate_requests[-1] == {
                        "session_id": branch_id,
                        "keep_count": branch_users[-1]["sourceIndex"],
                    }
                    await wait_for_event(
                        client,
                        "message.complete",
                        events,
                        lambda payload: payload.get("streamId") == edited_stream,
                    )
                    await wait_for_stream_closed(bridge, branch_id, edited_stream)

                    regenerated = await rpc(
                        client,
                        "regenerate",
                        "message.regenerate",
                        {"sessionId": branch_id},
                        events,
                    )
                    regenerated_stream = regenerated["streamId"]
                    regeneration_request = FAKE.chat_start_requests[-1]
                    assert regeneration_request == {
                        "session_id": branch_id,
                        "regenerate": True,
                        "regeneration_revision": "fixture-revision-4",
                    }
                    await wait_for_event(
                        client,
                        "message.complete",
                        events,
                        lambda payload: payload.get("streamId")
                        == regenerated_stream,
                    )
                    await wait_for_stream_closed(
                        bridge, branch_id, regenerated_stream
                    )
                    await rpc(
                        client,
                        "delete-branch",
                        "conversations.delete",
                        {"sessionId": branch_id},
                        events,
                    )
                    await rpc(
                        client,
                        "reselect-original",
                        "conversations.select",
                        {"sessionId": conversation_id},
                        events,
                    )

                    compressed = await rpc(
                        client,
                        "compress",
                        "session.compress",
                        {
                            "sessionId": conversation_id,
                            "focusTopic": "Keep fixture light state",
                        },
                        events,
                    )
                    assert compressed["compressed"] is True
                    assert FAKE.compress_requests[-1] == {
                        "session_id": conversation_id,
                        "focus_topic": "Keep fixture light state",
                    }

                    cancelling = await rpc(
                        client,
                        "cancel-prompt",
                        "prompt.submit",
                        {
                            "sessionId": conversation_id,
                            "text": FAKE.cancel_prompt,
                        },
                        events,
                    )
                    cancel_stream_id = cancelling["streamId"]
                    await wait_for_event(
                        client,
                        "message.delta",
                        events,
                        lambda payload: payload.get("streamId")
                        == cancel_stream_id,
                    )
                    interrupted = await rpc(
                        client,
                        "interrupt",
                        "session.interrupt",
                        {"sessionId": conversation_id},
                        events,
                    )
                    assert interrupted["cancelled"] is True
                    assert cancel_stream_id in FAKE.cancelled_streams
                    await wait_for_event(
                        client,
                        "message.complete",
                        events,
                        lambda payload: payload.get("streamId")
                        == cancel_stream_id
                        and payload.get("cancelled") is True,
                    )
                    await wait_for_stream_closed(
                        bridge, conversation_id, cancel_stream_id
                    )

                    deleted = await rpc(
                        client,
                        "delete",
                        "conversations.delete",
                        {"sessionId": conversation_id},
                        events,
                    )
                    assert deleted == {"deleted": conversation_id}
                    assert registry.selected_conversation_id == ""
                    remaining = await rpc(
                        client,
                        "remaining",
                        "conversations.list",
                        {},
                        events,
                    )
                    assert [row["id"] for row in remaining["conversations"]] == [
                        historical_id
                    ]

                    FAKE.expire()
                    expired = await rpc_frame(
                        client,
                        "expired-status",
                        "session.status",
                        {"sessionId": historical_id},
                        events,
                    )
                    assert expired["error"]["code"] == -32040
                    expiry = await wait_for_event(
                        client,
                        "remote.session_expired",
                        events,
                        lambda payload: payload.get("statusCode") == 401,
                    )
                    assert event_payload(expiry)["state"] == "expired"
                    final_snapshot = bridge.snapshot()
                    assert final_snapshot["selectedConversationId"] == ""
                    assert final_snapshot["agentReady"] is False

                    assert FAKE.protected_cookies
                    serialized = json.dumps(
                        {"events": events, "snapshot": final_snapshot},
                        ensure_ascii=False,
                    )
                    assert "channelId" not in serialized
                    assert FAKE.cookie not in serialized
                    assert FAKE.password not in serialized
                    for path in temporary_path.iterdir():
                        if path.is_file():
                            assert FAKE.password not in path.read_text(
                                encoding="utf-8"
                            )
    finally:
        if previous_remote_url is None:
            os.environ.pop("HERMES_REMOTE_URL", None)
        else:
            os.environ["HERMES_REMOTE_URL"] = previous_remote_url


if __name__ == "__main__":
    asyncio.run(scenario())
    print(
        "Hermes remote runtime lists native history, defaults to New chat, "
        "creates and deletes WebUI sessions, relays SSE interactions, and "
        "surfaces expiry without persisting the password"
    )
