"""Installer diagnostics and Wi-Fi defaults without touching host networking."""
import importlib.util
import json
from pathlib import Path
import sys
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'lifecycle'))
from nerdos.common import CommandFailure, Failure
from nerdos.installer_network import diagnostics, ensure_internet

spec = importlib.util.spec_from_file_location('installer_network_tool', ROOT / 'desktop/quickshell/scripts/network-tool.py')
tool = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tool)


class ConnectivityTests(unittest.TestCase):
    def run_fixture(self, curl_code=0):
        calls = []
        def run(*args, **kwargs):
            calls.append((args, kwargs))
            if args[0] == 'tailscale':
                self.assertTrue(kwargs['sensitive'])
                return json.dumps({'BackendState': 'NeedsLogin', 'AuthURL': 'https://secret.example/auth'})
            if args[0] == 'curl' and curl_code:
                raise CommandFailure('curl', curl_code)
            return 'Global: 8.8.8.8 8.8.4.4\n' if args[0] == 'resolvectl' else ''
        return run, calls

    def test_success_verifies_https_and_records_upstreams_without_authentication_links(self):
        run, calls = self.run_fixture()
        notes, notify = [], Mock()
        ensure_internet(run, notify, notes.append)
        self.assertEqual(notify.call_args.args, ('Internet connection ready.',))
        curl, options = calls[-1]
        self.assertEqual(curl[0], 'curl')
        self.assertNotIn('--insecure', curl)
        self.assertIn('--max-time', curl)
        self.assertEqual(options['timeout'], 15)
        self.assertIn('8.8.8.8', '\n'.join(notes))
        self.assertIn('Tailscale backend state: NeedsLogin', notes)
        self.assertNotIn('secret.example', '\n'.join(notes))
        self.assertTrue(all(call[0][0] in ('curl', 'resolvectl', 'tailscale') for call in calls))

    def test_dns_failure_is_distinguished_and_never_changes_dns(self):
        run, calls = self.run_fixture(6)
        with self.assertRaisesRegex(Failure, 'DNS could not resolve.*No disk has been erased'):
            ensure_internet(run)
        self.assertEqual([call[0][0] for call in calls], ['resolvectl', 'resolvectl', 'tailscale', 'curl'])

    def test_other_network_failures_are_actionable_without_rewriting_settings(self):
        for code in (5, 7, 22, 28, 35, 60):
            run, calls = self.run_fixture(code)
            with self.subTest(code=code), self.assertRaisesRegex(Failure, 'proxy and system clock.*No disk has been erased'):
                ensure_internet(run)
            self.assertEqual(len(calls), 4)

    def test_diagnostics_are_best_effort_and_never_block_a_working_connection(self):
        def run(*args, **kwargs):
            if args[0] != 'curl':
                raise FileNotFoundError(args[0])
            return ''
        ensure_internet(run)
        def timeout(*args, **kwargs):
            raise Failure('bounded command timed out')
        with self.assertRaisesRegex(Failure, 'did not complete.*No disk has been erased'):
            ensure_internet(timeout)

    def test_malformed_tailscale_output_is_not_logged(self):
        for output in ('not json', '[]', '{"BackendState":"https://secret.example"}'):
            notes = []
            diagnostics(lambda *args, **kwargs: output if args[0] == 'tailscale' else '', notes.append)
            self.assertNotIn('secret.example', '\n'.join(notes))


class WifiDefaultsTests(unittest.TestCase):
    def profile(self, provider):
        return {'connectionType': '802-3-ethernet', 'standalone': True, 'ipv4Method': 'auto',
                **tool.provider_configuration(provider, '9.9.9.9')}

    def inherit(self, previous):
        with patch.object(tool, 'modify_dns') as modify:
            tool.inherit_dns_for_new_profile('new-wifi', previous)
        return modify

    def test_first_wifi_connection_defaults_to_google_for_both_address_families(self):
        settings = self.inherit([]).call_args.args[1]
        self.assertEqual(settings['ipv4Dns'], ['8.8.8.8', '8.8.4.4'])
        self.assertEqual(settings['ipv6Dns'], ['2001:4860:4860::8888', '2001:4860:4860::8844'])
        self.assertTrue(settings['ipv4IgnoreAutoDns'])
        self.assertTrue(settings['ipv6IgnoreAutoDns'])

    def test_existing_provider_including_explicit_automatic_is_inherited(self):
        for provider in ('Automatic', 'Cloudflare', 'Google', 'Custom'):
            with self.subTest(provider=provider):
                modify = self.inherit([self.profile(provider)])
                self.assertEqual(modify.call_args.args, ('new-wifi', tool.provider_configuration(provider, '9.9.9.9')))

    def test_hotspots_and_vpns_do_not_override_the_first_wifi_default(self):
        hotspot = {**self.profile('Automatic'), 'connectionType': '802-11-wireless', 'ipv4Method': 'shared'}
        vpn = {**self.profile('Automatic'), 'connectionType': 'wireguard'}
        self.assertEqual(self.inherit([hotspot, vpn]).call_args.args[1]['provider'], 'Google')

    def test_mixed_existing_dns_is_preserved(self):
        self.inherit([self.profile('Automatic'), self.profile('Custom')]).assert_not_called()
