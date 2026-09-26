"""Guest-only SDDM/keyring qualification on TestVM's disposable installation.

No commands in this module run at import time. Secrets are synthetic fixture
values, sent over the guest's private SSH connection on stdin, never in argv.
"""
import json
import time

from vm_testing import poweroff_guest, run


USER_ENV = ('export XDG_RUNTIME_DIR=/run/user/$(id -u); '
            'export DBUS_SESSION_BUS_ADDRESS=unix:path=$XDG_RUNTIME_DIR/bus; ')


KEYRING_PROBE = r'''
from pathlib import Path
from gi.repository import Gio, GLib

bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
service = 'org.freedesktop.secrets'
base = '/org/freedesktop/secrets'
interface = 'org.freedesktop.Secret.'
def call(path, iface, method, signature=None, values=None):
    parameters = GLib.Variant(signature, values) if signature else None
    return bus.call_sync(service, path, iface, method, parameters, None,
                         Gio.DBusCallFlags.NONE, 10000, None).unpack()

# ReadAlias and Locked inspect state; do not call Unlock or answer a prompt.
collection, = call(base, interface + 'Service', 'ReadAlias', '(s)', ('login',))
assert collection != '/', 'PAM did not create the login keyring'
locked, = call(collection, 'org.freedesktop.DBus.Properties', 'Get', '(ss)',
               (interface + 'Collection', 'Locked'))
assert bool(locked) == (ACTION == 'locked'), 'Unexpected login-keyring lock state'
files = list((Path.home() / '.local/share/keyrings').glob('*.keyring'))
assert files, 'Persistent login keyring missing'
assert any(path.read_bytes().startswith(b'GnomeKeyring\n\r\0\n') for path in files), \
    'Encrypted binary keyring missing'
assert all(EXPECTED.encode() not in path.read_bytes() for path in files), \
    'Synthetic secret persisted as plaintext'
if ACTION == 'locked':
    print('Encrypted login keyring is locked; no unlock was attempted.')
    raise SystemExit(0)
if ACTION == 'lock':
    locked_paths, prompt = call(base, interface + 'Service', 'Lock', '(ao)', ([collection],))
    assert prompt == '/' and collection in locked_paths, 'Locking the synthetic collection requested interaction'
    locked, = call(collection, 'org.freedesktop.DBus.Properties', 'Get', '(ss)',
                   (interface + 'Collection', 'Locked'))
    assert locked, 'Synthetic login keyring did not lock'
    print('Synthetic login keyring locked before session teardown.')
    raise SystemExit(0)

_, session = call(base, interface + 'Service', 'OpenSession', '(sv)',
                  ('plain', GLib.Variant('s', '')))
attributes = {'cybexos-qualification': 'encrypted-login-roundtrip'}
try:
    if ACTION == 'create':
        properties = {
            interface + 'Item.Label': GLib.Variant('s', 'CybexOS disposable qualification'),
            interface + 'Item.Attributes': GLib.Variant('a{ss}', attributes),
        }
        _, prompt = call(collection, interface + 'Collection', 'CreateItem',
                         '(a{sv}(oayays)b)',
                         (properties, (session, b'', EXPECTED.encode(), 'text/plain'), True))
        assert prompt == '/', 'Creating a synthetic item requested interaction'
    unlocked, locked_items = call(base, interface + 'Service', 'SearchItems',
                                  '(a{ss})', (attributes,))
    assert len(unlocked) == 1 and not locked_items, 'Synthetic item is not unlocked'
    secret, = call(unlocked[0], interface + 'Item', 'GetSecret', '(o)', (session,))
    assert bytes(secret[2]) == EXPECTED.encode(), 'Synthetic item changed across login'
    if ACTION == 'delete':
        prompt, = call(unlocked[0], interface + 'Item', 'Delete')
        assert prompt == '/', 'Deleting a synthetic item requested interaction'
finally:
    call(session, interface + 'Session', 'Close')
print('Encrypted login keyring and synthetic secret passed without a prompt.')
'''


