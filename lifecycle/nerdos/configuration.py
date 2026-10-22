"""Typed desktop declarations, edited only in a staged personal configuration."""
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
        options = run('localectl', 'list-locales', '--no-pager').splitlines()
        previous = [line.strip() for line in open('/etc/locale.conf') if line.strip() and not line.startswith('#')]
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
