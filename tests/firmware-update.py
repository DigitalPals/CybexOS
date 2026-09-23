#!/usr/bin/env python3
"""Firmware helper contracts against a fake libfwupd.

The repository gate must never reach the real fwupd daemon. These fixtures
pin what the panel parses: the plan, one event per device outcome, progress
without duplicates, and exactly one closing summary with the exit status.
"""

import contextlib
import enum
import importlib.machinery
import importlib.util
import io
import json
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "assets/scripts/cybexos-firmware-update"
LOADER = importlib.machinery.SourceFileLoader("cybexos_firmware_update", str(HELPER))
SPEC = importlib.util.spec_from_loader(LOADER.name, LOADER)
module = importlib.util.module_from_spec(SPEC)
LOADER.exec_module(module)


class DeviceFlags(enum.IntFlag):
    # Like the real typelib: members above bit 31, such as affects-fde, are
    # missing, so the helper must read them from the device's JSON export.
    INTERNAL = 0x1
    UPDATABLE = 0x2
    SUPPORTED = 0x20
    NEEDS_REBOOT = 0x100
    NEEDS_SHUTDOWN = 0x20000


class FeatureFlags(enum.IntFlag):
    CAN_REPORT = 1 << 0
    DETACH_ACTION = 1 << 1
    UPDATE_ACTION = 1 << 2
    SWITCH_BRANCH = 1 << 3
    REQUESTS = 1 << 4
    FDE_WARNING = 1 << 5
    COMMUNITY_TEXT = 1 << 6
    SHOW_PROBLEMS = 1 << 7
    ALLOW_AUTHENTICATION = 1 << 8
    REQUESTS_NON_GENERIC = 1 << 9


class Error(enum.IntEnum):
    INTERNAL = 0
    VERSION_NEWER = 1
    VERSION_SAME = 2
    ALREADY_PENDING = 3
    AUTH_FAILED = 4
    READ = 5
    WRITE = 6
    INVALID_FILE = 7
    NOT_FOUND = 8
    NOTHING_TO_DO = 9
    NOT_SUPPORTED = 10
    SIGNATURE_INVALID = 11
    AC_POWER_REQUIRED = 12
    PERMISSION_DENIED = 13
    BROKEN_SYSTEM = 14
    BATTERY_LEVEL_TOO_LOW = 15
    NEEDS_USER_ACTION = 16
    AUTH_EXPIRED = 17
    INVALID_DATA = 18
    TIMED_OUT = 19
    BUSY = 20
    NOT_REACHABLE = 21


class Status(enum.IntEnum):
    UNKNOWN = 0
    IDLE = 1
    LOADING = 2
    DECOMPRESSING = 3
    DEVICE_RESTART = 4
    DEVICE_WRITE = 5
    DEVICE_VERIFY = 6
    SCHEDULING = 7
    DOWNLOADING = 8
    WAITING_FOR_USER = 14


class RequestKind(enum.IntEnum):
    UNKNOWN = 0
    POST = 1
    IMMEDIATE = 2


class IOErrorEnum(enum.IntEnum):
    CLOSED = 18
    TIMED_OUT = 24
    HOST_NOT_FOUND = 28


def status_to_string(status):
    # fwupd has no string for UNKNOWN.
    return None if status == Status.UNKNOWN else Status(status).name.lower().replace("_", "-")


class FakeGLibError(Exception):
    """PyGObject's GLib.Error: the domain is the quark's string."""

    def __init__(self, domain, code, message):
        super().__init__(message)
        self.domain = domain
        self.code = int(code)
        self.message = message


def fwupd_error(code, message="fwupd error"):
    return FakeGLibError("FwupdError", code, message)


class FakeGLib:
    """Timers fire in order when a loop runs; a loop with nothing left blocks."""

    Error = FakeGLibError

    def __init__(self):
        self.timers = {}
        self.next_timer = 1

    def quark_to_string(self, quark):
        return quark

    def timeout_add_seconds(self, _seconds, callback):
        timer, self.next_timer = self.next_timer, self.next_timer + 1
        self.timers[timer] = callback
        return timer

    def source_remove(self, timer):
        del self.timers[timer]

    def MainLoop(self):  # noqa: N802 - GLib's constructor name
        glib = self

        class Loop:
            quit_called = False

            def quit(self):
                self.quit_called = True

            def run(self):
                while not self.quit_called:
                    if not glib.timers:
                        raise AssertionError("the main loop would block forever")
                    timer = min(glib.timers)
                    callback = glib.timers.pop(timer)
                    if callback():
                        glib.timers[timer] = callback

        return Loop()


