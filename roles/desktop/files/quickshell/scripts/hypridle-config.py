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


def render(settings, session_action):
    blocks = [
        "general {\n"
        f"  lock_cmd = {LOCK}\n"
        f"  before_sleep_cmd = {session_action} lock\n"
        f"  after_sleep_cmd = {DPMS_ON}\n"
        "}\n"
    ]
    if settings["idleLockMins"]:
        blocks.append(
            "listener {\n"
            f"  timeout = {settings['idleLockMins'] * 60}\n"
            f"  on-timeout = {LOCK}\n"
            "}\n")
    if settings["idleScreenOffMins"]:
        blocks.append(
            "listener {\n"
            f"  timeout = {settings['idleScreenOffMins'] * 60}\n"
            f"  on-timeout = {DPMS_OFF}\n"
            f"  on-resume = {DPMS_ON}\n"
            "}\n")
    if settings["idleSuspendMins"]:
        command = f"{session_action} idle-suspend"
        if settings["idleSuspendBatteryOnly"]:
            command += " on-battery"
        blocks.append(
            "listener {\n"
            f"  timeout = {settings['idleSuspendMins'] * 60}\n"
            f"  on-timeout = {command}\n"
            "}\n")
    return "\n".join(blocks)


def main(argv):
    if len(argv) != 3:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    sys.stdout.write(render(load_settings(argv[1]), argv[2]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
