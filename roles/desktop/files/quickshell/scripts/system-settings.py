#!/usr/bin/env python3
"""Bounded, unprivileged system settings requests. No credentials cross this API."""
import json
import sys

from system_settings_audio import AudioSettings
from system_settings_network import NetworkSettings
from system_settings_accounts import AccountSettings


def main():
    try:
        if len(sys.argv) != 2 or sys.argv[1] not in ('sound', 'network', 'accounts'):
            raise ValueError('Unknown settings service')
        raw = sys.stdin.buffer.readline(65537)
        if len(raw) > 65536:
            raise ValueError('Settings request is too large')
        request = json.loads(raw)
        if not isinstance(request, dict):
            raise ValueError('Invalid settings request')
        service = {'sound': AudioSettings, 'network': NetworkSettings,
                   'accounts': AccountSettings}[sys.argv[1]]()
        result = service.dispatch(request)
        print(json.dumps({'success': True, **result}), flush=True)
    except ValueError as error:
        print(json.dumps({'success': False, 'error': str(error)}), flush=True)
    except Exception:
        # Backend errors may contain account identities or connection secrets.
        # Never forward arbitrary subprocess/GError text to the shell journal.
        print(json.dumps({'success': False, 'error':
                         'The service could not complete the request. Check its availability and permissions, then retry.'}), flush=True)
    return 0


if __name__ == '__main__':
    sys.exit(main())
