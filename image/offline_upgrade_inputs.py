"""Bounded, release-bound third-party RPM fixtures for offline upgrade qualification.

Importing this module never downloads, installs, boots, or imports trust keys.
"""
import argparse
from contextlib import contextmanager
from dataclasses import dataclass
import hashlib
import inspect
import itertools
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import tempfile
from urllib.parse import urlsplit

from build_support import atomic_json, digest

MANIFEST = 'manifest.json'
MAX_MANIFEST_BYTES = 1024 * 1024
MAX_RPMS = 256
MAX_RPM_BYTES = 512 * 1024 * 1024
MAX_TOTAL_BYTES = 2 * 1024 * 1024 * 1024
SIGNATURE_TAGS = ('RSAHEADER', 'DSAHEADER', 'SIGPGP', 'SIGGPG')
BINDINGS = ('baseline_iso_sha256', 'candidate_rpm_sha256', 'candidate_offline_rpm_sha256')
RPM_FIELDS = {'filename', 'name', 'nevra', 'architecture', 'sha256', 'size', 'signature', 'repository'}


@contextmanager
def regular_stream(path, maximum):
    """Never open a symlink, device or FIFO, or read an unbounded input."""
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, 'rb') as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or not 0 < info.st_size <= maximum:
            raise ValueError(f'Expected a bounded regular file: {path}')
        yield stream, info.st_size


def file_sha256(path, maximum, expected_size=None):
    with regular_stream(path, maximum) as (stream, size):
        if expected_size is not None and size != expected_size:
            raise ValueError(f'RPM size mismatch: {path}')
        checksum = hashlib.sha256()
        remaining = size
        while remaining:
            chunk = stream.read(min(1024 * 1024, remaining))
            if not chunk:
                raise ValueError(f'File changed while reading: {path}')
            checksum.update(chunk)
            remaining -= len(chunk)
        if stream.read(1):
            raise ValueError(f'File changed while reading: {path}')
        return checksum.hexdigest()


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f'Duplicate manifest key: {key}')
        result[key] = value
    return result


def read_json(path):
    with regular_stream(path, MAX_MANIFEST_BYTES) as (stream, _):
        data = stream.read(MAX_MANIFEST_BYTES + 1)
    if len(data) > MAX_MANIFEST_BYTES:
        raise ValueError('Manifest exceeds size limit')
    return json.loads(data, object_pairs_hook=unique_object), hashlib.sha256(data).hexdigest()


def exact_fields(value, fields):
    if not isinstance(value, dict) or set(value) != set(fields):
        raise ValueError('Malformed dependency manifest fields')


def valid_sha(value):
    return isinstance(value, str) and re.fullmatch(r'[0-9a-f]{64}', value)


def validate_record(record):
    exact_fields(record, RPM_FIELDS)
    for field in ('filename', 'name', 'nevra', 'architecture'):
        if not isinstance(record[field], str) or len(record[field]) > 255:
            raise ValueError(f'Malformed RPM {field}')
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._+~^-]*\.rpm', record['filename']):
        raise ValueError('Unsafe dependency RPM filename')
    if (not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._+-]*', record['name'])
            or record['name'].startswith('cybexos-') or record['name'] == 'gpg-pubkey'):
        raise ValueError('Dependency must be a third-party package, never first-party or a trust key')
    if record['architecture'] not in ('x86_64', 'noarch'):
        raise ValueError('Dependency architecture must be x86_64 or noarch')
    evr = r'(?:0|[1-9][0-9]{0,9}):[A-Za-z0-9][A-Za-z0-9._+~^]*-[A-Za-z0-9][A-Za-z0-9._+~^]*'
    if not re.fullmatch(re.escape(record['name']) + '-' + evr + r'\.' + record['architecture'], record['nevra']):
        raise ValueError('Dependency NEVRA must include an explicit numeric epoch and matching architecture')
    if not valid_sha(record['sha256']):
        raise ValueError('Malformed RPM SHA-256')
    if type(record['size']) is not int or not 0 < record['size'] <= MAX_RPM_BYTES:
        raise ValueError('Dependency RPM exceeds size limit')
    signature = record['signature']
    exact_fields(signature, ('tag', 'value'))
    if (signature['tag'] not in SIGNATURE_TAGS or not isinstance(signature['value'], str)
            or len(signature['value']) > 1024
            or not re.fullmatch(r'[\x20-\x7e]+ Key ID [0-9a-fA-F]{8,64}', signature['value'])):
        raise ValueError('Missing or malformed RPM signature identity')
    validate_repository(record['repository'])


