import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import uuid

from .common import Failure, atomic, digest, locked, read
from .engine import Engine

LIVE_MARKER = Path('/etc/cybexos/installer')
LIVE_UPDATE_REASON = 'System updates are available after installation. Run cybex install to install Cybex OS.'


def require_installed():
    if LIVE_MARKER.exists():
        raise Failure(LIVE_UPDATE_REASON)


def request_status(identifier, state='/var/lib/cybexos'):
    import re
    if not re.fullmatch('[a-f0-9]{32}', identifier):
        raise Failure('Invalid request identifier')
    value = read(Path(state) / 'request-status' / (identifier + '.json'))
    if value is None:
        raise Failure('No supervised request found. Refresh and submit again.')
    if value.get('state') in ('queued', 'running') and time.time() - value.get('createdAt', 0) > 10:
        unit = value.get('unit', '')
        if not re.fullmatch(r'cybexos-(?:update|software|maintenance-policy|maintenance)@[a-f0-9]{32}\.service', unit):
            raise Failure('Invalid supervised request record')
        try:
            result = subprocess.run(['systemctl', 'show', unit, '-p', 'ActiveState', '-p', 'Result'],
                                    text=True, capture_output=True, timeout=10)
        except (OSError, subprocess.SubprocessError):
            return value | {'state':'unknown', 'error':'Cannot check the supervised worker. Retry checking its status before submitting another operation.'}
        properties = dict(line.split('=', 1) for line in result.stdout.splitlines() if '=' in line)
        if result.returncode != 0 or 'ActiveState' not in properties:
            return value | {'state':'unknown', 'error':'Cannot check the supervised worker. Retry checking its status before submitting another operation.'}
        if result.returncode == 0 and properties.get('ActiveState') in ('inactive', 'failed'):
            return value | {'state':'failed', 'error':'The supervised request stopped before reporting completion. Review its system service log and retry.'}
    return value


def enqueue(state, action, payload):
    identifier = uuid.uuid4().hex
    atomic(state / 'requests' / (identifier + '.json'), payload)
    worker = action if action in ('software', 'maintenance-policy') else 'maintenance'
    unit = f'cybexos-{worker}@{identifier}.service'
    status = state / 'request-status' / (identifier + '.json')
    atomic(status, {'state':'queued', 'unit':unit, 'createdAt':time.time()}, 0o644)
    try:
        subprocess.run(['systemctl', 'start', '--no-block', unit], check=True)
    except BaseException:
        atomic(status, {'state':'failed', 'error':'The supervised service could not be started.'}, 0o644)
        (state / 'requests' / (identifier + '.json')).unlink(missing_ok=True)
        raise
    return {'accepted':True, 'requestId':identifier, 'unit':unit}


def update_arguments(action, values):
    identifier = lambda value: isinstance(value, str) and re.fullmatch('[0-9a-f]{32}', value)
    valid = ((action == 'stage' and len(values) == 1 and values[0] in ('upstream', 'cybexos', 'both', 'local'))
             or (action == 'apply' and len(values) == 2 and identifier(values[0])
                 and isinstance(values[1], str) and re.fullmatch('[0-9a-f]{64}', values[1]))
             or (action == 'confirm' and not values)
             or (action == 'rollback' and len(values) <= 1 and (not values or identifier(values[0])))
             or (action == 'discard' and len(values) == 1 and identifier(values[0])))
    if not valid:
        raise Failure('Invalid lifecycle request')


def enqueue_update(state, action, values):
    update_arguments(action, values)
    with locked(state / 'update-request.lock'):
        latest = read(state / 'update-request.json', {})
        if latest.get('id'):
            previous = request_status(latest['id'], state)
            if previous.get('state') in ('queued', 'running', 'unknown'):
                raise Failure('An update request is already running. Open Updates to review its progress.')
        identifier = uuid.uuid4().hex
        unit = f'cybexos-update@{identifier}.service'
        payload = state / 'requests' / (identifier + '.json')
        status = state / 'request-status' / (identifier + '.json')
        atomic(payload, {'action': action, 'arguments': values})
        atomic(status, {'id': identifier, 'action': action, 'state': 'queued', 'unit': unit,
                        'createdAt': time.time(), 'error': ''}, 0o644)
        atomic(state / 'update-request.json', {'id': identifier}, 0o644)
        try:
            subprocess.run(['systemctl', 'start', '--no-block', unit], check=True)
        except BaseException:
            atomic(status, read(status) | {'state': 'failed', 'finishedAt': time.time(),
                                          'error': 'The supervised update service could not be started. Retry or inspect its system service log.'}, 0o644)
            payload.unlink(missing_ok=True)
            raise Failure('The supervised update service could not be started. No update was applied.')
        return {'accepted': True, 'requestId': identifier, 'unit': unit}


