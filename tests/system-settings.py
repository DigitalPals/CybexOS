#!/usr/bin/env python3
"""Settings service contracts, using fake devices/buses; no host mutations."""
import importlib
import json
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch, Mock

SCRIPTS = Path(__file__).resolve().parents[1] / 'roles/desktop/files/quickshell/scripts'
sys.path.insert(0, str(SCRIPTS))
audio = importlib.import_module("system_settings_audio")
network = importlib.import_module("system_settings_network")
accounts = importlib.import_module("system_settings_accounts")

# Without PyGObject, `gi` can still import as a bare namespace package when
# another package ships gi/overrides (as the CI image does); it then has no
# require_version, and the libnm tests are skipped like a missing typelib.
try:
    import gi
    gi.require_version('NM', '1.0')
    from gi.repository import GLib, NM
except (ImportError, ValueError, AttributeError):
    GLib = NM = None


def profile():
    return dict(action='apply', uuid='profile', version='9', autoconnect=True, metered=0,
                ipv4=dict(method='manual', addresses='192.0.2.5/24', gateway='192.0.2.1',
                          dns='1.1.1.1', autoDns=False),
                ipv6=dict(method='auto', addresses='', gateway='', dns='', autoDns=True))


class NetworkValidation(unittest.TestCase):
    def test_addresses_and_dns_are_typed_and_bounded(self):
        network.validate_edit(profile())
        for key, value in [('addresses', '192.0.2.5'), ('gateway', '192.0.2.1,192.0.2.2'),
                           ('dns', 'example.com'), ('dns', '2001:db8::1')]:
            request = profile()
            request['ipv4'][key] = value
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                network.validate_edit(request)

    def test_empty_manual_and_disabled_both_rejected(self):
        request = profile()
        request['ipv4']['addresses'] = ''
        with self.assertRaises(ValueError):
            network.validate_edit(request)
        request = profile()
        request['ipv4']['method'] = request['ipv6']['method'] = 'disabled'
        with self.assertRaises(ValueError):
            network.validate_edit(request)

    def test_concurrent_edit_never_updates(self):
        service = object.__new__(network.NetworkSettings)
        service.client = Mock()
        remote = service.client.get_connection_by_uuid.return_value
        remote.get_connection_type.return_value = network.PHYSICAL[0]
        remote.get_version_id.return_value = 10
        with self.assertRaisesRegex(ValueError, 'changed elsewhere'):
            service.connection(profile())


@unittest.skipUnless(NM, 'libnm introspection unavailable')
class NetworkNativeTypes(unittest.TestCase):
    def setUp(self):
        self.service = object.__new__(network.NetworkSettings)
        self.service.NM, self.service.GLib = NM, GLib
        self.remote = NM.SimpleConnection.new()
        connection = NM.SettingConnection.new()
        connection.props.id = 'fixture'
        connection.props.uuid = 'aaaa1111-1111-4111-8111-111111111111'
        connection.props.type = '802-3-ethernet'
        connection.props.zone = 'cybexos'
        self.remote.add_setting(connection)
        self.remote.add_setting(NM.SettingWired.new())
        for cls in (NM.SettingIP4Config, NM.SettingIP6Config):
            config = cls.new()
            config.props.method = 'auto'
            self.remote.add_setting(config)
        self.remote.get_setting_ip4_config().add_route(NM.IPRoute.new(2, '198.51.100.0', 24, '192.0.2.1', 80))

    def test_preserves_unedited_routes_and_zone_without_mutating_original(self):
        clone = self.service.edited(self.remote, profile())
        self.assertEqual(clone.get_setting_connection().props.zone, 'cybexos')
        self.assertEqual(clone.get_setting_ip4_config().get_num_routes(), 1)
        self.assertEqual(clone.get_setting_ip4_config().get_address(0).get_address(), '192.0.2.5')
        self.assertEqual(self.remote.get_setting_ip4_config().props.method, 'auto')

    def test_update_retains_gvariant_types_and_version_guard(self):
        self.service.call = Mock()
        remote = Mock()
        remote.get_path.return_value = '/fixture'
        clone = self.service.edited(self.remote, profile())
        self.service.update(remote, clone, 2, '9007199254740993')
        args = self.service.call.call_args.args[3]
        self.assertEqual(args.get_type_string(), '(a{sa{sv}}ua{sv})')
        self.assertEqual(args.unpack()[2]['version-id'], 9007199254740993)
        self.assertEqual(args.unpack()[1], 2)

    def test_dhcp_secondary_addresses_survive_unrelated_edits(self):
        config = self.remote.get_setting_ip4_config()
        config.add_address(NM.IPAddress.new(2, '192.0.2.8', 24))
        config.props.gateway = '192.0.2.1'
        request = profile()
        request['ipv4']['method'] = 'auto'
        clone = self.service.edited(self.remote, request)
        edited = clone.get_setting_ip4_config()
        self.assertEqual(edited.get_address(0).get_address(), '192.0.2.8')
        self.assertEqual(edited.props.gateway, '192.0.2.1')

    def test_wifi_secrets_and_flags_survive_profile_edits(self):
        self.remote.remove_setting(NM.SettingWired)
        self.remote.get_setting_connection().props.type = '802-11-wireless'
        wifi = NM.SettingWireless.new()
        wifi.props.ssid = GLib.Bytes.new(b'fixture')
        self.remote.add_setting(wifi)
        security = NM.SettingWirelessSecurity.new()
        security.props.key_mgmt = 'wpa-psk'
        security.props.psk_flags = NM.SettingSecretFlags.AGENT_OWNED
        self.remote.add_setting(security)
        clone = self.service.edited(self.remote, profile())
        self.assertEqual(clone.get_setting_wireless_security().props.psk_flags,
                         NM.SettingSecretFlags.AGENT_OWNED)
        self.assertIsNone(clone.get_setting_wireless_security().props.psk)
        self.assertEqual(clone.get_setting_wireless().props.ssid.get_data(), b'fixture')