def validate_repository(repository):
    exact_fields(repository, ('id', 'url'))
    if (not isinstance(repository['id'], str)
            or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._:-]{0,127}', repository['id'])
            or not isinstance(repository['url'], str) or len(repository['url']) > 2048
            or not re.fullmatch(r'[\x21-\x7e]+', repository['url'])):
        raise ValueError('Missing or malformed repository provenance')
    url = urlsplit(repository['url'])
    # Accessing .port also rejects malformed/non-numeric/out-of-range ports.
    if url.scheme != 'https' or not url.hostname or url.port == 0 or url.username or url.password or url.fragment:
        raise ValueError('Repository provenance must be an HTTPS URL without credentials or a fragment')


@dataclass(frozen=True)
class DependencyBundle:
    directory: Path
    manifest: dict
    manifest_sha256: str

    def evidence(self):
        return {**self.manifest, 'manifest_sha256': self.manifest_sha256,
                'total_bytes': sum(item['size'] for item in self.manifest['rpms'])}

    def revalidate(self):
        current = load_bundle(self.directory)
        if current.manifest_sha256 != self.manifest_sha256:
            raise ValueError('Dependency manifest changed during qualification')
        return current


def load_bundle(directory, *, baseline_iso=None, candidate_rpm=None, candidate_offline_rpm=None):
    directory = Path(directory).absolute()
    if any(path.is_symlink() for path in (directory, *directory.parents)) or not directory.is_dir():
        raise ValueError('Dependency input must be a directory without symlinks')
    manifest, sha = read_json(directory / MANIFEST)
    exact_fields(manifest, ('schema', *BINDINGS, 'rpms'))
    if type(manifest['schema']) is not int or manifest['schema'] != 1:
        raise ValueError('Unsupported dependency manifest schema')
    if any(not valid_sha(manifest[key]) for key in BINDINGS):
        raise ValueError('Malformed dependency artifact bindings')
    supplied = (baseline_iso, candidate_rpm, candidate_offline_rpm)
    if any(path is not None for path in supplied):
        if any(path is None for path in supplied):
            raise ValueError('Dependency bundle requires the baseline ISO and both first-party candidates')
        for key, path in zip(BINDINGS, supplied):
            if digest(path) != manifest[key]:
                raise ValueError(f'Dependency bundle artifact binding mismatch: {key}')
    records = manifest['rpms']
    if not isinstance(records, list) or not 1 <= len(records) <= MAX_RPMS:
        raise ValueError('Dependency RPM count must be between 1 and 256')
    names, identities, total = set(), set(), 0
    for record in records:
        validate_record(record)
        identity = (record['name'], record['architecture'])
        if record['filename'] in names or identity in identities:
            raise ValueError('Duplicate dependency RPM filename or package architecture')
        names.add(record['filename'])
        identities.add(identity)
        total += record['size']
    if total > MAX_TOTAL_BYTES:
        raise ValueError('Dependency bundle exceeds total size limit')
    entries = list(itertools.islice(directory.iterdir(), MAX_RPMS + 2))
    if {path.name for path in entries} != names | {MANIFEST} or len(entries) != len(names) + 1:
        raise ValueError('Dependency directory has extra or missing files')
    for record in records:
        if file_sha256(directory / record['filename'], MAX_RPM_BYTES, record['size']) != record['sha256']:
            raise ValueError(f'Dependency RPM checksum mismatch: {record["filename"]}')
    return DependencyBundle(directory, manifest, sha)


def rpm_identity(path):
    """Used only by the optional host manifest creator (requires rpm)."""
    fields = '%{NAME}\n%{EPOCHNUM}\n%{VERSION}\n%{RELEASE}\n%{ARCH}\n'
    fields += ''.join('%{' + tag + ':pgpsig}\n' for tag in SIGNATURE_TAGS)
    values = subprocess.run(['rpm', '-qp', '--qf', fields, str(path)], check=True,
                            capture_output=True, text=True, timeout=30,
                            env={**os.environ, 'LC_ALL': 'C', 'TZ': 'UTC'}).stdout.splitlines()
    if len(values) != 5 + len(SIGNATURE_TAGS):
        raise ValueError('Unexpected RPM identity output')
    name, epoch, version, release, architecture = values[:5]
    signatures = [(tag, value) for tag, value in zip(SIGNATURE_TAGS, values[5:]) if value != '(none)']
    if not signatures:
        raise ValueError('Dependency RPM is unsigned')
    tag, value = signatures[0]
    return {'name': name, 'nevra': f'{name}-{epoch}:{version}-{release}.{architecture}',
            'architecture': architecture, 'signature': {'tag': tag, 'value': value}}


