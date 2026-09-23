#!/usr/bin/env python3
"""Focused native-conversation contract checks for the Hermes menubar bridge."""

from __future__ import annotations

import asyncio
import importlib.util
import json
import os
from pathlib import Path
import stat
import sys
import tempfile
from typing import Any
from urllib.parse import parse_qs, urlsplit


ROOT = Path(__file__).resolve().parents[1]
BRIDGE_PATH = ROOT / "roles/desktop/files/hermes-menubar-bridge/hermes_bridge.py"
SPEC = importlib.util.spec_from_file_location("hermes_menubar_bridge", BRIDGE_PATH)
assert SPEC and SPEC.loader
BRIDGE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = BRIDGE
SPEC.loader.exec_module(BRIDGE)


def connected_remote(bridge: Any, url: str) -> None:
    bridge.remote_auth.base_url = url
    bridge.remote_auth.source = "environment"
    bridge.remote_auth._status = bridge.remote_auth._make_status(
        "connected",
        configured=True,
        url=url,
        reachable=True,
        auth_enabled=True,
        authenticated=True,
        logged_in=True,
        password_auth_enabled=True,
        message="Connected",
    )


async def scenario() -> None:
    previous_remote = os.environ.pop("HERMES_REMOTE_URL", None)
    try:
        with tempfile.TemporaryDirectory(
            prefix="cybexos-hermes-conversations."
        ) as temporary:
            root = Path(temporary)
            state = root / "conversations.json"

            registry = BRIDGE.ConversationRegistry(state)
            assert registry.conversations == {}
            assert registry.selected_conversation_id == ""
            registry.save()
            assert stat.S_IMODE(state.stat().st_mode) == 0o600
            assert stat.S_IMODE(state.parent.stat().st_mode) == 0o700

            # Even a stale persisted selection must reopen on virtual New chat.
            state.write_text(
                json.dumps(
                    {
                        "selected_conversation_id": "history-1",
                        "conversations": [
                            {
                                "session_id": "history-1",
                                "title": "Persisted history",
                                "message_count": 2,
                            }
                        ],
                    }
                ),
                encoding="utf-8",
            )
            reloaded = BRIDGE.ConversationRegistry(state)
            assert reloaded.selected_conversation_id == ""
            assert reloaded.conversations["history-1"]["title"] == (
                "Persisted history"
            )

            bridge = BRIDGE.HermesBridge(
                reloaded,
                "http://127.0.0.1:1",
                root / "remote-auth.json",
                local_backend_enabled=False,
            )
            bridge.start()
            assert bridge.gateway._runner is None
            bounded_tool = bridge._remote_tool_text("x" * 8000)
            assert len(bounded_tool) == BRIDGE.MAX_REMOTE_TOOL_DETAIL
            assert bounded_tool.endswith("…")

            hello = await bridge.dispatch(
                "bridge.hello", {"client": "fixture", "version": 1}
            )
            assert hello["backendStatus"] == "disabled"
            assert hello["selectedConversationId"] == ""
            assert hello["capabilities"]["conversations"] is True
            assert hello["capabilities"]["localBackend"] is False
            assert hello["capabilities"]["providerSetup"] is False
            assert "conversations" in hello["features"]
            assert "channels" not in hello["capabilities"]
            assert "channels" not in hello["features"]

            connected_remote(bridge, "https://hermes.example.test:9443")
            calls: list[tuple[str, str, dict[str, Any] | None]] = []
            events: list[tuple[str, dict[str, Any]]] = []
            sessions: dict[str, dict[str, Any]] = {
                "history-1": {
                    "session_id": "history-1",
                    "title": "Kitchen lights",
                    "model": "fixture/model",
                    "message_count": 2,
                    "created_at": 1788000000,
                    "last_message_at": 1788000300,
                    "messages": [
                        {"id": "m1", "role": "user", "content": "Lights?"},
                        {
                            "id": "m2",
                            "role": "assistant",
                            "content": "They are on.",
                        },
                    ],
                },
                "shared.read-only": {
                    "session_id": "shared.read-only",
                    "title": "Shared transcript",
                    "message_count": 1,
                    "read_only": True,
                    "messages": [
                        {"id": "s1", "role": "assistant", "content": "Shared"}
                    ],
                },
            }

            async def fake_remote_request(
                method: str,
                path: str,
                payload: dict[str, Any] | None = None,
                timeout: float = 30.0,
            ) -> dict[str, Any]:
                assert timeout > 0
                calls.append((method, path, payload))
                if method == "GET" and path == "/api/sessions?exclude_hidden=1":
                    return {
                        "sessions": [
                            {key: value for key, value in session.items()
                             if key != "messages"}
                            for session in sessions.values()
                        ]
                    }
                if method == "GET" and path.startswith("/api/session?session_id="):
                    session_id = parse_qs(urlsplit(path).query)["session_id"][0]
                    return {"session": sessions[session_id]}
                if method == "GET" and path.startswith(
                    "/api/session/status?session_id="
                ):
                    session_id = path.rsplit("=", 1)[1]
                    return {
                        "session_id": session_id,
                        "is_streaming": False,
                        "active_stream_id": None,
                    }
                if method == "POST" and path == "/api/session/new":
                    created = {
                        "session_id": "new-session-1",
                        "title": "Untitled chat",
                        "message_count": 0,
                        "messages": [],
                    }
                    sessions[created["session_id"]] = created
                    return {"session": created}
                if method == "POST" and path == "/api/session/delete":
                    assert payload is not None
                    sessions.pop(str(payload["session_id"]))
                    return {"ok": True}
                raise AssertionError(f"unexpected remote request: {method} {path}")

            async def capture_event(
                event_type: str, payload: dict[str, Any]
            ) -> None:
                events.append((event_type, payload))

            bridge.remote_request = fake_remote_request
            bridge.broadcast_event = capture_event

            listed = await bridge.dispatch("conversations.list", {})
            assert listed["selectedConversationId"] == ""
            assert [row["id"] for row in listed["conversations"]] == [
                "history-1",
                "shared.read-only",
            ]
            historical = listed["conversations"][0]
            assert historical["sessionId"] == "history-1"
            assert historical["title"] == "Kitchen lights"
            assert historical["messageCount"] == 2
            assert listed["conversations"][1]["readOnly"] is True

            history = await bridge.dispatch(
                "session.history", {"sessionId": "history-1"}
            )
            assert history["sessionId"] == "history-1"
            assert [message["role"] for message in history["messages"]] == [
                "user",
                "assistant",
            ]
            assert reloaded.selected_conversation_id == "history-1"

            new_default = await bridge.dispatch(
                "conversations.select", {"sessionId": ""}
            )
            assert new_default == {"selectedConversationId": ""}
            created = await bridge.dispatch("conversations.create", {})
            assert created["id"] == "new-session-1"
            assert created["sessionId"] == "new-session-1"
            assert reloaded.selected_conversation_id == "new-session-1"
            deleted = await bridge.dispatch(
                "conversations.delete", {"sessionId": "new-session-1"}
            )
            assert deleted == {"deleted": "new-session-1"}
            assert reloaded.selected_conversation_id == ""

            try:
                await bridge.dispatch(
                    "conversations.delete", {"sessionId": "shared.read-only"}
                )
            except BRIDGE.RpcFault as fault:
                assert fault.code == -32046
            else:
                raise AssertionError("read-only history was deletable")

            try:
                await bridge.dispatch("channels.list", {})
            except BRIDGE.RpcFault as fault:
                assert fault.code == -32601
            else:
                raise AssertionError("retired channel RPC unexpectedly exists")

            assert ("GET", "/api/sessions?exclude_hidden=1", None) in calls
            assert any(path == "/api/session/new" for _, path, _ in calls)
            assert any(path == "/api/session/delete" for _, path, _ in calls)
            serialized = json.dumps(
                {"snapshot": bridge.snapshot(), "events": events},
                ensure_ascii=False,
            )
            assert "channelId" not in serialized
            assert "fixture-password" not in state.read_text(encoding="utf-8")
            await bridge.stop()
    finally:
        if previous_remote is not None:
            os.environ["HERMES_REMOTE_URL"] = previous_remote


