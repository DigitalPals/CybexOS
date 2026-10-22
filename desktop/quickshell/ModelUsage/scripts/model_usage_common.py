"""Shared state-file and error-sanitizing helpers for Model Usage backends."""

from __future__ import annotations

import errno
import json
import os
import re
import secrets
import stat
from pathlib import Path
from typing import Any


def clean_message(value: Any) -> str:
    """Return a short display-safe message with common credential forms removed."""
    text = str(value or "").replace("\n", " ").replace("\r", " ").strip()
    text = re.sub(r"(?i)bearer\s+[a-z0-9._~+/=-]+", "Bearer [redacted]", text)
    key = r"(?:access[_ -]?token|refresh[_ -]?token|api[_ -]?key|authorization)"
    text = re.sub(
        rf"(?i)([\"']?{key}[\"']?\s*[:=]\s*)(?:\"[^\"]*\"|'[^']*'|\S+)",
        r"\1[redacted]",
        text,
    )
    return text[:300]


def _check_directory(fd: int, *, private: bool, tighten: bool = False) -> None:
    info = os.fstat(fd)
    uid = os.getuid()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid not in ((uid,) if private else (0, uid)):
        raise PermissionError(errno.EACCES, "State directory has an unsafe owner or type")
    # Root-owned sticky ancestors (e.g. /tmp) protect each user's entries.
    # A private leaf may never be writable by another user or group.
    sticky_root = not private and info.st_uid == 0 and info.st_mode & stat.S_ISVTX
    if info.st_mode & 0o022 and not sticky_root:
        raise PermissionError(errno.EACCES, "State directory is writable by others")
    if private and stat.S_IMODE(info.st_mode) != 0o700:
        if not tighten or info.st_mode & 0o700 != 0o700:
            raise PermissionError(errno.EACCES, "State directory must have private permissions")
        # Preserve support for owned 0755 state directories without following
        # a pathname or changing permissions on any ancestor or foreign inode.
        os.fchmod(fd, 0o700)


def open_private_directory(path: Path, *, create: bool = False, tighten: bool = False) -> int:
    """Return an owned private dirfd; the caller must close it.

    Walk from / using O_NOFOLLOW for *every* component. Existing ancestors
    must be owned by root or this user and not writable by other users, except
    root-owned sticky directories. Missing components are created at 0700.
    Reject parent traversal rather than normalizing it through a symlink.
    """
    path = Path(path)
    if ".." in path.parts:
        raise PermissionError(errno.EACCES, "Parent traversal is not allowed for private state")
    if not path.is_absolute():
        path = Path.cwd() / path
    parts = path.parts[1:]
    if not parts:
        raise PermissionError(errno.EACCES, "The filesystem root is not a private state directory")
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
    directory_fd = os.open("/", flags)
    try:
        _check_directory(directory_fd, private=False)
        for index, part in enumerate(parts):
            try:
                child_fd = os.open(part, flags, dir_fd=directory_fd)
            except FileNotFoundError:
                if not create:
                    raise
                try:
                    os.mkdir(part, 0o700, dir_fd=directory_fd)
                except FileExistsError:
                    pass  # Another collector may have created it; validate it below.
                child_fd = os.open(part, flags, dir_fd=directory_fd)
            try:
                _check_directory(child_fd, private=index == len(parts) - 1, tighten=tighten)
            except BaseException:
                os.close(child_fd)
                raise
            os.close(directory_fd)
            directory_fd = child_fd
        return directory_fd
    except BaseException:
        os.close(directory_fd)
        raise


def atomic_write_json(path: Path, payload: Any) -> None:
    """Atomically replace JSON state using only a validated, pinned dirfd."""
    path = Path(path)
    directory_fd = open_private_directory(path.parent, create=True, tighten=True)
    temporary_name = None
    fd = None
    try:
        for _ in range(16):
            candidate = ".model-usage-" + secrets.token_hex(16) + ".tmp"
            try:
                fd = os.open(candidate, os.O_WRONLY | os.O_CREAT | os.O_EXCL
                             | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600, dir_fd=directory_fd)
            except FileExistsError:
                continue
            temporary_name = candidate
            break
        else:
            raise FileExistsError(errno.EEXIST, "Could not create private temporary state")
        os.fchmod(fd, 0o600)
        handle = os.fdopen(fd, "w", encoding="utf-8")
        fd = None  # The file object now owns the descriptor.
        with handle:
            json.dump(payload, handle, separators=(",", ":"), sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        # Replaces the directory entry itself, even if the old entry is a
        # symlink or hard link; its referent is never opened or chmodded.
        os.replace(temporary_name, path.name, src_dir_fd=directory_fd, dst_dir_fd=directory_fd)
        temporary_name = None
        os.fsync(directory_fd)
    finally:
        if fd is not None:
            os.close(fd)
        if temporary_name is not None:
            try:
                os.unlink(temporary_name, dir_fd=directory_fd)
            except OSError:
                pass
        os.close(directory_fd)