def create_manifest(directory, baseline_iso, candidate_rpm, candidate_offline_rpm, provenance):
    """Describe already verified downloads; never fetch RPMs or trust new keys."""
    directory = Path(directory).absolute()
    if any(path.is_symlink() for path in (directory, *directory.parents)) or not directory.is_dir():
        raise ValueError('Dependency input must be a directory without symlinks')
    destination = directory / MANIFEST
    if destination.exists() or destination.is_symlink():
        raise ValueError('Refusing to replace a dependency manifest')
    entries = list(itertools.islice(directory.iterdir(), MAX_RPMS + 1))
    if not 1 <= len(entries) <= MAX_RPMS or not isinstance(provenance, dict) or set(provenance) != {p.name for p in entries}:
        raise ValueError('Provenance must describe every RPM and no extra files')
    records = []
    total = 0
    for path in sorted(entries):
        if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._+~^-]*\.rpm', path.name):
            raise ValueError('Unsafe dependency RPM filename')
        # Bound input before invoking the host RPM parser.
        sha = file_sha256(path, MAX_RPM_BYTES)
        size = path.stat().st_size
        record = {'filename': path.name, **rpm_identity(path), 'size': size,
                  'sha256': sha, 'repository': provenance[path.name]}
        validate_record(record)
        total += size
        records.append(record)
    if total > MAX_TOTAL_BYTES:
        raise ValueError('Dependency bundle exceeds total size limit')
    manifest = {'schema': 1, **dict(zip(BINDINGS, map(digest, (baseline_iso, candidate_rpm, candidate_offline_rpm)))),
                'rpms': records}
    atomic_json(destination, manifest)
    try:
        return load_bundle(directory, baseline_iso=baseline_iso, candidate_rpm=candidate_rpm,
                           candidate_offline_rpm=candidate_offline_rpm)
    except BaseException:
        destination.unlink()
        raise


@dataclass(frozen=True)
class RawDependencyFixture:
    """Private pre-build snapshots, with a content identity but no artifact bindings."""
    directory: Path
    records: list
    provenance_sha256: str

    def evidence(self):
        value = {'schema': 1, 'provenance_sha256': self.provenance_sha256, 'rpms': self.records}
        sha = hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
        return {**value, 'fixture_sha256': sha, 'total_bytes': sum(record['size'] for record in self.records)}

    def bind(self, baseline_iso, candidate_rpm, candidate_offline_rpm):
        bundle = create_manifest(self.directory, baseline_iso, candidate_rpm, candidate_offline_rpm,
                                 {record['filename']: record['repository'] for record in self.records})
        if bundle.manifest['rpms'] != self.records:
            (self.directory / MANIFEST).unlink()
            raise ValueError('Raw dependency fixture changed after admission')
        return bundle


def snapshot_raw_dependencies(directory, provenance_file, destination):
    """Admit trusted raw RPMs before a build, without changing caller inputs."""
    directory, provenance_file, destination = (Path(path).absolute() for path in (directory, provenance_file, destination))
    if any(path.is_symlink() for path in (directory, *directory.parents)) or not directory.is_dir():
        raise ValueError('Raw dependency input must be a directory without symlinks')
    if any(path.is_symlink() for path in (provenance_file, *provenance_file.parents)):
        raise ValueError('Dependency provenance must not use symlinks')
    if destination.resolve().is_relative_to(directory.resolve()):
        raise ValueError('Dependency staging must be outside the caller input directory')
    provenance, provenance_sha = read_json(provenance_file)
    entries = list(itertools.islice(directory.iterdir(), MAX_RPMS + 1))
    if (not 1 <= len(entries) <= MAX_RPMS or not isinstance(provenance, dict)
            or set(provenance) != {path.name for path in entries}):
        raise ValueError('Provenance must describe every raw RPM and no extra files (1 to 256 RPMs)')
    for path in entries:
        if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._+~^-]*\.rpm', path.name):
            raise ValueError('Unsafe raw dependency RPM filename')
        validate_repository(provenance[path.name])
    destination.mkdir(mode=0o700)
    try:
        records, identities, total = [], set(), 0
        for path in sorted(entries):
            copied = destination / path.name
            with regular_stream(path, MAX_RPM_BYTES) as (source, size):
                total += size
                if total > MAX_TOTAL_BYTES:
                    raise ValueError('Raw dependency fixture exceeds total size limit')
                sha, remaining = hashlib.sha256(), size
                with copied.open('xb') as output:
                    while remaining:
                        chunk = source.read(min(1024 * 1024, remaining))
                        if not chunk:
                            raise ValueError('Raw dependency RPM changed while copying')
                        output.write(chunk)
                        sha.update(chunk)
                        remaining -= len(chunk)
                    if source.read(1):
                        raise ValueError('Raw dependency RPM grew while copying')
                    os.fchmod(output.fileno(), 0o400)
            record = {'filename': path.name, **rpm_identity(copied), 'size': size,
                      'sha256': sha.hexdigest(), 'repository': provenance[path.name]}
            validate_record(record)
            identity = (record['name'], record['architecture'])
            if identity in identities:
                raise ValueError('Duplicate raw dependency package architecture')
            identities.add(identity)
            records.append(record)
        # Artifact hashes have fixed length, so reject a fixture that cannot
        # fit the bound manifest before spending time on the candidate build.
        preview = {'schema': 1, **{key: '0' * 64 for key in BINDINGS}, 'rpms': records}
        if len(json.dumps(preview, indent=2, sort_keys=True).encode()) + 1 > MAX_MANIFEST_BYTES:
            raise ValueError('Raw dependency manifest exceeds size limit')
        return RawDependencyFixture(destination, records, provenance_sha)
    except BaseException:
        shutil.rmtree(destination)
        raise


