"""Personal shortcuts: bounded data, optimistic concurrency and reload rollback."""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import tempfile
import time

from system_settings_input import run
from system_settings_keymap import active_map

MAX_BYTES = 65536
# A broken file up to this size can still be replaced, after it is copied.
RECOVERY_LIMIT = 1048576
STATE_MAX_BYTES = 1048576


def reject_duplicates(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('Duplicate shortcut preference key')
        result[key] = value
    return result


def normalize(value):
    if not isinstance(value, str) or len(value.encode()) > 128:
        return ''
    parts = [part.strip() for part in value.split('+')]
    key = parts.pop()
    modifiers = ('SUPER', 'CTRL', 'ALT', 'SHIFT')
    if (not key or key.upper() in modifiers
            or not re.fullmatch(r'[A-Za-z0-9_]+|code:[0-9]+|mouse:[0-9]+', key, re.I)
            or any(part.upper() not in modifiers for part in parts)):
        return ''
    return ' + '.join([mod for mod in modifiers if mod in [p.upper() for p in parts]]
                      + [key.upper() if len(key) == 1 else key])


def text(value, limit, *, byte_limit=False):
    return (isinstance(value, str) and bool(value)
            and not any(ord(char) < 32 or 127 <= ord(char) <= 159 for char in value)
            and (len(value.encode('utf-8')) if byte_limit else len(value)) <= limit)


def validate_keys(keys):
    if not isinstance(keys, list) or len(keys) > 4:
        raise ValueError('Choose at most four keys per shortcut')
    identities = []
    for key in keys:
        normal = normalize(key)
        if not normal or 'mouse' in normal.lower() or normal.lower() in identities:
            raise ValueError('Invalid or duplicate shortcut key')
        identities.append(normal.lower())


def validate(document):
    if not isinstance(document, dict) or type(document.get('v')) not in (int, float) or document['v'] != 1:
        raise ValueError('Unsupported shortcut preferences version')
    actions, custom = document.get('actions', {}), document.get('custom', [])
    if not isinstance(actions, dict) or not isinstance(custom, list):
        raise ValueError('Invalid shortcut preferences')
    for entry in actions.values():
        if not isinstance(entry, dict):
            raise ValueError('Invalid shortcut override')
        validate_keys(entry.get('keys'))
    ids = set()
    for entry in custom:
        if (not isinstance(entry, dict) or not isinstance(entry.get('id'), str)
                or not re.fullmatch(r'custom\.[a-z0-9-]{1,40}', entry['id']) or entry['id'] in ids):
            raise ValueError('Invalid or duplicate custom shortcut ID')
        ids.add(entry['id'])
        if not text(entry.get('group'), 64) or ':' in entry['group'] or not text(entry.get('label'), 64):
            raise ValueError('Invalid shortcut group or label')
        validate_keys(entry.get('keys'))
        launch = entry.get('run')
        if not isinstance(launch, dict):
            raise ValueError('Invalid shortcut launch')
        kind = launch.get('type')
        valid = False
        if kind == 'app':
            value = launch.get('desktopId')
            valid = text(value, 255, byte_limit=True) and re.fullmatch(r'[A-Za-z0-9_@.+-]+\.desktop', value)
        elif kind == 'webapp':
            value = launch.get('id')
            valid = text(value, 64, byte_limit=True) and re.fullmatch(r'[a-z0-9][a-z0-9-]*', value)
        elif kind == 'url':
            value = launch.get('url')
            valid = text(value, 2048, byte_limit=True) and re.match(r'^https?://[^/\s]+', value)
        elif kind == 'command':
            valid = text(launch.get('command'), 512, byte_limit=True)
        if not valid:
            raise ValueError('Invalid shortcut launch')
    return document


def read_bytes(path, limit):
    # O_NOFOLLOW closes the check/open race and rejects dangling symlinks too.
    # O_NONBLOCK lets us reject a FIFO rather than hanging the settings helper.
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        return None
    except OSError as error:
        raise ValueError('Shortcut preferences could not be read; use a regular file.') from error
    with os.fdopen(fd, 'rb') as source:
        if not stat.S_ISREG(os.fstat(source.fileno()).st_mode):
            raise ValueError('Shortcut preferences must be a regular file')
        raw = source.read(limit + 1)
    if len(raw) > limit:
        raise ValueError('Shortcut preferences are too large')
    return raw


def decode(raw):
    return json.loads(raw, object_pairs_hook=reject_duplicates,
                      parse_constant=lambda _: (_ for _ in ()).throw(ValueError('Invalid JSON number')))


class KeybindingsSettings:
    def __init__(self):
        self.path = Path(os.environ.get('XDG_CONFIG_HOME') or Path.home() / '.config') / 'cybexos/keybindings.json'
        runtime = os.environ.get('XDG_RUNTIME_DIR')
        self.state_path = Path(runtime) / 'cybexos/keybindings-state.json' if runtime else None

    def parse(self, raw):
        try:
            return {'v': 1} if raw is None else validate(decode(raw))
        except (ValueError, UnicodeError, RecursionError) as error:
            raise ValueError('Shortcut preferences are invalid. Repair keybindings.json, or reset all shortcuts to replace it; a backup copy is kept.') from error

    def load(self):
        """Read the saved file without raising for bad content.

        Returns (document, version, raw, problem, replaceable). A bad file keeps
        its exact bytes' hash as the version, so replacing it still rejects a
        concurrent edit. Only a regular file that fits RECOVERY_LIMIT can be
        replaced; anything else must be repaired by hand.
        """
        try:
            raw = read_bytes(self.path, RECOVERY_LIMIT)
        except ValueError as error:
            return {'v': 1}, '', None, str(error), False
        version = hashlib.sha256(raw or b'').hexdigest()
        try:
            if raw is not None and len(raw) > MAX_BYTES:
                raise ValueError('Shortcut preferences are too large')
            return self.parse(raw), version, raw, '', True
        except ValueError as error:
            return {'v': 1}, version, raw, str(error), True

    def read(self):
        document, version, raw, problem, _ = self.load()
        if problem:
            raise ValueError(problem)
        return document, version, raw

    def keep_backup(self, raw):
        """Copy the bytes about to be replaced beside the file. Never deleted."""
        stamp = time.strftime('%Y%m%dT%H%M%SZ', time.gmtime())
        for attempt in range(100):
            name = self.path.with_name('%s.invalid-%s%s' % (self.path.name, stamp, '-%d' % attempt if attempt else ''))
            try:
                fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            except FileExistsError:
                continue
            except OSError as error:
                raise ValueError('Could not keep a backup copy of keybindings.json. Nothing was changed.') from error
            try:
                with os.fdopen(fd, 'wb') as target:
                    target.write(raw)
                    target.flush()
                    os.fsync(target.fileno())
                directory = os.open(self.path.parent, os.O_RDONLY | os.O_DIRECTORY)
                try:
                    os.fsync(directory)
                finally:
                    os.close(directory)
            except OSError as error:
                raise ValueError('Could not keep a backup copy of keybindings.json. Nothing was changed.') from error
            return name
        raise ValueError('Could not keep a backup copy of keybindings.json. Nothing was changed.')

    def snapshot(self):
        # A bad preferences file must not hide Lua's published reason or lock
        # the editor: report it beside the state instead of failing the read.
        document, version, _, problem, _ = self.load()
        raw = read_bytes(self.state_path, STATE_MAX_BYTES) if self.state_path else None
        if raw is None:
            raise ValueError('Shortcut state is unavailable. Reload Hyprland and retry.')
        try:
            state = decode(raw)
            if (not isinstance(state, dict) or state.get('v') != 1
                    or not all(isinstance(state.get(key), list) for key in ('actions', 'custom', 'diagnostics'))):
                raise ValueError('invalid state')
            for row in state['actions'] + state['custom']:
                if (not isinstance(row, dict)
                        or not all(isinstance(row.get(key), str) for key in ('id', 'group', 'label'))
                        or not isinstance(row.get('keys'), list)
                        or not all(isinstance(key, str) for key in row['keys'])):
                    raise ValueError('invalid state row')
            for row in state['actions']:
                if not isinstance(row.get('defaultKeys'), list) or not all(isinstance(key, str) for key in row['defaultKeys']):
                    raise ValueError('invalid default keys')
            binds = decode(run(['hyprctl', '-j', 'binds']))
            if not isinstance(binds, list):
                raise ValueError('invalid binds')
        except (ValueError, UnicodeError, RecursionError) as error:
            raise ValueError('Shortcut state could not be read. Reload Hyprland and retry.') from error
        # { "<xkb keycode>": "<level-1 keysym>" } for the recorder; {} when unknown.
        return {'state': state, 'preferences': document, 'version': version, 'binds': binds,
                'preferencesError': problem, 'keymap': active_map()}

    def atomic_write(self, raw):
        fd, name = tempfile.mkstemp(prefix='.keybindings-', dir=self.path.parent)
        try:
            with os.fdopen(fd, 'wb') as target:
                target.write(raw)
                target.flush()
                os.fsync(target.fileno())
            os.replace(name, self.path)
            directory = os.open(self.path.parent, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
        finally:
            if os.path.exists(name):
                os.unlink(name)

    def dispatch(self, request):
        action = request.get('action', 'snapshot')
        if action == 'snapshot':
            return self.snapshot()
        if action != 'apply':
            raise ValueError('Unknown shortcut operation')
        candidate = validate(request.get('preferences'))
        payload = (json.dumps(candidate, ensure_ascii=False, allow_nan=False, separators=(',', ':')) + '\n').encode()
        if len(payload) > MAX_BYTES:
            raise ValueError('Shortcut preferences are too large')
        self.path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        lock_fd = os.open(self.path.with_suffix('.lock'), os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        with os.fdopen(lock_fd, 'w') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            _, version, previous, problem, replaceable = self.load()
            if request.get('version') != version:
                raise ValueError('Shortcut preferences changed elsewhere. Discard the pending edits and refresh before applying.')
            if problem:
                # Only an explicit reset may replace a file the loader rejects,
                # and only after its exact bytes are kept beside it.
                if request.get('replaceInvalid') is not True or not replaceable:
                    raise ValueError(problem)
                if previous is not None:
                    self.keep_backup(previous)
            try:
                self.atomic_write(payload)
                if run(['hyprctl', 'reload']).lower() != 'ok':
                    raise ValueError('reload rejected')
                if run(['hyprctl', 'eval', 'assert(__cybexos_keybindings_error == nil, __cybexos_keybindings_error)']).lower() != 'ok':
                    raise ValueError('preferences rejected')
            except Exception as error:
                try:
                    if previous is None:
                        self.path.unlink(missing_ok=True)
                    else:
                        self.atomic_write(previous)
                    if run(['hyprctl', 'reload']).lower() != 'ok':
                        raise ValueError('rollback reload rejected')
                except Exception as rollback_error:
                    raise ValueError('Shortcut recovery did not complete. Check keybindings.json and reload Hyprland.') from rollback_error
                raise ValueError('Hyprland could not apply the shortcuts. Previous preferences were restored.') from error
        return {'version': hashlib.sha256(payload).hexdigest(), 'preferences': candidate}
