#!/usr/bin/env python3
"""Release assets, signing and qualification gates. No publication side effects."""
import argparse
import base64
import datetime as dt
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'lifecycle'))
from cybexos.common import Failure, atomic, read
from cybexos.trust import Fetcher, REPO, validate_release, verify, version

REQUIRED = {
    'encrypted-install', 'plain-install', 'installation-parity', 'upstream-only', 'cybexos-only',
    'combined', 'channel-unavailable', 'invalid-signature', 'failed-build', 'interrupted-update',
    'activation-recovery', 'boot-recovery', 'personal-persistence', 'plugin-api', 'desktop-login',
    'xps-camera-frames', 'xps-suspend-audio', 'nvidia', 'secure-boot', 'authentication',
    'mandatory-access-control', 'firewall'
}


def gate(report, revision, nar_hash):
    if not re.fullmatch('[0-9a-f]{40}', revision):
        raise Failure('Release qualification requires an exact committed revision')
    if not re.fullmatch(r'sha256-[A-Za-z0-9+/]{43}=', nar_hash):
        raise Failure('Release qualification requires a NAR content identity')
    if not isinstance(report, dict) or report.get('revision') != revision or report.get('narHash') != nar_hash:
        raise Failure('Qualification source identity does not match the release')
    checks = report.get('checks', {})
    if not isinstance(checks, dict) or not REQUIRED.issubset(checks) or any(
            not isinstance(checks[name], dict) or checks[name].get('result') != 'passed'
            or not isinstance(checks[name].get('evidence'), str) or not checks[name]['evidence'].strip()
            for name in REQUIRED):
        raise Failure('Release qualification is incomplete or has failing/skipped checks')
    if report.get('kind') != 'installation-update-and-physical-qualification':
        raise Failure('Fixture/build-only reports cannot qualify a release')


def sign(path, key, key_id, trust, purpose):
    signature = subprocess.check_output(['openssl', 'pkeyutl', '-sign', '-rawin', '-inkey', str(key), '-in', str(path)])
    atomic(str(path) + '.sig', {'keyId': key_id, 'signature': base64.b64encode(signature).decode()}, 0o644)
    # A wrong secret, key ID, expired key or purpose must fail before any
    # immutable release publication or Pages push can take place.
    verify(path.read_bytes(), Path(str(path) + '.sig').read_bytes(), trust, purpose)


def manifest(directory, release_version, revision, nar_hash, notes, dependencies):
    version(release_version)
    expected = {'cybexos-source.tar.gz', 'release-notes.md', 'qualification.json', 'SHA256SUMS',
                f'cybexos-{release_version}-x86_64-linux.iso'}
    if not expected.issubset(path.name for path in directory.iterdir() if path.is_file()):
        raise Failure('Release is missing required source, ISO, notes, checksums or qualification assets')
    gate(read(directory / 'qualification.json'), revision, nar_hash)
    assets = []
    for path in sorted(directory.iterdir()):
        if path.name in ('manifest.json', 'manifest.json.sig') or not path.is_file():
            continue
        if not re.fullmatch('[A-Za-z0-9._-]+', path.name):
            raise Failure('Asset filename must be ASCII without spaces')
        with path.open('rb') as stream:
            checksum = hashlib.file_digest(stream, 'sha256').hexdigest()
        assets.append({'name': path.name, 'url': f'https://github.com/{REPO}/releases/download/v{release_version}/{path.name}',
                       'sha256': checksum, 'bytes': path.stat().st_size})
    result = {'schema': 1, 'version': release_version, 'revision': revision, 'narHash': nar_hash,
              'architectures': ['x86_64-linux'], 'nixos': ['26.05'], 'configurationApi': 1, 'pluginApi': 1,
              'minUpdater': 1, 'notes': notes, 'assets': assets, 'vendorInputs': dependencies}
    validate_release(result, '0.0.0', 'x86_64-linux', '26.05', 'beta')
    atomic(directory / 'manifest.json', result, 0o644)