SESSION_STATE = r'''
import json, subprocess
def output(*argv):
    return subprocess.check_output(argv, text=True).strip()
sessions = []
for line in output('loginctl', 'list-sessions', '--no-legend', '--no-pager').splitlines():
    identifier = line.split()[0]
    try:
        detail = output('loginctl', 'show-session', identifier,
                        '-p', 'User', '-p', 'Name', '-p', 'Class', '-p', 'Type', '-p', 'State')
    except subprocess.CalledProcessError:
        continue  # A disappearing SSH session is expected during polling.
    value = dict(row.split('=', 1) for row in detail.splitlines())
    sessions.append(value)
print(json.dumps({
    'desktop': any(s.get('Name') == 'qualification' and s.get('Class') == 'user'
                   and s.get('Type') == 'wayland' and s.get('State') in ('active', 'online')
                   for s in sessions),
    'greeter': any(s.get('Class') == 'greeter' and s.get('State') in ('active', 'online')
                   for s in sessions),
    'sddm': subprocess.run(['systemctl', 'is-active', '--quiet', 'sddm.service']).returncode == 0,
}))
'''


LOGOUT = r'''
import os, re, subprocess
# SSH does not inherit the compositor environment. Import only the two values
# needed to address the actual graphical session, never execute shell exports.
raw = subprocess.check_output(['systemctl', '--user', 'show-environment'], text=True)
manager = dict(line.split('=', 1) for line in raw.splitlines() if '=' in line)
environment = dict(os.environ)
for name in ('HYPRLAND_INSTANCE_SIGNATURE', 'WAYLAND_DISPLAY'):
    value = manager.get(name, '')
    assert re.fullmatch(r'[A-Za-z0-9_.:/+-]+', value), 'Missing or invalid compositor environment'
    environment[name] = value
subprocess.run(['/usr/libexec/cybexos-session-action', 'logout'], env=environment, check=True)
'''


DISABLE_BOOT_CACHE = r'''
python3 - <<'PY'
from pathlib import Path
path = Path('/etc/pam.d/sddm-autologin')
# The backup must survive reboot. /run is tmpfs and cannot be renamed into
# /root, so create this nonsecret fixture backup directly on the root disk.
backup = Path('/root/cybexos-qualification-pam-backup')
assert not backup.exists()
original = path.read_bytes()
assert b'pam_systemd_loadkey.so' in original
backup.write_bytes(original)
backup.chmod(0o600)
lines = original.decode().splitlines(keepends=True)
path.write_text(''.join('# qualification-cache-unavailable ' + line
                        if 'pam_systemd_loadkey.so' in line and not line.lstrip().startswith('#')
                        else line for line in lines))
PY
'''


FAIL_FIRST_LAUNCH = r"""
python3 - <<'PY'
import os
from pathlib import Path
import tempfile
launcher = Path('/usr/bin/hyprland-quickshell')
backup = Path('/root/cybexos-qualification-launcher-backup')
marker = Path('/home/qualification/.local/state/cybexos/qualification-launch-failed')
assert launcher.is_file() and not launcher.is_symlink()
assert not backup.exists() and not marker.exists()
original = launcher.read_bytes()
assert original.startswith(b'#!/usr/bin/env bash\n')
backup.write_bytes(original)
backup.chmod(launcher.stat().st_mode & 0o777)
prefix = br'''#!/usr/bin/env bash
set -euo pipefail
# Disposable qualification fixture: fail before the real launcher once.
fixture_marker="${XDG_STATE_HOME:-$HOME/.local/state}/cybexos/qualification-launch-failed"
mkdir -p "$(dirname "$fixture_marker")"
if (set -C; printf '%s\n' first-autologin-failure > "$fixture_marker") 2>/dev/null; then
  exit 1
fi
'''
fd, name = tempfile.mkstemp(prefix='.cybexos-qualification-launcher-', dir=launcher.parent)
try:
    with os.fdopen(fd, 'wb') as stream:
        stream.write(prefix + original.split(b'\n', 1)[1])
        stream.flush()
        os.fchmod(stream.fileno(), launcher.stat().st_mode & 0o777)
        os.fsync(stream.fileno())
    os.replace(name, launcher)
finally:
    Path(name).unlink(missing_ok=True)
PY
restorecon /usr/bin/hyprland-quickshell
"""


