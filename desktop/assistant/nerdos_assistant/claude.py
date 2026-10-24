"""Claude Code over stream-json, with permission prompts answered by the policy.

`--permission-prompt-tool stdio` turns every prompt Claude Code would show in
a terminal into a `can_use_tool` control request on stdout. The answer is a
`control_response` on stdin: the policy's, or the person's through a card.
"""

from __future__ import annotations

import asyncio
import base64
import collections
import contextlib
import itertools
import os

from . import policy, steps
from .protocol import LOG, encode, iter_lines, parse_json, stop_process
from .turn import classify


IDLE_SECONDS = 15 * 60
STOP_GRACE = 5.0


class ClaudeAgent:
    name = "claude"
    label = "Claude Code"

    def __init__(self, executable, home, instructions, status_path=None, conversation_id=None,
                 on_conversation=None, env=None):
        self.executable = executable
        self.home = str(home)
        self.instructions = instructions
        self.status_path = status_path
        self.conversation_id = conversation_id
        self.on_conversation = on_conversation or (lambda agent, identifier: None)
        self.env = env
        self.process = None
        self.model = None
        self.turn = None
        self.result = None
        self.stderr = collections.deque(maxlen=20)
        self.tasks = set()
        self.write_lock = asyncio.Lock()
        self.idle = None
        self.requests = itertools.count(1)
        self.resumed = False
        self.resume_failed = False
        self.received = 0

    @property
    def resumable(self):
        return bool(self.conversation_id)

    def handoff(self):
        return [self.executable, "--resume", self.conversation_id] if self.conversation_id else None

    def _spawn(self, coroutine):
        task = asyncio.create_task(coroutine)
        self.tasks.add(task)
        task.add_done_callback(self.tasks.discard)
        return task

    def _record(self, identifier):
        if isinstance(identifier, str) and identifier and identifier != self.conversation_id:
            self.conversation_id = identifier
            self.on_conversation(self.name, identifier)

    async def _start(self, model):
        if self.process is not None and self.process.returncode is None:
            if self.model == model:
                return
            # A different model needs a new process; the session resumes in it.
            await self.close()
        command = [self.executable, "-p", "--input-format", "stream-json", "--output-format", "stream-json",
                   "--verbose", "--include-partial-messages", "--permission-prompt-tool", "stdio",
                   "--append-system-prompt", self.instructions]
        if model:
            command += ["--model", model]
        self.resumed = bool(self.conversation_id)
        if self.conversation_id:
            command += ["--resume", self.conversation_id]
        self.received = 0
        self.process = await asyncio.create_subprocess_exec(
            *command, cwd=self.home, env=self.env, stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE, start_new_session=True)
        self.model = model
        self.stderr.clear()
        process = self.process
        errors = self._spawn(self._read_errors(process))
        self._spawn(self._read(process, errors))

    async def _send(self, message):
        process = self.process
        if process is None or process.stdin is None or process.returncode is not None:
            raise ConnectionError("Claude Code is not running")
        async with self.write_lock:
            process.stdin.write(encode(message))
            await process.stdin.drain()

    def _settle(self, status, text=None, error="", kind=""):
        if self.result is not None and not self.result.done():
            self.result.set_result({"status": status, "text": text, "error": error, "kind": kind})

    async def run(self, turn, text, image=None, model=None):
        outcome = await self._attempt(turn, text, image, model)
        if outcome["kind"] == "crashed" and self.resume_failed and not turn.stopping:
            # A session Claude Code no longer has (deleted, or from another
            # machine's home) must not fail every later question too.
            LOG.warning("could not resume Claude Code session %s; starting a new one", self.conversation_id)
            self.resume_failed = False
            self.conversation_id = None
            self.on_conversation(self.name, None)
            outcome = await self._attempt(turn, text, image, model)
        return outcome

    async def _attempt(self, turn, text, image, model):
        self._cancel_idle()
        await self._start(model or None)
        loop = asyncio.get_running_loop()
        self.turn, self.result = turn, loop.create_future()
        content = [{"type": "text", "text": text}]
        if image:
            data, media = image
            content.append({"type": "image", "source": {"type": "base64", "media_type": media,
                                                        "data": base64.b64encode(data).decode("ascii")}})
        try:
            if turn.stopping:
                return {"status": "stopped", "text": None, "error": "", "kind": ""}
            await self._send({"type": "user", "message": {"role": "user", "content": content},
                              "parent_tool_use_id": None, "session_id": self.conversation_id or ""})
            return await self.result
        except (ConnectionError, OSError) as error:
            return {"status": "failed", "text": None, "error": self._last_error() or str(error), "kind": "crashed"}
        finally:
            self.turn = None
            self.result = None
            self._schedule_idle()

    async def interrupt(self):
        turn, result = self.turn, self.result
        if turn is None or result is None:
            return
        turn.stopping = True
        turn.deny_all()
        with contextlib.suppress(ConnectionError, OSError):
            await self._send({"type": "control_request", "request_id": f"interrupt-{next(self.requests)}",
                              "request": {"subtype": "interrupt"}})
        try:
            await asyncio.wait_for(asyncio.shield(result), STOP_GRACE)
        except asyncio.TimeoutError:
            # The session is on disk; the next question resumes it.
            await self.close()
            self._settle("stopped")

    async def close(self):
        process, self.process = self.process, None
        await stop_process(process)

    def _last_error(self):
        return self.stderr[-1] if self.stderr else ""

    def _cancel_idle(self):
        if self.idle is not None:
            self.idle.cancel()
            self.idle = None

    def _schedule_idle(self):
        self._cancel_idle()
        if self.process is not None:
            self.idle = asyncio.get_running_loop().call_later(IDLE_SECONDS, lambda: self._spawn(self.close()))

    # ---- the stream --------------------------------------------------------

    async def _read_errors(self, process):
        async for line in iter_lines(process.stderr, 64 * 1024):
            text = line.decode("utf-8", "replace").strip()
            if text:
                self.stderr.append(text[:500])

    async def _read(self, process, errors):
        try:
            async for line in iter_lines(process.stdout):
                message = parse_json(line)
                if message is not None:
                    if self.process is process:
                        self.received += 1
                    try:
                        self._handle(message)
                    except Exception:  # one malformed event must not end the session
                        LOG.exception("unexpected Claude Code event")
        finally:
            await process.wait()
            with contextlib.suppress(asyncio.TimeoutError):
                await asyncio.wait_for(asyncio.shield(errors), 1)
            # close() detaches the process first; only an unexpected exit
            # ends the turn here.
            if self.process is process:
                self.process = None
                self._exited(process)

    def _exited(self, process):
        self.resume_failed = self.resumed and self.received == 0 and process.returncode != 0
        turn = self.turn
        if turn is not None and turn.stopping:
            self._settle("stopped")
        else:
            detail = self._last_error() or f"Claude Code exited with status {process.returncode}."
            self._settle("failed", error=detail, kind=classify(detail) or "crashed")

    def _handle(self, message):
        kind = message.get("type")
        turn = self.turn
        if kind in ("system", "result"):
            self._record(message.get("session_id"))
        if kind == "control_request":
            request = message.get("request") or {}
            if request.get("subtype") == "can_use_tool":
                self._spawn(self._permission(message.get("request_id"), request))
            else:
                self._spawn(self._send_quietly({"type": "control_response", "response": {
                    "subtype": "error", "request_id": message.get("request_id"),
                    "error": "Not supported by the NerdOS Assistant"}}))
            return
        if kind == "control_cancel_request":
            if turn is not None:
                turn.cancel(message.get("request_id"))
            return
        if turn is None or message.get("parent_tool_use_id"):
            return
        if kind == "stream_event":
            event = message.get("event") or {}
            name = event.get("type")
            if name == "message_start":
                turn.reset_text()
                turn.set_step("Thinking")
            elif name == "content_block_delta":
                delta = event.get("delta") or {}
                if delta.get("type") == "text_delta":
                    turn.delta(delta.get("text", ""))
            elif name == "content_block_start":
                block = event.get("content_block") or {}
                if block.get("type") == "tool_use":
                    turn.set_step(steps.claude_tool(block.get("name", ""), {}))
        elif kind == "assistant":
            for block in (message.get("message") or {}).get("content") or []:
                if isinstance(block, dict) and block.get("type") == "tool_use":
                    name, tool_input = block.get("name", ""), block.get("input") or {}
                    turn.set_step(steps.claude_tool(name, tool_input))
                    # Best effort for edits the person's own rules allow without a prompt.
                    path = tool_input.get(policy.EDIT_TOOLS.get(name, "")) if isinstance(tool_input, dict) else None
                    if isinstance(path, str) and path and not policy.vendor(policy.expand(path, self.home)):
                        turn.snapshots.take(path)
        elif kind == "result":
            if turn.stopping:
                self._settle("stopped", text=turn.text)
                return
            text = message.get("result")
            if message.get("is_error") or message.get("subtype") not in (None, "success"):
                errors = message.get("errors")
                detail = text if isinstance(text, str) and text else \
                    "; ".join(str(item) for item in errors) if isinstance(errors, list) and errors else \
                    "Claude Code could not finish (" + str(message.get("subtype") or "error") + ")."
                self._settle("failed", error=detail, kind=classify(detail))
            else:
                self._settle("completed", text=text if isinstance(text, str) and text.strip() else turn.text)

    async def _send_quietly(self, message):
        with contextlib.suppress(ConnectionError, OSError):
            await self._send(message)

    async def _permission(self, request_id, request):
        turn = self.turn
        tool, tool_input = request.get("tool_name", ""), request.get("input")
        tool_input = tool_input if isinstance(tool_input, dict) else {}
        if turn is None:
            answer, note = "deny", "No question is in progress."
        else:
            decision = policy.decide_tool(tool, tool_input, self.home, self.status_path)
            answer, note = await turn.authorize(decision, cancel_key=request_id)
            if answer == "cancelled":
                return
        response = {"behavior": "allow", "updatedInput": tool_input} if answer in ("allow", "always") \
            else {"behavior": "deny", "message": note}
        await self._send_quietly({"type": "control_response", "response": {
            "subtype": "success", "request_id": request_id, "response": response}})


def media_type(path):
    extension = os.path.splitext(str(path))[1].lower()
    return "image/jpeg" if extension in (".jpg", ".jpeg") else "image/png"
