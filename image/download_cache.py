"""Reuse only inventory-checksummed downloads, never builder-installed state."""
import argparse
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import tempfile
import urllib.request
import fcntl

import yaml
from build_support import atomic_json, digest

COPR_SHA256 = "581bd602d10705eb89003680335ffc3684b922c587073b6e52c371f949843fd7"


def pins(root):
    inventory = yaml.safe_load((Path(root) / "inventory/group_vars/all.yml").read_text())
    result = []
    for app in inventory.get("github_release_apps", []) + inventory.get("nerd_font_apps", []):
        tag = re.sub(r"[^A-Za-z0-9._+-]", "_", str(app["version"]))
        result.append((app["checksum"].removeprefix("sha256:"),
                       f"/var/cache/cybexos-upstream/{app['name']}/{tag}/", app["asset_regex"]))
    for font in inventory.get("pinned_font_archives", []):
        result.append((font["checksum"].removeprefix("sha256:"),
                       f"/var/cache/cybexos-upstream/{font['name']}/{font['version']}.zip", None))
    for font in inventory.get("pinned_font_files", []):
        for checksum, filename in (("checksum", "filename"), ("license_checksum", "license_filename")):
            result.append((font[checksum].removeprefix("sha256:"),
                           f"/usr/local/share/fonts/{font['name']}/{font['version']}/{font[filename]}", None))
    result.append((COPR_SHA256, "/home/builder/build/hyprland.gpg", None))
    return result


def allowed(entry, contract):
    path = entry.get("path", "")
    if not path.startswith("/") or ".." in PurePosixPath(path).parts or "\x00" in path:
        return False
    for checksum, location, pattern in contract:
        if entry.get("sha256") != checksum:
            continue
        if pattern is None and path == location:
            return True
        if pattern and str(PurePosixPath(path).parent) + "/" == location and re.search(pattern, PurePosixPath(path).name):
            return True
    return False


def verified_entries(directory, contract):
    directory = Path(directory)
    manifest = directory / "manifest.json"
    if not manifest.exists():
        return []
    result = []
    for entry in json.loads(manifest.read_text())["entries"]:
        if not allowed(entry, contract):
            continue  # An older inventory may leave obsolete entries; never import them.
        blob = directory / entry["sha256"]
        if blob.is_symlink() or not blob.is_file() or digest(blob) != entry["sha256"]:
            # Corrupt caches are disposable; miss rather than trust them.
            continue
        result.append(entry)
    return result


def merge_cache(source, destination, contract):
    source, destination = Path(source), Path(destination)
    destination.mkdir(parents=True, exist_ok=True)
    with (destination / ".lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        existing = {entry["path"]: entry for entry in verified_entries(destination, contract)}
        for entry in verified_entries(source, contract):
            target = destination / entry["sha256"]
            if not target.is_file() or digest(target) != entry["sha256"]:
                with tempfile.NamedTemporaryFile(dir=destination, delete=False) as stream:
                    temporary = Path(stream.name)
                try:
                    shutil.copyfile(source / entry["sha256"], temporary)
                    if digest(temporary) != entry["sha256"]:
                        raise ValueError("Download cache changed during transfer")
                    temporary.replace(target)
                finally:
                    temporary.unlink(missing_ok=True)
            existing[entry["path"]] = entry
        atomic_json(destination / "manifest.json", {"entries": list(existing.values())})


def export_cache(directory, contract, filesystem=Path("/")):
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    entries = []
    for checksum, location, pattern in contract:
        base = filesystem / location.lstrip("/")
        candidates = list(base.iterdir()) if pattern and base.is_dir() else ([] if pattern else [base])
        for candidate in candidates:
            if not candidate.is_file() or candidate.is_symlink():
                continue
            entry = {"path": "/" + str(candidate.relative_to(filesystem)), "sha256": checksum}
            if not allowed(entry, contract) or digest(candidate) != checksum:
                continue
            shutil.copyfile(candidate, directory / checksum)
            entries.append(entry)
    atomic_json(directory / "manifest.json", {"entries": entries})


def import_cache(directory, contract, filesystem=Path("/")):
    for entry in verified_entries(directory, contract):
        target = filesystem / entry["path"].lstrip("/")
        # Never let a poisoned guest path redirect a root copy outside its contract.
        if any(parent.is_symlink() for parent in [target, *target.parents]):
            raise ValueError("Refusing a symlink in download cache destination")
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(Path(directory) / entry["sha256"], target)
        target.chmod(0o644)


def cached_download(url, checksum, directory):
    """Content-addressed cloud base cache with verified atomic downloads."""
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    target = directory / checksum
    with (directory / (checksum + ".lock")).open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if target.is_file() and not target.is_symlink() and digest(target) == checksum:
            return target
        with tempfile.NamedTemporaryFile(dir=directory, prefix=".download-", delete=False) as stream:
            temporary = Path(stream.name)
        try:
            with urllib.request.urlopen(url, timeout=60) as response, temporary.open("wb") as stream:
                shutil.copyfileobj(response, stream)
            if digest(temporary) != checksum:
                raise ValueError("Downloaded builder image checksum mismatch")
            temporary.replace(target)
        finally:
            temporary.unlink(missing_ok=True)
    return target


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("import", "export"))
    parser.add_argument("directory", type=Path)
    args = parser.parse_args()
    if os.geteuid() != 0 or Path("/etc/hostname").read_text().strip() != "image-builder":
        parser.error("only the disposable image builder may import/export guest cache")
    contract = pins(Path(__file__).resolve().parents[1])
    (import_cache if args.action == "import" else export_cache)(args.directory, contract)


if __name__ == "__main__":
    main()
