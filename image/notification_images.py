#!/usr/bin/python3
"""Stage and admit the same local Qt image module used by checkout installs."""
# SPDX-License-Identifier: MIT
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
RECIPE = Path('roles/desktop/files/notification-images')
SOURCES = ('CMakeLists.txt', 'LICENSE', 'build.py', 'imagefingerprints.cpp',
           'imagefingerprints.h', 'plugin.cpp', 'plugins.qmltypes', 'qmldir', 'tests.cpp')
MODULE = 'usr/lib64/qt6/qml/CybexOS/Images'
ARTIFACTS = tuple(f'{MODULE}/{name}' for name in
                  ('libcybexosnotificationimagesplugin.so', 'qmldir', 'plugins.qmltypes')) + (
                      'usr/share/licenses/cybexos-notification-images/LICENSE',)
MANIFEST = 'usr/share/cybexos/notification-images/build.json'


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def prepare_recipe(root, destination):
    recipe = destination / 'usr/share/cybexos/notification-images'
    recipe.mkdir(parents=True, exist_ok=True)
    for name in SOURCES:
        shutil.copyfile(root / RECIPE / name, recipe / name)


def prepare_notification_images(root, build, payload):
    staged = build / 'notification-images-root'
    manifest = json.loads((staged / MANIFEST).read_text())
    expected = {name: sha256(root / RECIPE / name) for name in SOURCES}
    if (manifest.get('v') != 1 or manifest['inputs']['source_sha256'] != expected
            or json.loads((build / 'notification-images.json').read_text()) != manifest
            or set(manifest['artifacts']) != set(ARTIFACTS)):
        raise RuntimeError('Native notification image build differs from this source revision')
    for name in SOURCES:
        if sha256(staged / 'usr/share/cybexos/notification-images' / name) != expected[name]:
            raise RuntimeError('Staged notification image recipe differs: ' + name)
    for name in ARTIFACTS:
        if sha256(staged / name) != manifest['artifacts'][name]:
            raise RuntimeError('Native notification image artifact differs: ' + name)
        destination = payload / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(staged / name, destination)
        destination.chmod(0o755 if name.endswith('.so') else 0o644)
    prepare_recipe(root, payload)
    shutil.copyfile(staged / MANIFEST, payload / MANIFEST)
    return manifest


def main():
    if os.geteuid() != 0 or Path('/etc/hostname').read_text().strip() != 'image-builder':
        raise RuntimeError('Native image builds require the disposable Fedora image builder')
    import yaml
    tasks = yaml.safe_load((ROOT / 'roles/desktop/tasks/notification-images.yml').read_text())
    packages = next(task['ansible.builtin.dnf']['name'] for task in tasks if 'ansible.builtin.dnf' in task)
    subprocess.run(['dnf', 'install', '-y', *packages], check=True)
    build = Path('/home/builder/build')
    staged = build / 'notification-images-root'
    staged.mkdir(parents=True, exist_ok=False)
    prepare_recipe(ROOT, staged)
    subprocess.run(['python3', str(staged / 'usr/share/cybexos/notification-images/build.py'),
                    '--root', str(staged)], check=True)
    shutil.copyfile(staged / MANIFEST, build / 'notification-images.json')


if __name__ == '__main__':
    main()
