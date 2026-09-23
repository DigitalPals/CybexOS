#!/usr/bin/env python3
"""Render the hypridle configuration from the shell's idle settings.

cybexos-runtime runs this when hypridle starts without a user-owned
hypridle.conf. With default settings the output is byte-for-byte the vendor
hypridle.conf, which remains the fallback if this script fails.

Usage: hypridle-config.py SHELL_JSON SESSION_ACTION
"""

import json
import sys

# Mirrors Common/SettingsHelpers.js. A value outside these lists is treated as
# absent, exactly as the shell's merge does, so both agree on the timeouts.
DEFAULTS = {
    "idleLockMins": 5,
    "idleScreenOffMins": 10,
    "idleSuspendMins": 0,
    "idleSuspendBatteryOnly": False,
}
CHOICES = {
    "idleLockMins": (0, 1, 2, 5, 10, 15, 30),
    "idleScreenOffMins": (0, 1, 2, 5, 10, 15, 30),
    "idleSuspendMins": (0, 15, 30, 60, 120),
}

LOCK = "systemctl --user start cybexos-session-lock.service"
DPMS_OFF = "hyprctl eval 'hl.dispatch(hl.dsp.dpms({ action = \"off\" }))'"
DPMS_ON = "hyprctl eval 'hl.dispatch(hl.dsp.dpms({ action = \"on\" }))'"
# hypridle runs condition_cmd first and, when it fails, skips on-timeout and
# the matching on-resume, so a listener with this condition acts only on a
# locked session.
IS_LOCKED = "hyprctl locked | grep -qx true"
# Idle seconds after which a locked screen goes dark. Without it the lock
# screen stayed lit until the screen-off timeout, which counts from the last
# input before the lock.
LOCKED_SCREEN_OFF_SECS = 60


def load_settings(path):
    try:
        with open(path, encoding="utf-8") as handle:
            raw = json.load(handle)
    except FileNotFoundError:
        raw = {}
    if not isinstance(raw, dict):
        raw = {}
    settings = dict(DEFAULTS)
    for key, choices in CHOICES.items():
        value = raw.get(key)
        # bool is an int subclass; true must not pass as one minute.
        if type(value) is int and value in choices:
            settings[key] = value
    if isinstance(raw.get("idleSuspendBatteryOnly"), bool):
        settings["idleSuspendBatteryOnly"] = raw["idleSuspendBatteryOnly"]
    return settings


def listener(timeout, on_timeout, on_resume="", condition=""):
    lines = [f"timeout = {timeout}"]
    if condition:
        lines.append(f"condition_cmd = {condition}")
    lines.append(f"on-timeout = {on_timeout}")
    if on_resume:
        lines.append(f"on-resume = {on_resume}")
    return "listener {\n" + "".join(f"  {line}\n" for line in lines) + "}\n"


def render(settings, session_action):
    lock = settings["idleLockMins"] * 60
    screen_off = settings["idleScreenOffMins"] * 60
    suspend = settings["idleSuspendMins"] * 60
    # inhibit_sleep = 3 holds every suspend until the compositor reports the
    # session locked (logind caps the delay). hypridle's automatic mode would
    # not choose that here, because lock_cmd does not name hyprlock.
    general = (
        "general {\n"
        f"  lock_cmd = {LOCK}\n"
        f"  before_sleep_cmd = {session_action} lock\n"
        f"  after_sleep_cmd = {DPMS_ON}\n"
        "  inhibit_sleep = 3\n"
        "}\n")
    listeners = []
    if lock:
        listeners.append((lock, listener(lock, LOCK)))
    if screen_off:
        # hypridle fires a listener once per idle stretch, so a manual lock
        # and the idle lock each need one. Where the screen-off timeout comes
        # first they add nothing, and Never keeps a locked screen lit too.
        locked_off = [LOCKED_SCREEN_OFF_SECS]
        if lock:
            locked_off.append(lock + LOCKED_SCREEN_OFF_SECS)
        for timeout in locked_off:
            if timeout < screen_off:
                listeners.append((timeout, listener(
                    timeout, DPMS_OFF, DPMS_ON, IS_LOCKED)))
        listeners.append((screen_off, listener(screen_off, DPMS_OFF, DPMS_ON)))
    if suspend:
        command = f"{session_action} idle-suspend"
        if settings["idleSuspendBatteryOnly"]:
            command += " on-battery"
        listeners.append((suspend, listener(suspend, command)))
    # In timeout order, so the file reads as the idle timeline. The sort is
    # stable: the lock still precedes a check for it at the same second.
    listeners.sort(key=lambda item: item[0])
    return "\n".join([general] + [block for _, block in listeners])


def main(argv):
    if len(argv) != 3:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    sys.stdout.write(render(load_settings(argv[1]), argv[2]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
