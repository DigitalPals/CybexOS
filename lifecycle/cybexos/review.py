"""Readable changes from the exact built systems' native software manifests."""
from collections import defaultdict
from pathlib import Path
import json
import re

from .common import Failure, parse


def inventory(body):
    value = parse(body)
    if (not isinstance(value, dict) or value.get('schema') != 1
            or not isinstance(value.get('packages'), list)):
        raise Failure('The built system has no supported software inventory. No update was applied.')
    result = defaultdict(list)
    for package in value['packages']:
        if (not isinstance(package, dict)
                or any(not isinstance(package.get(key), str) for key in ('name', 'version', 'path'))
                or not package['name']
                or not re.fullmatch(r'/nix/store/[a-z0-9]{32}-[^/]+', package['path'])):
            raise Failure('The built software inventory is invalid. No update was applied.')
        entry = {key: package[key] for key in ('name', 'version', 'path')}
        entry['description'] = str(package.get('description', ''))[:2048]
        if entry not in result[entry['name']]:
            result[entry['name']].append(entry)
    return result


def compare(before, after):
    """Include same-version rebuilds and multiple installed versions honestly."""
    old, new = inventory(before), inventory(after)
    changes = []
    for name in sorted(set(old) | set(new), key=str.casefold):
        previous = {item['path']: item for item in old[name]}
        candidate = {item['path']: item for item in new[name]}
        common = previous.keys() & candidate.keys()
        previous = sorted((v for k, v in previous.items() if k not in common), key=lambda p: (p['version'], p['path']))
        candidate = sorted((v for k, v in candidate.items() if k not in common), key=lambda p: (p['version'], p['path']))
        for index in range(max(len(previous), len(candidate))):
            left = previous[index] if index < len(previous) else None
            right = candidate[index] if index < len(candidate) else None
            kind = ('added' if left is None else 'removed' if right is None
                    else 'rebuilt' if left['version'] == right['version'] else 'updated')
            changes.append({'name': name, 'before': left['version'] if left else None,
                            'after': right['version'] if right else None, 'kind': kind,
                            'oldPath': left['path'] if left else None,
                            'newPath': right['path'] if right else None,
                            'description': (right or left)['description']})
    return changes


def identity(changes):
    return json.dumps(changes, sort_keys=True, separators=(',', ':'))


# Components a person recognises, in review order. The built system declares
# their exact versions in /etc/cybexos/components.json; nothing is inferred
# from store path names.
COMPONENTS = ('cybexos', 'nixos', 'kernel', 'graphics', 'nvidia', 'firmware', 'hyprland')
# Closure-diff names the component rows already represent.
COMPONENT_PACKAGES = {'kernel': ('linux',), 'graphics': ('mesa',), 'nvidia': ('nvidia-x11',),
                      'firmware': ('linux-firmware',), 'hyprland': ('hyprland',)}
ANSI = re.compile(r'\x1b\[[0-9;]*m')
CLOSURE_LINE = re.compile(r'^(?P<name>[^:\s][^:]*): (?P<detail>.+)$')
CLOSURE_SIZE = re.compile(r'([+-][0-9]+(?:\.[0-9]+)?) ([KMGT])iB\b')


def components(body):
    """A missing or unsupported manifest lists nothing; it never blocks review."""
    try:
        value = parse(body)
    except Failure:
        return {}
    if not isinstance(value, dict) or value.get('schema') != 1 or not isinstance(value.get('components'), dict):
        return {}
    return {name: version for name, version in value['components'].items()
            if name in COMPONENTS and isinstance(version, str) and 0 < len(version) <= 128}


def desktop_entry(path):
    """The first visible application entry a package installs, if any."""
    try:
        files = sorted(Path(path, 'share', 'applications').glob('*.desktop'))[:64]
    except OSError:
        return None
    for file in files:
        try:
            text = file.read_text(errors='replace')[:65536]
        except OSError:
            continue
        section, values = None, {}
        for line in text.splitlines():
            line = line.strip()
            if line.startswith('['):
                section = line
            elif section == '[Desktop Entry]' and '=' in line and not line.startswith('#'):
                key, value = line.split('=', 1)
                values.setdefault(key.strip(), value.strip())
        if (values.get('Type') == 'Application' and values.get('Name')
                and values.get('NoDisplay', '').lower() != 'true' and values.get('Hidden', '').lower() != 'true'):
            return {'title': values['Name'][:128], 'icon': values.get('Icon', '')[:512]}
    return None


def closure(changes):
    """Names and net size of `nix store diff-closures`; presentation only."""
    names, size = set(), 0.0
    for line in ANSI.sub('', changes).splitlines():
        match = CLOSURE_LINE.match(line.strip())
        if not match:
            continue
        names.add(match['name'])
        sized = CLOSURE_SIZE.search(match['detail'])
        if sized:
            size += float(sized[1]) * 1024 ** ('KMGT'.index(sized[2]) + 1)
    return names, int(size)


def highlights(package_changes, before, after, changes, entry=desktop_entry):
    """Group a built change for people: components, apps, tools, the rest.

    Same-version rebuilds are not shown as changes. Everything else in the
    closure is counted, not listed; the full diff stays in the review.
    """
    rows = []
    for name in COMPONENTS:
        old, new = before.get(name), after.get(name)
        if old == new or (old is None and not before) or (new is None and not after):
            continue
        rows.append({'id': name, 'before': old, 'after': new})
    shown = {package for row in rows for package in COMPONENT_PACKAGES.get(row['id'], ())}
    apps, tools = [], []
    for change in package_changes:
        if change['kind'] == 'rebuilt':
            continue
        shown.add(change['name'])
        row = {key: change[key] for key in ('name', 'kind', 'before', 'after')}
        application = entry(change['newPath'] or change['oldPath'])
        if application:
            apps.append(row | application)
        else:
            tools.append(row)
    names, size = closure(changes)
    return {'schema': 1, 'components': rows, 'apps': apps, 'tools': tools,
            'background': len(names - shown), 'sizeChange': size}
