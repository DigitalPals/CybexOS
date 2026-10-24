"""Named appearance themes: data, never code.

A theme is a directory holding `theme.json` and, optionally, the one wallpaper
image it names (PNG, JPEG or WebP). Nothing in a theme is executed or
interpreted beyond the schema below. Built-in themes ship read-only in the
shell runtime (`themes/` beside `scripts/`); user themes live in the
user-owned theme root, `$CYBEXOS_THEME_ROOT` (default
`~/.local/share/cybexos/themes`), which installs and updates never prune
(docs/architecture/ownership.md).

theme.json, schema 1:

    {
      "schema": 1,
      "name": "Nord",                    required, at most 48 characters
      "id": "nord",                      optional; derived from the name
      "mode": "dark",                    required: dark | light
      "accent": "#88c0d0",               required
      "accentSource": "fixed",           optional: fixed (default) | wallpaper
      "bar": "default",                  optional: a bar preset, "#rrggbb", or
                                         {"hue", "saturation", "lightness"}
      "font": "plex",                    optional: a shell font id
      "palette": {"background": ...},    optional explicit colours, fixed only
      "wallpaper": "wallpaper.jpg",      optional image beside theme.json
      "author", "license", "source", "description"   optional text
    }

Applying a theme is one settings change: settings_patch() maps it to the
shell.json keys that Settings → Appearance (Common/Themes.qml) and
`cybex theme apply` set together. That mapping exists only here.
"""
from datetime import datetime, timezone
import importlib.machinery
import importlib.util
import io
import json
import math
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import tarfile
import tempfile
import zipfile

SCHEMA = 1
THEME_FILE = 'theme.json'
# Where an installed theme came from. Written by install(), never by authors.
SOURCE_FILE = '.source.json'

ID = re.compile(r'^[a-z0-9](?:[a-z0-9-]{0,46}[a-z0-9])?$')
HEX = re.compile(r'^#[0-9a-fA-F]{6}$')
NAME_MAX = 48
TEXT_MAX = 200
MODES = ('dark', 'light')
ACCENT_SOURCES = ('fixed', 'wallpaper')
# SettingsHelpers.BAR_COLOR_CHOICES without `custom`: a colour is custom.
BAR_PRESETS = ('default', 'macos', 'black', 'graphite', 'slate', 'white')
# SettingsHelpers.FONT_IDS.
FONTS = ('figtree', 'google', 'urbanist', 'oppo', 'plex', 'mono')
# The explicit colours a theme may set, all optional. Theme.qml derives the
# rest and still applies its contrast floors to every text colour.
PALETTE_KEYS = ('background', 'surface', 'surfaceRaised', 'text', 'textMuted', 'textDim',
                'red', 'amber', 'green')
META_KEYS = ('author', 'license', 'source', 'description')
KNOWN_KEYS = {'schema', 'id', 'name', 'mode', 'accent', 'accentSource', 'bar', 'font', 'palette',
              'wallpaper', *META_KEYS}

IMAGE_MAGIC = {'.png': (b'\x89PNG\r\n\x1a\n',), '.jpg': (b'\xff\xd8\xff',),
               '.jpeg': (b'\xff\xd8\xff',), '.webp': (b'RIFF',)}
# Files a theme repository or archive may carry besides the theme itself.
# They are tolerated so an ordinary README or LICENSE does not block an
# install, and are never copied.
IGNORED_FILE = re.compile(
    r'^((readme|license|licence|copying|notice|changelog)(\.(md|txt|rst))?|\.gitignore|\.gitattributes'
    r'|\.ds_store)$', re.IGNORECASE)

MAX_THEME_JSON = 64 * 1024
MAX_IMAGE = 16 * 1024 * 1024
MAX_IGNORED = 256 * 1024
MAX_TOTAL = 40 * 1024 * 1024
MAX_ARCHIVE = 48 * 1024 * 1024
MAX_ENTRIES = 64
GIT_TIMEOUT = 120
URL_MAX = 512

# The appearance values a theme reads from or writes to shell.json, with the
# defaults SettingsHelpers.defaults() gives them (a node test keeps the two
# equal). Used to describe the current appearance without a running shell.
APPEARANCE_DEFAULTS = {
    'theme': '',
    'themeMode': 'dark',
    'paletteMode': 'fixed',
    'accent': '#60a5fa',
    'font': 'mono',
    'barColorMode': 'default',
    'barCustomHue': 230,
    'barCustomSaturation': 14,
    'barCustomLightness': 9,
    'themePalette': {'mode': '', **{key: '' for key in PALETTE_KEYS}},
    'wall': '',
    'wallDir': '~/Pictures/Wallpapers',
}


class ThemeError(ValueError):
    pass


# ---- schema -------------------------------------------------------------------

def slug(name):
    """A theme id derived from a display name: "Rosé Pine" -> "ros-pine"."""
    text = re.sub(r'[^a-z0-9]+', '-', str(name).lower()).strip('-')
    return text[:48].strip('-')


def _text(value, key, limit, required=False):
    if value is None and not required:
        return ''
    if not isinstance(value, str):
        raise ThemeError(f'{key} must be text')
    value = value.strip()
    if (required and not value) or len(value) > limit or any(ord(ch) < 32 or ord(ch) == 127
                                                             for ch in value):
        raise ThemeError(f'{key} must be plain text of at most {limit} characters')
    return value


