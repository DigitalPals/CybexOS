#!/usr/bin/env python3
"""Settings -> Displays backend: read outputs, trial and save display rules.

One JSON request per run on stdin; one JSON result on stdout. A change is
first applied as an unconfirmed trial:

  apply     writes the candidate to $XDG_RUNTIME_DIR/cybexos/displays-trial.json,
            arms a transient systemd timer that restores the previous rules,
            then asks Hyprland to evaluate displays.lua against the candidate.
  confirm   saves the candidate as ~/.config/cybexos/displays.json and disarms
            the timer.
  rollback  (and the timer's `expire`) discards the candidate and reloads
            Hyprland, which rebuilds every rule from the files on disk.

The saved file is only ever replaced atomically with a document that passes
the same validation displays.lua applies, and a trial never touches it.
"""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import sys
import tempfile
import time

TRIAL_SECONDS = 15
# The timer outlives the page's own countdown, so the page restores first and
# the timer only acts when the shell cannot.
WATCHDOG_SECONDS = TRIAL_SECONDS + 5
# A Keep sent as the countdown ends still counts; a much later one does not.
CONFIRM_GRACE_SECONDS = 3
MAX_BYTES = 262144
MAX_ENTRIES = 64
UNIT_PREFIX = 'cybexos-display-trial-'
TOKEN = re.compile(r'^[0-9a-f]{16}$')
CONNECTOR = re.compile(r'^[A-Za-z0-9_.-]{1,64}$')
CONTROL = re.compile(r'[\x00-\x1f\x7f]')


def config_path():
    base = os.environ.get('XDG_CONFIG_HOME') or str(Path.home() / '.config')
    return Path(base) / 'cybexos' / 'displays.json'


def runtime_dir():
    base = os.environ.get('XDG_RUNTIME_DIR')
    if not base:
        raise ValueError('XDG_RUNTIME_DIR is not set; display changes need a desktop session.')
    path = Path(base) / 'cybexos'
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    return path


def trial_paths():
    directory = runtime_dir()
    return directory / 'displays-trial.json', directory / 'displays-trial-state.json'


def run(command, timeout=20):
    return subprocess.run(command, capture_output=True, text=True, timeout=timeout, check=False)


def first_line(text):
    line = (text or '').strip().splitlines()[0:1]
    return CONTROL.sub(' ', line[0])[:200] if line else ''


# ------------------------------------------------------------ validation --

