#!/usr/bin/env python3
"""Stage a private management key over stdin; retain it only after commit."""

from __future__ import annotations

import json
import os
from pathlib import Path
import re
import select
import signal
import stat
import sys
import uuid

from model_usage_common import open_private_directory


def interrupted(_signum, _frame):
    raise InterruptedError


def main() -> int:
    directory_fd = None
    filenames = []
    committed = False
    signal.signal(signal.SIGTERM, interrupted)
    try:
        input_stream = os.fdopen(sys.stdin.fileno(), "rb", buffering=0, closefd=False)
        request = json.loads(input_stream.readline(65537))
        batch = "keys" in request
        keys = request.pop("keys") if batch else {"key": request.pop("key")}
        if not isinstance(keys, dict) or not 1 <= len(keys) <= 4:
            raise ValueError
        allowed = {"cliproxyKeyFile", "costKeeperPasswordFile"} if batch else {"key"}
        previous_paths = request.get("previousPaths", {}) if batch else {"key": request.get("previousPath", "")}
        if not isinstance(previous_paths, dict):
            raise ValueError
        for name, key in keys.items():
            if (name not in allowed and not (batch and re.fullmatch(r"t3Token_[a-zA-Z0-9-]{1,64}", name))) or not isinstance(key, str):
                raise ValueError
            key = key.strip()
            if not key or len(key) > 8191 or any(ord(c) < 32 or ord(c) > 126 for c in key):
                raise ValueError
            keys[name] = key
        config_home = Path(os.environ.get("XDG_CONFIG_HOME") or (Path.home() / ".config"))
        directory = config_home / "omarchy" / "model-usage" / "management-keys"
        directory_fd = open_private_directory(directory, create=True)
        paths = {}
        for name, key in keys.items():
            filename = "key-" + uuid.uuid4().hex + ".key"
            fd = os.open(filename, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                         0o600, dir_fd=directory_fd)
            filenames.append(filename)
            with os.fdopen(fd, "w", encoding="ascii") as stream:
                stream.write(key + "\n")
                stream.flush()
                os.fsync(stream.fileno())
            paths[name] = str(directory / filename)
        key = ""
        keys.clear()
        print(json.dumps({"paths": paths} if batch else {"path": paths["key"]}), flush=True)
        # Use unbuffered stdin reads for both messages: TextIO buffering can
        # otherwise hide an already-received commit from select().
        if select.select([input_stream], [], [], 5)[0]:
            committed = input_stream.readline(32).strip() == b"commit"
        if committed:
            for name in paths:
                previous = Path(str(previous_paths.get(name, ""))).expanduser()
                if previous.parent == directory and re.fullmatch(r"key-[0-9a-f]{32}\.key", previous.name):
                    try:
                        info = os.stat(previous.name, dir_fd=directory_fd, follow_symlinks=False)
                        if stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid():
                            os.unlink(previous.name, dir_fd=directory_fd)
                    except OSError:
                        pass
            return 0
        return 1
    except (OSError, ValueError, TypeError, KeyError, AttributeError):
        # Never print exception details, request contents, or the key.
        return 1
    finally:
        if directory_fd is not None:
            if not committed:
                for filename in filenames:
                    try:
                        os.unlink(filename, dir_fd=directory_fd)
                    except OSError:
                        pass
            os.close(directory_fd)


if __name__ == "__main__":
    raise SystemExit(main())
