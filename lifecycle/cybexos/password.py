"""Coordinated local account/LUKS password changes for fresh Cybex OS installs."""
import ctypes
import fcntl
import hmac
import json
import os
from pathlib import Path
import pwd
import subprocess
from contextlib import contextmanager

from .common import Failure, atomic, read
from .credentials import validate_password

TRANSACTION = Path('/var/lib/cybexos/password-change.json')


def command(*args, input=None, pass_fds=()):
    # Neither input nor child diagnostics may appear in a journal or response.
    result = subprocess.run(args, input=input, pass_fds=pass_fds, capture_output=True, timeout=120)
    if result.returncode:
        raise Failure('The password operation could not be completed')
    return result.stdout


@contextmanager
def key_input(value):
    # Anonymous RAM-backed descriptors avoid plaintext files and argv. The
    # size is bounded by the shared policy before any child is started.
    descriptor = os.memfd_create('cybexos-password', os.MFD_CLOEXEC)
    try:
        os.write(descriptor, value.encode())
        os.lseek(descriptor, 0, os.SEEK_SET)
        yield descriptor, '/proc/self/fd/' + str(descriptor)
    finally:
        os.close(descriptor)


def crypt_hash(password, setting):
    library = ctypes.CDLL(os.environ['CYBEXOS_LIBCRYPT'])
    library.crypt.argtypes = [ctypes.c_char_p, ctypes.c_char_p]
    library.crypt.restype = ctypes.c_char_p
    value = library.crypt(password.encode(), setting.encode())
    if not value or value.startswith(b'*'):
        raise Failure('The account password could not be verified')
    return value.decode()


def account_hash(user):
    account = command('getent', 'shadow', user).decode().strip().split(':')
    if len(account) < 2 or account[0] != user:
        raise Failure('The account password could not be verified')
    return account[1]


def matches(password, setting):
    return hmac.compare_digest(crypt_hash(password, setting), setting)


def root_luks():
    source = command('findmnt', '-n', '-o', 'SOURCE', '--target', '/').decode().strip().split('[')[0]
    tree = json.loads(command('lsblk', '--json', '--inverse', '--paths', '--output', 'NAME,TYPE,FSTYPE', source))
    devices = []
    def walk(node):
        if node.get('fstype') == 'crypto_LUKS':
            devices.append(node['name'])
        for child in node.get('children', []):
            walk(child)
    for node in tree['blockdevices']:
        walk(node)
    if len(set(devices)) != 1:
        raise Failure('The installed root disk is not a single supported LUKS device. No password was changed')
    return devices[0]


def matching_slot(device, password):
    metadata = json.loads(command('cryptsetup', 'luksDump', '--dump-json-metadata', device))
    for slot in sorted(metadata['keyslots'], key=int):
        with key_input(password) as (descriptor, path):
            result = subprocess.run(['cryptsetup', 'open', '--test-passphrase', '--key-slot', slot,
                                     '--key-file', path, device], pass_fds=(descriptor,),
                                    capture_output=True, timeout=120)
        if result.returncode == 0:
            return slot
    raise Failure('The current password did not unlock the disk. No password was changed')


def add_disk_key(device, slot, old, new):
    with key_input(old) as (old_fd, old_path), key_input(new) as (new_fd, new_path):
        command('cryptsetup', 'luksAddKey', '--batch-mode', '--new-key-slot', slot,
                '--key-file', old_path, device, new_path, pass_fds=(old_fd, new_fd))


def remove_disk_key(device, slot, password):
    with key_input(password) as (descriptor, path):
        command('cryptsetup', 'luksKillSlot', '--batch-mode', '--key-file', path,
                device, slot, pass_fds=(descriptor,))


def recover_disk_change(user, device, current):
    pending = read(TRANSACTION)
    if not pending:
        return
    if pending.get('username') != user or pending.get('device') != device:
        raise Failure('An interrupted password change belongs to another account or disk. No password was changed')
    # The current shadow password identifies which side of an interrupted
    # operation committed. No key material is persisted in this recovery file.
    slot = matching_slot(device, current)
    metadata = json.loads(command('cryptsetup', 'luksDump', '--dump-json-metadata', device))
    unwanted = pending['oldSlot'] if slot == pending['newSlot'] else pending['newSlot']
    if slot not in (pending['oldSlot'], pending['newSlot']):
        raise Failure('The interrupted disk password change needs manual recovery. No password was changed')
    if unwanted in metadata['keyslots']:
        remove_disk_key(device, unwanted, current)
    TRANSACTION.unlink()


