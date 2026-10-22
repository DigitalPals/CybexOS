#!/usr/bin/env python3
"""Authenticate local assets before publishing and public assets before promotion."""
import argparse
import hashlib
from pathlib import Path
import sys
import urllib.error
import urllib.request
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'lifecycle'))
from nerdos.common import Failure, read
from nerdos.trust import https, verify, validate_release

def verify_assets(manifest, trust, local=False, *, expected_version=None, expected_revision=None, expected_nar_hash=None):
    release = verify(manifest.read_bytes(), Path(str(manifest) + '.sig').read_bytes(), trust, 'release')
    validate_release(release, '0.0.0', 'x86_64-linux', '26.05', 'beta')
    expected = {'version': expected_version, 'revision': expected_revision, 'narHash': expected_nar_hash}
    if any(value is not None for value in expected.values()):
        if any(value is None for value in expected.values()):
            raise Failure('Expected release identity requires version, exact revision and NAR hash together')
        for name, value in expected.items():
            if release[name] != value:
                raise Failure('Authenticated release ' + name + ' does not match the selected tag/source identity')
    for asset in release['assets']:
        sha = hashlib.sha256()
        size = 0
        stream = (manifest.parent / asset['name']).open('rb') if local else urllib.request.urlopen(asset['url'], timeout=60)
        with stream as response:
            if not local:
                https(response.url, {'github.com', 'objects.githubusercontent.com', 'release-assets.githubusercontent.com'})
            while chunk := response.read(1024 * 1024):
                size += len(chunk)
                if size > asset['bytes']:
                    raise Failure('Asset exceeds authenticated size: ' + asset['name'])
                sha.update(chunk)
        if size != asset['bytes'] or sha.hexdigest() != asset['sha256']:
            raise Failure('Release asset failed content verification: ' + asset['name'])
    return release


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('manifest', type=Path)
    parser.add_argument('trust', type=Path)
    parser.add_argument('--local', action='store_true', help='Verify sibling files without downloading public assets')
    parser.add_argument('--expected-version', help='Bind the signed manifest to the selected semantic tag')
    parser.add_argument('--expected-revision', help='Exact commit selected by that tag')
    parser.add_argument('--expected-nar-hash', help='Measured NAR identity of the selected tag source')
    args = parser.parse_args()
    verify_assets(args.manifest, read(args.trust), args.local, expected_version=args.expected_version,
                  expected_revision=args.expected_revision, expected_nar_hash=args.expected_nar_hash)


if __name__ == '__main__':
    try:
        main()
    except (Failure, OSError, urllib.error.URLError) as error:
        sys.exit(str(error))
