#!/usr/bin/env python3
"""Input persistence and native region authorization with no host mutations."""
import copy
import importlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / 'roles/desktop/files/quickshell/scripts'
sys.path.insert(0, str(SCRIPTS))
inputs = importlib.import_module('system_settings_input')
region = importlib.import_module('system_settings_region')
CATALOG = [{'value': 'us', 'label': 'English', 'variants': [{'value': '', 'label': 'Default'}, {'value': 'intl', 'label': 'International'}]},
           {'value': 'nl', 'label': 'Dutch', 'variants': [{'value': '', 'label': 'Default'}]}]


class InputPersistence(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='cybexos-input-test-')
        self.addCleanup(self.temp.cleanup)
        self.service = inputs.InputSettings()
        self.service.path = Path(self.temp.name) / 'config/input.json'
        self.service.path.parent.mkdir()
        self.run = patch.object(inputs, 'run', return_value='ok').start()
        self.addCleanup(patch.stopall)
        patch.object(inputs, 'catalog', return_value=CATALOG).start()

    def apply(self, section='touchpad', values=None, version=None):
        return self.service.dispatch({'action': 'apply', 'section': section,
                                     'values': {'tap': False} if values is None else values,
                                     'version': self.service.read()[1] if version is None else version})

    def test_unknown_values_and_layout_metadata_survive(self):
        original = {'v': 1, 'future': {'unknown': [1, 'data']},
                    'keyboard': {'other': True, 'layouts': [{'layout': 'us', 'variant': '', 'future': 7}]},
                    'touchpad': {'future': 'keep', 'naturalScroll': False}}
        self.service.path.write_text(json.dumps(original))
        self.apply()
        saved = self.service.read()[0]
        expected = copy.deepcopy(original)
        expected['touchpad']['tap'] = False
        self.assertEqual(saved, expected)
        self.apply('keyboard', {'layouts': [{'layout': 'us', 'variant': ''}, {'layout': 'nl', 'variant': ''}]})
        self.assertEqual(self.service.read()[0]['keyboard']['layouts'][0]['future'], 7)
        self.assertEqual(self.service.path.stat().st_mode & 0o777, 0o600)

    def test_stale_version_does_not_save_or_reload(self):
        version = self.service.read()[1]
        self.service.path.write_text('{"v":1,"future":true}')
        with self.assertRaisesRegex(ValueError, 'changed elsewhere'):
            self.apply(version=version)
        self.run.assert_not_called()
        self.assertTrue(self.service.read()[0]['future'])

    def test_rejected_reload_restores_original_bytes(self):
        old = b'{ "v": 1, "future": 2 }\n'
        self.service.path.write_bytes(old)
        self.run.side_effect = ['error: bad configuration', 'ok']
        with self.assertRaisesRegex(ValueError, 'restored'):
            self.apply()
        self.assertEqual(self.service.path.read_bytes(), old)
        self.assertEqual(self.run.call_count, 2)

    def test_failed_first_save_removes_created_file(self):
        self.run.side_effect = [ValueError('unavailable'), 'ok']
        with self.assertRaisesRegex(ValueError, 'restored'):
            self.apply()
        self.assertFalse(self.service.path.exists())
        self.assertFalse(list(self.service.path.parent.glob('.input-*')))

    def test_contained_lua_error_also_restores_original_preferences(self):
        old = b'{"v":1,"touchpad":{"tap":true}}\n'
        self.service.path.write_bytes(old)
        self.run.side_effect = ['ok', 'error: input loader failed', 'ok']
        with self.assertRaisesRegex(ValueError, 'restored'):
            self.apply()
        self.assertEqual(self.service.path.read_bytes(), old)

    def test_symlink_and_invalid_document_are_never_replaced(self):
        destination = self.service.path.parent / 'personal.json'
        destination.write_text('{"v":1}')
        self.service.path.symlink_to(destination)
        with self.assertRaisesRegex(ValueError, 'symlink'):
            self.apply()
        self.assertEqual(destination.read_text(), '{"v":1}')
        self.service.path.unlink()
        self.service.path.write_text('{"v":1,"v":1}')
        with self.assertRaisesRegex(ValueError, 'invalid'):
            self.apply()
        self.run.assert_not_called()

    def test_invalid_changes_do_not_write(self):
        for section, values in [('touchpad', {'tap': 'yes'}), ('touchpad', {'sensitivity': float('nan')}),
                                ('touchpad', {'sensitivity': 2}), ('touchpad', {'naturalScroll': 1}),
                                ('keyboard', {'layouts': []}), ('keyboard', {'layouts': [{'layout': 'bad";code()'}]}),
                                ('keyboard', {'layouts': [{'layout': 'us', 'variant': 'missing'}]}),
                                ('keyboard', {'shortcut': 'exec:bad'})]:
            with self.subTest(values=values), self.assertRaises(ValueError):
                self.apply(section, values)
        self.assertFalse(self.service.path.exists())
        self.run.assert_not_called()

    def test_switch_uses_fixed_argument_array_without_saving(self):
        self.service.dispatch({'action': 'switch', 'layout': '$(false)'})
        self.run.assert_called_once_with(['hyprctl', 'switchxkblayout', 'all', 'next'])
        self.assertFalse(self.service.path.exists())

    def test_snapshot_accepts_current_and_legacy_hyprland_boolean_responses(self):
        # Current Boolean response shape captured from the Fedora 44 live
        # desktop. The other documented response fields remain unchanged.
        for field, tap, natural in [('bool', False, True), ('int', 0, 1)]:
            with self.subTest(field=field):
                replies = {
                    'input:kb_layout': {'str': 'us,nl', 'set': True},
                    'input:kb_variant': {'str': 'intl,', 'set': True},
                    'input:kb_options': {'str': 'compose:caps,grp:alt_shift_toggle', 'set': True},
                    'input:touchpad:tap_to_click': {field: tap, 'set': True},
                    'input:touchpad:natural_scroll': {field: natural, 'set': True},
                    'input:sensitivity': {'float': 0.0, 'set': False},
                    'devices': {'keyboards': [{'name': 'keyboard', 'active_keymap': 'English (US)', 'main': True}]},
                }
                self.run.side_effect = lambda command: json.dumps(replies[command[-1]])
                result = self.service.dispatch({'action': 'snapshot'})
                self.assertEqual(result['touchpad'], {'tap': False, 'naturalScroll': True, 'sensitivity': 0.0})
                self.assertEqual(result['keyboard']['layouts'], [
                    {'layout': 'us', 'variant': 'intl'}, {'layout': 'nl', 'variant': ''}])
                self.assertEqual(result['keyboard']['shortcut'], 'grp:alt_shift_toggle')
                self.assertEqual(result['keyboard']['active'][0]['layout'], 'English (US)')
                self.assertFalse(self.service.path.exists(), 'reading input must not create preferences')

    def test_malformed_boolean_options_do_not_become_enabled_switches(self):
        for reply in ({'bool': 'false'}, {'int': '0'}, {'int': 2}, {'int': False},
                      {'bool': None, 'int': 0}, {}, []):
            with self.subTest(reply=reply), self.assertRaisesRegex(ValueError, 'input configuration'):
                self.run.return_value = json.dumps(reply)
                self.service.option('touchpad:tap_to_click', 'bool')

    def test_catalog_reads_variants_from_xkb_data(self):
        path = Path(self.temp.name) / 'evdev.xml'
        path.write_text('<xkbConfigRegistry><layoutList><layout><configItem><name>us</name><description>English</description></configItem>'
                        '<variantList><variant><configItem><name>intl</name><description>International</description></configItem></variant></variantList>'
                        '</layout></layoutList></xkbConfigRegistry>')
        # This test intentionally bypasses the action tests' catalog mock.
        patch.stopall()
        result = inputs.catalog(path)
        self.assertEqual(result[0]['variants'][1], {'value': 'intl', 'label': 'International'})

    def test_real_stdin_protocol_handles_subprocess_failure(self):
        binary = Path(self.temp.name) / 'hyprctl'
        binary.write_text('#!/bin/sh\nexit 7\n')
        binary.chmod(0o755)
        result = subprocess.run([sys.executable, '-B', str(SCRIPTS / 'system-settings.py'), 'input'],
                                input='{"action":"switch"}\n', capture_output=True, text=True,
                                env={**os.environ, 'PATH': str(binary.parent), 'XDG_CONFIG_HOME': self.temp.name}, timeout=10)
        self.assertEqual(result.returncode, 0)
        self.assertFalse(json.loads(result.stdout)['success'])
        self.assertEqual(result.stderr, '')


