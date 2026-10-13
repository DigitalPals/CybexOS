"""Exact reviewed checkout content shared by image and checkout qualification."""
import hashlib
import json
from pathlib import Path, PurePosixPath
import subprocess
import tarfile

GENERATED = {'image/update-channel.json', 'image/update-key.asc', 'image/build-provenance.json'}


def content_digest(records):
    return hashlib.sha256(json.dumps(records, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def source_files(root):
    result = subprocess.run(['git', '-C', str(root), 'ls-files', '-z', '--cached', '--others', '--exclude-standard'],
                            capture_output=True, check=True)
    paths = []
    for name in sorted(set(result.stdout.decode().split('\0')) - {''} - GENERATED):
        path = Path(root) / name
        if '__pycache__' in path.parts or path.suffix == '.pyc':
            continue
        if path.is_symlink():
            raise ValueError(f'Source snapshot must contain regular files, not symlinks: {name}')
        if path.is_file():
            paths.append((name, path))
    return paths


def tree_identity(root):
    records = [{'path': name, 'executable': bool(path.stat().st_mode & 0o111),
                'sha256': hashlib.sha256(path.read_bytes()).hexdigest()} for name, path in source_files(root)]
    return {'source_content_sha256': content_digest(records), 'source_file_count': len(records)}


def write_archive(root, destination, additions=None):
    with tarfile.open(destination, 'w:gz') as archive:
        for name, path in source_files(root):
            archive.add(path, arcname=name, recursive=False)
        for name, path in (additions or {}).items():
            if name not in GENERATED:
                raise ValueError('Unexpected generated source input')
            archive.add(path, arcname=name, recursive=False)


def archive_identity(path):
    """Validate before extraction: no traversal, duplicate names or links."""
    records, seen = [], set()
    with tarfile.open(path, 'r:gz') as archive:
        for member in archive:
            name = member.name
            if (not member.isfile() or PurePosixPath(name).is_absolute() or '..' in PurePosixPath(name).parts
                    or name in seen or name.startswith('./') or '\\' in name):
                raise ValueError('Unsafe or duplicate source archive entry')
            seen.add(name)
            if name not in GENERATED:
                stream = archive.extractfile(member)
                records.append({'path': name, 'executable': bool(member.mode & 0o111),
                                'sha256': hashlib.file_digest(stream, 'sha256').hexdigest()})
    for required in ('install', 'site.yml', 'inventory/group_vars/all.yml', 'image/build-provenance.json'):
        if required not in seen:
            raise ValueError(f'Source archive lacks required input: {required}')
    records.sort(key=lambda item: item['path'])
    return {'source_content_sha256': content_digest(records), 'source_file_count': len(records)}
