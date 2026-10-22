#!/usr/bin/env python3
"""Opt-in native Wayland check: notification arrival/hover must retain focus.

Moves the pointer and opens a disposable Qt input window; injects no keys.
Not part of tests/run because it deliberately interacts with the live desktop.
"""
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import tempfile
import time

from evdev import UInput, ecodes


ROOT = Path(__file__).resolve().parents[1]
QML = '''import QtQuick
import QtQuick.Window
Window {
    visible: true; width: 600; height: 160
    title: "CybexOS notification focus fixture"
    TextInput { anchors.fill: parent; focus: true }
}
'''


def command(*args):
    return subprocess.check_output(args, text=True, timeout=15).strip()


def hypr(query):
    return json.loads(command("hyprctl", "-j", query))


def wait_for(predicate):
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.05)
    raise AssertionError("Desktop did not reach the expected fixture/toast state")


def toast():
    return next((s for monitor in hypr("layers").values()
                 for surfaces in monitor["levels"].values() for s in surfaces
                 if s["namespace"] == "qs-notifications"), None)


def live_check(phase):
    subprocess.run(["bash", "-c", f"source tests/lib/quickshell-live; qs_live_{phase}"],
                   cwd=ROOT, check=True, timeout=45)


def main():
    def interrupted(signum, _frame):
        raise SystemExit(128 + signum)

    for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(signum, interrupted)
    live_check("begin")
    initial = hypr("activewindow").get("address")
    pointer = hypr("cursorpos")
    pending = []
    process = None
    try:
        assert not toast(), "Wait for existing notifications to expire before testing"
        with tempfile.TemporaryDirectory(prefix="cybexos-notification-focus-live.") as temporary:
            scratch = Path(temporary)
            source = scratch / "Input.qml"
            source.write_text(QML)
            trace = scratch / "wayland.log"
            with trace.open("w") as log, UInput(
                    {ecodes.EV_KEY: [ecodes.BTN_LEFT],
                     ecodes.EV_REL: [ecodes.REL_X, ecodes.REL_Y]},
                    name="CybexOS notification focus regression") as mouse:
                def move(x, y):
                    for _ in range(50):
                        pos = hypr("cursorpos")
                        dx, dy = x - pos["x"], y - pos["y"]
                        if abs(dx) < 3 and abs(dy) < 3:
                            return
                        mouse.write(ecodes.EV_REL, ecodes.REL_X, round(dx / 2))
                        mouse.write(ecodes.EV_REL, ecodes.REL_Y, round(dy / 2))
                        mouse.syn()
                        time.sleep(0.05)
                    raise AssertionError("Could not position test pointer")

                try:
                    environment = dict(os.environ, WAYLAND_DEBUG="client")
                    process = subprocess.Popen(["/usr/lib64/qt6/bin/qml", str(source)],
                                               env=environment, stdout=log, stderr=log)
                    window = wait_for(lambda: next((w for w in hypr("clients")
                                                    if w["pid"] == process.pid), None))

                    def focused():
                        events = re.findall(r"wl_keyboard#\d+\.(enter|leave)\(", trace.read_text())
                        return bool(events and events[-1] == "enter")

                    def focus():
                        command("hyprctl", "dispatch", "hl.dsp.focus({ window = "
                                + json.dumps("address:" + window["address"]) + " })")
                        wait_for(focused)

                    def close():
                        while pending:
                            command("gdbus", "call", "--session", "--dest", "org.freedesktop.Notifications",
                                    "--object-path", "/org/freedesktop/Notifications", "--method",
                                    "org.freedesktop.Notifications.CloseNotification", str(pending.pop()))
                        wait_for(lambda: not toast())

                    def send(urgency):
                        pending.append(int(command("notify-send", "-p", "-a", "CybexOS focus regression",
                                                   "-u", urgency, "-t", "0", "Notification focus check",
                                                   "Typing should stay in the current window.")))
                        surface = wait_for(toast)
                        time.sleep(0.3)
                        return surface

                    focus()
                    surface = send("normal")
                    assert focused(), "Notification arrival stole Wayland keyboard focus"
                    target = (surface["x"] + surface["w"] // 2,
                              surface["y"] + surface["h"] // 2)
                    # Keep the fixture beneath the popup. Moving to an unrelated
                    # application would legitimately change focus when it closes.
                    selector = json.dumps("address:" + window["address"])
                    for operation in (
                            "float({ action = 'on', window = " + selector + " })",
                            "resize({ x = 600, y = 300, relative = false, window = " + selector + " })",
                            "move({ x = " + str(target[0] - 300) + ", y = " + str(target[1] - 50)
                            + ", relative = false, window = " + selector + " })"):
                        command("hyprctl", "dispatch", "hl.dsp.window." + operation)
                    focus()
                    move(*target)
                    time.sleep(0.3)
                    assert focused(), "Hovering a notification stole Wayland keyboard focus"
                    close()
                    for urgency in ("low", "normal", "critical"):
                        focus()
                        move(*target)
                        assert focused(), "Fixture lost focus before notification arrival"
                        send(urgency)
                        assert focused(), f"{urgency} popup beneath pointer stole keyboard focus"
                        close()
                    print("PASS: arrival, hover, and low/normal/critical popups beneath the pointer retain Wayland keyboard focus")
                finally:
                    for notification in pending:
                        command("gdbus", "call", "--session", "--dest", "org.freedesktop.Notifications",
                                "--object-path", "/org/freedesktop/Notifications", "--method",
                                "org.freedesktop.Notifications.CloseNotification", str(notification))
                    if process is not None:
                        process.terminate()
                        try:
                            process.wait(timeout=5)
                        except subprocess.TimeoutExpired:
                            process.kill()
                            process.wait(timeout=5)
                    if initial:
                        command("hyprctl", "dispatch", "hl.dsp.focus({ window = "
                                + json.dumps("address:" + initial) + " })")
                    move(pointer["x"], pointer["y"])
    finally:
        live_check("end")


if __name__ == "__main__":
    main()
