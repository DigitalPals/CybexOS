#!/usr/bin/env python3
"""NVIDIA helper behavior against a fixture sysfs and stubbed system tools.

No real driver, mokutil, akmods, dnf or GPU is touched: every command the
helper runs is a stub in PATH that records its arguments, and every absolute
path is redirected to a fixture root with CYBEXOS_NVIDIA_ROOT.
"""
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / 'roles/nvidia/files/cybexos-nvidia'
KERNEL = '6.17.4-300.fc44.x86_64'

# Each stub logs "name args" and answers from fixture files under $FIXTURE.
STUBS = {
    'mokutil': r'''
        printf 'mokutil %s\n' "$*" >>"$FIXTURE/calls"
        case $1 in
          --sb-state) cat "$FIXTURE/sb-state" 2>/dev/null || echo 'SecureBoot disabled' ;;
          --test-key) printf '%s %s\n' "$2" "$(cat "$FIXTURE/key-state" 2>/dev/null || echo 'is not enrolled')"
                      [[ $(cat "$FIXTURE/key-state" 2>/dev/null) == 'is not enrolled' ]] && exit 1; exit 0 ;;
          --generate-hash=*) echo '$6$salt$hash' ;;
          --import) cp "$4" "$FIXTURE/imported-hash"; echo 'is already in the enrollment request' >"$FIXTURE/key-state" ;;
        esac
    ''',
    'akmods': r'''
        printf 'akmods %s\n' "$*" >>"$FIXTURE/calls"
        if [[ -e $FIXTURE/build-fails ]]; then
          mkdir -p "$NVROOT/var/cache/akmods/nvidia"
          echo failed >"$NVROOT/var/cache/akmods/nvidia/615.78-1.fc44-for-$2.failed.log"
          exit 1
        fi
        echo 615.78.08 >"$FIXTURE/module-version"
    ''',
    'modinfo': r'''
        printf 'modinfo %s\n' "$*" >>"$FIXTURE/calls"
        [[ -s $FIXTURE/module-version ]] || { echo 'modinfo: ERROR: Module nvidia not found.' >&2; exit 1; }
        case $4 in
          version) cat "$FIXTURE/module-version" ;;
          signer) cat "$FIXTURE/signer" 2>/dev/null || true ;;
        esac
    ''',
    'rpm': r'''
        printf 'rpm %s\n' "$*" >>"$FIXTURE/calls"
        [[ ! -e $FIXTURE/no-headers ]]
    ''',
    'grubby': r'''printf 'grubby %s\n' "$*" >>"$FIXTURE/calls"''',
    'kmodgenca': r'''
        printf 'kmodgenca %s\n' "$*" >>"$FIXTURE/calls"
        mkdir -p "$NVROOT/etc/pki/akmods/certs"; printf 'generated-key' >"$NVROOT/etc/pki/akmods/certs/public_key.der"
    ''',
    'notify-send': r'''printf '%s\n' "$@" >>"$FIXTURE/notifications"; printf 'notify-send\n' >>"$FIXTURE/calls"''',
}


class Fixture:
    def __init__(self, directory):
        self.base = Path(directory)
        self.root = self.base / 'root'
        self.fixture = self.base / 'fixture'
        self.bin = self.base / 'bin'
        self.runtime = self.base / 'runtime'
        for path in (self.root, self.fixture, self.bin, self.runtime):
            path.mkdir(parents=True)
        for name, body in STUBS.items():
            script = self.bin / name
            script.write_text('#!/bin/bash\n' + textwrap.dedent(body))
            script.chmod(0o755)
        self.boot('boot-one')

    def boot(self, value):
        path = self.root / 'proc/sys/kernel/random/boot_id'
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(value + '\n')

    def gpu(self, slot, vendor, device, pci_class, boot_vga=None, driver=None):
        path = self.root / 'sys/bus/pci/devices' / slot
        path.mkdir(parents=True)
        (path / 'vendor').write_text(f'0x{vendor}\n')
        (path / 'device').write_text(f'0x{device}\n')
        (path / 'class').write_text(f'0x{pci_class}\n')
        if boot_vga is not None:
            (path / 'boot_vga').write_text('1\n' if boot_vga else '0\n')
        if driver:
            target = self.root / 'sys/bus/pci/drivers' / driver
            target.mkdir(parents=True, exist_ok=True)
            (path / 'driver').symlink_to(target)

    def write(self, name, text):
        (self.fixture / name).write_text(text)

    def loaded(self, modeset='Y', fbdev='Y'):
        (self.root / 'sys/module/nvidia').mkdir(parents=True, exist_ok=True)
        parameters = self.root / 'sys/module/nvidia_drm/parameters'
        parameters.mkdir(parents=True, exist_ok=True)
        (parameters / 'modeset').write_text(modeset + '\n')
        (parameters / 'fbdev').write_text(fbdev + '\n')

    def key(self, data=b'akmods-public-key'):
        key = self.root / 'etc/pki/akmods/certs/public_key.der'
        key.parent.mkdir(parents=True, exist_ok=True)
        key.write_bytes(data)

    def run(self, *argv, check=True):
        environment = {'PATH': f'{self.bin}:/usr/bin:/bin', 'CYBEXOS_NVIDIA_ROOT': str(self.root),
                       'NVROOT': str(self.root), 'FIXTURE': str(self.fixture), 'HOME': str(self.base),
                       'XDG_RUNTIME_DIR': str(self.runtime), 'PYTHONDONTWRITEBYTECODE': '1'}
        result = subprocess.run(['python3', str(HELPER), *argv], env=environment, text=True,
                                capture_output=True, timeout=60)
        if check:
            assert result.returncode == 0, result.stdout + result.stderr
        return result

    def apply(self, *extra):
        output = self.run('apply', '--kernel', KERNEL, '--retry', 'cybex repair --hardware', *extra).stdout
        return json.loads(output)

    def calls(self):
        path = self.fixture / 'calls'
        return path.read_text().splitlines() if path.exists() else []

    def status(self):
        return json.loads((self.root / 'var/lib/cybexos/nvidia-status.json').read_text())

    @property
    def enrollment(self):
        return self.root / 'var/lib/cybexos/nvidia-mok.json'


