"""Transactional management of trusted user-owned plugin source trees."""

import json
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


def git(directory, *args):
    result = subprocess.run(["git", "-c", "core.hooksPath=/dev/null", "-C", str(directory), *args],
                            text=True, capture_output=True, timeout=120,
                            env={**os.environ, "GIT_TERMINAL_PROMPT": "0"})
    if result.returncode:
        raise ValueError(result.stderr.strip() or "Git operation failed")
    return result.stdout.strip()


def fingerprint(directory):
    digest = hashlib.sha256()
    for root, dirs, files in os.walk(directory, followlinks=False):
        dirs[:] = sorted(name for name in dirs if name != ".git")
        for name in sorted(files):
            path = Path(root) / name
            digest.update(str(path.relative_to(directory)).encode())
            if path.is_symlink():
                digest.update(os.readlink(path).encode())
            else:
                digest.update(path.read_bytes())
    return digest.hexdigest()


def managed_directory(packages, plugin_id):
    directory = packages / plugin_id
    if directory.is_symlink() or not directory.is_dir():
        raise ValueError("Expected a local plugin directory, not a symlink")
    return directory


def install(packages, source, validate, read_object):
    packages.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".install-", dir=packages) as temporary:
        checkout = Path(temporary) / "checkout"
        git(packages, "clone", "--", source, str(checkout))
        plugin_id = read_object(checkout / "manifest.json").get("id")
        # Validate the ID before using it as a path.
        if not isinstance(plugin_id, str) or not plugin_id or "/" in plugin_id or plugin_id in (".", ".."):
            raise ValueError("Invalid manifest id")
        candidate = Path(temporary) / plugin_id
        if candidate != checkout:
            checkout.rename(candidate)
        validate(Path(temporary), plugin_id)
        destination = packages / plugin_id
        if destination.exists() or destination.is_symlink():
            raise ValueError("Plugin already installed")
        candidate.rename(destination)
        return plugin_id


def update(packages, plugin_id, validate, preview=False):
    directory = managed_directory(packages, plugin_id)
    if git(directory, "rev-parse", "--show-toplevel") != str(directory.resolve()):
        raise ValueError("Plugin must be its own Git checkout")
    if git(directory, "status", "--porcelain", "--untracked-files=all"):
        raise ValueError("Plugin has local changes; commit or stash them before updating")
    branch = git(directory, "symbolic-ref", "--quiet", "--short", "HEAD")
    remote = git(directory, "config", "--get", "branch." + branch + ".remote")
    git(directory, "fetch", "--", remote)
    upstream = git(directory, "rev-parse", "@{upstream}")
    previous = git(directory, "rev-parse", "HEAD")
    git(directory, "merge-base", "--is-ancestor", previous, upstream)
    diff = git(directory, "diff", "--stat", previous, upstream)
    if preview:
        return diff or "Already up to date"
    # Validate a detached candidate first. The installed tree is never reset on
    # validation failure, and local edits are never discarded.
    with tempfile.TemporaryDirectory(prefix=".update-", dir=packages) as temporary:
        candidate = Path(temporary) / plugin_id
        git(packages, "clone", "--no-hardlinks", "--", str(directory), str(candidate))
        git(candidate, "checkout", "--detach", upstream)
        validate(Path(temporary), plugin_id)
    if git(directory, "status", "--porcelain", "--untracked-files=all"):
        raise ValueError("Plugin changed during validation; update was not applied")
    git(directory, "merge", "--ff-only", upstream)
    return diff or "Already up to date"


def clone(packages, plugin_id, new_id, validate, read_object, builtin_root=None):
    manifest_path = None
    if builtin_root:
        builtin_root = Path(builtin_root).resolve()
        for path in (builtin_root / "shell/plugins").rglob("*manifest.json"):
            if read_object(path).get("id") == plugin_id:
                manifest_path = path
                break
        if manifest_path is None:
            raise ValueError("Built-in plugin not found in the supplied Omarchy checkout")
        source = manifest_path.parent
    else:
        source = managed_directory(packages, plugin_id)
        validate(packages, plugin_id)
    destination = packages / new_id
    if destination.exists() or destination.is_symlink():
        raise ValueError("Clone destination already exists")
    with tempfile.TemporaryDirectory(prefix=".clone-", dir=packages) as temporary:
        candidate = Path(temporary) / new_id
        if manifest_path and manifest_path.name != "manifest.json":
            manifest = read_object(manifest_path)
            candidate.mkdir()
            mappings = [{"source": path, "target": path} for path in manifest["entryPoints"].values()]
            mappings += manifest.get("omarchy", {}).get("clonePaths", [])
            for mapping in mappings:
                origin = (source / mapping["source"]).resolve()
                target = candidate / mapping["target"]
                if not origin.is_relative_to(builtin_root) or not target.resolve().is_relative_to(candidate):
                    raise ValueError("Clone path escapes source or destination")
                target.parent.mkdir(parents=True, exist_ok=True)
                if origin.is_dir():
                    shutil.copytree(origin, target, dirs_exist_ok=True)
                else:
                    shutil.copy2(origin, target)
            for path in candidate.rglob("*"):
                if path.suffix in (".qml", ".js"):
                    text = path.read_text()
                    for mapping in mappings:
                        text = text.replace(mapping["source"], mapping["target"])
                    path.write_text(text)
        else:
            shutil.copytree(source, candidate, symlinks=True, ignore=shutil.ignore_patterns(".git"))
            manifest = read_object(candidate / "manifest.json")
        manifest["id"] = new_id
        manifest["omarchy"] = {**manifest.get("omarchy", {}), "clonedFrom": plugin_id}
        manifest["omarchy"].pop("clonePaths", None)
        (candidate / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        validate(Path(temporary), new_id)
        candidate.rename(destination)
