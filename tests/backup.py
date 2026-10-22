#!/usr/bin/env python3
"""cybexos-backup against stubbed restic, secret-tool and desktop commands.

The gate never touches a keyring. Most tests use stubs on PATH, which
record every call, so these fixtures pin what the helper asks of them: the
repository setup and its two keys, the includes, excludes and retention,
the reasons a scheduled run quietly waits, the once-a-day reminder and
failure notice, and that a restore can only ever land in a new folder. When
restic is installed, an offline temporary snapshot/restore checks real data.
"""

import contextlib
import importlib.machinery
import importlib.util
import io
import json
import os
import pwd
import shutil
import sqlite3
from datetime import datetime, timedelta, timezone
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "assets/scripts/cybexos-backup"
LOADER = importlib.machinery.SourceFileLoader("cybexos_backup", str(HELPER))
SPEC = importlib.util.spec_from_loader(LOADER.name, LOADER)
backup = importlib.util.module_from_spec(SPEC)
LOADER.exec_module(backup)

# A small restic: a JSON state file stands in for the repository's keys and
# snapshots. Every call is logged with the passwords it was given.
RESTIC = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
argv = sys.argv[1:]
state_path = Path(os.environ["STUB_STATE"])
state = json.loads(state_path.read_text()) if state_path.exists() else {"keys": [], "snapshots": []}
def option(name):
    return argv[argv.index(name) + 1] if name in argv else None
def secret(name):
    path = option(name)
    return Path(path).read_text() if path else None
password, new_password = secret("--password-file"), secret("--new-password-file")
repository = option("--repo")
rest = [a for i, a in enumerate(argv) if a not in ("--repo", "--password-file", "--retry-lock", "-o",
        "--new-password-file") and (i == 0 or argv[i - 1] not in ("--repo", "--password-file",
        "--retry-lock", "-o", "--new-password-file"))]
command = rest[0] if rest else ""
with open(os.environ["STUB_LOG"], "a") as log:
    log.write(json.dumps({"argv": argv, "password": password, "new": new_password,
                          "command": command, "env": sorted(k for k in os.environ if k.startswith("RESTIC_"))}) + "\n")
fail = json.loads(os.environ.get("STUB_RESTIC_FAIL", "{}"))
if command in fail:
    sys.stderr.write(fail[command].get("stderr", "") + "\n")
    sys.exit(fail[command]["status"])
def save():
    state_path.write_text(json.dumps(state))
def known():
    return password in state["keys"]
if command == "init":
    if state["keys"]:
        sys.stderr.write("Fatal: create repository at x failed: config file already exists\n"); sys.exit(1)
    if not repository.startswith("sftp:"):
        for part in ("keys", "data"):
            (Path(repository) / part).mkdir(parents=True, exist_ok=True)
        (Path(repository) / "config").write_text("{}")
    state["keys"].append(password); save(); sys.exit(0)
if not known():
    sys.stderr.write("Fatal: wrong password or no key found\n"); sys.exit(12)
if command == "key" and rest[1] == "add":
    state["keys"].append(new_password); save(); sys.exit(0)
if command == "key" and rest[1] == "list":
    print(json.dumps([{"current": key == password, "id": "id-" + key[:6]} for key in state["keys"]]))
    sys.exit(0)
if command == "key" and rest[1] == "remove":
    state["keys"] = [key for key in state["keys"] if "id-" + key[:6] != rest[2]]; save(); sys.exit(0)
if command == "cat":
    print("{}"); sys.exit(0)
if command == "backup":
    for message in json.loads(os.environ.get("STUB_BACKUP_ERRORS", "[]")):
        print(json.dumps(message), file=sys.stderr)
    sys.stderr.write(os.environ.get("STUB_BACKUP_STDERR", ""))
    print(json.dumps({"message_type": "status", "percent_done": 0.5, "total_bytes": 10, "bytes_done": 5}))
    print(json.dumps({"message_type": "summary", "snapshot_id": "ab" * 32, "total_files_processed": 3,
                      "total_bytes_processed": 300, "data_added": 120}))
    sys.exit(int(os.environ.get("STUB_BACKUP_STATUS", "0")))
if command == "snapshots":
    print(json.dumps(state["snapshots"])); sys.exit(0)
if command == "restore":
    target = Path(option("--target"))
    include = option("--include")
    files = json.loads(os.environ.get("STUB_RESTORE_FILES", '["Documents/a.txt"]'))
    restored = 0
    for name in files:
        if include and not ("/" + name).startswith(include):
            continue
        (target / name).parent.mkdir(parents=True, exist_ok=True)
        (target / name).write_text("restored")
        restored += 1
    print(json.dumps({"message_type": "summary", "total_files": restored, "files_restored": restored}))
    sys.exit(0)
sys.exit(0)
'''

# secret-tool over a directory; STUB_KEYRING_LOCKED lists items without
# their secret, as a locked GNOME Keyring does for an unlocking-free search.
SECRET_TOOL = r'''#!/usr/bin/env python3
import os, sys, json
from pathlib import Path
store = Path(os.environ["STUB_KEYRING"]); store.mkdir(exist_ok=True)
action, args = sys.argv[1], sys.argv[2:]
label = ""
if action == "store":
    label, args = args[0], args[1:]
name = "_".join(args)
with open(os.environ["STUB_LOG"], "a") as log:
    log.write(json.dumps({"secret-tool": action, "args": args, "label": label}) + "\n")
locked = os.environ.get("STUB_KEYRING_LOCKED") == "1"
item = store / name
if action == "store":
    item.write_text(sys.stdin.read())
elif action == "lookup":
    if locked or not item.exists():
        sys.exit(1)
    sys.stdout.write(item.read_text())
elif action == "search":
    if item.exists():
        print("[/1]")
        print("label = " + name)
        if not locked:
            print("secret = " + item.read_text())
elif action == "clear":
    if item.exists():
        item.unlink()
