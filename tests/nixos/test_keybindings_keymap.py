"""Keycode -> level-1 keysym map for the shortcut recorder; fixtures are real xkbcli output."""
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
keymap = importlib.import_module('system_settings_keymap')
FIXTURES = ROOT / 'tests/fixtures/keybindings'


def fixture(name):
    return (FIXTURES / ('keymap-%s.xkb' % name)).read_text()


class KeymapParser(unittest.TestCase):
    def test_us_layout_maps_each_keycode_to_its_unshifted_symbol(self):
        group = keymap.parse(fixture('us'))['groups'][0]
        self.assertEqual({code: group[code] for code in ('10', '11', '19', '20', '21', '24', '49', '59', '60', '61', '65')},
                         {'10': '1', '11': '2', '19': '0', '20': 'minus', '21': 'equal', '24': 'q', '49': 'grave',
                          '59': 'comma', '60': 'period', '61': 'slash', '65': 'space'})
        self.assertEqual(group['9'], 'Escape')
        self.assertEqual(group['67'], 'F1')

    def test_azerty_layout_puts_punctuation_on_the_number_row(self):
        group = keymap.parse(fixture('fr'))['groups'][0]
        self.assertEqual({code: group[code] for code in ('10', '11', '12', '13', '20', '24', '26', '49', '61')},
                         {'10': 'ampersand', '11': 'eacute', '12': 'quotedbl', '13': 'apostrophe', '20': 'parenright',
                          '24': 'a', '26': 'e', '49': 'twosuperior', '61': 'exclam'})

    def test_every_group_is_parsed_and_picked_by_the_active_keymap_name(self):
        parsed = keymap.parse(fixture('us-fr'))
        self.assertEqual(parsed['names'], ['English (US)', 'French (AZERTY)'])
        self.assertEqual(keymap.select(parsed, 'English (US)')['10'], '1')
        self.assertEqual(keymap.select(parsed, 'French (AZERTY)')['10'], 'ampersand')
        self.assertEqual(keymap.select(parsed, 'Unknown layout')['10'], '1')
        self.assertEqual(keymap.select(parsed, '')['10'], '1')
        # The compact one-group form repeats for the later groups.
        self.assertEqual(parsed['groups'][1]['9'], 'Escape')

    def test_long_forms_with_types_actions_groups_and_nosymbol(self):
        text = """xkb_keymap {
xkb_keycodes "x" {
	<AE01> = 10;
	<AD01> = 24;
	<KPMU> = 63;
	<FK01> = 67;
	<LFSH> = 50;
	<MENU> = 135;
	<AB01> = 52;
	alias <ZALIAS> = <AB01>;
};
xkb_symbols "s" {
	name[Group1]="One";
	name[Group2]="Two";
	key <AE01>               {
		type[Group1]= "TWO_LEVEL",
		symbols[Group1]= [               1,          exclam ],
		symbols[Group2]= [       ampersand,               1 ]
	};
	key <AD01> { [ q, Q ] };
	key <KPMU> {
		type= "CTRL+ALT",
		symbols[1]= [     KP_Multiply,     KP_Multiply,     KP_Multiply,     KP_Multiply,   XF86ClearGrab ],
		actions[1]= [ NoAction(), NoAction() ]
	};
	key <FK01> {
		repeat= No,
		symbols[1]= [ NoSymbol ]
	};
	key <LFSH> { [ { Shift_L, Caps_Lock } ] };
	key <MENU> { symbols[2]= [ Menu ] };
	key <UNKNOWN> { [ x ] };
	key <ZALIAS> { [ z, Z ] };
};
};
"""
        parsed = keymap.parse(text)
        self.assertEqual(parsed['names'], ['One', 'Two'])
        one, two = parsed['groups']
        self.assertEqual(one['10'], '1')
        self.assertEqual(two['10'], 'ampersand')
        self.assertEqual((one['24'], two['24']), ('q', 'q'))
        self.assertEqual((one['63'], two['63']), ('KP_Multiply', 'KP_Multiply'))
        self.assertNotIn('67', one)
        self.assertEqual(one['50'], 'Shift_L')
        self.assertNotIn('135', one)
        self.assertEqual(two['135'], 'Menu')
        self.assertEqual(one['52'], 'z')
        self.assertNotIn('999', one)

    def test_garbage_and_oversized_input_is_rejected(self):
        for text in ('', 'nothing here', 'xkb_keymap {\n};', None, 'x' * (keymap.MAX_KEYMAP + 1)):
            with self.subTest(text=str(text)[:20]), self.assertRaises(ValueError):
                keymap.parse(text)