def _hex(value, key):
    if not isinstance(value, str) or not HEX.match(value):
        raise ThemeError(f'{key} must be a #rrggbb colour')
    return value.lower()


def _int(value, key, low, high):
    if type(value) is not int or not low <= value <= high:
        raise ThemeError(f'{key} must be a whole number from {low} to {high}')
    return value


def _bar(value):
    if value is None:
        return 'default'
    if isinstance(value, str) and value in BAR_PRESETS:
        return value
    if isinstance(value, str) and HEX.match(value):
        return value.lower()
    if isinstance(value, dict) and set(value) == {'hue', 'saturation', 'lightness'}:
        return {'hue': _int(value['hue'], 'bar.hue', 0, 359),
                'saturation': _int(value['saturation'], 'bar.saturation', 0, 100),
                'lightness': _int(value['lightness'], 'bar.lightness', 0, 100)}
    raise ThemeError('bar must be one of ' + ', '.join(BAR_PRESETS)
                     + ', a #rrggbb colour, or {hue, saturation, lightness}')


def _file_name(value, key):
    if (not isinstance(value, str) or not value or len(value) > 128 or value.startswith('.')
            or '/' in value or '\\' in value or any(ord(ch) < 32 for ch in value)):
        raise ThemeError(f'{key} must be a plain file name beside theme.json')
    if Path(value).suffix.lower() not in IMAGE_MAGIC:
        raise ThemeError(f'{key} must be a PNG, JPEG or WebP image')
    return value


def validate(raw):
    """Returns the normalized theme for a parsed theme.json, or raises ThemeError."""
    if not isinstance(raw, dict):
        raise ThemeError('theme.json must hold a JSON object')
    if raw.get('schema') != SCHEMA:
        raise ThemeError(f'theme.json must declare "schema": {SCHEMA}')
    unknown = sorted(set(raw) - KNOWN_KEYS)
    if unknown:
        raise ThemeError('unknown theme.json keys: ' + ', '.join(unknown))
    name = _text(raw.get('name'), 'name', NAME_MAX, required=True)
    theme_id = raw.get('id', slug(name))
    if not isinstance(theme_id, str) or not ID.match(theme_id):
        raise ThemeError('id must be 1-48 lowercase letters, digits and dashes'
                         if 'id' in raw else 'the name has no letters or digits to make an id from')
    mode = raw.get('mode')
    if mode not in MODES:
        raise ThemeError('mode must be dark or light')
    source = raw.get('accentSource', 'fixed')
    if source not in ACCENT_SOURCES:
        raise ThemeError('accentSource must be fixed or wallpaper')
    font = raw.get('font', '')
    if font != '' and font not in FONTS:
        raise ThemeError('font must be one of ' + ', '.join(FONTS))
    palette = raw.get('palette', {})
    if not isinstance(palette, dict):
        raise ThemeError('palette must be an object')
    extra = sorted(set(palette) - set(PALETTE_KEYS))
    if extra:
        raise ThemeError('unknown palette colours: ' + ', '.join(extra))
    if palette and source == 'wallpaper':
        raise ThemeError('a theme that takes its colours from the wallpaper cannot set a palette')
    wallpaper = raw.get('wallpaper', '')
    theme = {
        'schema': SCHEMA,
        'id': theme_id,
        'name': name,
        'mode': mode,
        'accentSource': source,
        'accent': _hex(raw.get('accent'), 'accent'),
        'bar': _bar(raw.get('bar')),
        'font': font,
        'palette': {key: _hex(palette[key], 'palette.' + key)
                    for key in PALETTE_KEYS if key in palette},
        'wallpaper': '' if wallpaper == '' else _file_name(wallpaper, 'wallpaper'),
    }
    for key in META_KEYS:
        theme[key] = _text(raw.get(key), key, TEXT_MAX)
    return theme


def canonical(theme):
    """theme.json text for a validated theme: optional fields only when set."""
    out = {'schema': SCHEMA, 'id': theme['id'], 'name': theme['name'], 'mode': theme['mode'],
           'accent': theme['accent']}
    if theme['accentSource'] != 'fixed':
        out['accentSource'] = theme['accentSource']
    if theme['bar'] != 'default':
        out['bar'] = theme['bar']
    for key in ('font', 'palette', 'wallpaper', *META_KEYS):
        if theme[key]:
            out[key] = theme[key]
    return json.dumps(out, indent=2, ensure_ascii=False) + '\n'


def check_image(name, data):
    """Raises unless `data` is the image its file name says it is."""
    if len(data) > MAX_IMAGE:
        raise ThemeError(f'{name} is larger than {MAX_IMAGE // (1024 * 1024)} MiB')
    suffix = Path(name).suffix.lower()
    magic = IMAGE_MAGIC.get(suffix)
    if magic is None or not any(data.startswith(prefix) for prefix in magic) or (
            suffix == '.webp' and data[8:12] != b'WEBP'):
        raise ThemeError(f'{name} is not a valid {suffix.lstrip(".").upper() or "image"} file')


