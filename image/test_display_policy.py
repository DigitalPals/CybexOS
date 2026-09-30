"""Execute the shared XPS display tasks against disposable EDIDs and kernels."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml

from provision_payload import prepare_provision


ROOT = Path(__file__).resolve().parents[1]
GRUBBY = '''#!/usr/bin/python3
import json, os, sys
from pathlib import Path
root = Path(os.environ['DISPLAY_FIXTURE'])
state = root / 'kernels.json'
entries = json.loads(state.read_text())
with (root / 'grubby.jsonl').open('a') as log:
    log.write(json.dumps(sys.argv[1:]) + '\\n')
if sys.argv[1:] == ['--info=ALL']:
    for entry in entries:
        print('args="' + entry + '"')
elif sys.argv[1:] == ['--update-kernel=ALL', '--args=xe.enable_psr=0']:
    if os.environ.get('DISPLAY_IGNORE_UPDATE') != '1':
        entries = [' '.join([arg for arg in entry.split()
                            if not arg.startswith('xe.enable_psr=')] + ['xe.enable_psr=0'])
                   for entry in entries]
        state.write_text(json.dumps(entries))
else:
    raise SystemExit('unexpected grubby invocation: ' + repr(sys.argv))
'''


class PanelRefreshParity(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='cybex-panel-refresh.')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        payload = self.root / 'payload'
        prepare_provision(ROOT, payload)
        self.sources = (ROOT, payload / 'usr/share/cybexos/provision')
        for relative in ('roles/xps-2026/tasks/main.yml', 'roles/xps-2026/tasks/display.yml',
                         'roles/xps-2026/defaults/main.yml'):
            self.assertEqual((self.sources[0] / relative).read_bytes(),
                             (self.sources[1] / relative).read_bytes())

    def fixture(self, source, *, supported=True, sku='0DB9', edid='30e4c607', opt_out=False):
        root = Path(tempfile.mkdtemp(dir=self.root))
        binaries = root / 'bin'
        binaries.mkdir()
        binary = binaries / 'grubby'
        binary.write_text(GRUBBY)
        binary.chmod(0o755)
        panel = root / 'drm/card0-eDP-1/edid'
        panel.parent.mkdir(parents=True)
        if edid is not None:
            panel.write_bytes(b'\x00\xff\xff\xff\xff\xff\xff\x00' + bytes.fromhex(edid) + bytes(116))
        entries = ['root=UUID=fixture quiet xe.enable_psr=0',
                   'root=UUID=fixture quiet video=DP-2:d xe.enable_dpcd_backlight=1']
        (root / 'kernels.json').write_text(json.dumps(entries))
        # Substitute only the sysfs root. Run the actual probe, guard and
        # convergence tasks; no host EDID, boot entry or privilege is used.
        display = root / 'display.yml'
        display.write_text((source / 'roles/xps-2026/tasks/display.yml').read_text()
                           .replace('/sys/class/drm/', str(root / 'drm') + '/'))
        main = yaml.safe_load((source / 'roles/xps-2026/tasks/main.yml').read_text())
        gate = dict(next(task for task in main if task.get('ansible.builtin.import_tasks') == 'display.yml'))
        gate['ansible.builtin.import_tasks'] = str(display)
        variables = yaml.safe_load((source / 'roles/xps-2026/defaults/main.yml').read_text())
        variables.update(xps_2026_is_supported=supported, xps_2026_product_sku=sku)
        if opt_out:
            variables['xps_2026_psr_disabled_panels'] = []
        playbook = root / 'playbook.yml'
        playbook.write_text(yaml.safe_dump([{
            'hosts': 'localhost', 'connection': 'local', 'gather_facts': False, 'become': False,
            'vars': variables, 'tasks': [gate],
            'environment': {'PATH': str(binaries) + ':/usr/bin:/bin', 'DISPLAY_FIXTURE': str(root),
                            'DISPLAY_IGNORE_UPDATE': "{{ fixture_ignore_update | default('0') }}"},
        }]))
        return root, entries

    def run_play(self, root, *arguments, succeeds=True):
        result = subprocess.run(['ansible-playbook', '-i', 'localhost,', str(root / 'playbook.yml'),
                                 *arguments], text=True, capture_output=True, timeout=30,
                                env={**os.environ, 'ANSIBLE_STDOUT_CALLBACK': 'default',
                                     'ANSIBLE_NOCOLOR': '1', 'ANSIBLE_FORCE_COLOR': '0'})
        self.assertEqual(result.returncode == 0, succeeds, result.stdout + result.stderr)

    def test_both_paths_preserve_arguments_and_update_all_kernels_once(self):
        outcomes = []
        for source in self.sources:
            with self.subTest(source=source):
                root, before = self.fixture(source)
                self.run_play(root, '--check')
                self.assertEqual(json.loads((root / 'kernels.json').read_text()), before)
                self.run_play(root)
                self.run_play(root)
                after = json.loads((root / 'kernels.json').read_text())
                self.assertEqual(after, [before[0], before[1] + ' xe.enable_psr=0'])
                calls = [json.loads(line) for line in (root / 'grubby.jsonl').read_text().splitlines()]
                self.assertEqual(sum('--update-kernel=ALL' in call for call in calls), 1)
                outcomes.append(after)
        self.assertEqual(outcomes[0], outcomes[1])

    def test_other_panels_machines_missing_edid_and_saved_opt_out_are_untouched(self):
        cases = ({'edid': '30e4c707'}, {'edid': '1234c607'}, {'edid': None},
                 {'sku': '0DBA'}, {'supported': False}, {'opt_out': True})
        for source in self.sources:
            for case in cases:
                with self.subTest(source=source, case=case):
                    root, before = self.fixture(source, **case)
                    self.run_play(root)
                    self.assertEqual(json.loads((root / 'kernels.json').read_text()), before)
                    self.assertFalse((root / 'grubby.jsonl').exists())

    def test_silent_boot_entry_update_failure_is_reported_on_both_paths(self):
        for source in self.sources:
            with self.subTest(source=source):
                root, before = self.fixture(source)
                self.run_play(root, '-e', 'fixture_ignore_update=1', succeeds=False)
                self.assertEqual(json.loads((root / 'kernels.json').read_text()), before)


if __name__ == '__main__':
    unittest.main()
