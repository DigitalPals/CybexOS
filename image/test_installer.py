"""Source-only fixtures. No real Anaconda, devices, mounts, services or secrets."""

import copy
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
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

    def inventory(self):
        return self.choices

    def reset(self):
        pass

    def keyboard(self, layout):
        return {"keyboard": layout, "boot_keyboard": layout}

    def plan(self, account, password, disk):
        if self.failed:
            raise RuntimeError("fixture failure")
        return dict(
            partitioning="/fixture",
            actions=[{"action-description": "create"}],
            errors=[],
            warnings=[],
            boot_keyboard="us",
        )

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
            return types.SimpleNamespace(stdout=output)

        with patch.object(
            backend.pwd, "getpwnam", return_value=types.SimpleNamespace(pw_uid=os.getuid())
        ):
            backend.apply_live_keyboard("us (dvorak)", run)
        self.assertEqual(calls[-1][-3:], ["keyword", "input:kb_variant", "dvorak"])
        self.assertTrue(
            all(command[:4] == ["runuser", "-u", "liveuser", "--"] for command in calls)
        )
        with self.assertRaises(backend.Invalid):
            backend.apply_live_keyboard("us; bad", run)

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


class AdapterContractTests(unittest.TestCase):
    def setUp(self):
        self.calls = []
        self.part = StrictProxy(
            {"Request": {}},
            {
                "SetPassphrase": lambda password: self.calls.append(("passphrase", password)),
                "ConfigureWithTask": lambda: "/configure",
                "ValidateWithTask": lambda: "/validate",
            },
        )
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
        self.assertEqual(path, "/partitioning")
        return self.part

    def task(self, module, path, result=False):
        self.calls.append(("task", module, path))
        if path == "/keyboard":
            self.modules[("Localization", "")].VirtualConsoleKeymap = "us"
        return {"error-messages": [], "warning-messages": []} if result else None

    def test_exact_account_partition_and_validation_sequence(self):
        account = backend.validate_account(ACCOUNT, CHOICES)
        result = self.adapter.plan(account, ACCOUNT["password"], DISK)
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
        self.adapter.plan(account, ACCOUNT["password"], DISK)
        self.assertFalse(self.part.Request["encrypted"])
        self.assertFalse(any(call[0] == "passphrase" for call in self.calls))

    def test_inventory_excludes_protected_media_and_reads_payload_size(self):
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
        localization._methods["GetCommonLocales"] = lambda: ["en_US.UTF-8"]
        self.modules[("Timezone", "")]._values["Timezone"] = "UTC"
        self.modules[("Payloads", "")] = StrictProxy(
            methods={"CalculateRequiredSpace": lambda: 70 * 1024**3}
        )
        inventory = self.adapter.inventory()
        self.assertEqual([item["name"] for item in inventory["disks"]], ["vda"])
        self.assertEqual(inventory["required_bytes"], 70 * 1024**3)

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

    def test_launcher_and_post_install_contract(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            tree.install_tree(ROOT / "live-rootfs", output)
            for executable in [
                "usr/bin/cybexos-installer-browser",
                "usr/libexec/cybexos-installer-backend",
                "usr/libexec/cybexos-installer-target",
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
        self.assertIn('"autologin":false,"live":false', hook)
        self.assertIn("systemctl enable sddm.service", hook)
        self.assertIn(
            "install -D -m 0644 /usr/lib/firewalld/zones/cybexos.xml /etc/firewalld/zones/cybexos.xml",
            hook,
        )
        self.assertIn("firewall-offline-cmd --set-default-zone=cybexos", hook)
        self.assertLess(
            hook.index("rm -f /etc/dracut.conf.d/99-live.conf"),
            hook.index("dracut --force --regenerate-all"),
        )
        self.assertLess(
            hook.index("/usr/libexec/cybexos-seed-installed-users"),
            hook.index("dracut --force --regenerate-all"),
        )


if __name__ == "__main__":
    unittest.main()
