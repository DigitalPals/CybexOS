"""The Cybex OS Assistant service against fake agent CLIs and speech-dispatcher.

No model is ever called: `claude` and `codex` are small scripts speaking the
same stream-json control protocol and app-server JSON-RPC as the real CLIs.
"""

import asyncio
import contextlib
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import textwrap
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "desktop" / "assistant"))

from cybexos_assistant import auth, policy, prompt, speech  # noqa: E402
from cybexos_assistant.protocol import encode, iter_lines, parse_json  # noqa: E402
from cybexos_assistant.server import RESTARTED, Server  # noqa: E402


FAKE_CLAUDE = r'''
import json, os, sys, time
from pathlib import Path

signed_out = Path(os.environ['HOME']) / 'signed-out-claude'
if sys.argv[1:] == ['auth', 'status']:
    print('private-account-details', file=sys.stderr)
    if signed_out.exists() and signed_out.read_text() == 'hang':
        time.sleep(60)
    sys.exit(2 if signed_out.exists() and signed_out.read_text() == 'error' else int(signed_out.exists()))
if sys.argv[1:] == ['auth', 'login']:
    signed_out.unlink(missing_ok=True)
    sys.exit(0)

log = Path(os.environ["FAKE_LOG"])
with log.open("a") as stream:
    stream.write(json.dumps({"agent": "claude", "argv": sys.argv[1:]}) + "\n")
args = sys.argv[1:]
session = args[args.index("--resume") + 1] if "--resume" in args else "sess-1"
home = Path(os.environ["HOME"])
if session == "gone":
    sys.stderr.write("No conversation found with session ID: gone\n")
    sys.exit(1)

def emit(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()

def read():
    line = sys.stdin.readline()
    if not line:
        sys.exit(0)
    return json.loads(line)

def ask(request_id, tool, tool_input):
    emit({"type": "control_request", "request_id": request_id,
          "request": {"subtype": "can_use_tool", "tool_name": tool, "input": tool_input, "tool_use_id": "tu"}})
    while True:
        message = read()
        if message.get("type") == "control_response" and message["response"]["request_id"] == request_id:
            return message["response"]["response"]

def say(text):
    emit({"type": "stream_event", "event": {"type": "message_start"}})
    emit({"type": "stream_event", "event": {"type": "content_block_delta",
                                            "delta": {"type": "text_delta", "text": text}}})

def finish(text, error=False):
    emit({"type": "result", "subtype": "success" if not error else "error_during_execution",
          "is_error": error, "result": text, "session_id": session})

emit({"type": "system", "subtype": "init", "session_id": session})
while True:
    message = read()
    if message.get("type") != "user":
        continue
    content = message["message"]["content"]
    text = content[0]["text"]
    if "bash" in text:
        answer = ask("r1", "Bash", {"command": "rm -rf ~/x"})
        say("allowed" if answer["behavior"] == "allow" else "denied")
        finish("")
    elif "always" in text:
        first = ask("r1", "Bash", {"command": "touch ~/y"})
        second = ask("r2", "Bash", {"command": "touch ~/y"})
        finish(first["behavior"] + "/" + second["behavior"])
    elif "edit" in text:
        target = home / ".config/cybexos/shell.json"
        answer = ask("r1", "Edit", {"file_path": str(target), "old_string": "a", "new_string": "b"})
        if answer["behavior"] == "allow":
            target.write_text('{"bar": "transparent"}\n')
        finish("edited")
    elif "plugin" in text:
        target = home / ".local/share/cybexos/plugins/personal.cputemp/manifest.json"
        answer = ask("r1", "Write", {"file_path": str(target), "content": "{}"})
        if answer["behavior"] == "allow":
            target.parent.mkdir(parents=True)
            target.write_text(json.dumps({"id": "personal.cputemp", "name": "CPU temperature"}))
        finish("widget")
    elif "stage" in text:
        Path(os.environ["CYBEXOS_ASSISTANT_STATUS"]).write_text(json.dumps({
            "transaction": "b" * 32, "state": "ready", "phase": "Built and checked",
            "changes": "obsidian: + 1.9.12", "reviewToken": "c" * 64}))
        answer = ask("r1", "Bash", {"command": "cybex update apply " + "b" * 32 + " " + "c" * 64})
        finish("applied" if answer["behavior"] == "allow" else "not applied")
    elif "hang" in text:
        say("working")
        while True:
            message = read()
            if message.get("type") == "control_request" and message["request"]["subtype"] == "interrupt":
                emit({"type": "control_response",
                      "response": {"subtype": "success", "request_id": message["request_id"]}})
                finish("", error=True)
                break
    elif "crash" in text:
        sys.stderr.write("boom: the fake crashed\n")
        sys.stderr.flush()
        sys.exit(3)
    elif "auth" in text:
        finish("Invalid API key · Please run /login", error=True)
    elif "image" in text:
        images = [block for block in content if block.get("type") == "image"]
        finish("image:" + (images[0]["source"]["media_type"] if images else "none"))
    else:
        say("Hello ")
        emit({"type": "stream_event", "event": {"type": "content_block_delta",
                                                "delta": {"type": "text_delta", "text": "world"}}})
        finish("Hello world")
'''

