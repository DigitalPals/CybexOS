"""Atomic, coalesced conversation metadata persistence."""

from __future__ import annotations

import asyncio
from contextlib import suppress
import json
import os
from pathlib import Path
from typing import Any


from .protocol import (
    LOG,
    BRIDGE_VERSION,
    REGISTRY_SAVE_DELAY,
    CONVERSATION_ID_PATTERN,
    utc_now,
)

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
        self._save_handle: asyncio.TimerHandle | None = None
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

    def save_later(self, delay: float = REGISTRY_SAVE_DELAY) -> None:
        """Coalesce frequent status writes into one atomic save per window."""
        if self._save_handle is not None:
            return
        try:
            loop = asyncio.get_running_loop()
        except RuntimeError:
            self.save()
            return
        self._save_handle = loop.call_later(delay, self._deferred_save)

    def _deferred_save(self) -> None:
        self._save_handle = None
        try:
            self.save()
        except OSError as exc:
            LOG.error("could not save conversation registry %s: %s", self.path, exc)

    def flush(self) -> None:
        """Write a pending coalesced save now (used on shutdown)."""
        if self._save_handle is not None:
            self.save()

    def save(self) -> None:
        if self._save_handle is not None:
            self._save_handle.cancel()
            self._save_handle = None
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
