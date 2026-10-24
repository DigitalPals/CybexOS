"""Short, human-readable lines for the working pill."""

from __future__ import annotations

import os
from urllib.parse import urlparse


def short(text, limit=60):
    text = " ".join(str(text).split())
    return text if len(text) <= limit else text[:limit - 1] + "…"


def basename(path):
    return os.path.basename(str(path).rstrip("/")) or str(path)


def running(command):
    return "Running " + short(command) if command else "Running a command"


def editing(path):
    return "Editing " + basename(path) if path else "Editing a file"


def claude_tool(name, tool_input):
    tool_input = tool_input if isinstance(tool_input, dict) else {}
    if name == "Read":
        return "Reading " + basename(tool_input.get("file_path", "a file"))
    if name == "Bash":
        return running(tool_input.get("command", ""))
    if name in ("Edit", "Write", "MultiEdit"):
        return editing(tool_input.get("file_path", ""))
    if name == "NotebookEdit":
        return editing(tool_input.get("notebook_path", ""))
    if name == "WebSearch":
        return "Searching the web"
    if name == "WebFetch":
        host = urlparse(str(tool_input.get("url", ""))).hostname
        return "Reading " + host if host else "Reading a web page"
    if name in ("Grep", "Glob", "LS"):
        return "Searching files"
    if name == "TodoWrite":
        return "Planning"
    if name in ("Task", "Agent"):
        return "Delegating"
    if name == "Skill":
        skill = tool_input.get("skill") or tool_input.get("name") or tool_input.get("command")
        return f"Using the {short(skill, 30)} skill" if skill else "Using a skill"
    if name.startswith("mcp__"):
        return "Using " + short(name.split("__")[-1], 40)
    return "Using " + short(name, 40)


def codex_item(item):
    kind = item.get("type") if isinstance(item, dict) else None
    if kind == "commandExecution":
        return running(item.get("command", ""))
    if kind == "fileChange":
        changes = item.get("changes") or []
        first = changes[0].get("path") if changes and isinstance(changes[0], dict) else ""
        return editing(first) if len(changes) <= 1 else f"Editing {len(changes)} files"
    if kind == "webSearch":
        return "Searching the web"
    if kind == "mcpToolCall":
        return "Using " + short(item.get("tool", "a tool"), 40)
    if kind == "dynamicToolCall":
        return "Using " + short(item.get("tool", "a tool"), 40)
    if kind == "reasoning":
        return "Thinking"
    if kind == "imageView":
        return "Looking at the screenshot"
    return ""