FAKE_CODEX = r'''
import json, os, sys
from pathlib import Path

signed_out = Path(os.environ['HOME']) / 'signed-out-codex'
if sys.argv[1:] == ['login', 'status']:
    sys.exit(int(signed_out.exists()))
if sys.argv[1:] == ['login']:
    signed_out.unlink(missing_ok=True)
    sys.exit(0)

log = Path(os.environ["FAKE_LOG"])
home = Path(os.environ["HOME"])
counter = [100]

def emit(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()

def note(entry):
    with log.open("a") as stream:
        stream.write(json.dumps(entry) + "\n")

def read():
    line = sys.stdin.readline()
    if not line:
        sys.exit(0)
    return json.loads(line)

def request(method, params):
    counter[0] += 1
    identifier = counter[0]
    emit({"id": identifier, "method": method, "params": params})
    while True:
        message = read()
        if message.get("id") == identifier and "method" not in message:
            return message.get("result")

def notify(method, params):
    emit({"method": method, "params": params})

def final(text, status="completed"):
    notify("item/started", {"threadId": "th-1", "turnId": "tu-1", "item": {"type": "agentMessage", "id": "m2", "text": ""}})
    notify("item/agentMessage/delta", {"threadId": "th-1", "turnId": "tu-1", "itemId": "m2", "delta": text})
    notify("item/completed", {"threadId": "th-1", "turnId": "tu-1",
                              "item": {"type": "agentMessage", "id": "m2", "text": text, "phase": "final_answer"}})
    notify("turn/completed", {"threadId": "th-1", "turn": {"id": "tu-1", "status": status, "error": None, "items": []}})

note({"agent": "codex", "argv": sys.argv[1:]})
while True:
    message = read()
    method, identifier, params = message.get("method"), message.get("id"), message.get("params") or {}
    note({"method": method, "params": params, "jsonrpc": "jsonrpc" in message})
    if method == "initialize":
        emit({"id": identifier, "result": {"userAgent": "fake", "codexHome": str(home), "platformFamily": "unix", "platformOs": "linux"}})
    elif method in ("thread/start", "thread/resume"):
        emit({"id": identifier, "result": {"thread": {"id": params.get("threadId", "th-1")}}})
    elif method == "turn/interrupt":
        emit({"id": identifier, "result": {}})
        notify("turn/completed", {"threadId": "th-1", "turn": {"id": "tu-1", "status": "interrupted", "error": None, "items": []}})
    elif method == "turn/start":
        emit({"id": identifier, "result": {"turn": {"id": "tu-1", "status": "inProgress", "items": []}}})
        text = params["input"][0]["text"]
        notify("turn/started", {"threadId": "th-1", "turn": {"id": "tu-1"}})
        notify("item/started", {"threadId": "th-1", "turnId": "tu-1", "item": {"type": "agentMessage", "id": "m1", "text": ""}})
        notify("item/agentMessage/delta", {"threadId": "th-1", "turnId": "tu-1", "itemId": "m1", "delta": "Let me look."})
        notify("item/completed", {"threadId": "th-1", "turnId": "tu-1",
                                  "item": {"type": "agentMessage", "id": "m1", "text": "Let me look.", "phase": "commentary"}})
        if "command" in text:
            notify("item/started", {"threadId": "th-1", "turnId": "tu-1",
                                    "item": {"type": "commandExecution", "id": "c1", "command": "rm -rf ~/x"}})
            result = request("item/commandExecution/requestApproval",
                             {"threadId": "th-1", "turnId": "tu-1", "itemId": "c1", "command": "rm -rf ~/x",
                              "cwd": str(home), "reason": "Clean up", "startedAtMs": 0, "kind": "command", "environmentId": None})
            final("decision:" + result["decision"])
        elif "edit" in text:
            target = home / ".config/cybexos/shell.json"
            notify("item/started", {"threadId": "th-1", "turnId": "tu-1", "item": {
                "type": "fileChange", "id": "f1", "status": "inProgress",
                "changes": [{"path": str(target), "kind": {"type": "update", "move_path": None}, "diff": "-a\n+b"}]}})
            result = request("item/fileChange/requestApproval",
                             {"threadId": "th-1", "turnId": "tu-1", "itemId": "f1", "startedAtMs": 0})
            if result["decision"] == "accept":
                target.write_text("{}\n")
            final("decision:" + result["decision"])
        elif "elicit" in text:
            result = request("mcpServer/elicitation/request", {"threadId": "th-1", "turnId": "tu-1",
                             "serverName": "x", "mode": "url", "message": "m", "url": "u", "elicitationId": "e", "_meta": None})
            final("elicitation:" + result["action"])
        elif "hang" in text:
            pass
        elif "image" in text:
            images = [item for item in params["input"] if item.get("type") == "localImage"]
            final("image:" + ("yes" if images and Path(images[0]["path"]).exists() else "no"))
        else:
            final("Hi there")
'''


class FakeSpeechd:
    """speech-dispatcher's SSIP, enough for one client."""

    def __init__(self, path, hold=False):
        self.path = path
        self.hold = hold
        self.spoken = []
        self.commands = []
        self.server = None
        self.counter = 0

    async def start(self):
        self.server = await asyncio.start_unix_server(self.handle, path=str(self.path))

    async def stop(self):
        self.server.close()
        await self.server.wait_closed()

    async def handle(self, reader, writer):
        with contextlib.suppress(ConnectionError):
            await self.converse(reader, writer)
        writer.close()

    async def converse(self, reader, writer):
        def send(*lines):
            writer.write(("".join(line + "\r\n" for line in lines)).encode())
        while True:
            raw = await reader.readline()
            if not raw:
                break
            line = raw.decode().rstrip("\r\n")
            self.commands.append(line)
            if line == "SPEAK":
                send("230 OK RECEIVING DATA")
                body = []
                while True:
                    data = (await reader.readline()).decode().rstrip("\r\n")
                    if data == ".":
                        break
                    body.append(data[1:] if data.startswith("..") else data)
                self.counter += 1
                self.spoken.append("\n".join(body))
                send(f"225-{self.counter}", "225 OK MESSAGE QUEUED")
                await writer.drain()
                if not self.hold:
                    await asyncio.sleep(0.01)
                    send(f"701-{self.counter}", "701-1", "701 BEGIN")
                    send(f"702-{self.counter}", "702-1", "702 END")
            elif line == "CANCEL self":
                send("210 OK CANCELED", f"703-{self.counter}", "703-1", "703 CANCELED")
            elif line == "QUIT":
                send("231 HAPPY HACKING")
                await writer.drain()
                break
            else:
                send("208 OK SET")
            await writer.drain()


