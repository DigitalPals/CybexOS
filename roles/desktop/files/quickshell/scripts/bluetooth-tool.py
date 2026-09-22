#!/usr/bin/env python3
"""Drawer-scoped BlueZ actions and KeyboardDisplay agent; JSON lines over stdio.

Uses the application agent contract (never replaces the desktop default agent):
https://bluez.readthedocs.io/en/latest/agent-api/
The private bus connection owns discovery, so exit also releases its scan session.
"""
import json
import os
import re
import signal
import sys

from gi.repository import Gio, GLib

AGENT_PATH = '/org/cybex/BluetoothAgent'
DEVICE_IFACE = 'org.bluez.Device1'
ADAPTER_IFACE = 'org.bluez.Adapter1'
AGENT_XML = '''<node><interface name="org.bluez.Agent1">
<method name="Release"/>
<method name="Cancel"/>
<method name="RequestPinCode"><arg type="o" direction="in"/><arg type="s" direction="out"/></method>
<method name="RequestPasskey"><arg type="o" direction="in"/><arg type="u" direction="out"/></method>
<method name="RequestConfirmation"><arg type="o" direction="in"/><arg type="u" direction="in"/></method>
<method name="RequestAuthorization"><arg type="o" direction="in"/></method>
<method name="AuthorizeService"><arg type="o" direction="in"/><arg type="s" direction="in"/></method>
<method name="DisplayPinCode"><arg type="o" direction="in"/><arg type="s" direction="in"/></method>
<method name="DisplayPasskey"><arg type="o" direction="in"/><arg type="u" direction="in"/><arg type="q" direction="in"/></method>
</interface></node>'''


def reply_value(kind, value):
    if kind == 'RequestPinCode':
        if not isinstance(value, str) or not 1 <= len(value) <= 16:
            raise ValueError('Enter a PIN of 1–16 characters.')
        return GLib.Variant('(s)', (value,))
    if kind == 'RequestPasskey':
        if not isinstance(value, str) or not re.fullmatch(r'[0-9]{1,6}', value):
            raise ValueError('Enter a numeric passkey of up to six digits.')
        return GLib.Variant('(u)', (int(value),))
    return GLib.Variant('()', ())


