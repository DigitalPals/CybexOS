"""The active keyboard layout's keycode -> level-1 keysym map.

Hyprland matches a bind against the key's unmodified keysym, but Qt reports the
shifted symbol while Shift is held, so the shortcut recorder needs this map to
store the keysym the vendor binds are written with. Everything here fails soft:
no map simply means no translation.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

MAX_KEYMAP = 524288
MAX_CACHE = 65536
CACHE_FILES = 8
CACHE_MEMO = 8
ARGUMENT = re.compile(r'(?!-)[A-Za-z0-9_,:.()+-]{0,256}')
KEYSYM = re.compile(r'[A-Za-z0-9_]{1,64}')
KEYCODE = re.compile(r'[0-9]{1,5}')
_memo = {}


def section(text, name):
    found = re.search(r'^' + name + r'\b.*?^\};', text, re.S | re.M)
    return found.group(0) if found else ''


def split_top(value):
    """Split on commas outside brackets, braces and quotes."""
    items, depth, quoted, start = [], 0, False, 0
    for index, char in enumerate(value):
        if char == '"':
            quoted = not quoted
        elif quoted:
            continue
        elif char in '[{':
            depth += 1
        elif char in ']}':
            depth -= 1
        elif char == ',' and depth == 0:
            items.append(value[start:index])
            start = index + 1
    items.append(value[start:])
    return [item.strip() for item in items if item.strip()]


def first_level(levels):
    """First keysym of a `[ a, b ]` list; a `{ a, b }` level uses its first."""
    first = (split_top(levels.strip()[1:-1]) or [''])[0].strip()
    if first.startswith('{'):
        first = (split_top(first[1:-1]) or [''])[0].strip()
    return first if KEYSYM.fullmatch(first) and first != 'NoSymbol' else ''


def parse(text):
    """Parse a compiled keymap into {'names': [...], 'groups': [{code: keysym}]}.

    Understands the compact `key <AE01> { [ 1, exclam ] };` form (group 1 only,
    repeated for further groups) and the long `symbols[Group1]=` form, with or
    without `type=` and `actions=` items beside it.
    """
    if not isinstance(text, str) or len(text) > MAX_KEYMAP:
        raise ValueError('keymap too large')
    codes = {}
    block = section(text, 'xkb_keycodes')
    for name, number in re.findall(r'^\s*<([^>\s]+)>\s*=\s*([0-9]+)\s*;', block, re.M):
        if KEYCODE.fullmatch(number):
            codes[name] = number
    for name, target in re.findall(r'^\s*alias\s+<([^>\s]+)>\s*=\s*<([^>\s]+)>\s*;', block, re.M):
        if target in codes:
            codes.setdefault(name, codes[target])
    symbols = section(text, 'xkb_symbols')
    if not codes or not symbols:
        raise ValueError('not a compiled keymap')
    names = {}
    for index, name in re.findall(r'^\s*name\[\s*(?:Group)?([0-9]+)\s*\]\s*=\s*"([^"]*)"\s*;', symbols, re.M):
        names[int(index)] = name
    keys = {}
    for found in re.finditer(r'key\s+<([^>\s]+)>\s*\{(.*?)\}\s*;', symbols, re.S):
        name, body = found.groups()
        groups = {}
        for item in split_top(body):
            if item.startswith('['):
                groups.setdefault(1, first_level(item))
                continue
            assign = re.fullmatch(r'symbols\s*\[\s*(?:Group)?([0-9]+)\s*\]\s*=\s*(\[.*\])', item, re.S)
            if assign:
                groups[int(assign.group(1))] = first_level(assign.group(2))
        if name in codes and groups:
            keys[codes[name]] = groups
    count = max([len(names)] + [max(groups) for groups in keys.values()] + [1])
    result = [{} for _ in range(min(count, 4))]
    for code, groups in keys.items():
        for index, target in enumerate(result, 1):
            if index in groups:
                keysym = groups[index]
            else:
                # A key defined for fewer groups repeats (xkb group wrapping).
                keysym = groups.get(((index - 1) % max(groups)) + 1, '')
            if keysym:
                target[code] = keysym
    return {'names': [names.get(index, '') for index in range(1, len(result) + 1)], 'groups': result}


def select(parsed, active):
    """The group whose name is the keyboard's active keymap; the first otherwise."""
    for index, name in enumerate(parsed['names']):
        if active and name == active:
            return parsed['groups'][index]
    return parsed['groups'][0]


