"""Opt-in graphical installation and lifecycle qualification on disposable QEMU disks."""
import argparse
import json
from pathlib import Path
import secrets
import signal
import subprocess
import sys
import time

from build_support import atomic_json, digest
from browser_qualification import qualify_browser
from login_qualification import qualify_login
from upgrade_qualification import (create_recovery_point, prepare_user_choices, select_recovery_boot,
                                   upgrade, verify_recovery_boot, verify_restored, verify_user_choices)
from vm_testing import QUALIFICATION_DISK_SERIAL, QUALIFICATION_UNUSED_SERIAL, TestVM, require_test_iso, run


BACKEND = '/usr/libexec/cybexos-installer-backend'
SCENARIOS = {
    'encrypted-us': (True, 'us', 'en_US.UTF-8', 'UTC'),
    'plain-us': (False, 'us', 'en_US.UTF-8', 'UTC'),
    'encrypted-nl': (True, 'nl', 'nl_NL.UTF-8', 'Europe/Amsterdam'),
    'plain-nl': (False, 'nl', 'nl_NL.UTF-8', 'Europe/Amsterdam'),
    'encrypted-de': (True, 'de', 'de_DE.UTF-8', 'Europe/Berlin'),
    'plain-de': (False, 'de', 'de_DE.UTF-8', 'Europe/Berlin'),
}


def backend(vm, action, payload=None):
    result = run([*vm.ssh, f'sudo {BACKEND} {action}'], input=json.dumps(payload or {}), text=True, capture_output=True, timeout=120)
    responses = [json.loads(line) for line in result.stdout.splitlines() if line.strip()]
    results = [item for item in responses if item.get('event') == 'result']
    if not results or not results[-1].get('ok'):
        raise RuntimeError(f'Installer {action} failed without a successful result')
    return results[-1]['data']


def root_script(vm, script, password, timeout=120):
    # Password stays in memory/stdin and is never part of a command line or log.
    if subprocess.run([*vm.ssh, "sudo -k -n true"], capture_output=True, timeout=15).returncode == 0:
        return run([*vm.ssh, "sudo -n bash -e -s"], input=script, text=True, capture_output=True, timeout=timeout)
    return run([*vm.ssh, "sudo -k -S -p '' bash -e -s"], input=password + '\n' + script, text=True, capture_output=True, timeout=timeout)