class KeymapLookup(unittest.TestCase):
    def setUp(self):
        keymap._memo.clear()
        self.addCleanup(keymap._memo.clear)
        self.temporary = tempfile.TemporaryDirectory(prefix='cybexos-keymap-')
        self.addCleanup(self.temporary.cleanup)
        patcher = patch.dict(os.environ, {'XDG_RUNTIME_DIR': self.temporary.name})
        patcher.start()
        self.addCleanup(patcher.stop)
        self.calls = []

    def compiler(self, outputs):
        def fake(command, **kwargs):
            self.calls.append(command)
            name = outputs.get(command[command.index('--layout') + 1], 'us')
            return subprocess.CompletedProcess(command, 0, fixture(name).encode(), b'')
        return fake

    def lookup(self, layout='us', variant='', options='', **extra):
        with patch.object(keymap.shutil, 'which', return_value='/bin/xkbcli'), \
                patch.object(keymap.subprocess, 'run', self.compiler({'us': 'us', 'fr': 'fr', 'us,fr': 'us-fr'})):
            return keymap.compile_keymap(layout, variant, options, **extra)

    def test_compiles_once_per_layout_in_memory_and_on_disk(self):
        first = self.lookup('fr')
        self.assertEqual(first['groups'][0]['10'], 'ampersand')
        self.assertEqual(len(self.calls), 1)
        self.assertEqual(self.calls[0], ['/bin/xkbcli', 'compile-keymap', '--layout', 'fr'])
        self.lookup('fr')
        self.assertEqual(len(self.calls), 1)
        keymap._memo.clear()
        self.assertEqual(self.lookup('fr'), first)
        self.assertEqual(len(self.calls), 1)
        self.assertEqual(len(list(Path(self.temporary.name, 'cybexos').glob('keymap-*.json'))), 1)
        self.lookup('us')
        self.assertEqual(len(self.calls), 2)

    def test_options_variant_rules_and_model_reach_the_tool_as_separate_arguments(self):
        self.lookup('us,fr', ',azerty', 'grp:alt_shift_toggle', rules='evdev', model='pc105')
        self.assertEqual(self.calls[0], ['/bin/xkbcli', 'compile-keymap', '--rules', 'evdev', '--model', 'pc105',
                                         '--layout', 'us,fr', '--variant', ',azerty', '--options', 'grp:alt_shift_toggle'])

    def test_unsafe_arguments_never_reach_the_tool(self):
        for layout, options in (('us; touch x', ''), ('us', '$(id)'), ('us', 'a' * 257), ('us', 'x y'), ('-x', ''), ('us', '--version')):
            with self.subTest(layout=layout):
                self.assertIsNone(self.lookup(layout, '', options))
        self.assertEqual(self.calls, [])

    def test_disk_cache_is_bounded_and_a_corrupt_file_is_recompiled(self):
        directory = Path(self.temporary.name, 'cybexos')
        for index in range(keymap.CACHE_FILES + 4):
            self.lookup('us', '', 'ctrl:option%d' % index)
        files = list(directory.glob('keymap-*.json'))
        self.assertEqual(len(files), keymap.CACHE_FILES)
        self.assertEqual(list(directory.glob('.keymap-*')), [])
        keymap._memo.clear()
        newest = self.lookup('us', '', 'ctrl:option%d' % (keymap.CACHE_FILES + 3))
        count = len(self.calls)
        for path in directory.glob('keymap-*.json'):
            path.write_text('{"names":["x"],"groups":[{"10":"1; rm"}]}')
        keymap._memo.clear()
        self.assertEqual(self.lookup('us', '', 'ctrl:option%d' % (keymap.CACHE_FILES + 3)), newest)
        self.assertEqual(len(self.calls), count + 1)

    def test_memo_is_bounded(self):
        for index in range(keymap.CACHE_MEMO + 3):
            self.lookup('us', '', 'ctrl:option%d' % index)
        self.assertLessEqual(len(keymap._memo), keymap.CACHE_MEMO)

    def test_missing_tool_failure_garbage_and_oversize_fail_soft(self):
        with patch.object(keymap.shutil, 'which', return_value=None):
            self.assertIsNone(keymap.compile_keymap('us', '', ''))
        cases = (subprocess.CompletedProcess([], 1, b'', b'error'),
                 subprocess.CompletedProcess([], 0, b'garbage', b''),
                 subprocess.CompletedProcess([], 0, b'\xff\xfe', b''),
                 subprocess.CompletedProcess([], 0, b'x' * (keymap.MAX_KEYMAP + 1), b''))
        for result in cases:
            with self.subTest(result=result.stdout[:10]), patch.object(keymap.shutil, 'which', return_value='/bin/xkbcli'), \
                    patch.object(keymap.subprocess, 'run', return_value=result):
                self.assertIsNone(keymap.compile_keymap('us', '', ''))
        for error in (subprocess.TimeoutExpired('xkbcli', 5), OSError('gone')):
            with self.subTest(error=error), patch.object(keymap.shutil, 'which', return_value='/bin/xkbcli'), \
                    patch.object(keymap.subprocess, 'run', side_effect=error):
                self.assertIsNone(keymap.compile_keymap('us', '', ''))
        self.assertEqual(list(Path(self.temporary.name, 'cybexos').glob('keymap-*.json')), [])

    def test_works_without_a_runtime_directory(self):
        with patch.dict(os.environ, {}, clear=False):
            os.environ.pop('XDG_RUNTIME_DIR')
            self.assertEqual(self.lookup('fr')['groups'][0]['10'], 'ampersand')
            self.lookup('fr')
            self.assertEqual(len(self.calls), 1)

    def hyprctl(self, keyboards, code=0):
        return subprocess.CompletedProcess([], code, json.dumps({'keyboards': keyboards}), '')

    def test_active_map_uses_the_main_keyboards_layout_and_active_group(self):
        keyboards = [{'main': False, 'layout': 'us'},
                     {'main': True, 'layout': 'us,fr', 'variant': ',azerty', 'options': 'grp:alt_shift_toggle',
                      'rules': 'evdev', 'model': 'pc105', 'active_keymap': 'French (AZERTY)'}]
        with patch.object(keymap.subprocess, 'run', return_value=self.hyprctl(keyboards)), \
                patch.object(keymap, 'compile_keymap', wraps=keymap.compile_keymap) as compile_keymap, \
                patch.object(keymap.shutil, 'which', return_value='/bin/xkbcli'):
            with patch.object(keymap.subprocess, 'run', side_effect=[self.hyprctl(keyboards),
                                                                      subprocess.CompletedProcess([], 0, fixture('us-fr').encode(), b'')]):
                result = keymap.active_map()
        self.assertEqual(result['10'], 'ampersand')
        compile_keymap.assert_called_once_with('us,fr', ',azerty', 'grp:alt_shift_toggle', 'evdev', 'pc105')

    def test_active_map_is_empty_when_anything_is_unavailable(self):
        for outcome in (self.hyprctl([], 0), self.hyprctl([{'main': True}], 1), OSError('no hyprctl'),
                        subprocess.CompletedProcess([], 0, 'not json', '')):
            with self.subTest(outcome=str(outcome)[:30]), patch.object(keymap.shutil, 'which', return_value=None):
                with patch.object(keymap.subprocess, 'run', **({'side_effect': outcome} if isinstance(outcome, Exception)
                                                               else {'return_value': outcome})):
                    self.assertEqual(keymap.active_map(), {})


if __name__ == '__main__':
    unittest.main()