'''

LOGGER = r'''#!/bin/sh
printf '%s\n' "$(basename "$0") $*" >> "$STUB_LOG"
'''

BUSCTL = r'''#!/bin/sh
printf '%s\n' "busctl $*" >> "$STUB_LOG"
printf 'u %s\n' "${STUB_METERED:-4}"
'''

SSH = r'''#!/bin/sh
printf '%s\n' "ssh $*" >> "$STUB_LOG"
printf 'user tester\nhostname 127.0.0.1\nport %s\nproxyjump none\n' "$STUB_SSH_PORT"
'''

UTC = timezone.utc


class Fixture(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="cybexos-backup.")
        self.root = Path(self.temporary.name)
        self.home = self.root / "home/tester"
        self.home.mkdir(parents=True)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.log = self.root / "calls.log"
        self.log.touch()
        for name, source in (("restic", RESTIC), ("secret-tool", SECRET_TOOL),
                             ("notify-send", LOGGER), ("xdg-open", LOGGER), ("systemctl", LOGGER),
                             ("busctl", BUSCTL), ("ssh", SSH)):
            path = self.bin / name
            path.write_text(source)
            path.chmod(0o755)
        self.drive = self.root / "drive"
        self.drive.mkdir()
        self.power = self.root / "power_supply"
        self.power.mkdir()
        runtime = self.root / "runtime"
        runtime.mkdir(mode=0o700)
        self.environ = {
            "HOME": str(self.home), "PATH": f"{self.bin}:/usr/bin:/bin",
            "XDG_CONFIG_HOME": str(self.home / ".config"),
            "XDG_STATE_HOME": str(self.home / ".local/state"),
            "XDG_RUNTIME_DIR": str(runtime),
            "STUB_LOG": str(self.log), "STUB_STATE": str(self.root / "repository.json"),
            "STUB_KEYRING": str(self.root / "keyring"), "STUB_SSH_PORT": "1",
            "RESTIC_PASSWORD": "leaked-from-the-session",
        }
        self.patches = [patch.dict(os.environ, self.environ, clear=True),
                        patch.object(backup, "POWER_SUPPLY", self.power),
                        # The fixture's drive is a plain directory, not a mount.
                        patch.object(backup, "mount_point", lambda path: Path("/"))]
        for item in self.patches:
            item.start()
        self.context = backup.Context()

    def tearDown(self):
        for item in reversed(self.patches):
            item.stop()
        self.temporary.cleanup()

    def main(self, *argv, stdin=""):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err), \
                patch.object(sys, "stdin", io.StringIO(stdin)):
            try:
                status = backup.main(list(argv), program="cybexos-backup")
            except SystemExit as error:
                status = error.code
        return status, out.getvalue(), err.getvalue()

    def calls(self):
        return [json.loads(line) if line.startswith("{") else line
                for line in self.log.read_text().splitlines()]

    def restic_calls(self, command=None):
        return [call for call in self.calls() if isinstance(call, dict) and "command" in call
                and (command is None or call["command"] == command)]

    def set_up_drive(self):
        status, out, err = self.main("setup", "local", str(self.drive), "--json")
        self.assertEqual(status, 0, err)
        return json.loads(out)

    def config(self):
        return json.loads(self.context.config_path.read_text())

    def state(self):
        return json.loads(self.context.state_path.read_text())

    def battery(self, capacity, online="0"):
        (self.power / "BAT0").mkdir(exist_ok=True)
        (self.power / "BAT0/type").write_text("Battery\n")
        (self.power / "BAT0/status").write_text("Discharging\n")
        (self.power / "BAT0/capacity").write_text(f"{capacity}\n")
        (self.power / "AC").mkdir(exist_ok=True)
        (self.power / "AC/type").write_text("Mains\n")
        (self.power / "AC/online").write_text(online + "\n")


class Setup(Fixture):
    def test_a_new_repository_gets_a_keyring_password_and_a_separate_recovery_key(self):
        result = self.set_up_drive()
        config = self.config()
        repository = self.drive / "cybexos-backup"
        self.assertEqual(config["repository"], str(repository))
        self.assertTrue((repository / "config").is_file())
        key = result["recoveryKey"]
        self.assertRegex(key, r"^([0-9A-HJKMNP-TV-Z]{5}-){5}[0-9A-HJKMNP-TV-Z]{5}$")
        self.assertFalse(config["recoveryKeyConfirmed"])
        self.assertTrue(config["automatic"])
        stored = (self.root / "keyring" / f"application_cybexos-backup_repository_{config['keyId']}").read_text()
        self.assertGreaterEqual(len(stored), 40, "a strong random password")
        self.assertNotEqual(stored, key)
        init, = self.restic_calls("init")
        self.assertEqual(init["password"], stored)
        add = self.restic_calls("key")[0]
        self.assertEqual((add["password"], add["new"]), (stored, key))
        for call in self.restic_calls():
            # Secrets reach restic through pipes; a session's RESTIC_* stays out.
            self.assertNotIn(stored, call["argv"])
            self.assertNotIn(key, call["argv"])
            self.assertEqual(call["env"], ["RESTIC_PROGRESS_FPS"])
        self.assertEqual(os.stat(self.context.config_path).st_mode & 0o777, 0o600)
        self.assertNotIn(key, self.context.config_path.read_text(), "the key is shown once, never kept")
        status, _, _ = self.main("confirm-key")
        self.assertEqual(status, 0)
        self.assertTrue(self.config()["recoveryKeyConfirmed"])
        # A session that predates the timer gets it now, not at the next login.
        self.assertIn("systemctl --user start --no-block cybexos-backup.timer", self.calls())

    def test_existing_backups_need_their_recovery_key_and_get_a_new_keyring_password(self):
        key = self.set_up_drive()["recoveryKey"]
        self.context.config_path.unlink()
        status, out, _ = self.main("setup", "local", str(self.drive), "--json")
        self.assertEqual(status, backup.EXIT_EXISTING)
        self.assertTrue(json.loads(out)["existing"])
        status, out, _ = self.main("setup", "local", str(self.drive), "--existing", "--json",
                                   stdin="WRONG-KEY\n")
        self.assertEqual(status, 1)
        self.assertEqual(json.loads(out)["error"], "That recovery key does not open these backups.")
        # Typed in lower case with O for zero: normalized to the canonical key.
        typed = key.lower().replace("0", "o")
        status, out, err = self.main("setup", "local", str(self.drive), "--existing", "--json",
                                     stdin=typed + "\n")
        self.assertEqual(status, 0, err)
        self.assertEqual(json.loads(out)["recoveryKey"], "")
        self.assertTrue(self.config()["recoveryKeyConfirmed"])
        add = self.restic_calls("key")[-2]
        self.assertEqual(add["password"], key)
        self.assertNotEqual(add["new"], key)

    def test_destinations_are_validated_as_data(self):
        for target in ("~/Backups", str(self.home / "inside"), "relative/path", "/", "/usr/share"):
            status, _, _ = self.main("setup", "local", target)
            self.assertEqual(status, backup.EXIT_USAGE, target)
        for host in ("-oProxyCommand=evil", "host;reboot", "a b", ""):
            status, _, _ = self.main("setup", "sftp", host)
            self.assertEqual(status, backup.EXIT_USAGE, host)
        for path in ("../../etc", "a/../b", "~/x", "a;b"):
            status, _, _ = self.main("setup", "sftp", "nas", path)
            self.assertEqual(status, backup.EXIT_USAGE, path)
        self.assertEqual(self.restic_calls(), [], "nothing reaches restic before validation")

    def test_sftp_uses_the_users_ssh_configuration_without_prompts(self):
        status, out, err = self.main("setup", "sftp", "nas", "backups/laptop", "--json")
        self.assertEqual(status, 0, err)
        init, = self.restic_calls("init")
        self.assertIn("sftp:nas:backups/laptop", init["argv"])
        options = init["argv"][init["argv"].index("-o") + 1]
        for flag in ("BatchMode=yes", "StrictHostKeyChecking=yes"):
            self.assertIn(flag, options)

    def test_a_failed_init_leaves_no_keyring_item_or_configuration(self):
        with patch.dict(os.environ, {"STUB_RESTIC_FAIL": json.dumps(
                {"init": {"status": 1, "stderr": "Fatal: unable to open config file: permission denied"}})}):
            status, out, _ = self.main("setup", "local", str(self.drive), "--json")
        self.assertEqual(status, 1)
        self.assertEqual(json.loads(out)["error"], "CybexOS cannot write to the backup destination.")
        self.assertFalse(self.context.config_path.exists())
        self.assertEqual(list((self.root / "keyring").iterdir()), [])

    def test_changing_destination_clears_the_old_keyring_item(self):
        self.set_up_drive()
        old = self.config()["keyId"]
        other = self.root / "other"
        other.mkdir()
        (self.root / "repository.json").unlink()
        status, _, err = self.main("setup", "local", str(other), "--json")
        self.assertEqual(status, 0, err)
        names = [path.name for path in (self.root / "keyring").iterdir()]
        self.assertEqual(names, [f"application_cybexos-backup_repository_{self.config()['keyId']}"])
        self.assertNotIn(old, names[0])

    def test_recovery_key_rotation_removes_the_previous_key(self):
        first = self.set_up_drive()["recoveryKey"]
        status, out, err = self.main("recovery-key", "--json")
        self.assertEqual(status, 0, err)
        second = json.loads(out)["recoveryKey"]
        self.assertNotEqual(first, second)
        keys = json.loads((self.root / "repository.json").read_text())["keys"]
        self.assertIn(second, keys)
        self.assertNotIn(first, keys)
        self.assertFalse(self.config()["recoveryKeyConfirmed"])


@unittest.skipUnless(shutil.which("restic"), "real restic is not installed")
class ResticDataPolicy(unittest.TestCase):
    def test_real_snapshot_restores_saves_volumes_and_exports_but_skips_downloads(self):
        with tempfile.TemporaryDirectory(prefix="cybexos-backup-data-") as temporary:
            root = Path(temporary)
            home = root / "home"
            home.mkdir()
            context = backup.Context({"HOME": str(home), "XDG_RUNTIME_DIR": str(root / "run")})
            config = {"repository": str(root / "repository"), "host": "offline-fixture",
                      "destination": {"type": "local", "path": str(root / "repository"),
                                      "display": "offline fixture"}}
            included = ["Documents/personal.txt", "Games/bind-mounted-data/save",
                        ".local/share/containers/storage/volumes/game/_data/save",
                        ".local/share/docker/volumes/database/_data/personal",
                        ".config/containers/storage.conf", ".config/docker/daemon.json",
                        ".local/share/cybexos/plugin-data/mine/data"]
            excluded = [".cache/throwaway", ".local/share/Trash/files/deleted",
                        ".local/share/containers/storage/overlay/layer/diff/image",
                        ".local/share/docker/overlay2/layer/diff/image",
                        ".local/share/docker/buildkit/cache", "project/node_modules/package/data",
                        ".local/share/cybexos/runtime/vendor", "Documents/explicit-exclude",
                        "tagged-cache/data", ".var/app/example/cache/temporary"]
            for store in (".local/share/Steam", ".steam", ".steam/steam", ".steam/root",
                          ".var/app/com.valvesoftware.Steam/.local/share/Steam"):
                included += [store + "/userdata/123/456/remote/save",
                             store + "/steamapps/compatdata/456/pfx/drive_c/users/steamuser/save",
                             store + "/config/loginusers.vdf"]
                excluded += [store + "/steamapps/common/game/downloaded",
                             store + "/steamapps/downloading/456/download",
                             store + "/steamapps/shadercache/456/cache", store + "/appcache/cache"]
            for relative in included + excluded:
                path = home / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("sentinel: " + relative)
            (home / "tagged-cache/CACHEDIR.TAG").write_text(
                "Signature: 8a477f597d28d172789f06886806bc55\n")
            context.user_excludes.parent.mkdir(parents=True, exist_ok=True)
            context.user_excludes.write_text(str(home / "Documents/explicit-exclude") + "\n")
            # A supported database export, rather than a claim about live file consistency.
            export = home / "Documents/database-export.sqlite"
            with sqlite3.connect(":memory:") as live, sqlite3.connect(export) as destination:
                live.execute("CREATE TABLE personal (value TEXT)")
                live.execute("INSERT INTO personal VALUES ('saved record')")
                live.commit()
                live.backup(destination)
            included.append(str(export.relative_to(home)))
            # Isolate restic's own cache/config from the real account; no keyring,
            # network, mount, timer or service is involved in this fixture.
            with patch.dict(os.environ, {"HOME": str(home), "XDG_CACHE_HOME": str(root / "cache"),
                                         "XDG_CONFIG_HOME": str(home / ".config"),
                                         "PATH": os.environ.get("PATH", "/usr/bin:/bin")}, clear=True):
                repository = backup.Restic(config)
                password = "synthetic-offline-fixture-password"
                code, _, error = repository.run(["init"], password)
                self.assertEqual(code, 0, error)
                backup.run_backup(context, config, password)
                state = backup.load_state(context)
                self.assertEqual(state["lastResult"], "ok")
                self.assertEqual(state["lastSummary"]["unreadable"], 0)
                restore = root / "restore"
                code, _, error = repository.run(["restore", "latest", "--target", str(restore)], password)
                self.assertEqual(code, 0, error)
            restored = restore / str(home).lstrip("/")
            for relative in included:
                self.assertEqual((restored / relative).read_bytes(), (home / relative).read_bytes(), relative)
            for relative in excluded:
                self.assertFalse((restored / relative).exists(), relative)
            with sqlite3.connect(restored / export.relative_to(home)) as database:
                self.assertEqual(database.execute("SELECT value FROM personal").fetchall(), [("saved record",)])

    def test_real_unreadable_volume_directory_is_partial_and_readable_volume_restores(self):
        if os.geteuid() == 0:
            # Root bypasses mode 000. Run this same real-restic test as nobody,
            # with a readable copy of just the fixture/helper and no host changes.
            nobody = pwd.getpwnam("nobody")
            with tempfile.TemporaryDirectory(prefix="cybexos-backup-unprivileged-") as temporary:
                fixture = Path(temporary)
                fixture.chmod(0o755)
                for source, relative in ((Path(__file__), "tests/backup.py"),
                                         (HELPER, "assets/scripts/cybexos-backup")):
                    target = fixture / relative
                    target.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(source, target)
                    target.chmod(0o644)
                for directory in fixture.rglob("*"):
                    if directory.is_dir():
                        directory.chmod(0o755)
                result = subprocess.run(
                    [sys.executable, "-B", str(fixture / "tests/backup.py"),
                     "ResticDataPolicy." + self._testMethodName],
                    user=nobody.pw_uid, group=nobody.pw_gid, extra_groups=[],
                    env={"PATH": os.environ.get("PATH", "/usr/bin:/bin"),
                         "PYTHONDONTWRITEBYTECODE": "1"},
                    cwd=fixture, capture_output=True, text=True, timeout=120)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertNotIn("skipped", result.stderr)
            return

        self.assertNotEqual(os.geteuid(), 0)
        with tempfile.TemporaryDirectory(prefix="cybexos-backup-private-volume-") as temporary:
            root = Path(temporary)
            home = root / "home"
            home.mkdir()
            context = backup.Context({"HOME": str(home), "XDG_RUNTIME_DIR": str(root / "run")})
            config = {"version": 1, "keyId": "offline-fixture", "host": "offline-fixture",
                      "repository": str(root / "repository"),
                      "destination": {"type": "local", "path": str(root / "repository"),
                                      "mount": "/", "display": "offline fixture"}}
            readable = Path(".local/share/containers/storage/volumes/readable/_data/save")
            private = Path(".local/share/docker/volumes/private/_data")
            for relative in (readable, private / "record", private / "nested/record"):
                path = home / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("sentinel: " + str(relative))
            backup.write_json(context.config_path, config)
            with patch.dict(os.environ, {"HOME": str(home), "XDG_CACHE_HOME": str(root / "cache"),
                                         "XDG_CONFIG_HOME": str(home / ".config"),
                                         "PATH": os.environ.get("PATH", "/usr/bin:/bin")}, clear=True), \
                    patch.object(backup, "keyring_password", return_value="offline-fixture-password"):
                repository = backup.Restic(config)
                password = "offline-fixture-password"
                code, _, error = repository.run(["init"], password)
                self.assertEqual(code, 0, error)
                backup.back_up_now(context, False)
                complete = backup.load_state(context)
                self.assertEqual(complete["lastResult"], "ok")
                (home / private).chmod(0)
                try:
                    with self.assertRaises(PermissionError):
                        list((home / private).iterdir())
                    # Advancing the clock proves the complete timestamp was preserved.
                    with patch.object(backup, "utcnow", return_value=backup.utcnow() + timedelta(hours=1)):
                        with self.assertRaisesRegex(backup.Failure, "Backup incomplete"):
                            backup.back_up_now(context, False)
                    partial = backup.load_state(context)
                    self.assertEqual(partial["lastResult"], "partial")
                    self.assertEqual(partial["lastSuccess"], complete["lastSuccess"])
                    self.assertNotEqual(partial["lastAttempt"], complete["lastAttempt"])
                    self.assertEqual(partial["lastMaintenance"], complete["lastMaintenance"])
                    self.assertGreater(partial["lastSummary"]["unreadable"], 0)
                    errors = "\n".join(partial["lastSummary"]["errors"])
                    self.assertIn(str(private), errors)
                    self.assertIn("permission denied", errors.lower())
                    self.assertIn("missing files is unknown", partial["lastError"])
                    self.assertNotEqual(partial["lastSnapshot"], complete["lastSnapshot"])
                    code, lines, error = repository.run(["snapshots", "--json"], password)
                    self.assertEqual(code, 0, error)
                    self.assertEqual({snapshot["id"] for snapshot in json.loads("\n".join(lines))},
                                     {complete["lastSnapshot"], partial["lastSnapshot"]})
                    for snapshot in (complete["lastSnapshot"], partial["lastSnapshot"]):
                        restore = root / snapshot
                        code, _, error = repository.run(["restore", snapshot, "--target", str(restore)], password)
                        self.assertEqual(code, 0, error)
                        restored = restore / str(home).lstrip("/")
                        self.assertEqual((restored / readable).read_bytes(), (home / readable).read_bytes())
                        if snapshot == partial["lastSnapshot"]:
                            self.assertFalse((restored / private / "record").exists())
                            self.assertFalse((restored / private / "nested/record").exists())
                        else:
                            self.assertEqual((restored / private / "record").read_text(),
                                             "sentinel: " + str(private / "record"))
                finally:
                    (home / private).chmod(0o755)


class BackingUp(Fixture):
    def test_home_is_backed_up_with_the_default_excludes(self):
        self.set_up_drive()
        (self.context.user_excludes).parent.mkdir(parents=True, exist_ok=True)
        self.context.user_excludes.write_text("Videos/raw\n")
        status, out, err = self.main("now")
        self.assertEqual(status, 0, err)
        self.assertIn("Backed up 3 files", out)
        call, = self.restic_calls("backup")
        argv = call["argv"]
        self.assertEqual(argv[-1], str(self.home), "the whole home folder is the include")
        excludes = [argv[i + 1] for i, flag in enumerate(argv) if flag == "--exclude"]
        home = str(self.home)
        for expected in (home + "/.cache", home + "/.local/share/Trash",
                         home + "/.local/share/Steam/steamapps/common",
                         home + "/.local/share/containers/storage/overlay", home + "/.local/share/cybexos/runtime",
                         home + "/.config/**/Cache", "node_modules", str(self.drive / "cybexos-backup")):
            self.assertIn(expected, excludes)
        for flag in ("--exclude-caches", "--one-file-system", "--skip-if-unchanged"):
            self.assertIn(flag, argv)
        self.assertEqual(argv[argv.index("--exclude-file") + 1], str(self.context.user_excludes))
        self.assertEqual(argv[argv.index("--tag") + 1], "cybexos")
        state = self.state()
        self.assertEqual(state["lastResult"], "ok")
        self.assertEqual(state["lastSummary"]["files"], 3)
        self.assertFalse(self.context.progress_path.exists(), "progress belongs to a running backup")

    def test_setup_and_status_explain_data_coverage_and_database_consistency(self):
        setup = self.set_up_drive()
        status, text, err = self.main("status", "--json")
        self.assertEqual(status, 0, err)
        for report in (setup, json.loads(text)):
            self.assertIn("Proton saves", report["coverage"])
            self.assertIn("container volumes", report["coverage"])
            self.assertIn("writable layers", report["coverage"])
            self.assertIn("Live database files may be inconsistent", report["consistency"])
            self.assertIn("pg_dump", report["consistency"])
            self.assertIn("readable rootless container volumes", report["coverage"])
            self.assertIn("subordinate UIDs require readable exports", report["consistency"])
            self.assertIn("alone does not make those files readable", report["consistency"])
        status, text, err = self.main("status")
        self.assertEqual(status, 0, err)
        self.assertIn("Live database files may be inconsistent", text)

    def test_retention_prunes_at_most_weekly(self):
        self.set_up_drive()
        self.main("now")
        forget, = self.restic_calls("forget")
        argv = forget["argv"]
        for flag, count in (("--keep-daily", "7"), ("--keep-weekly", "4"), ("--keep-monthly", "6")):
            self.assertEqual(argv[argv.index(flag) + 1], count)
        self.assertIn("--prune", argv)
        self.assertEqual(argv[argv.index("--host") + 1], self.config()["host"])
        self.assertEqual(len(self.restic_calls("check")), 1)
        self.main("now")
        self.assertEqual(len(self.restic_calls("forget")), 1, "pruning waits a week")

    def test_incomplete_snapshot_keeps_prior_success_and_actual_stderr_read_errors(self):
        self.set_up_drive()
        previous = backup.stamp(backup.utcnow() - timedelta(days=2))
        backup.save_state(self.context, {"lastSuccess": previous})
        errors = [{"message_type": "error", "item": f"/home/tester/private-{index}/_data",
                   "error": {"message": "open: permission denied"}} for index in range(55)]
        with patch.dict(os.environ, {"STUB_BACKUP_STATUS": "3", "STUB_BACKUP_ERRORS": json.dumps(errors)}):
            status, out, err = self.main("now", "--notify")
        self.assertEqual(status, backup.EXIT_FAILED)
        self.assertNotIn("Backed up", out)
        self.assertIn("Backup incomplete", err)
        self.assertIn("55 read error(s)", err)
        state = self.state()
        self.assertEqual(state["lastResult"], "partial")
        self.assertEqual(state["lastSuccess"], previous)
        self.assertEqual(state["lastSnapshot"], "ab" * 32)
        self.assertEqual(state["lastSummary"]["unreadable"], 55, "count every error, not just the stderr tail")
        self.assertEqual(len(state["lastSummary"]["errors"]), 40, "keep bounded diagnostic detail")
        self.assertIn("private-54/_data: open: permission denied", state["lastSummary"]["errors"][-1])
        self.assertEqual(self.restic_calls("forget"), [], "partial runs never prune prior snapshots")
        self.assertTrue(backup.due(state, backup.utcnow()))
        notices = [call for call in self.calls() if isinstance(call, str) and call.startswith("notify-send")]
        self.assertEqual(len(notices), 1)
        self.assertIn("Backup incomplete", notices[0])
        self.assertIn("--urgency=normal", notices[0])
        status, text, _ = self.main("status")
        self.assertEqual(status, 0)
        self.assertIn("Last attempt: partial: Backup incomplete", text)

    def test_incomplete_snapshot_without_structured_errors_has_an_unknown_count(self):
        self.set_up_drive()
        with patch.dict(os.environ, {"STUB_BACKUP_STATUS": "3", "STUB_BACKUP_STDERR":
                                    "Warning: at least one source file could not be read\n"}):
            status, _, err = self.main("now")
        self.assertEqual(status, backup.EXIT_FAILED)
        state = self.state()
        self.assertEqual(state["lastResult"], "partial")
        self.assertIsNone(state["lastSummary"]["unreadable"])
        self.assertNotIn("lastSuccess", state)
        self.assertIn("count is unknown", err)
        self.assertIn("Warning: at least one source file could not be read", state["lastSummary"]["errors"][0])
        self.assertNotIn("0 could not be read", err)
        # A later complete snapshot clears the warning and becomes the success.
        status, _, err = self.main("now")
        self.assertEqual(status, 0, err)
        state = self.state()
        self.assertEqual(state["lastResult"], "ok")
        self.assertTrue(state["lastSuccess"])
        self.assertEqual(state["lastSummary"]["unreadable"], 0)
        self.assertEqual(state["lastSummary"]["errors"], [])

    def test_reported_read_error_cannot_be_success_even_with_exit_zero(self):
        self.set_up_drive()
        errors = [{"message_type": "error", "item": "/home/tester/private", "error": "permission denied"}]
        with patch.dict(os.environ, {"STUB_BACKUP_ERRORS": json.dumps(errors)}):
            status, _, err = self.main("now")
        self.assertEqual(status, backup.EXIT_FAILED)
        self.assertIn("Backup incomplete", err)
        self.assertEqual(self.state()["lastSummary"]["unreadable"], 1)
        self.assertEqual(self.state()["lastSummary"]["errors"], ["/home/tester/private: permission denied"])

    def test_a_failure_is_explained_and_notified_once(self):
        self.set_up_drive()
        with patch.dict(os.environ, {"STUB_RESTIC_FAIL": json.dumps(
                {"backup": {"status": 1, "stderr": "Fatal: write /x: no space left on device"}})}):
            status, _, err = self.main("now", "--notify")
        self.assertEqual(status, 1)
        self.assertIn("The backup destination is full.", err)
        state = self.state()
        self.assertEqual((state["lastResult"], state["lastError"]),
                         ("failed", "The backup destination is full."))
        notices = [call for call in self.calls() if isinstance(call, str) and call.startswith("notify-send")]
        self.assertEqual(len(notices), 1)
        self.assertIn("--action=default=Open backup settings", notices[0])

    def test_one_run_at_a_time(self):
        self.set_up_drive()
        with backup.exclusive(self.context):
            self.assertTrue(backup.busy(self.context))
            status, _, err = self.main("now")
            self.assertEqual(status, backup.EXIT_BUSY)
            self.assertIn("already running", err)
        self.assertFalse(backup.busy(self.context))

    def test_status_is_offline_and_complete(self):
        status, out, _ = self.main("status", "--json")
        self.assertEqual(json.loads(out)["configured"], False)
        self.set_up_drive()
        self.main("now")
        before = len(self.restic_calls())
        status, out, _ = self.main("status", "--json")
        report = json.loads(out)
        self.assertEqual(len(self.restic_calls()), before, "status never runs restic")
        for key in ("destination", "automatic", "reachable", "lastSuccess", "nextDue", "running",
                    "recoveryKeyConfirmed", "lastError", "stale"):
            self.assertIn(key, report)
        self.assertTrue(report["reachable"])
        due = backup.parse_time(report["nextDue"])
        last = backup.parse_time(report["lastSuccess"])
        self.assertEqual(due - last, backup.DUE_AFTER)
        self.main("automatic", "off")
        self.assertEqual(json.loads(self.main("status", "--json")[1])["nextDue"], "")


class Scheduled(Fixture):
    def setUp(self):
        super().setUp()
        # One clock for the timer and everything the helper records, set in
        # the morning so an added half hour never crosses midnight.
        self.now = datetime(2026, 10, 13, 9, 0, tzinfo=UTC)
        self.clock = [self.now]
        clock = patch.object(backup, "utcnow", lambda: self.clock[0])
        clock.start()
        self.addCleanup(clock.stop)
        self.set_up_drive()
        self.main("confirm-key")

    def scheduled(self, now=None):
        self.clock[0] = now or self.now
        backup.scheduled(self.context, now=self.clock[0])

    def backups(self):
        return len(self.restic_calls("backup"))

    def notices(self):
        return [call for call in self.calls() if isinstance(call, str) and call.startswith("notify-send")]

    def test_a_due_backup_runs_once_a_day(self):
        self.scheduled()
        self.assertEqual(self.backups(), 1)
        self.scheduled(self.now + timedelta(hours=1))
        self.assertEqual(self.backups(), 1, "not due again within the day")
        self.scheduled(self.now + timedelta(hours=24))
        self.assertEqual(self.backups(), 2)
        self.assertEqual(self.notices(), [], "a successful run is silent")

    def test_partial_snapshots_remain_due_and_notify_without_claiming_success(self):
        with patch.dict(os.environ, {"STUB_BACKUP_STATUS": "3"}):
            self.scheduled()
            self.scheduled(self.now + timedelta(hours=1))
        self.assertEqual(self.backups(), 2, "a partial snapshot does not defer a complete backup")
        self.assertEqual(self.state()["lastResult"], "partial")
        self.assertNotIn("lastSuccess", self.state())
        self.assertEqual(len(self.notices()), 1, "retries keep the once-a-day notification policy")
        self.assertIn("Backup incomplete", self.notices()[0])

    def test_automatic_off_skips_the_backup(self):
        self.main("automatic", "off")
        self.scheduled()
        self.assertEqual(self.backups(), 0)

    def test_an_absent_drive_is_skipped_quietly(self):
        config = self.config()
        config["destination"].update(mount=str(self.root / "unmounted"), label="T7")
        backup.write_json(self.context.config_path, config)
        with patch.object(backup.os.path, "ismount", lambda path: False):
            self.scheduled()
            self.assertEqual(self.backups(), 0)
            self.assertEqual(self.state()["lastSkip"], "unreachable")
            self.assertEqual(self.notices(), [])
            status, _, err = self.main("now")
        self.assertEqual(status, 1)
        self.assertIn("T7 is not connected.", err)

    def test_low_battery_is_skipped_but_ac_or_charge_is_not(self):
        self.battery(20)
        self.scheduled()
        self.assertEqual((self.backups(), self.state()["lastSkip"]), (0, "battery"))
        self.battery(20, online="1")
        self.scheduled()
        self.assertEqual(self.backups(), 1)
        self.battery(80)
        self.assertFalse(backup.low_battery(self.power))
        # A wireless mouse's battery says nothing about this computer.
        mouse = self.power / "hidpp_battery_0"
        mouse.mkdir()
        (mouse / "type").write_text("Battery\n")
        (mouse / "scope").write_text("Device\n")
        (mouse / "capacity").write_text("5\n")
        self.assertFalse(backup.low_battery(self.power))

    def sftp(self):
        (self.root / "repository.json").unlink()
        status, _, err = self.main("setup", "sftp", "nas", "--json")
        self.assertEqual(status, 0, err)
        self.main("confirm-key")

    def test_metered_networks_and_unreachable_servers_are_skipped_for_ssh(self):
        self.sftp()
        with patch.dict(os.environ, {"STUB_METERED": "1"}):
            self.scheduled()
        self.assertEqual((self.backups(), self.state()["lastSkip"]), (0, "metered"))
        # Nothing listens on the stub's port: unreachable, skipped quietly.
        self.scheduled()
        self.assertEqual((self.backups(), self.state()["lastSkip"]), (0, "unreachable"))
        listener = socket.socket()
        listener.bind(("127.0.0.1", 0))
        listener.listen()
        with listener, patch.dict(os.environ, {"STUB_SSH_PORT": str(listener.getsockname()[1])}):
            self.scheduled()
        self.assertEqual(self.backups(), 1)
        self.assertEqual(self.notices(), [])

    def test_a_locked_keyring_waits_without_a_prompt(self):
        with patch.dict(os.environ, {"STUB_KEYRING_LOCKED": "1"}):
            self.scheduled()
        self.assertEqual((self.backups(), self.state()["lastSkip"]), (0, "keyring"))
        tools = [call["secret-tool"] for call in self.calls()
                 if isinstance(call, dict) and "secret-tool" in call]
        self.assertEqual(tools[-1], "search", "a scheduled run never calls the prompting lookup")

    def test_a_manual_backup_names_a_locked_keyring_and_a_missing_password(self):
        with patch.dict(os.environ, {"STUB_KEYRING_LOCKED": "1"}):
            status, _, err = self.main("now")
        self.assertEqual(status, 1)
        self.assertIn("The keyring is locked. Unlock it and try again.", err)
        for item in (self.root / "keyring").iterdir():
            item.unlink()
        status, _, err = self.main("now")
        self.assertIn("missing from the keyring", err)
        self.assertEqual(self.backups(), 0)

    def test_repeated_failures_notify_once_a_day(self):
        failing = {"STUB_RESTIC_FAIL": json.dumps(
            {"backup": {"status": 1, "stderr": "ssh: Could not resolve hostname nas"}})}
        with patch.dict(os.environ, failing):
            self.scheduled()
            self.scheduled(self.now + timedelta(minutes=5))
            self.assertEqual(len(self.notices()), 1)
            self.assertIn("Backup failed", self.notices()[0])
            self.scheduled(self.now + timedelta(days=1, minutes=5))
        self.assertEqual(len(self.notices()), 2)

    def test_a_week_without_a_backup_reminds_once_a_day(self):
        self.main("automatic", "off")
        state = {"lastSuccess": backup.stamp(self.now - timedelta(days=6))}
        backup.save_state(self.context, state)
        self.scheduled()
        self.assertEqual(self.notices(), [])
        later = self.now + timedelta(days=2)
        self.scheduled(later)
        self.scheduled(later + timedelta(minutes=30))
        self.assertEqual(len(self.notices()), 1)
        self.assertIn("Your last backup was 8 days ago. Automatic backups are off.", self.notices()[0])
        self.scheduled(later + timedelta(days=1))
        self.assertEqual(len(self.notices()), 2)

    def test_a_reminder_names_the_drive_to_connect(self):
        config = self.config()
        config["destination"].update(mount=str(self.root / "unmounted"), label="T7")
        backup.write_json(self.context.config_path, config)
        backup.save_state(self.context, {"lastSuccess": backup.stamp(self.now - timedelta(days=9))})
        with patch.object(backup.os.path, "ismount", lambda path: False):
            self.scheduled()
        notice, = self.notices()
        self.assertIn("Your last backup was 9 days ago. Connect T7 to back up.", notice)

    def test_unconfigured_accounts_do_nothing(self):
        self.context.config_path.unlink()
        self.log.write_text("")
        self.scheduled()
        self.assertEqual(self.calls(), [])


class Restoring(Fixture):
    def setUp(self):
        super().setUp()
        self.set_up_drive()
        state = json.loads((self.root / "repository.json").read_text())
        state["snapshots"] = [
            {"id": "a" * 64, "time": "2026-10-12T09:05:00.123456789Z", "hostname": "other",
             "paths": [str(self.home)], "summary": {"total_bytes_processed": 10}},
            {"id": "b" * 64, "time": "2026-10-13T10:05:00Z", "hostname": self.config()["host"],
             "paths": [str(self.home)], "summary": {"total_bytes_processed": 10}},
        ]
        (self.root / "repository.json").write_text(json.dumps(state))
        (self.home / "Documents").mkdir()
        (self.home / "Documents/a.txt").write_text("current")

    def test_restore_goes_into_a_new_folder_and_opens_files(self):
        status, out, err = self.main("restore", "latest", "--path", "Documents", "--open")
        self.assertEqual(status, 0, err)
        call, = self.restic_calls("restore")
        argv = call["argv"]
        self.assertEqual(argv[argv.index("restore") + 1], "b" * 64 + ":" + str(self.home))
        self.assertEqual(argv[argv.index("--include") + 1], "/Documents")
        self.assertEqual(argv[argv.index("--overwrite") + 1], "never")
        target = Path(argv[argv.index("--target") + 1])
        self.assertEqual(target.parent, self.home / "Restored")
        self.assertEqual((self.home / "Documents/a.txt").read_text(), "current", "home is untouched")
        self.assertEqual((target / "Documents/a.txt").read_text(), "restored")
        # Files opens detached from the restore; wait for the stub to log it.
        for _ in range(100):
            if f"xdg-open {target / 'Documents'}" in self.calls():
                break
            time.sleep(0.05)
        self.assertIn(f"xdg-open {target / 'Documents'}", self.calls())
        self.main("restore", "b" * 8)
        self.assertEqual(sorted(path.name for path in (self.home / "Restored").iterdir()),
                         [target.name, target.name + "-2"], "a second restore never reuses a folder")

    def test_restore_paths_stay_inside_the_backed_up_home(self):
        for path in ("../etc", "Documents/../../x", "*", "Doc?", "a\\b"):
            status, _, _ = self.main("restore", "latest", "--path", path)
            self.assertEqual(status, backup.EXIT_USAGE, path)
        status, _, _ = self.main("restore", "latest;rm")
        self.assertEqual(status, backup.EXIT_USAGE)
        self.assertEqual(self.restic_calls("restore"), [])
        self.assertEqual(backup.restore_path("~/Documents/./Taxes/"), "Documents/Taxes")
        self.assertEqual(backup.restore_path("/Documents"), "Documents")

    def test_a_symlinked_restore_folder_is_refused(self):
        outside = self.root / "outside"
        outside.mkdir()
        (self.home / "Restored").symlink_to(outside)
        status, _, err = self.main("restore", "latest")
        self.assertEqual(status, 1)
        self.assertIn("must be a folder", err)
        self.assertEqual(list(outside.iterdir()), [])

    def test_nothing_restored_is_an_error_and_leaves_no_empty_folder(self):
        with patch.dict(os.environ, {"STUB_RESTORE_FILES": "[]"}):
            status, _, err = self.main("restore", "latest", "--path", "Missing", "--notify")
        self.assertEqual(status, 1)
        self.assertIn("Nothing at Missing is in that backup.", err)
        self.assertEqual(list((self.home / "Restored").iterdir()), [])
        self.assertFalse(self.state()["lastRestore"]["ok"])

    def test_snapshots_list_every_host_newest_first(self):
        status, out, _ = self.main("snapshots", "--json")
        snapshots = json.loads(out)["snapshots"]
        self.assertEqual([entry["id"][0] for entry in snapshots], ["b", "a"])
        self.assertEqual(snapshots[1]["host"], "other")


class Compatibility(Fixture):
    def test_app_backup_keeps_its_age_recipient_contract(self):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            status = backup.main([], program="/home/tester/.local/bin/app-backup")
        self.assertEqual(status, 2)
        self.assertIn("Set AGE_RECIPIENT to an age public recipient.", err.getvalue())
        (self.bin / "age").write_text("#!/bin/sh\nprintf 'age %s\\n' \"$*\" >> \"$STUB_LOG\"\n"
                                      "cat > /dev/null; : > \"$4\"\n")
        (self.bin / "age").chmod(0o755)
        environ = dict(os.environ, AGE_RECIPIENT="age1example")
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            status = backup.main([], environ=environ, program="browser-backup")
        self.assertEqual(status, 1)
        self.assertIn("No browser profiles found", err.getvalue())
        (self.home / ".mozilla/firefox").mkdir(parents=True)
        output = self.root / "profiles.tar.age"
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            status = backup.main([str(output)], environ=environ, program="app-backup")
        self.assertEqual(status, 0)
        self.assertIn(f"Encrypted opt-in browser backup: {output}", out.getvalue())
        self.assertIn(f"age -r age1example -o {output}", self.calls())

    def test_the_command_line_runs_as_a_script(self):
        result = subprocess.run([sys.executable, "-I", str(HELPER), "status", "--json"],
                                env=self.environ, capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(json.loads(result.stdout)["configured"])
        result = subprocess.run([sys.executable, "-I", str(HELPER), "excludes"],
                                env=self.environ, capture_output=True, text=True, check=False)
        self.assertIn(str(self.home) + "/.cache", result.stdout.splitlines())


class Pure(unittest.TestCase):
    def test_recovery_keys_are_long_and_unambiguous(self):
        keys = {backup.new_recovery_key() for _ in range(50)}
        self.assertEqual(len(keys), 50)
        for key in keys:
            self.assertEqual(backup.normalize_recovery_key(key.lower().replace("-", " ")), key)
            self.assertFalse(set(key) & set("ILOU"))
        self.assertEqual(backup.normalize_recovery_key("  custom restic password "), "custom restic password")

    def test_failures_read_as_plain_words(self):
        explain = backup.explain
        self.assertIn("does not trust nas", explain(1, "Host key verification failed.", "nas"))
        self.assertEqual(explain(1, "tester@nas: Permission denied (publickey).", "nas"),
                         "nas refused your SSH key.")
        self.assertEqual(explain(12, ""), "The saved password does not open this backup. "
                         "Connect it again with its recovery key.")
        self.assertEqual(explain(1, "Fatal: something odd happened"), "Something odd happened.")
        self.assertEqual(explain(7, ""), "The backup failed (restic exit 7).")

    def test_drive_labels_come_from_udisks_mount_points(self):
        self.assertEqual(backup.drive_label("/run/media/tester/T7"), "T7")
        self.assertEqual(backup.drive_label("/media/Backup"), "Backup")
        self.assertEqual(backup.drive_label("/"), "")
        self.assertEqual(backup.drive_label("/mnt/data"), "")


if __name__ == "__main__":
    unittest.main()
