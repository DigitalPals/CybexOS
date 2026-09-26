"""Prepare verified GitHub Release assets and a small GitHub Pages RPM repository."""
import argparse
import hashlib
import gzip
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
from urllib.parse import urljoin
import xml.etree.ElementTree as ET

from release_metadata import fingerprint, public_key
from release_repository import rename_new_directory, sha256, verify_signed_rpm

ASSET_LIMIT = 2 * 1024 ** 3
ISO_PART_SIZE = 1900 * 1024 ** 2


def github_url(repository, tag):
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repository):
        raise ValueError('Use an owner/repository GitHub name')
    if not re.fullmatch(r'v\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?', tag):
        raise ValueError('Use a versioned vX.Y.Z release tag')
    return f'https://github.com/{repository}/releases/download/{tag}'


def verify_checksums(directory, filename="SHA256SUMS"):
    manifest = directory / filename
    checked = set()
    for line in manifest.read_text().splitlines():
        match = re.fullmatch(r'([0-9a-f]{64})  (.+)', line)
        if not match:
            raise ValueError('Invalid checksum manifest')
        if not re.fullmatch(r'[A-Za-z0-9_.+~^/-]+', match[2]):
            raise ValueError('Checksum filenames must be safe ASCII paths')
        name = Path(match[2])
        if name.is_absolute() or '..' in name.parts or name.as_posix() in checked:
            raise ValueError('Unsafe or repeated checksum filename')
        candidate = directory / name
        if candidate.is_symlink() or not candidate.is_file() or not candidate.resolve().is_relative_to(directory.resolve()):
            raise ValueError('Checksum file escapes the artifact directory')
        if sha256(candidate) != match[1]:
            raise ValueError(f'Artifact checksum mismatch: {name}')
        checked.add(name.as_posix())
    inventory = set()
    for path in directory.rglob('*'):
        if path.is_symlink() or (not path.is_dir() and not path.is_file()):
            raise ValueError('Artifact trees must contain only regular files and directories')
        if path.is_file() and path != manifest:
            inventory.add(path.relative_to(directory).as_posix())
    if checked != inventory:
        raise ValueError('Checksum inventory does not cover the complete artifact directory')
    return checked


def verify_release(directory, expected, temporary):
    public_key(directory / 'CYBEXOS-desktop.asc', expected)
    gpg_home = temporary / 'gpg'
    gpg_home.mkdir(mode=0o700)
    gpg = ['gpg', '--no-options', '--homedir', str(gpg_home), '--batch', '--no-autostart']
    subprocess.run([*gpg, '--import', str(directory / 'CYBEXOS-desktop.asc')], check=True, capture_output=True)
    for relative in ('release.json', 'repodata/repomd.xml'):
        subprocess.run([*gpg, '--verify', str(directory / (relative + '.asc')), str(directory / relative)],
                       check=True, capture_output=True)


def split_iso(source, destination, chunk_size=ISO_PART_SIZE):
    """Keep the original filename/checksum, with a deterministic reconstruction manifest."""
    if not source.name.isascii() or not re.fullmatch(r'[A-Za-z0-9._-]+\.iso', source.name):
        raise ValueError('ISO filename must be ASCII without spaces')
    if not isinstance(chunk_size, int) or not 0 < chunk_size < ASSET_LIMIT:
        raise ValueError('ISO part size must be positive and below the asset limit')
    digest = hashlib.sha256()
    parts = []
    with source.open('rb') as stream:
        number = 0
        while True:
            remaining = chunk_size
            name = f'{source.name}.part-{number:03d}'
            part = destination / name
            part_digest = hashlib.sha256()
            size = 0
            with part.open('xb') as output:
                while remaining:
                    block = stream.read(min(8 * 1024 * 1024, remaining))
                    if not block:
                        break
                    output.write(block)
                    digest.update(block)
                    part_digest.update(block)
                    size += len(block)
                    remaining -= len(block)
            if not size:
                part.unlink()
                break
            parts.append({'file': name, 'bytes': size, 'sha256': part_digest.hexdigest()})
            number += 1
    if not parts:
        raise ValueError('ISO is empty')
    record = {'format': 1, 'file': source.name, 'bytes': sum(item['bytes'] for item in parts),
              'sha256': digest.hexdigest(), 'parts': parts}
    (destination / (source.name + '.parts.json')).write_text(json.dumps(record, indent=2) + '\n')
    (destination / (source.name + '.sha256')).write_text(f"{record['sha256']}  {source.name}\n")
    return record