RESTORE_LAUNCHER = r'''
if test -f /root/cybexos-qualification-launcher-backup; then
    cp -a /root/cybexos-qualification-launcher-backup /usr/bin/hyprland-quickshell.cybexos-qualification-restore
    mv -f /usr/bin/hyprland-quickshell.cybexos-qualification-restore /usr/bin/hyprland-quickshell
    restorecon /usr/bin/hyprland-quickshell
    rm /root/cybexos-qualification-launcher-backup
fi
rm -f /home/qualification/.local/state/cybexos/qualification-launch-failed
'''


FAILED_LAUNCH_STATE = r'''
import configparser, json, pwd, stat
from pathlib import Path
marker = Path('/home/qualification/.local/state/cybexos/qualification-launch-failed')
info = marker.lstat()
assert stat.S_ISREG(info.st_mode) and info.st_uid == pwd.getpwnam('qualification').pw_uid
assert marker.read_text() == 'first-autologin-failure\n', 'The injected launch failure did not run'
consumed = Path('/run/cybexos-login/autologin-used').lstat()
assert stat.S_ISREG(consumed.st_mode) and consumed.st_uid == 0 and consumed.st_mode & 0o777 == 0o600, \
    'The failed autologin did not consume its protected boot marker'
settings = configparser.ConfigParser()
settings.read('/etc/sddm.conf')
status = json.loads(Path('/run/cybexos-login/status.json').read_text())
if RESTARTED:
    assert settings.get('Autologin', 'User') == '', 'Manager restart re-enabled failed autologin'
    assert status['autologin'] is False and status['reason'] == 'autologin-already-used'
else:
    assert settings.get('Autologin', 'User') == 'qualification'
    assert status['autologin'] is True and status['reason'] == 'encrypted-root', \
        'The first login was not an encrypted-root autologin attempt'
'''


def user_script(vm, script, timeout=60):
    return run([*vm.ssh, USER_ENV + 'python3 -'], input=script, text=True,
               capture_output=True, timeout=timeout)


def keyring_probe(vm, action, secret):
    if action not in ('create', 'read', 'lock', 'locked', 'delete'):
        raise ValueError('Unknown keyring qualification action')
    script = 'ACTION = ' + repr(action) + '\nEXPECTED = ' + repr(secret) + '\n' + KEYRING_PROBE
    user_script(vm, script)


def wait_login_state(vm, desktop, timeout=90, stable_for=0):
    deadline, stable_since = time.monotonic() + timeout, None
    while time.monotonic() < deadline:
        vm.alive()
        state = json.loads(user_script(vm, SESSION_STATE).stdout)
        matched = state['sddm'] and state['desktop'] == desktop and (desktop or state['greeter'])
        if matched:
            if stable_since is None:
                stable_since = time.monotonic()
            if time.monotonic() - stable_since >= stable_for:
                return state
        else:
            stable_since = None
        time.sleep(1)
    raise RuntimeError('Installed login/session state did not settle as expected')


def reboot_installed(vm, password, root_script, expect_desktop=True):
    poweroff_guest(vm, password, root_script, timeout=60)
    vm.start(user='qualification')
    vm.unlock_disk(password)
    vm.wait_ssh(setup=False, redactions=(password,))
    if expect_desktop:
        vm.wait_desktop()
    wait_login_state(vm, desktop=expect_desktop, stable_for=0 if expect_desktop else 10)