def parse_theme_bytes(data):
    if len(data) > MAX_THEME_JSON:
        raise ThemeError('theme.json is too large')
    try:
        return validate(json.loads(data.decode('utf-8')))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ThemeError(f'theme.json is not valid JSON: {error}') from None


# ---- colour ---------------------------------------------------------------------
# A #rrggbb bar colour is stored as the whole-number hue, saturation and
# lightness the Bar page's custom colour uses. Rounding follows JavaScript's
# Math.round, as SettingsHelpers.hexHue does.

def _round(value):
    return int(math.floor(value + 0.5))


def hex_to_hsl(value):
    r, g, b = (int(value[i:i + 2], 16) / 255 for i in (1, 3, 5))
    high, low = max(r, g, b), min(r, g, b)
    lightness = (high + low) / 2
    if high == low:
        return {'hue': 0, 'saturation': 0, 'lightness': _round(lightness * 100)}
    delta = high - low
    saturation = delta / (2 - high - low) if lightness > 0.5 else delta / (high + low)
    if high == r:
        hue = (g - b) / delta + (6 if g < b else 0)
    elif high == g:
        hue = (b - r) / delta + 2
    else:
        hue = (r - g) / delta + 4
    return {'hue': _round(hue * 60) % 360, 'saturation': _round(saturation * 100),
            'lightness': _round(lightness * 100)}


# ---- theme <-> settings -----------------------------------------------------------

def settings_patch(theme, wall=''):
    """The shell.json values that applying `theme` sets, as one change."""
    palette = theme['palette'] if theme['accentSource'] == 'fixed' else {}
    patch = {
        'theme': theme['id'],
        'themeMode': theme['mode'],
        'paletteMode': theme['accentSource'],
        'accent': theme['accent'],
        'themePalette': {'mode': theme['mode'] if palette else '',
                         **{key: palette.get(key, '') for key in PALETTE_KEYS}},
    }
    bar = theme['bar']
    if isinstance(bar, str) and bar in BAR_PRESETS:
        patch['barColorMode'] = bar
    else:
        hsl = bar if isinstance(bar, dict) else hex_to_hsl(bar)
        patch.update(barColorMode='custom', barCustomHue=hsl['hue'],
                     barCustomSaturation=hsl['saturation'], barCustomLightness=hsl['lightness'])
    if theme['font']:
        patch['font'] = theme['font']
    if wall:
        patch['wall'] = wall
    return patch


def _setting(settings, key):
    value = settings.get(key, APPEARANCE_DEFAULTS[key]) if isinstance(settings, dict) else None
    default = APPEARANCE_DEFAULTS[key]
    return value if type(value) is type(default) else default


def theme_from_settings(settings, name):
    """A theme that reproduces the appearance described by shell settings."""
    mode = _setting(settings, 'themeMode')
    source = _setting(settings, 'paletteMode')
    accent = _setting(settings, 'accent')
    raw = {'schema': SCHEMA, 'name': name, 'mode': mode if mode in MODES else 'dark',
           'accentSource': source if source in ACCENT_SOURCES else 'wallpaper',
           'accent': accent if HEX.match(accent) else APPEARANCE_DEFAULTS['accent']}
    bar = _setting(settings, 'barColorMode')
    if bar in BAR_PRESETS:
        raw['bar'] = bar
    elif bar == 'custom':
        raw['bar'] = {'hue': min(359, max(0, _setting(settings, 'barCustomHue'))),
                      'saturation': min(100, max(0, _setting(settings, 'barCustomSaturation'))),
                      'lightness': min(100, max(0, _setting(settings, 'barCustomLightness')))}
    font = _setting(settings, 'font')
    if font in FONTS:
        raw['font'] = font
    palette = _setting(settings, 'themePalette')
    # The palette is only part of the look while it is in effect: a dark
    # theme's surfaces stay out of a light appearance saved from it.
    if raw['accentSource'] == 'fixed' and palette.get('mode') == raw['mode']:
        colours = {key: palette.get(key) for key in PALETTE_KEYS
                   if isinstance(palette.get(key), str) and HEX.match(palette.get(key))}
        if colours:
            raw['palette'] = colours
    return validate(raw)


# ---- catalogue -------------------------------------------------------------------

def builtin_root():
    return Path(__file__).resolve().parent.parent / 'themes'


def user_root():
    override = os.environ.get('CYBEXOS_THEME_ROOT')
    if override:
        return Path(override)
    data = os.environ.get('XDG_DATA_HOME') or os.path.join(os.path.expanduser('~'), '.local/share')
    return Path(data) / 'cybexos/themes'


def _read_regular(path, limit):
    """Bytes of a regular file that is not a link, at most `limit` of them.

    O_NONBLOCK keeps a FIFO in its place from stalling the open; it is then
    refused like any other file that is not regular.
    """
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK)
    with os.fdopen(descriptor, 'rb') as handle:
        if not stat.S_ISREG(os.fstat(handle.fileno()).st_mode):
            raise ThemeError(f'{Path(path).name} is not a regular file')
        data = handle.read(limit + 1)
    if len(data) > limit:
        raise ThemeError(f'{Path(path).name} is too large')
    return data