class RegionTransactions(unittest.TestCase):
    def setUp(self):
        self.service = object.__new__(region.RegionSettings)
        self.service.call = Mock()
        self.timezone = 'Europe/Amsterdam'
        self.locale = ['LANG=en_US.UTF-8', 'LC_TIME=nl_NL.UTF-8', 'LC_NUMERIC=C']
        self.service.properties = Mock(side_effect=lambda service: {'Timezone': self.timezone} if service == region.TIME else {'Locale': self.locale.copy()})
        patch.object(region, 'choices', side_effect=lambda command: ['Europe/Amsterdam', 'UTC'] if command[0] == 'timedatectl' else ['en_US.UTF-8', 'nl_NL.UTF-8']).start()
        self.addCleanup(patch.stopall)

    def test_locale_keeps_explicit_categories_and_requests_authorization(self):
        previous = self.locale.copy()
        def apply(*args, **kwargs):
            self.locale = args[4][0]
        self.service.call.side_effect = apply
        result = self.service.dispatch({'action': 'locale', 'value': 'nl_NL.UTF-8', 'previous': previous})
        self.assertIn('LC_TIME=nl_NL.UTF-8', self.locale)
        self.assertIn('LC_NUMERIC=C', self.locale)
        self.assertIn('LANG=nl_NL.UTF-8', self.locale)
        self.assertNotIn('LANG=en_US.UTF-8', self.locale)
        self.assertEqual(self.service.call.call_args.args[3], '(asb)')
        self.assertTrue(self.service.call.call_args.args[4][1])
        self.assertTrue(self.service.call.call_args.kwargs['interactive'])
        self.assertIn('Sign out', result['message'])

    def test_timezone_verifies_after_authorized_write(self):
        self.service.call.side_effect = lambda *args, **kwargs: setattr(self, 'timezone', args[4][0])
        self.service.dispatch({'action': 'timezone', 'value': 'UTC', 'previous': self.timezone})
        self.assertEqual(self.timezone, 'UTC')
        self.assertEqual(self.service.call.call_args.args[3:], ('(sb)', ('UTC', True)))

    def test_denied_write_reports_failure_without_success(self):
        self.service.call.side_effect = ValueError('Authorization was cancelled or denied')
        with self.assertRaisesRegex(ValueError, 'denied'):
            self.service.dispatch({'action': 'timezone', 'value': 'UTC', 'previous': self.timezone})
        self.assertEqual(self.timezone, 'Europe/Amsterdam')

    def test_stale_and_uninstalled_choices_never_mutate(self):
        for request in [{'action': 'timezone', 'value': 'UTC', 'previous': 'stale'},
                        {'action': 'locale', 'value': 'nl_NL.UTF-8', 'previous': ['LANG=changed']},
                        {'action': 'locale', 'value': 'missing', 'previous': self.locale},
                        {'action': 'timezone', 'value': '../etc/passwd', 'previous': self.timezone}]:
            with self.subTest(request=request), self.assertRaises(ValueError):
                self.service.dispatch(request)
        self.service.call.assert_not_called()

    def test_noop_service_is_not_reported_as_success(self):
        with self.assertRaisesRegex(ValueError, 'not retained'):
            self.service.dispatch({'action': 'timezone', 'value': 'UTC', 'previous': self.timezone})


if __name__ == '__main__':
    unittest.main()
