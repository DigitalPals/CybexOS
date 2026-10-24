"""One question and its answer: streamed text, steps and approval cards."""

from __future__ import annotations

import asyncio
import re

from . import policy
from .protocol import now_ms


FINAL = ("completed", "stopped", "failed")
STOPPED_MESSAGE = "The person stopped this request."
DECLINED_MESSAGE = ("The person declined this action. Do not retry it; explain what you wanted "
                    "to do so they can decide.")
AUTH_PATTERN = re.compile(r"\b(?:log ?in|/login|logged in|authenticat\w*|api key|401|oauth|unauthori[sz]ed|sign in)\b", re.I)


def classify(error):
    return "auth" if error and AUTH_PATTERN.search(str(error)) else ""


class Turn:
    def __init__(self, identifier, agent, prompt, home, memory, publish, screenshot=False):
        self.id = identifier
        self.agent = agent
        self.prompt = prompt
        self.status = "running"
        self.step = "Thinking"
        self.text = ""
        self.error = ""
        self.error_kind = ""
        self.started_at = now_ms()
        self.finished_at = 0
        self.undo = []
        self.plugins = []
        self.staged = ""
        self.screenshot = screenshot
        self.snapshots = policy.Snapshots(home)
        # Conversation-wide "always" answers, shared with the next turns.
        self.memory = memory
        self.stopping = False
        self._publish = publish
        self._approvals = {}
        self._counter = 0

    @property
    def finished(self):
        return self.status in FINAL

    def snapshot(self, resumable=False):
        return {
            "id": self.id, "agent": self.agent, "prompt": self.prompt, "status": self.status,
            "step": self.step, "text": self.text, "error": self.error, "errorKind": self.error_kind,
            "approvals": [entry["card"] for entry in self._approvals.values()],
            "startedAt": self.started_at, "finishedAt": self.finished_at, "undo": list(self.undo),
            "plugins": list(self.plugins), "staged": self.staged, "screenshot": self.screenshot,
            "resumable": resumable,
        }

    def updated(self):
        self._publish("updated", self)

    def delta(self, text):
        if text and not self.finished:
            self.text += text
            self._publish("delta", self, text)

    def reset_text(self):
        if self.text and not self.finished:
            self.text = ""
            self.updated()

    def set_step(self, step):
        if step and step != self.step and not self.finished and self.status != "waiting":
            self.step = step
            self.updated()

    def finish(self, status, text=None, error="", kind=""):
        self.status = status
        if text is not None:
            self.text = text
        self.error = error or ""
        self.error_kind = kind or (classify(error) if status == "failed" else "")
        self.step = ""
        self.finished_at = now_ms()
        self.deny_all()

    # ---- approvals ---------------------------------------------------------

    async def authorize(self, decision, cancel_key=None):
        """("allow" | "always" | "deny" | "cancelled", message for a denial)."""
        if decision.action == "deny":
            return "deny", decision.message
        if self.stopping or self.finished:
            return "deny", STOPPED_MESSAGE
        if decision.action == "ask" and not (decision.key and decision.key in self.memory):
            answer = await self.ask(decision.card, cancel_key)
            if answer == "cancelled":
                return "cancelled", ""
            if answer not in ("allow", "always"):
                return "deny", STOPPED_MESSAGE if self.stopping else DECLINED_MESSAGE
            if answer == "always" and decision.key:
                self.memory.add(decision.key)
            result = answer
        else:
            result = "allow"
        for path in decision.paths:
            self.snapshots.take(path)
        if decision.step:
            self.set_step(decision.step)
        return result, ""

    async def ask(self, card, cancel_key=None):
        self._counter += 1
        identifier = f"a-{self._counter}"
        future = asyncio.get_running_loop().create_future()
        self._approvals[identifier] = {"card": dict(card, id=identifier), "future": future, "cancel": cancel_key}
        previous = self.step
        self.status = "waiting"
        self.step = "Waiting for your review" if card.get("kind") == "apply" else "Waiting for your approval"
        self.updated()
        try:
            return await future
        finally:
            self._approvals.pop(identifier, None)
            if not self._approvals and self.status == "waiting":
                self.status = "running"
                self.step = previous or "Working"
            if not self.finished:
                self.updated()

    # Answers leave the card list at once, so the snapshot published for the
    # change never still shows the card that was just answered.
    def _resolve(self, identifier, answer):
        entry = self._approvals.pop(identifier, None)
        if entry is None or entry["future"].done():
            return False
        entry["future"].set_result(answer)
        return True

    def respond(self, identifier, decision):
        return self._resolve(identifier, decision)

    def cancel(self, cancel_key):
        for identifier, entry in list(self._approvals.items()):
            if entry["cancel"] is not None and entry["cancel"] == cancel_key:
                self._resolve(identifier, "cancelled")

    def deny_all(self):
        for identifier in list(self._approvals):
            self._resolve(identifier, "deny")
