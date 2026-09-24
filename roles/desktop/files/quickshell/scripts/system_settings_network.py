"""Common profile editor using libnm validation and NM-owned rollback."""
import ipaddress
import re
import time

BUS = 'org.freedesktop.NetworkManager'
ROOT = '/org/freedesktop/NetworkManager'
CONNECTION = BUS + '.Settings.Connection'
PHYSICAL = ('802-3-ethernet', '802-11-wireless')
CHECKPOINT = re.compile(r'^/org/freedesktop/NetworkManager/Checkpoint/[0-9]+$')


def ip_values(text, family, addresses=False):
    if not isinstance(text, str) or len(text) > 4096:
        raise ValueError('Invalid IP configuration')
    result = []
    for value in re.split(r'[,\s]+', text.strip()):
        if not value:
            continue
        try:
            ip = ipaddress.ip_interface(value) if addresses else ipaddress.ip_address(value)
        except ValueError as error:
            raise ValueError('Enter valid IP addresses, using address/prefix for manual addresses') from error
        if ip.version != family or '%' in value or (addresses and '/' not in value):
            raise ValueError('Use the correct IP version and include a prefix for manual addresses')
        result.append(ip)
    if len(result) > 16:
        raise ValueError('Enter at most sixteen addresses')
    return result


def validate_edit(request):
    if not isinstance(request.get('autoconnect'), bool) or request.get('metered') not in (0, 1, 2):
        raise ValueError('Invalid connection preferences')
    for family in (4, 6):
        data = request.get('ipv' + str(family))
        if not isinstance(data, dict) or data.get('method') not in ('auto', 'manual', 'disabled'):
            raise ValueError('Choose automatic, manual or disabled IP configuration')
        if not isinstance(data.get('autoDns'), bool):
            raise ValueError('Invalid automatic DNS setting')
        addresses = ip_values(data.get('addresses', ''), family, True)
        gateway = ip_values(data.get('gateway', ''), family)
        ip_values(data.get('dns', ''), family)
        if len(gateway) > 1:
            raise ValueError('Enter one gateway per IP version')
        if data['method'] == 'manual' and not addresses:
            raise ValueError('Manual configuration requires at least one address and prefix')
    if all(request['ipv' + str(f)]['method'] == 'disabled' for f in (4, 6)):
        raise ValueError('Enable at least one IP version')