def verify_metadata(directory, packages):
    """Bind authenticated repomd metadata to the exact RPMs we will upload."""
    namespace = {'r': 'http://linux.duke.edu/metadata/repo',
                 'p': 'http://linux.duke.edu/metadata/common'}
    root = ET.parse(directory / 'repodata/repomd.xml').getroot()
    seen, primary = set(), None
    for entry in root.findall('r:data', namespace):
        location = entry.find('r:location', namespace)
        checksum = entry.find('r:checksum', namespace)
        if location is None or checksum is None or checksum.get('type') != 'sha256':
            raise ValueError('Repository metadata requires SHA-256 locations')
        relative = location.get('href', '')
        path = Path(relative)
        if path.is_absolute() or '..' in path.parts or len(path.parts) != 2 or path.parts[0] != 'repodata':
            raise ValueError('Repository metadata location escapes repodata')
        if relative in seen:
            raise ValueError('Repeated repository metadata location')
        seen.add(relative)
        source = directory / path
        if sha256(source) != checksum.text:
            raise ValueError('Signed repository metadata checksum mismatch')
        if entry.get('type') == 'primary':
            if primary is not None:
                raise ValueError('Repeated primary repository metadata')
            if source.suffix != '.gz':
                raise ValueError('Primary metadata must use gzip compression')
            with gzip.open(source, 'rb') as stream:
                content = stream.read(64 * 1024 * 1024 + 1)
            if len(content) > 64 * 1024 * 1024:
                raise ValueError('Primary repository metadata exceeds the size limit')
            primary = ET.fromstring(content)
    if primary is None:
        raise ValueError('Repository is missing primary metadata')
    listed = set()
    records = {package['sha256']: package for package in packages}
    if len(records) != len(packages):
        raise ValueError('Repeated package digest')
    for package in primary.findall('p:package', namespace):
        checksum = package.find('p:checksum', namespace)
        location = package.find('p:location', namespace)
        if checksum is None or checksum.get('type') != 'sha256' or location is None:
            raise ValueError('Primary package requires a SHA-256 checksum and URL')
        record = records.get(checksum.text)
        if record is None or checksum.text in listed:
            raise ValueError('Primary metadata does not match the release packages')
        listed.add(checksum.text)
        base = location.get('{http://www.w3.org/XML/1998/namespace}base', '')
        if urljoin(base, location.get('href', '')) != record['url']:
            raise ValueError('Primary metadata package URL differs from this GitHub Release')
        version = package.find('p:version', namespace)
        if (package.findtext('p:name', namespaces=namespace) != record['name']
                or package.findtext('p:arch', namespaces=namespace) != record['arch']
                or version is None
                or any(version.get(key) != record[field] for key, field in
                       (('epoch', 'epoch'), ('ver', 'version'), ('rel', 'release')))):
            raise ValueError('Primary metadata package identity differs from the manifest')
    if listed != set(records):
        raise ValueError('Primary metadata omits a release package')
    allowed = seen | {'repodata/repomd.xml', 'repodata/repomd.xml.asc'}
    present = {str(path.relative_to(directory)) for path in (directory / 'repodata').rglob('*') if path.is_file()}
    if present != allowed:
        raise ValueError('Repository contains unreferenced metadata files')


