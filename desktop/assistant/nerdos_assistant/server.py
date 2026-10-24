"""The socket, the conversation and the current turn.

The service owns the agent processes so a Quickshell restart, including one
the assistant's own change caused, never ends a turn. Clients reconcile with
`hello`; nothing is replayed after a reconnect.
"""

from __future__ import annotations

import asyncio
import contextlib
import os
from pathlib import Path
import re
import secrets
import shutil
import signal
import socket
import tempfile
import time

from . import auth, policy, prompt, speech
from .claude import ClaudeAgent, media_type
from .codex import CodexAgent
from .protocol import (
    BUSY, LOG, MAX_CLIENT_BACKLOG, MAX_LINE, MAX_PROMPT, MAX_SCREENSHOT, NOT_FOUND, PROTOCOL,
    UNAVAILABLE, RpcFault, default_state_dir, encode, error_frame, iter_lines, notification,
    now_ms, parse_json, result_frame, screenshot_dir,
)
from .turn import FINAL, Turn


AGENTS = {"claude": ClaudeAgent, "codex": CodexAgent}
LABELS = {"claude": "Claude Code", "codex": "Codex"}
DISCOVERY_SECONDS = 30.0
STOP_WAIT = 8.0
CONVERSATION_ID = re.compile(r"^[A-Za-z0-9._:-]{1,200}$")
MODEL = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:/\[\]-]{0,79}$")
LANGUAGE = re.compile(r"^[A-Za-z]{2,3}(?:[-_][A-Za-z0-9]{2,8})?$")
RESTARTED = "The assistant service restarted."


class Client:
    """One connection; frames are queued so a slow reader never blocks the others."""

    def __init__(self, writer):
        self.writer = writer
        self.queue = asyncio.Queue()
        self.closed = False
        self.task = asyncio.create_task(self._write())

    def send(self, frame):
        if self.closed:
            return
        if self.queue.qsize() >= MAX_CLIENT_BACKLOG:
            LOG.warning("disconnecting a client that stopped reading")
            self.close()
            return
        self.queue.put_nowait(frame)

    async def _write(self):
        try:
            while True:
                frame = await self.queue.get()
                self.writer.write(frame)
                await self.writer.drain()
        except (ConnectionError, OSError):
            self.close()

    def close(self):
        if self.closed:
            return
        self.closed = True
        self.task.cancel()
        with contextlib.suppress(Exception):
            self.writer.close()


