"""System region settings through timedated/localed's normal Polkit policy."""
import os
import subprocess

TIME = 'org.freedesktop.timedate1'
LOCALE = 'org.freedesktop.locale1'


def choices(command):
    result = subprocess.run(command, capture_output=True, text=True, timeout=5, check=False,
                            env={**os.environ, 'LC_ALL': 'C', 'SYSTEMD_PAGER': ''})
    if result.returncode:
        raise ValueError('System region choices are unavailable. Check systemd and language packages.')
    return sorted(set(result.stdout.splitlines()))


class RegionSettings:
    def __init__(self):
        import gi
        gi.require_version('Gio', '2.0')
        from gi.repository import Gio, GLib
        self.Gio, self.GLib = Gio, GLib
        self.bus = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)

    def call(self, service, interface, method, signature, values, interactive=False):
        try:
            flags = (self.Gio.DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION if interactive
                     else self.Gio.DBusCallFlags.NONE)
            return self.bus.call_sync(service, '/' + service.replace('.', '/'), interface, method,
                                      self.GLib.Variant(signature, values), None, flags,
                                      45000 if interactive else 5000, None).unpack()
        except self.GLib.Error as error:
            # Do not expose arbitrary D-Bus error text; identify the actionable cases.
            remote = self.Gio.DBusError.get_remote_error(error) or ''
            if any(word in remote.lower() for word in ('accessdenied', 'notauthorized', 'authfailed', 'cancelled')):
                raise ValueError('Authorization was cancelled or denied. Retry and approve the system prompt.') from error
            raise ValueError('The system region service did not finish. Refresh to check the current value before retrying.') from error

    def properties(self, service):
        return self.call(service, 'org.freedesktop.DBus.Properties', 'GetAll', '(s)', (service,))[0]

    def snapshot(self):
        time = self.properties(TIME)
        locale = self.properties(LOCALE).get('Locale', [])
        return {'timezone': time.get('Timezone', ''),
                'locale': next((value[5:] for value in locale if value.startswith('LANG=')), ''),
                'localeValues': locale,
                'timezones': choices(['timedatectl', 'list-timezones', '--no-pager']),
                'locales': choices(['localectl', 'list-locales', '--no-pager'])}

    def dispatch(self, request):
        action = request.get('action', 'snapshot')
        if action == 'snapshot':
            return self.snapshot()
        if action == 'timezone':
            value = request.get('value')
            if not isinstance(value, str) or value not in choices(['timedatectl', 'list-timezones', '--no-pager']):
                raise ValueError('Choose an installed timezone')
            if request.get('previous') != self.properties(TIME).get('Timezone', ''):
                raise ValueError('The timezone changed elsewhere. Discard the pending change and refresh before applying.')
            self.call(TIME, TIME, 'SetTimezone', '(sb)', (value, True), interactive=True)
            if self.properties(TIME).get('Timezone') != value:
                raise ValueError('The timezone was not retained. Refresh before retrying.')
            return {'message': 'System timezone updated'}
        if action == 'locale':
            value = request.get('value')
            if not isinstance(value, str) or value not in choices(['localectl', 'list-locales', '--no-pager']):
                raise ValueError('Choose an installed locale. Install its language pack first if it is missing.')
            previous = self.properties(LOCALE).get('Locale', [])
            if request.get('previous') != previous:
                raise ValueError('System language settings changed elsewhere. Discard the pending change and refresh before applying.')
            # SetLocale replaces the whole array. Keep LC_TIME, LC_NUMERIC and
            # every other explicit category; only change the requested LANG.
            values = [entry for entry in previous if not entry.startswith('LANG=')] + ['LANG=' + value]
            self.call(LOCALE, LOCALE, 'SetLocale', '(asb)', (values, True), interactive=True)
            if sorted(self.properties(LOCALE).get('Locale', [])) != sorted(values):
                raise ValueError('The language settings were not retained. Refresh before retrying.')
            return {'message': 'System language updated. Sign out and back in for applications to use it.'}
        raise ValueError('Unknown region operation')