def update_status(state=Path('/var/lib/cybexos'), working=Path('/etc/nixos')):
    """Read-only reconciliation; worker failure must survive polls and reloads."""
    state, working = Path(state), Path(working)
    status = read(state / 'status.json', {'state': 'idle'})
    now = time.time()
    status['phaseElapsedSeconds'] = max(0, int(now - status.get('phaseStartedAt', status.get('updatedAt', now))))
    status['elapsedSeconds'] = max(0, int(now - status.get('startedAt', now)))
    status['installedIdentity'] = digest(working / 'flake.lock') if (working / 'flake.lock').is_file() else ''
    identifiers = {read(state / 'update-request.json', {}).get('id'), status.get('requestId')} - {None, ''}
    requests = [request_status(identifier, state) | {'id': identifier} for identifier in identifiers]
    latest = max(requests, key=lambda value: value.get('createdAt', 0)) if requests else {}
    # An older failed update must not obscure a later local configuration change.
    if (latest and latest.get('id') != status.get('requestId')
            and latest.get('createdAt', 0) < status.get('startedAt', 0)):
        latest = {}
    status['request'] = latest
    if (latest.get('id') == status.get('requestId') and latest.get('state') == 'failed'
            and status.get('state') in ('discovering', 'building', 'validating', 'activating', 'recovering')):
        recovery = status['state'] in ('activating', 'recovering')
        status |= {'state': 'recovery-failed' if recovery else 'interrupted',
                   'phase': 'The update worker stopped. Restore the previous generation before continuing.' if recovery
                            else 'Preparation stopped before applying changes. You can prepare again.',
                   'error': latest['error'], 'reviewToken': None}
    return status


def run_update(engine, identifier):
    if not re.fullmatch('[0-9a-f]{32}', identifier):
        raise Failure('Invalid request identifier')
    payload_path = engine.state / 'requests' / (identifier + '.json')
    status_path = engine.state / 'request-status' / (identifier + '.json')
    status = read(status_path)
    if not status or status.get('state') != 'queued':
        raise Failure('This update request has already run or is unavailable')
    atomic(status_path, status | {'state': 'running', 'updatedAt': time.time()}, 0o644)
    engine.request_context = {'requestId': identifier, 'workerUnit': f'cybexos-update@{identifier}.service'}
    try:
        payload = read(payload_path)
        if not isinstance(payload, dict) or set(payload) != {'action', 'arguments'} or not isinstance(payload['arguments'], list):
            raise Failure('Invalid supervised update payload')
        action, values = payload['action'], payload['arguments']
        update_arguments(action, values)
        if action == 'stage': engine.stage(values[0], request_id=identifier)
        elif action == 'apply': engine.apply(*values)
        elif action == 'rollback': engine.rollback(values[0] if values else None)
        elif action == 'confirm': engine.confirm()
        elif action == 'discard': engine.discard(values[0])
        atomic(status_path, read(status_path) | {'state': 'done', 'finishedAt': time.time(), 'error': ''}, 0o644)
    except BaseException as error:
        message = str(error) if isinstance(error, Failure) else 'The update request failed. Inspect its private system service log.'
        atomic(status_path, read(status_path) | {'state': 'failed', 'finishedAt': time.time(), 'error': message}, 0o644)
        raise
    finally:
        payload_path.unlink(missing_ok=True)
        engine.request_context = {}


