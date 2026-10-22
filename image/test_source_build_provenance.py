"""Reject incomplete or stale compiler evidence before shipping offline builds."""
import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from source_build_provenance import collect


class SourceBuildProvenance(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='cybexos-source-provenance.')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.current = self.root / 'demo/current'
        (self.current / 'bin').mkdir(parents=True)
        self.binary = self.current / 'bin/demo'
        self.binary.write_bytes(b'fixture executable')
        self.binary.chmod(0o755)
        self.inventory = {'features': {'source_builds': True},
                          'source_build_container_image': 'fedora@sha256:' + 'a' * 64,
                          'source_apps': [{'name': 'demo', 'repo_url': 'https://example.invalid/demo',
                                           'tag': 'v1', 'commit': 'b' * 40, 'binary_names': ['demo']}]}
        self.record = {'schema': 1, 'name': 'demo', 'repository': 'https://example.invalid/demo',
                       'tag': 'v1', 'revision': 'b' * 40,
                       'base_image': self.inventory['source_build_container_image'],
                       'builder_image_id': 'sha256:' + 'c' * 64, 'recipe_sha256': 'd' * 64,
                       'packages': [{'name': 'rust', 'epoch': '0', 'version': '1.90',
                                     'release': '1.fc44', 'arch': 'x86_64'}],
                       'compilers': {tool: tool + ' 1.90' for tool in ('rustc', 'cargo', 'gcc', 'g++')},
                       'binaries': {'demo': hashlib.sha256(self.binary.read_bytes()).hexdigest()}}
        (self.current / '.cybexos-builder').write_text(self.record['builder_image_id'] + '\n')
        self.write(self.record)

    def write(self, record):
        (self.current / '.cybexos-build-provenance.json').write_text(json.dumps(record))

    def test_exports_actual_facts_without_podman_cache_access(self):
        self.assertEqual(collect(self.inventory, self.root), [self.record])
        disabled = copy.deepcopy(self.inventory)
        disabled['features']['source_builds'] = False
        self.assertEqual(collect(disabled, self.root / 'absent'), [])

    def test_missing_or_stale_metadata_cannot_silently_disappear_from_export(self):
        (self.current / '.cybexos-build-provenance.json').unlink()
        with self.assertRaises(OSError):
            collect(self.inventory, self.root)
        for field in ('revision', 'base_image', 'builder_image_id', 'recipe_sha256', 'compilers', 'packages', 'binaries'):
            with self.subTest(field=field):
                bad = copy.deepcopy(self.record)
                bad[field] = {} if field in ('compilers', 'binaries') else [] if field == 'packages' else 'stale'
                self.write(bad)
                with self.assertRaises(ValueError):
                    collect(self.inventory, self.root)

    def test_changed_shipped_binary_fails_before_artifact_export(self):
        self.binary.write_bytes(b'replaced executable')
        with self.assertRaisesRegex(ValueError, 'differs from its provenance'):
            collect(self.inventory, self.root)


if __name__ == '__main__':
    unittest.main()
