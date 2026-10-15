#!/usr/bin/env python3
"""Background update download contracts against mocked system tools.

The helper must only ever download (dnf --downloadonly, flatpak --no-deploy),
wait for an unmetered, fully connected network and for no other package work,
leave the last record alone when it skips, and publish exactly the record the
desktop reads (Common/UpdatesHelpers.js parseDownloadStatus). The fixture
never reaches the real package managers, NetworkManager or systemd.
"""

import json
import os
from pathlib import Path
import re
import stat
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "roles/base/files/cybexos-update-download"
SERVICE = ROOT / "roles/base/files/cybexos-update-download.service"
SHELL_HELPERS = ROOT / "roles/desktop/files/quickshell/Common/UpdatesHelpers.js"

MOCKS = {
    # `busctl get-property` answers "u <value>"; MOCK_NM_FAIL models a
    # system without NetworkManager.
    "busctl": """
[[ -z ${MOCK_NM_FAIL:-} ]] || exit 1
case ${@: -1} in
  State) printf 'u %s\\n' "${MOCK_NM_STATE:-70}" ;;
  Metered) printf 'u %s\\n' "${MOCK_NM_METERED:-4}" ;;
  *) exit 1 ;;
esac
""",
    "systemctl": """
printf '%s\\n' "$*" >>"$MOCK_LOG.systemctl"
[[ $1 == list-units ]] && printf '%s' "${MOCK_UPDATE_UNITS:-}"
exit 0
""",
    "pgrep": """
printf '%s\\n' "$*" >>"$MOCK_LOG.pgrep"
exit "${MOCK_PGREP_RC:-1}"
""",
    "dnf": """
printf '%s\\n' "$*" >>"$MOCK_LOG.dnf"
exit "${MOCK_DNF_RC:-0}"
""",
    "flatpak": """
printf '%s\\n' "$*" >>"$MOCK_LOG.flatpak"
exit "${MOCK_FLATPAK_RC:-0}"
""",
}