def qualify_failed_autologin(vm, password, root_script, report, secret):
    """A failed first session must leave the greeter usable without another auto attempt."""
    try:
        root_script(vm, FAIL_FIRST_LAUNCH, password)
        reboot_installed(vm, password, root_script, expect_desktop=False)
        root_script(vm, "python3 - <<'PY'\nRESTARTED = False\n" + FAILED_LAUNCH_STATE + '\nPY\n', password)
        report['checks'].append('first-autologin-launch-failure-consumes-boot-attempt')
        root_script(vm, 'systemctl restart sddm.service\n', password)
        wait_login_state(vm, desktop=False, stable_for=10)
        root_script(vm, "python3 - <<'PY'\nRESTARTED = True\n" + FAILED_LAUNCH_STATE + '\nPY\n', password)
        report['checks'].append('failed-first-autologin-manager-restart-requires-authentication')
        time.sleep(2)
        vm.type(password + '\n')
        vm.wait_desktop()
        wait_login_state(vm, desktop=True)
        keyring_probe(vm, 'read', secret)
        vm.audit(applications=False)
        report['checks'].append('failed-first-autologin-password-login-recovers-desktop')
    finally:
        root_script(vm, RESTORE_LAUNCHER, password)


def qualify_login(vm, password, root_script, report, secret):
    """Exercise the actual installed manager and vault; stop on the first failure."""
    root_script(vm, 'systemctl enable sshd.service\nfirewall-cmd --permanent --add-service=ssh\n', password)
    wait_login_state(vm, desktop=True)
    keyring_probe(vm, 'create', secret)
    report['checks'].append('initial-encrypted-keyring-unlocked-without-prompt')
    reboot_installed(vm, password, root_script)
    keyring_probe(vm, 'read', secret)
    vm.audit(applications=False)
    report['checks'].append('synthetic-keyring-secret-survives-cold-reboot')

    for action in ('logout', 'compositor-crash', 'manager-restart'):
        # Run the shared mandatory audit before every deliberate session teardown.
        vm.audit(applications=False)
        # SSH can keep the user manager and an already-unlocked keyring alive.
        # Lock explicitly so the subsequent successful read proves that the
        # new password/PAM login unlocked it, rather than reusing old state.
        keyring_probe(vm, 'lock', secret)
        if action == 'manager-restart':
            root_script(vm, 'systemctl restart sddm.service\n', password)
        elif action == 'compositor-crash':
            # Limit the kill to the synthetic user's actual compositor processes.
            root_script(vm, 'pkill -KILL -u qualification -x Hyprland\n', password)
        else:
            user_script(vm, LOGOUT)
        wait_login_state(vm, desktop=False, stable_for=10)
        keyring_probe(vm, 'locked', secret)
        report['checks'].append(action + '-requires-authentication')
        # The embedded SDDM theme focuses the selected user's password input.
        # Verify the greeter state first, type once, and never retry blindly.
        time.sleep(2)
        vm.type(password + '\n')
        vm.wait_desktop()
        wait_login_state(vm, desktop=True)
        keyring_probe(vm, 'read', secret)
        vm.audit(applications=False)
        report['checks'].append(action + '-password-recovery-and-keyring')

    # Model an unavailable/expired boot-password cache without accessing its
    # contents or changing LUKS slots: disable only loadkey in this task-owned VM.
    root_script(vm, DISABLE_BOOT_CACHE, password)
    try:
        reboot_installed(vm, password, root_script)
        keyring_probe(vm, 'locked', secret)
        report['checks'].append('missing-cached-password-preserves-locked-encrypted-keyring')
    finally:
        root_script(vm, 'cp /root/cybexos-qualification-pam-backup /etc/pam.d/sddm-autologin\n'
                    'restorecon /etc/pam.d/sddm-autologin\n'
                    'rm /root/cybexos-qualification-pam-backup\n', password)
    # Exercise the ordinary password-login fallback with the original PAM stack.
    user_script(vm, LOGOUT)
    wait_login_state(vm, desktop=False, stable_for=5)
    keyring_probe(vm, 'locked', secret)
    vm.type(password + '\n')
    vm.wait_desktop()
    wait_login_state(vm, desktop=True)
    keyring_probe(vm, 'read', secret)
    vm.audit(applications=False)
    report['checks'].append('fallback-password-login-unlocks-existing-keyring')
    qualify_failed_autologin(vm, password, root_script, report, secret)
    keyring_probe(vm, 'delete', secret)
