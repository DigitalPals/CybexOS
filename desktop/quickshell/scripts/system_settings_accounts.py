"""GOA metadata and account actions; never request credentials or tokens."""
BUS = 'org.gnome.OnlineAccounts'
ROOT = '/org/gnome/OnlineAccounts'
ACCOUNT = BUS + '.Account'


class AccountSettings:
    def __init__(self):
        import gi
        gi.require_version('Gio', '2.0')
        from gi.repository import Gio, GLib
        self.Gio, self.GLib = Gio, GLib
        self.bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)

    def call(self, path, interface, method, signature=None, values=()):
        args = self.GLib.Variant(signature, values) if signature else None
        return self.bus.call_sync(BUS, path, interface, method, args, None,
                                  self.Gio.DBusCallFlags.NONE, 12000, None).unpack()

    def accounts(self):
        objects = self.call(ROOT, 'org.freedesktop.DBus.ObjectManager', 'GetManagedObjects')[0]
        accounts = []
        for path, interfaces in objects.items():
            props = interfaces.get(ACCOUNT)
            if props is None:
                continue
            accounts.append(dict(id=props['Id'], path=path,
                                 provider=props.get('ProviderName', ''),
                                 identity=props.get('PresentationIdentity', ''),
                                 attention=props.get('AttentionNeeded', False),
                                 locked=props.get('IsLocked', False),
                                 calendar=(BUS + '.Calendar' in interfaces or props.get('ProviderType')
                                           in ('google', 'owncloud', 'exchange', 'ms_graph', 'webdav')),
                                 calendarDisabled=props.get('CalendarDisabled', False)))
        return accounts

    def dispatch(self, request):
        accounts = self.accounts()
        action = request.get('action', 'snapshot')
        if action == 'snapshot':
            return {'accounts': accounts}
        account = next((a for a in accounts if a['id'] == request.get('id')), None)
        if not account:
            raise ValueError('That account is no longer available')
        if account['locked']:
            raise ValueError('This account is managed by your administrator')
        if action == 'calendar':
            if not isinstance(request.get('enabled'), bool):
                raise ValueError('Invalid calendar setting')
            self.call(account['path'], 'org.freedesktop.DBus.Properties', 'Set', '(ssv)',
                      (ACCOUNT, 'CalendarDisabled', self.GLib.Variant('b', not request['enabled'])))
        elif action == 'remove':
            if request.get('confirmed') is not True:
                raise ValueError('Confirm removal of this account from the computer')
            self.call(account['path'], ACCOUNT, 'Remove')
        else:
            raise ValueError('Unknown account operation')
        return {'message': 'Account updated'}
