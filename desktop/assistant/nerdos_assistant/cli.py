"""`nerdos-assistant`: the service, a status probe and a small debugging client."""

from __future__ import annotations

import argparse
import asyncio
import json
import logging
import os
import sys

from .protocol import MAX_LINE, default_socket, encode, iter_lines, parse_json


def build_parser():
    parser = argparse.ArgumentParser(prog="nerdos-assistant", description="The NerdOS Assistant service")
    commands = parser.add_subparsers(dest="command", required=True)
    serve = commands.add_parser("serve", help="run the service (the user unit does this)")
    serve.add_argument("--socket", default=None)
    serve.add_argument("--state-dir", default=None)
    status = commands.add_parser("status", help="print the service state as JSON")
    status.add_argument("--socket", default=None)
    ask = commands.add_parser("ask", help="ask a question and print the reply")
    ask.add_argument("--agent", choices=("auto", "claude", "codex"), default="auto")
    ask.add_argument("--socket", default=None)
    ask.add_argument("text", nargs="+")
    for verb in ("show", "hide", "toggle"):
        commands.add_parser(verb, help=f"{verb} the character")
    return parser


class Connection:
    def __init__(self, reader, writer):
        self.reader, self.writer = reader, writer
        self.lines = iter_lines(reader, MAX_LINE)
        self.next_id = 0

    @classmethod
    async def open(cls, path):
        reader, writer = await asyncio.open_unix_connection(str(path))
        return cls(reader, writer)

    async def send(self, method, params):
        self.next_id += 1
        self.writer.write(encode({"jsonrpc": "2.0", "id": self.next_id, "method": method, "params": params}))
        await self.writer.drain()
        return self.next_id

    async def receive(self):
        async for line in self.lines:
            message = parse_json(line)
            if message is not None:
                return message
        raise ConnectionError("the assistant service closed the connection")

    async def call(self, method, params, on_notification=None):
        identifier = await self.send(method, params)
        while True:
            message = await self.receive()
            if message.get("id") == identifier:
                if "error" in message:
                    raise RuntimeError(message["error"].get("message", "request failed"))
                return message.get("result")
            if on_notification is not None and "method" in message:
                on_notification(message)

    def close(self):
        self.writer.close()


async def status(path):
    connection = await Connection.open(path)
    try:
        result = await connection.call("hello", {"client": "nerdos-assistant status", "protocol": 1})
    finally:
        connection.close()
    print(json.dumps(result, indent=2, ensure_ascii=False))
    return 0


async def ask(path, agent, text):
    connection = await Connection.open(path)
    current = {"id": None, "printed": 0, "told": set(), "done": None}

    def follow(message):
        method, params = message.get("method"), message.get("params") or {}
        if method == "turn.delta" and params.get("id") == current["id"]:
            sys.stdout.write(params.get("text", ""))
            sys.stdout.flush()
            current["printed"] += len(params.get("text", ""))
        elif method == "turn.updated":
            turn = params.get("turn") or {}
            if turn.get("id") != current["id"]:
                return
            for card in turn.get("approvals") or []:
                if card.get("id") not in current["told"]:
                    current["told"].add(card.get("id"))
                    print(f"\n[waiting in the assistant: {card.get('title')}]", file=sys.stderr)
            if turn.get("status") in ("completed", "stopped", "failed"):
                current["done"] = turn

    try:
        await connection.call("hello", {"client": "nerdos-assistant ask", "protocol": 1})
        started = await connection.call("turn.start", {"text": text, "agent": agent}, follow)
        current["id"] = started["turn"]["id"]
        while current["done"] is None:
            follow(await connection.receive())
    finally:
        connection.close()
    turn = current["done"]
    if not current["printed"] and turn.get("text"):
        sys.stdout.write(turn["text"])
    sys.stdout.write("\n")
    if turn.get("status") == "failed":
        print(turn.get("error") or "The assistant could not answer.", file=sys.stderr)
        return 1
    return 0 if turn.get("status") == "completed" else 1


def main(argv=None):
    args = build_parser().parse_args(argv)
    if args.command in ("show", "hide", "toggle"):
        try:
            os.execvp("nerdos-runtime", ["nerdos-runtime", "ipc", "assistant", args.command])
        except OSError as error:
            print(f"nerdos-assistant: {error}", file=sys.stderr)
            return 127
    path = args.socket or default_socket()
    if args.command == "serve":
        from .server import Server
        logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
        os.umask(0o077)
        asyncio.run(Server(path, args.state_dir).serve())
        return 0
    try:
        if args.command == "status":
            return asyncio.run(status(path))
        return asyncio.run(ask(path, args.agent, " ".join(args.text)))
    except (ConnectionError, FileNotFoundError, OSError) as error:
        print(f"nerdos-assistant: the assistant service is not running ({error})", file=sys.stderr)
        return 1
    except RuntimeError as error:
        print(f"nerdos-assistant: {error}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        return 130
