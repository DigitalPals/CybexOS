"""SSH switch failure and authorization boundaries; real login is tested in NixOS."""
import importlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'lifecycle'))
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'desktop/quickshell/scripts'))
from cybexos import ssh_server
from cybexos.common import Failure, atomic
bridge = importlib.import_module('system_settings_ssh')


class SshServerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.state = Path(self.temp.name)
        self.config = self.state / 'config.json'
        atomic(self.config, {'available': True, 'user': 'tester', 'ports': [22]})
        self.marker = self.state / 'enabled'

    def run_service(self, args, **kwargs):
        if args[:2] == ['ip', '-j']:
            return subprocess.CompletedProcess(args, 0, json.dumps([{'addr_info': [
                {'scope': 'host', 'local': '127.0.0.1'},
                {'scope': 'global', 'local': '192.0.2.8'}]}]))
        return subprocess.CompletedProcess(args, 0, 'active\n' if self.marker.exists() else 'inactive\n')

    def test_off_by_default_and_enable_disable_round_trip(self):
        with patch.object(ssh_server.subprocess, 'run', side_effect=self.run_service), patch.object(os, 'geteuid', return_value=0):
            self.assertFalse(ssh_server.status(self.state, self.config)['enabled'])
            enabled = ssh_server.change('enable', self.state, self.config)
            self.assertTrue(enabled['enabled'] and enabled['active'])
            self.assertEqual(enabled['addresses'], ['192.0.2.8'])
            self.assertEqual(self.marker.stat().st_mode & 0o777, 0o644)
            self.assertTrue(ssh_server.status(self.state, self.config)['enabled'])
            self.assertFalse(ssh_server.change('disable', self.state, self.config)['enabled'])

    def test_failed_enable_restores_off_and_failed_disable_preserves_on(self):
        for action in ('enable', 'disable'):
            self.marker.unlink(missing_ok=True)
            if action == 'disable':
                self.marker.write_text('enabled\n')
            def fail(args, **kwargs):
                if args[1] == ('start' if action == 'enable' else 'stop'):
                    raise subprocess.CalledProcessError(1, args)
                return self.run_service(args, **kwargs)
            with patch.object(os, 'geteuid', return_value=0), patch.object(ssh_server.subprocess, 'run', side_effect=fail):
                with self.assertRaises(Failure):
                    ssh_server.change(action, self.state, self.config)
            self.assertEqual(self.marker.exists(), action == 'disable')

    def test_unprivileged_or_unknown_actions_never_change_state(self):
        with patch.object(os, 'geteuid', return_value=1000), patch.object(ssh_server.subprocess, 'run') as run:
            for action in ('enable', 'disable', 'restart arbitrary.service'):
                with self.assertRaises(Failure):
                    ssh_server.change(action, self.state, self.config)
            run.assert_not_called()
        self.assertFalse(self.marker.exists())

    def test_personally_disabled_service_stays_disabled(self):
        atomic(self.config, {'available': False})
        with patch.object(os, 'geteuid', return_value=0), patch.object(ssh_server.subprocess, 'run') as run:
            self.assertFalse(ssh_server.status(self.state, self.config)['available'])
            with self.assertRaises(Failure):
                ssh_server.change('enable', self.state, self.config)
            run.assert_not_called()
        self.assertFalse(self.marker.exists())

    def test_settings_requires_polkit_and_preserves_cancellation(self):
        service = bridge.SshSettings()
        with patch.object(bridge.subprocess, 'run', return_value=subprocess.CompletedProcess([], 126, '')) as run:
            with self.assertRaisesRegex(ValueError, 'cancelled or denied'):
                service.dispatch({'action': 'set-enabled', 'enabled': True})
            self.assertEqual(run.call_args.args[0], ['/run/wrappers/bin/pkexec', os.path.realpath(bridge.HELPER), 'enable'])
        with patch.object(bridge.subprocess, 'run') as run:
            for request in ({'action': 'set-enabled', 'enabled': 'true'},
                            {'action': 'set-enabled', 'enabled': True, 'unit': 'other.service'}):
                with self.assertRaises(ValueError):
                    service.dispatch(request)
            run.assert_not_called()