def reject_duplicates(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('duplicate key')
        result[key] = value
    return result


def reject_constant(value):
    raise ValueError(f'invalid number {value}')


def loads(text):
    return json.loads(text, object_pairs_hook=reject_duplicates, parse_constant=reject_constant)


def is_int(value, low, high):
    return (isinstance(value, (int, float)) and not isinstance(value, bool)
            and float(value).is_integer() and low <= value <= high)


def is_number(value, low, high):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and low <= value <= high


def valid_key(key):
    if not isinstance(key, str):
        return False
    if key.startswith('desc:'):
        description = key[5:]
        return (len(key) <= 261 and description != '' and description.strip() == description
                and not CONTROL.search(description))
    return bool(CONNECTOR.match(key))


def validate_entry(key, entry):
    """Mirror displays.lua's validate_entry; both reject the same documents."""
    if not valid_key(key):
        raise ValueError(f'invalid display identifier {key!r}')
    if not isinstance(entry, dict):
        raise ValueError(f'{key}: the entry is not an object')
    description = entry.get('description')
    if description is not None and (not isinstance(description, str) or len(description.encode()) > 256
                                    or CONTROL.search(description)):
        raise ValueError(f'{key}: invalid description')
    connector = entry.get('connector')
    if connector is not None and (not isinstance(connector, str) or not CONNECTOR.match(connector)):
        raise ValueError(f'{key}: invalid connector')
    enabled = entry.get('enabled', True)
    if not isinstance(enabled, bool):
        raise ValueError(f'{key}: enabled must be true or false')
    if not enabled:
        companions = entry.get('disabledWith')
        if not isinstance(companions, list) or not 1 <= len(companions) <= 16:
            raise ValueError(f'{key}: a disabled display needs 1-16 disabledWith identifiers')
        if any(not valid_key(other) or other == key for other in companions):
            raise ValueError(f'{key}: invalid disabledWith identifier')
    mode = entry.get('mode')
    if mode is not None and mode != 'preferred':
        if (not isinstance(mode, dict) or not is_int(mode.get('width'), 1, 16384)
                or not is_int(mode.get('height'), 1, 16384) or not is_number(mode.get('refresh'), 1, 1000)):
            raise ValueError(f'{key}: invalid mode')
    position = entry.get('position')
    if position is not None and position != 'auto':
        if (not isinstance(position, dict) or not is_int(position.get('x'), -65536, 65536)
                or not is_int(position.get('y'), -65536, 65536)):
            raise ValueError(f'{key}: invalid position')
    scale = entry.get('scale')
    if scale is not None and scale != 'auto' and not is_number(scale, 0.25, 10):
        raise ValueError(f'{key}: invalid scale')
    if 'transform' in entry and not is_int(entry['transform'], 0, 7):
        raise ValueError(f'{key}: invalid transform')
    if 'vrr' in entry and not is_int(entry['vrr'], 0, 3):
        raise ValueError(f'{key}: invalid vrr')
    mirror = entry.get('mirror')
    if mirror is not None and (not isinstance(mirror, str) or (mirror != '' and not valid_key(mirror))
                               or mirror == key):
        raise ValueError(f'{key}: invalid mirror')


def validate_document(document):
    if not isinstance(document, dict):
        raise ValueError('the document is not an object')
    if document.get('v') != 1 or isinstance(document.get('v'), bool):
        raise ValueError('unsupported version (expected v = 1)')
    monitors = document.get('monitors', {})
    if not isinstance(monitors, dict):
        raise ValueError('monitors is not an object')
    if len(monitors) > MAX_ENTRIES:
        raise ValueError(f'more than {MAX_ENTRIES} displays')
    for key in sorted(monitors):
        validate_entry(key, monitors[key])
    return document


def encode(document):
    data = (json.dumps(document, indent=2, ensure_ascii=False, allow_nan=False) + '\n').encode()
    if len(data) > MAX_BYTES:
        raise ValueError('The display settings are too large to save.')
    return data


# --------------------------------------------------------------- storage --

def digest(data):
    return 'sha256:' + hashlib.sha256(data).hexdigest() if data is not None else 'absent'


def read_store():
    path = config_path()
    result = {'path': str(path), 'document': None, 'digest': 'absent', 'error': ''}
    try:
        if path.is_symlink() or (path.exists() and not path.is_file()):
            result['error'] = 'The display settings file is not a regular file.'
            result['digest'] = 'unsupported'
            return result
        data = path.read_bytes()
    except FileNotFoundError:
        return result
    except OSError:
        result['error'] = 'The display settings file could not be read.'
        result['digest'] = 'unreadable'
        return result
    result['digest'] = digest(data)
    try:
        if len(data) > MAX_BYTES:
            raise ValueError('the file is too large')
        result['document'] = validate_document(loads(data.decode()))
    except (ValueError, UnicodeDecodeError) as error:
        result['error'] = f'The saved display settings are invalid and were ignored: {error}.'
    return result


def atomic_write(path, data, mode=0o600):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if path.is_symlink() or (path.exists() and not path.is_file()):
        raise ValueError(f'{path.name} is not a regular file; nothing was saved.')
    try:
        mode = path.stat().st_mode & 0o777
    except FileNotFoundError:
        pass
    descriptor, temporary = tempfile.mkstemp(prefix=f'.{path.name}.', dir=path.parent)
    try:
        with os.fdopen(descriptor, 'wb') as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise
    directory = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)


def read_json_file(path):
    try:
        if path.is_symlink():
            return None
        return loads(path.read_text()[:MAX_BYTES])
    except (OSError, ValueError, UnicodeDecodeError):
        return None


