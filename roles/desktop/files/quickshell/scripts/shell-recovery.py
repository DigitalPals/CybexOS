#!/usr/bin/env python3
"""Crash-loop recovery for the managed shell, without modifying user settings.

The launcher execs qs so systemd's MainPID remains the only shell PID.
ExecStopPost records only failed invocations. Three short failures in two
minutes select a separate minimal configuration until the user retries.
"""
from __future__ import annotations

import argparse
from contextlib import contextmanager
import fcntl
import json
import os
from pathlib import Path
import sys
import tempfile
import time
from typing import Any, Iterator

FAILURE_WINDOW = 120.0
FAILURE_LIMIT = 3


def state_path() -> Path:
    return Path(os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local/state"))) / "cybexos/shell-recovery.json"


def boot_id() -> str:
    return Path("/proc/sys/kernel/random/boot_id").read_text().strip()


def read_state(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text())
        if not isinstance(value, dict) or value.get("version") != 1:
            raise ValueError("invalid recovery state")
        return value
    except FileNotFoundError:
        return {"version": 1, "safe": False, "failures": []}
    except (ValueError, OSError):
        # A damaged recovery record must not strand the desktop. It contains
        # only disposable lifecycle data, never user settings or plugin data.
        return {"version": 1, "safe": True, "failures": [], "reason": "Recovery state could not be read"}


def write_state(path: Path, value: dict[str, Any]) -> None:
    fd, temporary = tempfile.mkstemp(prefix=".shell-recovery-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(value, stream, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


@contextmanager
def state_lock(path: Path) -> Iterator[None]:
    path.parent.mkdir(parents=True, exist_ok=True)
    with (path.parent / ".shell-recovery.lock").open("a") as lock:
        os.chmod(lock.name, 0o600)
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield


def prepare(state: dict[str, Any], now: float, boot: str, invocation: str) -> dict[str, Any]:
    state = dict(state)
    if state.get("boot") != boot:
        state["failures"] = []
    state.update(boot=boot, invocation=invocation, started=now, active=True)
    return state


def record_stop(state: dict[str, Any], now: float, boot: str, invocation: str,
                result: str, exit_code: str, exit_status: str) -> dict[str, Any]:
    state = dict(state)
    if state.get("boot") != boot or state.get("invocation") != invocation or not state.get("active"):
        return state
    state["active"] = False
    state["lastExit"] = {"result": result, "code": exit_code, "status": exit_status}
    elapsed = max(0.0, now - float(state.get("started", now)))
    failures = [value for value in state.get("failures", [])
                if isinstance(value, (int, float)) and 0 <= now - value <= FAILURE_WINDOW]
    if result == "success" or elapsed > FAILURE_WINDOW:
        failures = []
    elif result in {"exit-code", "signal", "core-dump", "timeout", "watchdog", "oom-kill"}:
        failures.append(now)
    state["failures"] = failures[-FAILURE_LIMIT:]
    if len(failures) >= FAILURE_LIMIT:
        state["safe"] = True
        state["reason"] = "The desktop failed three times within two minutes"
    return state


def selected_path(runtime: Path, state: dict[str, Any]) -> Path:
    fallback = runtime / "safe-mode"
    return fallback if state.get("safe") and (fallback / "shell.qml").is_file() else runtime


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["run", "record-stop", "status", "path", "safe", "recover"])
    parser.add_argument("runtime", type=Path)
    args = parser.parse_args(argv)
    path = state_path()
    with state_lock(path):
        state = read_state(path)
        if args.action == "run":
            state = prepare(state, time.monotonic(), boot_id(), os.environ.get("INVOCATION_ID", ""))
        elif args.action == "record-stop":
            state = record_stop(state, time.monotonic(), boot_id(), os.environ.get("INVOCATION_ID", ""),
                                os.environ.get("SERVICE_RESULT", ""), os.environ.get("EXIT_CODE", ""),
                                os.environ.get("EXIT_STATUS", ""))
        elif args.action in {"safe", "recover"}:
            # Invalidate the old invocation: its ExecStopPost must not undo
            # this deliberate recovery choice during the following restart.
            state.update(safe=args.action == "safe", failures=[], active=False,
                         reason="Safe mode requested" if args.action == "safe" else "")
        if args.action not in {"status", "path"}:
            write_state(path, state)
    if args.action == "status":
        print(json.dumps({**state, "path": str(path), "runtime": str(selected_path(args.runtime, state))}, sort_keys=True))
    elif args.action == "path":
        print(selected_path(args.runtime, state))
    elif args.action == "run":
        selected = selected_path(args.runtime, state)
        if selected != args.runtime:
            os.environ["CYBEXOS_SHELL_SAFE_MODE"] = "1"
            print("cybexos: starting the recovery desktop; use cybex shell recover to retry", file=sys.stderr, flush=True)
        os.execv("/usr/bin/qs", ["qs", "-p", str(selected)])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
