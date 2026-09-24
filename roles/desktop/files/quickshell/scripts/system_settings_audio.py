"""PipeWire-Pulse capabilities absent from the installed Quickshell API."""
import json
import math
import subprocess


def pactl(*arguments):
    result = subprocess.run(['pactl', *map(str, arguments)], capture_output=True,
                            text=True, timeout=10, check=False)
    if result.returncode:
        raise ValueError('Audio service rejected the change. The device may have disconnected.')
    return result.stdout


def records(kind):
    data = json.loads(pactl('--format=json', 'list', kind))
    if not isinstance(data, list):
        raise ValueError('Audio service returned an invalid device list')
    return data


def choices(value):
    if isinstance(value, dict):
        return [dict(item, name=name) for name, item in value.items()]
    return value or []


def label(item):
    props = item.get('properties', {})
    return str(item.get('description') or props.get('device.description')
               or props.get('application.name') or item.get('name') or 'Audio device')


def identity(item):
    # A reused Pulse index must not apply a delayed action to a different app.
    return str(item.get('properties', {}).get('object.serial', ''))


def balance(item):
    volumes = item.get('volume', {})
    left = volumes.get('front-left', {}).get('value', 0)
    right = volumes.get('front-right', {}).get('value', 0)
    return round((right - left) / max(left, right), 3) if max(left, right) else 0


class AudioSettings:
    def snapshot(self):
        cards = []
        for card in records('cards'):
            profiles = [dict(value=p['name'], label=p.get('description', p['name']))
                        for p in choices(card.get('profiles'))
                        if p.get('available') not in ('no', False)]
            cards.append(dict(name=card['name'], label=label(card),
                              profile=card.get('active_profile', ''), profiles=profiles))
        devices = {}
        for kind in ('sinks', 'sources'):
            devices[kind] = [dict(name=d['name'], label=label(d), index=d['index'],
                                  port=d.get('active_port', ''),
                                  ports=[dict(value=p['name'], label=p.get('description', p['name']))
                                         for p in choices(d.get('ports'))
                                         if p.get('availability') not in ('not available', 'no')],
                                  balance=balance(d),
                                  stereo=(set(d.get('volume', {})) == {'front-left', 'front-right'}
                                          and d['name'] != 'xps_speaker_tuning'))
                             for d in records(kind)
                             if not (kind == 'sources' and (d['name'].endswith('.monitor')
                                     or d.get('properties', {}).get('device.class') == 'monitor'))]
        streams = []
        for kind, target in [('sink-inputs', 'sink'), ('source-outputs', 'source')]:
            for stream in records(kind):
                props = stream.get('properties', {})
                # Internal filter-chain streams must keep their physical route.
                if not props.get('application.name') or not identity(stream):
                    continue
                streams.append(dict(index=stream['index'], serial=identity(stream),
                                    kind=kind, label=label(stream), muted=bool(stream.get('mute')),
                                    target=stream.get(target)))
        return dict(cards=cards, streams=streams, **devices)

    def dispatch(self, request):
        action = request.get('action', 'snapshot')
        if action == 'snapshot':
            return self.snapshot()
        if action == 'profile':
            card = next((c for c in records('cards') if c['name'] == request.get('name')), None)
            if not card or request.get('value') not in [p['name'] for p in choices(card.get('profiles'))
                                                       if p.get('available') not in ('no', False)]:
                raise ValueError('That audio profile is no longer available')
            pactl('set-card-profile', card['name'], request['value'])
        elif action in ('port', 'balance'):
            kind = request.get('kind')
            if kind not in ('sinks', 'sources'):
                raise ValueError('Invalid audio device type')
            device = next((d for d in records(kind) if d['name'] == request.get('name')), None)
            if not device:
                raise ValueError('That audio device has disconnected')
            target = 'sink' if kind == 'sinks' else 'source'
            if action == 'port':
                if request.get('value') not in [p['name'] for p in choices(device.get('ports'))
                                                if p.get('availability') not in ('no', 'not available')]:
                    raise ValueError('That audio port is no longer available')
                pactl('set-' + target + '-port', device['name'], request['value'])
            else:
                balance = float(request.get('value', 0))
                if not math.isfinite(balance) or not -1 <= balance <= 1:
                    raise ValueError('Balance must be between left and right')
                volumes = device.get('volume', {})
                if device['name'] == 'xps_speaker_tuning':
                    raise ValueError('Adjust the physical speakers to preserve speaker tuning')
                if set(volumes) != {'front-left', 'front-right'}:
                    raise ValueError('Balance is available for stereo devices only')
                level = max(v['value'] for v in volumes.values())
                values = {'front-left': round(level * (1 - max(0, balance))),
                          'front-right': round(level * (1 + min(0, balance)))}
                channels = device.get('channel_map', 'front-left,front-right').split(',')
                pactl('set-' + target + '-volume', device['name'], *(values[c.strip()] for c in channels))
        elif action in ('route', 'mute'):
            kind = request.get('kind')
            if kind not in ('sink-inputs', 'source-outputs'):
                raise ValueError('Invalid application stream')
            stream = next((s for s in records(kind)
                           if s['index'] == request.get('index')
                           and identity(s) and identity(s) == request.get('serial')
                           and s.get('properties', {}).get('application.name')), None)
            if not stream:
                raise ValueError('That application stream has closed')
            stream_type = 'sink-input' if kind == 'sink-inputs' else 'source-output'
            if action == 'mute':
                if not isinstance(request.get('value'), bool):
                    raise ValueError('Invalid mute setting')
                pactl('set-' + stream_type + '-mute', stream['index'], int(request['value']))
            else:
                devices = records('sinks' if kind == 'sink-inputs' else 'sources')
                if request.get('value') not in [d['name'] for d in devices]:
                    raise ValueError('That audio destination has disconnected')
                pactl('move-' + stream_type, stream['index'], request['value'])
        else:
            raise ValueError('Unknown audio operation')
        return {'message': 'Audio updated'}