def change(user, current, new, *, metadata=None):
    validate_password(new)
    if not isinstance(current, str) or not current or len(current.encode()) > 4096 or any(c in current for c in ('\x00', '\n', '\r')):
        raise Failure('Enter your current password')
    metadata = read('/var/lib/cybexos/installation.json', {}) if metadata is None else metadata
    if metadata.get('username') != user or metadata.get('sharedPassword') is not True:
        raise Failure('This account has no Cybex OS installation password record. No password was changed')
    if not matches(current, account_hash(user)):
        raise Failure('The current login password is incorrect. No password was changed')
    device, slot, new_slot = None, None, None
    if metadata.get('encrypted'):
        device = root_luks()
        recover_disk_change(user, device, current)
        slot = matching_slot(device, current)
    if current == new:
        return {'success': True, 'message': 'Your password is already set to this value.'}
    if device:
        slots = json.loads(command('cryptsetup', 'luksDump', '--dump-json-metadata', device))['keyslots']
        new_slot = next((str(n) for n in range(32) if str(n) not in slots), None)
        if new_slot is None:
            raise Failure('The disk has no free password slot. No password was changed')
        atomic(TRANSACTION, {'username': user, 'device': device, 'oldSlot': slot, 'newSlot': new_slot})
        # Keep the old key until PAM commits. A crash at any point leaves a
        # disk key that matches the login password; retry finishes cleanup.
        add_disk_key(device, new_slot, current, new)
    integration_failed = False
    try:
        # passwd's ordinary PAM conversation also updates the login keyring.
        # Only the installed setuid wrapper receives this private input; the
        # GUI never runs with elevated privileges or repeats the new field.
        # pkexec deliberately omits the desktop environment. The keyring PAM
        # module needs this user's control socket to change the existing
        # login keyring rather than silently leaving its old password behind.
        runtime = '/run/user/' + str(pwd.getpwnam(user).pw_uid)
        command('runuser', '-u', user, '--', 'env',
                'XDG_RUNTIME_DIR=' + runtime, 'GNOME_KEYRING_CONTROL=' + runtime + '/keyring',
                '/run/wrappers/bin/passwd',
                input=(current + '\n' + new + '\n' + new + '\n').encode())
    except BaseException:
        try:
            setting = account_hash(user)
            committed, retained = matches(new, setting), matches(current, setting)
        except Exception:
            committed, retained = False, False
        if committed:
            # passwd may be interrupted after writing shadow. Keep the disk
            # key matching that committed credential, even on a child error.
            integration_failed = True
        elif not retained:
            raise Failure('The account password could not be rechecked. Verify your login password, then retry to finish password-change recovery') from None
        else:
            if device:
                try:
                    remove_disk_key(device, new_slot, current)
                    TRANSACTION.unlink()
                except Exception:
                    raise Failure('The login password is unchanged and still unlocks the disk. Retry this password change to finish cleaning up its additional disk key') from None
            raise Failure('The password change failed. Your previous password was retained') from None
    if device:
        try:
            remove_disk_key(device, slot, new)
            TRANSACTION.unlink()
        except Exception:
            raise Failure('Your new login password also unlocks the disk, but the previous disk key could not be removed. Retry using your new password to finish cleanup') from None
    if integration_failed:
        raise Failure('Your new password was set' + (' for login and disk unlock' if device else ' for login')
                      + ', but password integration did not finish. Keep the previous password for any login-keyring recovery')
    return {'success': True, 'message': 'Your login and disk password have been changed.' if device else 'Your login password has been changed.'}


def main():
    os.umask(0o077)
    if os.geteuid() != 0 or not os.environ.get('PKEXEC_UID') or Path('/etc/cybexos/installer').exists():
        raise Failure('Password changes require authorization from an installed desktop session')
    uid = int(os.environ['PKEXEC_UID'])
    if uid == 0:
        raise Failure('Select your normal desktop account')
    user = pwd.getpwuid(uid).pw_name
    request = json.loads(__import__('sys').stdin.read(16385))
    if not isinstance(request, dict) or set(request) != {'current', 'new'}:
        raise Failure('Invalid password change request')
    with open('/run/cybexos-password.lock', 'a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise Failure('Another password change is in progress') from None
        result = change(user, request['current'], request['new'])
    request.clear()
    print(json.dumps(result))
