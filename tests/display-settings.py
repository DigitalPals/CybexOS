#!/usr/bin/env python3
"""Settings -> Displays helper contracts, with fake hyprctl/systemd; no host changes."""
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'roles/desktop/files/quickshell/scripts/display-settings.py'
FIXTURES = ROOT / 'tests/displays'

loader = importlib.machinery.SourceFileLoader('display_settings', str(SCRIPT))
spec = importlib.util.spec_from_loader('display_settings', loader)
helper = importlib.util.module_from_spec(spec)
loader.exec_module(helper)

FAKE_HYPRCTL = r'''#!/usr/bin/env python3
import json, os, sys
log = os.environ['FAKE_LOG']
with open(log, 'a') as handle:
    handle.write(json.dumps(['hyprctl', *sys.argv[1:]]) + '\n')
args = sys.argv[1:]
if args[:3] == ['-j', 'monitors', 'all']:
    print(open(os.environ['FAKE_MONITORS']).read())
elif args[:1] == ['eval']:
    print(os.environ.get('FAKE_EVAL', 'ok'))
elif args[:1] == ['reload']:
    print(os.environ.get('FAKE_RELOAD', 'ok'))
else:
    sys.exit(3)
'''

FAKE_SYSTEMD = r'''#!/usr/bin/env python3
import json, os, sys
with open(os.environ['FAKE_LOG'], 'a') as handle:
    handle.write(json.dumps([os.path.basename(sys.argv[0]), *sys.argv[1:]]) + '\n')
sys.exit(int(os.environ.get('FAKE_ARM_STATUS', '0')) if sys.argv[0].endswith('systemd-run') else 0)
'''


def document(scale=1.5):
    return {'v': 1, 'monitors': {'desc:Example Monitors Inc. UHD32 SERIAL0001': {
        'description': 'Example Monitors Inc. UHD32 SERIAL0001', 'connector': 'DP-1', 'enabled': True,
        'mode': {'width': 3840, 'height': 2160, 'refresh': 120}, 'position': {'x': 0, 'y': 0},
        'scale': scale, 'transform': 0}}}


class SharedFixtures(unittest.TestCase):
    def test_python_and_lua_agree_on_every_document(self):
        for case in json.loads((FIXTURES / 'documents.json').read_text()):
            with self.subTest(case['name']):
                try:
                    helper.validate_document(helper.loads(case['text']))
                    valid = True
                except ValueError:
                    valid = False
                self.assertEqual(valid, case['valid'])

    def test_lua_literals_are_inert_for_any_path(self):
        value = '/run/user/1000/cybexos/x"); os.execute("id") --\\ é\n.json'
        literal = helper.lua_string(value)
        self.assertRegex(literal, r'^"[A-Za-z0-9/_.\- \\]*"$')
        if shutil.which('luajit'):
            result = subprocess.run(['luajit', '-e', f'io.write({literal})'], capture_output=True, check=True)
            self.assertEqual(result.stdout, value.encode())


