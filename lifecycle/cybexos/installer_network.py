"""Bounded, read-only connectivity diagnostics for the live installer."""

import json
import re
import time

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


def ensure_internet(run, notify=lambda _message: None, note=lambda _message: None, *, disk_touched=False):
    suffix = '' if disk_touched else ' No disk has been erased.'
    notify('Checking the internet connection…')
    diagnostics(run, note)
    try:
        run('curl', '--fail', '--silent', '--show-error', '--connect-timeout', '5',
            '--max-time', '10', '--output', '/dev/null', CACHE_URL, timeout=15)
    except CommandFailure as error:
        note('Internet check failed (curl exit ' + str(error.returncode) + ').')
        if error.returncode == 6:
            raise Failure(DNS_ERROR.removesuffix(' No disk has been erased.') + suffix) from error
        raise Failure('The installation download service could not be reached. Check the internet '
                      'connection, proxy and system clock, then retry.' + suffix) from error
    except (Failure, OSError) as error:
        note('Internet check did not complete.')
        raise Failure('The internet check did not complete. Check the network connection and retry.' + suffix) from error
    note('Verified HTTPS access to ' + CACHE_URL + '.')
    notify('Internet connection ready.')


def retry_download(operation, check, notify, *, wait=time.sleep, clock=time.monotonic, grace=900):
    """Retry only an explicitly supplied, repeatable download/build operation.

    Disk preparation and credential changes must never be passed here. A build
    error with working connectivity fails normally; transient transfer errors
    get at most three attempts. An offline machine waits for a bounded period
    and resumes the same operation, retaining its target and completed work.
    """
    for attempt in range(3):
        try:
            return operation()
        except CommandFailure as error:
            if attempt == 2:
                raise
            deadline = clock() + grace
            offline = False
            while True:
                try:
                    check()
                    break
                except Failure:
                    offline = True
                    if clock() >= deadline:
                        raise Failure('The network did not return within 15 minutes. Installation stopped; '
                                      'the selected disk has already been changed. See the installation details.') from error
                    notify('Connection interrupted. Reconnect Ethernet or Wi-Fi; installation will resume automatically.')
                    wait(min(5, max(0, deadline - clock())))
            transient = re.search(
                r'unable to download|could not resolve|couldn.t connect|connection (?:reset|refused|timed out)|'
                r'network is unreachable|temporary failure in name resolution|timeout was reached|'
                r'HTTP (?:error |status )?5\d\d|curl error', error.output, re.IGNORECASE)
            if not offline and not transient:
                raise
            notify('Connection restored. Resuming installation…' if offline else 'Retrying the interrupted download…')
            wait(2)
