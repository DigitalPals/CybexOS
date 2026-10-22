#!/usr/bin/env python3
"""Capture actual distribution bytes and require channel-specific owner review.

Capture is available to internal builds without approval. check-public captures
again from the candidate, then requires complete, digest-bound review coverage.
This records decisions; it cannot establish legal rights or authenticate a reviewer.
"""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import re
import stat
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
CHANNELS = ('source', 'desktop-rpm', 'offline-rpm', 'iso', 'web')


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def identity(document):
    return hashlib.sha256(json.dumps(document, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def regular(path):
    if path.is_symlink() or not path.is_file():
        raise ValueError(f'Expected regular file: {path}')


def files(root):
    if root.is_symlink() or not root.is_dir():
        raise ValueError(f'Expected payload directory: {root}')
    result = {}
    for path in sorted(root.rglob('*')):
        key = 'file:' + path.relative_to(root).as_posix()
        mode = path.lstat().st_mode
        if stat.S_ISLNK(mode):
            result[key] = {'kind': 'link', 'target': str(path.readlink())}
        elif stat.S_ISREG(mode):
            result[key] = {'kind': 'file', 'bytes': path.stat().st_size, 'sha256': digest(path),
                           'executable': bool(mode & 0o111)}
        elif not stat.S_ISDIR(mode):
            raise ValueError(f'Unsupported shipped file: {path}')
    if not result:
        raise ValueError('Empty payload inventory')
    return result


def rpm_files(path):
    regular(path)
    def query(formatting):
        return subprocess.check_output(['rpm', '-qp', '--queryformat', formatting, str(path)],
                                       text=True).strip()
    if query('%{FILEDIGESTALGO}') != '8':
        raise ValueError('Public RPM inventory requires SHA-256 payload digests')
    result = {}
    for line in query('[%{FILENAMES}\t%{FILEDIGESTS}\t%{FILELINKTOS}\t%{FILEMODES:octal}\n]').splitlines():
        name, checksum, target, mode = line.split('\t')
        key = 'rpm:' + name
        if key in result:
            raise ValueError(f'Duplicate RPM payload path: {name}')
        result[key] = {'sha256': checksum, 'target': target, 'mode': mode}
    if not result:
        raise ValueError('Empty RPM payload inventory')
    return result


def revalidate_artifacts(inventory, directory):
    """Bind hosted Fedora RPM-query evidence to the exact later upload bytes."""
    if not inventory.get('artifacts'):
        raise ValueError('Missing captured artifact identity')
    for name, record in inventory['artifacts'].items():
        if Path(name).name != name or name in ('.', '..'):
            raise ValueError('Unsafe captured artifact name')
        path = directory / name
        regular(path)
        if path.stat().st_size != record.get('bytes') or digest(path) != record.get('sha256'):
            raise ValueError(f'Artifact changed after payload capture: {name}')


def capture(channel, *, root=None, artifacts=(), sbom=None):
    if channel not in CHANNELS:
        raise ValueError('Unknown distribution channel')
    artifact_map = {}
    for path in artifacts:
        regular(path)
        if path.name in artifact_map:
            raise ValueError('Duplicate artifact basename')
        artifact_map[path.name] = {'sha256': digest(path), 'bytes': path.stat().st_size}
    if channel in ('desktop-rpm', 'offline-rpm'):
        prefix = 'cybexos-desktop-' if channel == 'desktop-rpm' else 'cybexos-offline-apps-'
        if len(artifacts) != 1 or not artifacts[0].name.startswith(prefix) or artifacts[0].suffix != '.rpm':
            raise ValueError('Expected exactly one channel-specific RPM')
        items = rpm_files(artifacts[0])
    else:
        if root is None:
            raise ValueError('A complete payload directory is required')
        items = files(root)
    if channel == 'source' and (not artifact_map or 'file:LICENSE' not in items):
        raise ValueError('Source review requires the actual archive and extracted payload')
    if channel == 'iso':
        # The prepared publication contains all ISO parts, their checksum files,
        # the signed RPMs and metadata. Its SBOM describes the exact raw ISO.
        if sbom is None or sbom.resolve().parent != root.resolve():
            raise ValueError('ISO review requires the shipped SPDX SBOM inside the asset directory')
        regular(sbom)
        from sbom import described_package, verify_release_sbom
        sidecar = sbom.with_name(sbom.name.removesuffix('.spdx.json') + '.iso.sha256')
        regular(sidecar)
        match = re.fullmatch(r'([a-f0-9]{64})  ([A-Za-z0-9._-]+\.iso)\n?', sidecar.read_text())
        if not match:
            raise ValueError('Missing exact ISO checksum')
        iso_digest, iso_name = match.groups()
        document = verify_release_sbom(sbom, iso_name, iso_digest)
        parts_path = root / (iso_name + '.parts.json')
        regular(parts_path)
        parts = json.loads(parts_path.read_text())
        if (parts.get('format') != 1 or parts.get('file') != iso_name
                or parts.get('sha256') != iso_digest or not parts.get('parts')):
            raise ValueError('ISO reconstruction identity disagrees with the SBOM')
        complete, total = hashlib.sha256(), 0
        for index, part in enumerate(parts['parts']):
            name = f'{iso_name}.part-{index:03d}'
            recorded = items.get('file:' + name, {})
            if (part.get('file') != name or recorded.get('kind') != 'file'
                    or recorded.get('sha256') != part.get('sha256')
                    or recorded.get('bytes') != part.get('bytes')):
                raise ValueError('Missing or changed ISO part')
            with (root / name).open('rb') as stream:
                while block := stream.read(8 * 1024 * 1024):
                    complete.update(block)
                    total += len(block)
        if total != parts.get('bytes') or complete.hexdigest() != iso_digest:
            raise ValueError('ISO parts do not reconstruct the SBOM subject')
        for package in document['packages']:
            key = 'package:' + package['SPDXID']
            if key in items:
                raise ValueError('Duplicate SPDX package')
            items[key] = package
        # Raw build inventories and toolchain facts must be available to reviewers,
        # rather than existing only inside a Podman cache or an old audit report.
        for name in ('rpm-inventory.tsv', 'flatpak-inventory.tsv', 'package-manifest.json',
                     'source-build-provenance.json', 'build-provenance.json'):
            if 'file:' + name not in items:
                raise ValueError(f'Missing actual build evidence: {name}')
        source_facts = items['file:source-build-provenance.json']['sha256']
        if source_facts not in described_package(document).get('sourceInfo', ''):
            raise ValueError('Source toolchain evidence is not bound to the ISO SBOM')
    for name, artifact in artifact_map.items():
        items['artifact:' + name] = artifact
    return {'schema': 1, 'channel': channel, 'artifacts': artifact_map, 'items': items}


def nonempty(value):
    return isinstance(value, str) and bool(value.strip())


def verify(inventory, manifest, evidence_root=ROOT):
    if manifest.get('schema') != 1 or manifest.get('publication') != 'PUBLIC':
        raise ValueError('Expected explicit PUBLIC distribution review manifest')
    matches = [entry for entry in manifest.get('reviews', [])
               if entry.get('channel') == inventory['channel'] and entry.get('inventorySha256') == identity(inventory)]
    if len(matches) != 1:
        raise ValueError(f'No unique reviewed {inventory["channel"]} inventory for {identity(inventory)}')
    review = matches[0]
    if review.get('decision') != 'approved' or not nonempty(review.get('reviewedBy')):
        raise ValueError('Owner review is unresolved')
    try:
        date = datetime.fromisoformat(review['reviewedAt'].replace('Z', '+00:00'))
        if date.tzinfo is None:
            raise ValueError('Review timestamp needs a timezone')
    except (KeyError, TypeError, ValueError) as error:
        raise ValueError('Review needs a valid timestamp with timezone') from error
    covered = set()
    for component in review.get('components', []):
        if (component.get('decision') != 'approved'
                or not all(nonempty(component.get(field)) for field in ('name', 'license', 'obligations'))
                or component.get('license', '').upper() in ('UNKNOWN', 'NOASSERTION', 'UNRESOLVED', 'NONE')
                or component.get('trademarks') not in ('reviewed', 'not-applicable')):
            raise ValueError('Unresolved component copyright, obligations or trademark review')
        evidence = component.get('evidence', {})
        relative = Path(evidence.get('path', ''))
        path = evidence_root / relative
        if (relative.is_absolute() or '..' in relative.parts or not relative.parts
                or any(parent.is_symlink() for parent in [path, *path.parents])):
            raise ValueError('Evidence must be a regular repository file')
        regular(path)
        if not re.fullmatch('[a-f0-9]{64}', evidence.get('sha256', '')) or digest(path) != evidence['sha256']:
            raise ValueError('Review evidence changed or is missing a SHA-256')
        members = component.get('items', [])
        # Compact groups are still bound to the exact full inventory digest;
        # prefixes never approve future files. Keep original code, each third-
        # party component, and independent trademark decisions in separate groups.
        if isinstance(members, dict):
            prefixes = members.get('prefixes', [])
            excludes = members.get('excludePrefixes', [])
            if (not prefixes or not all(nonempty(value) for value in [*prefixes, *excludes])
                    or set(members) - {'prefixes', 'excludePrefixes'}):
                raise ValueError('Invalid component inventory selectors')
            members = [key for key in inventory['items']
                       if key.startswith(tuple(prefixes)) and not key.startswith(tuple(excludes))]
        if not members or len(set(members)) != len(members):
            raise ValueError('Component must identify exact inventory items')
        if covered.intersection(members) or not set(members).issubset(inventory['items']):
            raise ValueError('Duplicate or unshipped review item')
        covered.update(members)
    missing = set(inventory['items']) - covered
    if missing:
        raise ValueError(f'Unreviewed shipped items: {", ".join(sorted(missing)[:8])}')
    return {'publication': 'PUBLIC', 'channel': inventory['channel'],
            'inventorySha256': identity(inventory), 'reviewedBy': review['reviewedBy'],
            'reviewedAt': review['reviewedAt']}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=('capture', 'check-public'))
    parser.add_argument('--channel', required=True, choices=CHANNELS)
    parser.add_argument('--root', type=Path)
    parser.add_argument('--artifact', action='append', type=Path, default=[])
    parser.add_argument('--sbom', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--reviews', type=Path, default=ROOT / 'assets/distribution-review.json')
    args = parser.parse_args()
    try:
        if args.root and args.output.resolve().is_relative_to(args.root.resolve()):
            raise ValueError('Write inventories outside their input payload directory')
        record = capture(args.channel, root=args.root, artifacts=args.artifact, sbom=args.sbom)
        args.output.write_text(json.dumps(record, indent=2, sort_keys=True) + '\n')
        print(f'{args.channel} inventory SHA-256: {identity(record)}')
        if args.command == 'check-public':
            verify(record, json.loads(args.reviews.read_text()))
            print('PUBLIC distribution review passed')
        return 0
    except (OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError) as error:
        print(f'distribution-review: {error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
