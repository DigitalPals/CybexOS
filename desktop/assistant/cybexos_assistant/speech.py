"""Spoken replies through speech-dispatcher, one sentence per message.

Speaking sentence by sentence lets the reply follow along (speech.progress)
and lets Stop cancel exactly this client's speech: SSIP's `CANCEL self` leaves
a screen reader talking through the same server untouched.
"""

from __future__ import annotations

import asyncio
import contextlib
import getpass
import os
from pathlib import Path
import re
import shutil

from .protocol import LOG


MAX_SENTENCES = 40
CODE_NOTE = "I put the code in the reply."

_FENCE = re.compile(r"```.*?(?:```|\Z)|~~~.*?(?:~~~|\Z)", re.S)
_IMAGE = re.compile(r"!\[([^\]]*)\]\([^)]*\)")
_LINK = re.compile(r"\[([^\]]+)\]\([^)]*\)")
_AUTOLINK = re.compile(r"<(https?://[^>]+)>")
_CODE = re.compile(r"`([^`]*)`")
_EMPHASIS = (
    re.compile(r"\*\*(?=\S)(.+?)(?<=\S)\*\*"),
    re.compile(r"(?<!\w)__(?=\S)(.+?)(?<=\S)__(?!\w)"),
    re.compile(r"~~(?=\S)(.+?)(?<=\S)~~"),
    re.compile(r"(?<![\w*])\*(?=\S)(.+?)(?<=\S)\*(?![\w*])"),
    re.compile(r"(?<!\w)_(?=\S)(.+?)(?<=\S)_(?!\w)"),
)
_TAG = re.compile(r"</?[A-Za-z][^>]*>")
_PREFIX = re.compile(r"^\s{0,3}(?:#{1,6}\s+|>\s?|[-*+]\s+(?:\[[ xX]\]\s+)?|\d+[.)]\s+)")
_RULE = re.compile(r"^[\s\-*_=|:]+$")
_SENTENCE_END = re.compile(r"(?<=[.!?…])\s+(?=[\"'(\[]?[A-Z0-9À-ÖØ-Þ])")


def sentences(markdown, limit=MAX_SENTENCES):
    """Markdown as plain sentences that read well aloud."""
    text = _FENCE.sub("\n" + CODE_NOTE + "\n", str(markdown or ""))
    text = _IMAGE.sub(r"\1", text)
    text = _LINK.sub(r"\1", text)
    text = _AUTOLINK.sub(r"\1", text)
    text = _CODE.sub(r"\1", text)
    for pattern in _EMPHASIS:
        text = pattern.sub(r"\1", text)
    text = _TAG.sub("", text)
    found = []
    for line in text.splitlines():
        line = _PREFIX.sub("", line).strip()
        if not line or _RULE.fullmatch(line):
            continue
        for part in _SENTENCE_END.split(line):
            part = " ".join(part.split())
            if part and not (part == CODE_NOTE and found and found[-1] == CODE_NOTE):
                found.append(part)
    return found[:limit]


class SsipError(Exception):
    pass


class Ssip:
    """A minimal SSIP client: commands, replies and event notifications."""

    def __init__(self):
        self.reader = None
        self.writer = None
        self.replies = asyncio.Queue()
        self.events = asyncio.Queue()
        self.task = None

    async def connect(self, path):
        self.reader, self.writer = await asyncio.wait_for(asyncio.open_unix_connection(str(path)), 5)
        self.task = asyncio.create_task(self._read())

    async def _read(self):
        lines = []
        try:
            while True:
                raw = await self.reader.readline()
                if not raw:
                    break
                line = raw.decode("utf-8", "replace").rstrip("\r\n")
                if len(line) < 4 or not line[:3].isdigit():
                    continue
                lines.append(line[4:])
                if line[3] == "-":
                    continue
                code, body = int(line[:3]), lines
                lines = []
                (self.events if 700 <= code < 800 else self.replies).put_nowait((code, body))
        finally:
            self.replies.put_nowait((0, ["connection closed"]))
            self.events.put_nowait((0, ["connection closed"]))

    async def command(self, line, timeout=5):
        self.writer.write((line + "\r\n").encode("utf-8"))
        await self.writer.drain()
        code, body = await asyncio.wait_for(self.replies.get(), timeout)
        if not 200 <= code < 300:
            raise SsipError(f"{code} {' '.join(body)}")
        return code, body

    async def speak(self, text):
        await self.command("SPEAK")
        lines = [("." + line if line.startswith(".") else line) for line in text.splitlines()] or [""]
        _, body = await self.command("\r\n".join(lines) + "\r\n.")
        return body[0] if len(body) > 1 else ""

    async def wait_end(self, message, timeout):
        loop = asyncio.get_running_loop()
        deadline = loop.time() + timeout
        while True:
            remaining = deadline - loop.time()
            if remaining <= 0:
                return "timeout"
            code, body = await asyncio.wait_for(self.events.get(), remaining)
            if code == 0:
                raise SsipError("speech-dispatcher closed the connection")
            if message and body and body[0] != message:
                continue
            if code == 702:
                return "end"
            if code == 703:
                return "cancelled"

    async def close(self):
        if self.writer is not None:
            with contextlib.suppress(Exception):
                self.writer.write(b"QUIT\r\n")
                await asyncio.wait_for(self.writer.drain(), 1)
            self.writer.close()
            with contextlib.suppress(Exception):
                await self.writer.wait_closed()
        if self.task is not None:
            self.task.cancel()
            with contextlib.suppress(asyncio.CancelledError, Exception):
                await self.task