def short_tempdir():
    # AF_UNIX paths are limited to 108 bytes; keep the socket short.
    base = "/tmp" if os.access("/tmp", os.W_OK) else None
    return tempfile.mkdtemp(prefix="nas-", dir=base)


class Harness:
    def __init__(self, claude=True, codex=True):
        self.root = Path(short_tempdir())
        self.home = self.root / "h"
        self.runtime = self.root / "r"
        self.home.mkdir()
        self.runtime.mkdir(mode=0o700)
        (self.home / ".config/cybexos").mkdir(parents=True)
        (self.home / ".config/cybexos/shell.json").write_text('{"bar": "solid"}\n')
        self.log = self.root / "log.jsonl"
        self.status = self.root / "status.json"
        self.status.write_text(json.dumps({"transaction": "a" * 32, "state": "done"}))
        self.bin = self.root / "bin"
        self.bin.mkdir()
        env = {"HOME": str(self.home), "XDG_RUNTIME_DIR": str(self.runtime), "PATH": os.environ.get("PATH", ""),
               "FAKE_LOG": str(self.log), "CYBEXOS_ASSISTANT_STATUS": str(self.status),
               "CYBEXOS_ASSISTANT_SPEECHD": str(self.runtime / "speechd.sock")}
        for name, source, wanted in (("claude", FAKE_CLAUDE, claude), ("codex", FAKE_CODEX, codex)):
            path = self.bin / name
            path.write_text(f"#!{sys.executable}\n" + textwrap.dedent(source))
            path.chmod(0o755)
            env["CYBEXOS_ASSISTANT_" + name.upper()] = str(path) if wanted else str(self.bin / "absent")
        self.env = env
        self.socket = self.runtime / "cybexos" / "assistant.sock"
        self.state = self.root / "state"
        self.server = None

    async def start(self):
        self.server = Server(self.socket, self.state, home=self.home, env=self.env)
        await self.server.start()
        return self.server

    async def stop(self):
        if self.server is not None:
            await self.server.shutdown()
            self.server = None

    def entries(self):
        if not self.log.exists():
            return []
        return [json.loads(line) for line in self.log.read_text().splitlines() if line]

    def cleanup(self):
        shutil.rmtree(self.root, ignore_errors=True)


class Client:
    def __init__(self):
        self.reader = self.writer = None
        self.notifications = []
        self.results = {}
        self.next_id = 0
        self.task = None

    async def open(self, path):
        self.reader, self.writer = await asyncio.open_unix_connection(str(path))
        self.task = asyncio.create_task(self._read())
        return self

    async def _read(self):
        async for line in iter_lines(self.reader):
            message = parse_json(line)
            if message is None:
                continue
            if "method" in message:
                self.notifications.append(message)
            else:
                self.results[message.get("id")] = message

    async def call(self, method, params=None):
        self.next_id += 1
        identifier = self.next_id
        self.writer.write(encode({"jsonrpc": "2.0", "id": identifier, "method": method, "params": params or {}}))
        await self.writer.drain()
        for _ in range(1000):
            if identifier in self.results:
                return self.results.pop(identifier)
            await asyncio.sleep(0.01)
        raise AssertionError(f"no reply to {method}")

    async def result(self, method, params=None):
        reply = await self.call(method, params)
        if "error" in reply:
            raise AssertionError(f"{method} failed: {reply['error']}")
        return reply["result"]

    async def until(self, predicate, timeout=8.0):
        loop = asyncio.get_running_loop()
        deadline = loop.time() + timeout
        seen = 0
        while loop.time() < deadline:
            while seen < len(self.notifications):
                message = self.notifications[seen]
                seen += 1
                if predicate(message):
                    return message
            await asyncio.sleep(0.01)
        raise AssertionError("timed out; notifications: " + json.dumps(self.notifications[-5:])[:2000])

    async def turn(self, predicate, timeout=8.0):
        message = await self.until(lambda m: m["method"] == "turn.updated" and predicate(m["params"]["turn"]), timeout)
        return message["params"]["turn"]

    async def finished(self, timeout=8.0):
        return await self.turn(lambda turn: turn["status"] in ("completed", "stopped", "failed"), timeout)

    async def close(self):
        if self.writer is not None:
            self.writer.close()
            with contextlib.suppress(Exception):
                await self.writer.wait_closed()
        if self.task is not None:
            self.task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await self.task