def verify_qualifications(paths, iso_digest, packages):
    """Require fresh installer and prior-release upgrade/recovery evidence."""
    scenarios = {'encrypted-us', 'plain-us', 'encrypted-nl', 'plain-nl'}
    fresh, upgrade, reports = set(), False, []
    candidates = {package['unsigned_input_sha256'] for package in packages}
    for path in paths:
        path = Path(path)
        if path.stat().st_size > 1024 * 1024:
            raise ValueError('Qualification report exceeds the size limit')
        report = json.loads(path.read_text())
        if not isinstance(report, dict) or report.get('status') != 'passed':
            raise ValueError('Every qualification report must have passed')
        checks = report.get('checks')
        if not isinstance(checks, list) or not all(isinstance(item, str) for item in checks):
            raise ValueError('Qualification checks must be a list of completed check names')
        prior = report.get('iso_sha256', '')
        if not isinstance(prior, str) or not re.fullmatch(r'[0-9a-f]{64}', prior):
            raise ValueError('Qualification must identify the tested ISO SHA-256')
        if prior == iso_digest and 'graphical-installer' in checks and report.get('scenario') in scenarios:
            fresh.add(report['scenario'])
        if (prior != iso_digest and report.get('candidate_rpm_sha256') in candidates
                and {'installed-rpm-upgrade', 'recovery-boot-restore'} <= set(checks)):
            upgrade = True
        reports.append(report)
    if fresh != scenarios:
        raise ValueError('Release requires all four fresh ISO installer qualifications: ' + ', '.join(sorted(scenarios - fresh)))
    if not upgrade:
        raise ValueError('Release requires a different prior ISO with the exact candidate RPM upgrade and recovery qualification')
    return reports


