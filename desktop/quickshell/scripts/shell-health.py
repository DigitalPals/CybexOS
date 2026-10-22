#!/usr/bin/env python3
"""Emit a bounded, non-sensitive health snapshot for the Quickshell UI."""

from __future__ import annotations

import json
import os
import re
import subprocess
import time


SERVICE = "quickshell.service"


def run(command: list[str]) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(
            command,
            check=False,
            capture_output=True,
            text=True,
            timeout=4,
            env={**os.environ, "LC_ALL": "C"},
        )
    except subprocess.TimeoutExpired:
        return subprocess.CompletedProcess(command, 124, "", "")
    except OSError:
        return subprocess.CompletedProcess(command, 127, "", "")


def parse_properties(text: str) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in text.splitlines():
        key, separator, value = line.partition("=")
        if separator:
            values[key] = value
    return values


def safe_int(value: str) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return 0


def safe_message(message: str) -> str:
    """Compact common journal diagnostics without exposing local secrets."""
    home = os.path.expanduser("~").rstrip("/")
    compact = " ".join(message.split())
    if home:
        compact = compact.replace(home, "~")
    compact = re.sub(r"(https?://)[^/@\s]+:[^/@\s]+@", r"\1…@", compact)
    compact = re.sub(
        r"(?i)\b(authorization)\s*[:=]\s*(?:(?:bearer|dpop)\s+)?[^,;&\s]+",
        r"\1: …",
        compact,
    )
    compact = re.sub(
        r"(?i)(--?(?:access[-_]?token|token|api[-_]?key|password|passwd|secret)"
        r"(?:=|\s+))[^,;&\s]+",
        r"\1…",
        compact,
    )
    compact = re.sub(
        r"(?i)([\"']?(?:access[-_]?token|token|api[-_]?key|password|passwd|secret)"
        r"[\"']?\s*[:=]\s*)[\"']?[^\"',;&\s}]+[\"']?",
        r"\1…",
        compact,
    )
    compact = re.sub(
        r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}(?:\.[A-Za-z0-9_-]+)?\b",
        "…",
        compact,
    )
    compact = re.sub(
        r"\b(?:gh[pousr]_|sk-|xox[baprs]-)[A-Za-z0-9_-]{8,}\b",
        "…",
        compact,
    )
    return compact[:237] + "…" if len(compact) > 240 else compact


def service_snapshot() -> dict[str, object]:
    result = run([
        "systemctl", "--user", "show", SERVICE, "--no-pager",
        "--property=ActiveState", "--property=MainPID",
        "--property=ActiveEnterTimestampMonotonic", "--property=InvocationID",
    ])
    if result.returncode != 0:
        return {"active": False, "pid": 0, "uptimeSecs": 0, "error": "Service state unavailable"}

    values = parse_properties(result.stdout)
    started_us = safe_int(values.get("ActiveEnterTimestampMonotonic", "0"))
    uptime = max(0, round(time.monotonic() - started_us / 1_000_000)) if started_us else 0
    return {
        "active": values.get("ActiveState") == "active",
        "pid": safe_int(values.get("MainPID", "0")),
        "uptimeSecs": uptime,
        "invocationId": values.get("InvocationID", ""),
        "error": "",
    }


def warning_snapshot(invocation_id: str) -> list[str]:
    if not invocation_id:
        return []
    result = run([
        "journalctl", "--user", "--unit", SERVICE,
        f"_SYSTEMD_INVOCATION_ID={invocation_id}", "--priority=warning",
        "--lines=8", "--output=json", "--no-pager",
    ])
    if result.returncode != 0:
        return []

    warnings: list[str] = []
    for line in result.stdout.splitlines():
        try:
            message = str(json.loads(line).get("MESSAGE", "")).strip()
        except (json.JSONDecodeError, AttributeError):
            continue
        if not message:
            continue
        warnings.append(safe_message(message))
    return warnings[-3:]


def main() -> int:
    service = service_snapshot()
    document = {
        "service": service,
        "warnings": warning_snapshot(str(service.get("invocationId", ""))),
        "checkedAt": int(time.time()),
    }
    print(json.dumps(document, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
