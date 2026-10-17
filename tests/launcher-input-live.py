#!/usr/bin/env python3
"""Opt-in live launcher regression: uinput, an IBus-active Qt field, and OCR.

Never part of tests/run: this deliberately changes desktop focus and types
only into the fixture or the verified launcher. It never injects Enter.
"""
import argparse
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
RUNTIME = ROOT / "assets/scripts/cybexos-runtime"
PREFIX = "Cybex launcher input fixture:"
QML = '''import QtQuick
import QtQuick.Window
Window {
    visible: true; width: 600; height: 160; color: "#202020"
    title: "Cybex launcher input fixture:" + field.text
    TextInput {
        id: field
        anchors.fill: parent; anchors.margins: 20
        focus: true; color: "white"; font.pixelSize: 32
    }
}
'''


def command(*args):
    return subprocess.check_output([str(a) for a in args], text=True,
                                   stderr=subprocess.DEVNULL, timeout=10).strip()


def hypr(query):
    return json.loads(command("hyprctl", "-j", query))


def live_check(phase):
    subprocess.run(["bash", "-c", f'source tests/lib/quickshell-live; qs_live_{phase}'],
                   cwd=ROOT, check=True, timeout=45)


def wait_for(predicate):
    for _ in range(100):
        result = predicate()
        if result:
            return result
        time.sleep(0.05)
    raise AssertionError("Desktop did not reach the expected focus/layer state")


def ipc(*args):
    return command(RUNTIME, "ipc", "launcher", *args)


def layers():
    return [surface for monitor in hypr("layers").values()
            for level in monitor["levels"].values() for surface in level]


def launcher():
    return next((s for s in layers() if s["namespace"] == "qs-launcher"), None)


def focus(address):
    command("hyprctl", "dispatch",
            'hl.dsp.focus({ window = ' + json.dumps("address:" + address) + ' })')