def load_dir(directory, builtin):
    """A theme read from its own directory, named by its id."""
    directory = Path(directory)
    try:
        theme = parse_theme_bytes(_read_regular(directory / THEME_FILE, MAX_THEME_JSON))
    except FileNotFoundError:
        raise ThemeError('theme.json is missing') from None
    except OSError as error:
        raise ThemeError(f'theme.json cannot be read: {error.strerror or error}') from None
    if theme['id'] != directory.name:
        raise ThemeError(f'its id {theme["id"]!r} does not match the folder name')
    if theme['wallpaper']:
        path = directory / theme['wallpaper']
        try:
            info = os.lstat(path)
        except OSError:
            raise ThemeError(f'its wallpaper {theme["wallpaper"]} is missing') from None
        if not stat.S_ISREG(info.st_mode) or info.st_size > MAX_IMAGE:
            raise ThemeError(f'its wallpaper {theme["wallpaper"]} is not a usable image')
    theme['builtin'] = builtin
    theme['path'] = str(directory)
    source = {}
    if not builtin:
        try:
            source = json.loads(_read_regular(directory / SOURCE_FILE, MAX_THEME_JSON))
        except (OSError, ValueError, ThemeError):
            source = {}
    theme['installedFrom'] = source if isinstance(source, dict) else {}
    return theme


def _theme_dirs(root):
    try:
        with os.scandir(root) as listing:
            entries = sorted(listing, key=lambda entry: entry.name)
    except OSError:
        return []
    # Hidden entries are install staging; files (an old personal.theme) and
    # links are not theme packages.
    return [entry for entry in entries
            if not entry.name.startswith('.') and entry.is_dir(follow_symlinks=False)]


def catalogue(builtin=None, user=None):
    """{"themes": [...], "invalid": [{"id", "error"}]}: built-ins first."""
    builtin = Path(builtin) if builtin else builtin_root()
    user = Path(user) if user else user_root()
    themes, invalid = [], []
    for entry in _theme_dirs(builtin):
        try:
            themes.append(load_dir(entry.path, True))
        except ThemeError as error:
            invalid.append({'id': entry.name, 'error': str(error)})
    builtin_ids = {theme['id'] for theme in themes}
    themes.sort(key=lambda theme: (theme['id'] != 'cybexos', theme['name'].lower()))
    personal = []
    for entry in _theme_dirs(user):
        if entry.name in builtin_ids:
            invalid.append({'id': entry.name, 'error': 'a built-in theme has the same id'})
            continue
        try:
            personal.append(load_dir(entry.path, False))
        except ThemeError as error:
            invalid.append({'id': entry.name, 'error': str(error)})
    personal.sort(key=lambda theme: theme['name'].lower())
    return {'themes': themes + personal, 'invalid': invalid}


def find(theme_id, builtin=None, user=None):
    listing = catalogue(builtin, user)
    for theme in listing['themes']:
        if theme['id'] == theme_id:
            return theme
    for entry in listing['invalid']:
        if entry['id'] == theme_id:
            raise ThemeError(f'theme {theme_id} is not usable: {entry["error"]}')
    raise ThemeError(f'no theme called {theme_id}; see `cybex theme list`')


def summary(theme):
    """What the shell lists for a theme: identity, metadata and its settings."""
    return {
        'id': theme['id'], 'name': theme['name'], 'mode': theme['mode'],
        'builtin': theme['builtin'], 'hasWallpaper': bool(theme['wallpaper']),
        'author': theme['author'], 'license': theme['license'], 'source': theme['source'],
        'installedFrom': theme.get('installedFrom', {}),
        'patch': settings_patch(theme),
    }


# ---- applying ---------------------------------------------------------------------

def expand_home(path):
    if path == '~' or path.startswith('~/'):
        return os.path.expanduser('~') + path[1:]
    return path


def settings_path():
    config = os.environ.get('XDG_CONFIG_HOME') or os.path.join(os.path.expanduser('~'), '.config')
    return Path(config) / 'cybexos/shell.json'


def read_settings(path=None):
    """The persisted shell settings as a dict; {} when there are none."""
    path = Path(path) if path else settings_path()
    try:
        data = _read_regular(path, 2 * 1024 * 1024)
    except FileNotFoundError:
        return {}
    except OSError as error:
        raise ThemeError(f'{path} cannot be read: {error.strerror or error}') from None
    if not data.strip():
        return {}
    try:
        value = json.loads(data)
    except ValueError:
        raise ThemeError(f'{path} is not valid JSON') from None
    if not isinstance(value, dict):
        raise ThemeError(f'{path} does not hold a settings object')
    return value


def wall_dir(settings):
    value = settings.get('wallDir') if isinstance(settings, dict) else None
    if not isinstance(value, str) or not (value.startswith('/') or value == '~'
                                          or value.startswith('~/')):
        value = APPEARANCE_DEFAULTS['wallDir']
    return Path(expand_home(value))