def valid_parsed(value):
    return (isinstance(value, dict) and isinstance(value.get('names'), list) and isinstance(value.get('groups'), list)
            and 1 <= len(value['groups']) <= 4 and len(value['names']) == len(value['groups'])
            and all(isinstance(name, str) and len(name) <= 128 for name in value['names'])
            and all(isinstance(group, dict) and len(group) <= 1024
                    and all(isinstance(key, str) and KEYCODE.fullmatch(key) and isinstance(sym, str)
                            and KEYSYM.fullmatch(sym) for key, sym in group.items())
                    for group in value['groups']))


def cache_dir():
    runtime = os.environ.get('XDG_RUNTIME_DIR')
    return Path(runtime) / 'cybexos' if runtime else None


def read_cache(path):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, 'rb') as source:
            raw = source.read(MAX_CACHE + 1)
        value = json.loads(raw) if len(raw) <= MAX_CACHE else None
        return value if valid_parsed(value) else None
    except (OSError, ValueError, RecursionError):
        return None


def write_cache(directory, path, parsed):
    """Atomic write, then keep only the newest few cache files."""
    try:
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        fd, name = tempfile.mkstemp(prefix='.keymap-', dir=directory)
        try:
            with os.fdopen(fd, 'w') as target:
                json.dump(parsed, target, separators=(',', ':'))
            os.replace(name, path)
        finally:
            if os.path.exists(name):
                os.unlink(name)
        files = sorted(directory.glob('keymap-*.json'), key=lambda item: item.stat().st_mtime, reverse=True)
        for stale in files[CACHE_FILES:]:
            stale.unlink(missing_ok=True)
    except OSError:
        pass


def compile_keymap(layout, variant, options, rules='', model=''):
    """Parsed keymap for one layout string, cached in memory and on disk."""
    arguments = [('--rules', rules), ('--model', model), ('--layout', layout),
                 ('--variant', variant), ('--options', options)]
    if not all(ARGUMENT.fullmatch(value) for _, value in arguments):
        return None
    identity = json.dumps(arguments)
    if identity in _memo:
        return _memo[identity]
    directory = cache_dir()
    path = directory / ('keymap-%s.json' % hashlib.sha256(identity.encode()).hexdigest()[:24]) if directory else None
    parsed = read_cache(path) if path else None
    if parsed is None:
        tool = shutil.which('xkbcli')
        if not tool:
            return None
        command = [tool, 'compile-keymap'] + [part for flag, value in arguments if value for part in (flag, value)]
        try:
            result = subprocess.run(command, capture_output=True, timeout=5, check=False)
            if result.returncode or len(result.stdout) > MAX_KEYMAP:
                return None
            parsed = parse(result.stdout.decode('utf-8'))
        except (OSError, ValueError, subprocess.SubprocessError, RecursionError):
            return None
        if path:
            write_cache(directory, path, parsed)
    if len(_memo) >= CACHE_MEMO:
        _memo.clear()
    _memo[identity] = parsed
    return parsed


def main_keyboard():
    try:
        result = subprocess.run(['hyprctl', '-j', 'devices'], capture_output=True, text=True, timeout=5, check=False)
        keyboards = json.loads(result.stdout).get('keyboards', []) if not result.returncode else []
    except (OSError, ValueError, AttributeError, subprocess.SubprocessError, RecursionError):
        return None
    keyboards = [item for item in keyboards if isinstance(item, dict)]
    return next((item for item in keyboards if item.get('main')), keyboards[0] if keyboards else None)


def active_map():
    """{ "<xkb keycode>": "<keysym>" } for the main keyboard, {} when unknown."""
    try:
        keyboard = main_keyboard()
        if not keyboard:
            return {}
        text = lambda key: keyboard[key] if isinstance(keyboard.get(key), str) else ''
        parsed = compile_keymap(text('layout'), text('variant'), text('options'), text('rules'), text('model'))
        return dict(select(parsed, text('active_keymap'))) if parsed else {}
    except Exception:
        # The map is an enhancement; nothing here may break the snapshot.
        return {}
