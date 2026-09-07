#!/usr/bin/env python3
"""Store Model Usage management keys outside shell settings. Input is one line."""

import argparse
import json
import os
import stat
import sys
import tempfile


def key_path(source="cliproxy"):
    override = os.environ.get(f"QUICKSHELL_USAGE_{source.upper()}_KEY_PATH")
    if override:
        return os.path.abspath(os.path.expanduser(override))
    state_home = os.environ.get("XDG_STATE_HOME")
    if not state_home:
        state_home = os.path.join(os.path.expanduser("~"), ".local", "state")
    return os.path.join(os.path.expanduser(state_home), "quickshell",
                        f"model-usage-{source}.key")


def inspect(path):
    try:
        info = os.lstat(path)
    except FileNotFoundError:
        return False, None
    except OSError:
        return False, "Management key file could not be inspected."
    if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
            or stat.S_IMODE(info.st_mode) & 0o077):
        return False, "Management key file must be owned by you and mode 0600."
    return info.st_size > 0, None


def store(path):
    raw = sys.stdin.buffer.readline(8193)
    if len(raw) > 8192:
        raise ValueError("Management key is too large.")
    try:
        value = raw.decode("utf-8").strip()
    except UnicodeDecodeError as failure:
        raise ValueError("Management key is not valid text.") from failure
    if not value or any(ord(char) < 0x20 for char in value):
        raise ValueError("Management key is empty or invalid.")

    directory = os.path.dirname(path)
    os.makedirs(directory, mode=0o700, exist_ok=True)
    os.chmod(directory, 0o700)
    fd, temporary = tempfile.mkstemp(prefix=".model-usage-key-", dir=directory)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as output:
            fd = -1
            output.write(value + "\n")
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
        os.chmod(path, 0o600, follow_symlinks=False)
    finally:
        if fd >= 0:
            os.close(fd)
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def clear(path):
    configured, failure = inspect(path)
    if failure:
        raise ValueError(failure)
    if configured or os.path.lexists(path):
        os.unlink(path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("status", "store", "clear"))
    parser.add_argument("--source", choices=("cliproxy", "sub2api"), default="cliproxy")
    args = parser.parse_args()
    path = key_path(args.source)
    try:
        if args.action == "store":
            store(path)
        elif args.action == "clear":
            clear(path)
        configured, failure = inspect(path)
        if failure:
            raise ValueError(failure)
        result = {"success": True, "configured": configured}
        exit_code = 0
    except (OSError, ValueError) as failure:
        result = {"success": False, "configured": False, "error": str(failure)}
        exit_code = 1
    json.dump(result, sys.stdout, separators=(",", ":"))
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