def place_wallpaper(theme, directory):
    """Copies the theme's wallpaper into the wallpaper folder; returns its name.

    The copy is named for the theme and never replaces a file: an identical
    earlier copy is reused, anything else gets a numbered name.
    """
    source = Path(theme['path']) / theme['wallpaper']
    data = _read_regular(source, MAX_IMAGE)
    check_image(theme['wallpaper'], data)
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    suffix = Path(theme['wallpaper']).suffix.lower()
    for number in range(1, 21):
        name = f'theme-{theme["id"]}{"" if number == 1 else "-" + str(number)}{suffix}'
        target = directory / name
        try:
            if _read_regular(target, MAX_IMAGE) == data:
                return name
            continue
        except FileNotFoundError:
            pass
        except (OSError, ThemeError):
            continue
        descriptor, temporary = tempfile.mkstemp(dir=directory, prefix='.theme-wallpaper-')
        try:
            with os.fdopen(descriptor, 'wb') as handle:
                handle.write(data)
            os.chmod(temporary, 0o644)
            try:
                os.link(temporary, target)
            except FileExistsError:
                continue
            return name
        finally:
            os.unlink(temporary)
    raise ThemeError(f'no free file name for the wallpaper in {directory}')


def resolve(theme, directory=None):
    """The payload `theme use` takes: the theme's name and its full patch."""
    wall = ''
    if theme['wallpaper']:
        wall = place_wallpaper(theme, directory if directory else wall_dir(read_settings()))
    return {'id': theme['id'], 'name': theme['name'], 'patch': settings_patch(theme, wall)}


def _settings_store():
    path = Path(__file__).resolve().parent / 'settings-store'
    loader = importlib.machinery.SourceFileLoader('cybexos_settings_store', str(path))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


def schema_version():
    """SettingsHelpers.VERSION of the shell this script ships with."""
    helpers = Path(__file__).resolve().parent.parent / 'Common/SettingsHelpers.js'
    match = re.search(r'^var VERSION = (\d+);$', helpers.read_text(encoding='utf-8'), re.MULTILINE)
    if not match:
        raise ThemeError('cannot read the settings schema version')
    return int(match.group(1))


def persist(patch, path=None):
    """Writes a theme's settings for the next shell start.

    Goes through the shell's own transactional writer (scripts/settings-store):
    other keys, unknown fields and the file's schema version are kept, and a
    file from a newer shell is refused rather than downgraded. A running shell
    watches the file and applies the change as well.
    """
    path = Path(path) if path else settings_path()
    version = schema_version()
    store = _settings_store()
    try:
        baseline = path.read_text(encoding='utf-8') if path.exists() else ''
        current = store.parse(baseline)
    except (OSError, UnicodeDecodeError, ValueError) as error:
        raise ThemeError(f'{path} cannot be read: {error}') from None
    stored = current.get('v')
    if isinstance(stored, (int, float)) and not isinstance(stored, bool) and stored > version:
        raise ThemeError(f'{path} was saved by a newer Cybex OS; apply the theme from Settings instead')
    # The file keeps its schema version: an older file is still migrated by
    # the shell, which reads these keys the same way in every schema.
    candidate = {**current, **patch}
    if not current:
        candidate = {'v': version, **patch}
    try:
        store.commit(path, baseline, json.dumps(candidate), candidate.get('v'))
    except ValueError as error:
        raise ThemeError(str(error)) from None


# ---- installing -----------------------------------------------------------------

def _member_parts(name):
    """Path components of an archive or repository entry, or raises."""
    if not isinstance(name, str) or not name or '\\' in name or '\0' in name:
        raise ThemeError(f'unsafe path in the source: {name!r}')
    if name.startswith('/'):
        raise ThemeError(f'absolute path in the source: {name}')
    parts = [part for part in name.split('/') if part not in ('', '.')]
    if any(part == '..' for part in parts):
        raise ThemeError(f'path escapes the theme: {name}')
    if any(ord(ch) < 32 for ch in name):
        raise ThemeError(f'unsafe path in the source: {name!r}')
    return parts


def _strip_wrapper(files):
    """Accepts a theme at the top level or inside one wrapping folder."""
    junk = [path for path in files if path[0] == '__MACOSX']
    for path in junk:
        del files[path]
    if not files:
        raise ThemeError('the source is empty')
    if (THEME_FILE,) in files:
        return files
    tops = {path[0] for path in files}
    if len(tops) == 1 and len(next(iter(files))) > 1:
        top = next(iter(tops))
        if (top, THEME_FILE) in files:
            return {path[1:]: value for path, value in files.items()}
    raise ThemeError('the source has no theme.json at its top level')


def _select(files, reader):
    """Validates the entries of a source; returns {name: bytes} to install.

    `files` maps path tuples to sizes; `reader(path)` returns an entry's bytes.
    Only theme.json and the wallpaper it names are ever read for installing.
    """
    if len(files) > MAX_ENTRIES:
        raise ThemeError(f'the source has more than {MAX_ENTRIES} files')
    files = _strip_wrapper(dict(files))
    total = 0
    for path, size in files.items():
        name = path[-1]
        if len(path) > 1:
            raise ThemeError('themes cannot contain folders: ' + '/'.join(path))
        suffix = Path(name).suffix.lower()
        if name == THEME_FILE:
            limit = MAX_THEME_JSON
        elif suffix in IMAGE_MAGIC and not name.startswith('.'):
            limit = MAX_IMAGE
        elif IGNORED_FILE.match(name):
            limit = MAX_IGNORED
        else:
            raise ThemeError(f'unexpected file {name}: a theme holds only theme.json and images')
        if size > limit:
            raise ThemeError(f'{name} is too large')
        total += size
    if total > MAX_TOTAL:
        raise ThemeError('the theme is too large')
    theme = parse_theme_bytes(reader((THEME_FILE,)))
    out = {THEME_FILE: canonical(theme).encode('utf-8')}
    if theme['wallpaper']:
        key = (theme['wallpaper'],)
        if key not in files:
            raise ThemeError(f'the wallpaper {theme["wallpaper"]} is missing')
        data = reader(key)
        check_image(theme['wallpaper'], data)
        out[theme['wallpaper']] = data
    return theme, out


