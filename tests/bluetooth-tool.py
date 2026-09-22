#!/usr/bin/env python3
"""Exercise the BlueZ session protocol without changing a real radio."""
import importlib.util
import sys
import types
import unittest
from pathlib import Path
from unittest.mock import Mock, patch


class Variant:
    def __init__(self, signature, value):
        self.signature, self.value = signature, value

    def unpack(self):
        return self.value


# Keep the repository gate independent of PyGObject or a running system bus.
glib = types.SimpleNamespace(Variant=Variant, Error=RuntimeError,
                             timeout_add_seconds=Mock(return_value=7), source_remove=Mock())
gio = types.SimpleNamespace(DBusCallFlags=types.SimpleNamespace(NONE=0))
spec = importlib.util.spec_from_file_location('bluetooth_tool',
    Path(__file__).resolve().parents[1] / 'roles/desktop/files/quickshell/scripts/bluetooth-tool.py')
module = importlib.util.module_from_spec(spec)
with patch.dict(sys.modules, {'gi': types.ModuleType('gi'),
                             'gi.repository': types.SimpleNamespace(Gio=gio, GLib=glib)}):
    spec.loader.exec_module(module)


class BluetoothTest(unittest.TestCase):
    def setUp(self):
        self.session = module.Session.__new__(module.Session)
        s = self.session
        s.adapter = '/org/bluez/hci0'
        s.device = ''
        s.operation = ''
        s.canceled = False
        s.pending = None
        s.prompt_kind = ''
        s.scan = False
        s.scan_busy = False
        s.scan_timer = 0
        s.closed = False
        s.owner = ':1.4'
        s.bus = Mock()
        s.loop = Mock()
        s.emit = Mock()
        s.call = Mock()
        self.device = s.adapter + '/dev_AA_BB_CC_DD_EE_FF'

    def agent(self, method, args, sender=':1.4'):
        invocation = Mock()
        self.session.agent(None, sender, '', '', method, Variant('', args), invocation)
        return invocation

    def test_pin_and_passkey_validation(self):
        self.assertEqual(module.reply_value('RequestPasskey', '000042').unpack(), (42,))
        self.assertEqual(module.reply_value('RequestPinCode', 'abc-123').unpack(), ('abc-123',))
        for kind, values in [('RequestPasskey', ['', '-1', '1000000', 'a', '１２', 123]),
                             ('RequestPinCode', ['', 'a' * 17, 123])]:
            for value in values:
                with self.subTest(kind=kind, value=value), self.assertRaises(ValueError):
                    module.reply_value(kind, value)

    def test_rejects_unknown_sender_and_unrequested_device(self):
        self.session.device = self.device
        for sender, device in [(':1.9', self.device), (':1.4', self.device + '00')]:
            self.agent('RequestConfirmation', (device, 42), sender).return_dbus_error.assert_called_once()
        self.assertIsNone(self.session.pending)

    def test_confirmation_preserves_leading_zeroes_and_requires_reply(self):
        self.session.device = self.device
        invocation = self.agent('RequestConfirmation', (self.device, 42))
        invocation.return_value.assert_not_called()
        self.assertEqual(self.session.emit.call_args.kwargs['prompt']['code'], '000042')
        self.session.command({'action': 'reply', 'accept': True})
        invocation.return_value.assert_called_once()
        self.assertIsNone(self.session.pending)

    def test_invalid_input_leaves_prompt_available_for_retry(self):
        self.session.device = self.device
        invocation = self.agent('RequestPasskey', (self.device,))
        with self.assertRaises(ValueError):
            self.session.command({'action': 'reply', 'accept': True, 'value': 'oops'})
        self.assertIs(self.session.pending, invocation)
        self.session.command({'action': 'reply', 'accept': True, 'value': '001234'})
        self.assertEqual(invocation.return_value.call_args.args[0].unpack(), (1234,))

    def test_display_passkey_reports_progress_without_pending_response(self):
        self.session.device = self.device
        invocation = self.agent('DisplayPasskey', (self.device, 42, 3))
        invocation.return_value.assert_called_once()
        self.assertIsNone(self.session.pending)
        self.assertEqual(self.session.emit.call_args.kwargs['prompt']['entered'], 3)

    def test_rejecting_prompt_cancels_pair_but_keeps_operation_locked(self):
        s = self.session
        s.command({'action': 'pair', 'device': self.device})
        invocation = self.agent('RequestAuthorization', (self.device,))
        s.command({'action': 'reply', 'accept': False})
        invocation.return_dbus_error.assert_called_once()
        self.assertEqual(s.call.call_args.args[2], 'CancelPairing')
        with self.assertRaises(ValueError):
            s.command({'action': 'connect', 'device': self.device})
        s.finish('Pairing canceled')
        self.assertEqual(s.device, '')

    def test_pairing_success_trusts_then_connects(self):
        s = self.session
        s.command({'action': 'pair', 'device': self.device})
        self.assertEqual(s.call.call_args.args[2], 'Pair')
        s.call.call_args.kwargs['done']('')
        self.assertEqual(s.call.call_args.args[2], 'Set')
        params = s.call.call_args.args[3].unpack()
        self.assertEqual(params[:2], (module.DEVICE_IFACE, 'Trusted'))
        self.assertTrue(params[2].unpack())
        s.call.call_args.kwargs['done']('')
        self.assertEqual(s.call.call_args.args[2], 'Connect')
        s.call.call_args.kwargs['done']('')
        self.assertEqual(s.device, '')

    def test_cancel_racing_with_pair_success_never_connects(self):
        s = self.session
        s.command({'action': 'pair', 'device': self.device})
        paired = s.call.call_args.kwargs['done']
        s.cancel()
        paired('')
        self.assertEqual(s.device, '')
        self.assertFalse(any(call.args[2] == 'Set' for call in s.call.call_args_list))

    def test_pair_failure_cancels_and_does_not_trust_or_connect(self):
        s = self.session
        s.command({'action': 'pair', 'device': self.device})
        s.call.call_args.kwargs['done']('Authentication failed')
        self.assertEqual(s.call.call_args.args[2], 'CancelPairing')
        self.assertEqual(s.emit.call_args.kwargs['error'], 'Authentication failed')
        self.assertEqual(s.device, '')

    def test_connect_and_disconnect_errors_release_busy_state(self):
        for action in ('connect', 'disconnect'):
            self.session.command({'action': action, 'device': self.device})
            self.session.call.call_args.kwargs['done']('Device unavailable')
            self.assertEqual(self.session.device, '')
            self.assertEqual(self.session.emit.call_args.kwargs['error'], 'Device unavailable')

    def test_cross_adapter_and_invalid_paths_are_rejected(self):
        for device in ['/org/bluez/hci1/dev_AA_BB_CC_DD_EE_FF', self.device + '/extra', 'oops']:
            with self.assertRaises(ValueError):
                self.session.command({'action': 'pair', 'device': device})
        self.session.call.assert_not_called()

    def test_discovery_is_bounded_and_stop_releases_own_session(self):
        s = self.session
        s.discovery(True)
        self.assertTrue(s.scan_busy)
        s.discovery(True)
        self.assertEqual(s.call.call_count, 1)
        s.call.call_args.kwargs['done']('')
        self.assertTrue(s.scan)
        glib.timeout_add_seconds.assert_called_with(60, s.scan_expired)
        s.scan_expired()
        self.assertEqual(s.call.call_args.args[2], 'StopDiscovery')
        s.call.call_args.kwargs['done']('')
        self.assertFalse(s.scan)

    def test_failed_scan_does_not_claim_discovery(self):
        self.session.discovery(True)
        self.session.call.call_args.kwargs['done']('Adapter powered off')
        self.assertFalse(self.session.scan)
        self.assertFalse(self.session.scan_busy)

    def test_close_cancels_pairing_and_closes_private_bus(self):
        s = self.session
        s.command({'action': 'pair', 'device': self.device})
        invocation = self.agent('RequestPinCode', (self.device,))
        s.close()
        invocation.return_dbus_error.assert_called_once()
        self.assertEqual(s.bus.call_sync.call_args.args[3], 'CancelPairing')
        s.bus.close_sync.assert_called_once()
        s.close()
        s.bus.close_sync.assert_called_once()


if __name__ == '__main__':
    unittest.main()