class StalledSocket:
    """A local client that never drains its socket."""

    def __init__(self) -> None:
        self.never = asyncio.Event()
        self.closed_with: tuple[int, str] | None = None

    async def send(self, _text: str) -> None:
        await self.never.wait()

    async def close(self, code: int = 1000, reason: str = "") -> None:
        self.closed_with = (code, reason)


class RecordingSocket:
    def __init__(self) -> None:
        self.frames: list[dict[str, Any]] = []

    async def send(self, text: str) -> None:
        self.frames.append(json.loads(text))

    async def close(self, code: int = 1000, reason: str = "") -> None:
        pass


async def delivery_scenario() -> None:
    with tempfile.TemporaryDirectory(prefix="cybexos-hermes-delivery.") as temporary:
        root = Path(temporary)
        state = root / "conversations.json"
        state.write_text(
            json.dumps({"conversations": [{"session_id": "live-1", "title": "Live"}]}),
            encoding="utf-8",
        )
        registry = BRIDGE.ConversationRegistry(state)
        bridge = BRIDGE.HermesBridge(
            registry,
            "http://127.0.0.1:1",
            root / "remote-auth.json",
            local_backend_enabled=False,
        )
        saves: list[str] = []
        real_save = registry.save

        def counting_save() -> None:
            saves.append(registry.conversations["live-1"]["status_text"])
            real_save()

        registry.save = counting_save  # type: ignore[method-assign]

        # Repeated thinking/tool-progress status is neither re-broadcast nor
        # re-persisted; a real transition is, and writes are coalesced.
        fast = BRIDGE.LocalClient(RecordingSocket())  # type: ignore[arg-type]
        fast.start()
        bridge.clients.add(fast)
        conversation = registry.conversations["live-1"]
        for _ in range(50):
            await bridge.set_conversation_status(
                conversation, "working", "Hermes is working…"
            )
        await bridge.set_conversation_status(
            conversation, "working", "Hermes is reading…"
        )
        await bridge.set_conversation_status(
            conversation, "working", "Hermes is reading…", unread=False
        )
        await asyncio.sleep(0.05)
        kinds = [frame["params"]["type"] for frame in fast.websocket.frames]
        assert kinds == [
            "session.status",
            "conversation.updated",
            "session.status",
            "conversation.updated",
        ], kinds
        assert saves == [], "status churn must not write synchronously"
        assert registry._save_handle is not None
        await asyncio.sleep(BRIDGE.REGISTRY_SAVE_DELAY + 0.2)
        assert saves == ["Hermes is reading…"], saves
        persisted = json.loads(state.read_text(encoding="utf-8"))
        assert persisted["conversations"][0]["status_text"] == "Hermes is reading…"

        # Shutdown flushes a pending coalesced write.
        await bridge.set_conversation_status(conversation, "idle", "Ready")
        assert len(saves) == 1
        await bridge.stop()
        assert saves[-1] == "Ready" and registry._save_handle is None

        # A client that stops reading is dropped after its bounded backlog
        # instead of blocking the broadcaster (and the upstream heartbeat).
        stalled_socket = StalledSocket()
        stalled = BRIDGE.LocalClient(stalled_socket, backlog=4)  # type: ignore[arg-type]
        stalled.start()
        healthy = BRIDGE.LocalClient(RecordingSocket())  # type: ignore[arg-type]
        healthy.start()
        bridge.clients = {stalled, healthy}
        await asyncio.wait_for(
            asyncio.gather(
                *(bridge.broadcast_event("fixture.tick", {"n": n}) for n in range(20))
            ),
            timeout=1,
        )
        await asyncio.sleep(0.05)
        assert stalled not in bridge.clients
        assert stalled.closed is True
        assert stalled_socket.closed_with == (1013, "client too slow")
        assert healthy in bridge.clients
        assert [
            frame["params"]["payload"]["n"] for frame in healthy.websocket.frames
        ] == list(range(20))
        for client in (stalled, healthy, fast):
            await client.stop()


if __name__ == "__main__":
    asyncio.run(scenario())
    asyncio.run(delivery_scenario())
    print(
        "Hermes bridge exposes native WebUI history, starts on New chat, "
        "creates and deletes sessions, has no channel RPC contract, "
        "coalesces status churn, and isolates slow local clients"
    )