def _collect_directory(directory):
    directory = Path(directory)
    files = {}
    with os.scandir(directory) as listing:
        entries = list(listing)
    for entry in entries:
        if entry.name in ('.git', SOURCE_FILE) and not entry.is_symlink():
            continue
        if entry.is_symlink():
            raise ThemeError(f'symbolic links are not allowed: {entry.name}')
        if entry.is_dir():
            raise ThemeError(f'themes cannot contain folders: {entry.name}')
        if not entry.is_file():
            raise ThemeError(f'special files are not allowed: {entry.name}')
        files[(entry.name,)] = entry.stat(follow_symlinks=False).st_size
        if len(files) > MAX_ENTRIES:
            raise ThemeError(f'the source has more than {MAX_ENTRIES} files')

    def reader(path):
        limit = MAX_THEME_JSON if path == (THEME_FILE,) else MAX_IMAGE
        return _read_regular(directory / path[0], limit)
    return _select(files, reader)


def _collect_tar(path):
    data = {}
    files = {}
    try:
        with tarfile.open(path, 'r:*') as archive:
            total = 0
            for member in archive:
                if len(files) >= MAX_ENTRIES:
                    raise ThemeError(f'the archive has more than {MAX_ENTRIES} files')
                parts = _member_parts(member.name)
                if member.isdir() or not parts:
                    continue
                if member.issym() or member.islnk():
                    raise ThemeError(f'links are not allowed: {member.name}')
                if not member.isreg():
                    raise ThemeError(f'special files are not allowed: {member.name}')
                if member.size > MAX_IMAGE:
                    raise ThemeError(f'{parts[-1]} is too large')
                total += member.size
                if total > MAX_TOTAL:
                    raise ThemeError('the archive is too large')
                key = tuple(parts)
                if key in files:
                    raise ThemeError(f'duplicate entry {member.name}')
                files[key] = member.size
                handle = archive.extractfile(member)
                data[key] = handle.read(member.size + 1) if handle else b''
    except (tarfile.TarError, EOFError, OSError) as error:
        raise ThemeError(f'the archive cannot be read: {error}') from None
    return _select(files, lambda key: data[_unwrap(data, key)])


def _unwrap(data, key):
    """The stored key for a path _strip_wrapper may have shortened."""
    if key in data:
        return key
    for stored in data:
        if stored[1:] == key:
            return stored
    raise ThemeError(f'{"/".join(key)} is missing')


def _collect_zip(path):
    files, infos = {}, {}
    try:
        with zipfile.ZipFile(path) as archive:
            entries = archive.infolist()
            if len(entries) > MAX_ENTRIES:
                raise ThemeError(f'the archive has more than {MAX_ENTRIES} files')
            total = 0
            for info in entries:
                parts = _member_parts(info.filename)
                if info.is_dir() or not parts:
                    continue
                kind = (info.external_attr >> 16) & 0o170000
                if kind == stat.S_IFLNK:
                    raise ThemeError(f'links are not allowed: {info.filename}')
                if kind not in (0, stat.S_IFREG):
                    raise ThemeError(f'special files are not allowed: {info.filename}')
                if info.flag_bits & 0x1:
                    raise ThemeError(f'encrypted entries are not allowed: {info.filename}')
                if info.file_size > MAX_IMAGE:
                    raise ThemeError(f'{parts[-1]} is too large')
                total += info.file_size
                if total > MAX_TOTAL:
                    raise ThemeError('the archive is too large')
                key = tuple(parts)
                if key in files:
                    raise ThemeError(f'duplicate entry {info.filename}')
                files[key] = info.file_size
                infos[key] = info

            def reader(key):
                info = infos[_unwrap(infos, key)]
                with archive.open(info) as handle:
                    return handle.read(info.file_size + 1)
            return _select(files, reader)
    except (zipfile.BadZipFile, zipfile.LargeZipFile, OSError, RuntimeError) as error:
        raise ThemeError(f'the archive cannot be read: {error}') from None


def check_url(url):
    """Only plain https URLs: no other protocol, credentials or options."""
    if (not isinstance(url, str) or len(url) > URL_MAX or not url.startswith('https://')
            or any(ord(ch) <= 32 or ch in '\\"\'<>`' for ch in url)):
        raise ThemeError('a Git source must be an https:// URL')
    host = url[len('https://'):].split('/', 1)[0]
    if not host or '@' in host or host.startswith('-') or '/' not in url[len('https://'):]:
        raise ThemeError('a Git source must be an https:// URL of a repository')
    return url