class BackgroundDownload(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="cybexos-update-download-test.")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for name, body in MOCKS.items():
            path = self.bin / name
            path.write_text("#!/usr/bin/env bash\nset -uo pipefail\n" + body)
            path.chmod(0o755)
        self.state = self.root / "state"
        self.cmdline = self.root / "cmdline"
        self.cmdline.write_text("BOOT_IMAGE=/vmlinuz-7.2.7 root=UUID=x ro rootflags=subvol=root quiet\n")
        self.log = self.root / "log"
        self.environment = {
            "PATH": f"{self.bin}:{os.environ['PATH']}",
            "HOME": str(self.root),
            "LC_ALL": "C",
            "STATE_DIRECTORY": str(self.state),
            "CYBEXOS_UPDATE_DOWNLOAD_TESTING": "1",
            "CYBEXOS_UPDATE_DOWNLOAD_CMDLINE": str(self.cmdline),
            "MOCK_LOG": str(self.log),
        }

    def run_helper(self, *arguments, **overrides):
        environment = {**self.environment, **overrides}
        return subprocess.run(["bash", str(HELPER), *arguments], env=environment,
                              capture_output=True, text=True, timeout=30, check=False)

    def calls(self, tool):
        path = Path(f"{self.log}.{tool}")
        return path.read_text().splitlines() if path.exists() else []

    def record(self):
        return json.loads((self.state / "status.json").read_text())

    def test_downloads_without_installing_and_publishes_a_readable_record(self):
        result = self.run_helper()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls("dnf"), ["--assumeyes upgrade --downloadonly"])
        self.assertEqual(self.calls("flatpak"), ["update --system --noninteractive --no-deploy"])
        record = self.record()
        self.assertEqual(set(record), {"version", "state", "startedAt", "finishedAt", "dnfRc",
                                       "flatpakRc"})
        self.assertEqual((record["version"], record["state"], record["dnfRc"],
                          record["flatpakRc"]), (1, "done", 0, 0))
        self.assertGreaterEqual(record["finishedAt"], record["startedAt"])
        mode = stat.S_IMODE((self.state / "status.json").stat().st_mode)
        self.assertEqual(mode, 0o644, "the desktop reads it unprivileged")
        self.assertEqual(list(self.state.glob(".status.*")), [], "no temporary file is left")
        self.assertIn("download done", result.stdout)

    def test_never_installs_or_deploys(self):
        source = HELPER.read_text()
        commands = [line.strip() for line in source.splitlines()
                    if re.match(r"\s*(dnf|flatpak) ", line)]
        self.assertEqual(len(commands), 2, commands)
        self.assertIn("--downloadonly", commands[0])
        self.assertIn("--no-deploy", commands[1])
        self.assertNotRegex(source, r"\bsudo\b|\bpkexec\b|--offline|\breboot\b")

    def test_skips_leave_the_last_record_and_download_nothing(self):
        self.state.mkdir()
        previous = {"version": 1, "state": "done", "startedAt": 1, "finishedAt": 2,
                    "dnfRc": 0, "flatpakRc": 0}
        (self.state / "status.json").write_text(json.dumps(previous))
        cases = {
            "the network is metered": {"MOCK_NM_METERED": "1"},
            "the network is metered (guessed)": {"MOCK_NM_METERED": "3"},
            "the network is not fully connected": {"MOCK_NM_STATE": "50"},
            "an update is running": {
                "MOCK_UPDATE_UNITS": "cybexos-update-20261013-120000-1-1.service loaded active running x\n"},
            "other package work is running": {"MOCK_PGREP_RC": "0"},
        }
        for label, overrides in cases.items():
            with self.subTest(label):
                result = self.run_helper(**overrides)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("skipped: " + label.split(" (")[0], result.stdout)
                self.assertEqual(self.calls("dnf"), [])
                self.assertEqual(self.calls("flatpak"), [])
                self.assertEqual(self.record(), previous)
        self.cmdline.write_text("BOOT_IMAGE=/x cybexos.recovery=20261013T120000Z-42 ro\n")
        result = self.run_helper()
        self.assertIn("skipped: this boot runs from a recovery point", result.stdout)
        self.assertEqual(self.calls("dnf"), [])
        self.assertEqual(self.record(), previous)

    def test_checks_the_update_worker_and_package_processes(self):
        self.run_helper()
        self.assertIn("list-units --plain --no-legend --state=active,activating "
                      "cybexos-update-2*.service", self.calls("systemctl"))
        self.assertEqual(self.calls("pgrep"), ["-x dnf5|dnf|rpm"])

    def test_without_networkmanager_dnf_decides(self):
        result = self.run_helper(MOCK_NM_FAIL="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.calls("dnf")), 1)
        self.assertEqual(self.record()["state"], "done")

    def test_a_failed_download_is_recorded_not_raised(self):
        for tool, rc in (("dnf", "1"), ("flatpak", "2")):
            with self.subTest(tool):
                result = self.run_helper(**{f"MOCK_{tool.upper()}_RC": rc})
                self.assertEqual(result.returncode, 0,
                                 "being offline for a while is not a failed unit")
                record = self.record()
                self.assertEqual(record["state"], "failed")
                self.assertEqual(record[f"{tool}Rc"], int(rc))

    def test_an_unwritable_record_fails_the_unit_and_arguments_are_refused(self):
        self.state.mkdir()
        self.state.chmod(0o555)
        self.addCleanup(self.state.chmod, 0o755)
        if os.access(self.state, os.W_OK):
            self.skipTest("running as root; directory permissions do not apply")
        result = self.run_helper()
        self.assertEqual(result.returncode, 1)
        self.assertIn("could not record the download", result.stdout)
        self.assertEqual(self.run_helper("--now").returncode, 2)

    def test_the_desktop_reads_the_path_the_unit_writes(self):
        shell_path = re.search(r'var DOWNLOAD_STATUS_PATH = "([^"]+)";',
                               SHELL_HELPERS.read_text()).group(1)
        unit = SERVICE.read_text()
        state_directory = re.search(r"^StateDirectory=(\S+)$", unit, re.M).group(1)
        self.assertEqual(shell_path, f"/var/lib/{state_directory}/status.json")
        self.assertIn(f"state_dir=${{STATE_DIRECTORY:-/var/lib/{state_directory}}}",
                      HELPER.read_text())
        self.assertIn("ExecStart=/usr/local/libexec/cybexos-update-download", unit)


if __name__ == "__main__":
    unittest.main()