def main():
    parser = argparse.ArgumentParser(prog='cybex', description='Cybex OS')
    commands = parser.add_subparsers(dest='command', required=True)
    installer = commands.add_parser('install')
    installer.add_argument('--terminal', action='store_true', help='Open the live installer in a terminal')
    commands.add_parser('version')
    software = commands.add_parser('software')
    software_sub = software.add_subparsers(dest='software_action', required=True)
    software_sub.add_parser('list')
    search = software_sub.add_parser('search'); search.add_argument('query', nargs='?', default='')
    software_request = software_sub.add_parser('request'); software_request.add_argument('identifier')
    software_stage = software_sub.add_parser('stage'); software_stage.add_argument('request')
    maintenance = commands.add_parser('maintenance')
    maintenance_sub = maintenance.add_subparsers(dest='maintenance_action', required=True)
    for name in ('status', 'preview', 'resume'):
        maintenance_sub.add_parser(name)
    clean = maintenance_sub.add_parser('clean'); clean.add_argument('review'); clean.add_argument('token')
    pin = maintenance_sub.add_parser('pin'); pin.add_argument('deployment'); pin.add_argument('enabled', choices=('true', 'false'))
    maintenance_request = maintenance_sub.add_parser('request'); maintenance_request.add_argument('identifier')
    maintenance_policy = maintenance_sub.add_parser('policy'); maintenance_policy.add_argument('request')
    config = commands.add_parser('config')
    config.add_argument('domain', choices=('region',))
    config.add_argument('field', choices=('timezone', 'locale'))
    config.add_argument('value')
    config.add_argument('previous', help='JSON value from the current region snapshot')
    for name in ('agent', 'assistant', 'backup', 'report'):
        command = commands.add_parser(name); command.add_argument('arguments', nargs=argparse.REMAINDER)
    plugin = commands.add_parser('plugin'); plugin.add_argument('arguments', nargs=argparse.REMAINDER)
    shell = commands.add_parser('shell'); shell.add_argument('arguments', nargs=argparse.REMAINDER)
    theme = commands.add_parser('theme'); theme.add_argument('arguments', nargs=argparse.REMAINDER)
    update = commands.add_parser('update')
    sub = update.add_subparsers(dest='action', required=True)
    sub.add_parser('check')
    sub.add_parser('status')
    sub.add_parser('history')
    update_request = sub.add_parser('request'); update_request.add_argument('identifier')
    log = sub.add_parser('log'); log.add_argument('transaction')
    stage = sub.add_parser('stage'); stage.add_argument('scope', choices=('upstream', 'cybexos', 'both', 'local'))
    apply = sub.add_parser('apply'); apply.add_argument('transaction'); apply.add_argument('review_token')
    rollback = sub.add_parser('rollback'); rollback.add_argument('transaction', nargs='?')
    sub.add_parser('confirm')
    retry = sub.add_parser('retry-failed'); retry.add_argument('transaction')
    discard = sub.add_parser('discard'); discard.add_argument('transaction')
    args = parser.parse_args()
    if args.command == 'version':
        print(read('/etc/cybexos/release.json')['version']); return
    if args.command == 'software':
        require_installed()
        from . import software as native
        if args.software_action == 'list':
            print(json.dumps(native.inventory())); return
        if args.software_action == 'search':
            print(json.dumps(native.search(args.query))); return
        if args.software_action == 'request':
            print(json.dumps(request_status(args.identifier))); return
        os.execvp('pkexec', ['pkexec', '/run/current-system/sw/bin/cybexos-request', 'software', args.request])
    if args.command == 'maintenance':
        require_installed()
        if args.maintenance_action == 'request':
            print(json.dumps(request_status(args.identifier))); return
        if args.maintenance_action == 'status':
            from .maintenance import public_status
            print(json.dumps(public_status())); return
        extra = ([args.review, args.token] if args.maintenance_action == 'clean' else
                 [args.deployment, args.enabled] if args.maintenance_action == 'pin' else
                 [args.request] if args.maintenance_action == 'policy' else [])
        action = 'maintenance-policy' if args.maintenance_action == 'policy' else 'maintenance-' + args.maintenance_action
        os.execvp('pkexec', ['pkexec', '/run/current-system/sw/bin/cybexos-request', action, *extra])
    if args.command == 'config':
        from .common import parse
        payload = {'field': args.field, 'value': args.value, 'previous': parse(args.previous)}
        os.execvp('pkexec', ['pkexec', '/run/current-system/sw/bin/cybexos-request', 'region', json.dumps(payload)])
    if args.command in ('agent', 'assistant', 'backup', 'report'):
        os.execvp('cybexos-' + args.command, ['cybexos-' + args.command, *args.arguments])
    if args.command == 'install':
        os.execvp('cybexos-install', ['cybexos-install', *(['--terminal'] if args.terminal else [])])
    if args.command in ('plugin', 'shell'):
        os.execvp('cybexos-runtime', ['cybexos-runtime', args.command, *args.arguments])
    if args.command == 'theme':
        os.execvp('cybexos-theme', ['cybexos-theme', *args.arguments])
    if LIVE_MARKER.exists():
        if args.action == 'check':
            print(json.dumps({'available': False, 'reason': LIVE_UPDATE_REASON,
                              'upstream': {'state': 'unavailable'}, 'cybexos': {'state': 'unavailable'}}))
            return
        if args.action == 'status':
            print(json.dumps({'available': False, 'state': 'unavailable', 'phase': LIVE_UPDATE_REASON}))
            return
        raise Failure(LIVE_UPDATE_REASON)
    if args.action == 'status':
        print(json.dumps(update_status()))
    elif args.action == 'request':
        print(json.dumps(request_status(args.identifier)))
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
                 [args.transaction] if args.action in ('rollback', 'retry-failed', 'log', 'discard') and args.transaction else [])
        os.execvp('pkexec', ['pkexec', '/run/current-system/sw/bin/cybexos-request', args.action, *extra])


