"""Transactional management of trusted user-owned plugin source trees."""

from contextlib import nullcontext
import json
import hashlib
import os
from pathlib import Path
import shutil
import stat
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
            mode = path.lstat().st_mode
            # Opening a FIFO blocks forever, and a device is not package
            # code. Neither is copied into a snapshot, so neither is hashed.
            if not stat.S_ISLNK(mode) and not stat.S_ISREG(mode):
                continue
            digest.update(str(path.relative_to(directory)).encode())
            if stat.S_ISLNK(mode):
                digest.update(os.readlink(path).encode())
            else:
                digest.update(path.read_bytes())
    return digest.hexdigest()


def stat_signature(directory):
    """Identify a tree by metadata alone: (signature, newest timestamp in ns).

    Hashing every file is what a rescan used to cost. Names, types, sizes and
    change times identify a revision without reading any contents; callers
    remember signature -> fingerprint and hash again only when this changes.
    """
    digest = hashlib.sha256()
    newest = 0
    for root, dirs, files in os.walk(directory, followlinks=False):
        dirs[:] = sorted(name for name in dirs if name != ".git")
        for name in sorted(files):
            path = os.path.join(root, name)
            info = os.lstat(path)
            digest.update(os.fsencode(os.path.relpath(path, directory)))
            digest.update(f"\0{info.st_mode}:{info.st_size}:{info.st_mtime_ns}:"
                          f"{info.st_ctime_ns}:{info.st_ino}\n".encode())
            newest = max(newest, info.st_mtime_ns, info.st_ctime_ns)
    return digest.hexdigest(), newest


def ignore_special(directory, names):
    """copytree filter: skip .git and anything but files, links and directories."""
    ignored = []
    for name in names:
        if name == ".git":
            ignored.append(name)
            continue
        mode = os.lstat(os.path.join(directory, name)).st_mode
        if not (stat.S_ISREG(mode) or stat.S_ISLNK(mode) or stat.S_ISDIR(mode)):
            ignored.append(name)
    return ignored


def managed_directory(packages, plugin_id):
    directory = packages / plugin_id
    if directory.is_symlink() or not directory.is_dir():
        raise ValueError("Expected a local plugin directory, not a symlink")
    return directory


# Network operations (clone, fetch) and validation run without `lock`: a slow
# remote may take minutes, and holding the registry lock that long would stall
# discovery and every other preference write. `lock` is taken only for the
# final rename and registry write, after re-checking what the unlocked phase
# assumed.
#
# `revision` pins the installed tree to one commit while keeping the default
# branch and its upstream, so a later `update` can still fast-forward it.
def install(packages, source, validate, read_object, lock=None, commit=None,
            revision=None, expected_id=None):
    packages.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".install-", dir=packages) as temporary:
        checkout = Path(temporary) / "checkout"
        git(packages, "clone", "--", source, str(checkout))
        if revision:
            git(checkout, "reset", "--hard", revision)
        plugin_id = read_object(checkout / "manifest.json").get("id")
        # Validate the ID before using it as a path.
        if not isinstance(plugin_id, str) or not plugin_id or "/" in plugin_id or plugin_id in (".", ".."):
            raise ValueError("Invalid manifest id")
        if expected_id is not None and plugin_id != expected_id:
            raise ValueError(f"Package id {plugin_id} does not match {expected_id}")
        candidate = Path(temporary) / plugin_id
        if candidate != checkout:
            checkout.rename(candidate)
        validate(Path(temporary), plugin_id)
        with (lock or nullcontext)():
            destination = packages / plugin_id
            if destination.exists() or destination.is_symlink():
                raise ValueError("Plugin already installed")
            candidate.rename(destination)
            if commit:
                try:
                    commit(plugin_id)
                except Exception:
                    shutil.rmtree(destination)
                    raise
        return plugin_id


def update(packages, plugin_id, validate, preview=False, lock=None):
    directory = managed_directory(packages, plugin_id)
    if git(directory, "rev-parse", "--show-toplevel") != str(directory.resolve()):
        raise ValueError("Plugin must be its own Git checkout")
    if git(directory, "status", "--porcelain", "--untracked-files=all"):
        raise ValueError("Plugin has local changes; commit or stash them before updating")
    branch = git(directory, "symbolic-ref", "--quiet", "--short", "HEAD")
    remote = git(directory, "config", "--get", "branch." + branch + ".remote")
    # Unlocked: a fetch adds only objects and remote-tracking refs, which
    # neither discovery nor code snapshots read.
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
    with (lock or nullcontext)():
        directory = managed_directory(packages, plugin_id)
        if (git(directory, "rev-parse", "HEAD") != previous
                or git(directory, "status", "--porcelain", "--untracked-files=all")):
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
            shutil.copytree(source, candidate, symlinks=True, ignore=ignore_special)
            manifest = read_object(candidate / "manifest.json")
        manifest["id"] = new_id
        manifest["omarchy"] = {**manifest.get("omarchy", {}), "clonedFrom": plugin_id}
        manifest["omarchy"].pop("clonePaths", None)
        (candidate / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        validate(Path(temporary), new_id)
        candidate.rename(destination)
