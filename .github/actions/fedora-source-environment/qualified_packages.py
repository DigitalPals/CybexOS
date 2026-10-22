#!/usr/bin/env python3
"""Use the installed product's package-series contract in source CI."""
import argparse
import importlib.util
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location("cybexos_versionlock", ROOT / "image/library/cybexos_versionlock.py")
policy = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(policy)


def prepare(series, path):
    _, preserved = policy.manage(path, series)
    if preserved:
        raise ValueError(f"Cannot enforce qualified packages: {preserved}")


def verify(series, names, installed=policy.installed_evr):
    policy.validate_series(series)
    selected = [entry for entry in series if entry["name"] in names]
    unknown = set(names) - {entry["name"] for entry in selected}
    if unknown:
        raise ValueError("No qualified series for " + ", ".join(sorted(unknown)))
    versions = {entry["name"]: installed(entry["name"]) for entry in selected}
    problems = policy.outside_series(selected, versions.get, require=True)
    if problems:
        raise ValueError("; ".join(problems))
    return versions


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("prepare", "verify"))
    parser.add_argument("packages", nargs="*", default=["quickshell"])
    parser.add_argument("--lock-file", type=Path, default=Path(policy.DEFAULT_PATH))
    args = parser.parse_args()
    try:
        inventory = yaml.safe_load((ROOT / "inventory/group_vars/all.yml").read_text())
        series = inventory["qualified_package_series"]
        if args.command == "prepare":
            prepare(series, args.lock_file)
        else:
            for name, version in verify(series, args.packages or ["quickshell"]).items():
                print(f"Qualified runtime: {name} {version}")
    except (OSError, ValueError, KeyError) as error:
        parser.exit(1, f"qualified packages: {error}\n")


if __name__ == "__main__":
    main()
