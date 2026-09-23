# Compact stdout callback for the XPS Fedora playbook.
#
# Quiet by default: unchanged/skipped tasks print nothing, roles appear as dim
# headers, changed tasks print one ✓ line each (preferring the helper scripts'
# "CHANGED: ..." payload), debug tasks render as ! warnings, and the recap is a
# single line. Any -v verbosity falls back to the stock default callback.
from __future__ import annotations

import re
from collections.abc import Mapping

from ansible import constants as C
from ansible.plugins.callback.default import CallbackModule as DefaultCallback

DOCUMENTATION = """
    name: xps
    type: stdout
    short_description: compact change-focused output for the XPS playbook
    description:
      - Prints only role headers, changes, warnings, and failures.
      - Delegates to the default callback when verbosity is raised.
    extends_documentation_fragment:
      - default_callback
      - result_format_callback
"""

CHANGED_RE = re.compile(r"^CHANGED: (.*)$", re.MULTILINE)


class CallbackModule(DefaultCallback):
    CALLBACK_VERSION = 2.0
    CALLBACK_TYPE = "stdout"
    CALLBACK_NAME = "xps"

    def __init__(self):
        super().__init__()
        self._xps_role = None

    @property
    def _xps_verbose(self):
        # Callback event objects intentionally expose some implementation
        # attributes, but keep their use behind tolerant adapters so a minor
        # ansible-core change degrades to compact output instead of crashing.
        return getattr(getattr(self, "_display", None), "verbosity", 0) > 0

    @staticmethod
    def _xps_payload(result):
        payload = getattr(result, "_result", None)
        return payload if isinstance(payload, Mapping) else {}

    @staticmethod
    def _xps_task(result):
        return getattr(result, "_task", None)

    @staticmethod
    def _xps_role_name(task):
        role = getattr(task, "_role", None)
        get_name = getattr(role, "get_name", None)
        if not callable(get_name):
            return None
        try:
            name = get_name()
        except (AttributeError, TypeError):
            return None
        return str(name) if name else None

    def _xps_note_role(self, task):
        role = self._xps_role_name(task)
        if role and role != self._xps_role:
            self._xps_role = role
            self._display.display("  %s" % role, color=C.COLOR_DEBUG)

    def _xps_task_label(self, result, item=False):
        task = self._xps_task(result)
        get_name = getattr(task, "get_name", None)
        label = get_name() if callable(get_name) else "unnamed task"
        role = self._xps_role_name(task)
        if role:
            prefix = "%s : " % role
            if label.startswith(prefix):
                label = label[len(prefix):]
        if item:
            item_label = self._get_item_label(self._xps_payload(result))
            if isinstance(item_label, (str, int, float)) and str(item_label).strip():
                label = "%s (%s)" % (label, item_label)
        return label

    def _xps_report_ok(self, result, item=False):
        r = self._xps_payload(result)
        task = self._xps_task(result)
        action = str(getattr(task, "action", ""))
        if action.rsplit(".", 1)[-1] == "debug":
            msg = r.get("msg", "")
            if msg:
                self._display.display("    ! %s" % msg, color="yellow")
            return
        if not r.get("changed"):
            return
        payloads = CHANGED_RE.findall(r.get("stdout", "") or "")
        if payloads:
            for payload in payloads:
                self._display.display("    ✓ %s" % payload, color=C.COLOR_CHANGED)
        else:
            self._display.display(
                "    ✓ %s" % self._xps_task_label(result, item=item),
                color=C.COLOR_CHANGED,
            )

    def _xps_report_failed(self, result, item=False, ignored=False):
        r = self._xps_payload(result)
        detail = r.get("msg") or r.get("stderr") or r.get("stdout") or ""
        detail = detail.strip().splitlines()
        prefix = "!" if ignored else "✗"
        color = "yellow" if ignored else C.COLOR_ERROR
        self._display.display(
            "    %s %s" % (prefix, self._xps_task_label(result, item=item)),
            color=color,
        )
        for line in detail[:8]:
            self._display.display("      %s" % line, color=color)

    # -- task lifecycle -----------------------------------------------------

    def v2_playbook_on_start(self, playbook):
        if self._xps_verbose:
            super().v2_playbook_on_start(playbook)

    def v2_playbook_on_play_start(self, play):
        if self._xps_verbose:
            super().v2_playbook_on_play_start(play)

    def v2_playbook_on_task_start(self, task, is_conditional):
        if self._xps_verbose:
            return super().v2_playbook_on_task_start(task, is_conditional)
        self._xps_note_role(task)

    def v2_playbook_on_handler_task_start(self, task):
        if self._xps_verbose:
            return super().v2_playbook_on_handler_task_start(task)
        self._xps_note_role(task)

    def v2_playbook_on_include(self, included_file):
        if self._xps_verbose:
            super().v2_playbook_on_include(included_file)

    def v2_runner_on_start(self, host, task):
        if self._xps_verbose:
            super().v2_runner_on_start(host, task)

    # -- results ------------------------------------------------------------

    def v2_runner_on_ok(self, result):
        if self._xps_verbose:
            return super().v2_runner_on_ok(result)
        if "results" in self._xps_payload(result):
            return  # loop aggregate; items were reported individually
        self._xps_report_ok(result)

    def v2_runner_item_on_ok(self, result):
        if self._xps_verbose:
            return super().v2_runner_item_on_ok(result)
        self._xps_report_ok(result, item=True)

    def v2_runner_on_failed(self, result, ignore_errors=False):
        if self._xps_verbose:
            return super().v2_runner_on_failed(result, ignore_errors=ignore_errors)
        if "results" in self._xps_payload(result):
            return
        self._xps_report_failed(result, ignored=ignore_errors)

    def v2_runner_item_on_failed(self, result):
        if self._xps_verbose:
            return super().v2_runner_item_on_failed(result)
        self._xps_report_failed(result, item=True)

    def v2_runner_on_skipped(self, result):
        if self._xps_verbose:
            super().v2_runner_on_skipped(result)

    def v2_runner_item_on_skipped(self, result):
        if self._xps_verbose:
            super().v2_runner_item_on_skipped(result)

    def v2_runner_on_unreachable(self, result):
        if self._xps_verbose:
            return super().v2_runner_on_unreachable(result)
        self._xps_report_failed(result)

    def v2_runner_retry(self, result):
        # Silent: async_status polling loops would otherwise spam retries.
        if self._xps_verbose:
            super().v2_runner_retry(result)

    def v2_on_file_diff(self, result):
        # Only show diffs when explicitly running verbose/diff mode.
        if self._xps_verbose:
            super().v2_on_file_diff(result)

    # -- recap --------------------------------------------------------------

    def v2_playbook_on_stats(self, stats):
        if self._xps_verbose:
            return super().v2_playbook_on_stats(stats)
        ok = changed = failed = unreachable = ignored = 0
        for host in stats.processed:
            s = stats.summarize(host)
            ok += s.get("ok", 0)
            changed += s.get("changed", 0)
            failed += s.get("failures", 0)
            unreachable += s.get("unreachable", 0)
            ignored += s.get("ignored", 0)
        failed += unreachable
        if failed:
            self._display.display(
                "  ✗ %d task(s) failed  (ok %d, changed %d)" % (failed, ok, changed),
                color=C.COLOR_ERROR,
            )
        elif changed:
            self._display.display(
                "  ✓ %d configuration change(s)  (ok %d)" % (changed, ok),
                color=C.COLOR_CHANGED,
            )
        else:
            self._display.display(
                "  ✓ no configuration changes  (ok %d)" % ok,
                color=C.COLOR_DEBUG,
            )
        if ignored:
            self._display.display(
                "  ! %d failure(s) ignored" % ignored, color="yellow"
            )