def channel(manifest_path, name, sequence, previous=None, trust=None, fetch=None):
    if not isinstance(trust, dict):
        raise Failure('Channel promotion requires publisher trust')
    release = verify(manifest_path.read_bytes(), Path(str(manifest_path) + '.sig').read_bytes(), trust, 'release')
    validate_release(release, '0.0.0', 'x86_64-linux', '26.05', name)
    if sequence < 1:
        raise Failure('Channel sequence must be positive and strictly advance the published channel')
    if previous is not None:
        # Expiry does not prevent renewal, but prior bytes and source identity
        # must still be authenticated before comparing sequence and version.
        old = verify(previous.read_bytes(), Path(str(previous) + '.sig').read_bytes(), trust, 'channel')
        fields = {'schema', 'channel', 'sequence', 'expires', 'manifest', 'sha256'}
        if not isinstance(old, dict) or set(old) != fields or old['schema'] != 1 or old['channel'] != name or type(old['sequence']) is not int:
            raise Failure('Published channel metadata is invalid')
        if sequence <= old['sequence']:
            raise Failure('Channel sequence must strictly advance the published channel')
        if not isinstance(old['manifest'], str) or not re.fullmatch(
                rf'https://github.com/{REPO}/releases/download/v[0-9A-Za-z.-]+/manifest.json', old['manifest']):
            raise Failure('Published channel release URL is invalid')
        body = fetch.get(old['manifest'])
        if hashlib.sha256(body).hexdigest() != old['sha256']:
            raise Failure('Published channel release identity mismatch')
        old_release = verify(body, fetch.get(old['manifest'] + '.sig'), trust, 'release')
        validate_release(old_release, '0.0.0', 'x86_64-linux', '26.05', name)
        if old['manifest'] != f'https://github.com/{REPO}/releases/download/v{old_release["version"]}/manifest.json':
            raise Failure('Published channel and release version disagree')
        if version(release['version']) < version(old_release['version']):
            raise Failure('Channel downgrade rejected; retained-generation rollback is separate')
    return {'schema': 1, 'channel': name, 'sequence': sequence,
            'expires': (dt.datetime.now(dt.timezone.utc) + dt.timedelta(days=30)).isoformat(),
            'manifest': f'https://github.com/{REPO}/releases/download/v{release["version"]}/manifest.json',
            'sha256': hashlib.sha256(manifest_path.read_bytes()).hexdigest()}


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest='action', required=True)
    g = sub.add_parser('gate'); g.add_argument('report', type=Path); g.add_argument('revision'); g.add_argument('nar_hash')
    m = sub.add_parser('manifest'); m.add_argument('directory', type=Path); m.add_argument('version'); m.add_argument('revision'); m.add_argument('nar_hash'); m.add_argument('notes', type=Path)
    s = sub.add_parser('sign'); s.add_argument('path', type=Path); s.add_argument('key', type=Path); s.add_argument('key_id')
    s.add_argument('--trust', type=Path, required=True); s.add_argument('--purpose', choices=['release', 'channel'], required=True)
    c = sub.add_parser('channel'); c.add_argument('manifest', type=Path); c.add_argument('channel', choices=['stable','beta']); c.add_argument('sequence', type=int); c.add_argument('output', type=Path)
    c.add_argument('--previous', type=Path); c.add_argument('--trust', type=Path, required=True)
    args = parser.parse_args()
    if args.action == 'gate':
        gate(read(args.report), args.revision, args.nar_hash)
    elif args.action == 'manifest':
        manifest(args.directory, args.version, args.revision, args.nar_hash, args.notes.read_text(), ['lanzaboote'])
    elif args.action == 'sign':
        sign(args.path, args.key, args.key_id, read(args.trust), args.purpose)
    else:
        with tempfile.TemporaryDirectory(prefix='cybexos-channel-') as cache:
            result = channel(args.manifest, args.channel, args.sequence, args.previous, read(args.trust), Fetcher(cache))
        atomic(args.output, result, 0o644)


if __name__ == '__main__':
    try:
        main()
    except Failure as error:
        sys.exit(str(error))
