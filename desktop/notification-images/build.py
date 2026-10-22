#!/usr/bin/python3
"""Build/install local public-Qt image identities; shared checkout/image recipe."""
# SPDX-License-Identifier: MIT
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

SOURCES = ('CMakeLists.txt', 'LICENSE', 'build.py', 'imagefingerprints.cpp',
           'imagefingerprints.h', 'plugin.cpp', 'plugins.qmltypes', 'qmldir', 'tests.cpp')
MODULE = 'usr/lib64/qt6/qml/CybexOS/Images'
ARTIFACTS = tuple(f'{MODULE}/{name}' for name in
                  ('libcybexosnotificationimagesplugin.so', 'qmldir', 'plugins.qmltypes')) + (
                      'usr/share/licenses/cybexos-notification-images/LICENSE',)
MANIFEST = 'usr/share/cybexos/notification-images/build.json'


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def source_hashes(source):
    return {name: sha256(source / name) for name in SOURCES}


def install(source, root):
    inputs = {'source_sha256': source_hashes(source), 'qt': subprocess.check_output(
        ['pkg-config', '--modversion', 'Qt6Core', 'Qt6Quick', 'Qt6Qml'], text=True).splitlines()}
    manifest_path = root / MANIFEST
    try:
        previous = json.loads(manifest_path.read_text())
        if (previous['inputs'] == inputs and set(previous['artifacts']) == set(ARTIFACTS)
                and all(sha256(root / name) == checksum for name, checksum in previous['artifacts'].items())):
            print('UNCHANGED: native notification images')
            return previous
    except (OSError, ValueError, KeyError, TypeError):
        pass
    with tempfile.TemporaryDirectory(prefix='cybexos-notification-images-') as temporary:
        build = Path(temporary) / 'build'
        staged = Path(temporary) / 'root'
        subprocess.run(['cmake', '-S', str(source), '-B', str(build),
                        '-DCMAKE_BUILD_TYPE=Release', '-DCMAKE_INSTALL_PREFIX=/usr',
                        '-DBUILD_TESTING=ON'], check=True)
        subprocess.run(['cmake', '--build', str(build), '--parallel', '2'], check=True)
        subprocess.run(['ctest', '--test-dir', str(build), '--output-on-failure'], check=True)
        subprocess.run(['cmake', '--install', str(build)], check=True,
                       env={**os.environ, 'DESTDIR': str(staged)})
        if source_hashes(source) != inputs['source_sha256']:
            raise RuntimeError('Native notification image sources changed during build')
        manifest = {'v': 1, 'inputs': inputs, 'artifacts': {name: sha256(staged / name) for name in ARTIFACTS}}
        for name in ARTIFACTS:
            destination = root / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            descriptor, pending = tempfile.mkstemp(prefix='.notification-images-', dir=destination.parent)
            os.close(descriptor)
            try:
                shutil.copyfile(staged / name, pending)
                os.chmod(pending, 0o755 if name.endswith('.so') else 0o644)
                os.replace(pending, destination)
            finally:
                Path(pending).unlink(missing_ok=True)
        manifest_path.parent.mkdir(parents=True, exist_ok=True)
        descriptor, pending = tempfile.mkstemp(prefix='.build-', dir=manifest_path.parent)
        try:
            with os.fdopen(descriptor, 'w') as stream:
                json.dump(manifest, stream, indent=2, sort_keys=True)
                stream.write('\n')
            os.chmod(pending, 0o644)
            os.replace(pending, manifest_path)
        finally:
            Path(pending).unlink(missing_ok=True)
    print('CHANGED: native notification images')
    return manifest


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path('/'))
    args = parser.parse_args()
    install(Path(__file__).resolve().parent, args.root.resolve())
