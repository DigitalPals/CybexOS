"""Select exact NixOS systems through systemd-boot's Type 1/UKI interface."""
import re
import shlex
import subprocess

from .common import Failure, parse


def entry(system, entries):
    if not re.fullmatch(r'/nix/store/[a-z0-9]{32}-[^/]+', system):
        raise Failure('Invalid retained system identity')
    if not isinstance(entries, list):
        raise Failure('Invalid systemd-boot entry list')
    # bootctl reads both .conf entries and the embedded .cmdline of UKIs. Do
    # not infer a system from a generation number, filename or substring: a
    # specialisation or an unrelated option can contain another system path.
    for candidate in entries:
        if not isinstance(candidate, dict) or candidate.get('type') not in ('type1', 'type2'):
            continue
        options = candidate.get('options', '')
        if not isinstance(options, str):
            continue
        try:
            initializers = [s for s in shlex.split(options) if s.startswith('init=')]
        except ValueError:
            continue
        if initializers != ['init=' + system + '/init']:
            continue
        identifier = candidate.get('id', '')
        if not isinstance(identifier, str) or not re.fullmatch(r'[A-Za-z0-9_.+@-]+\.(conf|efi)', identifier):
            raise Failure('Unsafe systemd-boot entry identity')
        if candidate.get('triesLeft') == 0:
            continue
        # The list is already ordered by systemd's own boot-entry ordering.
        return identifier
    raise Failure('No bootable systemd-boot entry for the retained system; check the ESP and retained generations')


def trial(arguments, run=None):
    run = run or subprocess.check_output
    if len(arguments) != 2:
        raise Failure('Expected candidate/previous systems or --restore/--commit and a system')
    entries = parse(run(['bootctl', 'list', '--json=short', '--no-pager'], text=True))
    action, system = arguments
    if action in ('--restore', '--commit'):
        selected = entry(system, entries)
        if action == '--restore':
            run(['bootctl', 'set-oneshot', ''], text=True)
        run(['bootctl', 'set-default', selected], text=True)
    else:
        # Resolve both before changing firmware state. A missing candidate
        # must not alter the persistent default or consume a trial selection.
        candidate, previous = entry(action, entries), entry(system, entries)
        run(['bootctl', 'set-default', previous], text=True)
        run(['bootctl', 'set-oneshot', candidate], text=True)
