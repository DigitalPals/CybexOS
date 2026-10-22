#!/usr/bin/env python3
"""Lossless settings writes and actual application include precedence."""
import importlib.machinery
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


def load(name, relative):
    loader = importlib.machinery.SourceFileLoader(name, str(ROOT / relative))
    spec = importlib.util.spec_from_loader(name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


STORE = load('settings_store', 'desktop/quickshell/scripts/settings-store')


class SettingsOwnership(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='nerdos-settings-ownership-')
        self.addCleanup(self.temporary.cleanup)
        self.home = Path(self.temporary.name)
        self.path = self.home / 'shell.json'

    def test_independent_concurrent_edit_survives(self):
        base = {'v': 27, 'unit': 'c', 'themeMode': 'dark', 'future': {'data': [1]}}
        local = {**base, 'unit': 'f'}
        other = {**base, 'themeMode': 'light', 'future': {'data': [2]}}
        self.path.write_text(json.dumps(other))
        saved = json.loads(STORE.commit(self.path, json.dumps(base), json.dumps(local), 27))
        self.assertEqual(saved, {**other, 'unit': 'f'})
        self.assertEqual(json.loads(self.path.read_text()), saved)

    def test_conflict_preserves_disk_and_pending_candidate(self):
        base = {'v': 27, 'barHeight': 36}
        desired = {'v': 27, 'barHeight': 40}
        current = json.dumps({'v': 27, 'barHeight': 44})
        self.path.write_text(current)
        with self.assertRaisesRegex(ValueError, '/barHeight'):
            STORE.commit(self.path, json.dumps(base), json.dumps(desired), 27)
        self.assertEqual(self.path.read_text(), current)
        copies = list(self.home.glob('shell.json.conflict-*'))
        self.assertEqual(len(copies), 1)
        self.assertEqual(json.loads(copies[0].read_text()), desired)

    def test_newer_schema_blocks_writes_even_if_loaded_file_was_older(self):
        future = '{"v":28,"future":{"opaque":true}}'
        self.path.write_text(future)
        with self.assertRaisesRegex(ValueError, 'newer shell'):
            STORE.commit(self.path, '{"v":27}', '{"v":27,"unit":"f"}', 27)
        self.assertEqual(self.path.read_text(), future)

    def test_migration_keeps_exact_original_and_unknown_fields(self):
        original = '{ "v": 3, "barHeight":30, "unknown":{"unparsed":true} }\n'
        self.path.write_text(original)
        candidate = json.loads(original)
        candidate.update(v=27, unit='f')
        STORE.commit(self.path, original, json.dumps(candidate), 27)
        backups = list(self.home.glob('shell.json.before-migration-*'))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_text(), original)
        self.assertEqual(json.loads(self.path.read_text())['unknown'], {'unparsed': True})

    def test_nested_merge_and_explicit_reset_preserve_other_edits(self):
        base = {'v': 27, 'unit': 'c', 'modOpts': {'weather': {'place': 'Home', 'pollMins': 10}}}
        local = {'v': 27, 'modOpts': {'weather': {'place': 'Home', 'pollMins': 20}}}
        other = {'v': 27, 'unit': 'c', 'modOpts': {'weather': {'place': 'Away', 'pollMins': 10}}}
        merged = STORE.merge(base, local, other)
        self.assertNotIn('unit', merged)
        self.assertEqual(merged['modOpts']['weather'], {'place': 'Away', 'pollMins': 20})



if __name__ == '__main__':
    unittest.main()