INSTALLED_AUDIT = r'''
! getent passwd liveuser
for path in /etc/sudoers.d/cybexos-live /etc/polkit-1/rules.d/49-cybexos-live.rules /usr/lib/systemd/system/cybexos-live.service; do
  test ! -e "$path"
done
test "$(getenforce)" = Enforcing
test "$(findmnt -n -o FSTYPE /)" = btrfs
if [ "${EXPECTED_ENCRYPTED}" = true ]; then
  lsblk -s -n -o TYPE "$(findmnt -n -o SOURCE / | cut -d '[' -f 1)" | grep -qx crypt
else
  ! lsblk -s -n -o TYPE "$(findmnt -n -o SOURCE / | cut -d '[' -f 1)" | grep -qx crypt
fi
systemctl is-active --quiet sddm.service
test "$(systemctl show sddm.service -p KeyringMode --value)" = inherit
! rpm -q gdm >/dev/null
if [ "${REQUIRE_SECURE_SUDO}" = true ]; then
  grep -qx 'passwordless_wheel: false' /etc/cybexos/config.yml
  test ! -e /etc/sudoers.d/10-wheel-nopasswd
fi
python3 - <<'CHECK'
import configparser,json
import os
from pathlib import Path
encrypted=os.environ['EXPECTED_ENCRYPTED'] == 'true'
policy=json.loads(Path('/etc/cybexos/login.json').read_text())
assert policy == {'version':1, 'user':'qualification', 'autologin':encrypted, 'live':False}
config=configparser.ConfigParser()
config.read('/etc/sddm.conf')
assert config.get('Autologin','User',fallback='') == ('qualification' if encrypted else '')
if encrypted:
    assert config.get('Autologin','Session') == 'hyprland-quickshell.desktop'
    assert not config.getboolean('Autologin','Relogin')
marker=Path('/run/cybexos-login/autologin-used')
if encrypted:
    assert marker.exists() and marker.stat().st_uid == 0
    assert not marker.stat().st_mode & 0o077
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


def installed_audit(encrypted, require_secure_sudo):
    return (f'export EXPECTED_ENCRYPTED={str(encrypted).lower()}\n'
            f'export REQUIRE_SECURE_SUDO={str(require_secure_sudo).lower()}\n' + INSTALLED_AUDIT)


def qualification_disks(vm):
    output = run([*vm.ssh, 'lsblk -dn -o NAME,SERIAL'], text=True, capture_output=True, timeout=15).stdout
    devices = {}
    for line in output.splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[1] in (QUALIFICATION_DISK_SERIAL, QUALIFICATION_UNUSED_SERIAL):
            if parts[1] in devices:
                raise RuntimeError('Duplicate qualification disk serial in guest')
            devices[parts[1]] = parts[0]
    if set(devices) != {QUALIFICATION_DISK_SERIAL, QUALIFICATION_UNUSED_SERIAL}:
        raise RuntimeError('Both serial-identified disposable disks must be visible in the guest')
    return devices[QUALIFICATION_DISK_SERIAL], devices[QUALIFICATION_UNUSED_SERIAL]


def focus_installed_desktop(vm, password, encrypted):
    """Return from the verified text console to the graphical session."""
    from login_qualification import wait_login_state
    script = '''python3 - <<'PY'
import subprocess
for line in subprocess.check_output(['loginctl', 'list-sessions', '--no-legend', '--no-pager'], text=True).splitlines():
    identifier = line.split()[0]
    values = dict(item.split('=', 1) for item in subprocess.check_output(
        ['loginctl', 'show-session', identifier, '-p', 'Class', '-p', 'Name', '-p', 'Type', '-p', 'VTNr'], text=True).splitlines())
    if ((values.get('Class') == 'greeter' and not ENCRYPTED) or
            (values.get('Class') == 'user' and values.get('Name') == 'qualification' and
             values.get('Type') == 'wayland' and ENCRYPTED)) and values.get('VTNr', '').isdigit():
        print(values['VTNr'])
        raise SystemExit(0)