class FakeDevice:
    def __init__(self, device_id, name, version, flags=DeviceFlags.UPDATABLE,
                 extra_flags=(), vendor="HP"):
        self.device_id = device_id
        self.name = name
        self.version = version
        self.flags = flags
        self.extra_flags = tuple(extra_flags)
        self.vendor = vendor

    def get_id(self):
        return self.device_id

    def get_name(self):
        return self.name

    def get_vendor(self):
        return self.vendor

    def get_version(self):
        return self.version

    def has_flag(self, flag):
        return bool(self.flags & flag)

    def to_json_string(self, _codec_flags):
        names = [member.name.lower().replace("_", "-") for member in DeviceFlags
                 if self.flags & member]
        return json.dumps({"DeviceId": self.device_id, "Flags": names + list(self.extra_flags)})


class FakeRelease:
    def __init__(self, version, update_message=None):
        self.version = version
        self.update_message = update_message

    def get_version(self):
        return self.version

    def get_update_message(self):
        return self.update_message


class FakeRequest:
    def __init__(self, kind, request_id, message=None):
        self.kind = kind
        self.request_id = request_id
        self.message = message

    def get_kind(self):
        return self.kind

    def get_id(self):
        return self.request_id

    def get_message(self):
        return self.message


class FakeClient:
    """Completes every call synchronously, driven by per-device scripts."""

    def __init__(self, devices=(), upgrades=None, scripts=None, connect_error=None,
                 responds=True):
        self.devices = list(devices)
        self.upgrades = upgrades or {}
        self.scripts = scripts or {}
        self.connect_error = connect_error
        self.responds = responds
        self.handlers = {}
        self.status = Status.IDLE
        self.percentage = 0
        self.upgrade_queries = []
        self.installs = []
        self.feature_flags = None
        self.user_agent = None

    def connect(self, signal, handler):
        self.handlers.setdefault(signal, []).append(handler)
        return len(self.handlers[signal])

    def connect_async(self, _cancellable, callback, *data):
        if self.responds:
            callback(self, "connected", *data)

    def connect_finish(self, _result):
        if self.connect_error is not None:
            raise self.connect_error
        return True

    def set_feature_flags(self, flags, _cancellable):
        self.feature_flags = flags
        return True

    def set_user_agent_for_package(self, name, version):
        self.user_agent = (name, version)

    def get_devices(self, _cancellable):
        return list(self.devices)

    def get_upgrades(self, device_id, _cancellable):
        self.upgrade_queries.append(device_id)
        value = self.upgrades.get(device_id)
        if isinstance(value, Exception):
            raise value
        if not value:
            raise fwupd_error(Error.NOTHING_TO_DO, "No releases found")
        return list(value)

    def get_status(self):
        return self.status

    def get_percentage(self):
        return self.percentage

    def emit(self, signal, argument=None):
        for handler in self.handlers.get(signal, []):
            handler(self, argument)

    def progress(self, status, percent):
        # Both properties notify, so the second notification repeats the first.
        self.status, self.percentage = status, percent
        self.emit("notify::status")
        self.emit("notify::percentage")

    def request(self, request):
        self.emit("device-request", request)

    def install_release_async(self, device, release, install_flags, download_flags,
                              _cancellable, callback, *data):
        self.installs.append((device.get_id(), release.get_version(),
                              install_flags, download_flags))
        script = self.scripts.get(device.get_id())
        error = script(self) if script is not None else None
        callback(self, error, *data)

    def install_release_finish(self, result):
        if result is not None:
            raise result
        return True


