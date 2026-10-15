#!/usr/bin/env python3
"""Game mode helper contracts against a stub compositor and user manager.

hyprctl, systemctl, systemd-run and notify-send are fakes on PATH that record
their arguments, so the fixture never reaches a live session. The compositor
side (cybexos_game_mode in looknfeel.lua) has its own fixture in
tests/quickshell/game-mode.test.cjs.
"""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "assets/scripts/game-mode"
UNIT = "cybexos-game-mode-inhibit.service"

FAKE = """#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$(basename "$0") $*" >>"$FAKE_LOG"
case $(basename "$0") in
  hyprctl)
    if [[ -n ${FAKE_HYPRCTL_REPLY:-} ]]; then printf '%s\\n' "$FAKE_HYPRCTL_REPLY"; else printf 'ok\\n'; fi
    ;;
  systemctl)
    case " $* " in
      *" is-active "*) [[ -e $FAKE_UNITS/inhibitor ]] ;;
      *" stop "*) rm -f -- "$FAKE_UNITS/inhibitor" ;;
    esac
    ;;
  systemd-run)
    [[ -z ${FAKE_SYSTEMD_RUN_FAIL:-} ]] || exit 1
    : >"$FAKE_UNITS/inhibitor"
    ;;
esac
"""


class GameMode(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="cybexos-game-mode-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.bin = self.root / "bin"
        self.units = self.root / "units"
        self.runtime = self.root / "runtime"
        for directory in (self.bin, self.units, self.runtime):
            directory.mkdir()
        self.runtime.chmod(0o700)
        for name in ("hyprctl", "systemctl", "systemd-run", "notify-send"):
            path = self.bin / name
            path.write_text(FAKE)
            path.chmod(0o755)
        self.log = self.root / "calls.log"
        self.environment = {
            "PATH": f"{self.bin}:/usr/bin:/bin", "FAKE_LOG": str(self.log),
            "FAKE_UNITS": str(self.units), "XDG_RUNTIME_DIR": str(self.runtime),
            "HYPRLAND_INSTANCE_SIGNATURE": "instance-one", "HOME": str(self.root),
        }
        self.state = self.runtime / "cybexos/game-mode.json"

    def game_mode(self, *args, **environment):
        self.log.unlink(missing_ok=True)
        return subprocess.run([sys.executable, "-I", str(HELPER), *args], capture_output=True, text=True,
                              env={**self.environment, **environment}, timeout=30, check=False)

    def calls(self, program):
        if not self.log.exists():
            return []
        return [line.split(" ", 1)[1] if " " in line else "" for line in self.log.read_text().splitlines()
                if line.split(" ", 1)[0] == program]

    def saved(self):
        return json.loads(self.state.read_text())

    def test_on_applies_effects_inhibits_idle_and_records_this_instance(self):
        result = self.game_mode("on")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "on\n")
        state = self.saved()
        self.assertIs(state["active"], True)
        self.assertEqual(state["instance"], "instance-one")
        self.assertIsInstance(state["since"], int)
        self.assertEqual(self.state.stat().st_mode & 0o777, 0o600)
        self.assertEqual((self.runtime / "cybexos").stat().st_mode & 0o777, 0o700)
        self.assertEqual(self.calls("hyprctl"), ["eval cybexos_game_mode(true)"])
        [inhibitor] = self.calls("systemd-run")
        self.assertIn(f"--unit={UNIT}", inhibitor)
        self.assertIn("--property=PartOf=hyprland-session.target", inhibitor)
        self.assertIn("-- systemd-inhibit --what=idle", inhibitor)
        self.assertIn("--mode=block sleep infinity", inhibitor)
        self.assertNotIn("sleep:", inhibitor, "explicit suspend stays available")
        [notification] = self.calls("notify-send")
        self.assertIn("Game mode on", notification)

        status = self.game_mode("status", "--json")
        self.assertEqual(status.returncode, 0, status.stderr)
        report = json.loads(status.stdout)
        self.assertEqual(report["active"], True)
        self.assertEqual(report["inhibitor"], True)
        self.assertEqual(report["since"], state["since"])
        self.assertEqual(self.calls("hyprctl"), [], "status only reads")

        again = self.game_mode("on")
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertEqual(self.calls("systemd-run"), [], "a running inhibitor is reused")
        self.assertEqual(self.calls("notify-send"), [], "nothing changed, nothing to announce")
        self.assertEqual(self.saved()["since"], state["since"])

    def test_off_restores_effects_releases_idle_and_notifies(self):
        self.game_mode("on")
        result = self.game_mode("off")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "off\n")
        self.assertEqual(self.saved(), {"active": False})
        self.assertEqual(self.calls("hyprctl"), ["eval cybexos_game_mode(false)"])
        self.assertIn(f"--user stop {UNIT}", self.calls("systemctl"))
        self.assertFalse((self.units / "inhibitor").exists())
        [notification] = self.calls("notify-send")
        self.assertIn("Game mode off", notification)
        self.assertEqual(json.loads(self.game_mode("status", "--json").stdout),
                         {"active": False, "inhibitor": False, "since": None})

        quiet = self.game_mode("off")
        self.assertEqual(quiet.returncode, 0, quiet.stderr)
        self.assertEqual(self.calls("hyprctl"), [], "turning off twice leaves the compositor alone")
        self.assertEqual(self.calls("notify-send"), [])

    def test_toggle_alternates(self):
        self.assertEqual(self.game_mode("toggle").stdout, "on\n")
        self.assertEqual(self.game_mode("toggle").stdout, "off\n")
        self.assertEqual(self.game_mode("toggle", "--json").stdout.strip(),
                         json.dumps({"active": True, "inhibitor": True, "since": self.saved()["since"]},
                                    sort_keys=True))

    def test_a_new_login_starts_off_and_clears_what_the_last_one_left(self):
        self.game_mode("on")
        (self.units / "inhibitor").unlink()
        later = {"HYPRLAND_INSTANCE_SIGNATURE": "instance-two"}
        self.assertEqual(self.game_mode("status", **later).stdout, "off\n")
        result = self.game_mode("toggle", **later)
        self.assertEqual(result.stdout, "on\n", "the old file does not make toggle turn it off")
        self.assertEqual(self.saved()["instance"], "instance-two")
        self.game_mode("on")
        stale_off = self.game_mode("off", **later)
        self.assertEqual(stale_off.returncode, 0, stale_off.stderr)
        self.assertEqual(self.calls("hyprctl"), [], "a stale file never restores another session")
        self.assertEqual(self.saved(), {"active": False})

    def test_compositor_refusal_rolls_back_and_reports(self):
        result = self.game_mode("on", FAKE_HYPRCTL_REPLY="error: attempt to call a nil value")
        self.assertEqual(result.returncode, 1)
        self.assertIn("Hyprland could not turn game mode on", result.stderr)
        self.assertEqual(self.saved(), {"active": False})
        self.assertEqual(self.calls("systemd-run"), [], "no inhibitor without the compositor change")
        self.assertEqual(self.calls("notify-send"), [])

    def test_failed_inhibitor_still_turns_effects_off_and_says_so(self):
        result = self.game_mode("on", FAKE_SYSTEMD_RUN_FAIL="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("idle", result.stderr)
        [notification] = self.calls("notify-send")
        self.assertIn("idle lock is still on", notification)
        self.assertIs(json.loads(self.game_mode("status", "--json").stdout)["inhibitor"], False)

    def test_damaged_state_reads_as_off_and_is_replaced(self):
        directory = self.runtime / "cybexos"
        directory.mkdir()
        for text in ("{", "[]", '"on"', '{"active": "true", "instance": "instance-one"}',
                     '{"active": true}', json.dumps({"active": True, "instance": "instance-one",
                                                     "pad": "x" * 5000})):
            with self.subTest(text=text[:40]):
                self.state.write_text(text)
                self.assertEqual(self.game_mode("status").stdout, "off\n")
        self.state.write_text("{")
        self.assertEqual(self.game_mode("on").returncode, 0)
        self.assertIs(self.saved()["active"], True)

    def test_needs_a_session_and_valid_arguments(self):
        outside = self.game_mode("on", HYPRLAND_INSTANCE_SIGNATURE="")
        self.assertEqual(outside.returncode, 1)
        self.assertIn("Hyprland session", outside.stderr)
        self.assertFalse(self.state.exists())
        self.assertEqual(self.game_mode("status", HYPRLAND_INSTANCE_SIGNATURE="").stdout, "off\n")
        no_runtime = self.game_mode("status", XDG_RUNTIME_DIR="")
        self.assertEqual(no_runtime.returncode, 1)
        self.assertIn("XDG_RUNTIME_DIR", no_runtime.stderr)
        for arguments in ((), ("enable",), ("on", "extra")):
            with self.subTest(arguments=arguments):
                self.assertEqual(self.game_mode(*arguments).returncode, 2)

    def test_the_helper_is_a_shared_user_helper_bound_to_super_shift_g(self):
        contract = json.loads((ROOT / "assets/desktop-contract.json").read_text())
        self.assertIn("game-mode", contract["userHelpers"])
        self.assertTrue(os.access(HELPER, os.X_OK))
        self.assertEqual(HELPER.read_text().splitlines()[0], "#!/usr/bin/python3 -I")
        bindings = (ROOT / "roles/desktop/files/bindings.lua").read_text()
        self.assertIn('bind(mainMod .. " + SHIFT + G", hl.dsp.exec_cmd(home .. "/.local/bin/game-mode toggle"),',
                      bindings)
        self.assertIn('"Shell: Game mode"', bindings)
        vendor = json.loads((ROOT / "roles/base/files/cybexos-vendor-paths.json").read_text())
        self.assertIn(".local/bin/game-mode", vendor)
        self.assertIn('/.local/bin/game-mode"', (ROOT / "roles/uninstall/tasks/main.yml").read_text())


if __name__ == "__main__":
    unittest.main()