def prepare(signed, artifacts, destination, repository, tag, expected, qualifications=()):
    signed, artifacts, destination = Path(signed), Path(artifacts), Path(destination).absolute()
    expected = fingerprint(expected)
    downloads = github_url(repository, tag)
    if destination.exists() or destination.is_symlink():
        raise ValueError('Output must be a new directory')
    repository_files = verify_checksums(signed)
    artifact_files = verify_checksums(artifacts)
    manifest = json.loads((signed / 'release.json').read_text())
    channel = json.loads((signed / 'update-channel.json').read_text())
    owner, project = repository.split('/')
    pages_url = f'https://{owner.lower()}.github.io/{project}/44/x86_64'
    if (manifest.get('format') != 1 or manifest.get('baseurl') != pages_url
            or channel != {'baseurl': pages_url, 'fingerprint': expected, 'key_file': 'CYBEXOS-desktop.asc'}):
        raise ValueError('Release channel must match this exact GitHub Pages repository')
    if manifest['fingerprint'] != expected:
        raise ValueError('Release manifest uses an unexpected signing key')
    packages = manifest['packages']
    if not isinstance(packages, list) or not packages:
        raise ValueError('Release contains no RPMs')
    package_names = set()
    for package in packages:
        if package.get('name') != 'cybexos-desktop' or package.get('arch') != 'x86_64' or package.get('version') != tag[1:].replace('-', '~', 1):
            raise ValueError('RPM identity must match the release tag and desktop architecture')
        path = signed / package['file']
        if not re.fullmatch(r'Packages/[A-Za-z0-9][A-Za-z0-9._+~^-]*\.rpm', package['file']) or path.name in package_names:
            raise ValueError('RPM filenames must be safe, distinct release assets')
        package_names.add(path.name)
        for key in ('sha256', 'unsigned_input_sha256'):
            if not isinstance(package.get(key), str) or not re.fullmatch(r'[0-9a-f]{64}', package[key]):
                raise ValueError('Release package is missing a complete SHA-256 identity')
        if package['file'] not in repository_files or package.get('url') != downloads + '/' + path.name:
            raise ValueError('RPM metadata must reference this exact GitHub Release')
        if path.stat().st_size >= ASSET_LIMIT:
            raise ValueError('Desktop RPM exceeds the GitHub 2 GiB asset limit; split the package before release')
        if sha256(path) != package['sha256']:
            raise ValueError('Signed manifest RPM digest mismatch')
    isos = [artifacts / name for name in artifact_files if name.endswith('.iso')]
    if len(isos) != 1:
        raise ValueError('Exactly one checksum-verified ISO is required')
    iso_digest = sha256(isos[0])
    reports = verify_qualifications(qualifications, iso_digest, packages)
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.cybexos-github-', dir=destination.parent) as directory:
        work = Path(directory)
        verify_release(signed, expected, work)
        verify_metadata(signed, packages)
        stage = work / 'output'
        assets = stage / 'assets'
        pages = stage / 'pages/44/x86_64'
        assets.mkdir(parents=True)
        pages.mkdir(parents=True)
        for package in packages:
            source = signed / package['file']
            copied = assets / source.name
            shutil.copyfile(source, copied)
            if sha256(copied) != package['sha256']:
                raise ValueError('RPM changed during release preparation')
            verify_signed_rpm(copied, signed / 'CYBEXOS-desktop.asc', work)
        for name in ('release.json', 'release.json.asc', 'CYBEXOS-desktop.asc', 'update-channel.json'):
            content = (signed / name).read_bytes()
            if name == 'update-channel.json' and json.loads(content) != channel:
                raise ValueError('Channel configuration changed during release preparation')
            # Both delivery locations must contain the same snapshot; the
            # copied Pages signatures are verified again below.
            (assets / name).write_bytes(content)
            (pages / name).write_bytes(content)
        shutil.copytree(signed / 'repodata', pages / 'repodata')
        iso = split_iso(isos[0], assets)
        if iso['sha256'] != iso_digest:
            raise ValueError('ISO changed during release preparation')
        shutil.copyfile(Path(__file__).with_name('reconstruct-iso'), assets / 'reconstruct-iso.py')
        (assets / 'qualification-reports.json').write_text(json.dumps(reports, indent=2) + '\n')
        copied_verify = work / 'copied-verification'
        copied_verify.mkdir()
        verify_release(pages, expected, copied_verify)
        verify_metadata(pages, packages)
        # Metadata checksums contain only files hosted by Pages, never the large RPMs.
        for target in (assets, pages):
            files = sorted(path for path in target.rglob('*') if path.is_file())
            checksum_name = 'desktop-SHA256SUMS' if target == assets else 'SHA256SUMS'
            (target / checksum_name).write_text(''.join(f'{sha256(path)}  {path.relative_to(target)}\n' for path in files))
        (stage / 'pages/.nojekyll').touch()
        (stage / 'pages/index.html').write_text('<!doctype html><html lang="en"><meta charset="utf-8">'
            '<title>CybexOS updates</title><h1>CybexOS desktop updates</h1>'
            '<p>Signed Fedora 44 x86_64 repository. Use the public channel configuration and independently verify its signing fingerprint.</p>'
            '<a href="44/x86_64/update-channel.json">Channel configuration</a></html>\n')
        rename_new_directory(stage, destination)
    return destination


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--signed-repository', type=Path, required=True)
    parser.add_argument('--artifacts', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--repository', default='DigitalPals/CybexOS')
    parser.add_argument('--tag', required=True)
    parser.add_argument('--fingerprint', required=True)
    parser.add_argument('--qualification', type=Path, action='append', required=True,
                        help='Passed VM qualification JSON; repeat for four installer scenarios and prior-release upgrade/recovery')
    args = parser.parse_args()
    try:
        print(prepare(args.signed_repository, args.artifacts, args.output,
                      args.repository, args.tag, args.fingerprint, args.qualification))
    except (OSError, ValueError, KeyError, TypeError, ET.ParseError, subprocess.SubprocessError) as error:
        parser.exit(1, f'github-release: {error}\n')


if __name__ == '__main__':
    main()
