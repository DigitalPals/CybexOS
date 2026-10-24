"""Native package choices in the machine's single, locked package universe."""
import json
import os
from pathlib import Path
import re

from .common import Failure, Runner, atomic, locked, parse, read

ATTRIBUTE = re.compile(r'[A-Za-z0-9_][A-Za-z0-9_+-]*(?:\.[A-Za-z0-9_][A-Za-z0-9_+-]*)*')


def packages(value):
    if (not isinstance(value, list) or len(value) > 512
            or any(not isinstance(p, str) or len(p) > 200 or not ATTRIBUTE.fullmatch(p) for p in value)
            or len(set(value)) != len(value)):
        raise Failure('Choose up to 512 distinct package attributes from the catalogue.')
    return sorted(value)


def document(config):
    path = Path(config) / 'local/software.json'
    value = read(path)
    if (path.is_symlink() or not isinstance(value, dict) or set(value) != {'schema', 'packages'}
            or value['schema'] != 1):
        raise Failure('The machine-owned local/software.json declaration is missing or unsupported. Preserve personal modules.')
    return {'schema': 1, 'packages': packages(value['packages'])}


def prepare(config, request):
    if not isinstance(request, dict) or set(request) != {'packages', 'previous'}:
        raise Failure('Invalid software request')
    current = document(config)
    if packages(request['previous']) != current['packages']:
        raise Failure('Package choices changed. Refresh Software before previewing again.')
    wanted = packages(request['packages'])
    atomic(Path(config) / 'local/software.json', {'schema': 1, 'packages': wanted}, 0o644)
    return {'packages': wanted, 'previous': current['packages']}


def inventory(path='/etc/nerdos/software.json', config='/etc/nixos'):
    result = read(path)
    if not isinstance(result, dict) or result.get('schema') != 1:
        raise Failure('The installed software inventory is unavailable.')
    desired = document(config)['packages']
    return result | {'desired': desired, 'configurationChanged': desired != result['selected']}


def search(query='', *, config='/etc/nixos', installed='/etc/nerdos/software.json', cache=None, run=None):
    from .engine import config_digest
    if not isinstance(query, str) or len(query) > 200:
        raise Failure('Search is limited to 200 characters.')
    config = Path(config).resolve()
    before = config_digest(config)
    cache = Path(cache or (Path(os.environ.get('XDG_CACHE_HOME', str(Path.home() / '.cache'))) / 'nerdos/software'))
    cache.mkdir(parents=True, exist_ok=True, mode=0o700)
    run = run or Runner()
    with locked(cache / 'catalogue.lock'):
        index = read(cache / 'catalogue.json', {})
        if index.get('identity') != before:
            # Includes machine overlays; neither discovery nor lock refresh.
            expression = 'import (builtins.toPath ' + json.dumps(str(Path(__file__).with_name('software-catalogue.nix'))) + ') { machine = ' + json.dumps('path:' + str(config)) + '; }'
            data = parse(run('nix', 'eval', '--json', '--offline', '--no-update-lock-file',
                             '--impure', '--expr', expression, timeout=600, sensitive=True))
            if not isinstance(data, list):
                raise Failure('Nix returned an invalid package catalogue.')
            rows = []
            for meta in data:
                if not isinstance(meta, dict) or not ATTRIBUTE.fullmatch(meta.get('attribute', '')):
                    continue
                rows.append({'attribute': meta['attribute'], 'name': str(meta.get('name', meta['attribute'])),
                             'version': str(meta.get('version', '')),
                             'description': str(meta.get('description', ''))[:2048]})
            if config_digest(config) != before:
                raise Failure('The machine configuration changed while indexing. Refresh Software.')
            index = {'identity': before, 'packages': rows}
            atomic(cache / 'catalogue.json', index)
    current = inventory(installed, config)
    if config_digest(config) != before:
        raise Failure('The machine configuration changed. Refresh Software.')
    terms = query.casefold().split()
    rows = [p for p in index['packages'] if all(term in
            (p['attribute'] + ' ' + p['name'] + ' ' + p['description']).casefold() for term in terms)]
    rows.sort(key=lambda p: (p['attribute'].casefold() != query.casefold(),
                            not p['name'].casefold().startswith(query.casefold()), p['attribute']))
    return current | {'identity': before, 'total': len(rows), 'results': rows[:200]}
