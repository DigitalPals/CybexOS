"""Personal input preferences. Reloads preserve the final user.lua layer."""
import copy
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import re
import subprocess
import tempfile
import xml.etree.ElementTree as ET

MAX_BYTES = 262144
TOKEN = re.compile(r'^[A-Za-z0-9_-]{1,64}$')
SHORTCUTS = ('', 'grp:alt_shift_toggle', 'grp:ctrl_shift_toggle', 'grp:caps_toggle')


def run(args):
    result = subprocess.run(args, capture_output=True, text=True, timeout=8, check=False)
    if result.returncode:
        raise ValueError('Hyprland could not apply this change. Check your session and retry.')
    return result.stdout.strip()


def reject_duplicates(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('Duplicate input preference key')
        result[key] = value
    return result


def validate(document):
    if not isinstance(document, dict) or type(document.get('v')) not in (int, float) or document['v'] != 1:
        raise ValueError('Unsupported input preferences version')
    keyboard = document.get('keyboard', {})
    touchpad = document.get('touchpad', {})
    if not isinstance(keyboard, dict) or not isinstance(touchpad, dict):
        raise ValueError('Invalid input preferences')
    if 'layouts' in keyboard:
        layouts = keyboard['layouts']
        if not isinstance(layouts, list) or not 1 <= len(layouts) <= 4:
            raise ValueError('Choose between one and four keyboard layouts')
        for entry in layouts:
            if (not isinstance(entry, dict) or not isinstance(entry.get('layout'), str)
                    or not TOKEN.fullmatch(entry['layout']) or not isinstance(entry.get('variant', ''), str)
                    or (entry.get('variant') and not TOKEN.fullmatch(entry['variant']))):
                raise ValueError('Invalid keyboard layout or variant')
    if 'shortcut' in keyboard and keyboard['shortcut'] not in SHORTCUTS:
        raise ValueError('Invalid layout switching shortcut')
    for key in ('tap', 'naturalScroll'):
        if key in touchpad and type(touchpad[key]) is not bool:
            raise ValueError('Touchpad switches must be true or false')
    if 'sensitivity' in touchpad:
        value = touchpad['sensitivity']
        if type(value) not in (int, float) or not math.isfinite(value) or not -1 <= value <= 1:
            raise ValueError('Touchpad sensitivity must be between -1 and 1')
    return document


def catalog(path=Path('/usr/share/X11/xkb/rules/evdev.xml')):
    result = []
    for layout in ET.parse(path).getroot().findall('./layoutList/layout'):
        info = layout.find('configItem')
        name = info.findtext('name', '')
        if not TOKEN.fullmatch(name):
            continue
        variants = [{'value': '', 'label': 'Default'}]
        for entry in layout.findall('./variantList/variant/configItem'):
            variant = entry.findtext('name', '')
            if TOKEN.fullmatch(variant):
                variants.append({'value': variant, 'label': entry.findtext('description', variant)})
        result.append({'value': name, 'label': info.findtext('description', name), 'variants': variants})
    return result


class InputSettings:
    def __init__(self):
        self.path = Path(os.environ.get('XDG_CONFIG_HOME') or Path.home() / '.config') / 'cybexos/input.json'

    def read(self):
        if self.path.is_symlink():
            raise ValueError('Input preferences are a symlink; edit the linked file directly.')
        try:
            with self.path.open('rb') as source:
                raw = source.read(MAX_BYTES + 1)
        except FileNotFoundError:
            raw = b''
        if len(raw) > MAX_BYTES:
            raise ValueError('Input preferences are too large')
        try:
            document = validate(json.loads(raw, object_pairs_hook=reject_duplicates)) if raw else {'v': 1}
        except (ValueError, UnicodeError, RecursionError) as error:
            raise ValueError('Input preferences are invalid. Repair input.json before applying changes.') from error
        return document, hashlib.sha256(raw).hexdigest(), raw

    def option(self, name, field):
        value = json.loads(run(['hyprctl', '-j', 'getoption', 'input:' + name]))
        if not isinstance(value, dict):
            raise ValueError('Hyprland did not report its input configuration')
        if field == 'bool':
            # Current Hyprland reports Boolean options as JSON booleans;
            # older releases encoded the same switches as integer 0/1.
            # Do not coerce strings such as "false" into a true switch.
            if 'bool' in value and type(value['bool']) is bool:
                return value['bool']
            if 'bool' not in value and type(value.get('int')) is int and value['int'] in (0, 1):
                return bool(value['int'])
            raise ValueError('Hyprland did not report its input configuration')
        if field not in value:
            raise ValueError('Hyprland did not report its input configuration')
        return value[field]

    def snapshot(self):
        document, version, _ = self.read()
        layouts = str(self.option('kb_layout', 'str')).split(',')
        variants = str(self.option('kb_variant', 'str')).split(',')
        options = str(self.option('kb_options', 'str')).split(',')
        devices = json.loads(run(['hyprctl', '-j', 'devices']))
        return {'version': version, 'catalog': catalog(), 'preferences': document,
                'keyboard': {'layouts': [{'layout': name, 'variant': variants[index] if index < len(variants) else ''}
                                         for index, name in enumerate(layouts)],
                             'shortcut': next((option for option in options if option.startswith('grp:')), ''),
                             'active': [{'name': item.get('name', ''), 'layout': item.get('active_keymap', '')}
                                        for item in devices.get('keyboards', []) if item.get('main', False)]},
                'touchpad': {'tap': self.option('touchpad:tap_to_click', 'bool'),
                             'naturalScroll': self.option('touchpad:natural_scroll', 'bool'),
                             'sensitivity': float(self.option('sensitivity', 'float'))}}

    def atomic_write(self, raw):
        fd, name = tempfile.mkstemp(prefix='.input-', dir=self.path.parent)
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
        if action == 'switch':
            run(['hyprctl', 'switchxkblayout', 'all', 'next'])
            return {'message': 'Keyboard layout switched'}
        if action != 'apply' or request.get('section') not in ('keyboard', 'touchpad'):
            raise ValueError('Unknown input operation')
        section = request['section']
        patch = request.get('values')
        allowed = {'keyboard': {'layouts', 'shortcut'}, 'touchpad': {'tap', 'naturalScroll', 'sensitivity'}}[section]
        if not isinstance(patch, dict) or not patch or set(patch) - allowed:
            raise ValueError('Invalid input change')
        self.path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        lock_fd = os.open(self.path.with_suffix('.lock'), os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        with os.fdopen(lock_fd, 'w') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            document, version, previous = self.read()
            if request.get('version') != version:
                raise ValueError('Input preferences changed elsewhere. Discard the pending edits and refresh before applying.')
            candidate = copy.deepcopy(document)
            candidate.setdefault(section, {}).update(patch)
            validate(candidate)
            if section == 'keyboard' and 'layouts' in patch:
                available = {item['value']: {variant['value'] for variant in item['variants']} for item in catalog()}
                for entry in patch['layouts']:
                    if entry.get('variant', '') not in available.get(entry['layout'], set()):
                        raise ValueError('That keyboard layout or variant is not installed')
                # Preserve future per-layout metadata for unchanged identities.
                old = {(entry['layout'], entry.get('variant', '')): entry for entry in document.get('keyboard', {}).get('layouts', [])}
                candidate[section]['layouts'] = [{**old.get((entry['layout'], entry.get('variant', '')), {}), **entry}
                                                  for entry in patch['layouts']]
            payload = (json.dumps(candidate, ensure_ascii=False, allow_nan=False, indent=2) + '\n').encode()
            if len(payload) > MAX_BYTES:
                raise ValueError('Input preferences are too large')
            try:
                self.atomic_write(payload)
                output = run(['hyprctl', 'reload'])
                if output.lower() != 'ok':
                    raise ValueError('Hyprland rejected the input configuration')
                # The loader contains errors to keep the compositor alive;
                # reload's acknowledgement alone therefore cannot prove success.
                output = run(['hyprctl', 'eval', 'assert(__cybexos_input_error == nil, __cybexos_input_error)'])
                if output.lower() != 'ok':
                    raise ValueError('Hyprland rejected the saved input preferences')
            except Exception as error:
                if previous:
                    self.atomic_write(previous)
                else:
                    self.path.unlink(missing_ok=True)
                try:
                    run(['hyprctl', 'reload'])
                except Exception:
                    raise ValueError('Input preferences were restored, but Hyprland could not reload. Sign out to restore the session.') from error
                raise ValueError('Hyprland could not apply the change. Previous preferences were restored.') from error
        return {'message': 'Input preferences saved. Personal Hyprland overrides still take precedence.'}
