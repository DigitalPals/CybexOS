"""Opt-in full installation qualification on one newly created QEMU disk."""
import argparse
import json
from pathlib import Path
import secrets
import signal
import subprocess
import time

from build_support import atomic_json, digest
from vm_testing import TestVM, require_test_iso, run


BACKEND = '/usr/libexec/cybexos-installer-backend'


def backend(vm, action, payload=None):
    result = run([*vm.ssh, f'sudo {BACKEND} {action}'], input=json.dumps(payload or {}), text=True, capture_output=True, timeout=120)
    responses = [json.loads(line) for line in result.stdout.splitlines() if line.strip()]
    results = [item for item in responses if item.get('event') == 'result']
    if not results or not results[-1].get('ok'):
        raise RuntimeError(f'Installer {action} failed without a successful result')
    return results[-1]['data']


def root_script(vm, script, password):
    # Password stays in memory/stdin and is never part of a command line or log.
    return run([*vm.ssh, "sudo -k -S -p '' bash -e -s"], input=password + '\n' + script, text=True, capture_output=True, timeout=120)


def wait_install(vm, timeout):
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        state = backend(vm, 'status')
        phase = state.get('phase')
        if phase == 'complete':
            return state
        if phase in ('failed', 'failed-install'):
            raise RuntimeError('Installer reported failure; inspect its secret-free state and journal')
        status = (phase, state.get('step'), state.get('message'))
        if status != last:
            print(f'Installer: {status}', flush=True)
            last = status
        vm.alive()
        time.sleep(2)
    raise RuntimeError('Installer completion deadline exceeded')


INSTALLED_AUDIT = r'''
! getent passwd liveuser
for path in /etc/sudoers.d/cybexos-live /etc/polkit-1/rules.d/49-cybexos-live.rules /usr/lib/systemd/system/cybexos-live.service; do
  test ! -e "$path"
done
test "$(getenforce)" = Enforcing
test "$(findmnt -n -o FSTYPE /)" = btrfs
lsblk -s -n -o TYPE "$(findmnt -n -o SOURCE / | cut -d '[' -f 1)" | grep -qx crypt
python3 - <<'CHECK'
import configparser,json
from pathlib import Path
config=configparser.ConfigParser()
config.read('/etc/gdm/custom.conf')
assert config.getboolean('daemon','AutomaticLoginEnable')
assert config.get('daemon','AutomaticLogin') == 'qualification'
plymouth=configparser.ConfigParser()
plymouth.read('/etc/plymouth/plymouthd.conf')
assert plymouth.get('Daemon','Theme') == 'cybex'
contract=json.loads(Path('/usr/share/cybexos/desktop-contract.json').read_text())
settings=json.loads(Path('/home/qualification/.config/cybexos/shell.json').read_text())
for key,value in contract['shell'].items():
    assert settings.get(key) == value, f'Desktop default mismatch: {key}'
assert not Path('/home/qualification/.config/cybexos/hypr/user.lua').exists()
assert Path('/home/qualification/.local/state/cybexos/offline-apps-seeded').exists()
CHECK
'''


