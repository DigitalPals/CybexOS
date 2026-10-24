#!/usr/bin/env python3
"""Drive the real shell and assistant service with a scripted agent.

The actual Quickshell engine loads the whole shell under a private headless
Sway, the actual nerdos-assistant service runs beside it, and a fake
`claude` speaks Claude Code's stream-json and permission protocol. Questions
go in through the shell's `assistant` IPC target, as `nerd assistant ask`
sends them; approvals are answered over the service socket, as the card's
buttons do. What a turn left behind (Undo, a new widget) is checked on disk
and in the service's snapshot, and the shell's log must stay free of QML
errors throughout.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import re
import shutil
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import time


ROOT = Path(__file__).resolve().parents[1]
DBUS = ["dbus-run-session", *(["--config-file", os.environ["NERDOS_DBUS_SESSION_CONFIG"]]
                              if os.environ.get("NERDOS_DBUS_SESSION_CONFIG") else []), "--"]
QML_ERRORS = re.compile(r"TypeError|ReferenceError|Binding loop|is not a type|Type \w+ unavailable"
                        r"|Cannot assign|Unable to assign|Illegal method name|Failed to load configuration")

FAKE_CLAUDE = r'''
import json, os, sys, time
from pathlib import Path

args = sys.argv[1:]
session = args[args.index("--resume") + 1] if "--resume" in args else "overlay-session"
home = Path(os.environ["HOME"])
signed_out = home / 'signed-out-claude'
if args == ['auth', 'status']:
    sys.exit(int(signed_out.exists()))
if args == ['auth', 'login']:
    signed_out.unlink(missing_ok=True)
    sys.exit(0)

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
          "request": {"subtype": "can_use_tool", "tool_name": tool, "input": tool_input,
                      "tool_use_id": "tu-" + request_id}})
    while True:
        message = read()
        if message.get("type") == "control_response" and message["response"]["request_id"] == request_id:
            return message["response"]["response"]

def reply(text):
    emit({"type": "stream_event", "event": {"type": "message_start"}})
    for word in text.split(" "):
        emit({"type": "stream_event", "event": {"type": "content_block_delta",
                                                "delta": {"type": "text_delta", "text": word + " "}}})
    emit({"type": "result", "subtype": "success", "is_error": False, "result": text, "session_id": session})

emit({"type": "system", "subtype": "init", "session_id": session})
while True:
    message = read()
    if message.get("type") != "user":
        continue
    text = message["message"]["content"][0]["text"].lower()
    if "transparent" in text:
        target = home / ".config/nerdos/shell.json"
        emit({"type": "assistant", "message": {"content": [
            {"type": "tool_use", "id": "x", "name": "Read", "input": {"file_path": str(target)}}]}})
        if ask("r1", "Edit", {"file_path": str(target), "old_string": "a", "new_string": "b"})["behavior"] == "allow":
            data = json.loads(target.read_text())
            data["glassEnabled"] = True
            target.write_text(json.dumps(data, indent=2) + "\n")
        reply("The menubar is transparent now.")
    elif "clean" in text:
        answer = ask("r1", "Bash", {"command": "rm -rf ~/Downloads/old-isos"})
        time.sleep(0.2)
        reply("Removed it." if answer["behavior"] == "allow" else "Okay, I left it alone.")
    elif "widget" in text:
        target = home / ".local/share/nerdos/plugins/personal.cputemp/manifest.json"
        if ask("r1", "Write", {"file_path": str(target), "content": "{}"})["behavior"] == "allow":
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(json.dumps({"id": "personal.cputemp", "name": "CPU temperature",
                                          "version": "1.0.0", "apiVersion": 1, "entrypoint": "Widget.qml"}))
        reply("I made a CPU temperature widget. It is off until you add it to the bar.")
    else:
        reply("I can help with NerdOS.")
'''


class VirtualPointer:
    """Real headless-compositor input via wlr-virtual-pointer v1.

    Sway's cursor IPC reports success without delivering events when its
    headless seat has no pointer. This creates a pointer device on that seat.
    The tiny client only binds the registry and sends motion/button/frame.
    """
    def __init__(self, env, width, height):
        self.width, self.height = width, height
        self.socket = socket.socket(socket.AF_UNIX)
        self.socket.settimeout(5)
        self.socket.connect(str(Path(env['XDG_RUNTIME_DIR']) / env['WAYLAND_DISPLAY']))
        self.buffer = bytearray()
        self.send(1, 1, 2)  # wl_display.get_registry(new_id=2)
        self.send(1, 0, 3)  # wl_display.sync(callback=3)
        manager = None
        while True:
            identifier, opcode, payload = self.receive()
            if identifier == 2 and opcode == 0:
                name, length = struct.unpack_from('II', payload)
                interface = payload[8:8 + length - 1].decode()
                if interface == 'zwlr_virtual_pointer_manager_v1':
                    manager = name
            if identifier == 3:
                break
        assert manager is not None, 'The isolated compositor has no virtual pointer protocol'
        interface = b'zwlr_virtual_pointer_manager_v1\0'
        interface += b'\0' * (-len(interface) % 4)
        payload = struct.pack('II', manager, len(b'zwlr_virtual_pointer_manager_v1\0')) + interface + struct.pack('II', 1, 4)
        self.frame(2, 0, payload)  # wl_registry.bind(manager v1, new_id=4)
        self.send(4, 0, 0, 5)  # manager.create_virtual_pointer(default seat, new_id=5)

    def frame(self, identifier, opcode, payload=b''):
        self.socket.sendall(struct.pack('II', identifier, ((len(payload) + 8) << 16) | opcode) + payload)

    def send(self, identifier, opcode, *values):
        self.frame(identifier, opcode, struct.pack('I' * len(values), *values))

    def receive(self):
        while len(self.buffer) < 8 or len(self.buffer) < struct.unpack_from('II', self.buffer)[1] >> 16:
            data = self.socket.recv(4096)
            assert data, 'The compositor closed the pointer connection'
            self.buffer.extend(data)
        identifier, header = struct.unpack_from('II', self.buffer)
        size, opcode = header >> 16, header & 0xffff
        payload = bytes(self.buffer[8:size])
        del self.buffer[:size]
        assert not (identifier == 1 and opcode == 0), f'Wayland protocol error: {payload!r}'
        return identifier, opcode, payload

    def move(self, x, y):
        self.send(5, 1, int(time.monotonic() * 1000) & 0xffffffff, round(x), round(y), self.width, self.height)
        self.send(5, 4)
        time.sleep(0.04)

    def button(self, pressed):
        self.send(5, 2, int(time.monotonic() * 1000) & 0xffffffff, 0x110, int(pressed))
        self.send(5, 4)
        time.sleep(0.04)

    def close(self):
        self.socket.close()


class Session:
    def __init__(self, base):
        self.base = base
        self.runtime = base / "run"
        self.runtime.mkdir(mode=0o700)
        self.home = base / "home"
        (self.home / ".config/nerdos").mkdir(parents=True)
        self.preferences = self.home / ".config/nerdos/shell.json"
        self.preferences.write_text(json.dumps({"v": 30, "assistantShown": True,
                                               "assistantX": 1000, "assistantY": 120}, indent=2) + "\n")
        (self.home / 'signed-out-claude').touch()
        self.shell = base / "shell"
        shutil.copytree(ROOT / "desktop/quickshell", self.shell)
        shell_entry = self.shell / 'shell.qml'
        shell_entry.write_text(shell_entry.read_text().replace('target: "assistant"',
            'target: "assistant"\n        function signIn(agent: string): void { Assistant.signIn(agent); }'))
        fake = base / "claude"
        fake.write_text(f"#!{sys.executable}\n" + FAKE_CLAUDE)
        fake.chmod(0o700)
        launchers = base / 'bin'
        launchers.mkdir()
        terminal = launchers / 'nerdos-apps'
        terminal.write_text(f'#!{sys.executable}\nimport json,os,sys\nfrom pathlib import Path\n'
            'Path(os.environ["HOME"]).joinpath("login-argv.json").write_text(json.dumps(sys.argv[1:]))\n'
            'command=sys.argv[sys.argv.index("--")+1:]\nos.execv(command[0], command)\n')
        terminal.chmod(0o700)
        self.env = {**os.environ, "HOME": str(self.home), "XDG_RUNTIME_DIR": str(self.runtime),
                    "XDG_CONFIG_HOME": str(self.home / ".config"),
                    "XDG_DATA_HOME": str(self.home / ".local/share"),
                    "XDG_STATE_HOME": str(self.home / ".local/state"), "QT_QPA_PLATFORM": "wayland",
                    "QT_QUICK_BACKEND": "software", "WLR_BACKENDS": "headless", "WLR_RENDERER": "pixman",
                    "WLR_LIBINPUT_NO_DEVICES": "1", "NERDOS_ASSISTANT": "1",
                    "NERDOS_CONNECTED_WIDGETS": "0", "NERDOS_DEVELOPER_TOOLS": "0",
                    "QML_IMPORT_PATH": os.environ.get("NERDOS_QML_IMPORT_PATH", ""),
                    "PATH": str(launchers) + os.pathsep + os.environ.get('PATH', '')}
        for name in ("DISPLAY", "WAYLAND_DISPLAY"):
            self.env.pop(name, None)
        self.service_env = {"PYTHONPATH": str(ROOT / "desktop/assistant"), "PYTHONDONTWRITEBYTECODE": "1",
                            "NERDOS_ASSISTANT_CLAUDE": str(fake),
                            "NERDOS_ASSISTANT_CODEX": str(base / "no-codex"),
                            "NERDOS_ASSISTANT_STATUS": str(base / "no-status.json")}
        self.processes = []
        self.pointer = None

    def start(self, argv, log, extra=None):
        process = subprocess.Popen(argv, env={**self.env, **(extra or {})}, stdout=(self.base / log).open("w"),
                                   stderr=subprocess.STDOUT, start_new_session=True)
        self.processes.append(process)
        return process

    def stop(self):
        if self.pointer is not None:
            self.pointer.close()
        for process in reversed(self.processes):
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        for process in reversed(self.processes):
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()

    def ipc(self, *args):
        result = subprocess.run(["qs", "ipc", "-p", str(self.shell), "call", "assistant", *args],
                                env=self.env, capture_output=True, text=True, timeout=10)
        return result.stdout.strip()

    def shell_state(self):
        try:
            return json.loads(self.ipc("status") or "{}")
        except (json.JSONDecodeError, subprocess.TimeoutExpired):
            return {}

    def call(self, method, params):
        with socket.socket(socket.AF_UNIX) as client:
            client.settimeout(10)
            client.connect(str(self.runtime / "nerdos/assistant.sock"))
            client.sendall((json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params})
                            + "\n").encode())
            buffer = b""
            while True:
                chunk = client.recv(65536)
                if not chunk:
                    raise AssertionError(f"the service closed the connection during {method}")
                buffer += chunk
                *lines, buffer = buffer.split(b"\n")
                for line in lines:
                    message = json.loads(line)
                    if message.get("id") == 1:
                        return message

    def turn(self):
        return self.call("hello", {"client": "overlay-test", "protocol": 1})["result"]["turn"]

    def wait(self, predicate, what, timeout=20):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            value = predicate()
            if value:
                return value
            time.sleep(0.2)
        raise AssertionError(f"timed out waiting for {what}\n{self.log()}")

    def finished(self, prompt):
        def done():
            turn = self.turn()
            return turn if turn and turn["prompt"] == prompt and turn["status"] in ("completed", "failed") else None
        return self.wait(done, f"the answer to {prompt!r}")

    def log(self):
        path = self.base / "qs.log"
        return path.read_text(errors="replace") if path.exists() else ""

    def drag(self, x, y, dx, dy):
        self.pointer.move(x, y)
        self.pointer.button(True)
        for step in range(1, 21):
            self.pointer.move(x + dx * step / 20, y + dy * step / 20)
        self.pointer.button(False)


def main():
    if not shutil.which("qs") or any(subprocess.run(['pgrep', '-u', str(os.getuid()), '-x', name],
            stdout=subprocess.DEVNULL).returncode == 0 for name in ('qs', '.quickshell-wra')):
        print("Assistant overlay test deferred to isolated CI")
        return
    with tempfile.TemporaryDirectory(prefix="nerdos-assistant-overlay-") as temporary:
        session = Session(Path(temporary))
        try:
            (session.base / "sway.conf").write_text("output HEADLESS-1 mode 1440x900\nseat seat0 fallback true\n")
            sway = session.base / "sway"
            shutil.copyfile(shutil.which("sway"), sway)
            sway.chmod(0o700)
            session.start([str(sway), "-c", str(session.base / "sway.conf")], "sway.log")
            sockets = session.wait(lambda: [p for p in session.runtime.glob("wayland-*") if p.is_socket()],
                                   "the compositor", timeout=10)
            session.env["WAYLAND_DISPLAY"] = sockets[0].name
            session.pointer = VirtualPointer(session.env, 1440, 900)
            session.start([sys.executable, "-B", "-m", "nerdos_assistant", "serve"], "service.log",
                          session.service_env)
            session.start([*DBUS, "qs", "--no-color", "-p", str(session.shell)], "qs.log")

            state = session.wait(lambda: session.shell_state().get("connected") and session.shell_state(),
                                 "the shell to connect to the service", timeout=45)
            assert state["shown"] and state["screen"] == "HEADLESS-1", state

            # A fresh account sees onboarding before a model process is used.
            assert state['setupRequired'] and not state['agentReady'], state
            session.ipc('ask', 'Keep this first question')
            session.wait(lambda: session.shell_state().get('composing') and session.shell_state().get('hasDraft'),
                         'sign-in onboarding with the saved question')
            assert session.turn() is None
            session.wait(lambda: not session.shell_state().get('authChecking'), 'the initial sign-in check')
            session.ipc('signIn', 'claude')
            session.wait(lambda: session.shell_state().get('agentReady') and session.shell_state().get('hasDraft'),
                         'automatic sign-in detection with the saved question')
            argv = json.loads((session.home / 'login-argv.json').read_text())
            assert argv[-3:] == [str(session.base / 'claude'), 'auth', 'login'], argv

            # Send real compositor pointer events. Repeated movement must cover
            # the full distance despite the character's scale/rotation/mask.
            for dx, dy in ((-300, 200), (180, -120), (-400, 330)):
                before = session.shell_state()
                size = before['size']
                session.drag(before['x'] + size / 2, before['y'] + size / 2, dx, dy)
                try:
                    after = session.wait(lambda: (lambda s: s if abs(s.get('x', -9999) - before['x'] - dx) <= 3
                        and abs(s.get('y', -9999) - before['y'] - dy) <= 3 else None)(session.shell_state()),
                        'the full drag distance', timeout=3)
                except AssertionError as error:
                    raise AssertionError(f'{before=} wanted {dx=}, {dy=}; actual={session.shell_state()}\n{error}') from error
                assert after['screen'] == 'HEADLESS-1'

            # A preference edit is allowed without a card and comes back with Undo.
            session.ipc("ask", "Make the menubar transparent")
            turn = session.finished("Make the menubar transparent")
            assert turn["status"] == "completed" and turn["text"].startswith("The menubar"), turn
            assert turn["undo"] == ["~/.config/nerdos/shell.json"], turn
            assert json.loads(session.preferences.read_text())["glassEnabled"] is True
            session.wait(lambda: session.shell_state().get("turn") == "completed", "the shell's reply")
            undone = session.call("turn.undo", {"id": turn["id"]})["result"]
            assert undone == {"restored": ["~/.config/nerdos/shell.json"], "skipped": []}, undone
            assert "glassEnabled" not in json.loads(session.preferences.read_text())

            # Anything else waits for the person, and the shell shows it as waiting.
            session.ipc("ask", "Clean up my old downloads")
            waiting = session.wait(lambda: (lambda t: t if t and t["approvals"] else None)(session.turn()),
                                   "the command card")
            card = waiting["approvals"][0]
            assert waiting["status"] == "waiting" and card["kind"] == "command", waiting
            assert card["command"] == "rm -rf ~/Downloads/old-isos", card
            session.wait(lambda: session.shell_state().get("turn") == "waiting", "the shell to show the card")
            assert session.call("approval.respond", {"id": card["id"], "decision": "deny"})["result"] == {"ok": True}
            denied = session.finished("Clean up my old downloads")
            assert denied["text"] == "Okay, I left it alone.", denied

            # A widget lands disabled, and the reply offers it.
            session.ipc("ask", "Create a CPU temperature widget")
            made = session.finished("Create a CPU temperature widget")
            assert made["plugins"] == [{"id": "personal.cputemp", "name": "CPU temperature"}], made

            # Hiding takes the character away and reports it; the service keeps the conversation.
            session.ipc("hide")
            session.wait(lambda: session.shell_state().get("shown") is False, "the character to hide")
            # Settings are saved shortly after they change.
            session.wait(lambda: json.loads(session.preferences.read_text()).get("assistantShown") is False,
                         "the hidden state to be saved")
            hello = session.call("hello", {"client": "overlay-test", "protocol": 1})["result"]
            assert hello["conversation"] == {"agent": "claude", "resumable": True}, hello

            output = session.log()
            errors = [line for line in output.splitlines() if QML_ERRORS.search(line)]
            assert not errors, "\n".join(errors)
            print("Assistant onboarding/draft preservation, repeated pointer dragging, approvals, Undo, widget hand-off and hiding passed")
        finally:
            session.stop()


if __name__ == "__main__":
    if os.geteuid() == 0:
        raise SystemExit(subprocess.call(["runuser", "-u", "nobody", "--", sys.executable, __file__]))
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    main()
