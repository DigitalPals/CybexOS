"""Shortcut settings transactions; every file and subprocess is isolated."""
import copy
import hashlib
import importlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'desktop/quickshell/scripts'))
backend = importlib.import_module('system_settings_keybindings')


class KeybindingsBackend(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='cybexos-keybindings-backend-')
        self.addCleanup(self.temporary.cleanup)
        base = Path(self.temporary.name)
        patcher = patch.dict(os.environ, {'HOME': str(base), 'XDG_CONFIG_HOME': str(base / 'config'),
                                         'XDG_RUNTIME_DIR': str(base / 'runtime'),
                                         'XDG_DATA_HOME': str(base / 'data'), 'XDG_STATE_HOME': str(base / 'state')})
        patcher.start()
        self.addCleanup(patcher.stop)
        self.service = backend.KeybindingsSettings()
        self.service.path.parent.mkdir(parents=True)
        self.service.state_path.parent.mkdir(parents=True)
        self.state = {'v': 1, 'error': None, 'actions': [], 'custom': [], 'diagnostics': []}
        self.service.state_path.write_text(json.dumps(self.state))
        patcher = patch.object(backend, 'run', return_value='ok')
        self.run = patcher.start()
        self.addCleanup(patcher.stop)
        self.preferences = {'v': 1, 'actions': {'apps.browser': {'keys': ['SUPER + ALT + B']}}}

    def apply(self, preferences=None, version=None):
        return self.service.dispatch({'action': 'apply', 'preferences': preferences or self.preferences,
                                      'version': self.service.read()[1] if version is None else version})

    def test_snapshot_includes_lua_state_preferences_exact_hash_and_live_binds(self):
        raw = b'{ "v": 1, "future": "keep" }\n'
        self.service.path.write_bytes(raw)
        self.run.return_value = '[{"modmask":64,"key":"B","description":"Personal: Browser"}]'
        result = self.service.snapshot()
        self.assertEqual(result['state'], self.state)
        self.assertEqual(result['preferences'], {'v': 1, 'future': 'keep'})
        self.assertEqual(result['version'], hashlib.sha256(raw).hexdigest())
        self.assertEqual(result['binds'][0]['description'], 'Personal: Browser')
        self.run.assert_called_once_with(['hyprctl', '-j', 'binds'])

    def test_malformed_state_is_a_read_error_not_a_partially_loaded_model(self):
        self.state['actions'] = [None]
        self.service.state_path.write_text(json.dumps(self.state))
        with self.assertRaisesRegex(ValueError, 'state could not be read'):
            self.service.snapshot()
        self.run.assert_not_called()

    def test_apply_verifies_contained_error_and_returns_exact_committed_hash(self):
        result = self.apply()
        self.assertEqual(self.service.read()[0], self.preferences)
        self.assertEqual(result['version'], hashlib.sha256(self.service.path.read_bytes()).hexdigest())
        self.assertEqual(result['preferences'], self.preferences)
        self.assertEqual(self.service.path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.run.call_args_list[0].args[0], ['hyprctl', 'reload'])
        self.assertEqual(self.run.call_args_list[1].args[0], ['hyprctl', 'eval',
            'assert(__cybexos_keybindings_error == nil, __cybexos_keybindings_error)'])
        self.assertFalse(list(self.service.path.parent.glob('.keybindings-*')))

    def test_concurrent_edit_rejected_without_write_or_reload(self):
        version = self.service.read()[1]
        raw = b'{"v":1,"future":"external"}'
        self.service.path.write_bytes(raw)
        with self.assertRaisesRegex(ValueError, 'changed elsewhere'):
            self.apply(version=version)
        self.assertEqual(self.service.path.read_bytes(), raw)
        self.run.assert_not_called()

    def test_eval_failure_restores_exact_previous_bytes_and_reloads(self):
        for previous in (None, b'{ "v": 1, "future": "keep" }\n'):
            with self.subTest(previous=previous):
                self.service.path.unlink(missing_ok=True)
                if previous is not None:
                    self.service.path.write_bytes(previous)
                self.run.reset_mock()
                self.run.side_effect = ['ok', 'error: validation failed', 'ok']
                with self.assertRaisesRegex(ValueError, 'Previous preferences were restored'):
                    self.apply()
                self.assertEqual(self.service.path.read_bytes() if self.service.path.exists() else None, previous)
                self.assertEqual(self.run.call_count, 3)
                self.assertEqual(self.run.call_args.args[0], ['hyprctl', 'reload'])

    def test_reload_failure_and_failed_recovery_are_reported(self):
        self.run.side_effect = ['rejected', 'ok']
        with self.assertRaisesRegex(ValueError, 'Previous preferences were restored'):
            self.apply()
        self.assertFalse(self.service.path.exists())
        self.run.side_effect = ['ok', ValueError('eval failed'), 'rejected']
        with self.assertRaisesRegex(ValueError, 'recovery did not complete'):
            self.apply()
        self.assertFalse(self.service.path.exists())

    def test_symlink_duplicate_key_oversized_empty_and_nonregular_files_rejected(self):
        outside = self.service.path.parent / 'target.json'
        outside.write_text('{"v":1}')
        for raw in (b'{"v":1,"v":1}', b' ' * 65537, b'', b'{"v":true}', b'{"v":1,"custom":null}', b'{"v":1,"future":NaN}'):
            self.service.path.write_bytes(raw)
            with self.subTest(raw=raw[:40]), self.assertRaises(ValueError):
                self.service.read()
        self.service.path.unlink()
        self.service.path.symlink_to(outside)
        with self.assertRaises(ValueError):
            self.service.read()
        self.assertEqual(outside.read_text(), '{"v":1}')
        self.service.path.unlink()
        os.mkfifo(self.service.path)
        with self.assertRaises(ValueError):
            self.service.read()
        self.run.assert_not_called()

    def test_custom_schema_and_multibyte_command_limits(self):
        entry = {'id': 'custom.notes', 'group': 'Apps', 'label': 'Notes', 'keys': ['SUPER + N'],
                 'run': {'type': 'command', 'command': 'kitty -e nvim ~/notes.md'}}
        backend.validate({'v': 1, 'custom': [entry]})
        for patch_value in ({'id': 'custom.UPPER'}, {'group': 'Apps: bad'}, {'label': 'bad\nname'},
                            {'keys': ['SUPER + N', 'super+n']}, {'keys': ['mouse:272']},
                            {'keys': ['SUPER + F1'] * 5}, {'run': {'type': 'url', 'url': 'file:///etc/passwd'}},
                            {'run': {'type': 'app', 'desktopId': 'gimp.desktop; false'}},
                            {'run': {'type': 'webapp', 'id': '$(false)'}},
                            {'run': {'type': 'command', 'command': 'é' * 257}}):
            with self.subTest(patch_value=patch_value), self.assertRaises(ValueError):
                backend.validate({'v': 1, 'custom': [{**entry, **patch_value}]})
        backend.validate({'v': 1, 'custom': [{**entry, 'run': {'type': 'command', 'command': 'é' * 256}}]})
        with self.assertRaises(ValueError):
            backend.validate({'v': 1, 'custom': [entry, copy.deepcopy(entry)]})

    def test_outer_request_rejects_duplicate_json_keys(self):
        # Import main without starting it so unrelated GI services need no bus.
        import importlib.util
        spec = importlib.util.spec_from_file_location('settings_entry', ROOT / 'desktop/quickshell/scripts/system-settings.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        import io
        with patch.object(sys, 'argv', ['system-settings.py', 'keybindings']), \
                patch.object(sys, 'stdin', io.TextIOWrapper(io.BytesIO(b'{"action":"snapshot","action":"apply"}\n'))), \
                patch('sys.stdout', new_callable=io.StringIO) as output:
            module.main()
            result = json.loads(output.getvalue())
        self.assertFalse(result['success'])
        self.run.assert_not_called()


if __name__ == '__main__':
    unittest.main()
