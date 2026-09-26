#!/usr/bin/env python3
"""Launch one read-only Linux telemetry stream over the user's SSH connection.

exec keeps the SSH lifetime identical to the shell-owned Process. The probe
is sent as program text, never installed remotely. stdin remains available for
cadence/refresh requests; EOF ends the remote probe.
"""
import argparse
import os
from pathlib import Path
import re
import shlex


def command(host):
    # A destination is data, never SSH options, a URI or shell program.
    if not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_.@:%\[\]-]{0,253}", host):
        raise ValueError("Enter an SSH alias or user@hostname; set ports in ~/.ssh/config")
    source = Path(__file__).with_name("remote_server_probe.py").read_text()
    return [
        "ssh", "-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
        "-o", "ConnectTimeout=7", "-o", "ConnectionAttempts=1",
        "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=2",
        # Own this connection, including its teardown, even if ssh config
        # normally shares a persistent master with interactive terminals.
        "-o", "ControlMaster=no", "-o", "ControlPath=none",
        "-o", "ClearAllForwardings=yes", "-o", "ForwardAgent=no",
        "-o", "PermitLocalCommand=no", "-o", "RequestTTY=no",
        "--", host, "python3 -B -u -c " + shlex.quote(source),
    ]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("host")
    args = parser.parse_args()
    try:
        argv = command(args.host)
    except ValueError as error:
        parser.error(str(error))
    os.execvp(argv[0], argv)


if __name__ == "__main__":
    main()
