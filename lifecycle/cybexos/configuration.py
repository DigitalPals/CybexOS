"""Typed desktop declarations, edited only in a staged personal configuration."""
import json
import re
from .common import Failure, atomic, read


FIELDS = ('timezone', 'locale')


def changes(request):
    """The one or two regional changes a request carries, each field once."""
    if not isinstance(request, dict) or set(request) != {'changes'} or not isinstance(request['changes'], list):
        raise Failure('Invalid regional configuration request')
    items = request['changes']
    if not 1 <= len(items) <= len(FIELDS) or any(
            not isinstance(item, dict) or set(item) != {'field', 'value', 'previous'} for item in items):
        raise Failure('Invalid regional configuration request')
    fields = [item['field'] for item in items]
    if len(set(fields)) != len(fields):
        raise Failure('Invalid regional configuration request')
    for item in items:
        value = item['value']
        if item['field'] not in FIELDS or not isinstance(value, str) or not re.fullmatch(r'[A-Za-z0-9_+./@-]{1,80}', value) or '..' in value:
            raise Failure('Invalid regional setting')
    return items


def region(config, request, run):
    """Stage every requested regional field into one personal declaration.

    Each change is checked against the running system before anything is
    written, so a stale timezone never lands beside a valid language change.
    """
    staged = {}
    for item in changes(request):
        field, value = item['field'], item['value']
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
                    or not all(isinstance(entry, str) for entry in current['data'])):
                raise Failure('Could not read the current regional setting')
            previous = current['data']
        expected = item['previous']
        if (sorted(previous) if isinstance(previous, list) else previous) != (sorted(expected) if isinstance(expected, list) and all(isinstance(x, str) for x in expected) else expected):
            raise Failure('The current regional setting changed. Refresh before previewing again.')
        if value not in options:
            raise Failure('Choose an installed regional setting')
        staged[field] = value.replace('.utf8', '.UTF-8') if field == 'locale' else value
    path = config / 'desktop-settings.json'
    existing = read(path)
    if not isinstance(existing, dict) or set(existing) - set(FIELDS):
        raise Failure('Personal desktop-settings.json is not supported. Preserve it and edit local Nix modules explicitly.')
    atomic(path, existing | staged, 0o644)


def verify_region(config, request, run):
    """Do not offer a generation whose regional preference is overridden."""
    for item in changes(request):
        option = 'time.timeZone' if item['field'] == 'timezone' else 'i18n.defaultLocale'
        effective = json.loads(run('nix', 'eval', '--json', '--no-update-lock-file',
                                   f'path:{config}#nixosConfigurations.cybexos.config.{option}'))
        expected = item['value'].replace('.utf8', '.UTF-8') if item['field'] == 'locale' else item['value']
        if effective != expected:
            raise Failure('This regional setting is overridden by a stronger NixOS declaration. '
                          'Review your machine and personal modules; no deployment was prepared.')