class ServiceTest(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.harness = Harness()
        await self.harness.start()
        self.client = await Client().open(self.harness.socket)

    async def asyncTearDown(self):
        await self.client.close()
        await self.harness.stop()
        self.harness.cleanup()

    async def ask(self, text, **params):
        started = await self.client.result("turn.start", dict({"text": text, "agent": "claude"}, **params))
        return started["turn"]


class AuthenticationTest(ServiceTest):
    async def test_signed_out_agent_is_detected_before_any_question(self):
        (self.harness.home / 'signed-out-claude').write_text('out')
        hello = await self.client.result('hello')
        self.assertEqual(hello['agents']['claude']['auth'], 'required')
        reply = await self.client.call('turn.start', {'text': 'Keep my question', 'agent': 'claude'})
        self.assertEqual(reply['error']['code'], -32004)
        self.assertIsNone(self.harness.server.turn)
        self.assertEqual(self.harness.entries(), [])
        self.assertNotIn('private-account-details', json.dumps(hello))
        self.assertFalse(self.harness.server.state_path.exists())

    async def test_each_agents_own_login_command_unblocks_questions(self):
        for agent in ('claude', 'codex'):
            marker = self.harness.home / ('signed-out-' + agent)
            marker.write_text('out')
            before = await self.client.result('auth.status')
            self.assertEqual(before['agents'][agent]['auth'], 'required')
            login = await self.client.result('auth.login', {'agent': agent})
            self.assertEqual(login['argv'], [str(self.harness.bin / agent), *auth.LOGIN_ARGS[agent]])
            self.assertEqual(login['cwd'], str(self.harness.home))
            process = await asyncio.create_subprocess_exec(*login['argv'], env=self.harness.env)
            self.assertEqual(await process.wait(), 0)
            after = await self.client.result('auth.status')
            self.assertEqual(after['agents'][agent]['auth'], 'ready')
            self.assertFalse(marker.exists())
        await self.ask('A question after sign-in')
        self.assertEqual((await self.client.finished())['status'], 'completed')

    async def test_automatic_uses_a_signed_in_agent_and_login_validates_its_target(self):
        (self.harness.home / 'signed-out-claude').write_text('out')
        status = await self.client.result('auth.status')
        self.assertEqual(self.harness.server.resolve('auto', status['agents']), 'codex')
        self.assertEqual(self.harness.server.resolve('claude', status['agents']), 'claude')
        invalid = await self.client.call('auth.login', {'agent': '../../bad'})
        self.assertEqual(invalid['error']['code'], -32602)
        self.harness.server.env['CYBEXOS_ASSISTANT_CODEX'] = str(self.harness.bin / 'absent')
        missing = await self.client.call('auth.login', {'agent': 'codex'})
        self.assertEqual(missing['error']['code'], -32003)

    async def test_uncheckable_auth_is_not_reported_as_ready(self):
        marker = self.harness.home / 'signed-out-claude'
        marker.write_text('error')
        status = await self.client.result('auth.status')
        self.assertEqual(status['agents']['claude']['auth'], 'unknown')
        marker.write_text('hang')
        with patch.object(auth, 'STATUS_TIMEOUT', 0.05):
            status = await self.client.result('auth.status')
        self.assertEqual(status['agents']['claude']['auth'], 'unknown')
        # The timed-out status process was reaped; a later probe can recover.
        marker.unlink()
        status = await self.client.result('auth.status')
        self.assertEqual(status['agents']['claude']['auth'], 'ready')

    async def test_lost_credentials_refresh_the_setup_state(self):
        await self.ask('auth')
        turn = await self.client.finished()
        self.assertEqual(turn['errorKind'], 'auth')
        hello = await self.client.result('hello')
        self.assertEqual(hello['agents']['claude']['auth'], 'required')
        updates = [m for m in self.client.notifications if m['method'] == 'agents.updated']
        self.assertEqual(updates[-1]['params']['agents']['claude']['auth'], 'required')


class PolicyTest(unittest.TestCase):
    home = "/home/person"

    def decide(self, command):
        return policy.decide_command(command, self.home, "/nonexistent/status.json")

    def test_read_only_commands_are_allowed(self):
        for command in ("ls -la ~/.config", "cat /etc/os-release | head -5", "hyprctl -j monitors",
                        "cybex update status", "systemctl --user status quickshell.service",
                        "journalctl --user -u quickshell -n 50", "jq .bar ~/.config/cybexos/shell.json",
                        "git status", "bash -c 'ls -la'", "rg -n foo ~/.config 2>/dev/null",
                        "cd ~/.config && ls", "uname -a; id", "cybex plugin list", "cat $HOME/.bashrc"):
            self.assertEqual(self.decide(command).action, "allow", command)

    def test_staging_is_allowed_and_applying_needs_review(self):
        staged = self.decide("cybex update stage local")
        self.assertEqual((staged.action, staged.step), ("allow", "Waiting for administrator authentication"))
        self.assertEqual(self.decide("cybex software stage '{\"add\": [\"obsidian\"]}'").action, "allow")
        apply = self.decide("cybex update apply " + "0" * 32 + " " + "1" * 64)
        self.assertEqual((apply.action, apply.card["kind"]), ("ask", "apply"))
        self.assertIsNone(apply.key)

    def test_refusals(self):
        for command, fragment in (("sudo rm -rf /", "administrator"), ("cd /tmp && sudo ls", "administrator"),
                                  ("echo $(pkexec id)", "administrator"), ("nixos-rebuild switch", "reviewed"),
                                  ("systemctl reboot", "restarts"), ("reboot", "restarts"),
                                  ("loginctl suspend", "restarts"), ("cybex update rollback", "Rollback"),
                                  ("env FOO=1 sudo id", "administrator")):
            decision = self.decide(command)
            self.assertEqual(decision.action, "deny", command)
            self.assertIn(fragment, decision.message)

    def test_everything_else_asks(self):
        for command in ("rm -rf ~/x", "echo hi > /tmp/x", "find . -delete", "fd -x rm", "rg x --pre=sh",
                        "sort -o out in", "git push", "hyprctl dispatch exec kitty", "cat $FOO",
                        "ls & rm x", "ls && rm x", "bash -c 'rm x'", "journalctl --vacuum-size=1M",
                        "./ls", "cybex plugin enable personal.x", "yq -i .a f", "uniq a b",
                        # Evaluation can read the environment, fetch and build.
                        "nix eval --expr 'builtins.getEnv \"HOME\"'", "nix eval nixpkgs#hello.version",
                        "nix search nixpkgs hello", "nix-instantiate --eval -E 1",
                        # The service's environment may carry an agent's credentials.
                        "env", "printenv", "printenv ANTHROPIC_API_KEY"):
            decision = self.decide(command)
            self.assertEqual((decision.action, decision.card["kind"]), ("ask", "command"), command)
            self.assertEqual(decision.key, ("command", command))

    def test_apply_card_reads_the_staged_change(self):
        with tempfile.TemporaryDirectory() as directory:
            status = Path(directory) / "status.json"
            status.write_text(json.dumps({"transaction": "f" * 32, "state": "ready", "phase": "Built and checked",
                                          "changes": "obsidian: ∅ → 1.9.12"}))
            card = policy.decide_command("cybex update apply " + "f" * 32 + " " + "e" * 64, self.home, status).card
            self.assertEqual((card["transaction"], card["ready"], card["detail"]), ("f" * 32, True, "Built and checked"))
            self.assertIn("obsidian", card["changes"])
            other = policy.decide_command("cybex update apply " + "d" * 32 + " " + "e" * 64, self.home, status).card
            self.assertEqual((other["changes"], other["ready"]), ("", False))

    def test_tools_and_edits(self):
        home = self.home
        self.assertEqual(policy.decide_tool("Read", {"file_path": "/etc/passwd"}, home).action, "allow")
        self.assertEqual(policy.decide_tool("WebFetch", {"url": "https://nixos.org"}, home).action, "allow")
        preference = policy.decide_tool("Edit", {"file_path": "~/.config/cybexos/shell.json"}, home)
        self.assertEqual((preference.action, preference.paths), ("allow", [home + "/.config/cybexos/shell.json"]))
        plugin = policy.decide_tool("Write", {"file_path": home + "/.local/share/cybexos/plugins/p.x/W.qml"}, home)
        self.assertEqual(plugin.action, "allow")
        for vendor in ("/nix/store/abc-x/y", "/etc/cybexos/release.json", "/run/current-system/sw/bin/x"):
            self.assertEqual(policy.decide_tool("Write", {"file_path": vendor}, home).action, "deny")
        other = policy.decide_tool("Write", {"file_path": "notes.txt", "content": "one\ntwo"}, home)
        self.assertEqual((other.action, other.card["path"], other.card["diff"]), ("ask", "~/notes.txt", "+ one\n+ two"))
        self.assertEqual(other.key, ("edit", (home + "/notes.txt",)))
        mcp = policy.decide_tool("mcp__github__create_issue", {"title": "x"}, home)
        self.assertEqual((mcp.action, mcp.card["title"]), ("ask", "Use create_issue from github"))
        bash = policy.decide_tool("Bash", {"command": "ls"}, home)
        self.assertEqual(bash.action, "allow")

    def test_a_link_out_of_the_personal_directories_is_an_ordinary_edit(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            (home / ".config/cybexos").mkdir(parents=True)
            (home / ".bashrc").write_text("# shell\n")
            (home / ".config/cybexos/evil").symlink_to(home / ".bashrc")
            linked = policy.decide_edit(["~/.config/cybexos/evil"], str(home))
            self.assertEqual((linked.action, linked.card["kind"]), ("ask", "edit"))
            (home / "dotfiles").mkdir()
            (home / ".local/share/cybexos").mkdir(parents=True)
            (home / ".local/share/cybexos/plugins").symlink_to(home / "dotfiles")
            self.assertEqual(policy.decide_edit(["~/.local/share/cybexos/plugins/p.x/W.qml"], str(home)).action, "ask",
                             "a linked parent directory counts as well")
            self.assertEqual(policy.decide_edit(["~/.config/cybexos/shell.json"], str(home)).action, "allow")


class SnapshotTest(unittest.TestCase):
    def setUp(self):
        self.home = Path(tempfile.mkdtemp())
        self.shell = self.home / ".config/cybexos/shell.json"
        self.shell.parent.mkdir(parents=True)
        self.shell.write_text("before")
        os.chmod(self.shell, 0o640)

    def tearDown(self):
        shutil.rmtree(self.home, ignore_errors=True)

    def test_undo_restores_preferences_and_removes_created_files(self):
        snapshots = policy.Snapshots(self.home)
        snapshots.begin()
        widget = self.home / ".local/share/cybexos/plugins/personal.cpu/Widget.qml"
        snapshots.take(str(widget))
        self.shell.write_text("after")
        widget.parent.mkdir(parents=True)
        widget.write_text("Item {}")
        self.assertEqual(snapshots.finish(), ["~/.config/cybexos/shell.json",
                                              "~/.local/share/cybexos/plugins/personal.cpu/Widget.qml"])
        restored, skipped = snapshots.undo()
        self.assertEqual((len(restored), skipped), (2, []))
        self.assertEqual(self.shell.read_text(), "before")
        self.assertEqual(self.shell.stat().st_mode & 0o777, 0o640)
        self.assertFalse(widget.parent.exists())
        self.assertTrue((self.home / ".local/share/cybexos/plugins").exists())

    def test_later_edits_are_not_overwritten(self):
        snapshots = policy.Snapshots(self.home)
        snapshots.begin()
        self.shell.write_text("assistant")
        snapshots.finish()
        self.shell.write_text("person")
        restored, skipped = snapshots.undo()
        self.assertEqual((restored, skipped), ([], ["~/.config/cybexos/shell.json"]))
        self.assertEqual(self.shell.read_text(), "person")

    def test_unchanged_files_are_not_listed(self):
        snapshots = policy.Snapshots(self.home)
        snapshots.begin()
        self.assertEqual(snapshots.finish(), [])

    def test_plugins_and_staged_changes(self):
        before = policy.plugin_manifests(self.home)
        for identifier, name in (("personal.cputemp", "CPU temperature"), ("Bad ID", "x")):
            folder = self.home / ".local/share/cybexos/plugins" / identifier.replace(" ", "")
            folder.mkdir(parents=True)
            (folder / "manifest.json").write_text(json.dumps({"id": identifier, "name": name}))
        self.assertEqual(policy.new_plugins(before, policy.plugin_manifests(self.home)),
                         [{"id": "personal.cputemp", "name": "CPU temperature"}])
        self.assertEqual(policy.staged_transaction({"transaction": "a"}, {"transaction": "b", "state": "ready"}), "b")
        self.assertEqual(policy.staged_transaction({"transaction": "b"}, {"transaction": "b", "state": "ready"}), "")
        self.assertEqual(policy.staged_transaction({}, {"transaction": "b", "state": "failed"}), "")


class TextTest(unittest.TestCase):
    def test_markdown_becomes_speakable_sentences(self):
        reply = textwrap.dedent("""\
            **Done.** The bar is now *transparent*. See [the docs](https://example.org).

            - Open `Settings` first
            - Then pick a_b_c.

            ```nix
            environment.systemPackages = [ pkgs.obsidian ];
            ```
            ```sh
            cybex update status
            ```
            That's it!""")
        self.assertEqual(speech.sentences(reply), [
            "Done.", "The bar is now transparent.", "See the docs.", "Open Settings first",
            "Then pick a_b_c.", speech.CODE_NOTE, "That's it!"])
        self.assertEqual(len(speech.sentences("Hi. " * 100)), speech.MAX_SENTENCES)

    def test_prompt_and_turn_notes(self):
        with tempfile.TemporaryDirectory() as directory:
            (Path(directory) / "release.json").write_text(json.dumps({"version": "1.2.3"}))
            (Path(directory) / "developer-enabled").write_text("enabled\n")
            built = prompt.build(release_path=Path(directory) / "release.json", feature_dir=directory)
        self.assertIn("Cybex OS 1.2.3", built)
        self.assertIn("feature groups: developer", built)
        self.assertIn("cybex update apply TRANSACTION REVIEW_TOKEN", built)
        self.assertEqual(prompt.turn_text("Hi", {}), "Hi")
        noted = prompt.turn_text("Why?", {"output": "DP-1", "speak": True}, screenshot=True)
        self.assertTrue(noted.startswith("[Cybex OS: A screenshot of the display the person is looking at (DP-1)"))
        self.assertIn("read aloud", noted)
        self.assertTrue(noted.endswith("]\nWhy?"))


class ClaudeTest(ServiceTest):
    async def test_reply_streams_and_survives_reconnect(self):
        hello = await self.client.result("hello", {"client": "test", "protocol": 1})
        self.assertEqual(hello["agents"]["claude"], {"available": True, "label": "Claude Code", "auth": "ready"})
        self.assertIsNone(hello["turn"])
        turn = await self.ask("Hi there")
        self.assertEqual((turn["status"], turn["agent"], turn["prompt"]), ("running", "claude", "Hi there"))
        done = await self.client.finished()
        self.assertEqual((done["status"], done["text"], done["error"]), ("completed", "Hello world", ""))
        self.assertTrue(done["resumable"])
        deltas = [m["params"]["text"] for m in self.client.notifications if m["method"] == "turn.delta"]
        self.assertEqual("".join(deltas), "Hello world")
        second = await Client().open(self.harness.socket)
        try:
            hello = await second.result("hello", {"client": "second", "protocol": 1})
        finally:
            await second.close()
        self.assertEqual((hello["turn"]["id"], hello["turn"]["text"]), (turn["id"], "Hello world"))
        self.assertEqual(hello["conversation"], {"agent": "claude", "resumable": True})
        argv = self.harness.entries()[0]["argv"]
        for flag in ("-p", "--permission-prompt-tool", "--include-partial-messages", "--append-system-prompt"):
            self.assertIn(flag, argv)
        self.assertEqual(argv[argv.index("--input-format") + 1], "stream-json")
        handoff = await self.client.result("conversation.handoff")
        self.assertEqual(handoff["argv"][1:], ["--resume", "sess-1"])
        self.assertEqual(handoff["cwd"], str(self.harness.home))

    async def test_commands_reach_a_card(self):
        await self.ask("run bash please")
        waiting = await self.client.turn(lambda turn: turn["approvals"])
        card = waiting["approvals"][0]
        self.assertEqual((waiting["status"], card["kind"], card["command"]), ("waiting", "command", "rm -rf ~/x"))
        busy = await self.client.call("turn.start", {"text": "again", "agent": "claude"})
        self.assertEqual(busy["error"]["code"], -32001)
        await self.client.result("approval.respond", {"id": card["id"], "decision": "allow"})
        done = await self.client.finished()
        self.assertEqual((done["status"], done["text"], done["approvals"]), ("completed", "allowed", []))
        missing = await self.client.call("approval.respond", {"id": card["id"], "decision": "allow"})
        self.assertEqual(missing["error"]["code"], -32002)

    async def test_denied_and_remembered_answers(self):
        await self.ask("bash")
        card = (await self.client.turn(lambda turn: turn["approvals"]))["approvals"][0]
        await self.client.result("approval.respond", {"id": card["id"], "decision": "deny"})
        self.assertEqual((await self.client.finished())["text"], "denied")
        self.client.notifications.clear()
        await self.ask("always")
        card = (await self.client.turn(lambda turn: turn["approvals"]))["approvals"][0]
        await self.client.result("approval.respond", {"id": card["id"], "decision": "always"})
        self.assertEqual((await self.client.finished())["text"], "allow/allow")

    async def test_preference_edit_is_allowed_and_undoable(self):
        turn = await self.ask("edit the bar")
        done = await self.client.finished()
        self.assertEqual((done["text"], done["undo"]), ("edited", ["~/.config/cybexos/shell.json"]))
        shell = self.harness.home / ".config/cybexos/shell.json"
        self.assertIn("transparent", shell.read_text())
        undone = await self.client.result("turn.undo", {"id": turn["id"]})
        self.assertEqual(undone, {"restored": ["~/.config/cybexos/shell.json"], "skipped": []})
        self.assertEqual(shell.read_text(), '{"bar": "solid"}\n')
        self.assertEqual((await self.client.turn(lambda turn: not turn["undo"]))["undo"], [])
        again = await self.client.call("turn.undo", {"id": turn["id"]})
        self.assertEqual(again["error"]["code"], -32002)

    async def test_new_widget_is_reported(self):
        await self.ask("make a plugin")
        done = await self.client.finished()
        self.assertEqual(done["plugins"], [{"id": "personal.cputemp", "name": "CPU temperature"}])
        self.assertEqual(done["undo"], ["~/.local/share/cybexos/plugins/personal.cputemp/manifest.json"])

    async def test_staged_change_and_apply_card(self):
        await self.ask("stage obsidian")
        waiting = await self.client.turn(lambda turn: turn["approvals"])
        card = waiting["approvals"][0]
        self.assertEqual((card["kind"], card["ready"], waiting["step"]), ("apply", True, "Waiting for your review"))
        self.assertIn("obsidian", card["changes"])
        await self.client.result("approval.respond", {"id": card["id"], "decision": "allow"})
        done = await self.client.finished()
        self.assertEqual((done["text"], done["staged"]), ("applied", "b" * 32))

    async def test_stop_interrupts(self):
        await self.ask("hang around")
        await self.client.until(lambda m: m["method"] == "turn.delta")
        stopped = await self.client.result("turn.stop")
        self.assertEqual(stopped, {"stopped": True})
        done = await self.client.finished()
        self.assertEqual(done["status"], "stopped")
        self.assertEqual(await self.client.result("turn.stop"), {"stopped": False})

    async def test_crash_and_auth_errors(self):
        await self.ask("crash now")
        done = await self.client.finished()
        self.assertEqual((done["status"], done["errorKind"]), ("failed", "crashed"))
        self.assertIn("boom", done["error"])
        self.client.notifications.clear()
        await self.ask("auth please")
        done = await self.client.finished()
        self.assertEqual((done["status"], done["errorKind"]), ("failed", "auth"))

    async def test_screenshot_is_attached_and_deleted(self):
        shots = self.harness.runtime / "cybexos" / "assistant"
        shot = shots / "screen.jpg"
        shot.write_bytes(b"\xff\xd8fake")
        turn = await self.ask("what is this image", screenshot=str(shot), context={"output": "DP-1"})
        self.assertTrue(turn["screenshot"])
        done = await self.client.finished()
        self.assertEqual(done["text"], "image:image/jpeg")
        self.assertFalse(shot.exists())
        outside = self.harness.root / "elsewhere.png"
        outside.write_bytes(b"x")
        rejected = await self.client.call("turn.start", {"text": "x", "screenshot": str(outside)})
        self.assertEqual(rejected["error"]["code"], -32602)

    async def test_missing_agent_and_invalid_requests(self):
        self.harness.server.env["CYBEXOS_ASSISTANT_CLAUDE"] = str(self.harness.bin / "absent")
        self.harness.server.discovered = (0.0, {})
        await self.ask("hello")
        done = await self.client.finished()
        self.assertEqual((done["status"], done["errorKind"]), ("failed", "missing"))
        for params in ({"text": ""}, {"text": "x", "agent": "gpt"}, {"text": "x", "model": "a b"}):
            self.assertEqual((await self.client.call("turn.start", params))["error"]["code"], -32602)
        self.assertEqual((await self.client.call("nope"))["error"]["code"], -32601)

    async def test_resume_after_restart(self):
        await self.ask("Hi")
        await self.client.finished()
        await self.client.close()
        await self.harness.stop()
        server = await self.harness.start()
        self.assertEqual(server.turn.status, "completed")
        self.client = await Client().open(self.harness.socket)
        hello = await self.client.result("hello")
        self.assertEqual((hello["turn"]["text"], hello["conversation"]["resumable"]), ("Hello world", True))
        await self.ask("Hi again")
        await self.client.finished()
        argv = self.harness.entries()[-1]["argv"]
        self.assertEqual(argv[argv.index("--resume") + 1], "sess-1")
        await self.client.result("conversation.reset")
        hello = await self.client.result("hello")
        self.assertIsNone(hello["conversation"])
        self.assertFalse(hello["turn"]["resumable"])

    async def test_a_lost_session_starts_over(self):
        await self.client.close()
        await self.harness.stop()
        self.harness.state.mkdir(parents=True, exist_ok=True)
        (self.harness.state / "state.json").write_text(json.dumps(
            {"version": 1, "conversation": {"agent": "claude", "claude": "gone"}, "turn": None}))
        server = await self.harness.start()
        self.client = await Client().open(self.harness.socket)
        await self.ask("Hi")
        done = await self.client.finished()
        self.assertEqual((done["status"], done["text"]), ("completed", "Hello world"))
        self.assertEqual(server.conversation["claude"], "sess-1")
        self.assertEqual([entry["argv"].count("--resume") for entry in self.harness.entries()], [1, 0])

    async def test_running_turn_is_failed_after_a_restart(self):
        await self.client.close()
        await self.harness.stop()
        state = self.harness.state / "state.json"
        state.write_text(json.dumps({"version": 1, "conversation": {"agent": "claude", "claude": "sess-9"},
                                     "turn": {"id": "t-1", "agent": "claude", "prompt": "p", "status": "running",
                                              "text": "half", "undo": ["~/.config/cybexos/shell.json"]}}))
        server = await self.harness.start()
        self.client = await Client().open(self.harness.socket)
        turn = (await self.client.result("hello"))["turn"]
        self.assertEqual((turn["status"], turn["error"], turn["undo"]), ("failed", RESTARTED, []))
        self.assertEqual(server.conversation["claude"], "sess-9")
        self.assertEqual(state.stat().st_mode & 0o777, 0o600)


class CodexTest(ServiceTest):
    async def ask(self, text, **params):
        return await super().ask(text, agent="codex", **params)

    async def test_thread_turn_and_final_answer(self):
        await self.ask("Hello")
        done = await self.client.finished()
        self.assertEqual((done["status"], done["text"], done["agent"]), ("completed", "Hi there", "codex"))
        entries = self.harness.entries()
        self.assertEqual(entries[0]["argv"], ["app-server"])
        methods = [entry.get("method") for entry in entries[1:]]
        self.assertEqual(methods[:4], ["initialize", "initialized", "thread/start", "turn/start"])
        self.assertFalse(any(entry.get("jsonrpc") for entry in entries[1:]))
        thread = entries[3]["params"]
        self.assertEqual((thread["sandbox"], thread["approvalPolicy"], thread["cwd"]),
                         ("read-only", "on-request", str(self.harness.home)))
        self.assertIn("Cybex OS Assistant", thread["developerInstructions"])
        handoff = await self.client.result("conversation.handoff")
        self.assertEqual(handoff["argv"][1:], ["resume", "th-1"])

    async def test_command_approval_and_session_grant(self):
        await self.ask("run a command")
        card = (await self.client.turn(lambda turn: turn["approvals"]))["approvals"][0]
        self.assertEqual((card["kind"], card["command"], card["detail"]), ("command", "rm -rf ~/x", "Clean up"))
        await self.client.result("approval.respond", {"id": card["id"], "decision": "always"})
        self.assertEqual((await self.client.finished())["text"], "decision:acceptForSession")

    async def test_preference_patch_is_accepted(self):
        await self.ask("edit preferences")
        done = await self.client.finished()
        self.assertEqual((done["text"], done["undo"]), ("decision:accept", ["~/.config/cybexos/shell.json"]))

    async def test_unsupported_requests_are_declined(self):
        await self.ask("elicit something")
        self.assertEqual((await self.client.finished())["text"], "elicitation:decline")

    async def test_stop_and_screenshot(self):
        await self.ask("hang")
        await self.client.until(lambda m: m["method"] == "turn.delta")
        await self.client.result("turn.stop")
        self.assertEqual((await self.client.finished())["status"], "stopped")
        self.client.notifications.clear()
        shot = self.harness.runtime / "cybexos" / "assistant" / "screen.png"
        shot.write_bytes(b"\x89PNG")
        await self.ask("image", screenshot=str(shot))
        self.assertEqual((await self.client.finished())["text"], "image:yes")
        self.assertFalse(shot.exists())


class CommandLineTest(ServiceTest):
    async def command(self, *args):
        env = dict(self.harness.env, PYTHONPATH=str(ROOT / "desktop" / "assistant"), PYTHONDONTWRITEBYTECODE="1")
        process = await asyncio.create_subprocess_exec(
            sys.executable, "-m", "cybexos_assistant", *args, env=env,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
        out, err = await asyncio.wait_for(process.communicate(), 20)
        return process.returncode, out.decode(), err.decode()

    async def test_status_and_ask(self):
        code, out, _ = await self.command("status", "--socket", str(self.harness.socket))
        self.assertEqual((code, json.loads(out)["protocol"]), (0, 1))
        code, out, _ = await self.command("ask", "--agent", "claude", "--socket", str(self.harness.socket), "Hi")
        self.assertEqual((code, out), (0, "Hello world\n"))
        code, _, err = await self.command("ask", "--socket", str(self.harness.socket), "auth")
        self.assertEqual(code, 1)
        self.assertIn("/login", err)
        code, _, err = await self.command("status", "--socket", str(self.harness.root / "none.sock"))
        self.assertEqual(code, 1)
        self.assertIn("not running", err)


class ServeTest(unittest.IsolatedAsyncioTestCase):
    async def test_service_owns_its_socket_and_stops_cleanly(self):
        harness = Harness()
        try:
            env = dict(harness.env, PYTHONPATH=str(ROOT / "desktop" / "assistant"), PYTHONDONTWRITEBYTECODE="1")
            process = await asyncio.create_subprocess_exec(
                sys.executable, "-m", "cybexos_assistant", "serve", "--state-dir", str(harness.state), env=env,
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
            for _ in range(500):
                if harness.socket.exists():
                    break
                await asyncio.sleep(0.01)
            self.assertEqual(harness.socket.stat().st_mode & 0o777, 0o600)
            self.assertEqual(harness.socket.parent.stat().st_mode & 0o777, 0o700)
            self.assertEqual((harness.runtime / "cybexos" / "assistant").stat().st_mode & 0o777, 0o700)
            client = await Client().open(harness.socket)
            self.assertEqual((await client.result("hello"))["protocol"], 1)
            await client.close()
            process.terminate()
            await asyncio.wait_for(process.wait(), 10)
            self.assertEqual(process.returncode, 0)
            self.assertFalse(harness.socket.exists())
            self.assertTrue((harness.state / "state.json").exists())
        finally:
            harness.cleanup()


class SpeechTest(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.harness = Harness()
        self.speechd = FakeSpeechd(Path(self.harness.env["CYBEXOS_ASSISTANT_SPEECHD"]))

    async def asyncTearDown(self):
        await self.harness.stop()
        self.harness.cleanup()

    async def test_sentences_are_spoken_in_order(self):
        await self.speechd.start()
        await self.harness.start()
        client = await Client().open(self.harness.socket)
        try:
            self.assertTrue((await client.result("hello"))["speech"]["available"])
            said = await client.result("speech.say", {"text": "Done. The bar is **clear**.", "language": "en"})
            self.assertEqual(said["sentences"], ["Done.", "The bar is clear."])
            done = await client.until(lambda m: m["method"] == "speech.done")
            self.assertEqual(done["params"], {"id": said["id"], "status": "done"})
            progress = [m["params"]["index"] for m in client.notifications if m["method"] == "speech.progress"]
            self.assertEqual(progress, [0, 1])
            self.assertEqual(self.speechd.spoken, ["Done.", "The bar is clear."])
            self.assertIn("SET self LANGUAGE en", self.speechd.commands)
            self.assertTrue(any(command.startswith("SET self CLIENT_NAME") for command in self.speechd.commands))
        finally:
            await client.close()
            await self.speechd.stop()

    async def test_stop_cancels_only_this_client(self):
        self.speechd.hold = True
        await self.speechd.start()
        await self.harness.start()
        client = await Client().open(self.harness.socket)
        try:
            said = await client.result("speech.say", {"text": "One sentence. Two sentences."})
            await client.until(lambda m: m["method"] == "speech.progress")
            await asyncio.sleep(0.05)
            await client.result("speech.stop")
            done = await client.until(lambda m: m["method"] == "speech.done")
            self.assertEqual(done["params"], {"id": said["id"], "status": "stopped"})
            self.assertIn("CANCEL self", self.speechd.commands)
        finally:
            await client.close()
            await self.speechd.stop()


if __name__ == "__main__":
    unittest.main()