class HelperFlow(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix='cybexos-display-test.'))
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        (self.bin / 'hyprctl').write_text(FAKE_HYPRCTL)
        for name in ('systemd-run', 'systemctl'):
            (self.bin / name).write_text(FAKE_SYSTEMD)
        for path in self.bin.iterdir():
            path.chmod(0o755)
        self.log = self.root / 'log'
        self.log.write_text('')
        self.saved_env = dict(os.environ)
        (self.root / 'config').mkdir()
        (self.root / 'runtime').mkdir(mode=0o700)
        os.environ.update({
            'PATH': f'{self.bin}:{os.environ["PATH"]}',
            'XDG_CONFIG_HOME': str(self.root / 'config'),
            'XDG_RUNTIME_DIR': str(self.root / 'runtime'),
            'HYPRLAND_INSTANCE_SIGNATURE': 'test-instance',
            'FAKE_LOG': str(self.log),
            'FAKE_MONITORS': str(FIXTURES / 'monitors-docked.json'),
        })
        for name in ('FAKE_EVAL', 'FAKE_RELOAD', 'FAKE_ARM_STATUS'):
            os.environ.pop(name, None)
        self.store = self.root / 'config/cybexos/displays.json'

    def tearDown(self):
        os.environ.clear()
        os.environ.update(self.saved_env)
        shutil.rmtree(self.root)

    def calls(self, program=None):
        entries = [json.loads(line) for line in self.log.read_text().splitlines()]
        return [entry for entry in entries if program is None or entry[0] == program]

    def trial_files(self):
        return sorted(path.name for path in (self.root / 'runtime/cybexos').glob('displays-trial*.json'))

    def test_snapshot_reports_outputs_store_and_no_trial(self):
        result = helper.snapshot({})
        self.assertEqual([m['name'] for m in result['monitors']], ['eDP-1', 'DP-1'])
        self.assertEqual(result['store']['digest'], 'absent')
        self.assertIsNone(result['store']['document'])
        self.assertIsNone(result['trial'])

    def test_apply_arms_restore_before_evaluating_and_confirm_saves(self):
        result = helper.apply({'action': 'apply', 'document': document(), 'baseDigest': 'absent'})
        token = result['checkpoint']
        self.assertEqual(self.trial_files(), ['displays-trial-state.json', 'displays-trial.json'])
        run, = self.calls('systemd-run')
        self.assertIn(f'--unit=cybexos-display-trial-{token}', run)
        self.assertIn(f'--on-active={helper.WATCHDOG_SECONDS}s', run)
        self.assertIn('--setenv=HYPRLAND_INSTANCE_SIGNATURE=test-instance', run)
        self.assertEqual(run[-2:], ['expire', token])
        order = [entry[0] if entry[0] != 'hyprctl' else entry[1] for entry in self.calls()]
        self.assertLess(order.index('systemd-run'), order.index('eval'), 'restore is armed first')
        evaluated = [entry for entry in self.calls('hyprctl') if entry[1] == 'eval'][0][2]
        self.assertTrue(evaluated.startswith('require("displays").apply_trial("'))
        self.assertFalse(self.store.exists(), 'a trial never touches the saved file')

        with self.assertRaisesRegex(ValueError, 'Keep or revert'):
            helper.apply({'action': 'apply', 'document': document(2), 'baseDigest': 'absent'})
        with self.assertRaisesRegex(ValueError, 'already ended'):
            helper.confirm({'checkpoint': '0' * 16})

        helper.confirm({'checkpoint': token})
        self.assertEqual(json.loads(self.store.read_text()), document())
        self.assertEqual(self.store.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.trial_files(), [])
        stops = [entry for entry in self.calls('systemctl') if entry[-1].startswith('cybexos-display-trial-')]
        self.assertEqual({entry[-1] for entry in stops},
                         {f'cybexos-display-trial-{token}.timer', f'cybexos-display-trial-{token}.service'})
        self.assertFalse([entry for entry in self.calls('hyprctl') if entry[1] == 'reload'])

    def test_rollback_and_expiry_reload_from_disk(self):
        token = helper.apply({'document': document(), 'baseDigest': 'absent'})['checkpoint']
        helper.rollback({'checkpoint': token})
        self.assertEqual(self.trial_files(), [])
        self.assertEqual(len([e for e in self.calls('hyprctl') if e[1] == 'reload']), 1)
        self.assertFalse(self.store.exists())
        self.assertEqual(helper.rollback({'checkpoint': token})['message'],
                         'The previous display settings are in effect.')

        token = helper.apply({'document': document(), 'baseDigest': 'absent'})['checkpoint']
        self.assertEqual(helper.expire('f' * 16), 0)
        self.assertEqual(len([e for e in self.calls('hyprctl') if e[1] == 'reload']), 1, 'other token ignored')
        self.assertEqual(helper.expire(token), 0)
        self.assertEqual(len([e for e in self.calls('hyprctl') if e[1] == 'reload']), 2)
        self.assertEqual(self.trial_files(), [])
        with self.assertRaisesRegex(ValueError, 'already ended'):
            helper.confirm({'checkpoint': token})

    def test_rejected_rules_and_unarmed_restore_change_nothing(self):
        os.environ['FAKE_ARM_STATUS'] = '1'
        with self.assertRaisesRegex(ValueError, 'could not be scheduled'):
            helper.apply({'document': document(), 'baseDigest': 'absent'})
        self.assertFalse([e for e in self.calls('hyprctl') if e[1] == 'eval'])
        self.assertEqual(self.trial_files(), [])

        os.environ['FAKE_ARM_STATUS'] = '0'
        os.environ['FAKE_EVAL'] = 'error: hl.monitor: field \'mode\': invalid resolution'
        with self.assertRaisesRegex(ValueError, 'Hyprland rejected the display settings: error: hl.monitor'):
            helper.apply({'document': document(), 'baseDigest': 'absent'})
        self.assertEqual(self.trial_files(), [])
        self.assertTrue([e for e in self.calls('hyprctl') if e[1] == 'reload'])
        self.assertTrue([e for e in self.calls('systemctl') if e[-1].endswith('.timer')])

        with self.assertRaisesRegex(ValueError, 'unsupported version'):
            helper.apply({'document': {'v': 2}, 'baseDigest': 'absent'})

    def test_a_late_keep_is_refused_and_restores(self):
        token = helper.apply({'document': document(), 'baseDigest': 'absent'})['checkpoint']
        state_path = self.root / 'runtime/cybexos/displays-trial-state.json'
        state = json.loads(state_path.read_text())
        state['expires'] -= helper.TRIAL_SECONDS + helper.CONFIRM_GRACE_SECONDS + 1
        state_path.write_text(json.dumps(state))
        with self.assertRaisesRegex(ValueError, 'expired'):
            helper.confirm({'checkpoint': token})
        self.assertFalse(self.store.exists())
        self.assertEqual(self.trial_files(), [])
        self.assertTrue([e for e in self.calls('hyprctl') if e[1] == 'reload'])

    def test_concurrent_edits_are_refused(self):
        self.store.parent.mkdir(parents=True)
        self.store.write_text(json.dumps(document(2)))
        digest = helper.read_store()['digest']
        with self.assertRaisesRegex(ValueError, 'changed elsewhere'):
            helper.apply({'document': document(), 'baseDigest': 'absent'})
        token = helper.apply({'document': document(), 'baseDigest': digest})['checkpoint']
        self.store.write_text(json.dumps(document(1.25)))
        with self.assertRaisesRegex(ValueError, 'changed elsewhere'):
            helper.confirm({'checkpoint': token})
        self.assertEqual(json.loads(self.store.read_text()), document(1.25), 'the other edit wins')
        self.assertEqual(self.trial_files(), [])

    def test_unsafe_or_invalid_saved_files_are_reported_not_used(self):
        self.store.parent.mkdir(parents=True)
        self.store.write_text('{"v": 1, "monitors": {"eDP-1": {"scale": 0.01}}}')
        store = helper.read_store()
        self.assertIsNone(store['document'])
        self.assertIn('invalid scale', store['error'])
        self.store.unlink()
        target = self.root / 'elsewhere.json'
        target.write_text(json.dumps(document()))
        self.store.symlink_to(target)
        self.assertIn('not a regular file', helper.read_store()['error'])
        with self.assertRaisesRegex(ValueError, 'not a regular file'):
            helper.atomic_write(self.store, b'{}')
        self.assertEqual(json.loads(target.read_text()), document(), 'a symlink target is never written')

    def test_process_interface_is_bounded_json(self):
        def call(payload):
            result = subprocess.run([sys.executable, '-B', str(SCRIPT)], input=payload, capture_output=True,
                                    text=True, timeout=30, env=os.environ, check=True)
            return json.loads(result.stdout)
        self.assertTrue(call('{"action":"snapshot"}\n')['success'])
        self.assertEqual(call('{"action":"format-disk"}\n'), {'success': False, 'error': 'Unknown display request.'})
        self.assertFalse(call('not json\n')['success'])
        self.assertFalse(call(json.dumps({'action': 'apply', 'document': {'v': 1, 'monitors': {'DP 1': {}}}}) + '\n')['success'])


if __name__ == '__main__':
    unittest.main(verbosity=1)
