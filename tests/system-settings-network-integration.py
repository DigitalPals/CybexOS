#!/usr/bin/env python3
"""Invoked only inside system-settings-network-namespace's private system bus."""
import importlib
from pathlib import Path
import subprocess
import sys
import time

if not Path('/run/cybexos-settings-test').exists():
    sys.exit('Run tests/system-settings-network-namespace; this test must not use the host bus')

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'roles/desktop/files/quickshell/scripts'))
NetworkSettings = importlib.import_module('system_settings_network').NetworkSettings


def draft():
    return next(p for p in NetworkSettings().snapshot()['profiles'] if p['name'] == 'settings-fixture')


def persistent_address():
    files = list(Path('/etc/NetworkManager/system-connections').glob('*'))
    assert len(files) == 1
    return files[0].read_text()


def apply(address):
    request = draft()
    request['action'] = 'apply'
    request['ipv4']['addresses'] = address + '/24'
    return NetworkSettings().dispatch(request)


trial = apply('192.0.2.2')
assert 'checkpoint' in trial
assert '192.0.2.1/24' in persistent_address(), 'Trial wrote to persistent storage before confirmation'
assert draft()['ipv4']['addresses'] == '192.0.2.2/24'
NetworkSettings().dispatch(dict(action='rollback', checkpoint=trial['checkpoint']))
assert draft()['ipv4']['addresses'] == '192.0.2.1/24', 'Explicit rollback lost the original profile'

trial = apply('192.0.2.3')
NetworkSettings().dispatch(dict(trial, action='confirm'))
assert '192.0.2.3/24' in persistent_address(), 'Confirmed settings were not persisted'
assert not NetworkSettings().client.get_checkpoints(), 'Confirmed checkpoint was not released'

# Simulate losing the shell/helper after applying. NetworkManager owns rollback.
trial = apply('192.0.2.4')
service = NetworkSettings()
service.call('/org/freedesktop/NetworkManager', 'org.freedesktop.NetworkManager',
             'CheckpointAdjustRollbackTimeout', '(ou)', (trial['checkpoint'], 1))
time.sleep(2)
assert draft()['ipv4']['addresses'] == '192.0.2.3/24', 'Timed rollback failed'
assert '192.0.2.3/24' in persistent_address()
try:
    NetworkSettings().dispatch(dict(trial, action='confirm'))
except ValueError:
    pass
else:
    raise AssertionError('Expired trial was accepted')

# Editing an inactive profile must save without activating a device.
subprocess.run(['nmcli', 'connection', 'down', 'settings-fixture'], check=True, capture_output=True)
request = draft()
request.update(action='apply', metered=1)
result = NetworkSettings().dispatch(request)
assert 'checkpoint' not in result
assert draft()['metered'] == 1 and not draft()['active']
subprocess.run(['nmcli', 'connection', 'add', 'type', 'wifi', 'ifname', 'fixture-wifi',
                'con-name', 'secrets-fixture', 'ssid', 'Fixture',
                '802-11-wireless-security.key-mgmt', 'wpa-psk',
                '802-11-wireless-security.psk', 'fixture-password',
                'connection.autoconnect', 'no'], check=True, capture_output=True)
request = next(p for p in NetworkSettings().snapshot()['profiles'] if p['name'] == 'secrets-fixture')
request.update(action='apply', metered=1)
NetworkSettings().dispatch(request)
secret = subprocess.check_output(['nmcli', '--show-secrets', '-g', '802-11-wireless-security.psk',
                                  'connection', 'show', 'secrets-fixture'], text=True).strip()
assert secret == 'fixture-password', 'Updating a profile lost its saved secret'
print('PASS real NetworkManager: trial, rollback, persistence, timeout, stale confirmation, inactive edit, saved-secret preservation')