def fake_gi(client, glib=None):
    fwupd = types.SimpleNamespace(
        DeviceFlags=DeviceFlags, FeatureFlags=FeatureFlags, Error=Error, Status=Status,
        RequestKind=RequestKind, status_to_string=status_to_string,
        error_quark=lambda: "FwupdError",
        InstallFlags=types.SimpleNamespace(NONE=0),
        ClientDownloadFlags=types.SimpleNamespace(NONE=0),
        CodecFlags=types.SimpleNamespace(NONE=0),
        Client=types.SimpleNamespace(new=lambda: client))
    gio = types.SimpleNamespace(IOErrorEnum=IOErrorEnum,
                                io_error_quark=lambda: "g-io-error-quark",
                                resolver_error_quark=lambda: "g-resolver-error-quark")
    gi = types.ModuleType("gi")
    gi.versions = []
    gi.require_version = lambda namespace, version: gi.versions.append((namespace, version))
    repository = types.SimpleNamespace(Fwupd=fwupd, GLib=glib or FakeGLib(), Gio=gio)
    return gi, repository


def fake_api():
    gi, repository = fake_gi(FakeClient())
    return module.Api(repository.Fwupd, repository.GLib, repository.Gio)


class HelperRun:
    def __init__(self, rc, events, raw, stdout, stderr):
        self.rc = rc
        self.events = events
        self.raw = raw
        self.stdout = stdout
        self.stderr = stderr

    def kinds(self):
        return [event["event"] for event in self.events]

    def only(self, kind):
        found = [event for event in self.events if event["event"] == kind]
        assert len(found) == 1, (kind, self.events)
        return found[0]


def run_helper(client, *arguments, modules=None):
    gi, repository = fake_gi(client)
    modules = modules if modules is not None else {"gi": gi, "gi.repository": repository}
    stdout, stderr = io.StringIO(), io.StringIO()
    with tempfile.TemporaryDirectory() as directory:
        events_path = Path(directory) / "firmware-events.log"
        argv = list(arguments) or ["install", "--events", str(events_path)]
        with patch.dict(sys.modules, modules), contextlib.redirect_stdout(stdout), \
                contextlib.redirect_stderr(stderr):
            rc = module.main(argv)
        raw = events_path.read_bytes() if events_path.exists() else b""
    events = [json.loads(line) for line in raw.decode("ascii").splitlines()]
    run = HelperRun(rc, events, raw, stdout.getvalue(), stderr.getvalue())
    run.gi = gi
    return run


def system_firmware(**overrides):
    values = {"flags": DeviceFlags.UPDATABLE | DeviceFlags.NEEDS_REBOOT}
    values.update(overrides)
    return FakeDevice("sysfw", "System Firmware", "0x01060200", **values)


class PlanTests(unittest.TestCase):
    def test_plan_matches_fwupdmgr_update_selection(self):
        client = FakeClient(
            devices=[
                system_firmware(),
                FakeDevice("disk", "NVMe SSD", "HPS0050 ", vendor="Micron",
                           flags=DeviceFlags.UPDATABLE | DeviceFlags.NEEDS_SHUTDOWN,
                           extra_flags=["affects-fde"]),
                FakeDevice("tpm", "TPM", "7.2", vendor="Nuvoton",
                           flags=DeviceFlags.INTERNAL | DeviceFlags.NEEDS_REBOOT),
                FakeDevice("touchpad", "Touchpad", "1.2", vendor="Synaptics"),
                FakeDevice("dock", "Dock", "44.00", vendor="OWC"),
            ],
            upgrades={
                "sysfw": [FakeRelease("0x01070000"), FakeRelease("0x01065000")],
                "disk": [FakeRelease("HPS0060")],
                "tpm": [FakeRelease("7.3")],
                "dock": fwupd_error(Error.INTERNAL, "metadata is corrupt"),
            })
        run = run_helper(client, "plan")

        self.assertEqual(run.rc, 0)
        self.assertEqual(json.loads(run.stdout), {"devices": [
            {"id": "sysfw", "name": "System Firmware", "vendor": "HP", "from": "0x01060200",
             "to": "0x01070000", "needsReboot": True, "affectsFde": False},
            {"id": "disk", "name": "NVMe SSD", "vendor": "Micron", "from": "HPS0050",
             "to": "HPS0060", "needsReboot": True, "affectsFde": True},
        ]})
        # A device that is not updatable costs no query at all.
        self.assertEqual(client.upgrade_queries, ["sysfw", "disk", "touchpad", "dock"])
        # "Nothing to do" is ordinary; any other planning error is logged.
        self.assertNotIn("Touchpad", run.stderr)
        self.assertIn("Dock: metadata is corrupt", run.stderr)
        self.assertEqual(client.installs, [])
        self.assertEqual(run.gi.versions, [("Fwupd", "2.0")])
        # The daemon filters releases by client features; plan and install
        # declare the same ones fwupdmgr needs for requests and warnings.
        self.assertEqual(client.feature_flags,
                         FeatureFlags.REQUESTS | FeatureFlags.REQUESTS_NON_GENERIC
                         | FeatureFlags.UPDATE_ACTION | FeatureFlags.DETACH_ACTION
                         | FeatureFlags.FDE_WARNING)
        self.assertEqual(client.user_agent, ("cybexos-firmware-update", "1"))

    def test_plan_reports_an_unreachable_daemon(self):
        client = FakeClient(connect_error=FakeGLibError("g-dbus-error-quark", 2, "no daemon"))
        run = run_helper(client, "plan")
        self.assertEqual(run.rc, 2)
        self.assertEqual(run.stdout, "")
        self.assertIn("not available", run.stderr)


