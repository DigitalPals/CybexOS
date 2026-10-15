"""Source-only fixtures. No real Anaconda, devices, mounts, services or secrets."""

import copy
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import types
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent


def load(name, relative):
    loader = importlib.machinery.SourceFileLoader(name, str(ROOT / relative))
    spec = importlib.util.spec_from_loader(name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


backend = load("installer_backend", "live-rootfs/usr/libexec/cybexos-installer-backend")
target = load("installer_target", "live-rootfs/usr/libexec/cybexos-installer-target")
tree = load("installer_tree", "install-live-rootfs")
browser = load("installer_browser", "live-rootfs/usr/bin/cybexos-installer-browser")
DISK = dict(
    name="vda",
    path="/dev/vda",
    size=100 * 1024**3,
    model="Fixture disk",
    serial="FIXTURE-ONLY",
    wwn="",
    device_id="disk-vda",
)
CHOICES = dict(
    disks=[DISK],
    keyboards=[{"id": "us", "label": "English"}, {"id": "nl", "label": "Dutch"}],
    locales=["en_US.UTF-8", "nl_NL.UTF-8"],
    locale="en_US.UTF-8",
    keyboard="us",
    timezones=["Europe/Amsterdam", "UTC"],
    timezone="UTC",
)
ACCOUNT = dict(
    username="alice",
    password="fixture phrase never real",
    confirm="fixture phrase never real",
    keyboard="us",
    locale="en_US.UTF-8",
    timezone="UTC",
    hostname="cybexos",
    disk="vda",
    encrypted=True,
)


class FakeBackend:
    def __init__(self):
        self.choices = copy.deepcopy(CHOICES)
        self.started = False
        self.failed = False
        self.rescanned = False
        self.actions = [{"action-description": "create"}]
        self.analysis = {"free": 1024**3, "partitions": [
            {"id": "vda1", "path": "/dev/vda1", "size": 512 * 1024**2, "min_size": 512 * 1024**2,
             "shrinkable": False, "filesystem": "efi"},
            {"id": "vda3", "path": "/dev/vda3", "size": 400 * 1024**3, "min_size": 100 * 1024**3,
             "shrinkable": True, "filesystem": "ntfs"},
            {"id": "vda4", "path": "/dev/vda4", "size": 20 * 1024**3, "min_size": 2 * 1024**3,
             "shrinkable": True, "filesystem": "ntfs"},
        ]}

    def inventory(self):
        return self.choices

    def reset(self):
        pass

    def rescan(self):
        self.rescanned = True

    def keyboard(self, layout):
        return {"keyboard": layout, "boot_keyboard": layout}

    def plan(self, account, credentials, disk):
        if self.failed:
            raise RuntimeError("fixture failure")
        self.credentials = dict(credentials)
        self.planned = account
        return dict(
            partitioning="/fixture",
            actions=copy.deepcopy(self.actions),
            errors=[],
            warnings=[],
            boot_keyboard="us",
        )

    def alongside(self, disk):
        return copy.deepcopy(self.analysis)

    def check_plan(self, state):
        pass

    def start_install(self, state):
        self.started = True

    def run_install(self, state, progress, store):
        progress(1, 2, "Installing fixture")
        if self.failed:
            raise RuntimeError("fixture failure")


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.state = backend.State(Path(self.temporary.name))
        self.adapter = FakeBackend()
        self.installer = backend.Installer(self.adapter, self.state)

    def plan(self, **changes):
        return self.installer.plan({**ACCOUNT, **changes})

    def commit(self, plan, **changes):
        return self.installer.install(
            dict(token=plan["token"], confirmed_disk="vda", erase_confirmed=True, **changes)
        )

    def test_plan_is_non_destructive_and_persists_no_password(self):
        data = copy.deepcopy(ACCOUNT)
        result = self.installer.plan(data)
        self.assertEqual(result["phase"], "review")
        self.assertFalse(self.adapter.started)
        self.assertNotIn("password", data)
        self.assertNotIn(ACCOUNT["password"], (self.state.directory / "state.json").read_text())
        self.assertEqual((self.state.directory / "state.json").stat().st_mode & 0o777, 0o600)

    def test_invalid_account_cannot_reach_review(self):
        cases = [
            {"username": "root"},
            {"username": "liveuser"},
            {"username": "sddm"},
            {"username": "alice\nuser"},
            {"password": "short", "confirm": "short"},
            {"confirm": "different"},
            {"keyboard": "invented"},
            {"locale": "invented"},
            {"timezone": "../etc/passwd"},
            {"hostname": "host;command"},
            {"encrypted": "false"},
        ]
        for changes in cases:
            with self.subTest(changes=list(changes)), self.assertRaises(backend.Invalid):
                self.plan(**changes)
        self.assertFalse(self.adapter.started)

    def test_locale_keyboard_and_unencrypted_choices_are_preserved(self):
        plan = self.plan(
            keyboard="nl", locale="nl_NL.UTF-8", timezone="Europe/Amsterdam", encrypted=False
        )
        self.assertEqual(plan["account"]["locale"], "nl_NL.UTF-8")
        self.assertFalse(plan["account"]["encrypted"])
        self.assertFalse(plan["account"]["passwordless_wheel"])

    def test_sudo_requires_explicit_boolean_opt_in(self):
        self.assertTrue(self.plan(passwordless_wheel=True)["account"]["passwordless_wheel"])
        for invalid in ("true", 1, None):
            with self.subTest(invalid=invalid), self.assertRaises(backend.Invalid):
                self.plan(passwordless_wheel=invalid)

    def test_rescan_invalidates_confirmation_and_returns_new_inventory(self):
        old = self.plan()
        self.assertEqual(self.installer.rescan()["disks"][0]["name"], "vda")
        self.assertTrue(self.adapter.rescanned)
        with self.assertRaises(backend.Invalid):
            self.commit(old)

    def test_keyboard_change_invalidates_old_confirmation(self):
        plan = self.plan()
        self.assertEqual(self.installer.keyboard({"keyboard": "nl"})["boot_keyboard"], "nl")
        with self.assertRaises(backend.Invalid):
            self.commit(plan)

    def test_live_keyboard_command_runs_as_live_user_with_validated_values(self):
        calls = []

        def run(command, **kwargs):
            calls.append(command)
            output = (
                json.dumps([{"pid": os.getpid(), "instance": "fixture_instance-1"}])
                if command[-1] == "instances"
                else "ok\n"
            )
            return types.SimpleNamespace(stdout=output, returncode=0)

        with patch.object(
            backend.pwd, "getpwnam", return_value=types.SimpleNamespace(pw_uid=os.getuid())
        ):
            backend.apply_live_keyboard("us (dvorak)", run)
        # Lua-configured Hyprland refuses `hyprctl keyword`; one eval sets both.
        self.assertEqual(
            calls[-1][-2:],
            ["eval", 'hl.config({ input = { kb_layout = "us", kb_variant = "dvorak" } })'],
        )
        self.assertEqual(len(calls), 2)
        self.assertTrue(
            all(command[:4] == ["runuser", "-u", "liveuser", "--"] for command in calls)
        )
        with self.assertRaises(backend.Invalid):
            backend.apply_live_keyboard("us; bad", run)

    def test_live_keyboard_rejected_by_compositor_is_reported(self):
        def run(command, **kwargs):
            if command[-1] == "instances":
                return types.SimpleNamespace(
                    stdout=json.dumps([{"pid": os.getpid(), "instance": "fixture"}]), returncode=0
                )
            return types.SimpleNamespace(stdout=reply, returncode=code)

        for reply, code in (
            ("keyword can't work with non-legacy parsers. Use eval.\n", 0),
            ("error: unknown config key 'input.kb_layout'\n", 7),
        ):
            with patch.object(
                backend.pwd, "getpwnam", return_value=types.SimpleNamespace(pw_uid=os.getuid())
            ), self.assertRaises(backend.Invalid):
                backend.apply_live_keyboard("nl", run)

    def test_password_control_characters_rejected_without_echo(self):
        with self.assertRaises(backend.Invalid) as caught:
            self.plan(password="long secret\nvalue", confirm="long secret\nvalue")
        self.assertNotIn("secret", str(caught.exception))

    def test_missing_or_small_disk_is_rejected(self):
        with self.assertRaises(backend.Invalid):
            self.plan(disk="sda")
        self.adapter.choices["disks"][0]["size"] = 1024
        with self.assertRaises(backend.Invalid):
            self.plan()

    def test_changed_disk_and_stale_confirmation_are_rejected(self):
        plan = self.plan()
        self.adapter.choices["disks"][0]["serial"] = "REPLACED"
        with self.assertRaises(backend.Invalid):
            self.commit(plan)
        self.assertFalse(self.adapter.started)
        self.adapter.choices["disks"][0]["serial"] = "FIXTURE-ONLY"
        new = self.plan()
        self.adapter.choices["disks"][0]["partitions"] = [
            {"path": "/dev/vda1", "size": 1024, "filesystem": "ext4"}
        ]
        with self.assertRaises(backend.Invalid):
            self.commit(new)

    def test_status_and_diagnostics_redact_policy_and_worker_text(self):
        plan = self.plan(passwordless_wheel=True)
        self.commit(plan)
        state = self.state.read()
        state.update(step=1, total=2, message="private /home/alice fixture phrase never real")
        self.state.write(state)
        status = backend.installation_status(self.state, lambda *args, **kwargs: types.SimpleNamespace(stdout="active\n"))
        self.assertEqual(status["phase"], "installing")
        self.assertNotIn("account", status)
        self.assertNotIn("private", json.dumps(status))
        report = backend.diagnostics(self.state, lambda *args, **kwargs: types.SimpleNamespace(
            stdout="ActiveState=active\nSubState=running\nResult=success\nEnvironment=SECRET=leak\n"))
        self.assertEqual(report["worker"], {"ActiveState": "active", "SubState": "running", "Result": "success"})
        self.assertNotIn("alice", json.dumps(report))
        self.assertNotIn("SECRET", json.dumps(report))

    def test_confirmation_and_replay_protection(self):
        plan = self.plan()
        with self.assertRaises(backend.Invalid):
            self.installer.install({"token": plan["token"], "confirmed_disk": "vda"})
        with self.assertRaises(backend.Invalid):
            self.installer.install(
                {"token": "other", "confirmed_disk": "vda", "erase_confirmed": True}
            )
        self.commit(plan)
        self.assertTrue(self.adapter.started)
        with self.assertRaises(backend.Invalid):
            self.commit(plan)
        with self.assertRaises(backend.Invalid):
            self.installer.reset()

    def test_failed_plan_retries_but_never_reuses_old_token(self):
        old = self.plan()
        self.adapter.failed = True
        with self.assertRaises(RuntimeError):
            self.plan()
        with self.assertRaises(backend.Invalid):
            self.commit(old)
        self.adapter.failed = False
        new = self.plan()
        self.assertNotEqual(old["token"], new["token"])

    def test_worker_completion_and_failure_are_durable(self):
        self.commit(self.plan())
        self.assertEqual(self.installer.worker()["phase"], "complete")
        self.state.write({"phase": "setup"})
        self.commit(self.plan())
        self.adapter.failed = True
        with self.assertRaises(RuntimeError):
            self.installer.worker()
        self.assertEqual(self.state.read()["phase"], "failed-install")
        with self.assertRaises(backend.Invalid):
            self.plan()

    def test_failed_worker_names_its_step_and_explaining_log(self):
        self.commit(self.plan())
        self.adapter.failed = True
        self.adapter.run_install = lambda state, progress, store: (
            progress(40, 41, "Running post-installation scripts"),
            (_ for _ in ()).throw(RuntimeError("There was an error running the kickstart script at line 1.")))
        with self.assertRaises(RuntimeError):
            self.installer.worker()
        state = self.state.read()
        self.assertEqual((state["phase"], state["failed_step"], state["log_source"]),
                         ("failed-install", "Running post-installation scripts", "post"))
        self.assertIn("Running post-installation scripts", state["message"])
        status = backend.public_status(state)
        self.assertEqual(status["log_source"], "post")
        self.assertEqual(status["failed_step"], "Running post-installation scripts")
        steps = (Path(self.temporary.name) / "worker.log").read_text()
        self.assertIn("Installing to /dev/vda (Fixture disk), encrypted.", steps)
        self.assertIn("[40/41] Running post-installation scripts", steps)
        self.assertIn("RuntimeError: There was an error running the kickstart script at line 1.", steps)
        self.assertNotIn(ACCOUNT["password"], steps + json.dumps(state))

    def test_failed_worker_keeps_free_form_text_out_of_status_and_state(self):
        self.commit(self.plan())
        private = "private /home/alice fixture phrase never real"
        def fail(state, progress, store):
            progress(1, 2, private)
            raise RuntimeError(private)
        self.adapter.run_install = fail
        with self.assertRaises(RuntimeError):
            self.installer.worker()
        state = self.state.read()
        self.assertNotIn(private, json.dumps(state))
        self.assertNotIn(private, json.dumps(backend.public_status(state)))
        self.assertEqual(backend.public_status(state)["log_source"], "steps")
        # Only the explicitly opened log carries free-form diagnostic text.
        self.assertIn(private, (Path(self.temporary.name) / "worker.log").read_text())

    def test_new_installation_starts_a_new_step_log(self):
        log = Path(self.temporary.name) / "worker.log"
        log.write_text("an earlier attempt\n")
        self.commit(self.plan())
        self.installer.worker()
        self.assertNotIn("an earlier attempt", log.read_text())
        self.assertTrue(log.read_text().rstrip().endswith("Installation finished."))
        # Other failures point at the step log itself.
        self.assertEqual(backend.failure_state({"message": "Installing the software"})["log_source"], "steps")

    def test_disconnected_browser_cannot_allow_retry_after_worker_loss(self):
        self.commit(self.plan())
        def active(*args, **kwargs):
            return types.SimpleNamespace(stdout="active\n")
        def stopped(*args, **kwargs):
            return types.SimpleNamespace(stdout="inactive\n")
        self.assertEqual(backend.installation_status(self.state, active)["phase"], "installing")
        self.assertEqual(backend.installation_status(self.state, stopped)["phase"], "installing")
        state = self.state.read()
        state["worker_queued_at"] = 0
        self.state.write(state)
        self.assertEqual(
            backend.installation_status(self.state, stopped)["phase"], "failed-install"
        )
        self.assertEqual(self.state.read()["phase"], "installing")
        with self.assertRaises(backend.Invalid):
            self.plan()

    def test_new_owner_plan_has_no_account_and_keeps_only_the_passphrase_in_memory(self):
        data = {**ACCOUNT, "oem": True, "username": "", "password": "temporary handover 1",
                "confirm": "temporary handover 1"}
        plan = self.installer.plan(data)
        self.assertEqual((plan["account"]["oem"], plan["account"]["username"]), (True, ""))
        self.assertEqual(self.adapter.credentials, {"passphrase": "temporary handover 1"})
        self.assertNotIn("temporary handover", (self.state.directory / "state.json").read_text())
        # Unencrypted new-owner installations take no passphrase at all.
        self.installer.plan({**data, "encrypted": False, "password": "", "confirm": ""})
        self.assertEqual(self.adapter.credentials, {})
        with self.assertRaises(backend.Invalid):
            self.installer.plan({**data, "oem": "yes"})

    def alongside(self, **changes):
        return self.installer.plan({**ACCOUNT, "layout": "alongside", **changes})

    def test_alongside_offers_and_accepts_only_the_largest_shrinkable_partition(self):
        options = self.installer.alongside({"disk": "vda"})
        self.assertEqual(options["mode"], "shrink")
        self.assertEqual(options["partition"]["id"], "vda3")
        self.assertEqual(options["floor"], 105 * 1024**3)
        self.assertEqual(options["max_space"], 1024**3 + 400 * 1024**3 - 105 * 1024**3)
        self.assertTrue(options["min_space"] <= options["default_space"] <= options["max_space"])
        for shrink in ({"device": "vda4", "size": 10 * 1024**3},          # not the largest
                       {"device": "vda3", "size": 104 * 1024**3},         # below its floor
                       {"device": "vda3", "size": 400 * 1024**3},         # not a shrink
                       {"device": "vda3", "size": 380 * 1024**3}):        # too little for CybexOS
            with self.subTest(shrink=shrink), self.assertRaises(backend.Invalid):
                self.alongside(shrink=shrink)
        with self.assertRaises(backend.Invalid):
            self.alongside()  # Free space alone is not enough here.
        plan = self.alongside(shrink={"device": "vda3", "size": 300 * 1024**3})
        self.assertEqual(plan["layout"]["resize"], {"path": "/dev/vda3", "filesystem": "ntfs",
                                                     "from": 400 * 1024**3, "to": 300 * 1024**3})
        self.assertEqual(plan["layout"]["space"], 101 * 1024**3)
        self.assertEqual(plan["layout"]["kept"], ["/dev/vda1", "/dev/vda4"])
        self.assertEqual(self.adapter.planned["shrink"], {"device": "vda3", "size": 300 * 1024**3})

    def test_alongside_uses_free_space_without_shrinking_when_it_suffices(self):
        self.adapter.analysis["free"] = 80 * 1024**3
        self.assertEqual(self.installer.alongside({"disk": "vda"})["mode"], "free")
        with self.assertRaises(backend.Invalid):
            self.alongside(shrink={"device": "vda3", "size": 300 * 1024**3})
        plan = self.alongside()
        self.assertIsNone(plan["account"]["shrink"])
        self.assertNotIn("resize", plan["layout"])

    def test_alongside_plan_touching_other_partitions_is_refused(self):
        self.adapter.analysis["free"] = 80 * 1024**3
        for action in ({"action-type": "destroy", "device-id": "vda4"},
                       {"action-type": "resize", "device-id": "vda4"},
                       {"action-type": "create", "object-type": "format", "device-id": "vda1"},
                       {"action-type": "create", "object-type": "format", "device-id": "vda"}):
            with self.subTest(action=action):
                self.adapter.actions = [{"action-type": "create", "device-id": "new-1"}, action]
                with self.assertRaises(backend.Invalid):
                    self.alongside()
                self.assertEqual(self.state.read()["phase"], "failed-plan")
        self.adapter.actions = [{"action-type": "create", "object-type": "device", "device-id": "new-1"},
                                {"action-type": "create", "object-type": "format", "device-id": "new-1"}]
        self.assertEqual(self.alongside()["phase"], "review")

    def test_alongside_install_requires_its_own_confirmation(self):
        self.adapter.analysis["free"] = 80 * 1024**3
        plan = self.alongside()
        with self.assertRaises(backend.Invalid):
            self.commit(plan)  # erase_confirmed does not confirm a dual-boot install.
        self.assertFalse(self.adapter.started)
        self.installer.install({"token": plan["token"], "confirmed_disk": "vda", "alongside_confirmed": True})
        self.assertTrue(self.adapter.started)


# Strict proxy member sets were checked against the anaconda-44.30 interface
# declarations linked in INSTALLER.md. Unknown property access or assignment
# fails instead of silently creating arbitrary MagicMock methods.
class StrictProxy:
    def __init__(self, values=None, methods=None):
        object.__setattr__(self, "_values", values or {})
        object.__setattr__(self, "_methods", methods or {})

    def __getattr__(self, name):
        if name in self._values:
            return self._values[name]
        if name in self._methods:
            return self._methods[name]
        raise AttributeError(name)

    def __setattr__(self, name, value):
        if name not in self._values:
            raise AttributeError(name)
        self._values[name] = value


class Structure:
    __slots__ = (
        "name",
        "gecos",
        "password",
        "is_crypted",
        "groups",
        "partitioning_scheme",
        "encrypted",
        "luks_version",
    )

    @classmethod
    def from_structure(cls, data):
        return cls()

    @staticmethod
    def to_structure(data):
        return {
            name.replace("_", "-"): getattr(data, name)
            for name in data.__slots__
            if hasattr(data, name)
        }


LSBLK = {"blockdevices": [
    {"name": "nvme0n1", "path": "/dev/nvme0n1", "type": "disk", "fstype": None, "label": None, "size": 512 * 1024**3,
     "hotplug": False, "rm": False, "ro": False, "mountpoints": [None],
     "children": [{"name": "nvme0n1p1", "path": "/dev/nvme0n1p1", "type": "part", "fstype": "vfat", "label": None,
                   "size": 600 * 1024**2, "hotplug": False, "rm": False, "ro": False, "mountpoints": [None]}]},
    {"name": "sda", "path": "/dev/sda", "type": "disk", "fstype": "iso9660", "label": "CYBEXOS-LIVE-44",
     "size": 8 * 1024**3, "hotplug": True, "rm": True, "ro": False, "mountpoints": ["/run/initramfs/live"],
     "children": [{"name": "sda2", "path": "/dev/sda2", "type": "part", "fstype": "vfat", "label": "ANACONDA",
                   "size": 10 * 1024**2, "hotplug": True, "rm": True, "ro": False, "mountpoints": [None]}]},
    {"name": "sdb", "path": "/dev/sdb", "type": "disk", "fstype": None, "label": None, "size": 32 * 1024**3,
     "hotplug": True, "rm": True, "ro": False, "mountpoints": [None],
     "children": [{"name": "sdb1", "path": "/dev/sdb1", "type": "part", "fstype": "exfat", "label": "STICK",
                   "size": 32 * 1024**3, "hotplug": True, "rm": True, "ro": False, "mountpoints": [None]},
                  {"name": "sdb2", "path": "/dev/sdb2", "type": "part", "fstype": "ntfs", "label": "WIN",
                   "size": 1024**3, "hotplug": True, "rm": True, "ro": False, "mountpoints": [None]}]},
    {"name": "sdc", "path": "/dev/sdc", "type": "disk", "fstype": "vfat", "label": "MOUNTED", "size": 16 * 1024**3,
     "hotplug": True, "rm": False, "ro": False, "mountpoints": ["/run/media/liveuser/MOUNTED"]},
    {"name": "vda", "path": "/dev/vda", "type": "disk", "fstype": "ext4", "label": None, "size": 100 * 1024**3,
     "hotplug": True, "rm": False, "ro": False, "mountpoints": [None]},
]}


class DiagnosticsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def test_log_reading_is_allow_listed_and_bounded(self):
        first, second = self.root / "one.log", self.root / "two.log"
        first.write_text("".join(f"line {number}\n" for number in range(100)))
        sources = {"one": [first], "both": [first, second], "missing": [self.root / "absent.log"]}
        with self.assertRaises(backend.Invalid):
            backend.read_log("../../etc/shadow", sources)
        with self.assertRaises(backend.Invalid):
            backend.read_log("/tmp/sensitive-info.log")
        tail = backend.read_log("one", sources, limit=30)["text"]
        self.assertTrue(tail.startswith("line ") and tail.endswith("line 99\n"))
        self.assertLessEqual(len(tail), 30)
        self.assertEqual(backend.read_log("missing", sources), {"source": "missing", "available": False, "text": ""})
        second.write_text("second\n")
        both = backend.read_log("both", sources)["text"]
        self.assertLess(both.index(f"==> {first} <=="), both.index(f"==> {second} <=="))
        self.assertNotIn(Path("/tmp/sensitive-info.log"), [path for paths in backend.LOG_SOURCES.values() for path in paths])
        # Post-install output lands in the target (chroot) and the live system (nochroot).
        self.assertEqual(backend.LOG_SOURCES["post"], [Path("/mnt/sysroot/var/log/anaconda/cybexos-cleanup.log"),
                                                     Path("/var/log/anaconda/cybexos-target-policy.log")])
        hook = (ROOT / "live-rootfs/usr/share/anaconda/post-scripts/90-cybexos.ks").read_text()
        self.assertIn("--log=/var/log/anaconda/cybexos-cleanup.log", hook)
        self.assertIn("--log=/var/log/anaconda/cybexos-target-policy.log", hook)

    def test_page_offers_exactly_the_backend_logs(self):
        import re
        page = (ROOT / "live-rootfs/usr/share/cockpit/cybexos-installer/index.html").read_text()
        select = page[page.index('<select id="log-source">'):page.index("</select>", page.index('<select id="log-source">'))]
        self.assertEqual(re.findall(r'value="([a-z]+)"', select), list(backend.LOG_SOURCES))

    def lsblk(self, *args, **kwargs):
        return types.SimpleNamespace(stdout=json.dumps(LSBLK), returncode=0)

    def test_destinations_exclude_live_medium_target_and_internal_disks(self):
        destinations = backend.log_destinations({"disk": {"name": "vda"}}, self.lsblk)
        self.assertEqual([(item["name"], item["mountpoint"]) for item in destinations],
                         [("sdb1", ""), ("sdc", "/run/media/liveuser/MOUNTED")])

    def export_runner(self, calls):
        def run(command, **kwargs):
            calls.append(command)
            if command[0] == "lsblk":
                return self.lsblk()
            if command[0] == "journalctl":
                return types.SimpleNamespace(stdout="fixture journal\n", returncode=0)
            return types.SimpleNamespace(stdout="", returncode=0)
        return run

    def test_export_mounts_unmounted_drive_and_always_unmounts(self):
        calls = []
        (self.root / "state.json").write_text('{"phase": "failed-install"}')
        with patch.object(backend, "LOG_SOURCES", {"steps": [self.root / "worker.log"]}):
            (self.root / "worker.log").write_text("[40/41] Running post-installation scripts\n")
            result = backend.export_logs("sdb1", {"disk": {"name": "vda"}}, self.export_runner(calls), self.root)
        mountpoint = self.root / "export-mount"
        self.assertIn(["mount", "-o", "nosuid,nodev,noexec", "/dev/sdb1", str(mountpoint)], calls)
        self.assertEqual(calls[-1], ["umount", str(mountpoint)])
        saved = mountpoint / result["file"]
        self.assertEqual(saved.stat().st_mode & 0o777, 0o644)
        import tarfile
        with tarfile.open(saved) as archive:
            names = archive.getnames()
            self.assertEqual(archive.extractfile("cybexos-install-logs/journal.txt").read(), b"fixture journal\n")
        self.assertEqual(sorted(names), ["cybexos-install-logs/journal.txt", "cybexos-install-logs/state.json",
                                         "cybexos-install-logs/steps/worker.log"])
        self.assertEqual([path.name for path in self.root.iterdir() if path.name.startswith(".export-")], [])

    def test_export_rejects_unlisted_devices(self):
        for name in ("sda2", "vda", "nvme0n1p1", "sdb2", "../sdb1"):
            with self.assertRaises(backend.Invalid):
                backend.export_logs(name, {"disk": {"name": "vda"}}, self.export_runner([]), self.root)


class InstallModeTests(unittest.TestCase):
    """The "Install CybexOS" boot entry's session, without booting anything."""

    def run_block(self, script, start, end, replacements, env=None):
        text = script.read_text()
        block = text[text.index(start):text.index(end, text.index(start)) + len(end)]
        for old, new in replacements.items():
            block = block.replace(old, new)
        return subprocess.run(["bash", "-euc", block + '\nprintf "%s" "${CYBEXOS_SESSION_TARGET:-}"'],
                              capture_output=True, text=True, env={"PATH": "/usr/bin:/bin", **(env or {})})

    def test_boot_argument_marks_installation_only_mode(self):
        setup = ROOT / "live-rootfs/usr/libexec/cybexos-live-setup"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for cmdline, expected in (("BOOT_IMAGE=vmlinuz0 rd.live.image quiet cybexos.install", True),
                                      ("rd.live.image cybexos.installer cybexos.install=0", False)):
                (root / "cmdline").write_text(cmdline + "\n")
                marker = root / "cybexos-install-mode"
                marker.unlink(missing_ok=True)
                result = self.run_block(setup, "if tr ' '", "\nfi\n",
                                        {"/proc/cmdline": str(root / "cmdline"), "/run/cybexos-install-mode": str(marker)})
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(marker.exists(), expected, cmdline)

    def test_launcher_selects_the_install_target_only_in_the_marked_live_session(self):
        launcher = ROOT / "rootfs/usr/bin/hyprland-quickshell"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for live, marked, expected in ((True, True, "cybexos-install-session.target"),
                                           (False, True, "hyprland-session.target"),
                                           (True, False, "hyprland-session.target")):
                for name, present in (("cybexos-live", live), ("cybexos-install-mode", marked)):
                    (root / name).unlink(missing_ok=True)
                    if present:
                        (root / name).touch()
                result = self.run_block(launcher, "if [[ -e /run/cybexos-live", "\nfi\n",
                                        {"/run/": str(root) + "/"})
                self.assertEqual(result.stdout, expected, (live, marked))
        text = launcher.read_text()
        self.assertLess(text.index("export CYBEXOS_SESSION_TARGET"), text.index("Hyprland --config"))

    def test_launcher_stops_each_selected_session_target_once(self):
        text = (ROOT / "rootfs/usr/bin/hyprland-quickshell").read_text()
        cleanup = text[text.index('session_stop_targets='):text.index('# Launch once:')]
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / 'stopped'
            for target in ('hyprland-session.target', 'cybexos-install-session.target'):
                log.unlink(missing_ok=True)
                result = subprocess.run(['bash', '-euc',
                    'systemctl() { printf "%s\\n" "$*" >>"$SESSION_TEST_LOG"; }\n' + cleanup],
                    env={'PATH': '/usr/bin:/bin', 'CYBEXOS_SESSION_TARGET': target,
                         'SESSION_TEST_LOG': str(log)}, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                targets = ['hyprland-session.target']
                if target != targets[0]:
                    targets.append(target)
                self.assertEqual(log.read_text().splitlines(), ['--user stop ' + ' '.join(targets)])

    def test_install_session_starts_only_the_installer(self):
        import configparser
        units = ROOT / "live-rootfs/usr/lib/systemd/user"
        target = configparser.ConfigParser()
        target.read(units / "cybexos-install-session.target")
        self.assertEqual(set(target["Unit"]["Wants"].split()),
                         {"graphical-session-pre.target", "hyprpolkitagent.service", "cybexos-install-welcome.service"})
        self.assertEqual(target["Unit"]["BindsTo"], "graphical-session.target")
        window = configparser.ConfigParser()
        window.read(units / "cybexos-install-welcome.service")
        self.assertEqual(window["Service"]["ExecStart"], "/usr/bin/cybexos-welcome --install-mode")
        self.assertEqual(window["Unit"]["PartOf"], "cybexos-install-session.target")
        with tempfile.TemporaryDirectory() as directory:
            tree.install_tree(ROOT / "live-rootfs", Path(directory))
            installed = Path(directory) / "usr/lib/systemd/user/cybexos-install-session.target"
            self.assertEqual(installed.stat().st_mode & 0o777, 0o644)
        # Live-only files never reach an installed system.
        hook = (ROOT / "live-rootfs/usr/share/anaconda/post-scripts/90-cybexos.ks").read_text()
        self.assertIn("rm -f /usr/lib/systemd/user/cybexos-install-session.target "
                      "/usr/lib/systemd/user/cybexos-install-welcome.service", hook)
        # No wallpaper covers the installation-only session's background, where
        # Hyprland would draw a random splash such as "Segmentation fault".
        looknfeel = (ROOT.parent / "roles/desktop/templates/looknfeel.lua.j2").read_text()
        self.assertIn("disable_splash_rendering = true", looknfeel)


class AdapterContractTests(unittest.TestCase):
    def setUp(self):
        self.calls = []
        self.part = StrictProxy(
            {"Request": {}},
            {
                "SetPassphrase": lambda password: self.calls.append(("passphrase", password)),
                "ConfigureWithTask": lambda: self.calls.append(("configure-request", dict(self.part.Request))) or "/configure",
                "ValidateWithTask": lambda: "/validate",
                "GetDeviceTree": lambda: self.calls.append(("tree",)) or "/tree",
            },
        )
        # anaconda-44.30 ResizableDeviceTreeInterface (a DeviceTreeInterface).
        self.tree = StrictProxy(methods={
            "ShrinkDevice": lambda device, size: self.calls.append(("shrink", device, size)),
            "GetDevicePartitions": lambda disk: ["vda1", "vda3"],
            "IsDeviceShrinkable": lambda device: device == "vda3",
            "GetDeviceSizeLimits": lambda device: (100 * 1024**3, 400 * 1024**3),
            "GetDeviceData": lambda device: {"path": "/dev/" + device,
                                             "size": {"vda1": 512 * 1024**2, "vda3": 400 * 1024**3}[device]},
            "GetFormatData": lambda device: {"type": {"vda1": "efi", "vda3": "ntfs"}[device]},
            "GetDiskFreeSpace": lambda disks: self.calls.append(("free", tuple(disks))) or 2 * 1024**3,
        })
        self.modules = {
            ("Storage", ""): StrictProxy(
                {"AppliedPartitioning": "/partitioning"},
                {
                    "ResetPartitioning": lambda: self.calls.append(("reset",)),
                    "CreatePartitioning": lambda method: (
                        self.calls.append(("create", method)) or "/partitioning"
                    ),
                    "ApplyPartitioning": lambda path: self.calls.append(("apply", path)),
                },
            ),
            ("Storage", "/DiskSelection"): StrictProxy({"SelectedDisks": []}),
            ("Storage", "/DiskInitialization"): StrictProxy(
                {
                    "InitializationMode": 0,
                    "InitializeLabelsEnabled": False,
                    "DrivesToClear": [],
                    "DevicesToClear": [],
                }
            ),
            ("Storage", "/Bootloader"): StrictProxy({"Drive": ""}),
            ("Storage", "/DeviceTree"): StrictProxy(methods={"GetActions": lambda: []}),
            ("Users", ""): StrictProxy(
                {"Users": [], "IsRootAccountLocked": False},
                {"ClearRootPassword": lambda: self.calls.append(("clear-root",))},
            ),
            ("Localization", ""): StrictProxy(
                {"Language": "", "XLayouts": [], "VirtualConsoleKeymap": ""},
                {"PopulateMissingKeyboardConfigurationWithTask": lambda: "/keyboard"},
            ),
            ("Timezone", ""): StrictProxy(
                methods={
                    "SetTimezoneWithPriority": lambda timezone, priority: self.calls.append(
                        ("timezone", timezone, priority)
                    )
                }
            ),
            ("Network", ""): StrictProxy({"Hostname": ""}),
        }
        self.adapter = backend.Anaconda.__new__(backend.Anaconda)
        self.adapter.proxy = lambda module, suffix="": self.modules[(module, suffix)]
        self.adapter.bus = types.SimpleNamespace(get_proxy=self.get_proxy)
        self.adapter.task = self.task
        self.addCleanup(patch.stopall)
        patch.dict(
            "sys.modules",
            {
                "pyanaconda.core.users": types.SimpleNamespace(
                    crypt_password=lambda password: "fixture-hash"
                ),
                "pyanaconda.modules.common.structures.user": types.SimpleNamespace(
                    UserData=Structure
                ),
                "pyanaconda.modules.common.structures.partitioning": types.SimpleNamespace(
                    PartitioningRequest=Structure
                ),
            },
        ).start()

    def get_proxy(self, service, path):
        self.assertEqual(service, "org.fedoraproject.Anaconda.Modules.Storage")
        return {"/partitioning": self.part, "/tree": self.tree}[path]

    def task(self, module, path, result=False):
        self.calls.append(("task", module, path))
        if path == "/keyboard":
            self.modules[("Localization", "")].VirtualConsoleKeymap = "us"
        return {"error-messages": [], "warning-messages": []} if result else None

    def test_exact_account_partition_and_validation_sequence(self):
        account = backend.validate_account(ACCOUNT, CHOICES)
        result = self.adapter.plan(account, {"password": ACCOUNT["password"], "passphrase": ACCOUNT["password"]}, DISK)
        self.assertEqual(result["boot_keyboard"], "us")
        self.assertEqual(
            self.part.Request,
            {"partitioning-scheme": 1, "encrypted": True, "luks-version": "luks2"},
        )
        self.assertEqual(self.modules[("Storage", "/DiskInitialization")].DrivesToClear, ["vda"])
        self.assertEqual(self.modules[("Storage", "/DiskSelection")].SelectedDisks, ["vda"])
        user = self.modules[("Users", "")].Users[0]
        self.assertEqual(user["password"], "fixture-hash")
        self.assertEqual(user["groups"], ["wheel"])
        self.assertTrue(self.modules[("Users", "")].IsRootAccountLocked)
        self.assertIn(("passphrase", ACCOUNT["password"]), self.calls)
        self.assertLess(
            self.calls.index(("task", "Storage", "/configure")),
            self.calls.index(("apply", "/partitioning")),
        )
        self.assertLess(
            self.calls.index(("apply", "/partitioning")),
            self.calls.index(("task", "Storage", "/validate")),
        )

    def test_unencrypted_path_never_sets_luks_password(self):
        account = backend.validate_account({**ACCOUNT, "encrypted": False}, CHOICES)
        self.adapter.plan(account, {"password": ACCOUNT["password"]}, DISK)
        self.assertFalse(self.part.Request["encrypted"])
        self.assertFalse(any(call[0] == "passphrase" for call in self.calls))

    def test_inventory_excludes_protected_media_and_reads_payload_size(self):
        lsblk_calls = []
        def lsblk(command, **kwargs):
            lsblk_calls.append(command)
            return types.SimpleNamespace(stdout=json.dumps({"blockdevices": [{
                "path": "/dev/vda", "type": "disk", "children": [
                    {"path": "/dev/vda1", "size": 2 * 1024**3, "type": "part", "fstype": "vfat"}
                ]}]}))
        patch.object(backend.subprocess, "run", side_effect=lsblk).start()
        self.modules[("Storage", "/DiskSelection")]._methods["GetUsableDisks"] = lambda: [
            "vda",
            "live",
        ]
        self.modules[("Storage", "/DeviceTree")]._methods["GetDeviceData"] = lambda name: {
            "is-disk": True,
            "protected": name == "live",
            "path": "/dev/" + name,
            "size": 100 * 1024**3,
            "attrs": {"serial": name, "model": "Fixture"},
            "device-id": name,
        }
        localization = self.modules[("Localization", "")]
        localization.Language = "en_US.UTF-8"
        localization._methods["GetKeyboardLayouts"] = lambda: [
            {"layout-id": "us", "description": "English"}
        ]
        localization._methods["GetLanguages"] = lambda: ["en"]
        localization._methods["GetLocales"] = lambda language: ["en_US.UTF-8"]
        timezone = self.modules[("Timezone", "")]
        timezone._values.update(Timezone="America/New_York", GeolocationResult={"territory": "", "timezone": ""})
        timezone._methods["GetAllValidTimezones"] = lambda: {
            "America": ["New_York"], "Europe": ["Amsterdam", "Berlin"]
        }
        self.modules[("Payloads", "")] = StrictProxy(
            methods={"CalculateRequiredSpace": lambda: 70 * 1024**3}
        )
        inventory = self.adapter.inventory()
        self.assertEqual([item["name"] for item in inventory["disks"]], ["vda"])
        self.assertEqual(inventory["disks"][0]["partitions"], [
            {"path": "/dev/vda1", "size": 2 * 1024**3, "filesystem": "vfat"}
        ])
        self.assertEqual(lsblk_calls[0][-2:], ["--", "/dev/vda"])
        self.assertEqual(inventory["required_bytes"], 70 * 1024**3)
        self.assertEqual(
            inventory["timezones"], ["America/New_York", "Europe/Amsterdam", "Europe/Berlin", "UTC"]
        )
        self.assertEqual((inventory["timezone"], inventory["detected_timezone"]), ("America/New_York", ""))
        # A geolocation result that arrived after Anaconda's startup wait is preselected.
        timezone.GeolocationResult = {"territory": "NL", "timezone": "Europe/Amsterdam"}
        inventory = self.adapter.inventory()
        self.assertEqual((inventory["timezone"], inventory["detected_timezone"]),
                         ("Europe/Amsterdam", "Europe/Amsterdam"))
        timezone.GeolocationResult = {"territory": "", "timezone": "Mars/Olympus"}
        timezone.Timezone = "Mars/Olympus"
        inventory = self.adapter.inventory()
        self.assertEqual((inventory["timezone"], inventory["detected_timezone"]), ("UTC", ""))

    def test_inventory_lists_all_supported_regional_locales_not_only_common_choices(self):
        self.modules[("Storage", "/DiskSelection")]._methods["GetUsableDisks"] = lambda: []
        localization = self.modules[("Localization", "")]
        localization.Language = "fr_CA.UTF-8"
        available = {"en": ["en_US.UTF-8", "en_GB.UTF-8"],
                     "nl": ["nl_NL.UTF-8", "nl_BE.UTF-8", "nl_NL.UTF-8"]}
        localization._methods.update(
            GetKeyboardLayouts=lambda: [],
            GetCommonLocales=lambda: ["en_US.UTF-8"],
            GetLanguages=lambda: list(available),
            GetLocales=lambda language: available[language],
        )
        timezone = self.modules[("Timezone", "")]
        timezone._values.update(Timezone="UTC", GeolocationResult={})
        timezone._methods["GetAllValidTimezones"] = lambda: {}
        self.modules[("Payloads", "")] = StrictProxy(methods={"CalculateRequiredSpace": lambda: 1})
        inventory = self.adapter.inventory()
        self.assertEqual(inventory["locales"], [
            "en_GB.UTF-8", "en_US.UTF-8", "nl_BE.UTF-8", "nl_NL.UTF-8", "fr_CA.UTF-8"
        ])
        self.assertEqual(inventory["locale"], "fr_CA.UTF-8")
        self.assertEqual(backend.validate_account(
            {**ACCOUNT, "locale": "nl_NL.UTF-8"},
            {**CHOICES, "locales": inventory["locales"]}
        )["locale"], "nl_NL.UTF-8")

    def test_rescan_uses_anaconda_scan_task(self):
        storage = self.modules[("Storage", "")]
        storage._methods["ScanDevicesWithTask"] = lambda: "/scan"
        calls = []
        self.adapter.task = lambda module, path, **kwargs: calls.append((module, path, kwargs))
        self.adapter.rescan()
        self.assertEqual(calls, [("Storage", "/scan", {"timeout": 300})])

    def test_geolocation_runs_only_without_an_earlier_result(self):
        timezone = self.modules[("Timezone", "")]
        timezone._values["GeolocationResult"] = {"territory": "", "timezone": ""}

        def start():
            self.calls.append(("geolocate",))
            return "/geolocation"

        timezone._methods["StartGeolocationWithTask"] = start
        tasks = []

        def task(module, path, result=False, timeout=300):
            tasks.append((module, path))
            timezone.GeolocationResult = {"territory": "NL", "timezone": "Europe/Amsterdam"}

        self.adapter.task = task
        self.assertEqual(self.adapter.geolocate(), {"timezone": "Europe/Amsterdam"})
        self.assertEqual(tasks, [("Timezone", "/geolocation")])
        self.assertEqual(self.adapter.geolocate(), {"timezone": "Europe/Amsterdam"})
        self.assertEqual(self.calls, [("geolocate",)])

    def test_plan_check_ignores_anaconda_action_reordering(self):
        actions = [
            {"action-type": "create", "device-name": "vda1", "attrs": {"mount-point": "/boot/efi"}},
            {"action-type": "create", "device-name": "vda2", "attrs": {"mount-point": "/boot"}},
            {"action-type": "create", "device-name": "vda3", "attrs": {"mount-point": ""}},
        ]
        state = {"partitioning": "/partitioning", "disk": DISK, "actions": actions}
        self.modules[("Storage", "/DiskSelection")].SelectedDisks = ["vda"]
        tree = self.modules[("Storage", "/DeviceTree")]
        # GetActions() re-sorts in place; blivet's tsort reverses independent actions.
        tree._methods["GetActions"] = lambda: list(reversed(actions))
        self.adapter.check_plan(state)
        tree._methods["GetActions"] = lambda: actions[:2]
        with self.assertRaises(backend.Invalid):
            self.adapter.check_plan(state)
        changed = copy.deepcopy(actions)
        changed[2]["device-name"] = "vdb3"
        tree._methods["GetActions"] = lambda: changed
        with self.assertRaises(backend.Invalid):
            self.adapter.check_plan(state)

    def test_task_finish_is_checked_after_stopped_and_before_result(self):
        events = []
        callbacks = []
        signal = types.SimpleNamespace(connect=callbacks.append)

        def start():
            events.append("start")
            for callback in callbacks:
                callback()

        task = StrictProxy(
            {"Stopped": signal},
            {
                "Start": start,
                "Finish": lambda: events.append("finish"),
                "GetResult": lambda: events.append("result") or {"error-messages": []},
            },
        )
        self.adapter.bus = types.SimpleNamespace(get_proxy=lambda service, path: task)
        self.adapter.GLib = types.SimpleNamespace(
            MainContext=types.SimpleNamespace(
                default=lambda: types.SimpleNamespace(pending=lambda: False)
            )
        )
        result = backend.Anaconda.task(self.adapter, "Storage", "/task", result=True)
        self.assertEqual(events, ["start", "finish", "result"])
        self.assertEqual(result, {"error-messages": []})

        def fail():
            raise RuntimeError("fixture task failure")

        task._methods["Finish"] = fail
        with self.assertRaises(RuntimeError):
            backend.Anaconda.task(self.adapter, "Storage", "/task")


    # ---- installing alongside, new-owner and seeded accounts ----------------

    def test_alongside_uses_free_space_and_shrinks_only_the_reviewed_partition(self):
        account = backend.validate_account({**ACCOUNT, "layout": "alongside",
                                            "shrink": {"device": "vda3", "size": 300 * 1024**3}}, CHOICES)
        self.adapter.plan(account, {"password": ACCOUNT["password"], "passphrase": ACCOUNT["password"]}, DISK)
        initialization = self.modules[("Storage", "/DiskInitialization")]
        # CLEAR_PARTITIONS_NONE, nothing listed for clearing, no new disk label.
        self.assertEqual(initialization.InitializationMode, 0)
        self.assertEqual(initialization.DrivesToClear, [])
        self.assertEqual(initialization.DevicesToClear, [])
        self.assertFalse(initialization.InitializeLabelsEnabled)
        self.assertEqual(self.modules[("Storage", "/DiskSelection")].SelectedDisks, ["vda"])
        self.assertIn(("shrink", "vda3", 300 * 1024**3), self.calls)
        # The shrink is scheduled on the same partitioning before it is configured.
        self.assertLess(self.calls.index(("create", "AUTOMATIC")), self.calls.index(("tree",)))
        self.assertLess(self.calls.index(("shrink", "vda3", 300 * 1024**3)),
                        self.calls.index(("task", "Storage", "/configure")))
        self.assertLess(self.calls.index(("task", "Storage", "/configure")),
                        self.calls.index(("apply", "/partitioning")))

    def test_alongside_without_a_shrink_never_resizes(self):
        account = backend.validate_account({**ACCOUNT, "layout": "alongside"}, CHOICES)
        self.adapter.plan(account, {"password": ACCOUNT["password"], "passphrase": ACCOUNT["password"]}, DISK)
        self.assertFalse(any(call[0] in ("shrink", "tree") for call in self.calls))
        self.assertEqual(self.modules[("Storage", "/DiskInitialization")].InitializationMode, 0)

    def test_erase_still_clears_only_the_selected_disk(self):
        account = backend.validate_account(ACCOUNT, CHOICES)
        self.adapter.plan(account, {"password": ACCOUNT["password"], "passphrase": ACCOUNT["password"]}, DISK)
        initialization = self.modules[("Storage", "/DiskInitialization")]
        self.assertEqual((initialization.InitializationMode, initialization.DrivesToClear), (1, ["vda"]))
        self.assertTrue(initialization.InitializeLabelsEnabled)
        self.assertFalse(any(call[0] == "shrink" for call in self.calls))

    def test_analysis_reads_limits_without_scheduling_and_resets(self):
        analysis = self.adapter.alongside(DISK)
        self.assertEqual(analysis["free"], 2 * 1024**3)
        self.assertEqual(analysis["partitions"], [
            {"id": "vda1", "path": "/dev/vda1", "size": 512 * 1024**2, "min_size": 512 * 1024**2,
             "shrinkable": False, "filesystem": "efi"},
            {"id": "vda3", "path": "/dev/vda3", "size": 400 * 1024**3, "min_size": 100 * 1024**3,
             "shrinkable": True, "filesystem": "ntfs"},
        ])
        self.assertFalse(any(call[0] in ("shrink", "apply") for call in self.calls))
        self.assertEqual(self.calls.count(("reset",)), 2)
        self.assertEqual(self.modules[("Storage", "/DiskSelection")].SelectedDisks, [])

    def test_new_owner_plan_creates_no_account_and_keeps_root_locked(self):
        account = backend.validate_account({**ACCOUNT, "oem": True, "username": ""}, CHOICES)
        self.assertEqual(account["username"], "")
        with patch.dict("sys.modules", {"pyanaconda.core.users": types.SimpleNamespace(
                crypt_password=lambda password: self.fail("an OEM plan hashes no account password"))}):
            self.adapter.plan(account, {"passphrase": "temporary handover 1"}, DISK)
        self.assertEqual(self.modules[("Users", "")].Users, [])
        self.assertTrue(self.modules[("Users", "")].IsRootAccountLocked)
        self.assertIn(("passphrase", "temporary handover 1"), self.calls)

    def test_seed_plan_uses_the_hash_as_is_and_sets_the_full_name(self):
        account = dict(backend.validate_account(ACCOUNT, CHOICES), full_name="Alice Example")
        with patch.dict("sys.modules", {"pyanaconda.core.users": types.SimpleNamespace(
                crypt_password=lambda password: self.fail("a seed hash is never rehashed"))}):
            self.adapter.plan(account, {"password_hash": "$6$seed$fixture", "passphrase": "disk phrase 123"}, DISK)
        user = self.modules[("Users", "")].Users[0]
        self.assertEqual((user["password"], user["is-crypted"], user["gecos"]),
                         ("$6$seed$fixture", True, "Alice Example"))


class TargetTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "etc").mkdir()
        (self.root / "etc/passwd").write_text(
            "root:x:0:0::/root:/bin/bash\nalice:x:1000:1000::/home/alice:/bin/bash\n"
        )
        (self.root / "etc/shadow").write_text("root:!:1::::::\nalice:fixture-hash:1::::::\n")
        (self.root / "etc/cybexos").mkdir()
        (self.root / "etc/cybexos/config.yml").write_text(
            "primary_user: 'alice'\ndesktop_autologin: false\npasswordless_wheel: false\n"
        )

    def test_autologin_requires_both_request_and_verified_encryption(self):
        policy = {"account": {"username": "alice", "encrypted": True}}
        with self.assertRaises(RuntimeError):
            target.finalize(self.root, policy, False)
        self.assertFalse((self.root / "etc/cybexos/login.json").exists())
        target.finalize(self.root, policy, True)
        login = self.root / "etc/cybexos/login.json"
        self.assertEqual(json.loads(login.read_text()),
                         {"version": 1, "user": "alice", "autologin": True, "live": False})
        self.assertEqual(login.stat().st_mode & 0o777, 0o644)
        record = json.loads((self.root / "etc/cybexos/installation.json").read_text())
        self.assertEqual(record["keyring"], "encrypted-boot-passphrase-or-prompt")
        self.assertNotIn("password", record)
        self.assertFalse(record["passwordless_wheel"])
        policy["account"]["encrypted"] = False
        target.finalize(self.root, policy, False)
        self.assertFalse(json.loads(login.read_text())["autologin"])
        target.finalize(self.root, policy, True)
        self.assertFalse(json.loads(login.read_text())["autologin"])

    def test_target_discards_live_decision_and_requires_boolean_encryption(self):
        (self.root / "run").mkdir()
        (self.root / "run/cybexos-live-session").write_text("liveuser\n")
        (self.root / "etc/sddm.conf").write_text("[Autologin]\nUser=liveuser\n")
        (self.root / "var/lib/sddm").mkdir(parents=True)
        (self.root / "var/lib/sddm/state.conf").write_text("[Last]\nUser=liveuser\n")
        target.finalize(self.root, {"account": {"username": "alice", "encrypted": False}}, False)
        self.assertFalse((self.root / "run/cybexos-live-session").exists())
        self.assertFalse((self.root / "etc/sddm.conf").exists())
        self.assertFalse((self.root / "var/lib/sddm/state.conf").exists())
        for invalid in ("false", "true", 1, None):
            with self.subTest(value=invalid), self.assertRaises(RuntimeError):
                target.finalize(self.root, {"account": {"username": "alice", "encrypted": invalid}}, True)

    def test_sudo_policy_requires_explicit_choice_and_records_it(self):
        path = self.root / "etc/sudoers.d/10-wheel-nopasswd"
        path.parent.mkdir()
        path.write_text("inherited image policy\n")
        target.finalize(self.root, {"account": {"username": "alice", "encrypted": False,
                                                     "passwordless_wheel": False}}, False)
        self.assertFalse(path.exists())
        target.finalize(self.root, {"account": {"username": "alice", "encrypted": False,
                                                     "passwordless_wheel": True}}, False)
        self.assertEqual(path.read_text(), "%wheel ALL=(ALL:ALL) NOPASSWD: ALL\n")
        self.assertEqual(path.stat().st_mode & 0o777, 0o440)
        self.assertIn("passwordless_wheel: true\n", (self.root / "etc/cybexos/config.yml").read_text())
        self.assertTrue(json.loads((self.root / "etc/cybexos/installation.json").read_text())["passwordless_wheel"])
        for invalid in ("true", 1, None):
            with self.subTest(invalid=invalid), self.assertRaises(RuntimeError):
                target.finalize(self.root, {"account": {"username": "alice", "encrypted": False,
                                                         "passwordless_wheel": invalid}}, False)

    def test_missing_or_ambiguous_saved_policy_fails_closed(self):
        config = self.root / "etc/cybexos/config.yml"
        config.unlink()
        with self.assertRaises(FileNotFoundError):
            target.finalize(self.root, {"account": {"username": "alice", "encrypted": False,
                                                     "passwordless_wheel": True}}, False)
        self.assertFalse((self.root / "etc/sudoers.d/10-wheel-nopasswd").exists())
        config.write_text("primary_user: 'alice'\ndesktop_autologin: false\npasswordless_wheel: false\npasswordless_wheel: true\n")
        with self.assertRaises(RuntimeError):
            target.finalize(self.root, {"account": {"username": "alice", "encrypted": False,
                                                     "passwordless_wheel": True}}, False)
        self.assertFalse((self.root / "etc/sudoers.d/10-wheel-nopasswd").exists())

    def test_missing_administrator_does_not_authorize_login(self):
        with self.assertRaises(RuntimeError):
            target.finalize(self.root, {"account": {"username": "missing", "encrypted": True}}, True)
        self.assertFalse((self.root / "etc/cybexos/login.json").exists())

    def test_unlocked_root_fails_finalization(self):
        (self.root / "etc/shadow").write_text("root:fixture-hash:1::::::\n")
        with self.assertRaises(RuntimeError):
            target.finalize(self.root, {"account": {"username": "alice", "encrypted": True}}, True)

    def test_encryption_check_uses_mounted_target_and_block_ancestors(self):
        def run(command, **kwargs):
            if command[0] == "findmnt":
                data = {
                    "filesystems": [{"source": "/dev/mapper/root", "target": str(self.root), "fstype": "ext4"}]
                }
            else:
                self.assertEqual(command[-1], "/dev/mapper/root")
                self.assertIn('--tree', command)
                data = {"blockdevices": [{"type": "part", "children": [{"type": "crypt"}]}]}
            return types.SimpleNamespace(stdout=json.dumps(data))

        self.assertTrue(target.root_is_encrypted(self.root, run))

        def wrong_mount(command, **kwargs):
            return types.SimpleNamespace(
                stdout=json.dumps({"filesystems": [{"source": "/dev/sda1", "target": "/"}]})
            )

        with self.assertRaises(RuntimeError):
            target.root_is_encrypted(self.root, wrong_mount)

    def test_encryption_check_rejects_mixed_and_plaintext_backing_devices(self):
        def check(devices):
            def run(command, **kwargs):
                data = ({"filesystems": [{"source": "/dev/mapper/root", "target": str(self.root), "fstype": "ext4"}]}
                        if command[0] == "findmnt" else {"blockdevices": devices})
                return types.SimpleNamespace(stdout=json.dumps(data))
            return target.root_is_encrypted(self.root, run)

        self.assertFalse(check([]))
        self.assertFalse(check([{"type": "part", "children": [{"type": "disk"}]}]))
        self.assertFalse(check([{"type": "lvm", "children": [{"type": "crypt"}, {"type": "part"}]}]))
        self.assertFalse(check([{"type": "crypt"}, {"type": "part"}]))
        self.assertTrue(check([{"type": "lvm", "children": [{"type": "crypt"}, {"type": "crypt"}]}]))

    def test_btrfs_encryption_checks_every_member_and_rejects_incomplete_reports(self):
        report = ("Label: none  uuid: 12345678-1234-1234-1234-123456789abc\n"
                  "\tTotal devices 2 FS bytes used 4096\n"
                  "\tdevid 1 size 1048576 used 4096 path /dev/mapper/root\n"
                  "\tdevid 2 size 1048576 used 4096 path /dev/second\n")
        def check(output, second):
            checked = []
            def run(command, **kwargs):
                if command[0] == 'findmnt':
                    data = {'filesystems': [{'source': '/dev/mapper/root[/@]', 'target': str(self.root), 'fstype': 'btrfs'}]}
                elif command[0] == 'btrfs':
                    self.assertEqual(command[-1], str(self.root))
                    return types.SimpleNamespace(stdout=output)
                else:
                    checked.append(command[-1])
                    data = {'blockdevices': [{'type': second if command[-1] == '/dev/second' else 'crypt'}]}
                return types.SimpleNamespace(stdout=json.dumps(data))
            return target.root_is_encrypted(self.root, run), checked
        self.assertEqual(check(report, 'crypt'), (True, ['/dev/mapper/root', '/dev/second']))
        self.assertEqual(check(report, 'part'), (False, ['/dev/mapper/root', '/dev/second']))
        for output in [report.replace('Total devices 2', 'Total devices 3'),
                       report.replace('/dev/second', 'missing'), '', report + 'Some devices missing\n']:
            with self.subTest(report=output):
                self.assertEqual(check(output, 'crypt'), (False, []))

    def assert_default_zone_block_is_idempotent(self, hook):
        # Run the script's default-zone block under the %post shell options
        # against a stand-in that fails like firewalld 2.4 when the zone is
        # already the default (ZONE_ALREADY_SET, exit 16).
        start = hook.index('if [ "$(firewall-offline-cmd --get-default-zone)"')
        block = hook[start:hook.index("\nfi\n", start) + 4]
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            fake = directory / "firewall-offline-cmd"
            fake.write_text(
                "#!/bin/sh\n"
                'case "$1" in\n'
                '  --get-default-zone) cat "$ZONE_FILE" ;;\n'
                '  --set-default-zone=*) zone=${1#*=}\n'
                '    if [ "$zone" = "$(cat "$ZONE_FILE")" ]; then echo "ZONE_ALREADY_SET: $zone"; exit 16; fi\n'
                '    echo "$zone" > "$ZONE_FILE"; echo set >> "$ZONE_FILE.calls" ;;\n'
                "esac\n"
            )
            fake.chmod(0o755)
            for initial, calls in (("cybexos", 0), ("FedoraWorkstation", 1)):
                zone = directory / ("zone-" + initial)
                zone.write_text(initial + "\n")
                result = subprocess.run(
                    ["bash", "-euc", block], capture_output=True, text=True,
                    env={**os.environ, "PATH": f"{directory}:{os.environ['PATH']}", "ZONE_FILE": str(zone)},
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(zone.read_text().strip(), "cybexos")
                recorded = Path(str(zone) + ".calls")
                self.assertEqual(len(recorded.read_text().split()) if recorded.exists() else 0, calls)

    def test_launcher_and_post_install_contract(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            tree.install_tree(ROOT / "live-rootfs", output)
            for executable in [
                "usr/bin/cybexos-installer-browser",
                "usr/libexec/cybexos-installer-backend",
                "usr/libexec/cybexos-installer-target",
                "usr/libexec/cybexos-installer-seed",
            ]:
                self.assertEqual((output / executable).stat().st_mode & 0o777, 0o755)
            self.assertEqual(
                (output / "usr/share/cockpit/cybexos-installer/index.html").stat().st_mode & 0o777,
                0o644,
            )
        config = (ROOT / "live-rootfs/etc/anaconda/conf.d/20-cybexos.conf").read_text()
        self.assertIn("webui_web_engine = /usr/bin/cybexos-installer-browser", config)
        self.assertEqual(
            browser.installer_url(
                "http://127.0.0.1:9090/cockpit/@localhost/anaconda-webui/index.html"
            ),
            "http://127.0.0.1:9090/cockpit/@localhost/cybexos-installer/index.html",
        )
        for url in [
            "https://example.com/cockpit/@localhost/anaconda-webui/index.html",
            "http://127.0.0.1@evil.invalid/cockpit/@localhost/anaconda-webui/index.html",
            "http://127.0.0.1/other",
        ]:
            with self.assertRaises(ValueError):
                browser.installer_url(url)
        hook = (ROOT / "live-rootfs/usr/share/anaconda/post-scripts/90-cybexos.ks").read_text()
        self.assertIn("/usr/libexec/cybexos-seed-installed-users", hook)
        self.assertIn("%post --nochroot --erroronfail", hook)
        self.assertIn("rm -f /etc/anaconda/conf.d/20-cybexos.conf", hook)
        self.assertIn("rm -f /run/cybexos-live-session /etc/sddm.conf", hook)
        self.assertIn("rm -f /etc/sudoers.d/10-wheel-nopasswd", hook)
        self.assertIn('"autologin":false,"live":false', hook)
        self.assertIn("systemctl enable sddm.service", hook)
        self.assertIn(
            "install -D -m 0644 /usr/lib/firewalld/zones/cybexos.xml /etc/firewalld/zones/cybexos.xml",
            hook,
        )
        self.assertIn("firewall-offline-cmd --set-default-zone=cybexos", hook)
        self.assert_default_zone_block_is_idempotent(hook)
        self.assertLess(
            hook.index("rm -f /etc/dracut.conf.d/99-live.conf"),
            hook.index("dracut --force --regenerate-all"),
        )
        self.assertLess(
            hook.index("/usr/libexec/cybexos-seed-installed-users"),
            hook.index("dracut --force --regenerate-all"),
        )
        # Seed choices reach the target before the in-target hook records config.yml.
        self.assertTrue(hook.startswith("%post --nochroot --erroronfail"))
        self.assertLess(hook.index("/usr/libexec/cybexos-installer-target --stage"),
                        hook.index("/usr/libexec/cybexos-configure-installed --offline"))
        self.assertIn("rm -f /usr/libexec/cybexos-installer-seed", hook)


if __name__ == "__main__":
    unittest.main()
