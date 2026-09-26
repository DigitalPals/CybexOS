"""The release orchestrator fails closed before publishing or starting VM tests."""
import importlib.machinery
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import MagicMock, patch

import browser_qualification

loader = importlib.machinery.SourceFileLoader('release_gate', str(Path(__file__).with_name('release-gate')))
spec = importlib.util.spec_from_loader(loader.name, loader)
gate = importlib.util.module_from_spec(spec)
loader.exec_module(gate)


class ReleaseGate(unittest.TestCase):
    def fixture(self, root, same_iso=False):
        checkout = root / 'source'
        checkout.mkdir()
        (checkout / 'VERSION').write_text('1.2.3\n')
        pxe = root / 'pxe'
        (pxe / 'iso').mkdir(parents=True)
        (pxe / 'README.md').write_text('fixture PXE host')
        baseline = pxe / 'iso/baseline.iso'
        baseline.write_bytes(b'candidate' if same_iso else b'prior ISO')
        output = root / 'output'
        commands = []
        def paths(value):
            value = str(value)
            return pxe / value[len('/data/pxe/'):] if value.startswith('/data/pxe/') else Path(value)
        def run(command):
            commands.append(command)
            if command[0].endswith('/image/build'):
                artifacts = output / 'build/artifacts'
                artifacts.mkdir(parents=True)
                (artifacts / 'candidate.iso').write_bytes(b'candidate')
                (artifacts / 'cybexos-desktop-1.2.3.rpm').write_bytes(b'RPM')
            if command[0].endswith('/image/publish-pxe'):
                (pxe / 'iso/candidate.iso').write_bytes(b'candidate')
        return checkout, baseline, output, paths, run, commands

    def invoke(self, root, same_iso=False):
        checkout, baseline, output, paths, run, commands = self.fixture(root, same_iso)
        with patch.object(gate, 'ROOT', checkout), patch.object(gate, 'Path', side_effect=paths), \
             patch.object(gate, 'require_test_iso', side_effect=lambda path: path), \
             patch.object(gate.subprocess, 'run'), patch.object(gate, 'browser_dependencies'), \
             patch.object(gate, 'run_child', side_effect=run), patch.object(gate.signal, 'signal'), \
             patch('sys.argv', ['release-gate', '--output', str(output), '--baseline-iso', str(baseline),
                                '--tag', 'v1.2.3', '--execute']):
            if same_iso:
                with self.assertRaisesRegex(RuntimeError, 'different prior ISO'):
                    gate.main()
            else:
                gate.main()
        return output, commands

    def test_same_iso_is_rejected_before_pxe_publication_and_vm_creation(self):
        with tempfile.TemporaryDirectory() as temporary:
            output, commands = self.invoke(Path(temporary), same_iso=True)
            self.assertEqual(len(commands), 1)
            self.assertFalse((output / 'build').exists())
            self.assertEqual(json.loads((output / 'release-gate.json').read_text())['status'], 'failed')

    def test_required_matrix_and_prior_rpm_upgrade_recovery_are_invoked(self):
        with tempfile.TemporaryDirectory() as temporary:
            output, commands = self.invoke(Path(temporary))
            qualifications = [command for command in commands if command[0].endswith('/image/qualify')]
            self.assertEqual(len(qualifications), 5)
            self.assertEqual([command[command.index('--scenario') + 1] for command in qualifications[:4]],
                             ['encrypted-us', 'plain-us', 'encrypted-nl', 'plain-nl'])
            upgrade = qualifications[-1]
            self.assertTrue(upgrade[1].endswith('/baseline.iso'))
            self.assertIn('--candidate-rpm', upgrade)
            self.assertIn('--recovery-check', upgrade)
            self.assertIn('--legacy-installer', upgrade)
            self.assertEqual(json.loads((output / 'release-gate.json').read_text())['status'], 'passed')

    def test_interruption_terminates_owned_process_group_before_returning(self):
        process = MagicMock()
        process.pid = 43210
        process.poll.return_value = None
        process.wait.side_effect = [KeyboardInterrupt(), 0]
        process.__enter__.return_value = process
        with patch.object(gate.subprocess, 'Popen', return_value=process) as spawn, \
             patch.object(gate.os, 'killpg') as stop:
            with self.assertRaises(KeyboardInterrupt):
                gate.run_child(['fixture-child'])
        spawn.assert_called_once_with(['fixture-child'], start_new_session=True)
        stop.assert_called_once_with(process.pid, gate.signal.SIGTERM)
        self.assertEqual(process.wait.call_args_list[-1].kwargs, {'timeout': 30})

    def test_unresponsive_owned_group_is_killed_and_reaped(self):
        process = MagicMock()
        process.pid = 43210
        process.poll.return_value = None
        process.wait.side_effect = [KeyboardInterrupt(), subprocess.TimeoutExpired('fixture', 30), 0]
        process.__enter__.return_value = process
        with patch.object(gate.subprocess, 'Popen', return_value=process), patch.object(gate.os, 'killpg') as stop:
            with self.assertRaises(KeyboardInterrupt):
                gate.run_child(['fixture-child'])
        self.assertEqual([call.args[1] for call in stop.call_args_list], [gate.signal.SIGTERM, gate.signal.SIGKILL])
        self.assertEqual(process.wait.call_count, 3)

    def test_browser_preflight_checks_supported_node_and_driver_before_build(self):
        with patch.dict(browser_qualification.os.environ, {'CYBEXOS_BROWSER': '/fixture/browser'}), \
             patch.object(browser_qualification.shutil, 'which', return_value=None), \
             patch.object(browser_qualification.os, 'access', return_value=True), \
             patch.object(browser_qualification.subprocess, 'run', return_value=SimpleNamespace(returncode=1)) as run:
            with self.assertRaisesRegex(RuntimeError, 'Node.js >=20'):
                browser_qualification.browser_dependencies()
            source = run.call_args.args[0][-1]
            self.assertIn('process.versions.node', source)
            self.assertIn('require("playwright-core")', source)


if __name__ == '__main__':
    unittest.main()
