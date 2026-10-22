import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

from .common import Failure, atomic, locked, read
from .engine import Engine


def main():
    parser = argparse.ArgumentParser(prog='cybex')
    commands = parser.add_subparsers(dest='command', required=True)
    commands.add_parser('install')
    commands.add_parser('version')
    config = commands.add_parser('config')
    config.add_argument('domain', choices=('region',))
    config.add_argument('field', choices=('timezone', 'locale'))
    config.add_argument('value')
    config.add_argument('previous', help='JSON value from the current region snapshot')
    for name in ('agent', 'backup', 'report'):
        command = commands.add_parser(name); command.add_argument('arguments', nargs=argparse.REMAINDER)
    plugin = commands.add_parser('plugin'); plugin.add_argument('arguments', nargs=argparse.REMAINDER)
    shell = commands.add_parser('shell'); shell.add_argument('arguments', nargs=argparse.REMAINDER)
    theme = commands.add_parser('theme'); theme.add_argument('arguments', nargs=argparse.REMAINDER)
    update = commands.add_parser('update')
    sub = update.add_subparsers(dest='action', required=True)
    sub.add_parser('check')
    sub.add_parser('status')
    sub.add_parser('history')
    log = sub.add_parser('log'); log.add_argument('transaction')
    stage = sub.add_parser('stage'); stage.add_argument('scope', choices=('upstream', 'cybexos', 'both', 'local'))
    apply = sub.add_parser('apply'); apply.add_argument('transaction'); apply.add_argument('review_token')
    rollback = sub.add_parser('rollback'); rollback.add_argument('transaction', nargs='?')
    sub.add_parser('confirm')
    retry = sub.add_parser('retry-failed'); retry.add_argument('transaction')
    args = parser.parse_args()
    if args.command == 'version':
        print(read('/etc/cybexos/release.json')['version']); return
    if args.command == 'config':
        from .common import parse
        payload = {'field': args.field, 'value': args.value, 'previous': parse(args.previous)}
        os.execvp('pkexec', ['pkexec', '/run/current-system/sw/bin/cybexos-request', 'region', json.dumps(payload)])
    if args.command in ('agent', 'backup', 'report'):
        os.execvp('cybexos-' + args.command, ['cybexos-' + args.command, *args.arguments])
    if args.command == 'install':
        os.execvp('cybexos-install', ['cybexos-install'])
    if args.command in ('plugin', 'shell'):
        os.execvp('cybexos-runtime', ['cybexos-runtime', args.command, *args.arguments])
    if args.command == 'theme':
        os.execvp('cybexos-theme', ['cybexos-theme', *args.arguments])
    if args.action == 'status':
        status = read('/var/lib/cybexos/status.json', {'state': 'idle'})
        status['phaseElapsedSeconds'] = max(0, int(__import__('time').time()) - status.get('updatedAt', int(__import__('time').time())))
        print(json.dumps(status))
    elif args.action == 'check':
        # Root-owned configuration is readable; cache/network work uses the caller's cache.
        engine = object.__new__(Engine)
        engine.state = Path(os.environ.get('XDG_CACHE_HOME', str(Path.home() / '.cache'))) / 'cybexos'
        engine.state.mkdir(parents=True, exist_ok=True)
        engine.machine_state = Path('/var/lib/cybexos')
        engine.working = Path('/etc/nixos')
        engine.release = Path('/etc/cybexos/release.json')
        engine.policy = Path('/etc/cybexos/update.json')
        engine.trust = Path('/etc/cybexos/trust.json')
        from .common import Runner
        engine.run = Runner()
        print(json.dumps(engine.check()))
    elif args.action == 'history':
        os.execvp('pkexec', ['pkexec', '/run/current-system/sw/bin/cybexos-request', 'history'])
    else:
        extra = ([args.scope] if args.action == 'stage' else
                 [args.transaction, args.review_token] if args.action == 'apply' else
                 [args.transaction] if args.action in ('rollback', 'retry-failed', 'log') and args.transaction else [])
        os.execvp('pkexec', ['pkexec', '/run/current-system/sw/bin/cybexos-request', args.action, *extra])


