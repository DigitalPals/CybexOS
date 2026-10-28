"""Typed desktop declarations, edited only in a staged personal configuration."""
import json
import re
from .common import Failure, atomic, read


def region(config, request, run):
    if not isinstance(request, dict) or set(request) != {'field', 'value', 'previous'}:
        raise Failure('Invalid regional configuration request')
    field, value = request['field'], request['value']
    if field not in ('timezone', 'locale') or not isinstance(value, str) or not re.fullmatch(r'[A-Za-z0-9_+./@-]{1,80}', value) or '..' in value:
        raise Failure('Invalid regional setting')
    if field == 'timezone':
        options = run('timedatectl', 'list-timezones', '--no-pager').splitlines()
        previous = run('timedatectl', 'show', '--property=Timezone', '--value').strip()
    else:
        options = [value.replace('.utf8', '.UTF-8') for value in run('locale', '-a').splitlines()
                   if value.endswith(('.utf8', '.UTF-8'))]
        # Match the Settings snapshot: localed omits redundant LC_* values
        # equal to LANG, even when they are explicit in /etc/locale.conf.
        current = json.loads(run('busctl', '--system', '--json=short', 'get-property',
                                 'org.freedesktop.locale1', '/org/freedesktop/locale1',
                                 'org.freedesktop.locale1', 'Locale'))
        if (not isinstance(current, dict) or current.get('type') != 'as'
                or not isinstance(current.get('data'), list)
                or not all(isinstance(item, str) for item in current['data'])):
            raise Failure('Could not read the current regional setting')
        previous = current['data']
    expected = request['previous']
    if (sorted(previous) if isinstance(previous, list) else previous) != (sorted(expected) if isinstance(expected, list) and all(isinstance(x, str) for x in expected) else expected):
        raise Failure('The current regional setting changed. Refresh before previewing again.')
    if value not in options:
        raise Failure('Choose an installed regional setting')
    path = config / 'desktop-settings.json'
    existing = read(path)
    if not isinstance(existing, dict) or set(existing) - {'timezone', 'locale'}:
        raise Failure('Personal desktop-settings.json is not supported. Preserve it and edit local Nix modules explicitly.')
    if field == 'locale':
        value = value.replace('.utf8', '.UTF-8')
    atomic(path, existing | {field: value}, 0o644)


def verify_region(config, request, run):
    """Do not offer a generation whose regional preference is overridden."""
    option = 'time.timeZone' if request['field'] == 'timezone' else 'i18n.defaultLocale'
    effective = json.loads(run('nix', 'eval', '--json', '--no-update-lock-file',
                               f'path:{config}#nixosConfigurations.cybexos.config.{option}'))
    expected = request['value'].replace('.utf8', '.UTF-8') if request['field'] == 'locale' else request['value']
    if effective != expected:
        raise Failure('This regional setting is overridden by a stronger NixOS declaration. '
                      'Review your machine and personal modules; no deployment was prepared.')