class NetworkTransactions(unittest.TestCase):
    def setUp(self):
        self.service = object.__new__(network.NetworkSettings)
        self.service.connection = Mock(return_value=Mock())
        self.remote = self.service.connection.return_value
        self.remote.get_uuid.return_value = 'profile'
        self.remote.get_path.return_value = '/profile'
        self.service.edited = Mock(return_value=object())
        self.service.update = Mock()
        self.service.call = Mock()
        self.service.rollback = Mock()
        self.service.active_for = Mock(return_value=Mock())
        device = Mock()
        device.get_path.return_value = '/device'
        self.service.active_for.return_value.get_devices.return_value = [device]
        self.service.NM = Mock()
        self.service.NM.Object.get_path.side_effect = lambda device: device.get_path()
        self.service.NM.Client.new.return_value.get_connection_by_uuid.return_value.get_version_id.return_value = 10

    def test_active_trial_is_in_memory_and_networkmanager_owns_timeout(self):
        self.service.call.side_effect = [('/org/freedesktop/NetworkManager/Checkpoint/1',), ('/active',), (2,)]
        result = self.service.dispatch(profile())
        self.assertEqual(self.service.call.call_args_list[0].args[-1], (['/device'], 60, 0))
        self.assertEqual(self.service.update.call_args.args[2], 2)
        self.assertEqual(result['version'], '10')
        self.assertIn('checkpoint', result)
        self.assertNotIn('Save', [c.args[2] for c in self.service.call.call_args_list])

    def test_failed_activation_restores_checkpoint(self):
        self.service.call.side_effect = [('/checkpoint',), ('/active',), (4,)]
        with self.assertRaises(ValueError):
            self.service.dispatch(profile())
        self.service.rollback.assert_called_once_with('/checkpoint')

    def test_inactive_edit_saves_without_disrupting_devices(self):
        self.service.active_for.return_value = None
        self.service.dispatch(profile())
        self.assertEqual(self.service.update.call_args.args[2], 1)
        self.service.call.assert_not_called()

    def test_expired_preview_cannot_be_saved(self):
        self.service.checkpoint_exists = Mock(return_value=False)
        with self.assertRaisesRegex(ValueError, 'expired'):
            self.service.dispatch(dict(action='confirm', checkpoint='/expired'))
        self.service.call.assert_not_called()

    def test_confirmation_saves_then_releases_checkpoint(self):
        self.service.checkpoint_exists = Mock(return_value=True)
        self.service.dispatch(dict(action='confirm', checkpoint='/preview'))
        self.assertEqual([c.args[2] for c in self.service.call.call_args_list], ['Save', 'CheckpointDestroy'])

    def test_failed_save_and_concurrent_confirmation_restore(self):
        self.service.checkpoint_exists = Mock(return_value=True)
        self.service.call.side_effect = RuntimeError('not authorized')
        with self.assertRaises(RuntimeError):
            self.service.dispatch(dict(action='confirm', checkpoint='/preview'))
        self.service.rollback.assert_called_once_with('/preview')


