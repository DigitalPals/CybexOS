"""Validate the built compositor configuration in a disposable namespace."""
import os
from pathlib import Path
import re
import shutil
import subprocess

from .common import Failure


def compositor_command(system, check):
    system = Path(system).resolve()
    if not re.fullmatch(r'/nix/store/[a-z0-9]{32}-[^/]+', str(system)):
        raise Failure('Desktop validation requires a built NixOS system')
    executable = shutil.which('Hyprland')
    sandbox = shutil.which('bwrap')
    shell = shutil.which('bash')
    if not executable or not sandbox or not shell:
        raise Failure('Candidate compositor or isolated configuration checker is missing')
    # No host /etc, home, devices, sockets, network or persistent writes. The
    # exact candidate /etc/nerdos tree keeps absolute runtime/plugin paths
    # identical to an installed boot without changing the running machine.
    args = [sandbox, '--unshare-all', '--die-with-parent', '--new-session',
            '--ro-bind', '/nix/store', '/nix/store', '--proc', '/proc', '--dev', '/dev',
            '--tmpfs', '/tmp', '--tmpfs', '/run', '--dir', '/etc',
            '--ro-bind', str(system / 'etc/nerdos'), '/etc/nerdos',
            '--ro-bind', str(system / 'sw'), '/run/current-system/sw',
            '--dir', '/bin', '--symlink', shell, '/bin/sh',
            '--dir', '/home/check/.config', '--dir', '/home/check/.local/state',
            '--dir', '/home/check/.local/share', '--perms', '0700', '--dir', '/run/check',
            '--ro-bind', str(check), '/tmp/verify.lua', '--clearenv',
            '--setenv', 'PATH', os.environ.get('PATH', ''),
            '--setenv', 'HOME', '/home/check', '--setenv', 'XDG_RUNTIME_DIR', '/run/check',
            '--setenv', 'XDG_CONFIG_HOME', '/home/check/.config',
            '--setenv', 'XDG_STATE_HOME', '/home/check/.local/state',
            '--setenv', 'XDG_DATA_HOME', '/home/check/.local/share',
            '--setenv', 'HYPRLAND_NO_RT', '1', '--chdir', '/tmp',
            '--', executable, '--i-am-really-stupid', '--verify-config', '--config', '/tmp/verify.lua']
    return args


def verify_compositor(system, directory, run=subprocess.run):
    check = Path(directory) / 'verify.lua'
    check.write_text('''dofile("/etc/nerdos/runtime/hypr/hyprland.lua")
assert(not __nerdos_displays_error, "vendor display module failed")
assert(not __nerdos_input_error, "vendor input module failed")
assert(not __nerdos_workspaces_error, "vendor workspace module failed")
assert(type(__nerdos_workspaces) == "table", "vendor workspace module is absent")
assert(__nerdos_workspaces.error == "", "vendor workspace/plugin setup failed")
''')
    result = run(compositor_command(system, check), capture_output=True, text=True, timeout=60)
    if result.returncode:
        raise Failure('Candidate Hyprland configuration validation failed in its isolated namespace. '
                      'Inspect the private transaction log; namespace restrictions or Lua/plugin errors must be corrected.\n'
                      + (result.stdout + result.stderr)[-3000:])