raise SystemExit(1)
PY
'''
    script = script.replace('import subprocess\n', f'import subprocess\nENCRYPTED = {encrypted!r}\n', 1)
    vt = int(run([*vm.ssh, 'bash -s'], input=script, text=True, capture_output=True,
                 timeout=20).stdout.strip())
    if not 1 <= vt <= 6:
        raise RuntimeError('Installed greeter was not on an expected virtual terminal')
    if not encrypted:
        wait_login_state(vm, desktop=False)
    vm.keypress(f'ctrl+alt+f{vt}')
    if encrypted:
        vm.wait_desktop()
        wait_login_state(vm, desktop=True)
        return
    time.sleep(2)
    vm.type(password + '\n')
    vm.wait_desktop()
    wait_login_state(vm, desktop=True)


def boot_installed(vm, password, encrypted):
    vm.start(user='qualification')
    if encrypted:
        vm.unlock_disk(password)
    try:
        vm.wait_ssh(timeout=12, setup=False)
    except RuntimeError:
        vm.bootstrap_installed_ssh(password)
    focus_installed_desktop(vm, password, encrypted)


def poweroff_installed(vm, password):
    root_script(vm, 'sync\nsystemctl poweroff --no-block\n', password)
    vm.ssh_ready = False
    vm.process.wait(timeout=90)
    if vm.console:
        vm.console.close()
        vm.console = None


def main():
    # Register here as well as direct module execution: image/qualify imports
    # this function, so module __main__ hooks alone do not protect cleanup.
    for name in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(name, interrupt)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('iso', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--firmware', choices=('uefi', 'bios'), default='uefi')
    parser.add_argument('--scenario', choices=tuple(SCENARIOS), default='encrypted-us')
    parser.add_argument('--candidate-rpm', type=Path, help='Newer desktop RPM for an offline N to N+1 upgrade')
    parser.add_argument('--recovery-check', action='store_true', help='Boot and restore the pre-upgrade recovery point')
    parser.add_argument('--legacy-installer', action='store_true', help='Permit baseline installer without new policy/rescan controls')
    parser.add_argument('--execute-vm', action='store_true')
    parser.add_argument('--erase-disposable-disk', action='store_true', help='Explicitly allow installation onto the new task-owned virtual disk')
    parser.add_argument('--keep-artifacts', action='store_true', help='Retain task-owned disk/logs for unresolved diagnostics')
    parser.add_argument('--install-timeout', type=int, default=1800)
    args = parser.parse_args()
    if not args.execute_vm or not args.erase_disposable_disk:
        parser.error('qualification requires --execute-vm --erase-disposable-disk; no VM or installer starts without both')
    if args.recovery_check and not args.candidate_rpm:
        parser.error('--recovery-check requires --candidate-rpm')
    iso = require_test_iso(args.iso)
    if args.candidate_rpm and (args.candidate_rpm.is_symlink() or not args.candidate_rpm.is_file()
                               or args.candidate_rpm.suffix != '.rpm'):
        parser.error('--candidate-rpm must be a regular .rpm file')
    encrypted, keyboard, locale, timezone = SCENARIOS[args.scenario]
    vm = TestVM(args.output, args.firmware, guard_disk=True)
    # Hex uses the same physical keys under US, NL and DE layouts, including
    # the early boot unlock and text-console bootstrap paths.
    password = secrets.token_hex(24)
    report = {'iso_sha256': digest(iso),
              'candidate_rpm_sha256': digest(args.candidate_rpm) if args.candidate_rpm else None,
              'scenario': args.scenario, 'firmware': args.firmware, 'status': 'failed', 'checks': [],
              'network': 'outbound-blocked', 'bootstrap': 'recognized disk-unlock prompt; bounded graphical SSH setup', 'scope': 'QEMU fixture; does not qualify physical hardware or Secure Boot'}
    try:
        vm.prepare()
        untouched_sha = digest(vm.unused_disk)
        vm.start(iso)
        vm.wait_ssh()
        if args.legacy_installer:
            # The retained N image deliberately starts an installer-only
            # session target in live mode. Activate its full desktop target
            # only in this disposable older guest for the shell/application
            # audit. New images must pass normal startup without this branch.
            live_shell = subprocess.run(
                [*vm.ssh, 'systemctl --user is-active --quiet quickshell.service'],
                capture_output=True, timeout=15)
            if live_shell.returncode:
                installer_only = subprocess.run(
                    [*vm.ssh, 'test -e /run/cybexos-install-mode && '
                     'systemctl --user is-active --quiet cybexos-install-session.target'],
                    capture_output=True, timeout=15)
                if installer_only.returncode:
                    raise RuntimeError('Legacy guest shell is inactive outside the expected installer-only session')
                run([*vm.ssh, 'systemctl --user start hyprland-session.target'], timeout=30)
                report['legacy_session_bootstrap'] = 'activated full desktop target from baseline installer-only session'
                report['checks'].append('legacy-installer-only-session-desktop-bootstrap')
        vm.audit()
        report['checks'].append('live-boot-and-offline-applications')
        target_disk, unused_disk = qualification_disks(vm)
        run([*vm.ssh, 'XDG_RUNTIME_DIR=/run/user/1000 systemd-run --user --collect --unit=cybexos-qualification-anaconda /usr/bin/liveinst --nosave=all_ks'])
        qualify_browser(vm, password=password, target_disk=target_disk, unused_disk=unused_disk,
                        encrypted=encrypted, keyboard=keyboard, locale=locale, timezone=timezone,
                        install_timeout=args.install_timeout, require_policy_controls=not args.legacy_installer)
        report['checks'].append('graphical-installer')
        report['checks'].append('encrypted-installation' if encrypted else 'plain-installation')
        # Audit live state before a graceful shutdown; target mounts are left
        # to Anaconda/systemd. Do not assume /mnt/sysroot survives completion.
        vm.audit(applications=False)
        vm.stop(graceful=True)
        if digest(vm.unused_disk) != untouched_sha:
            raise RuntimeError('The unused disposable guard disk changed during installation')
        report['checks'].append('unused-disk-unchanged')
        (vm.work / 'known_hosts').unlink(missing_ok=True)
        boot_installed(vm, password, encrypted)  # No ISO/CD-ROM attached.
        vm.audit()
        root_script(vm, installed_audit(encrypted, not args.legacy_installer), password)
        report['checks'] += ['installed-boot-without-iso', 'encrypted-btrfs' if encrypted else 'plain-btrfs',
                             'autologin' if encrypted else 'password-login', 'desktop-parity', 'live-cleanup', 'selinux-enforcing']
        if not args.legacy_installer:
            sudo = subprocess.run([*vm.ssh, 'sudo -k -n true'], capture_output=True, timeout=15)
            if sudo.returncode == 0:
                raise RuntimeError('Fresh installation unexpectedly allows passwordless sudo')
            report['checks'].append('sudo-requires-password')
        if encrypted and not args.candidate_rpm:
            qualify_login(vm, password, root_script, report, secrets.token_urlsafe(32))
        if args.candidate_rpm:
            preference = prepare_user_choices(vm, password, root_script)
            point = create_recovery_point(vm, password, root_script) if args.recovery_check else None
            sha, versions = upgrade(vm, args.candidate_rpm, password, root_script)
            if sha != report['candidate_rpm_sha256']:
                raise RuntimeError('Candidate RPM checksum changed during qualification')
            report['checks'].append('installed-rpm-upgrade')
            verify_user_choices(vm, password, root_script, preference)
            if point:
                select_recovery_boot(vm, point, password, root_script)
                poweroff_installed(vm, password)
                boot_installed(vm, password, encrypted)
                verify_recovery_boot(vm, point, password, root_script)
                poweroff_installed(vm, password)
                boot_installed(vm, password, encrypted)
                verify_restored(vm, versions['installed'], password, root_script)
                verify_user_choices(vm, password, root_script, preference)
                report['checks'].append('recovery-boot-restore')
        # Clear the temporary test access before stopping the disposable disk.
        vm.audit(applications=False)
        root_script(vm, 'rm -f /home/qualification/.ssh/authorized_keys /home/qualification/.bash_history\nsystemctl disable sshd.service\nsync\nsystemctl poweroff --no-block\n', password)
        vm.ssh_ready = False
        vm.process.wait(timeout=60)
        if digest(vm.unused_disk) != untouched_sha:
            raise RuntimeError('The unused disposable guard disk changed after installed boot')
        report['status'] = 'passed'
    except BaseException as error:
        report['error'] = str(error) or type(error).__name__
        raise
    finally:
        if vm.owned:
            failed_before_cleanup = sys.exc_info()[0] is not None
            try:
                vm.cleanup(args.keep_artifacts)
            except BaseException as cleanup_error:
                report['status'] = 'failed'
                report['cleanup_error'] = str(cleanup_error) or type(cleanup_error).__name__
                if not failed_before_cleanup:
                    raise
            finally:
                atomic_json(args.output / 'qualification.json', report)
    print(f"Qualification passed: {args.output / 'qualification.json'}")


def interrupt(_signum, _frame):
    raise KeyboardInterrupt


if __name__ == '__main__':
    main()