class InstallTests(unittest.TestCase):
    def test_staged_capsule_streams_progress_and_requests(self):
        def script(client):
            client.progress(Status.DOWNLOADING, 0)
            client.emit("notify::percentage")
            client.progress(Status.DOWNLOADING, 40)
            client.progress(Status.DOWNLOADING, 45)
            client.progress(Status.UNKNOWN, 50)
            client.progress(Status.DECOMPRESSING, 2**32 - 1)
            client.request(FakeRequest(RequestKind.IMMEDIATE,
                                       "org.freedesktop.fwupd.request.remove-replug"))
            client.progress(Status.DEVICE_WRITE, 0)
            client.progress(Status.DEVICE_WRITE, 100)
            client.request(FakeRequest(RequestKind.POST, "org.example.vendor",
                                       "  Replug the dock power.\n"))
            client.progress(Status.SCHEDULING, 100)
            return None

        client = FakeClient(devices=[system_firmware()],
                            upgrades={"sysfw": [FakeRelease("0x01070000",
                                                            "Restart to finish.")]},
                            scripts={"sysfw": script})
        run = run_helper(client)

        self.assertEqual(run.rc, 0)
        self.assertEqual(client.installs, [("sysfw", "0x01070000", 0, 0)])
        self.assertEqual(run.events[0]["event"], "plan")
        self.assertEqual(run.events[1], {"event": "device", "id": "sysfw", "index": 1, "count": 1})
        progress = [(event["status"], event["percent"]) for event in run.events
                    if event["event"] == "progress"]
        # Repeated notifications add no events; an unknown status or
        # percentage (fwupd's G_MAXUINT) keeps the last known one.
        self.assertEqual(progress, [
            ("downloading", 0), ("downloading", 40), ("downloading", 45),
            ("downloading", 50), ("decompressing", 50), ("device-write", 0),
            ("device-write", 100), ("scheduling", 100),
        ])
        requests = [event for event in run.events if event["event"] == "request"]
        self.assertEqual(requests, [
            {"event": "request", "id": "sysfw", "kind": "immediate",
             "requestId": "org.freedesktop.fwupd.request.remove-replug",
             "message": "Unplug the device and plug it back in."},
            {"event": "request", "id": "sysfw", "kind": "post",
             "requestId": "org.example.vendor", "message": "Replug the dock power."},
        ])
        self.assertEqual(run.only("installed"), {
            "event": "installed", "id": "sysfw", "needsReboot": True,
            "message": "Restart to finish."})
        self.assertEqual(run.events[-1], {"event": "summary", "installed": 1, "failed": 0,
                                          "needsReboot": True})
        self.assertEqual(run.kinds().count("summary"), 1)
        # Compact JSON lines, one object per line, for the panel's reader.
        first = run.raw.decode("ascii").splitlines()[1]
        self.assertEqual(first, '{"event":"device","id":"sysfw","index":1,"count":1}')
        # stdout follows status changes and tenths of the percentage only.
        label = "System Firmware 0x01060200 → 0x01070000"
        self.assertIn(f"{label}: downloading 40%\n", run.stdout)
        self.assertNotIn("45%", run.stdout)
        self.assertIn(f"{label}: writing\n{label}: writing 100%\n", run.stdout)
        self.assertIn(f"{label}: installed; restart to finish\n", run.stdout)

    def test_ac_power_failure_does_not_stop_later_devices(self):
        client = FakeClient(
            devices=[system_firmware(),
                     FakeDevice("pad", "Thunderbolt™ Dock", "1.0", vendor="Dock Co")],
            upgrades={"sysfw": [FakeRelease("0x01070000")], "pad": [FakeRelease("1.1")]},
            scripts={"sysfw": lambda _client: fwupd_error(
                Error.AC_POWER_REQUIRED,
                "Cannot install update when not on AC power unless forced")})
        run = run_helper(client)

        self.assertEqual(run.rc, 1)
        self.assertEqual(run.only("failed"), {
            "event": "failed", "id": "sysfw", "reason": "ac-power",
            "message": "Connect the power adapter to install this firmware."})
        self.assertEqual(run.only("installed"), {
            "event": "installed", "id": "pad", "needsReboot": False, "message": ""})
        self.assertEqual(run.events[-1], {"event": "summary", "installed": 1, "failed": 1,
                                          "needsReboot": False})
        self.assertEqual([event["index"] for event in run.events if event["event"] == "device"],
                         [1, 2])
        # Events are ASCII, so every byte offset is a character boundary.
        self.assertIn(b"Thunderbolt\\u2122 Dock", run.raw)
        self.assertIn("System Firmware 0x01060200 → 0x01070000: failed: Cannot install",
                      run.stdout)

    def test_already_scheduled_capsule_counts_as_installed(self):
        client = FakeClient(devices=[system_firmware()],
                            upgrades={"sysfw": [FakeRelease("0x01070000")]},
                            scripts={"sysfw": lambda _client: fwupd_error(
                                Error.ALREADY_PENDING, "update already pending")})
        run = run_helper(client)

        self.assertEqual(run.rc, 0)
        self.assertEqual(run.only("installed"), {
            "event": "installed", "id": "sysfw", "needsReboot": True,
            "message": "Already scheduled for the next restart."})
        self.assertEqual(run.events[-1], {"event": "summary", "installed": 1, "failed": 0,
                                          "needsReboot": True})

    def test_nothing_to_install_is_success(self):
        client = FakeClient(devices=[FakeDevice("pad", "Touchpad", "1.2")])
        run = run_helper(client)
        self.assertEqual(run.rc, 0)
        self.assertEqual(run.events, [
            {"event": "plan", "devices": []},
            {"event": "summary", "installed": 0, "failed": 0, "needsReboot": False},
        ])

    def test_version_race_is_skipped_not_failed(self):
        client = FakeClient(devices=[system_firmware()],
                            upgrades={"sysfw": [FakeRelease("0x01070000")]},
                            scripts={"sysfw": lambda _client: fwupd_error(
                                Error.VERSION_SAME, "Specified firmware is already installed")})
        run = run_helper(client)
        self.assertEqual(run.rc, 0)
        self.assertEqual(run.only("skipped"), {
            "event": "skipped", "id": "sysfw",
            "message": "Specified firmware is already installed"})
        self.assertEqual(run.events[-1]["failed"], 0)

    def test_unreachable_daemon_is_one_unavailable_failure(self):
        cases = {
            "connect error": (FakeClient(connect_error=FakeGLibError(
                "g-dbus-error-quark", 2, "The name is not activatable")), None),
            "no reply": (FakeClient(responds=False), None),
            "no bindings": (FakeClient(), {"gi": None, "gi.repository": None}),
        }
        for name, (client, modules) in cases.items():
            with self.subTest(name):
                run = run_helper(client, modules=modules)
                self.assertEqual(run.rc, 2)
                self.assertEqual(run.kinds(), ["failed", "summary"])
                self.assertEqual(run.events[0]["id"], "")
                self.assertEqual(run.events[0]["reason"], "unavailable")
                self.assertEqual(run.events[1], {"event": "summary", "installed": 0,
                                                 "failed": 1, "needsReboot": False})
                self.assertEqual(client.installs, [])

    def test_without_events_path_stdout_stays_human(self):
        client = FakeClient(devices=[system_firmware()],
                            upgrades={"sysfw": [FakeRelease("0x01070000")]})
        run = run_helper(client, "install")
        self.assertEqual(run.rc, 0)
        self.assertEqual(run.raw, b"")
        self.assertNotIn('"event"', run.stdout)
        self.assertIn("Firmware: 1 installed, 0 failed; restart to finish installing",
                      run.stdout)