@contextmanager
def transfer_stream(bundle, record):
    """Snapshot bounded bytes so a file growing during SSH cannot extend transfer."""
    with regular_stream(bundle.directory / record['filename'], MAX_RPM_BYTES) as (source, size), tempfile.TemporaryFile() as snapshot:
        if size != record['size']:
            raise ValueError('Dependency RPM size changed before transfer')
        checksum = hashlib.sha256()
        remaining = size
        while remaining:
            chunk = source.read(min(1024 * 1024, remaining))
            if not chunk:
                raise ValueError('Dependency RPM changed before transfer')
            snapshot.write(chunk)
            checksum.update(chunk)
            remaining -= len(chunk)
        if source.read(1) or checksum.hexdigest() != record['sha256']:
            raise ValueError('Dependency RPM checksum changed before transfer')
        snapshot.seek(0)
        yield snapshot


def verify_guest(directory, records):
    """Self-contained verifier executed as root with the guest's existing RPM DB."""
    import hashlib
    import os
    from pathlib import Path
    import re
    import stat
    import subprocess

    directory = Path(directory)
    if directory.is_symlink() or not directory.is_dir():
        raise ValueError('Unsafe guest dependency directory')
    if {path.name for path in directory.iterdir()} != {item['filename'] for item in records}:
        raise ValueError('Extra or missing guest dependency RPMs')
    environment = {**os.environ, 'LC_ALL': 'C', 'TZ': 'UTC'}
    for record in records:
        path = directory / record['filename']
        info = path.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_size != record['size']:
            raise ValueError('Guest dependency RPM size or file type mismatch')
        with path.open('rb') as stream:
            if hashlib.file_digest(stream, 'sha256').hexdigest() != record['sha256']:
                raise ValueError('Guest dependency RPM checksum mismatch')
        identity = '%{NAME}-%{EPOCHNUM}:%{VERSION}-%{RELEASE}.%{ARCH}\n%{ARCH}\n'
        identity += '%{' + record['signature']['tag'] + ':pgpsig}\n'
        result = subprocess.run(['rpm', '-qp', '--qf', identity, str(path)], check=True,
                                capture_output=True, text=True, timeout=30, env=environment)
        if result.stdout.splitlines() != [record['nevra'], record['architecture'], record['signature']['value']]:
            raise ValueError('Guest dependency RPM identity or signature header mismatch')
        # No --import or alternate database: use only installed guest trust.
        result = subprocess.run(['rpm', '--define', '_pkgverify_level all', '--define', '_pkgverify_flags 0x0',
                                 '--checksig', '--verbose', str(path)], check=True,
                                capture_output=True, text=True, timeout=30, env=environment)
        if not re.search(r'(?im)^\s*.*\b(?:signature|openpgp)\b.*:\s*OK\s*$', result.stdout):
            raise ValueError('Guest dependency RPM has no verified trusted signature')


def guest_verification_script(directory, records):
    return "python3 - <<'PY'\n" + inspect.getsource(verify_guest) + f'\nverify_guest({str(directory)!r}, {records!r})\nPY\n'