def _git(args, cwd=None, allow_file=False):
    # Nothing from the remote may run: no hooks (they are never cloned, and
    # none of the user's own run here either), no submodules, no LFS
    # smudging, and no protocol but https.
    command = ['git', '-c', 'core.hooksPath=/dev/null', '-c', 'protocol.allow=never',
               '-c', 'protocol.https.allow=always', '-c', 'transfer.fsckObjects=true',
               '-c', 'submodule.recurse=false']
    if allow_file:
        command += ['-c', 'protocol.file.allow=always']
    environment = {**os.environ, 'GIT_TERMINAL_PROMPT': '0', 'GIT_LFS_SKIP_SMUDGE': '1',
                   'GIT_ASKPASS': '/bin/false', 'SSH_ASKPASS': '/bin/false'}
    try:
        result = subprocess.run(command + args, cwd=cwd, stdin=subprocess.DEVNULL,
                                capture_output=True, timeout=GIT_TIMEOUT, env=environment)
    except FileNotFoundError:
        raise ThemeError('git is not installed') from None
    except subprocess.TimeoutExpired:
        raise ThemeError('the Git download timed out') from None
    if result.returncode:
        lines = result.stderr.decode('utf-8', 'replace').strip().splitlines()
        raise ThemeError('git failed: ' + (lines[-1] if lines else f'exit {result.returncode}'))
    return result.stdout


def _collect_git(url, staging, allow_file=False):
    """Fetches a repository's tree without checking anything out.

    The clone holds commits and trees only; the two blobs a theme needs are
    read with `git cat-file` after the whole tree has been checked, so
    nothing the repository contains is ever written to disk as a file.
    """
    checkout = Path(staging) / 'repository'
    _git(['clone', '--quiet', '--depth', '1', '--no-tags', '--single-branch', '--no-checkout',
          '--no-recurse-submodules', '--filter=blob:none', '--', url, str(checkout)],
         allow_file=allow_file)
    commit = _git(['rev-parse', 'HEAD'], cwd=checkout, allow_file=allow_file).decode().strip()
    listing = _git(['ls-tree', '-r', '-l', '-z', '--full-tree', 'HEAD'], cwd=checkout,
                   allow_file=allow_file)
    files, blobs = {}, {}
    for record in listing.decode('utf-8', 'replace').split('\0'):
        if not record:
            continue
        meta, _, name = record.partition('\t')
        mode, kind, sha, size = (meta.split() + ['', '', '', ''])[:4]
        parts = _member_parts(name)
        if mode == '160000' or kind == 'commit' or name == '.gitmodules':
            raise ThemeError('submodules are not allowed')
        if mode == '120000':
            raise ThemeError(f'symbolic links are not allowed: {name}')
        if kind != 'blob' or not size.isdigit():
            raise ThemeError(f'unexpected entry: {name}')
        files[tuple(parts)] = int(size)
        blobs[tuple(parts)] = sha
        if len(files) > MAX_ENTRIES:
            raise ThemeError(f'the repository has more than {MAX_ENTRIES} files')

    def reader(key):
        return _git(['cat-file', 'blob', blobs[_unwrap(blobs, key)]], cwd=checkout,
                    allow_file=allow_file)
    theme, out = _select(files, reader)
    return theme, out, commit


def install(source, replace=False, root=None, builtin=None, _allow_file_urls=False):
    """Installs a theme from a folder, an archive or an https Git URL.

    `_allow_file_urls` exists for the test suite, which serves repositories
    over file:// instead of the network; the command line never sets it.
    """
    root = Path(root) if root else user_root()
    if root.is_symlink():
        raise ThemeError(f'refusing a linked theme folder: {root}')
    root.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix='.install-', dir=root))
    try:
        origin = {'type': 'local', 'source': ''}
        if isinstance(source, str) and (source.startswith('https://') or (
                _allow_file_urls and source.startswith('file://'))):
            if not source.startswith('file://'):
                check_url(source)
            theme, files, commit = _collect_git(source, staging, allow_file=_allow_file_urls)
            origin = {'type': 'git', 'source': source, 'commit': commit}
        else:
            text = str(source)
            if re.match(r'^[A-Za-z][A-Za-z0-9+.-]*://', text) or re.match(r'^[^/]+@[^/]+:', text):
                raise ThemeError('a Git source must be an https:// URL')
            path = Path(text).expanduser()
            if path.is_symlink() and path.is_dir():
                raise ThemeError('the theme folder is a symbolic link')
            if path.is_dir():
                theme, files = _collect_directory(path)
            elif path.is_file():
                if path.stat().st_size > MAX_ARCHIVE:
                    raise ThemeError('the archive is too large')
                theme, files = (_collect_zip(path) if zipfile.is_zipfile(path)
                                else _collect_tar(path))
            else:
                raise ThemeError(f'no theme folder or archive at {source}')
            origin['source'] = str(path.resolve())
        builtin_ids = {entry.name for entry in _theme_dirs(Path(builtin) if builtin
                                                            else builtin_root())}
        if theme['id'] in builtin_ids:
            raise ThemeError(f'a built-in theme is already called {theme["id"]}')
        candidate = staging / theme['id']
        candidate.mkdir()
        for name, data in files.items():
            (candidate / name).write_bytes(data)
            (candidate / name).chmod(0o644)
        origin['installed'] = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
        (candidate / SOURCE_FILE).write_text(json.dumps(origin, indent=2) + '\n')
        destination = root / theme['id']
        if destination.exists() or destination.is_symlink():
            if not replace:
                raise ThemeError(f'a theme called {theme["id"]} is already installed; '
                                 'use --replace to update it')
            if destination.is_symlink() or not destination.is_dir():
                raise ThemeError(f'refusing to replace {destination}: not a theme folder')
            retired = staging / 'previous'
            destination.rename(retired)
            try:
                candidate.rename(destination)
            except OSError:
                retired.rename(destination)
                raise
        else:
            candidate.rename(destination)
        return load_dir(destination, False)
    finally:
        shutil.rmtree(staging, ignore_errors=True)