class AudioCapabilities(unittest.TestCase):
    def test_unavailable_profiles_never_reach_pactl(self):
        with patch.object(audio, 'records', return_value=[dict(name='card', profiles={'off': {'available':'no'}})]), patch.object(audio, 'pactl') as command:
            with self.assertRaises(ValueError):
                audio.AudioSettings().dispatch(dict(action='profile', name='card', value='off'))
            command.assert_not_called()

    def test_stream_index_reuse_is_rejected(self):
        stream = dict(index=3, properties={'object.serial': 'new', 'application.name': 'Browser'})
        with patch.object(audio, 'records', return_value=[stream]), patch.object(audio, 'pactl') as command:
            with self.assertRaises(ValueError):
                audio.AudioSettings().dispatch(dict(action='mute', kind='sink-inputs', index=3, serial='old', value=True))
            command.assert_not_called()

    def test_internal_filter_streams_are_not_rerouted(self):
        stream = dict(index=3, properties={'object.serial': '44'})
        with patch.object(audio, 'records', return_value=[stream]), patch.object(audio, 'pactl') as command:
            with self.assertRaises(ValueError):
                audio.AudioSettings().dispatch(dict(action='route', kind='sink-inputs', index=3, serial='44', value='sink'))
            command.assert_not_called()

    def test_stereo_balance_preserves_loudest_channel(self):
        device = dict(name='speaker', channel_map='front-right,front-left',
                      volume={'front-left':{'value':32768}, 'front-right':{'value':32768}})
        with patch.object(audio, 'records', return_value=[device]), patch.object(audio, 'pactl') as command:
            audio.AudioSettings().dispatch(dict(action='balance', kind='sinks', name='speaker', value=-1))
            command.assert_called_once_with('set-sink-volume', 'speaker', 0, 32768)


class Accounts(unittest.TestCase):
    def setUp(self):
        self.service = object.__new__(accounts.AccountSettings)
        self.service.accounts = Mock(return_value=[dict(id='1', path='/account', locked=False)])
        self.service.call = Mock()
        self.service.GLib = Mock()

    def test_removal_requires_explicit_confirmation(self):
        with self.assertRaises(ValueError):
            self.service.dispatch(dict(action='remove', id='1'))
        self.service.call.assert_not_called()
        self.service.dispatch(dict(action='remove', id='1', confirmed=True))
        self.assertEqual(self.service.call.call_args.args[2], 'Remove')

    def test_managed_account_cannot_be_changed(self):
        self.service.accounts.return_value[0]['locked'] = True
        with self.assertRaises(ValueError):
            self.service.dispatch(dict(action='remove', id='1', confirmed=True))
        self.service.call.assert_not_called()

    def test_calendar_toggle_only_sets_calendar_property(self):
        self.service.dispatch(dict(action='calendar', id='1', enabled=False))
        self.assertEqual(self.service.call.call_args.args[:3], ('/account', 'org.freedesktop.DBus.Properties', 'Set'))
        self.assertEqual(self.service.call.call_args.args[-1][1], 'CalendarDisabled')
        self.service.GLib.Variant.assert_called_once_with('b', True)


class RequestBoundary(unittest.TestCase):
    def test_malformed_or_oversized_input_returns_bounded_error(self):
        for body in ['[]\n', 'invalid\n', 'x'*65537]:
            result = subprocess.run([sys.executable, str(SCRIPTS/'system-settings.py'), 'sound'],
                                    input=body, text=True, capture_output=True, timeout=5)
            self.assertFalse(json.loads(result.stdout)['success'])
            self.assertEqual(result.stderr, '')
            self.assertLess(len(result.stdout), 500)


if __name__ == '__main__':
    unittest.main()
