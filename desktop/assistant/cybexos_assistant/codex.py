"""Codex through `codex app-server`: threads, turns and approval requests.

The thread runs with a read-only sandbox and on-request approvals, so every
write and every escalation becomes a server request that the policy answers
or turns into a card. The app-server's JSON-RPC omits the "jsonrpc" member.
"""

from __future__ import annotations

import asyncio
import collections
import contextlib
import itertools
import json
import shlex

from . import policy, steps
from .protocol import LOG, encode, iter_lines, parse_json, stop_process
from .turn import classify


IDLE_SECONDS = 15 * 60
STOP_GRACE = 5.0
REQUEST_TIMEOUT = 60.0
# Starting or resuming a thread also starts the person's MCP servers.
THREAD_TIMEOUT = 180.0


class CodexError(Exception):
    pass


class CodexAgent:
    name = "codex"
    label = "Codex"

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
        self.loaded = None
        self.pending = {}
        self.ids = itertools.count(1)
        self.turn = None
        self.result = None
        self.turn_id = None
        self.items = {}
        self.message_item = None
        self.final_text = None
        self.last_message = None
        self.turn_error = ""
        self.turn_kind = ""
        self.stderr = collections.deque(maxlen=20)
        self.tasks = set()
        self.write_lock = asyncio.Lock()
        self.idle = None

    @property
    def resumable(self):
        return bool(self.conversation_id)

    def handoff(self):
        return [self.executable, "resume", self.conversation_id] if self.conversation_id else None

    def _spawn(self, coroutine):
        task = asyncio.create_task(coroutine)
        self.tasks.add(task)
        task.add_done_callback(self.tasks.discard)
        return task

    def _record(self, identifier):
        if isinstance(identifier, str) and identifier and identifier != self.conversation_id:
            self.conversation_id = identifier
            self.on_conversation(self.name, identifier)

    # ---- transport ---------------------------------------------------------

    async def _send(self, message):
        process = self.process
        if process is None or process.stdin is None or process.returncode is not None:
            raise ConnectionError("Codex is not running")
        async with self.write_lock:
            process.stdin.write(encode(message))
            await process.stdin.drain()

    async def request(self, method, params, timeout=REQUEST_TIMEOUT):
        identifier = next(self.ids)
        future = asyncio.get_running_loop().create_future()
        self.pending[identifier] = future
        try:
            await self._send({"id": identifier, "method": method, "params": params})
            return await asyncio.wait_for(future, timeout)
        except asyncio.TimeoutError:
            raise CodexError(f"Codex did not answer {method}") from None
        finally:
            self.pending.pop(identifier, None)

    async def _reply(self, identifier, result=None, error=None):
        message = {"id": identifier}
        if error is not None:
            message["error"] = {"code": error[0], "message": error[1]}
        else:
            message["result"] = result
        with contextlib.suppress(ConnectionError, OSError):
            await self._send(message)

    async def _start(self):
        if self.process is not None and self.process.returncode is None:
            return
        self.process = await asyncio.create_subprocess_exec(
            self.executable, "app-server", cwd=self.home, env=self.env, stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE, start_new_session=True)
        self.loaded = None
        self.stderr.clear()
        process = self.process
        errors = self._spawn(self._read_errors(process))
        self._spawn(self._read(process, errors))
        await self.request("initialize", {
            "clientInfo": {"name": "cybexos_assistant", "title": "Cybex OS Assistant", "version": "1"},
            "capabilities": {"experimentalApi": False, "requestAttestation": False}})
        await self._send({"method": "initialized"})

    async def _thread(self, model):
        if self.conversation_id and self.loaded == self.conversation_id:
            return
        params = {"cwd": self.home, "approvalPolicy": "on-request", "sandbox": "read-only",
                  "developerInstructions": self.instructions}
        if model:
            params["model"] = model
        if self.conversation_id:
            try:
                result = await self.request("thread/resume", dict(params, threadId=self.conversation_id),
                                            timeout=THREAD_TIMEOUT)
                self.loaded = ((result or {}).get("thread") or {}).get("id") or self.conversation_id
                self._record(self.loaded)
                return
            except CodexError as error:
                # A thread removed from Codex's history starts over.
                LOG.warning("could not resume Codex thread: %s", error)
        result = await self.request("thread/start", params, timeout=THREAD_TIMEOUT)
        identifier = ((result or {}).get("thread") or {}).get("id")
        if not isinstance(identifier, str) or not identifier:
            raise CodexError("Codex did not start a thread")
        self.conversation_id = None
        self._record(identifier)
        self.loaded = identifier

    async def run(self, turn, text, image=None, model=None):
        self._cancel_idle()
        loop = asyncio.get_running_loop()
        try:
            await self._start()
            await self._thread(model or None)
            self.turn, self.result = turn, loop.create_future()
            self.turn_id, self.items, self.message_item = None, {}, None
            self.final_text = self.last_message = None
            self.turn_error, self.turn_kind = "", ""
            items = [{"type": "text", "text": text, "text_elements": []}]
            if image:
                items.append({"type": "localImage", "path": image})
            params = {"threadId": self.conversation_id, "input": items}
            if model:
                params["model"] = model
            if turn.stopping:
                return {"status": "stopped", "text": None, "error": "", "kind": ""}
            started = await self.request("turn/start", params)
            if self.turn_id is None:
                self.turn_id = ((started or {}).get("turn") or {}).get("id")
            return await self.result
        except FileNotFoundError:
            return {"status": "failed", "text": None, "error": "Codex is not installed.", "kind": "missing"}
        except (CodexError, ConnectionError, OSError) as error:
            detail = str(error) if isinstance(error, CodexError) else (self._last_error() or str(error))
            return {"status": "failed", "text": None, "error": detail, "kind": classify(detail) or "crashed"}
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
        if self.turn_id:
            with contextlib.suppress(CodexError, ConnectionError, OSError):
                await self.request("turn/interrupt", {"threadId": self.conversation_id, "turnId": self.turn_id},
                                   timeout=STOP_GRACE)
        try:
            await asyncio.wait_for(asyncio.shield(result), STOP_GRACE)
        except asyncio.TimeoutError:
            await self.close()
            self._settle("stopped")

    async def close(self):
        process, self.process = self.process, None
        self.loaded = None
        await stop_process(process)

    def _settle(self, status, text=None, error="", kind=""):
        if self.result is not None and not self.result.done():
            self.result.set_result({"status": status, "text": text, "error": error, "kind": kind})

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
                if message is None:
                    continue
                try:
                    self._dispatch(message)
                except Exception:  # one malformed event must not end the session
                    LOG.exception("unexpected Codex message")
        finally:
            await process.wait()
            with contextlib.suppress(asyncio.TimeoutError):
                await asyncio.wait_for(asyncio.shield(errors), 1)
            if self.process is process:
                self.process = None
                self.loaded = None
                self._exited(process)

    def _exited(self, process):
        detail = self._last_error() or f"Codex exited with status {process.returncode}."
        for future in list(self.pending.values()):
            if not future.done():
                future.set_exception(CodexError(detail))
        turn = self.turn
        if turn is not None and turn.stopping:
            self._settle("stopped")
        else:
            self._settle("failed", error=detail, kind=classify(detail) or "crashed")

    def _dispatch(self, message):
        method = message.get("method")
        if method is None:
            future = self.pending.get(message.get("id"))
            if future is not None and not future.done():
                error = message.get("error")
                if error:
                    future.set_exception(CodexError(str((error or {}).get("message") or error)))
                else:
                    future.set_result(message.get("result"))
            return
        params = message.get("params") if isinstance(message.get("params"), dict) else {}
        if "id" in message:
            self._spawn(self._server_request(message["id"], method, params))
        else:
            self._notification(method, params)

    def _notification(self, method, params):
        turn = self.turn
        if turn is None:
            return
        if self.conversation_id and params.get("threadId") not in (None, self.conversation_id):
            return
        if method == "turn/started":
            self.turn_id = (params.get("turn") or {}).get("id") or self.turn_id
        elif method == "item/started":
            item = params.get("item") or {}
            kind = item.get("type")
            if kind == "agentMessage":
                self.message_item = item.get("id")
                turn.reset_text()
                turn.set_step("Thinking")
                return
            if kind == "fileChange":
                self.items[item.get("id")] = item
            turn.set_step(steps.codex_item(item))
        elif method == "item/agentMessage/delta":
            if self.message_item in (None, params.get("itemId")):
                turn.delta(params.get("delta", ""))
        elif method == "item/completed":
            item = params.get("item") or {}
            if item.get("type") == "agentMessage" and isinstance(item.get("text"), str):
                self.last_message = item["text"]
                if item.get("phase") == "final_answer":
                    self.final_text = item["text"]
            elif item.get("type") == "fileChange":
                self.items[item.get("id")] = item
        elif method == "error":
            error = params.get("error") or {}
            if not params.get("willRetry"):
                self.turn_error = str(error.get("message") or "")
                if error.get("codexErrorInfo") == "unauthorized":
                    self.turn_kind = "auth"
        elif method == "turn/completed":
            completed = params.get("turn") or {}
            if self.turn_id and completed.get("id") not in (None, self.turn_id):
                return
            status = completed.get("status")
            text = self.final_text if self.final_text is not None else self.last_message
            if text is None or not text.strip():
                text = turn.text
            if status == "interrupted" or turn.stopping:
                self._settle("stopped", text=text)
            elif status == "failed":
                error = completed.get("error") or {}
                detail = str(error.get("message") or self.turn_error or "Codex could not finish.")
                kind = "auth" if error.get("codexErrorInfo") == "unauthorized" else self.turn_kind
                self._settle("failed", text=text, error=detail, kind=kind or classify(detail))
            else:
                self._settle("completed", text=text)

    # ---- approvals ---------------------------------------------------------

    async def _server_request(self, identifier, method, params):
        turn = self.turn
        try:
            if method == "item/commandExecution/requestApproval":
                answer = await self._command(turn, params.get("command") or "", params.get("reason"))
                decision = {"allow": "accept", "always": "acceptForSession"}.get(answer, "decline")
                await self._reply(identifier, {"decision": decision})
            elif method == "item/fileChange/requestApproval":
                item = self.items.get(params.get("itemId")) or {}
                changes = [change for change in item.get("changes") or [] if isinstance(change, dict)]
                paths = [change.get("path") for change in changes]
                if params.get("grantRoot"):
                    paths.append(params["grantRoot"])
                diff = "\n".join(str(change.get("diff") or "") for change in changes)
                answer = await self._edit(turn, paths, diff, params.get("reason"))
                decision = {"allow": "accept", "always": "acceptForSession"}.get(answer, "decline")
                await self._reply(identifier, {"decision": decision})
            elif method == "item/permissions/requestApproval":
                requested = params.get("permissions") or {}
                answer = await self._permissions(turn, requested, params.get("reason"))
                granted = {key: value for key, value in requested.items()
                           if key in ("network", "fileSystem") and value} if answer in ("allow", "always") else {}
                await self._reply(identifier, {"permissions": granted,
                                               "scope": "session" if answer == "always" else "turn"})
            elif method == "execCommandApproval":
                command = params.get("command")
                command = shlex.join(command) if isinstance(command, list) else str(command or "")
                answer = await self._command(turn, command, params.get("reason"))
                await self._reply(identifier, {"decision": review_decision(answer)})
            elif method == "applyPatchApproval":
                changes = params.get("fileChanges") or {}
                paths = list(changes) + ([params["grantRoot"]] if params.get("grantRoot") else [])
                diff = "\n".join(str((change or {}).get("unified_diff") or (change or {}).get("content") or "")
                                 for change in changes.values())
                answer = await self._edit(turn, paths, diff, params.get("reason"))
                await self._reply(identifier, {"decision": review_decision(answer)})
            elif method == "item/tool/requestUserInput":
                await self._reply(identifier, {"answers": {}})
            elif method == "mcpServer/elicitation/request":
                await self._reply(identifier, {"action": "decline", "content": None, "_meta": None})
            elif method == "item/tool/call":
                await self._reply(identifier, {"contentItems": [], "success": False})
            else:
                await self._reply(identifier, error=(-32601, f"{method} is not supported by the Cybex OS Assistant"))
        except Exception as error:  # an answer is always owed, or Codex waits forever
            LOG.exception("Codex request %s failed", method)
            await self._reply(identifier, error=(-32603, str(error) or "internal error"))

    async def _authorize(self, turn, decision, reason=None):
        if turn is None:
            return "deny"
        if decision.action == "ask" and reason and decision.card is not None and not decision.card.get("detail"):
            decision.card["detail"] = str(reason)[:400]
        answer, _ = await turn.authorize(decision)
        return answer

    async def _command(self, turn, command, reason=None):
        return await self._authorize(turn, policy.decide_command(command, self.home, self.status_path), reason)

    async def _edit(self, turn, paths, diff, reason=None):
        return await self._authorize(turn, policy.decide_edit(paths, self.home, diff, reason or ""))

    async def _permissions(self, turn, requested, reason=None):
        detail = []
        if reason:
            detail.append(str(reason))
        network = requested.get("network") or {}
        if network.get("enabled"):
            detail.append("Network access")
        files = requested.get("fileSystem") or {}
        for key, label in (("write", "Write to"), ("read", "Read")):
            for path in files.get(key) or []:
                detail.append(f"{label} {policy.display(policy.expand(path, self.home), self.home)}")
        card = {"kind": "other", "title": "Allow more access", "detail": "\n".join(detail)[:1500]}
        key = ("permissions", json.dumps(requested, sort_keys=True))
        return await self._authorize(turn, policy.ask(card, key=key))


def review_decision(answer):
    if answer == "allow":
        return "approved"
    if answer == "always":
        return "approved_for_session"
    return {"denied": {"rejection": "The person declined this action."}}
