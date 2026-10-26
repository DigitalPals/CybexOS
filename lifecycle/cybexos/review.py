"""Readable changes from the exact built systems' native software manifests."""
from collections import defaultdict
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
