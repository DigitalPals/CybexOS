"""Bounded, public-safe observations of Nix's internal-json stderr protocol.

Nix totals can grow during evaluation. Bytes describe transfers, never overall
system completion. A stopped build activity alone does not imply success.
"""
import json
import re
import time


def number(value):
    return type(value) is int and 0 <= value <= 2**64 - 1


def component(fields):
    # Never publish a derivation name, URL, build log, or personal module text.
    path = fields[0] if fields and isinstance(fields[0], str) else ''
    match = re.fullmatch(r'/nix/store/[a-z0-9]{32}-([^/]+)\.drv', path)
    name = match[1] if match else ''
    for prefix, label in (('hyprland-titlebar-', 'window-decorations'), ('hyprland-', 'window-manager'),
                          ('aquamarine-', 'graphics-backend'), ('quickshell-', 'desktop')):
        if name.startswith(prefix):
            return label
    return 'system-component'


class NixProgress:
    MAX_LINE = 256 * 1024
    MAX_ACTIVITIES = 2048

    def __init__(self, publish, step='evaluating', clock=time.monotonic):
        self.publish, self.step, self.clock = publish, step, clock
        self.buffer = bytearray()
        self.discarding = False
        self.activities = {}
        self.transferred = 0
        self.download_expected = 0
        self.builds = [0, 0, 0, 0]
        self.last_publish = float('-inf')
        self.last_snapshot = None
        self.closed = False
        self.emit(force=True)

    def feed(self, data):
        # Split incrementally: even hostile/unsupported log lines stay bounded.
        for part in data.splitlines(keepends=True):
            newline = part.endswith(b'\n')
            if not self.discarding:
                if len(self.buffer) + len(part) <= self.MAX_LINE:
                    self.buffer.extend(part)
                else:
                    self.buffer.clear()
                    self.discarding = True
            if newline:
                if not self.discarding:
                    self.line(bytes(self.buffer))
                self.buffer.clear()
                self.discarding = False
        self.emit()

    def line(self, line):
        if not line.startswith(b'@nix '):
            return
        try:
            event = json.loads(line[5:])
        except (ValueError, UnicodeError, RecursionError):
            return
        if not isinstance(event, dict) or not number(event.get('id')):
            return
        identifier = event['id']
        action, kind = event.get('action'), event.get('type')
        fields = event.get('fields', [])
        if not isinstance(fields, list):
            return
        if action == 'start' and type(kind) is int and kind in (101, 102, 104, 105):
            if identifier in self.activities or len(self.activities) >= self.MAX_ACTIVITIES:
                return
            self.activities[identifier] = {'type': kind, 'counts': [0, 0, 0, 0],
                                           'component': component(fields) if kind == 105 else ''}
        elif action == 'result' and type(kind) is int and identifier in self.activities:
            activity = self.activities[identifier]
            if kind == 105 and len(fields) == 4 and all(number(n) for n in fields):
                activity['counts'] = fields
                if activity['type'] == 104:
                    self.builds = fields
            elif (kind == 106 and activity['type'] == 102 and len(fields) == 2
                  and fields[0] == 101 and all(number(n) for n in fields)):
                self.download_expected = fields[1]
        elif action == 'stop':
            activity = self.activities.pop(identifier, None)
            if activity and activity['type'] == 101:
                self.transferred += activity['counts'][0]

    def snapshot(self):
        transfers = [a['counts'] for a in self.activities.values() if a['type'] == 101]
        running = [a for a in self.activities.values() if a['type'] == 105]
        done = self.transferred + sum(a[0] for a in transfers)
        expected = max(done, self.download_expected, self.transferred + sum(max(a[0], a[1]) for a in transfers))
        active_builds = max(len(running), self.builds[2]) if not self.closed else 0
        step = 'building' if active_builds else 'downloading' if transfers else self.step
        return {'schema': 1, 'step': step, 'active': not self.closed,
                'downloads': {'doneBytes': done, 'expectedBytes': expected,
                              'active': len(transfers),
                              'totalKnown': expected > 0 and all(a[1] > 0 for a in transfers)},
                'builds': {'done': self.builds[0], 'expected': self.builds[1],
                           'active': active_builds, 'failed': self.builds[3]},
                'components': sorted({a['component'] for a in running})}

    def emit(self, force=False):
        now = self.clock()
        if not force and now - self.last_publish < 1:
            return
        snapshot = self.snapshot()
        if snapshot != self.last_snapshot:
            self.publish(snapshot)
            self.last_snapshot = snapshot
            self.last_publish = now

    def close(self):
        if self.buffer and not self.discarding:
            self.line(bytes(self.buffer))
        self.buffer.clear()
        self.transferred += sum(a['counts'][0] for a in self.activities.values() if a['type'] == 101)
        self.activities.clear()
        self.closed = True
        self.emit(force=True)


def log_line(line):
    """Render structured diagnostics only for the existing private log reader."""
    if not line.startswith('@nix '):
        return line
    try:
        event = json.loads(line[5:])
        if event.get('action') == 'msg':
            return str(event.get('msg', '')) + '\n'
        if event.get('action') == 'start' and event.get('text'):
            return str(event['text']) + '\n'
        if event.get('action') == 'result' and event.get('type') in (101, 104):
            fields = event.get('fields', [])
            if fields and isinstance(fields[0], str):
                return fields[0] + '\n'
        return ''
    except (ValueError, AttributeError, TypeError, RecursionError):
        return line
