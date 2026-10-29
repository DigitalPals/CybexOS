"""Device firmware discovery and durable progress for the supervised updater."""
import json

from .common import CommandFailure, Failure, atomic, parse


def discover(run, refresh=False):
    try:
        value = parse(run('cybexos-firmware-update', 'plan', *(['--refresh'] if refresh else []),
                          timeout=150, sensitive=True))
        devices = value['devices']
        if not isinstance(devices, list) or any(
                not isinstance(item, dict) or not all(isinstance(item.get(key), str) and item[key]
                for key in ('id', 'name', 'to')) for item in devices):
            raise ValueError('Invalid firmware plan')
        result = {'state': 'available' if devices else 'unavailable' if value.get('error') else 'current', 'devices': devices}
        if value.get('error'):
            result['error'] = 'Some devices could not be checked. Try checking for updates again.'
        return result
    except (Failure, OSError, ValueError, KeyError, TypeError):
        return {'state': 'unavailable', 'devices': [],
                'error': 'Device firmware could not be checked. Check the network and firmware service, then try again.'}


def install(engine, tx, plan):
    """Stream libfwupd events to public status without killing a flash on timeout."""
    path = tx / 'firmware-plan.json'
    atomic(path, {'devices': plan['devices']})
    value = {'state': 'installing', 'devices': plan['devices'], 'results': [],
             'requests': [], 'needsReboot': False, 'needsShutdown': False,
             'error': '', 'bootId': engine.boot_id()}
    engine.status(state='firmware', phase='Installing device firmware. Keep external power connected.', firmware=value)
    buffered = bytearray()

    def observe(data):
        buffered.extend(data)
        while b'\n' in buffered:
            raw, _, rest = buffered.partition(b'\n')
            buffered[:] = rest
            try:
                event = json.loads(raw)
            except (ValueError, UnicodeError):
                continue
            kind = event.get('event')
            if kind == 'device':
                value.update(current=event['id'], percent=0, requests=[
                    request for request in value['requests'] if request.get('kind') == 'post'])
            elif kind == 'progress':
                value.update(percent=event['percent'], status=event['status'])
            elif kind == 'request':
                value['requests'].append(event)
            elif kind in ('installed', 'failed', 'skipped'):
                value['results'].append(event)
                value['requests'] = [request for request in value['requests']
                                     if request.get('kind') == 'post' or request.get('id') != event.get('id')]
                value['needsReboot'] |= event.get('needsReboot', False)
                if kind == 'failed':
                    value['error'] = event.get('message', 'A device firmware update failed.')
            elif kind == 'summary':
                value.update(state='failed' if event['failed'] else 'done', needsReboot=event['needsReboot'],
                             needsShutdown=event.get('needsShutdown', False))
            engine.status(firmware=value)

    previous = getattr(engine.run, 'observer', None)
    engine.run.observer = observe
    try:
        # Runner has no deadline when timeout is infinity; fwupd owns the write.
        engine.run('cybexos-firmware-update', 'install', '--plan', path, '--events', '-', timeout=float('inf'))
        if value['state'] == 'installing':
            raise Failure('Firmware installation stopped without reporting its result. Check the device before retrying.')
    except (Failure, OSError) as error:
        value['state'] = 'failed'
        value['error'] = value['error'] or ('Firmware installation failed. Check the device and try again.'
                                          if isinstance(error, CommandFailure) else str(error))
    finally:
        engine.run.observer = previous
        engine.status(firmware=value)
    return value
