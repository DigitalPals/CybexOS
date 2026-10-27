"""Unprivileged Settings bridge; Polkit owns SSH authorization."""
import json
import os
import subprocess

HELPER = '/run/current-system/sw/bin/cybexos-ssh-server'


class SshSettings:
    def dispatch(self, request):
        action = request.get('action')
        if action == 'snapshot' and set(request) == {'action'}:
            command = [HELPER, 'status']
        elif action == 'set-enabled' and set(request) == {'action', 'enabled'} and type(request['enabled']) is bool:
            command = ['/run/wrappers/bin/pkexec', os.path.realpath(HELPER), 'enable' if request['enabled'] else 'disable']
        else:
            raise ValueError('Invalid SSH Server request')
        result = subprocess.run(command, capture_output=True, text=True, timeout=180)
        if result.returncode in (126, 127):
            raise ValueError('SSH Server authorization was cancelled or denied.')
        try:
            value = json.loads(result.stdout)
        except ValueError:
            raise ValueError('SSH Server did not return its status. Check its service and retry.') from None
        if result.returncode or value.get('success') is not True:
            raise ValueError(value.get('error') or 'Could not change SSH Server.')
        return value