def dismiss_outside(sink, guard):
    """Click only inside the disposable fixture, outside the launcher card."""
    surface = launcher()
    window = next(w for w in hypr("clients") if w["address"] == sink["address"])
    x, y = window["at"]
    width, height = window["size"]
    # Keep clear of the bar's transparent envelope and window borders.
    candidates = [(x + 30, y + 100), (x + width - 30, y + 100),
                  (x + 30, y + height - 30), (x + width - 30, y + height - 30)]
    target = next(((px, py) for px, py in candidates
                   if not (surface["x"] <= px < surface["x"] + surface["w"]
                           and surface["y"] <= py < surface["y"] + surface["h"])), None)
    assert target, "fixture has no exposed area for a safe outside click"
    original = hypr("cursorpos")
    with UInput({ecodes.EV_KEY: [ecodes.BTN_LEFT],
                 ecodes.EV_REL: [ecodes.REL_X, ecodes.REL_Y]},
                name="Cybex launcher dismissal regression") as mouse:
        def move(px, py):
            for _ in range(30):
                current = hypr("cursorpos")
                dx, dy = px - current["x"], py - current["y"]
                if abs(dx) < 3 and abs(dy) < 3:
                    return
                mouse.write(ecodes.EV_REL, ecodes.REL_X, round(dx / 2))
                mouse.write(ecodes.EV_REL, ecodes.REL_Y, round(dy / 2))
                mouse.syn()
                time.sleep(0.08)
            raise AssertionError("pointer did not reach the fixture")

        try:
            time.sleep(0.3)
            move(*target)
            guard(True)
            mouse.write(ecodes.EV_KEY, ecodes.BTN_LEFT, 1)
            mouse.syn()
            try:
                time.sleep(0.04)
            finally:
                mouse.write(ecodes.EV_KEY, ecodes.BTN_LEFT, 0)
                mouse.syn()
            wait_for(lambda: not launcher())
        finally:
            move(original["x"], original["y"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--trials", type=int, default=10)
    args = parser.parse_args()
    if args.trials < 10:
        parser.error("at least ten IBus-active trials are required")
    command("systemctl", "--user", "is-active", "cybexos-input-method.service")
    live_check("begin")
    initial = hypr("activewindow").get("address")
    main_pid = command("systemctl", "--user", "show", "quickshell.service", "-p", "MainPID", "--value")
    try:
        with tempfile.TemporaryDirectory(prefix="cybex-launcher-input.") as temporary:
            scratch = Path(temporary)
            source = scratch / "Sink.qml"
            source.write_text(QML)
            with UInput({ecodes.EV_KEY: list(range(1, 256))},
                        name="Cybex launcher input regression") as keyboard:
                time.sleep(0.5)  # Wait for libinput to enumerate the device.
                for native, count in ((True, args.trials), (False, 1)):
                    environment = dict(os.environ, WAYLAND_DEBUG="client")
                    environment.pop("QT_IM_MODULE", None)
                    environment.pop("QT_IM_MODULES", None)
                    if not native:
                        environment["QT_IM_MODULE"] = "compose"
                    trace = scratch / "sink.log"
                    with trace.open("w") as log:
                        process = subprocess.Popen(["/usr/lib64/qt6/bin/qml", str(source)],
                                                   env=environment, stdout=log, stderr=log)
                        try:
                            sink = wait_for(lambda: next((w for w in hypr("clients")
                                                        if w["pid"] == process.pid and w["title"].startswith(PREFIX)), None))

                            def text():
                                return next(w for w in hypr("clients") if w["address"] == sink["address"])["title"][len(PREFIX):]

                            def guard(in_launcher):
                                assert process.poll() is None, "fixture exited"
                                assert command("systemctl", "--user", "show", "quickshell.service", "-p", "MainPID", "--value") == main_pid, "shell restarted"
                                active = hypr("activewindow").get("address")
                                surface = launcher()
                                assert not any(re.search(r"polkit|authentication|(^|[-_])lock($|[-_])", s["namespace"], re.I) for s in layers()), "authentication/lock surface is open"
                                if in_launcher:
                                    assert surface and str(surface["pid"]) == main_pid, "launcher is absent"
                                    # activewindow can retain the previous toplevel
                                    # while a layer has keyboard focus. Check the
                                    # fixture's actual wl_keyboard.leave as well.
                                    assert active in (None, "", sink["address"]), "unexpected window"
                                    events = re.findall(r"wl_keyboard#\d+\.(enter|leave)\(", trace.read_text())
                                    assert events and events[-1] == "leave", "fixture still has keyboard focus"
                                else:
                                    assert not surface and active == sink["address"], "fixture is not focused"

                            def key(code, in_launcher=False):
                                guard(in_launcher)
                                keyboard.write(ecodes.EV_KEY, code, 1)
                                keyboard.syn()
                                try:
                                    time.sleep(0.04)
                                finally:
                                    keyboard.write(ecodes.EV_KEY, code, 0)
                                    keyboard.syn()
                                time.sleep(0.08)

                            def hello(in_launcher=False):
                                for letter in "hello":
                                    key(getattr(ecodes, "KEY_" + letter.upper()), in_launcher)

                            ipc("close")
                            wait_for(lambda: not launcher())
                            focus(sink["address"])
                            time.sleep(0.4)
                            hello()
                            wait_for(lambda: text() == "hello")
                            enabled = bool(re.search(r"zwp_text_input_v3#\d+\.enable\(", trace.read_text()))
                            assert enabled == native, "control has the wrong input-method path"
                            guard(False)
                            keyboard.write(ecodes.EV_KEY, ecodes.KEY_LEFTCTRL, 1)
                            keyboard.syn()
                            try:
                                key(ecodes.KEY_A)
                            finally:
                                keyboard.write(ecodes.EV_KEY, ecodes.KEY_LEFTCTRL, 0)
                                keyboard.syn()
                            key(ecodes.KEY_BACKSPACE)
                            wait_for(lambda: text() == "")
                            for trial in range(count):
                                focus(sink["address"])
                                time.sleep(0.25)
                                guard(False)
                                ipc("open", "apps")
                                wait_for(launcher)
                                time.sleep(0.3)
                                hello(True)
                                time.sleep(0.2)
                                guard(True)
                                surface = launcher()
                                shot = scratch / "query.png"
                                command("grim", "-g", f"{surface['x']},{surface['y']} {surface['w']}x130", shot)
                                ocr = command("tesseract", shot, "stdout", "--psm", "6")
                                assert re.search(r"\bhello\b", ocr), f"launcher lost text: {ocr!r}"
                                assert text() == "", "keys reached the previous application"
                                print(f"PASS {'IBus' if native else 'non-IBus'} {trial + 1}/{count}", flush=True)
                                ipc("close")
                                wait_for(lambda: not launcher())
                            focus(sink["address"])
                            ipc("open", "apps")
                            wait_for(launcher)
                            time.sleep(0.3)
                            dismiss_outside(sink, guard)
                            print("PASS outside-click dismissal", flush=True)
                        finally:
                            try:
                                ipc("close")
                            finally:
                                process.terminate()
                                try:
                                    process.wait(timeout=5)
                                except subprocess.TimeoutExpired:
                                    process.kill()
                                    process.wait(timeout=5)
    finally:
        try:
            ipc("close")
            if initial and any(w["address"] == initial for w in hypr("clients")):
                focus(initial)
        finally:
            live_check("end")


def interrupt(*_):
    raise KeyboardInterrupt()


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, interrupt)
    main()