class Session:
    def __init__(self, adapter):
        if not re.fullmatch(r'/org/bluez/hci[0-9]+', adapter):
            raise ValueError('Invalid Bluetooth adapter.')
        self.adapter = adapter
        self.loop = GLib.MainLoop()
        self.pending = None
        self.prompt_kind = ''
        self.device = ''
        self.operation = ''
        self.canceled = False
        self.scan = False
        self.scan_busy = False
        self.scan_timer = 0
        self.buffer = b''
        self.closed = False
        self.bus = Gio.DBusConnection.new_for_address_sync(
            Gio.dbus_address_get_for_bus_sync(Gio.BusType.SYSTEM, None),
            Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT
            | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION, None, None)
        self.owner = self.bus.call_sync(
            'org.freedesktop.DBus', '/org/freedesktop/DBus',
            'org.freedesktop.DBus', 'GetNameOwner',
            GLib.Variant('(s)', ('org.bluez',)), None,
            Gio.DBusCallFlags.NONE, 5000, None).unpack()[0]
        self.bus.register_object(AGENT_PATH,
                                 Gio.DBusNodeInfo.new_for_xml(AGENT_XML).interfaces[0],
                                 self.agent, None, None)
        self.bus.call_sync('org.bluez', '/org/bluez', 'org.bluez.AgentManager1',
                           'RegisterAgent', GLib.Variant('(os)', (AGENT_PATH, 'KeyboardDisplay')),
                           None, Gio.DBusCallFlags.NONE, 5000, None)

    def emit(self, **event):
        if not self.closed:
            try:
                print(json.dumps(event), flush=True)
            except BrokenPipeError:
                self.close()

    def call(self, path, interface, method, params=None, done=None, timeout=30000):
        def finished(bus, result):
            try:
                bus.call_finish(result)
                error = ''
            except GLib.Error as exc:
                error = exc.message
            if not self.closed and done:
                done(error)
        self.bus.call('org.bluez', path, interface, method, params, None,
                      Gio.DBusCallFlags.NONE, timeout, None, finished)

    def clear_prompt(self):
        if self.pending:
            self.pending.return_dbus_error('org.bluez.Error.Canceled', 'Pairing canceled')
        self.pending = None
        self.prompt_kind = ''
        self.emit(prompt=None)

    def agent(self, connection, sender, path, interface, method, parameters, invocation):
        args = parameters.unpack()
        if sender != self.owner:
            invocation.return_dbus_error('org.bluez.Error.Rejected', 'Unknown caller')
            return
        if method in ('Release', 'Cancel'):
            self.clear_prompt()
            invocation.return_value(None)
            if method == 'Release':
                self.close()
            return
        if not self.device or args[0] != self.device:
            invocation.return_dbus_error('org.bluez.Error.Rejected', 'No matching user action')
            return
        display = method in ('DisplayPinCode', 'DisplayPasskey')
        if not display and self.pending:
            invocation.return_dbus_error('org.bluez.Error.Rejected', 'Another prompt is pending')
            return
        code = str(args[1]) if method == 'DisplayPinCode' else (
            f'{args[1]:06d}' if method in ('DisplayPasskey', 'RequestConfirmation') else '')
        if display:
            invocation.return_value(None)
        else:
            self.pending = invocation
            self.prompt_kind = method
        self.emit(prompt={'kind': method, 'code': code,
                          'entered': args[2] if method == 'DisplayPasskey' else 0,
                          'service': args[1] if method == 'AuthorizeService' else ''})

    def finish(self, error=''):
        self.clear_prompt()
        self.device = ''
        self.operation = ''
        self.emit(busy='', error=error)

    def cancel(self):
        self.canceled = True
        self.clear_prompt()
        if self.operation == 'pair' and self.device:
            self.call(self.device, DEVICE_IFACE, 'CancelPairing')
        elif self.operation == 'connect' and self.device:
            self.call(self.device, DEVICE_IFACE, 'Disconnect')
        # Keep the operation locked until its original D-Bus reply arrives.

    def discovery(self, enabled):
        if self.scan_busy or enabled == self.scan:
            return
        self.scan_busy = True
        self.emit(scanBusy=True)
        def complete(error):
            self.scan_busy = False
            if not error:
                self.scan = enabled
                if self.scan_timer:
                    GLib.source_remove(self.scan_timer)
                    self.scan_timer = 0
                if enabled:
                    self.scan_timer = GLib.timeout_add_seconds(60, self.scan_expired)
            self.emit(scanning=self.scan, scanBusy=False, error=error)
        self.call(self.adapter, ADAPTER_IFACE,
                  'StartDiscovery' if enabled else 'StopDiscovery', done=complete)

    def scan_expired(self):
        self.scan_timer = 0
        self.discovery(False)
        return False

    def command(self, message):
        action = message.get('action')
        if action == 'scan':
            self.discovery(message.get('enabled') is True)
        elif action == 'cancel':
            self.cancel()
        elif action == 'reply':
            if not self.pending:
                return
            if message.get('accept') is not True:
                self.cancel()
                return
            value = reply_value(self.prompt_kind, message.get('value', ''))
            self.pending.return_value(value)
            self.pending = None
            self.prompt_kind = ''
            self.emit(prompt=None, error='')
        elif action in ('pair', 'connect', 'disconnect'):
            if self.device:
                raise ValueError('Wait for the current Bluetooth action to finish.')
            device = message.get('device', '')
            if not re.fullmatch(re.escape(self.adapter) + r'/dev_(?:[0-9A-F]{2}_){5}[0-9A-F]{2}', device):
                raise ValueError('Invalid Bluetooth device.')
            self.canceled = False
            self.device, self.operation = device, action
            self.emit(busy=device, error='')
            if action == 'pair':
                self.call(device, DEVICE_IFACE, 'Pair', done=self.paired, timeout=120000)
            else:
                self.call(device, DEVICE_IFACE, action.title(), done=self.finish)
        else:
            raise ValueError('Unknown Bluetooth action.')

    def paired(self, error):
        if self.canceled:
            self.finish('Pairing canceled')
            return
        if error:
            # A local D-Bus timeout does not cancel the remote Pair operation.
            self.call(self.device, DEVICE_IFACE, 'CancelPairing')
            self.finish(error)
            return
        self.clear_prompt()
        device = self.device
        def trusted(error):
            if self.canceled:
                self.finish('Pairing canceled')
            elif error:
                self.finish(error)
            else:
                self.operation = 'connect'
                self.call(device, DEVICE_IFACE, 'Connect', done=self.finish)
        self.call(device, 'org.freedesktop.DBus.Properties', 'Set',
                  GLib.Variant('(ssv)', (DEVICE_IFACE, 'Trusted', GLib.Variant('b', True))),
                  done=trusted)

    def read(self, fd, condition):
        data = os.read(fd, 65536)
        if not data:
            self.close()
            return False
        self.buffer += data
        if len(self.buffer) > 65536:
            self.close()
            return False
        while b'\n' in self.buffer:
            line, self.buffer = self.buffer.split(b'\n', 1)
            try:
                message = json.loads(line)
                if not isinstance(message, dict):
                    raise ValueError('Invalid Bluetooth request.')
                self.command(message)
            except (ValueError, TypeError, GLib.Error) as exc:
                self.emit(error=str(exc))
        return True

    def close(self):
        if self.closed:
            return False
        self.closed = True
        self.clear_prompt()
        if self.device and self.operation == 'pair':
            try:
                self.bus.call_sync('org.bluez', self.device, DEVICE_IFACE, 'CancelPairing',
                                   None, None, Gio.DBusCallFlags.NONE, 1000, None)
            except GLib.Error:
                pass
        # Closing this private connection unregisters the agent and releases
        # only our discovery session, including an in-flight StartDiscovery.
        self.bus.close_sync(None)
        self.loop.quit()
        return False

    def run(self):
        GLib.io_add_watch(sys.stdin.fileno(), GLib.IO_IN | GLib.IO_HUP, self.read)
        GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGTERM, self.close)
        GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGINT, self.close)
        self.emit(ready=True)
        try:
            self.loop.run()
        finally:
            self.close()


def main():
    try:
        Session(sys.argv[1]).run()
    except (GLib.Error, ValueError, IndexError) as exc:
        print(json.dumps({'error': str(exc)}), flush=True)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