class Speaker:
    """One spoken reply at a time; a new one replaces the current one."""

    def __init__(self, socket_path, publish):
        self.socket_path = Path(socket_path)
        self.publish = publish
        self.task = None
        self.counter = 0

    @property
    def available(self):
        return self.socket_path.exists() or shutil.which("spd-say") is not None

    @property
    def speaking(self):
        return self.task is not None and not self.task.done()

    async def say(self, text, language=None):
        await self.stop()
        self.counter += 1
        identifier = f"s-{self.counter}"
        items = sentences(text)
        language = language if isinstance(language, str) and re.fullmatch(r"[A-Za-z]{2,3}(?:[-_][A-Za-z0-9]{2,8})?", language) else None
        self.task = asyncio.create_task(self._run(identifier, items, language))
        return {"id": identifier, "sentences": items}

    async def stop(self):
        task, self.task = self.task, None
        if task is not None and not task.done():
            task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await task

    async def _run(self, identifier, items, language):
        status = "done"
        try:
            if items:
                if self.socket_path.exists():
                    await self._ssip(identifier, items, language)
                else:
                    await self._spd_say(identifier, items, language)
        except asyncio.CancelledError:
            status = "stopped"
            raise
        except Exception as error:  # a broken speech server must not take the service down
            LOG.warning("speech failed: %s", error)
            status = "failed"
        finally:
            self.publish("speech.done", {"id": identifier, "status": status})

    async def _ssip(self, identifier, items, language):
        client = Ssip()
        try:
            await client.connect(self.socket_path)
            await client.command(f"SET self CLIENT_NAME {user()}:cybexos:assistant")
            await client.command("SET self NOTIFICATION end on")
            await client.command("SET self NOTIFICATION cancel on")
            if language:
                with contextlib.suppress(SsipError):
                    await client.command(f"SET self LANGUAGE {language}")
            for index, sentence in enumerate(items):
                self.publish("speech.progress", {"id": identifier, "index": index})
                message = await client.speak(sentence)
                outcome = await client.wait_end(message, 15 + len(sentence) / 6)
                if outcome == "cancelled":
                    raise SsipError("speech was cancelled by another client")
        except asyncio.CancelledError:
            # Only this client's queue: a screen reader keeps talking.
            with contextlib.suppress(Exception):
                await asyncio.shield(client.command("CANCEL self", timeout=1))
            raise
        finally:
            await client.close()

    async def _spd_say(self, identifier, items, language):
        for index, sentence in enumerate(items):
            self.publish("speech.progress", {"id": identifier, "index": index})
            command = ["spd-say", "-w"] + (["-l", language] if language else []) + ["--", sentence]
            process = await asyncio.create_subprocess_exec(
                *command, stdin=asyncio.subprocess.DEVNULL,
                stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL)
            try:
                await process.wait()
            except asyncio.CancelledError:
                with contextlib.suppress(ProcessLookupError):
                    process.terminate()
                with contextlib.suppress(Exception):
                    stopper = await asyncio.create_subprocess_exec(
                        "spd-say", "-S", stdout=asyncio.subprocess.DEVNULL,
                        stderr=asyncio.subprocess.DEVNULL)
                    await asyncio.wait_for(stopper.wait(), 2)
                raise


def user():
    try:
        name = getpass.getuser()
    except (KeyError, OSError):
        name = str(os.getuid())
    return re.sub(r"[^A-Za-z0-9_.-]", "_", name) or "user"


def default_socket(env=os.environ):
    runtime = env.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}"
    return Path(env.get("CYBEXOS_ASSISTANT_SPEECHD") or Path(runtime) / "speech-dispatcher" / "speechd.sock")