class Detection(unittest.TestCase):
    def test_nvidia_only_desktop_is_not_hybrid(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = Fixture(directory)
            fixture.gpu('0000:01:00.0', '10de', '2684', '030000', boot_vga=True, driver='nouveau')
            # The GPU's HDMI audio function shares the vendor but is class 0403.
            fixture.gpu('0000:01:00.1', '10de', '22ba', '040300')
            result = json.loads(fixture.run('detect').stdout)
            self.assertTrue(result['present'])
            self.assertFalse(result['hybrid'])
            self.assertEqual(result['primary'], 'nvidia')
            self.assertEqual([gpu['slot'] for gpu in result['gpus']], ['0000:01:00.0'])
            self.assertEqual(result['gpus'][0]['driver'], 'nouveau')

    def test_intel_and_amd_laptops_with_a_3d_controller_are_hybrid(self):
        for vendor, name in (('8086', 'intel'), ('1002', 'amd')):
            with self.subTest(vendor=name), tempfile.TemporaryDirectory() as directory:
                fixture = Fixture(directory)
                fixture.gpu('0000:00:02.0', vendor, '7d55', '030000', boot_vga=True)
                fixture.gpu('0000:01:00.0', '10de', '28a0', '030200', boot_vga=False)
                result = json.loads(fixture.run('detect').stdout)
                self.assertTrue(result['present'])
                self.assertTrue(result['hybrid'])
                self.assertEqual(result['primary'], name, 'the integrated GPU stays the renderer')

    def test_machines_without_nvidia_are_absent_and_untouched(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = Fixture(directory)
            fixture.gpu('0000:00:02.0', '8086', '7d55', '030000', boot_vga=True)
            self.assertFalse(json.loads(fixture.run('detect').stdout)['present'])
            self.assertEqual(fixture.apply()['state'], 'absent')
            self.assertFalse(any(call.startswith(('akmods', 'mokutil', 'grubby')) for call in fixture.calls()))

    def test_empty_sysfs_is_absent(self):
        with tempfile.TemporaryDirectory() as directory:
            result = json.loads(Fixture(directory).run('detect').stdout)
            self.assertEqual(result, {'present': False, 'hybrid': False, 'primary': '', 'gpus': []})


class DriverWithoutSecureBoot(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.fixture = Fixture(self.directory.name)
        self.fixture.gpu('0000:01:00.0', '10de', '2684', '030000', boot_vga=True)

    def test_built_driver_waits_for_a_restart_then_is_ready(self):
        status = self.fixture.apply('--force')
        self.assertEqual(status['state'], 'reboot')
        self.assertTrue(status['changed'])
        self.assertEqual(status['driver_version'], '615.78.08')
        self.assertEqual(status['secure_boot'], 'disabled')
        self.assertIn(f'akmods --kernels {KERNEL} --akmod nvidia', self.fixture.calls())
        self.fixture.boot('boot-two')
        self.fixture.loaded()
        status = self.fixture.apply()
        self.assertEqual(status['state'], 'ready')
        self.assertFalse(any(call.startswith('grubby') for call in self.fixture.calls()),
                         'driver 560+ already enables modeset and fbdev')
        self.assertFalse(self.fixture.apply()['changed'])

    def test_a_driver_that_does_not_load_after_a_restart_is_a_visible_failure(self):
        self.assertEqual(self.fixture.apply()['state'], 'reboot')
        # Same boot: still waiting for the restart.
        self.assertEqual(self.fixture.apply()['state'], 'reboot')
        self.fixture.boot('boot-two')
        status = self.fixture.apply()
        self.assertEqual(status['state'], 'failed')
        self.assertIn('open-source driver is in use', status['reason'])

    def test_disabled_modeset_is_enabled_through_kernel_arguments(self):
        self.fixture.loaded(modeset='N', fbdev='N')
        status = self.fixture.apply()
        self.assertEqual(status['state'], 'reboot')
        self.assertIn('grubby --update-kernel=ALL --args=nvidia-drm.modeset=1 nvidia-drm.fbdev=1',
                      self.fixture.calls())

    def test_an_explicit_modeset_choice_on_the_command_line_is_kept(self):
        self.fixture.loaded(modeset='N', fbdev='Y')
        (self.fixture.root / 'proc/cmdline').write_text('root=UUID=x rhgb nvidia-drm.modeset=0\n')
        self.assertEqual(self.fixture.apply()['state'], 'ready')
        self.assertFalse(any(call.startswith('grubby') for call in self.fixture.calls()))

    def test_build_failure_is_recorded_with_the_akmods_log(self):
        self.fixture.write('build-fails', '')
        status = self.fixture.apply()
        self.assertEqual(status['state'], 'failed')
        self.assertIn(f'/var/cache/akmods/nvidia/615.78-1.fc44-for-{KERNEL}.failed.log', status['reason'])
        self.assertIn('cybex repair --hardware', status['reason'])
        self.assertEqual(self.fixture.status()['state'], 'failed')

    def test_retired_kernel_headers_explain_the_remedy(self):
        self.fixture.write('no-headers', '')
        status = self.fixture.apply()
        self.assertEqual(status['state'], 'failed')
        self.assertIn('kernel headers', status['reason'])
        self.assertFalse(any(call.startswith('akmods') for call in self.fixture.calls()))

    def test_package_failures_are_recorded_without_running_the_build(self):
        output = self.fixture.run('record-failure', '--kernel', KERNEL, '--retry', 'cybex install',
                                  '--reason', 'Install the NVIDIA driver failed').stdout
        status = json.loads(output)
        self.assertEqual(status['state'], 'failed')
        self.assertEqual(status['reason'], 'Install the NVIDIA driver failed. The open-source driver '
                                           'stays in use; run cybex install to try again.')
        self.assertEqual(self.fixture.calls(), [])


class DriverWithSecureBoot(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.fixture = Fixture(self.directory.name)
        self.fixture.gpu('0000:00:02.0', '8086', '7d55', '030000', boot_vga=True)
        self.fixture.gpu('0000:01:00.0', '10de', '28a0', '030200', boot_vga=False)
        self.fixture.write('sb-state', 'SecureBoot enabled\n')
        self.fixture.write('signer', 'thebeast_1760000000_abcd\n')
        self.fixture.key()

    def test_prepare_creates_the_akmods_key_only_when_missing(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = Fixture(directory)
            self.assertIn('created', fixture.run('prepare').stdout)
            self.assertEqual(fixture.run('prepare').stdout, '')
            self.assertEqual([call for call in fixture.calls() if call.startswith('kmodgenca')], ['kmodgenca -a'])

    def test_unenrolled_key_is_queued_with_a_digit_password_kept_out_of_status(self):
        status = self.fixture.apply()
        self.assertEqual((status['state'], status['key']), ('enroll', 'pending'))
        self.assertTrue(status['hybrid'])
        enrollment = json.loads(self.fixture.enrollment.read_text())
        password = enrollment['password']
        self.assertRegex(password, r'^[0-9]{8}$', 'MOK manager uses a US keymap; digits are layout-safe')
        self.assertEqual(stat.S_IMODE(self.fixture.enrollment.stat().st_mode), 0o640)
        self.assertEqual(enrollment['key_sha256'], status['key_sha256'])
        self.assertNotIn(password, json.dumps(status))
        self.assertNotIn(password, (self.fixture.root / 'var/lib/cybexos/nvidia-status.json').read_text())
        imports = [call for call in self.fixture.calls() if call.startswith('mokutil --import')]
        self.assertEqual(len(imports), 1)
        self.assertIn('--hash-file', imports[0])
        self.assertNotIn(password, imports[0])
        self.assertEqual((self.fixture.fixture / 'imported-hash').read_text(), '$6$salt$hash\n')

    def test_a_pending_request_is_not_queued_again(self):
        self.fixture.apply()
        status = self.fixture.apply('--automatic')
        self.assertEqual((status['state'], status['key']), ('enroll', 'pending'))
        self.assertEqual(len([call for call in self.fixture.calls() if call.startswith('mokutil --import')]), 1)

    def test_a_skipped_enrollment_is_renewed_only_by_an_explicit_retry(self):
        self.fixture.apply()
        first = json.loads(self.fixture.enrollment.read_text())
        # The user let the MOK manager time out: the request is gone.
        self.fixture.write('key-state', 'is not enrolled')
        self.fixture.boot('boot-two')
        status = self.fixture.apply('--automatic')
        self.assertEqual((status['state'], status['key']), ('enroll', 'skipped'))
        self.assertIn('cybex repair --hardware', status['reason'])
        self.assertEqual(len([call for call in self.fixture.calls() if call.startswith('mokutil --import')]), 1)
        status = self.fixture.apply()
        self.assertEqual((status['state'], status['key']), ('enroll', 'pending'))
        second = json.loads(self.fixture.enrollment.read_text())
        self.assertNotEqual(first['password'], second['password'], 'each request gets a new password')

    def test_an_enrolled_key_discards_the_password_and_reaches_ready(self):
        self.fixture.apply()
        self.fixture.write('key-state', 'is already enrolled')
        self.fixture.boot('boot-two')
        self.fixture.loaded()
        status = self.fixture.apply('--automatic')
        self.assertEqual((status['state'], status['key']), ('ready', 'enrolled'))
        self.assertFalse(self.fixture.enrollment.exists())

    def test_an_unsigned_module_or_blocked_key_fails_without_disabling_secure_boot(self):
        self.fixture.write('signer', '')
        status = self.fixture.apply('--automatic')
        self.assertEqual(status['state'], 'failed')
        self.assertIn('not signed', status['reason'])
        self.assertFalse(any('--rebuild' in call for call in self.fixture.calls()),
                         'only an explicit retry rebuilds an installed module')
        self.fixture.apply('--force')
        self.assertIn(f'akmods --kernels {KERNEL} --akmod nvidia --rebuild', self.fixture.calls())
        self.fixture.write('signer', 'signer\n')
        self.fixture.write('key-state', 'is blocked in MokListX')
        self.assertEqual(self.fixture.apply()['state'], 'failed')
        for call in self.fixture.calls():
            self.assertNotIn('--disable-validation', call)
            self.assertNotIn('--sb-state=', call)


class RestartAwareStatusAndNotifications(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.fixture = Fixture(self.directory.name)
        self.fixture.gpu('0000:01:00.0', '10de', '2684', '030000', boot_vga=True)

    def notifications(self):
        path = self.fixture.fixture / 'notifications'
        return path.read_text() if path.exists() else ''

    def test_status_corrects_a_request_recorded_before_the_restart(self):
        self.fixture.apply()
        self.assertEqual(json.loads(self.fixture.run('status').stdout)['state'], 'reboot')
        self.fixture.boot('boot-two')
        self.assertEqual(json.loads(self.fixture.run('status').stdout)['state'], 'failed')
        self.fixture.loaded()
        self.assertEqual(json.loads(self.fixture.run('status').stdout)['state'], 'ready')

    def test_enrollment_notification_shows_the_password_once_per_boot(self):
        self.fixture.write('sb-state', 'SecureBoot enabled\n')
        self.fixture.write('signer', 'signer\n')
        self.fixture.key()
        self.fixture.apply()
        password = json.loads(self.fixture.enrollment.read_text())['password']
        self.fixture.run('notify')
        self.fixture.run('notify')
        text = self.notifications()
        self.assertEqual(text.count('Restart to enroll the Secure Boot key'), 1)
        self.assertIn(f'one-time password {password}', text)
        self.assertIn('Enroll MOK', text)
        self.assertIn('--urgency=critical', text)
        # A new boot without enrollment (the request was skipped).
        self.fixture.boot('boot-two')
        self.fixture.run('notify')
        self.assertEqual(self.notifications().count('needs attention'), 1)

    def test_unreadable_password_points_to_the_administrator_command(self):
        self.fixture.write('sb-state', 'SecureBoot enabled\n')
        self.fixture.write('signer', 'signer\n')
        self.fixture.key()
        self.fixture.apply()
        self.fixture.enrollment.chmod(0)
        try:
            if os.access(self.fixture.enrollment, os.R_OK):
                self.skipTest('running as root; permissions are not enforced')
            self.fixture.run('notify')
            self.assertIn('sudo cat /var/lib/cybexos/nvidia-mok.json', self.notifications())
        finally:
            self.fixture.enrollment.chmod(0o640)

    def test_ready_and_absent_systems_are_silent(self):
        self.fixture.loaded()
        self.assertEqual(self.fixture.apply()['state'], 'ready')
        self.fixture.run('notify')
        with tempfile.TemporaryDirectory() as directory:
            Fixture(directory).run('notify')
        self.assertEqual(self.notifications(), '')


if __name__ == '__main__':
    unittest.main()