def request():
    """Small authenticated request boundary; no arbitrary paths or commands."""
    if os.geteuid() != 0:
        raise Failure('Administrator authentication is required')
    args = sys.argv[1:]
    if not args:
        raise Failure('Missing lifecycle action')
    state = Path('/var/lib/cybexos')
    action, *values = args
    if action == 'region' and len(values) == 1 and len(values[0]) < 4096:
        from .common import parse
        payload = parse(values[0])
        if not isinstance(payload, dict) or set(payload) != {'field', 'value', 'previous'}:
            raise Failure('Invalid region request')
        atomic(state / 'region-request.json', payload)
        subprocess.run(['systemctl', 'start', '--no-block', 'cybexos-region.service'], check=True)
        print(json.dumps({'accepted': True})); return
    if action == 'log' and len(values) == 1:
        import re
        if not re.fullmatch('[0-9a-f]{32}', values[0]):
            raise Failure('Invalid deployment identifier')
        path = state / 'transactions' / values[0] / 'build.log'
        if not path.is_file():
            raise Failure('No build log for this deployment')
        # Logs can contain private module diagnostics. Only the authenticated
        # administrator sees them; never copy them to world-readable status.
        with path.open('r', errors='replace') as stream:
            for line in stream:
                sys.stdout.write(line)
        return
    if action == 'retry-failed' and len(values) == 1:
        import re
        if not re.fullmatch('[0-9a-f]{32}', values[0]):
            raise Failure('Invalid deployment identifier')
        tx = state / 'transactions' / values[0]
        if not (tx / 'failed.json').exists():
            raise Failure('No failed deployment found')
        with locked(state / 'operation.lock'):
            system = read(tx / 'deployment.json')['system']
            authorized = []
            for failed in (state / 'transactions').glob('*/failed.json'):
                if read(failed.parent / 'deployment.json', {}).get('system') == system:
                    atomic(failed.parent / 'retry-authorized.json', {'authorizedAt': __import__('time').time()})
                    authorized.append(failed.parent.name)
        print(json.dumps({'retryAuthorized': values[0], 'sameSystemDeployments': authorized})); return
    if action == 'history' and not values:
        records = []
        for tx in sorted((state / 'transactions').glob('*')):
            if (tx / 'deployment.json').exists():
                records.append(read(tx / 'deployment.json') | {'good': (tx / 'good.json').exists(), 'failed': read(tx / 'failed.json')})
        print(json.dumps(records)); return
    import re
    if action == 'stage' and len(values) == 1 and values[0] in ('upstream', 'cybexos', 'both', 'local'):
        unit = f'cybexos-stage@{values[0]}.service'
    elif action == 'apply' and len(values) == 2 and re.fullmatch('[0-9a-f]{32}', values[0]) and re.fullmatch('[0-9a-f]{64}', values[1]):
        atomic(state / ('apply-' + values[0] + '.json'), {'token': values[1]})
        unit = f'cybexos-apply@{values[0]}.service'
    elif action == 'confirm' and not values:
        unit = 'cybexos-confirm.service'
    elif action == 'rollback' and len(values) <= 1 and (not values or re.fullmatch('[0-9a-f]{32}', values[0])):
        atomic(state / 'rollback-request.json', {'id': values[0] if values else None})
        unit = 'cybexos-rollback.service'
    else:
        raise Failure('Invalid lifecycle request')
    subprocess.run(['systemctl', 'start', '--no-block', unit], check=True)
    print(json.dumps({'accepted': True, 'unit': unit}))


def admin():
    if os.geteuid() != 0:
        raise Failure('Lifecycle worker requires root')
    engine = Engine()
    action, *values = sys.argv[1:]
    if action == 'stage' and len(values) == 1:
        engine.stage(values[0])
    elif action == 'region' and not values:
        engine.stage('local', region=read(engine.state / 'region-request.json'))
    elif action == 'apply' and len(values) == 1:
        engine.apply(values[0], read(engine.state / ('apply-' + values[0] + '.json'))['token'])
    elif action == 'recover' and not values:
        engine.recover()
    elif action == 'confirm' and not values:
        engine.confirm()
    elif action == 'rollback' and not values:
        engine.rollback(read(engine.state / 'rollback-request.json', {}).get('id'))
    else:
        raise Failure('Invalid worker action')


def entry(function):
    try:
        function()
    except (Failure, ValueError, KeyError, OSError, subprocess.SubprocessError) as error:
        print(json.dumps({'error': str(error)}), file=sys.stderr)
        sys.exit(1)