class ClassificationTests(unittest.TestCase):
    def test_errors_map_to_what_the_user_can_fix(self):
        api = fake_api()
        cases = [
            (fwupd_error(Error.BATTERY_LEVEL_TOO_LOW), "failed", "battery"),
            (fwupd_error(Error.AUTH_FAILED), "failed", "auth"),
            (fwupd_error(Error.PERMISSION_DENIED), "failed", "auth"),
            (fwupd_error(Error.NOT_REACHABLE), "failed", "network"),
            (fwupd_error(Error.INVALID_FILE, "Failed to download file: Couldn't resolve host"),
             "failed", "network"),
            (fwupd_error(Error.INVALID_FILE, "checksum invalid, expected 1234"),
             "failed", "signature"),
            (fwupd_error(Error.SIGNATURE_INVALID, "the downloaded firmware was not signed"),
             "failed", "signature"),
            (fwupd_error(Error.BUSY), "failed", "busy"),
            (FakeGLibError("g-io-error-quark", IOErrorEnum.HOST_NOT_FOUND, "no host"),
             "failed", "network"),
            (FakeGLibError("g-resolver-error-quark", 0, "no name"), "failed", "network"),
            # A daemon that went away is not a network problem.
            (FakeGLibError("g-io-error-quark", IOErrorEnum.CLOSED, "The connection is closed"),
             "failed", "other"),
            (fwupd_error(Error.NOTHING_TO_DO), "skipped", None),
            (fwupd_error(Error.VERSION_NEWER), "skipped", None),
        ]
        for error, event, reason in cases:
            with self.subTest(error=error.message, code=error.code):
                kind, fields = module.classify_error(api, error)
                self.assertEqual(kind, event)
                self.assertEqual(fields.get("reason"), reason)
                self.assertTrue(fields["message"])

    def test_fwupd_text_is_one_trimmed_line(self):
        api = fake_api()
        kind, fields = module.classify_error(api, fwupd_error(
            Error.NEEDS_USER_ACTION, "  Press the unlock button \nthen retry"))
        self.assertEqual((kind, fields), ("failed", {
            "reason": "user-action", "message": "Press the unlock button"}))
        kind, fields = module.classify_error(api, fwupd_error(
            Error.BROKEN_SYSTEM,
            "GDBus.Error:org.freedesktop.fwupd.BrokenSystem: Secure boot is misconfigured\n"))
        self.assertEqual((kind, fields), ("failed", {
            "reason": "other", "message": "Secure boot is misconfigured"}))
        self.assertEqual(module.classify_error(api, RuntimeError("")),
                         ("failed", {"reason": "other", "message": "The firmware update failed."}))


