"""Wire framing, limits and paths shared by the service and its clients."""

from __future__ import annotations

import asyncio
import json
import logging
import os
from pathlib import Path
import time


LOG = logging.getLogger("cybexos-assistant")
PROTOCOL = 1
# One JSON object per line. The shell never sends images through the socket
# (only a path), so a line this long is a confused or hostile client.
MAX_LINE = 4 * 1024 * 1024
# Agent CLIs echo tool results, which can be large files; a line beyond this
# is dropped rather than buffered without bound.
MAX_AGENT_LINE = 64 * 1024 * 1024
MAX_PROMPT = 32 * 1024
MAX_SCREENSHOT = 20 * 1024 * 1024
# Frames queued for one client: a long streamed reply is one frame per
# chunk. A shell that stops reading is disconnected (it reconciles with
# hello) rather than holding every agent event in memory.
MAX_CLIENT_BACKLOG = 16384

BUSY = -32001
NOT_FOUND = -32002
UNAVAILABLE = -32003


class RpcFault(Exception):
    """A JSON-RPC error safe to return to a local client."""

    def __init__(self, code, message):
        super().__init__(message)
        self.code = code
        self.message = message


def encode(frame):
    return (json.dumps(frame, ensure_ascii=False, separators=(",", ":")) + "\n").encode()


def result_frame(request_id, result):
    return {"jsonrpc": "2.0", "id": request_id, "result": result}


def error_frame(request_id, code, message):
    return {"jsonrpc": "2.0", "id": request_id, "error": {"code": code, "message": message}}


def notification(method, params):
    return {"jsonrpc": "2.0", "method": method, "params": params}


def now_ms():
    return int(time.time() * 1000)


def runtime_dir(env=os.environ):
    return Path(env.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}")


def default_socket(env=os.environ):
    return runtime_dir(env) / "cybexos" / "assistant.sock"


def screenshot_dir(env=os.environ):
    return runtime_dir(env) / "cybexos" / "assistant"


def default_state_dir(home):
    return Path(home) / ".local" / "state" / "cybexos" / "assistant"


async def iter_lines(reader, limit=MAX_AGENT_LINE):
    """Yield complete lines without the newline; an overlong line is skipped.

    StreamReader.readline() would raise and leave the reader mid-line, so
    chunks are split here and an oversized line is discarded up to its end.
    """
    buffer = bytearray()
    discarding = False
    while True:
        chunk = await reader.read(65536)
        if not chunk:
            if buffer and not discarding:
                yield bytes(buffer)
            return
        start = 0
        while True:
            end = chunk.find(b"\n", start)
            if end == -1:
                if not discarding:
                    buffer += chunk[start:]
                    if len(buffer) > limit:
                        LOG.warning("dropping a line longer than %d bytes", limit)
                        buffer.clear()
                        discarding = True
                break
            if discarding:
                discarding = False
            else:
                buffer += chunk[start:end]
                if len(buffer) <= limit:
                    yield bytes(buffer)
                buffer.clear()
            start = end + 1


def parse_json(line):
    try:
        value = json.loads(line)
    except (UnicodeDecodeError, json.JSONDecodeError):
        return None
    return value if isinstance(value, dict) else None


async def stop_process(process, grace=3.0):
    """Terminate a child and wait for it, escalating to SIGKILL."""
    if process is None or process.returncode is not None:
        return
    try:
        process.terminate()
    except ProcessLookupError:
        return
    try:
        await asyncio.wait_for(process.wait(), grace)
    except asyncio.TimeoutError:
        try:
            process.kill()
        except ProcessLookupError:
            return
        await process.wait()
