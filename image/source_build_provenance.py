"""Export resolved compiler facts only for the source binaries actually shipped."""
import hashlib
import json
from pathlib import Path
import re


def collect(inventory, builds=Path('/opt/cybexos-builds')):
    if not inventory['features'].get('source_builds', False):
        return []
    records = []
    for app in inventory['source_apps']:
        current = builds / app['name'] / 'current'
        record = json.loads((current / '.cybexos-build-provenance.json').read_text())
        expected = {'name': app['name'], 'repository': app['repo_url'], 'tag': app['tag'],
                    'revision': app['commit'], 'base_image': inventory['source_build_container_image']}
        if record.get('schema') != 1 or any(record.get(key) != value for key, value in expected.items()):
            raise ValueError(f'Source provenance does not match authorized inputs: {app["name"]}')
        builder = record.get('builder_image_id', '')
        if (not re.fullmatch(r'sha256:[a-f0-9]{64}', builder)
                or (current / '.cybexos-builder').read_text().strip() != builder
                or not re.fullmatch(r'[a-f0-9]{64}', record.get('recipe_sha256', ''))):
            raise ValueError(f'Incomplete source builder identity: {app["name"]}')
        if (not record.get('packages') or not all(
                isinstance(record.get('compilers', {}).get(tool), str) and record['compilers'][tool].strip()
                for tool in ('rustc', 'cargo', 'gcc', 'g++'))):
            raise ValueError(f'Incomplete resolved compiler inventory: {app["name"]}')
        for package in record['packages']:
            if not all(isinstance(package.get(key), str) and package[key]
                       for key in ('name', 'epoch', 'version', 'release', 'arch')):
                raise ValueError('Incomplete resolved builder package')
        if set(record.get('binaries', {})) != set(app['binary_names']):
            raise ValueError('Incomplete source binary inventory')
        for name, expected_digest in record['binaries'].items():
            path = current / 'bin' / name
            if path.is_symlink() or not path.is_file() or not path.stat().st_mode & 0o111:
                raise ValueError(f'Missing executable source binary: {name}')
            if hashlib.sha256(path.read_bytes()).hexdigest() != expected_digest:
                raise ValueError(f'Shipped source binary differs from its provenance: {name}')
        records.append(record)
    return records
