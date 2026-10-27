"""A narrow, authenticated switch for the declared NixOS SSH service."""
import json
import os
from pathlib import Path
import subprocess
import sys

from .common import Failure, atomic, locked, read, syncdir

STATE = Path('/var/lib/cybexos/ssh-server')
CONFIG = Path('/etc/cybexos/ssh-server.json')


def status(state=STATE, config=CONFIG):
    settings = read(config, {})
    value = {'available': settings.get('available', False),
             'enabled': (state / 'enabled').is_file(), 'active': False,
             'user': settings.get('user', ''), 'ports': settings.get('ports', [22]), 'addresses': []}
    if not value['available']:
        return value
    result = subprocess.run(['systemctl', 'show', 'sshd.service', '-p', 'ActiveState', '--value'],
                            capture_output=True, text=True, timeout=10, check=True)
    addresses = []
    network = subprocess.run(['ip', '-j', 'address', 'show', 'up'],
                             capture_output=True, text=True, timeout=10, check=True)
    for interface in json.loads(network.stdout):
        for address in interface.get('addr_info', []):
            if address.get('scope') == 'global':
                addresses.append(address['local'])
    addresses.sort(key=lambda value: ':' in value)
    return value | {'active': result.stdout.strip() == 'active', 'addresses': addresses}


def change(action, state=STATE, config=CONFIG):
    if action not in ('enable', 'disable'):
        raise Failure('Choose enable or disable')
    if os.geteuid() != 0:
        raise Failure('Administrator authentication is required')
    if not read(config, {}).get('available'):
        raise Failure('SSH Server is unavailable in this system configuration')
    marker = state / 'enabled'
    with locked(state / 'operation.lock'):
        before = marker.is_file()
        if action == 'enable':
            atomic(marker, b'enabled\n', 0o644)
        try:
            subprocess.run(['systemctl', 'start' if action == 'enable' else 'stop', 'sshd.service'],
                           capture_output=True, timeout=30, check=True)
            if action == 'enable':
                subprocess.run(['systemctl', 'is-active', '--quiet', 'sshd.service'],
                               capture_output=True, timeout=10, check=True)
        except (OSError, subprocess.SubprocessError) as error:
            if action == 'enable' and not before:
                marker.unlink(missing_ok=True)
                syncdir(state)
                subprocess.run(['systemctl', 'stop', 'sshd.service'], capture_output=True, timeout=30)
            raise Failure('Could not change SSH Server. Check the sshd service log and retry.') from error
        if action == 'disable':
            marker.unlink(missing_ok=True)
            syncdir(state)
    return status(state, config)


def main():
    try:
        if len(sys.argv) != 2 or sys.argv[1] not in ('status', 'enable', 'disable'):
            raise Failure('Choose status, enable or disable')
        value = status() if sys.argv[1] == 'status' else change(sys.argv[1])
        print(json.dumps({'success': True, **value}))
    except (Failure, OSError, ValueError, subprocess.SubprocessError) as error:
        message = str(error) if isinstance(error, Failure) else 'Could not read SSH Server status. Check its service and retry.'
        print(json.dumps({'success': False, 'error': message}))
        return 1
    return 0