def main():
    # Register here as well as direct module execution: image/qualify imports
    # this function, so module __main__ hooks alone do not protect cleanup.
    for name in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(name, interrupt)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('iso', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--firmware', choices=('uefi', 'bios'), default='uefi')
    parser.add_argument('--execute-vm', action='store_true')
    parser.add_argument('--erase-disposable-disk', action='store_true', help='Explicitly allow installation onto the new task-owned virtual disk')
    parser.add_argument('--keep-artifacts', action='store_true', help='Retain task-owned disk/logs for unresolved diagnostics')
    parser.add_argument('--install-timeout', type=int, default=1800)
    args = parser.parse_args()
    if not args.execute_vm or not args.erase_disposable_disk:
        parser.error('qualification requires --execute-vm --erase-disposable-disk; no VM or installer starts without both')
    iso = require_test_iso(args.iso)
    vm = TestVM(args.output, args.firmware)
    password = secrets.token_urlsafe(24)
    report = {'iso_sha256': digest(iso), 'firmware': args.firmware, 'status': 'failed', 'checks': [],
              'network': 'outbound-blocked', 'bootstrap': 'bounded graphical keyboard retries; no prompt recognition', 'scope': 'QEMU fixture; does not qualify physical hardware or Secure Boot'}
    try:
        vm.prepare()
        vm.start(iso)
        vm.wait_ssh()
        vm.audit()
        report['checks'].append('live-boot-and-offline-applications')
        serial = run([*vm.ssh, 'lsblk -dn -o SERIAL /dev/vda'], text=True, capture_output=True).stdout.strip()
        if serial != 'CYBEXOS-QUALIFICATION':
            raise RuntimeError('Refusing installation: guest target is not the newly created qualification disk')
        run([*vm.ssh, 'XDG_RUNTIME_DIR=/run/user/1000 systemd-run --user --collect --unit=cybexos-qualification-anaconda /usr/bin/liveinst --nosave=all_ks'])
        deadline = time.monotonic() + 120
        while True:
            try:
                backend(vm, 'inventory')
                break
            except (RuntimeError, subprocess.CalledProcessError):
                if time.monotonic() >= deadline:
                    raise RuntimeError('Anaconda backend readiness timed out') from None
                time.sleep(2)
        plan = backend(vm, 'plan', {'username': 'qualification', 'password': password, 'confirm': password,
                                   'keyboard': 'us', 'locale': 'en_US.UTF-8', 'timezone': 'UTC', 'hostname': 'cybexos-test',
                                   'disk': 'vda', 'encrypted': True})
        if plan.get('disk', {}).get('name') != 'vda' or not plan.get('token'):
            raise RuntimeError('Installer plan did not confirm the disposable target')
        backend(vm, 'install', {'token': plan['token'], 'confirmed_disk': 'vda', 'erase_confirmed': True})
        wait_install(vm, args.install_timeout)
        report['checks'].append('encrypted-installation')
        # Audit live state before a graceful shutdown; target mounts are left
        # to Anaconda/systemd. Do not assume /mnt/sysroot survives completion.
        vm.audit(applications=False)
        vm.stop(graceful=True)
        (vm.work / 'known_hosts').unlink(missing_ok=True)
        vm.start(user='qualification')  # Intentionally no ISO/CD-ROM attached.
        deadline = time.monotonic() + 300
        while time.monotonic() < deadline:
            vm.alive()
            if vm.qmp_path.exists():
                vm.type(password + '\n')
                try:
                    vm.wait_ssh(timeout=20, setup_password=password)
                    break
                except RuntimeError:
                    pass
            time.sleep(2)
        else:
            raise RuntimeError('Encrypted installed boot/autologin did not become ready')
        vm.audit()
        root_script(vm, INSTALLED_AUDIT, password)
        report['checks'] += ['installed-boot-without-iso', 'encrypted-btrfs', 'autologin', 'desktop-parity', 'live-cleanup', 'selinux-enforcing']
        # Clear the temporary test access before stopping the disposable disk.
        vm.audit(applications=False)
        root_script(vm, 'rm -f /home/qualification/.ssh/authorized_keys /home/qualification/.bash_history\nsystemctl disable sshd.service\nsync\nsystemctl poweroff --no-block\n', password)
        vm.ssh_ready = False
        vm.process.wait(timeout=60)
        report['status'] = 'passed'
    except BaseException as error:
        report['error'] = str(error) or type(error).__name__
        raise
    finally:
        if vm.owned:
            try:
                vm.cleanup(args.keep_artifacts)
            except BaseException:
                report['status'] = 'failed'
                raise
            finally:
                atomic_json(args.output / 'qualification.json', report)
    print(f"Qualification passed: {args.output / 'qualification.json'}")


def interrupt(_signum, _frame):
    raise KeyboardInterrupt


if __name__ == '__main__':
    main()
