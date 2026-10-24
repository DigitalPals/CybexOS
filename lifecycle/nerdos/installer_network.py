"""Bounded, read-only connectivity diagnostics for the live installer."""

import json

from .common import CommandFailure, Failure


CACHE_URL = 'https://cache.nixos.org/nix-cache-info'
DNS_ERROR = ('DNS could not resolve cache.nixos.org. Open the network menu and '
             'check the DNS provider and any VPN DNS settings, then retry. No disk has been erased.')


def diagnostics(run, note):
    # resolv.conf normally shows only the local stub. Record actual upstream
    # servers and routing domains, including a VPN's split-DNS configuration.
    for arguments in (('resolvectl', 'dns'), ('resolvectl', 'domain')):
        note(' '.join(arguments) + ':')
        try:
            note(run(*arguments, timeout=5).strip())
        except (Failure, OSError):
            note('Resolver diagnostics unavailable.')
    try:
        # Never write the complete status: it may contain an authentication URL.
        result = json.loads(run('tailscale', 'status', '--json', timeout=5, sensitive=True))
        state = result.get('BackendState')
        if state in ('NoState', 'NeedsLogin', 'NeedsMachineAuth', 'Stopped', 'Starting', 'Running'):
            note('Tailscale backend state: ' + state)
    except (Failure, OSError, ValueError, AttributeError):
        note('Tailscale status unavailable.')


def ensure_internet(run, notify=lambda _message: None, note=lambda _message: None):
    notify('Checking the internet connection…')
    diagnostics(run, note)
    try:
        run('curl', '--fail', '--silent', '--show-error', '--connect-timeout', '5',
            '--max-time', '10', '--output', '/dev/null', CACHE_URL, timeout=15)
    except CommandFailure as error:
        note('Internet check failed (curl exit ' + str(error.returncode) + ').')
        if error.returncode == 6:
            raise Failure(DNS_ERROR) from error
        raise Failure('The installation download service could not be reached. Check the internet '
                      'connection, proxy and system clock, then retry. No disk has been erased.') from error
    except (Failure, OSError) as error:
        note('Internet check did not complete.')
        raise Failure('The internet check did not complete. Check the network connection and retry. '
                      'No disk has been erased.') from error
    note('Verified HTTPS access to ' + CACHE_URL + '.')
    notify('Internet connection ready.')
