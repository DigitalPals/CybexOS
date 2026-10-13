#!/usr/bin/env python3
"""Exercise crash accounting and recovery with isolated state; never start qs."""
from __future__ import annotations

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "roles/desktop/files/quickshell/scripts/shell-recovery.py"
SPEC = importlib.util.spec_from_file_location("shell_recovery", SCRIPT)
assert SPEC and SPEC.loader
M = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(M)


class RecoveryTest(unittest.TestCase):
    def test_failures_select_safe_mode_on_fourth_launch(self):
        state = {"version": 1, "safe": False, "failures": []}
        for count in range(3):
            state = M.prepare(state, 10 * count, "boot", str(count))
            state = M.record_stop(state, 10 * count + 1, "boot", str(count), "signal", "killed", "SEGV")
            self.assertEqual(bool(state.get("safe")), count == 2)
        state = M.prepare(state, 31, "boot", "safe")
        self.assertTrue(state["safe"])

    def test_normal_restart_long_run_and_boot_do_not_form_crash_loop(self):
        state = {"version": 1, "safe": False, "failures": []}
        for count in range(6):
            state = M.prepare(state, count * 5, "boot", str(count))
            state = M.record_stop(state, count * 5 + 1, "boot", str(count), "success", "exited", "0")
        self.assertFalse(state["safe"])
        state = M.prepare(state, 100, "boot", "fail")
        state = M.record_stop(state, 101, "boot", "fail", "exit-code", "exited", "1")
        state = M.prepare(state, 105, "boot", "long")
        state = M.record_stop(state, 300, "boot", "long", "signal", "killed", "SEGV")
        self.assertEqual(state["failures"], [])
        state["failures"] = [300, 305]
        self.assertEqual(M.prepare(state, 1, "new-boot", "next")["failures"], [])

    def test_stale_or_duplicate_stop_cannot_count_twice(self):
        state = M.prepare({"version": 1, "safe": False, "failures": []}, 0, "boot", "new")
        self.assertEqual(M.record_stop(state, 1, "boot", "old", "signal", "killed", "SEGV"), state)
        stopped = M.record_stop(state, 1, "boot", "new", "signal", "killed", "SEGV")
        self.assertEqual(M.record_stop(stopped, 2, "boot", "new", "signal", "killed", "SEGV"), stopped)

    def test_launcher_execs_selected_shell_without_an_extra_supervisor(self):
        with tempfile.TemporaryDirectory(prefix="cybexos-shell-exec.") as scratch:
            runtime = ROOT / "roles/desktop/files/quickshell"
            with patch.dict(os.environ, {"XDG_STATE_HOME": scratch, "INVOCATION_ID": "test"}):
                M.main(["safe", str(runtime)])
                with patch.object(M.os, "execv") as execute:
                    M.main(["run", str(runtime)])
                execute.assert_called_once_with("/usr/bin/qs", ["qs", "-p", str(runtime / "safe-mode")])
                self.assertEqual(M.read_state(M.state_path())["invocation"], "test")

    def test_commands_preserve_config_and_roundtrip_state(self):
        with tempfile.TemporaryDirectory(prefix="cybexos-shell-recovery.") as scratch:
            root = Path(scratch)
            config = root / "config/cybexos"
            config.mkdir(parents=True)
            personal = {"shell.json": '{"v":26,"font":"mine"}', "plugins.json": '{"enabled":["mine"]}'}
            for name, content in personal.items():
                (config / name).write_text(content)
            env = dict(os.environ, XDG_STATE_HOME=str(root / "state"), XDG_CONFIG_HOME=str(root / "config"), HOME=str(root))
            runtime = ROOT / "roles/desktop/files/quickshell"
            def call(action):
                return subprocess.check_output(["python3", "-B", str(SCRIPT), action, str(runtime)], env=env, text=True)
            call("safe")
            status = json.loads(call("status"))
            self.assertTrue(status["safe"])
            self.assertEqual(call("path").strip(), str(runtime / "safe-mode"))
            self.assertEqual(Path(status["path"]).stat().st_mode & 0o777, 0o600)
            call("recover")
            self.assertFalse(json.loads(call("status"))["safe"])
            self.assertEqual(call("path").strip(), str(runtime))
            for name, content in personal.items():
                self.assertEqual((config / name).read_text(), content)
            Path(status["path"]).write_text("{broken")
            self.assertTrue(json.loads(call("status"))["safe"])
            call("recover")
            self.assertFalse(json.loads(call("status"))["safe"])
            self.assertEqual(list((root / "state/cybexos").glob(".shell-recovery-*")), [])


if __name__ == "__main__":
    unittest.main()