class NetworkSettings:
    def __init__(self):
        import gi
        gi.require_version('NM', '1.0')
        from gi.repository import Gio, GLib, NM
        self.Gio, self.GLib, self.NM = Gio, GLib, NM
        self.client = NM.Client.new(None)
        self.bus = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)

    def call(self, path, interface, method, signature=None, values=()):
        args = signature if isinstance(signature, self.GLib.Variant) else (
            self.GLib.Variant(signature, values) if signature else None)
        return self.bus.call_sync(BUS, path, interface, method, args, None,
                                  self.Gio.DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION,
                                  20000, None).unpack()

    def ip_snapshot(self, config, family):
        if not config:
            return dict(method='auto', addresses='', gateway='', dns='', autoDns=True)
        return dict(method=config.props.method or 'auto',
                    addresses=', '.join(f'{config.get_address(i).get_address()}/{config.get_address(i).get_prefix()}'
                                        for i in range(config.get_num_addresses())),
                    gateway=config.props.gateway or '',
                    dns=', '.join(config.get_dns(i) for i in range(config.get_num_dns())),
                    autoDns=not config.props.ignore_auto_dns)

    def active_for(self, uuid):
        return next((a for a in self.client.get_active_connections() if a.get_uuid() == uuid), None)

    def snapshot(self):
        profiles = []
        for connection in self.client.get_connections():
            setting = connection.get_setting_connection()
            kind = setting.props.type
            if kind not in PHYSICAL:
                continue
            ip4 = self.ip_snapshot(connection.get_setting_ip4_config(), 4)
            ip6 = self.ip_snapshot(connection.get_setting_ip6_config(), 6)
            supported = all(ip['method'] in ('auto', 'manual', 'disabled') for ip in (ip4, ip6))
            profiles.append(dict(uuid=connection.get_uuid(), name=connection.get_id(),
                                 version=str(connection.get_version_id()),
                                 kind=kind, active=self.active_for(connection.get_uuid()) is not None,
                                 supported=supported, autoconnect=setting.props.autoconnect,
                                 metered=int(setting.props.metered), ipv4=ip4, ipv6=ip6))
        devices = [dict(name=d.get_iface(), state=int(d.get_state())) for d in self.client.get_devices()
                   if d.get_device_type() in (self.NM.DeviceType.ETHERNET, self.NM.DeviceType.WIFI)]
        return dict(profiles=sorted(profiles, key=lambda p: (not p['active'], p['name'])), devices=devices)

    def connection(self, request):
        remote = self.client.get_connection_by_uuid(str(request.get('uuid', '')))
        if remote is None or remote.get_connection_type() not in PHYSICAL:
            raise ValueError('That physical connection is no longer available')
        if str(remote.get_version_id()) != str(request.get('version')):
            raise ValueError('This connection changed elsewhere. Reload it before applying changes.')
        return remote

    def edited(self, remote, request):
        validate_edit(request)
        clone = self.NM.SimpleConnection.new_clone(remote)
        setting = clone.get_setting_connection()
        setting.props.autoconnect = request['autoconnect']
        setting.props.metered = request['metered']
        for family, config in [(4, clone.get_setting_ip4_config()), (6, clone.get_setting_ip6_config())]:
            if config is None or config.props.method not in ('auto', 'manual', 'disabled'):
                raise ValueError('Use the advanced editor for this connection type')
            data = request['ipv' + str(family)]
            preserve_auto_addresses = config.props.method == data['method'] == 'auto'
            config.props.method = data['method']
            # DHCP profiles may also contain static secondary addresses and a
            # gateway. They are not edited by the automatic-mode form.
            if not preserve_auto_addresses:
                config.clear_addresses()
            if data['method'] == 'manual':
                for ip in ip_values(data['addresses'], family, True):
                    config.add_address(self.NM.IPAddress.new(2 if family == 4 else 10,
                                                            str(ip.ip), ip.network.prefixlen))
            if not preserve_auto_addresses:
                config.props.gateway = data['gateway'].strip() or None if data['method'] == 'manual' else None
            config.clear_dns()
            if data['method'] != 'disabled':
                for ip in ip_values(data['dns'], family):
                    config.add_dns(str(ip))
            config.props.ignore_auto_dns = not data['autoDns']
        try:
            clone.verify()
        except Exception as error:
            raise ValueError('NetworkManager rejected these settings. Check addresses, gateways and DNS.') from error
        return clone

    def update(self, remote, clone, flags, version):
        # Keep the typed nested variants: unpack() would erase the signatures
        # of integers, byte arrays and the other variant-valued settings.
        args = self.GLib.Variant.new_tuple(
            clone.to_dbus(self.NM.ConnectionSerializationFlags.ALL),
            self.GLib.Variant('u', flags),
            self.GLib.Variant('a{sv}', {'version-id': self.GLib.Variant('t', int(version))}))
        self.call(remote.get_path(), CONNECTION, 'Update2', args)

    def checkpoint_exists(self, path):
        return isinstance(path, str) and CHECKPOINT.fullmatch(path) and any(
            checkpoint.get_path() == path for checkpoint in self.client.get_checkpoints())

    def rollback(self, checkpoint):
        result = self.call(ROOT, BUS, 'CheckpointRollback', '(o)', (checkpoint,))[0]
        if any(code != 0 for code in result.values()):
            raise ValueError('NetworkManager could not restore every device. Open the advanced editor.')

    def dispatch(self, request):
        action = request.get('action', 'snapshot')
        if action == 'snapshot':
            return self.snapshot()
        if action in ('confirm', 'rollback'):
            checkpoint = request.get('checkpoint')
            if not self.checkpoint_exists(checkpoint):
                raise ValueError('The trial expired or was already restored. Reload the connection.')
            if action == 'rollback':
                self.rollback(checkpoint)
                return {'message': 'Previous network settings restored'}
            try:
                remote = self.connection(request)
                self.call(remote.get_path(), CONNECTION, 'Save')
                self.call(ROOT, BUS, 'CheckpointDestroy', '(o)', (checkpoint,))
            except Exception:
                self.rollback(checkpoint)
                raise
            return {'message': 'Network settings saved'}
        if action != 'apply':
            raise ValueError('Unknown network operation')
        remote = self.connection(request)
        clone = self.edited(remote, request)
        active = self.active_for(remote.get_uuid())
        if not active:
            self.update(remote, clone, 1, request['version'])
            return {'message': 'Connection saved; it will apply when connected'}
        # NM.Device.get_path is the physical udev path on current libnm and
        # shadows NM.Object.get_path in GI. Checkpoints require D-Bus paths.
        devices = [self.NM.Object.get_path(d) for d in active.get_devices()]
        if not devices:
            raise ValueError('This connection has no active physical device')
        checkpoint = self.call(ROOT, BUS, 'CheckpointCreate', '(aouu)', (devices, 60, 0))[0]
        expires = int(time.time()) + 60
        try:
            # Persistent storage is unchanged until the user confirms. NM owns
            # the timeout even if this helper or Quickshell exits unexpectedly.
            self.update(remote, clone, 2, request['version'])
            activation = self.call(ROOT, BUS, 'ActivateConnection', '(ooo)',
                                   (remote.get_path(), devices[0], '/'))[0]
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                state = self.call(activation, 'org.freedesktop.DBus.Properties', 'Get', '(ss)',
                                  (BUS + '.Connection.Active', 'State'))[0]
                if state == 2:
                    break
                if state == 4:
                    raise ValueError('The new settings could not connect; previous settings were restored')
                time.sleep(.2)
            else:
                raise ValueError('Connection timed out; previous settings were restored')
            updated = self.NM.Client.new(None).get_connection_by_uuid(remote.get_uuid())
            return dict(message='Check your connection, then keep or revert these settings',
                        checkpoint=checkpoint, expires=expires, uuid=remote.get_uuid(),
                        version=str(updated.get_version_id()))
        except Exception:
            self.rollback(checkpoint)
            raise