class Server:
    def __init__(self, socket_path, state_dir=None, home=None, env=None):
        self.env = dict(os.environ if env is None else env)
        self.home = Path(home or self.env.get("HOME") or Path.home())
        self.socket_path = Path(socket_path)
        self.state_path = Path(state_dir or default_state_dir(self.home)) / "state.json"
        self.status_path = self.env.get("NERDOS_ASSISTANT_STATUS") or "/var/lib/nerdos/status.json"
        self.shots = screenshot_dir(self.env)
        self.instructions = prompt.build()
        self.clients = set()
        self.tasks = set()
        self.adapters = {}
        self.conversation = {"agent": None, "claude": None, "codex": None}
        self.memory = set()
        self.turn = None
        self.task = None
        self.discovered = (0.0, {})
        self.authentication = {}
        self.auth_lock = asyncio.Lock()
        self.speaker = speech.Speaker(speech.default_socket(self.env), self.publish)
        self.listener = None
        self.closing = False
        self.methods = {
            "hello": self.hello, "turn.start": self.turn_start, "turn.stop": self.turn_stop,
            "approval.respond": self.approval_respond, "turn.undo": self.turn_undo,
            "conversation.reset": self.conversation_reset, "conversation.handoff": self.conversation_handoff,
            "speech.say": self.speech_say, "speech.stop": self.speech_stop,
            "auth.status": self.auth_status, "auth.login": self.auth_login,
        }
        self._load()

    # ---- agents ------------------------------------------------------------

    def agent_env(self):
        env = dict(self.env)
        local = str(self.home / ".local" / "bin")
        if local not in env.get("PATH", "").split(os.pathsep):
            env["PATH"] = os.pathsep.join(filter(None, [env.get("PATH", ""), local]))
        return env

    def agents(self):
        stamp, found = self.discovered
        if time.monotonic() - stamp < DISCOVERY_SECONDS and found:
            return found
        found = {}
        search = self.agent_env()["PATH"]
        for name in AGENTS:
            override = self.env.get("NERDOS_ASSISTANT_" + name.upper())
            if override:
                found[name] = override if os.path.isfile(override) and os.access(override, os.X_OK) else None
            else:
                found[name] = shutil.which(name, path=search)
        self.discovered = (time.monotonic(), found)
        return found

    def preferred(self):
        config = Path(self.env.get("XDG_CONFIG_HOME") or self.home / ".config")
        try:
            value = (config / "nerdos" / "defaults" / "agent").read_text(encoding="utf-8").strip()
        except (OSError, UnicodeDecodeError):
            return None
        return value if value in AGENTS else None

    def resolve(self, requested, statuses=None):
        if requested in AGENTS:
            return requested
        found = self.agents()
        preferred = self.preferred()
        order = ([preferred] if preferred else []) + list(AGENTS)
        if statuses:
            for name in order:
                if statuses.get(name, {}).get('auth') == 'ready':
                    return name
        for name in order:
            if found.get(name):
                return name
        return preferred or "claude"

    def adapter(self, name, executable):
        adapter = self.adapters.get(name)
        if adapter is not None and adapter.executable != executable:
            self._spawn(adapter.close())
            adapter = None
        if adapter is None:
            adapter = AGENTS[name](executable, self.home, self.instructions, status_path=self.status_path,
                                   conversation_id=self.conversation.get(name),
                                   on_conversation=self._conversation_id, env=self.agent_env())
            self.adapters[name] = adapter
        return adapter

    def _conversation_id(self, agent, identifier):
        self.conversation[agent] = identifier or None
        self.conversation["agent"] = agent if identifier else None
        self.save()
        if self.turn is not None:
            self._turn_event("updated", self.turn)

    async def _reset_conversation(self):
        adapters, self.adapters = list(self.adapters.values()), {}
        for adapter in adapters:
            await adapter.close()
        self.memory = set()
        self.conversation = {"agent": None, "claude": None, "codex": None}
        self.save()

    # ---- notifications -----------------------------------------------------

    def _spawn(self, coroutine):
        task = asyncio.create_task(coroutine)
        self.tasks.add(task)
        task.add_done_callback(self.tasks.discard)
        return task

    def publish(self, method, params):
        frame = encode(notification(method, params))
        for client in list(self.clients):
            client.send(frame)

    def resumable(self, turn):
        return self.conversation.get("agent") == turn.agent and bool(self.conversation.get(turn.agent))

    def snapshot(self, turn):
        return turn.snapshot(self.resumable(turn)) if turn is not None else None

    def _turn_event(self, kind, turn, text=None):
        if turn is not self.turn:
            return
        if kind == "delta":
            self.publish("turn.delta", {"id": turn.id, "text": text})
        else:
            self.publish("turn.updated", {"turn": self.snapshot(turn)})

    # ---- methods -----------------------------------------------------------

    async def hello(self, params):
        agent = self.conversation.get("agent")
        return {
            "protocol": PROTOCOL,
            "agents": await self.agent_status(),
            "turn": self.snapshot(self.turn),
            "conversation": {"agent": agent, "resumable": bool(self.conversation.get(agent))} if agent else None,
            "speech": {"available": self.speaker.available},
        }

    async def agent_status(self, refresh=False):
        async with self.auth_lock:
            if refresh:
                self.discovered = (0.0, {})
            found = self.agents()
            async def inspect(name):
                executable = found.get(name)
                if not executable:
                    self.authentication.pop(name, None)
                    return name, {"available": False, "label": LABELS[name], "auth": "missing"}
                stamp, previous_executable, state = self.authentication.get(name, (0.0, None, "unknown"))
                if refresh or previous_executable != executable or time.monotonic() - stamp >= DISCOVERY_SECONDS:
                    state = await auth.status(name, executable, self.home, self.agent_env())
                    self.authentication[name] = (time.monotonic(), executable, state)
                return name, {"available": True, "label": LABELS[name], "auth": state}
            return dict(await asyncio.gather(*(inspect(name) for name in AGENTS)))

    async def auth_status(self, params):
        agents = await self.agent_status(refresh=True)
        self.publish("agents.updated", {"agents": agents})
        return {"agents": agents}

    async def auth_login(self, params):
        name = params.get('agent')
        if name not in AGENTS:
            raise RpcFault(-32602, 'Choose Claude Code or Codex to sign in.')
        if self.busy():
            raise RpcFault(BUSY, 'Wait for the current question before signing in.')
        self.discovered = (0.0, {})
        executable = self.agents().get(name)
        if not executable:
            raise RpcFault(UNAVAILABLE, f'{LABELS[name]} is not installed. Enable it in Software first.')
        adapter = self.adapters.pop(name, None)
        if adapter is not None:
            await adapter.close()
        self.authentication.pop(name, None)
        # A terminal runs the agent's own browser authentication. Credentials
        # never pass through the assistant, QML or the JSON-RPC connection.
        return {"argv": [executable, *auth.LOGIN_ARGS[name]], "cwd": str(self.home)}

    def busy(self):
        return self.task is not None and not self.task.done()

    def screenshot(self, value):
        if value in (None, ""):
            return None
        if not isinstance(value, str):
            raise RpcFault(-32602, "Invalid screenshot")
        try:
            real = Path(value).resolve(strict=True)
            root = self.shots.resolve(strict=True)
        except OSError:
            raise RpcFault(-32602, "The screenshot is no longer available.") from None
        if not policy.under(str(real), str(root)) or real == root or not real.is_file() \
                or real.suffix.lower() not in (".png", ".jpg", ".jpeg") or real.stat().st_size > MAX_SCREENSHOT:
            raise RpcFault(-32602, "The screenshot must be a PNG or JPEG taken by the assistant.")
        return real

    async def turn_start(self, params):
        if self.busy():
            raise RpcFault(BUSY, "The assistant is still working on the previous question.")
        text = params.get("text")
        if not isinstance(text, str) or not text.strip():
            raise RpcFault(-32602, "Ask a question first.")
        text = text.strip()
        if len(text) > MAX_PROMPT:
            raise RpcFault(-32602, "That question is too long.")
        requested = params.get("agent") or "auto"
        if requested not in ("auto", *AGENTS):
            raise RpcFault(-32602, "Unknown agent")
        model = params.get("model")
        if model in (None, "", "default"):
            model = None
        elif not isinstance(model, str) or not MODEL.fullmatch(model):
            raise RpcFault(-32602, "Invalid model")
        context = params.get("context") if isinstance(params.get("context"), dict) else {}
        shot = self.screenshot(params.get("screenshot"))
        statuses = await self.agent_status()
        # Auth probing yields to other clients; a second start may have won.
        if self.busy():
            raise RpcFault(BUSY, "The assistant is still working on the previous question.")
        agent = self.resolve(requested, statuses)
        if statuses[agent]['available'] and statuses[agent]['auth'] != 'ready':
            raise RpcFault(-32004, f'Sign in to {LABELS[agent]} before asking the assistant. Your question has been kept.')
        if self.conversation.get("agent") not in (None, agent):
            await self._reset_conversation()
        turn = Turn("t-" + secrets.token_hex(8), agent, text, self.home, self.memory, self._turn_event,
                    screenshot=shot is not None)
        turn.snapshots.begin()
        plugins = policy.plugin_manifests(self.home)
        status = policy.read_json(self.status_path)
        self.turn = turn
        self.task = asyncio.create_task(self._run(turn, text, shot, model, context, plugins, status, requested))
        self.save()
        self._turn_event("updated", turn)
        return {"turn": self.snapshot(turn)}

    async def _run(self, turn, text, shot, model, context, plugins, status, requested):
        try:
            executable = self.agents().get(turn.agent)
            if not executable:
                message = (f"{LABELS[turn.agent]} is not installed." if requested != "auto"
                           else "Neither Claude Code nor Codex is installed.")
                turn.finish("failed", error=message, kind="missing")
                return
            image = None
            if shot is not None:
                image = (shot.read_bytes(), media_type(shot)) if turn.agent == "claude" else str(shot)
            adapter = self.adapter(turn.agent, executable)
            outcome = await adapter.run(turn, prompt.turn_text(text, context, shot is not None), image, model)
            turn.finish(outcome.get("status", "failed"), outcome.get("text"), outcome.get("error", ""),
                        outcome.get("kind", ""))
            if turn.error_kind == 'auth':
                self.authentication[turn.agent] = (time.monotonic(), executable, 'required')
                self.publish('agents.updated', {'agents': await self.agent_status()})
        except FileNotFoundError:
            turn.finish("failed", error=f"{LABELS[turn.agent]} is not installed.", kind="missing")
        except asyncio.CancelledError:
            if self.closing:
                turn.finish("failed", error=RESTARTED, kind="crashed")
            else:
                turn.finish("stopped")
            raise
        except Exception as error:
            LOG.exception("turn failed")
            turn.finish("failed", error=str(error) or "The assistant could not finish.", kind="crashed")
        finally:
            if shot is not None:
                with contextlib.suppress(OSError):
                    shot.unlink()
            if not turn.finished:
                turn.finish("failed", error="The assistant could not finish.", kind="crashed")
            turn.undo = turn.snapshots.finish()
            turn.plugins = policy.new_plugins(plugins, policy.plugin_manifests(self.home))
            turn.staged = policy.staged_transaction(status, policy.read_json(self.status_path))
            self.save()
            self._turn_event("updated", turn)

    async def turn_stop(self, params):
        turn, task = self.turn, self.task
        if task is None or task.done():
            return {"stopped": False}
        turn.stopping = True
        turn.deny_all()
        adapter = self.adapters.get(turn.agent)
        if adapter is not None:
            await adapter.interrupt()
        try:
            await asyncio.wait_for(asyncio.shield(task), STOP_WAIT)
        except asyncio.TimeoutError:
            task.cancel()
            with contextlib.suppress(asyncio.CancelledError, Exception):
                await task
        return {"stopped": True}

    async def approval_respond(self, params):
        decision = params.get("decision")
        if decision not in ("allow", "always", "deny"):
            raise RpcFault(-32602, "Invalid decision")
        if self.turn is None or not self.turn.respond(params.get("id"), decision):
            raise RpcFault(NOT_FOUND, "That approval is no longer pending.")
        return {"ok": True}

    async def turn_undo(self, params):
        turn = self.turn
        if turn is None or turn.id != params.get("id") or not turn.finished or not turn.undo:
            raise RpcFault(NOT_FOUND, "There is nothing to undo.")
        restored, skipped = turn.snapshots.undo()
        turn.undo = []
        self.save()
        self._turn_event("updated", turn)
        return {"restored": restored, "skipped": skipped}

    async def conversation_reset(self, params):
        if self.busy():
            raise RpcFault(BUSY, "The assistant is still working on the previous question.")
        await self._reset_conversation()
        if self.turn is not None:
            self._turn_event("updated", self.turn)
        return {"ok": True}

    async def conversation_handoff(self, params):
        if self.busy():
            raise RpcFault(BUSY, "Wait until the assistant has answered, then continue in a terminal.")
        agent = self.conversation.get("agent")
        identifier = self.conversation.get(agent) if agent else None
        if not identifier:
            raise RpcFault(UNAVAILABLE, "There is no conversation to continue.")
        executable = self.agents().get(agent) or agent
        argv = [executable, "--resume", identifier] if agent == "claude" else [executable, "resume", identifier]
        # The terminal continues the session from disk; a later question
        # here resumes it again instead of forking the history.
        adapter = self.adapters.pop(agent, None)
        if adapter is not None:
            await adapter.close()
        return {"argv": argv, "cwd": str(self.home)}

    async def speech_say(self, params):
        text = params.get("text")
        if not isinstance(text, str) or len(text) > 64 * 1024:
            raise RpcFault(-32602, "Invalid text")
        language = params.get("language")
        if language is not None and (not isinstance(language, str) or not LANGUAGE.fullmatch(language)):
            language = None
        return await self.speaker.say(text, language)

    async def speech_stop(self, params):
        await self.speaker.stop()
        return {"ok": True}

    # ---- persistence -------------------------------------------------------

    def _load(self):
        data = policy.read_json(self.state_path)
        conversation = data.get("conversation") if isinstance(data.get("conversation"), dict) else {}
        for name in AGENTS:
            value = conversation.get(name)
            if isinstance(value, str) and CONVERSATION_ID.fullmatch(value):
                self.conversation[name] = value
        if conversation.get("agent") in AGENTS and self.conversation.get(conversation["agent"]):
            self.conversation["agent"] = conversation["agent"]
        stored = data.get("turn")
        if isinstance(stored, dict) and stored.get("agent") in AGENTS and isinstance(stored.get("id"), str):
            turn = Turn(stored["id"], stored["agent"], str(stored.get("prompt") or ""), self.home,
                        self.memory, self._turn_event, screenshot=bool(stored.get("screenshot")))
            turn.text = str(stored.get("text") or "")
            turn.started_at = int(stored.get("startedAt") or 0)
            if stored.get("status") in FINAL:
                turn.status = stored["status"]
                turn.error = str(stored.get("error") or "")
                turn.error_kind = str(stored.get("errorKind") or "")
                turn.finished_at = int(stored.get("finishedAt") or 0)
            else:
                turn.status, turn.error, turn.error_kind, turn.finished_at = "failed", RESTARTED, "crashed", now_ms()
            turn.step = ""
            plugins = stored.get("plugins")
            turn.plugins = [entry for entry in plugins if isinstance(entry, dict)
                            and isinstance(entry.get("id"), str) and policy.PLUGIN_ID.fullmatch(entry["id"])] \
                if isinstance(plugins, list) else []
            turn.staged = stored.get("staged") if isinstance(stored.get("staged"), str) else ""
            # Pre-images lived in the previous process; Undo cannot survive it.
            turn.undo = []
            self.turn = turn

    def save(self):
        turn = self.snapshot(self.turn)
        if turn is not None:
            turn["approvals"] = []
        document = {"version": 1, "conversation": self.conversation, "turn": turn}
        try:
            self.state_path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            handle, temporary = tempfile.mkstemp(prefix=".state-", dir=self.state_path.parent)
            with os.fdopen(handle, "wb") as stream:
                os.fchmod(stream.fileno(), 0o600)
                stream.write(encode(document))
            os.replace(temporary, self.state_path)
        except OSError as error:
            LOG.warning("could not save assistant state: %s", error)

    # ---- socket ------------------------------------------------------------

    async def _connection(self, reader, writer):
        client = Client(writer)
        self.clients.add(client)
        try:
            async for line in iter_lines(reader, MAX_LINE):
                message = parse_json(line)
                if message is None:
                    client.send(encode(error_frame(None, -32700, "Parse error")))
                    continue
                self._spawn(self._request(client, message))
        except (ConnectionError, OSError):
            pass
        finally:
            self.clients.discard(client)
            client.close()

    async def _request(self, client, message):
        identifier = message.get("id")
        method = message.get("method")
        params = message.get("params") if message.get("params") is not None else {}
        try:
            if not isinstance(method, str) or not isinstance(params, dict):
                raise RpcFault(-32600, "Invalid request")
            handler = self.methods.get(method)
            if handler is None:
                raise RpcFault(-32601, f"Unknown method {method}")
            result = await handler(params)
        except RpcFault as fault:
            if identifier is not None:
                client.send(encode(error_frame(identifier, fault.code, fault.message)))
        except Exception:
            LOG.exception("%s failed", method)
            if identifier is not None:
                client.send(encode(error_frame(identifier, -32603, "Internal error")))
        else:
            if identifier is not None:
                client.send(encode(result_frame(identifier, result)))

    def _prepare(self):
        for directory in (self.socket_path.parent, self.shots):
            directory.mkdir(parents=True, exist_ok=True, mode=0o700)
            with contextlib.suppress(OSError):
                os.chmod(directory, 0o700)
        # A screenshot belongs to one question; none survives the service.
        for leftover in self.shots.iterdir():
            if leftover.is_file() or leftover.is_symlink():
                with contextlib.suppress(OSError):
                    leftover.unlink()
        if self.socket_path.exists() or self.socket_path.is_symlink():
            probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            try:
                probe.settimeout(1)
                probe.connect(str(self.socket_path))
            except OSError:
                self.socket_path.unlink()
            else:
                raise SystemExit(f"nerdos-assistant: already running at {self.socket_path}")
            finally:
                probe.close()

    async def start(self):
        self._prepare()
        self.listener = await asyncio.start_unix_server(self._connection, path=str(self.socket_path))
        os.chmod(self.socket_path, 0o600)

    async def shutdown(self):
        self.closing = True
        if self.listener is not None:
            self.listener.close()
        for client in list(self.clients):
            client.close()
        await self.speaker.stop()
        if self.busy():
            self.task.cancel()
            with contextlib.suppress(asyncio.CancelledError, Exception):
                await self.task
        for adapter in list(self.adapters.values()):
            await adapter.close()
        self.save()
        with contextlib.suppress(OSError):
            self.socket_path.unlink()
        for task in list(self.tasks):
            task.cancel()

    async def serve(self):
        await self.start()
        stop = asyncio.Event()
        loop = asyncio.get_running_loop()
        for number in (signal.SIGTERM, signal.SIGINT):
            loop.add_signal_handler(number, stop.set)
        LOG.info("listening on %s", self.socket_path)
        await stop.wait()
        await self.shutdown()