def read_trial_state():
    _, state_path = trial_paths()
    state = read_json_file(state_path)
    if not isinstance(state, dict) or not TOKEN.match(str(state.get('token', ''))):
        return None
    if not is_number(state.get('expires'), 0, 1e12):
        return None
    return state


def clear_trial():
    for path in trial_paths():
        try:
            path.unlink()
        except FileNotFoundError:
            pass


class TrialLock:
    """Serialises apply/confirm/rollback and the timer's expiry."""

    def __enter__(self):
        self.handle = open(runtime_dir() / 'displays-trial.lock', 'a')
        fcntl.flock(self.handle, fcntl.LOCK_EX)
        return self

    def __exit__(self, *_):
        fcntl.flock(self.handle, fcntl.LOCK_UN)
        self.handle.close()


# -------------------------------------------------------------- Hyprland --

def lua_string(value):
    """A Lua string literal that can hold any byte string safely."""
    return '"' + ''.join(ch if re.match(r'[A-Za-z0-9/_.\- ]', ch) else f'\\{b:03d}'
                         for ch in value for b in ch.encode()) + '"'


def hyprctl(*arguments, timeout=20):
    result = run(['hyprctl', *arguments], timeout=timeout)
    return result.returncode, (result.stdout or '').strip(), (result.stderr or '').strip()


def monitors():
    code, output, _ = hyprctl('-j', 'monitors', 'all')
    if code != 0:
        raise ValueError('Hyprland did not report its displays. Is this a Hyprland session?')
    try:
        data = json.loads(output)
    except ValueError as error:
        raise ValueError('Hyprland returned an unreadable display list.') from error
    if not isinstance(data, list):
        raise ValueError('Hyprland returned an unreadable display list.')
    keep = ('id', 'name', 'description', 'make', 'model', 'width', 'height', 'physicalWidth',
            'physicalHeight', 'refreshRate', 'x', 'y', 'scale', 'transform', 'disabled',
            'mirrorOf', 'vrr', 'focused', 'availableModes')
    return [{key: item.get(key) for key in keep if key in item} for item in data if isinstance(item, dict)]


def reload_hyprland():
    code, output, error = hyprctl('reload')
    if code != 0 or output != 'ok':
        raise ValueError('Hyprland could not reload its configuration: '
                         + (first_line(output) or first_line(error) or 'no reply'))


def unit_name(token):
    return UNIT_PREFIX + token


def arm_watchdog(token):
    environment = []
    for name in ('HYPRLAND_INSTANCE_SIGNATURE', 'XDG_RUNTIME_DIR', 'XDG_CONFIG_HOME', 'PATH', 'HOME'):
        value = os.environ.get(name)
        if value and not CONTROL.search(value):
            environment.append(f'--setenv={name}={value}')
    command = ['systemd-run', '--user', '--quiet', '--collect', f'--unit={unit_name(token)}',
               f'--on-active={WATCHDOG_SECONDS}s', '--timer-property=AccuracySec=500ms',
               *environment, '--', sys.executable, '-B', str(Path(__file__).resolve()),
               'expire', token]
    result = run(command, timeout=15)
    if result.returncode != 0:
        raise ValueError('Automatic restore could not be scheduled, so nothing was changed.')


def disarm_watchdog(token):
    for suffix in ('.timer', '.service'):
        run(['systemctl', '--user', 'stop', unit_name(token) + suffix], timeout=15)


# --------------------------------------------------------------- actions --

def snapshot(_request):
    store = read_store()
    status_path = runtime_dir() / 'displays-status.json'
    status = read_json_file(status_path)
    state = read_trial_state()
    trial = None
    if state:
        trial = {'checkpoint': state['token'], 'expires': state['expires']}
    return {'monitors': monitors(), 'store': store,
            'status': status if isinstance(status, dict) else None, 'trial': trial}