def request():
    """Small authenticated request boundary; no arbitrary paths or commands."""
    if os.geteuid() != 0:
        raise Failure('Administrator authentication is required')
    require_installed()
    args = sys.argv[1:]
    if not args:
        raise Failure('Missing lifecycle action')
    state = Path('/var/lib/cybexos')
    action, *values = args
    if action in ('software', 'maintenance-policy') and len(values) == 1 and len(values[0]) <= 65536:
        from .common import parse
        payload = parse(values[0])
        if not isinstance(payload, dict):
            raise Failure('Invalid personal declaration request')
        print(json.dumps(enqueue(state, action, payload))); return
    if action.startswith('maintenance-'):
        import re
        valid = ((action in ('maintenance-preview', 'maintenance-resume') and not values)
                 or (action == 'maintenance-clean' and len(values) == 2
                     and re.fullmatch('[0-9a-f]{32}', values[0]) and re.fullmatch('[0-9a-f]{64}', values[1]))
                 or (action == 'maintenance-pin' and len(values) == 2
                     and re.fullmatch('[0-9a-f]{32}', values[0]) and values[1] in ('true', 'false')))
        if not valid:
            raise Failure('Invalid storage request')
        print(json.dumps(enqueue(state, action, {'action':action, 'values':values}))); return
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
                records.append(read(tx / 'deployment.json') | {'good': (tx / 'good.json').exists(), 'failed': read(tx / 'failed.json'),
                                                               'retired': (tx / 'retired.json').exists()})
        print(json.dumps(records)); return
    print(json.dumps(enqueue_update(state, action, values)))


def admin():
    if os.geteuid() != 0:
        raise Failure('Lifecycle worker requires root')
    require_installed()
    engine = Engine()
    action, *values = sys.argv[1:]
    if action == 'update' and len(values) == 1:
        run_update(engine, values[0])
    elif action in ('software', 'maintenance-policy', 'maintenance') and len(values) == 1:
        import re
        if not re.fullmatch('[a-f0-9]{32}', values[0]):
            raise Failure('Invalid request identifier')
        path = engine.state / 'requests' / (values[0] + '.json')
        payload = read(path)
        request_status = engine.state / 'request-status' / (values[0] + '.json')
        atomic(request_status, read(request_status, {}) | {'state':'running', 'unit':f'cybexos-{action}@{values[0]}.service'}, 0o644)
        try:
            if action == 'software':
                engine.stage('local', software=payload, request_id=values[0])
            elif action == 'maintenance-policy':
                engine.stage('local', maintenance=payload, request_id=values[0])
            else:
                from .maintenance import Maintenance
                service = Maintenance(engine, request_id=values[0])
                operation, arguments = payload['action'], payload['values']
                service.publish(state='checking', error='')
                try:
                    if operation == 'maintenance-preview': service.preview()
                    elif operation == 'maintenance-clean': service.clean(*arguments)
                    elif operation == 'maintenance-pin': service.pin(arguments[0], arguments[1] == 'true')
                    elif operation == 'maintenance-resume':
                        with locked(engine.state / 'operation.lock'): service.resume()
                    else: raise Failure('Invalid storage worker request')
                except BaseException as error:
                    service.publish(state='failed', error=str(error) if isinstance(error, Failure) else 'Storage cleanup failed. Inspect the private maintenance log.', reviewToken=None)
                    raise
            atomic(request_status, read(request_status) | {'state':'done', 'finishedAt':time.time()}, 0o644)
        except BaseException as error:
            atomic(request_status, read(request_status) | {'state':'failed', 'finishedAt':time.time(), 'error':str(error) if isinstance(error, Failure) else 'The request failed. Inspect its private system service log.'}, 0o644)
            raise
        finally:
            path.unlink(missing_ok=True)
    elif action == 'maintenance-auto' and not values:
        from .maintenance import Maintenance
        Maintenance(engine).clean(automatic=True)
    elif action == 'region' and not values:
        engine.stage('local', region=read(engine.state / 'region-request.json'))
    elif action == 'recover' and not values:
        engine.recover()
    else:
        raise Failure('Invalid worker action')


def entry(function):
    try:
        function()
    except (Failure, ValueError, KeyError, OSError, subprocess.SubprocessError) as error:
        print(json.dumps({'error': str(error)}), file=sys.stderr)
        sys.exit(1)