def remove(theme_id, root=None):
    root = Path(root) if root else user_root()
    if not isinstance(theme_id, str) or not ID.match(theme_id):
        raise ThemeError(f'{theme_id!r} is not a theme id')
    target = root / theme_id
    if target.is_symlink() or not target.is_dir():
        if (builtin_root() / theme_id).is_dir():
            raise ThemeError(f'{theme_id} is a built-in theme and cannot be removed')
        raise ThemeError(f'no user theme called {theme_id}')
    shutil.rmtree(target)


def _free_id(base, root, builtin):
    taken = {entry.name for entry in _theme_dirs(root)} | {
        entry.name for entry in _theme_dirs(builtin)}
    base = base or 'theme'
    for number in range(1, 100):
        candidate = base if number == 1 else f'{base[:44]}-{number}'
        if candidate not in taken:
            return candidate
    raise ThemeError('no free theme id; remove an old theme first')


def save(settings, name, root=None, builtin=None):
    """Saves the appearance in `settings` as a new user theme; returns it."""
    root = Path(root) if root else user_root()
    builtin = Path(builtin) if builtin else builtin_root()
    name = _text(name, 'name', NAME_MAX, required=True)
    theme = theme_from_settings(settings, name)
    theme['id'] = _free_id(slug(name), root, builtin)
    root.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix='.save-', dir=root))
    try:
        candidate = staging / theme['id']
        candidate.mkdir()
        (candidate / THEME_FILE).write_text(canonical(theme), encoding='utf-8')
        (candidate / SOURCE_FILE).write_text(json.dumps({
            'type': 'saved', 'source': '',
            'installed': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')}, indent=2) + '\n')
        candidate.rename(root / theme['id'])
    finally:
        shutil.rmtree(staging, ignore_errors=True)
    return load_dir(root / theme['id'], False)


def export(theme, destination, wallpaper=None):
    """Writes a theme where others can install it; returns the written path.

    `destination` ending in .tar.gz or .tgz is an archive holding one folder
    named for the theme; anything else is a folder that receives that theme
    folder. `wallpaper` optionally overrides the image to include.
    """
    destination = Path(destination).expanduser()
    files = {}
    image = wallpaper
    if image is None and theme.get('wallpaper'):
        image = Path(theme['path']) / theme['wallpaper']
    theme = dict(theme)
    if image is not None:
        name = 'wallpaper' + Path(image).suffix.lower()
        data = _read_regular(image, MAX_IMAGE)
        check_image(name, data)
        files[name] = data
        theme['wallpaper'] = name
    else:
        theme['wallpaper'] = ''
    files[THEME_FILE] = canonical(theme).encode('utf-8')
    if destination.name.endswith(('.tar.gz', '.tgz')):
        if destination.exists() or destination.is_symlink():
            raise ThemeError(f'{destination} already exists')
        destination.parent.mkdir(parents=True, exist_ok=True)
        descriptor, temporary = tempfile.mkstemp(dir=destination.parent, prefix='.theme-export-')
        try:
            with os.fdopen(descriptor, 'wb') as handle, \
                    tarfile.open(fileobj=handle, mode='w:gz') as archive:
                for name, data in sorted(files.items()):
                    info = tarfile.TarInfo(f'{theme["id"]}/{name}')
                    info.size, info.mode = len(data), 0o644
                    info.mtime = int(datetime.now(timezone.utc).timestamp())
                    archive.addfile(info, io.BytesIO(data))
            os.chmod(temporary, 0o644)
            os.link(temporary, destination)
        except FileExistsError:
            raise ThemeError(f'{destination} already exists') from None
        finally:
            os.unlink(temporary)
        return destination
    target = destination / theme['id']
    if target.exists() or target.is_symlink():
        raise ThemeError(f'{target} already exists')
    destination.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix='.theme-export-', dir=destination))
    try:
        for name, data in files.items():
            (staging / name).write_bytes(data)
            (staging / name).chmod(0o644)
        staging.chmod(0o755)
        staging.rename(target)
    finally:
        shutil.rmtree(staging, ignore_errors=True)
    return target


def current_wallpaper(settings):
    """The current wallpaper's path when a theme may carry it, else None."""
    wall = settings.get('wall') if isinstance(settings, dict) else None
    if not isinstance(wall, str) or not wall or '/' in wall:
        return None
    path = wall_dir(settings) / wall
    if Path(wall).suffix.lower() not in IMAGE_MAGIC:
        return None
    try:
        info = os.lstat(path)
    except OSError:
        return None
    return path if stat.S_ISREG(info.st_mode) and info.st_size <= MAX_IMAGE else None
