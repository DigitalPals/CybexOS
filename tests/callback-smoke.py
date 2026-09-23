#!/usr/bin/env python3
"""Small compatibility contract for the custom Ansible stdout callback."""

from __future__ import annotations

import importlib.util
from pathlib import Path
from types import SimpleNamespace


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "cybexos_callback", ROOT / "plugins" / "callback" / "cybexos.py"
)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class Display:
    verbosity = 0

    def __init__(self):
        self.lines: list[tuple[str, str | None]] = []

    def display(self, message, color=None, **_kwargs):
        self.lines.append((message, color))


class Role:
    def get_name(self):
        return "desktop"


class Task:
    _role = Role()
    action = "ansible.builtin.command"

    def get_name(self):
        return "desktop : Install helper"


def result(payload, task=None):
    return SimpleNamespace(_result=payload, _task=task or Task())


callback = MODULE.CallbackModule()
callback._display = Display()

callback.v2_playbook_on_task_start(Task(), False)
callback.v2_runner_on_ok(result({"changed": True, "stdout": "CHANGED: helper"}))
callback.v2_runner_on_failed(result({"msg": "expected failure detail"}))

messages = [line for line, _color in callback._display.lines]
assert messages == [
    "  desktop",
    "    ✓ helper",
    "    ✗ Install helper",
    "      expected failure detail",
], messages

# Missing optional callback internals must degrade to a useful label instead
# of raising during a future ansible-core transition.
callback._display.lines.clear()
callback.v2_runner_on_ok(SimpleNamespace(_result={"changed": True}))
assert callback._display.lines[0][0] == "    ✓ unnamed task"

print("callback compatibility smoke test passed")