def apply(request):
    document = validate_document(request.get('document'))
    data = encode(document)
    with TrialLock():
        state = read_trial_state()
        if state and state['expires'] + WATCHDOG_SECONDS > time.time():
            raise ValueError('Keep or revert the current display change first.')
        if state:
            clear_trial()
        store = read_store()
        if request.get('baseDigest') not in (None, store['digest']):
            raise ValueError('The saved display settings changed elsewhere. Reload the page and try again.')
        token = secrets.token_hex(8)
        trial_path, state_path = trial_paths()
        expires = time.time() + TRIAL_SECONDS
        atomic_write(trial_path, data)
        atomic_write(state_path, encode({'token': token, 'expires': expires, 'baseDigest': store['digest']}))
        try:
            arm_watchdog(token)
        except ValueError:
            clear_trial()
            raise
        code, output, error = hyprctl('eval', 'require("displays").apply_trial('
                                      + lua_string(str(trial_path)) + ')')
        if code != 0 or output != 'ok':
            reason = first_line(output) or first_line(error) or 'no reply'
            disarm_watchdog(token)
            clear_trial()
            try:
                reload_hyprland()
            except ValueError:
                pass
            raise ValueError('Hyprland rejected the display settings: ' + reason)
    return {'message': f'Showing the new arrangement for {TRIAL_SECONDS} seconds.',
            'checkpoint': token, 'expires': expires}


def confirm(request):
    token = str(request.get('checkpoint', ''))
    with TrialLock():
        state = read_trial_state()
        if not state or state['token'] != token:
            raise ValueError('That display change already ended, and the previous settings were restored.')
        disarm_watchdog(token)
        if time.time() > state['expires'] + CONFIRM_GRACE_SECONDS:
            clear_trial()
            reload_hyprland()
            raise ValueError('The display change expired, and the previous settings were restored.')
        trial_path, _ = trial_paths()
        try:
            document = validate_document(loads(trial_path.read_text()))
        except (OSError, ValueError, UnicodeDecodeError) as error:
            clear_trial()
            reload_hyprland()
            raise ValueError('The pending display change was unreadable and has been undone.') from error
        store = read_store()
        if state.get('baseDigest') != store['digest']:
            clear_trial()
            reload_hyprland()
            raise ValueError('The saved display settings changed elsewhere; the new arrangement was undone.')
        atomic_write(config_path(), encode(document))
        clear_trial()
    return {'message': 'Display settings saved.'}


def rollback(request):
    token = str(request.get('checkpoint', ''))
    with TrialLock():
        state = read_trial_state()
        if not state:
            return {'message': 'The previous display settings are in effect.'}
        if token and state['token'] != token:
            raise ValueError('A different display change is pending.')
        disarm_watchdog(state['token'])
        clear_trial()
        reload_hyprland()
    return {'message': 'The previous display settings were restored.'}


def expire(token):
    """Run by the transient timer when the shell did not end the trial."""
    if not TOKEN.match(token):
        return 2
    with TrialLock():
        state = read_trial_state()
        if not state or state['token'] != token:
            return 0
        clear_trial()
        reload_hyprland()
    return 0


ACTIONS = {'snapshot': snapshot, 'apply': apply, 'confirm': confirm, 'rollback': rollback}


def main(argv):
    if len(argv) == 3 and argv[1] == 'expire':
        try:
            return expire(argv[2])
        except (OSError, ValueError, subprocess.SubprocessError):
            return 1
    try:
        raw = sys.stdin.buffer.readline(MAX_BYTES + 1)
        if len(raw) > MAX_BYTES:
            raise ValueError('The display request is too large.')
        request = loads(raw.decode())
        if not isinstance(request, dict) or request.get('action') not in ACTIONS:
            raise ValueError('Unknown display request.')
        result = ACTIONS[request['action']](request)
        print(json.dumps({'success': True, **result}), flush=True)
    except ValueError as error:
        print(json.dumps({'success': False, 'error': str(error)}), flush=True)
    except (OSError, UnicodeDecodeError, subprocess.SubprocessError):
        print(json.dumps({'success': False, 'error':
                         'The display settings helper could not finish. Retry, or check the session journal.'}),
              flush=True)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
