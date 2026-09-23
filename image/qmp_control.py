#!/usr/bin/env python3
"""Inspect only the disposable VM described by image/test-live's vm.json."""
import argparse
import json
from pathlib import Path
import socket
import subprocess
import time
import sys


class Qmp:
    def __init__(self, path):
        self.socket = socket.socket(socket.AF_UNIX)
        self.socket.settimeout(10)
        self.socket.connect(path)
        self.stream = self.socket.makefile("rwb", buffering=0)
        self.stream.readline()
        self.call("qmp_capabilities")

    def call(self, command, arguments=None):
        self.stream.write((json.dumps({"execute": command, "arguments": arguments or {}}) + "\n").encode())
        while line := self.stream.readline():
            response = json.loads(line)
            if "error" in response:
                raise RuntimeError(response["error"])
            if "return" in response:
                return response["return"]
        raise RuntimeError("QEMU disconnected")


def type_text(qmp, text):
    if any(ord(character) > 127 for character in text):
        raise ValueError("QMP typing supports ASCII only")
    punctuation = {" ": "spc", "\n": "ret", "/": "slash", ".": "dot", "-": "minus",
                   "=": "equal", "[": "bracket_left", "]": "bracket_right", "'": "apostrophe",
                   ";": "semicolon", "\\": "backslash", ",": "comma", "`": "grave_accent"}
    shifted = dict(zip('!@#$%^&*()_+{}:"|<>?~', '1234567890-=[];\'\\,./`'))
    for character in text:
        shift = character.isupper() or character in shifted
        base = shifted.get(character, character.lower())
        code = punctuation.get(base, base)
        codes = ["shift", code] if shift else [code]
        events = [{"type": "key", "data": {"down": True, "key": {"type": "qcode", "data": item}}} for item in codes]
        events += [{"type": "key", "data": {"down": False, "key": {"type": "qcode", "data": item}}} for item in reversed(codes)]
        qmp.call("input-send-event", {"events": events})
        time.sleep(0.015)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    subparsers = parser.add_subparsers(dest="command", required=True)
    screenshot = subparsers.add_parser("screenshot")
    screenshot.add_argument("filename", type=Path)
    key = subparsers.add_parser("key")
    key.add_argument("keys", help="QEMU key names joined with +, e.g. ctrl+alt+f2")
    typing = subparsers.add_parser("type")
    typing.add_argument("text", nargs="?", default="", help="ASCII text to type into the focused VM window")
    typing.add_argument("--stdin", action="store_true", help="Read private text from stdin instead of process arguments")
    click = subparsers.add_parser("click")
    click.add_argument("x", type=int)
    click.add_argument("y", type=int)
    click.add_argument("--width", type=int, default=1280)
    click.add_argument("--height", type=int, default=800)
    ssh = subparsers.add_parser("ssh")
    ssh.add_argument("arguments", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    state = json.loads((args.directory / "vm.json").read_text())
    if args.command == "ssh":
        raise SystemExit(subprocess.run([*state["ssh"], *args.arguments]).returncode)
    qmp = Qmp(state["qmp"])
    if args.command == "screenshot":
        qmp.call("screendump", {"filename": str(args.filename.resolve()), "format": "png"})
    elif args.command == "key":
        qmp.call("send-key", {"keys": [{"type": "qcode", "data": key} for key in args.keys.split("+")]})
    elif args.command == "type":
        type_text(qmp, sys.stdin.read() if args.stdin else args.text)
    elif args.command == "click":
        qmp.call("input-send-event", {"events": [
            {"type": "abs", "data": {"axis": "x", "value": int(args.x / args.width * 32767)}},
            {"type": "abs", "data": {"axis": "y", "value": int(args.y / args.height * 32767)}},
        ]})
        time.sleep(0.15)
        qmp.call("input-send-event", {"events": [{"type": "btn", "data": {"down": True, "button": "left"}}]})
        time.sleep(0.15)
        qmp.call("input-send-event", {"events": [{"type": "btn", "data": {"down": False, "button": "left"}}]})


if __name__ == "__main__":
    main()
