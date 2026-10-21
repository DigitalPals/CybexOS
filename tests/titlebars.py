#!/usr/bin/env python3
"""Native compiler, offline rebuild, failure and package admission contracts."""
import importlib.machinery
import importlib.util
import io
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest import mock

import yaml

ROOT = Path(__file__).resolve().parents[1]
loader = importlib.machinery.SourceFileLoader('native_titlebars_install', str(ROOT / 'roles/desktop/files/titlebars-install'))
SPEC = importlib.util.spec_from_loader(loader.name, loader)
INSTALL = importlib.util.module_from_spec(SPEC)
loader.exec_module(INSTALL)
sys.path.insert(0, str(ROOT / 'image'))
PAYLOAD = __import__('titlebars_payload')
prepare_recipe, prepare_titlebars = PAYLOAD.prepare_recipe, PAYLOAD.prepare_titlebars


class NativeTitlebars(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='cybexos-titlebars-test.')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.installer = INSTALL.Installer(self.root)
        self.recipe = self.installer.recipe
        self.recipe.mkdir(parents=True)
        self.compositor = {'rpm': '0.56.2-2.fc44.x86_64', 'abi': 'fixture', 'build_id': 'a' * 40,
                           'binary_sha256': 'b' * 64, 'headers_sha256': 'c' * 64}
        self.identity = mock.patch.object(INSTALL, 'installed_identity', side_effect=lambda: dict(self.compositor))
        self.identity.start()
        self.addCleanup(self.identity.stop)
        self.write_archive()

    def write_archive(self, unsafe=False, fail=False):
        files = {
            'CMakeLists.txt': 'cmake_minimum_required(VERSION 3.27)\nproject(test LANGUAGES CXX)\n'
                             'add_library(titlebars SHARED main.cpp)\n'
                             'set_target_properties(titlebars PROPERTIES PREFIX "")\n',
            'main.cpp': '#error expected build failure\n' if fail else 'extern "C" int value() { return 7; }\n',
            'LICENSE': 'BSD-3-Clause fixture\n', 'LICENSE.MIT': 'MIT fixture\n',
        }
        archive = self.recipe / 'source.tar.gz'
        with tarfile.open(archive, 'w:gz') as stream:
            for name, data in files.items():
                entry = tarfile.TarInfo('fixture/' + name)
                entry.size = len(data.encode())
                stream.addfile(entry, io.BytesIO(data.encode()))
            if unsafe:
                entry = tarfile.TarInfo('../../escape')
                entry.size = 3
                stream.addfile(entry, io.BytesIO(b'bad'))
        pin = {'version': 'v0.2.2', 'commit': 'a' * 40,
               'checksum': 'sha256:' + INSTALL.digest(archive)}
        (self.recipe / 'source.json').write_text(json.dumps(pin))
        # Apply a real patch and run a real native compiler, without Fedora SDK
        # dependencies. Compositor identity alone is supplied by the fixture.
        (self.recipe / 'native.patch').write_text(
            '--- a/LICENSE\n+++ b/LICENSE\n@@ -1 +1 @@\n-BSD-3-Clause fixture\n+BSD-3-Clause patched fixture\n')

    def build(self):
        self.installer.build(offline=True)

    def assert_clean(self):
        self.assertEqual(list((self.root / 'var/cache/cybexos-titlebars').glob('.build-*')), [])
        self.assertEqual(list(self.root.rglob('*.new')), [])

    def test_offline_native_build_converges_and_repairs_library_and_licenses(self):
        self.build()
        first = json.loads(self.installer.manifest.read_text())
        self.assertEqual(self.installer.library.read_bytes()[:4], b'\x7fELF')
        with mock.patch.object(INSTALL, 'run', side_effect=AssertionError('unchanged build used a subprocess')):
            self.build()
        for damaged in (self.installer.library, self.installer.licenses / 'LICENSE.MIT'):
            damaged.write_text('corrupt')
            self.build()
            saved = json.loads(self.installer.manifest.read_text())
            self.assertEqual(saved['inputs'], first['inputs'])
            self.assertEqual(INSTALL.digest(self.installer.library), saved['plugin_sha256'])
        self.assert_clean()

    def test_same_source_fedora_release_update_rebuilds_and_failure_removes_stale_plugin(self):
        self.build()
        self.compositor.update(rpm='0.56.2-3.fc44.x86_64', build_id='d' * 40)
        self.build()
        self.assertEqual(json.loads(self.installer.manifest.read_text())['inputs']['hyprland'], self.compositor)
        self.write_archive(fail=True)
        with self.assertRaises(subprocess.CalledProcessError):
            self.build()
        self.assertFalse(self.installer.library.exists())
        self.assertFalse(self.installer.manifest.exists())
        self.assert_clean()

    def test_header_package_mismatch_and_transaction_race_fail_closed(self):
        self.build()
        with mock.patch.object(INSTALL, 'installed_identity', side_effect=RuntimeError('SDK mismatch')):
            with self.assertRaisesRegex(RuntimeError, 'SDK mismatch'):
                self.build()
        self.assertFalse(self.installer.library.exists())
        with mock.patch.object(INSTALL, 'installed_identity', side_effect=[self.compositor, {'rpm': 'new'}]):
            with self.assertRaisesRegex(RuntimeError, 'changed during compilation'):
                self.build()
        self.assertFalse(self.installer.library.exists())
        self.assert_clean()

    def test_cached_source_checksum_and_archive_traversal_rejected_without_network(self):
        (self.recipe / 'source.tar.gz').write_bytes(b'altered')
        with self.assertRaisesRegex(RuntimeError, 'Verified cached'):
            self.build()
        self.write_archive(unsafe=True)
        with self.assertRaisesRegex(RuntimeError, 'Unsafe titlebar source archive'):
            self.build()
        self.assertFalse((self.root / 'escape').exists())
        self.assert_clean()

    def test_running_elf_build_id_guard_from_shared_library(self):
        # This probes the real patch in a native executable. A plugin must read
        # the host's mapped build ID rather than its own or an on-disk path.
        patch = (ROOT / 'roles/desktop/files/titlebars-native.patch').read_text()
        section = patch.split('+++ b/cybexosBuildId.hpp\n', 1)[1]
        header = '\n'.join(line[1:] for line in section.splitlines() if line.startswith('+')) + '\n'
        (self.root / 'cybexosBuildId.hpp').write_text(header)
        (self.root / 'host.cpp').write_text('#include <dlfcn.h>\nint main(int n,char** v) { '
            'auto h=dlopen(v[1],RTLD_NOW); if(!h)return 2; return ((int(*)())dlsym(h,"check"))(); }\n')
        (self.root / 'probe.cpp').write_text('#include "cybexosBuildId.hpp"\n'
            'extern "C" int check() { return cybexosHyprlandBuildId() == EXPECTED ? 0 : 1; }\n')
        host = self.root / 'host'
        subprocess.run(['g++', str(self.root / 'host.cpp'), '-Wl,--build-id', '-ldl', '-o', str(host)], check=True)
        build_id = re.search(r'Build ID: ([0-9a-f]+)', subprocess.check_output(['readelf', '-n', host], text=True))[1]
        for expected, status in ((build_id, 0), ('0' * len(build_id), 1)):
            library = self.root / 'probe.so'
            subprocess.run(['g++', '-shared', '-fPIC', str(self.root / 'probe.cpp'), '-ldl',
                            '-DEXPECTED="' + expected + '"', '-o', str(library)], check=True)
            self.assertEqual(subprocess.run([str(host), str(library)]).returncode, status)

    def test_rpm_recipe_reuses_checkout_pin_helper_and_units(self):
        inventory = yaml.safe_load((ROOT / 'inventory/group_vars/all.yml').read_text())
        payload = self.root / 'rpm'
        prepare_recipe(ROOT, payload, inventory)
        self.assertEqual((payload / 'usr/libexec/cybexos-titlebars-install').read_bytes(),
                         (ROOT / 'roles/desktop/files/titlebars-install').read_bytes())
        self.assertEqual(json.loads((payload / 'usr/share/cybexos/titlebars/source.json').read_text())['commit'],
                         inventory['titlebars_commit'])
        for suffix in ('service', 'path'):
            self.assertEqual((payload / f'usr/lib/systemd/system/cybexos-titlebars-build.{suffix}').read_bytes(),
                             (ROOT / f'roles/desktop/files/titlebars-build.{suffix}').read_bytes())
        self.assertRaises(FileNotFoundError, prepare_titlebars, ROOT, self.root / 'no-build', payload)

    def test_package_admits_complete_build_and_rejects_output_or_manifest_drift(self):
        self.build()
        project = self.root / 'project'
        files = project / 'roles/desktop/files'
        files.mkdir(parents=True)
        shutil.copyfile(ROOT / 'roles/desktop/files/titlebars-install', files / 'titlebars-install')
        shutil.copyfile(self.recipe / 'native.patch', files / 'titlebars-native.patch')
        for suffix in ('service', 'path'):
            shutil.copyfile(ROOT / f'roles/desktop/files/titlebars-build.{suffix}', files / f'titlebars-build.{suffix}')
        pin = json.loads((self.recipe / 'source.json').read_text())
        inventory = project / 'inventory/group_vars'
        inventory.mkdir(parents=True)
        (inventory / 'all.yml').write_text(yaml.safe_dump({'titlebars_' + key: value for key, value in pin.items()}))
        build = self.root / 'build'
        build.mkdir()
        (build / 'titlebars-root').symlink_to(self.root, target_is_directory=True)
        shutil.copyfile(self.installer.manifest, build / 'titlebars.json')
        payload = self.root / 'admitted'
        result = prepare_titlebars(project, build, payload)
        self.assertEqual(result['inputs']['source'], pin)
        self.assertEqual(INSTALL.digest(payload / 'usr/lib64/cybexos/titlebars.so'), result['plugin_sha256'])
        self.installer.library.write_bytes(b'damaged')
        with self.assertRaisesRegex(RuntimeError, 'does not match'):
            prepare_titlebars(project, build, payload)
        (build / 'titlebars.json').write_text('{}')
        with self.assertRaisesRegex(RuntimeError, 'manifest differs'):
            prepare_titlebars(project, build, payload)


if __name__ == '__main__':
    unittest.main()