class ProgressTests(unittest.TestCase):
    def test_progress_is_deduplicated(self):
        progress = module.ProgressFilter()
        observed = [progress.observe(status, percent) for status, percent in [
            (None, 0), ("downloading", 0), ("downloading", 0), (None, 10),
            ("downloading", 10), ("device-write", None), ("device-write", 10),
        ]]
        self.assertEqual(observed, [None, ("downloading", 0), None, ("downloading", 10),
                                    None, ("device-write", 10), None])
        self.assertEqual([module.percentage(value) for value in (0, 100, 2**32 - 1, -1, None)],
                         [0, 100, None, None, None])
        progress.reset()
        self.assertEqual(progress.observe("device-write", 10), ("device-write", 10))

    def test_human_progress_is_throttled_to_tenths(self):
        human = module.HumanProgress()
        lines = [human.observe("Dock 1 → 2", status, percent) for status, percent in [
            ("idle", 0), ("device-write", 1), ("device-write", 9), ("device-write", 10),
            ("device-write", 19), ("device-verify", 19),
        ]]
        self.assertEqual(lines, [None, "Dock 1 → 2: writing 1%", None, "Dock 1 → 2: writing 10%",
                                 None, "Dock 1 → 2: verifying 19%"])


if __name__ == "__main__":
    unittest.main()