def seal_guest_inputs(source_directory, records, firstparty):
    """Copy account-owned transfers into new root-only inodes before verification."""
    import hashlib
    import os
    from pathlib import Path
    import shutil
    import stat
    import tempfile

    if os.geteuid() != 0:
        raise PermissionError('Upgrade staging requires root')
    parent = Path('/tmp')
    info = parent.lstat()
    if (not stat.S_ISDIR(info.st_mode) or info.st_uid != 0
            or (info.st_mode & 0o022 and not info.st_mode & stat.S_ISVTX)):
        raise PermissionError('Upgrade staging parent must be root-owned and protected against renames')
    if set(firstparty) != {'candidate', 'offline_candidate'}:
        raise ValueError('Sealing requires both first-party candidates')
    directory = Path(tempfile.mkdtemp(prefix='cybexos-qualification-sealed-', dir=parent))
    try:
        os.chmod(directory, 0o700)
        (directory / 'candidates').mkdir(mode=0o700)
        (directory / 'dependencies').mkdir(mode=0o700)

        def copy_file(source, destination, expected, *, source_fd=None):
            # Never follow a swapped symlink or block on an account-owned FIFO.
            descriptor = os.open(source, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=source_fd)
            with os.fdopen(descriptor, 'rb') as original:
                info = os.fstat(original.fileno())
                size = expected['size']
                if (type(size) is not int or size <= 0 or not stat.S_ISREG(info.st_mode)
                        or info.st_size != size):
                    raise ValueError('Transferred upgrade RPM size or file type mismatch')
                output_fd = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
                with os.fdopen(output_fd, 'wb') as output:
                    remaining = size
                    while remaining:
                        chunk = original.read(min(1024 * 1024, remaining))
                        if not chunk:
                            raise ValueError('Transferred upgrade RPM changed during sealing')
                        output.write(chunk)
                        remaining -= len(chunk)
                    if original.read(1):
                        raise ValueError('Transferred upgrade RPM grew during sealing')
                    output.flush()
                    os.fchmod(output.fileno(), 0o400)
            # Verify the new inode, never the account-owned source pathname.
            with destination.open('rb') as copied:
                if hashlib.file_digest(copied, 'sha256').hexdigest() != expected['sha256']:
                    raise ValueError('Sealed upgrade RPM checksum mismatch')

        result = {'directory': str(directory), 'dependencies': []}
        for key, expected in firstparty.items():
            destination = directory / 'candidates' / (key + '.rpm')
            copy_file(expected['source'], destination, expected)
            result[key] = str(destination)
        # Pin the original directory inode too; a parent-path swap cannot turn
        # an RPM open into traversal through an account-controlled symlink.
        source_fd = os.open(source_directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            for record in records:
                destination = directory / 'dependencies' / record['filename']
                copy_file(record['filename'], destination, record, source_fd=source_fd)
                result['dependencies'].append(str(destination))
        finally:
            os.close(source_fd)
        verify_guest(directory / 'dependencies', records)
        return result
    except BaseException:
        shutil.rmtree(directory)
        raise


def guest_sealing_script(directory, records, firstparty):
    return ("python3 - <<'PY'\nimport json\n" + inspect.getsource(verify_guest) + '\n'
            + inspect.getsource(seal_guest_inputs)
            + f'\nprint(json.dumps(seal_guest_inputs({str(directory)!r}, {records!r}, {firstparty!r})))\nPY\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('create', 'verify'))
    parser.add_argument('directory', type=Path)
    parser.add_argument('--baseline-iso', type=Path, required=True)
    parser.add_argument('--candidate-rpm', type=Path, required=True)
    parser.add_argument('--candidate-offline-rpm', type=Path, required=True)
    parser.add_argument('--provenance', type=Path, help='Create only: JSON mapping RPM filenames to {id, url} repositories')
    args = parser.parse_args()
    try:
        if args.action == 'create':
            if not args.provenance:
                parser.error('create requires --provenance')
            provenance, _ = read_json(args.provenance)
            bundle = create_manifest(args.directory, args.baseline_iso, args.candidate_rpm,
                                     args.candidate_offline_rpm, provenance)
        else:
            if args.provenance:
                parser.error('--provenance is only valid for create')
            bundle = load_bundle(args.directory, baseline_iso=args.baseline_iso, candidate_rpm=args.candidate_rpm,
                                 candidate_offline_rpm=args.candidate_offline_rpm)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        parser.error(str(error))
    print(json.dumps(bundle.evidence(), indent=2, sort_keys=True))


if __name__ == '__main__':
    main()
