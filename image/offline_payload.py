"""Independently version the large, offline application payload.

Run `python3 image/offline_payload.py --version X.Y.Z` when changing its
reviewed inputs. Desktop-only changes do not advance this RPM's identity.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = "cybexos-offline-apps"
PREFIXES = (
    "opt/cybexos-apps", "opt/cybexos-builds", "usr/local/bin", "usr/local/libexec",
    "usr/local/share/fonts", "usr/local/share/applications/omawrite.desktop",
    "usr/share/icons/hicolor/scalable/apps/omawrite.svg",
    "usr/share/cybexos/user-seed", "usr/share/cybexos/final-seed",
    "usr/share/cybexos/seed-groups.json", "usr/share/licenses/cybexos-fonts",
    "usr/share/cybexos/offline-inputs.json",
)
INPUTS = (
    "inventory/group_vars/all.yml", "roles/apps", "roles/dotfiles", "image/applications",
    "image/applications.yml", "image/application_payload.py", "image/offline_payload.py", "image/package",
    "assets/EDM115-newline2.omp.json", "assets/nautilus-localsend.py",
    "assets/desktop-contract.json", "image/desktop_payload.py",
    "image/system_packages.py", "image/live.ks", "image/cybexos-desktop.spec",
    "roles/base/defaults/main.yml", "roles/desktop/tasks/main.yml",
    "roles/xps-2026/tasks/packages.yml",
)


def input_digest(root=ROOT):
    records = []
    for relative in INPUTS:
        source = root / relative
        if not source.exists():
            raise ValueError(f"Missing offline application input: {relative}")
        files = sorted(source.rglob("*")) if source.is_dir() else [source]
        for path in files:
            if path.is_file() and not path.is_symlink() and "__pycache__" not in path.parts and path.suffix != ".pyc":
                records.append((path.relative_to(root).as_posix(), hashlib.sha256(path.read_bytes()).hexdigest()))
    return hashlib.sha256(json.dumps(records, separators=(",", ":")).encode()).hexdigest()


def configuration(root=ROOT):
    config = json.loads((root / "image/offline-payload.json").read_text())
    if set(config) != {"version", "inputs_sha256"} or not re.fullmatch(r"\d+\.\d+\.\d+", config["version"]):
        raise ValueError("Offline payload requires an independent X.Y.Z version and input digest")
    if config["inputs_sha256"] != input_digest(root):
        raise ValueError("Offline application inputs changed: run python3 image/offline_payload.py --version NEW_VERSION")
    return config


def file_lists(payload):
    """Directory entries recurse in RPM; both packages partition one payload."""
    return ["/" + relative for relative in PREFIXES
            if (payload / relative).exists() or (payload / relative).is_symlink()]


def inventory(payload):
    result = {"bytes": 0, "files": 0, "groups": {}}
    for relative in PREFIXES:
        source = payload / relative
        paths = list(source.rglob("*")) if source.is_dir() else [source]
        sizes = [path.stat().st_size for path in paths if path.is_file() and not path.is_symlink()]
        result["groups"][relative] = {"bytes": sum(sizes), "files": len(sizes)}
        result["bytes"] += sum(sizes)
        result["files"] += len(sizes)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", help="Advance the offline payload version and record its reviewed inputs")
    args = parser.parse_args()
    path = ROOT / "image/offline-payload.json"
    if args.version:
        if not re.fullmatch(r"\d+\.\d+\.\d+", args.version):
            parser.error("version must be X.Y.Z")
        if path.exists():
            previous = json.loads(path.read_text())
            if previous["inputs_sha256"] != input_digest() and tuple(map(int, args.version.split("."))) <= tuple(map(int, previous["version"].split("."))):
                parser.error("Changed offline inputs require a newer version")
        path.write_text(json.dumps({"version": args.version, "inputs_sha256": input_digest()}, indent=2) + "\n")
    print(json.dumps(configuration(), indent=2))


if __name__ == "__main__":
    main()
