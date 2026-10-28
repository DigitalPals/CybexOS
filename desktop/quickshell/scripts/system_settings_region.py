"""Read region services; stage persistent NixOS declarations for changes."""
import os
import json
import subprocess

TIME = 'org.freedesktop.timedate1'
LOCALE = 'org.freedesktop.locale1'


def choices(command):
    result = subprocess.run(command, capture_output=True, text=True, timeout=5, check=False,
                            env={**os.environ, 'LC_ALL': 'C', 'SYSTEMD_PAGER': ''})
    if result.returncode:
        raise ValueError('System region choices are unavailable. Check systemd and language packages.')
    return sorted(set(result.stdout.splitlines()))


def installed_locales():
    # localectl enumerates mutable locale directories. NixOS installs an
    # archive selected by LOCALE_ARCHIVE, which glibc's locale tool reads.
    return sorted({value.replace('.utf8', '.UTF-8') for value in choices(['locale', '-a'])
                   if value.endswith(('.utf8', '.UTF-8'))})


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
                'locales': installed_locales()}

    def dispatch(self, request):
        action = request.get('action', 'snapshot')
        if action == 'snapshot':
            return self.snapshot()
        if action == 'stage':
            # One preview for every pending regional change, so a timezone and
            # a language chosen together build one generation and one restart.
            items = request.get('changes')
            if not isinstance(items, list) or not 1 <= len(items) <= 2 \
                    or len({item.get('field') for item in items if isinstance(item, dict)}) != len(items):
                raise ValueError('Choose a timezone or a language to apply')
            staged = []
            for item in items:
                field, value, previous = item.get('field'), item.get('value'), item.get('previous')
                if field == 'timezone':
                    if not isinstance(value, str) or value not in choices(['timedatectl', 'list-timezones', '--no-pager']):
                        raise ValueError('Choose an installed timezone')
                    if previous != self.properties(TIME).get('Timezone', ''):
                        raise ValueError('The timezone changed elsewhere. Discard the pending change and refresh before applying.')
                elif field == 'locale':
                    if not isinstance(value, str) or value not in installed_locales():
                        raise ValueError('Choose an installed locale. Install its language pack first if it is missing.')
                    if previous != self.properties(LOCALE).get('Locale', []):
                        raise ValueError('System language settings changed elsewhere. Discard the pending change and refresh before applying.')
                else:
                    raise ValueError('Unknown region operation')
                staged.append((field, value, previous))
            return self.stage(staged)
        raise ValueError('Unknown region operation')

    def stage(self, items):
        command = ['cybex', 'config', 'region']
        for field, value, previous in items:
            command += [field, value, json.dumps(previous)]
        result = subprocess.run(command, capture_output=True, text=True, timeout=50)
        if result.returncode:
            raise ValueError('Regional preview could not start. Check authorization and cybex update status.')
        return {'staged': True, 'message': 'Preparing the system change. Review it in Software Update, then restart to use it.'}
