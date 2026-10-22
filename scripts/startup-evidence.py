#!/usr/bin/env python3
"""Capture read-only boot diagnostics or compare equivalent boot samples."""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import statistics
import subprocess


def command(arguments):
    try:
        result = subprocess.run(arguments, capture_output=True, text=True, timeout=20,
                                check=False)
        return {"status": result.returncode, "stdout": result.stdout[:262144],
                "stderr": result.stderr[:4096]}
    except (OSError, subprocess.TimeoutExpired) as error:
        return {"status": None, "error": str(error)}


def read(path):
    try:
        return Path(path).read_text().strip()
    except OSError:
        return ""


def capture(args):
    diagnostics = {}
    for scope in ("system", "user"):
        option = ["--user"] if scope == "user" else []
        for query in ("time", "critical-chain", "blame"):
            diagnostics[scope + "_" + query] = command(["systemd-analyze", *option, query])
    diagnostics["units"] = command([
        "systemctl", "--user", "show", "hyprland-session.target", "quickshell.service",
        "xdg-desktop-portal.service", "xdg-desktop-portal-hyprland.service",
        "-p", "Id", "-p", "ActiveEnterTimestampMonotonic", "-p", "ExecMainStartTimestampMonotonic",
        "-p", "Result", "-p", "InvocationID"])
    diagnostics["boot_timestamps"] = command([
        "systemctl", "show", "-p", "FirmwareTimestampMonotonic", "-p", "LoaderTimestampMonotonic",
        "-p", "KernelTimestampMonotonic", "-p", "InitRDTimestampMonotonic",
        "-p", "UserspaceTimestampMonotonic", "-p", "FinishTimestampMonotonic"])
    diagnostics["session_journal"] = command([
        "journalctl", "--user", "-b", "-n", "500", "--no-pager", "-o", "short-monotonic",
        "-u", "hyprland-session.target", "-u", "quickshell.service",
        "-u", "xdg-desktop-portal.service", "-u", "xdg-desktop-portal-hyprland.service"])
    diagnostics["boot_manager"] = command(["bootctl", "status"])
    diagnostics["binfmt_units"] = command([
        "systemctl", "cat", "systemd-binfmt.service", "proc-sys-fs-binfmt_misc.mount",
        "proc-sys-fs-binfmt_misc.automount"])
    diagnostics["desktop_packages"] = command(["nix", "path-info", "/run/current-system"])
    return {"v": 1, "revision": args.revision, "configuration": args.configuration,
            "bootKind": args.boot_kind, "loginKind": args.login_kind,
            "bootId": read("/proc/sys/kernel/random/boot_id"),
            "host": hashlib.sha256(read("/etc/machine-id").encode()).hexdigest(),
            "kernel": platform.release(), "architecture": platform.machine(),
            "milestonesSeconds": {"desktopReady": args.desktop_ready_seconds,
                                  "portalReady": args.portal_ready_seconds,
                                  "humanAuthentication": args.authentication_seconds},
            "milestoneEvidence": args.milestone_evidence,
            "diagnostics": diagnostics}


def compare(before, after):
    samples = before + after
    if not before or not after:
        raise ValueError("both before and after samples are required")
    for key in ("host", "configuration", "bootKind", "loginKind", "architecture", "kernel"):
        if len({sample.get(key) for sample in samples}) != 1 or not samples[0].get(key):
            raise ValueError("samples must share an explicit " + key)
    if samples[0]["bootKind"] not in ("cold", "warm"):
        raise ValueError("cold and warm boots must be identified and analyzed separately")
    if samples[0]["loginKind"] not in ("first", "normal"):
        raise ValueError("first and normal logins must be identified separately")
    packages = []
    for sample in samples:
        diagnostic = sample.get("diagnostics", {}).get("desktop_packages", {})
        lines = diagnostic.get("stdout", "")
        if diagnostic.get("status") != 0 or not isinstance(lines, str) or not lines.strip():
            raise ValueError("successful desktop dependency capture is required; qualification is blocked")
        packages.append(tuple(sorted(line.strip() for line in lines.splitlines() if line.strip())))
    if len(set(packages)) != 1:
        raise ValueError("samples have different desktop dependency versions")
    if len({sample.get("bootId") for sample in samples}) != len(samples):
        raise ValueError("repeated captures of the same boot are not independent samples")
    output = {"v": 1, "status": "passed", "kernel": samples[0]["kernel"],
              "desktopPackages": list(packages[0]), "comparison": {}}
    for name, group in (("before", before), ("after", after)):
        if len(group) < 3 or any(not sample.get("bootId") for sample in group):
            raise ValueError("at least three identified boots are required per revision")
        revisions = {sample.get("revision") for sample in group}
        if len(revisions) != 1 or not next(iter(revisions)):
            raise ValueError("each group must use one identified source revision")
        summary = {"revision": next(iter(revisions)), "boots": len(group)}
        for milestone in ("desktopReady", "portalReady", "humanAuthentication"):
            values = [sample.get("milestonesSeconds", {}).get(milestone) for sample in group]
            if any(type(value) not in (int, float) or not 0 <= value < 86400 for value in values):
                raise ValueError("missing or invalid measured " + milestone + "; qualification is blocked")
            if milestone != "humanAuthentication" and any(not sample.get("milestoneEvidence") for sample in group):
                raise ValueError("desktop and portal readiness require recorded observation evidence")
            summary[milestone] = {"medianSeconds": statistics.median(values),
                                  "minimumSeconds": min(values), "maximumSeconds": max(values)}
        output["comparison"][name] = summary
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    actions = parser.add_subparsers(dest="action", required=True)
    collect = actions.add_parser("capture", help="read diagnostics without changing the session")
    collect.add_argument("--revision", required=True)
    collect.add_argument("--configuration", required=True, help="same hardware and configuration label for comparisons")
    collect.add_argument("--boot-kind", choices=("cold", "warm"), required=True)
    collect.add_argument("--login-kind", choices=("first", "normal"), required=True)
    collect.add_argument("--desktop-ready-seconds", type=float)
    collect.add_argument("--portal-ready-seconds", type=float)
    collect.add_argument("--authentication-seconds", type=float)
    collect.add_argument("--milestone-evidence", default="", help="observer log/evidence identifying the measured milestones")
    comparison = actions.add_parser("compare")
    comparison.add_argument("--before", type=Path, nargs="+", required=True)
    comparison.add_argument("--after", type=Path, nargs="+", required=True)
    args = parser.parse_args()
    if args.action == "capture":
        result = capture(args)
    else:
        try:
            result = compare([json.loads(path.read_text()) for path in args.before],
                             [json.loads(path.read_text()) for path in args.after])
        except (OSError, ValueError, TypeError) as error:
            parser.error(str(error))
    print(json.dumps(result, indent=2, allow_nan=False))


if __name__ == "__main__":
    main()
