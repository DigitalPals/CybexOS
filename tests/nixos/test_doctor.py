#!/usr/bin/env python3
"""cybex doctor: read-only checks, the JSON contract, timeouts and privacy.

Every system tool the check runs is a stub in PATH and every file it reads
lives in a fixture tree (sysfs, /etc, /run, /proc). Fixtures carry the kinds of
private values real machines have; none of them may reach the report.
"""
import contextlib
import importlib.machinery
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / 'assets/scripts/cybexos-doctor'
loader = importlib.machinery.SourceFileLoader('cybexos_doctor', str(HELPER))
spec = importlib.util.spec_from_loader(loader.name, loader)
doctor = importlib.util.module_from_spec(spec)
loader.exec_module(doctor)

ORDER = ['graphics', 'drivers', 'firmware-files', 'services', 'audio', 'secure-boot', 'firmware-updates',
         'storage', 'battery', 'time', 'desktop']
HOST = 'fixture-private-host'
PERSON = 'fixtureperson'
MACHINE_ID = '0f1e2d3c4b5a69788796a5b4c3d2e1f0'
SIGNATURE = 'abcdef0123456789_1761600000_123456789'
GIB = 1024 ** 3
# Values that must never reach the report.
PRIVATE = (HOST, PERSON, MACHINE_ID, SIGNATURE, 'A4:5E:60:C1:22:9F', 'A4_5E_60_C1_22_9F', '192.168.1.23',
           'c0ffee00', 'S3R1ALUSB0042', 'BATSERIAL123', 'Neighbours WiFi', "Anna's AirPods")

KERNEL_LOG = textwrap.dedent('''\
    Linux version 7.3.0 (nixbld@localhost) #1-NixOS SMP PREEMPT_DYNAMIC
    iwlwifi 0000:00:14.3: Direct firmware load for iwlwifi-so-a0-gf-a0-89.ucode failed with error -2
    iwlwifi 0000:00:14.3: firmware: failed to load iwlwifi-so-a0-gf-a0-89.ucode (-2)
    iwlwifi 0000:00:14.3: Direct firmware load for iwlwifi-so-a0-gf-a0-88.ucode failed with error -2
    iwlwifi 0000:00:14.3: loaded firmware version 86.fb5c9aeb.0 so-a0-gf-a0-86.ucode op_mode iwlmvm
    platform regulatory.0: firmware: failed to load regulatory.db (-2)
    Bluetooth: hci0: Failed to load Intel firmware file intel/ibt-0040-0041.sfi (-2)
    i915 0000:00:02.0: [drm] *ERROR* Failed to load DMC firmware i915/adlp_dmc.bin (-2). Disabling runtime PM.
    xe 0000:00:02.0: [drm] GT0: failed to load firmware: -110
    wlp0s20f3: associated with Neighbours WiFi A4:5E:60:C1:22:9F
''')

STUBS = {
    # Each stub answers from a fixture file; a missing file is a failing tool.
    'lspci': '[ -f "$FIXTURE/lspci" ] && cat "$FIXTURE/lspci"',
    'journalctl': 'stub journalctl "$@"; cat "$FIXTURE/kernel.log"',
    'systemctl': textwrap.dedent('''\
        case " $* " in
          *" --user show-environment "*) stub show-environment "$@"; cat "$FIXTURE/environment" ;;
          *" --user "*) stub user-failed "$@"; cat "$FIXTURE/user-failed" ;;
          *) stub system-failed "$@"; cat "$FIXTURE/system-failed" ;;
        esac'''),
    'pactl': 'stub pactl "$@"; [[ $* == *"-f json"* ]] && cat "$FIXTURE/sinks.json"',
    'bootctl': 'stub bootctl "$@"; cat "$FIXTURE/bootctl"',
    'cybexos-firmware-update': 'stub firmware "$@"; [[ $1 == plan ]] && cat "$FIXTURE/plan.json"',
    'timedatectl': 'stub timedatectl "$@"; cat "$FIXTURE/timedatectl"',
    'nmcli': 'stub nmcli "$@"; cat "$FIXTURE/connectivity"',
    'hyprctl': 'stub hyprctl "$@"; [[ $HYPRLAND_INSTANCE_SIGNATURE == "$SIGNATURE" ]] && cat "$FIXTURE/configerrors"',
    'cybex': 'stub cybex "$@"; [[ $* == "shell status" ]] && cat "$FIXTURE/shell.json"',
}
PRELUDE = textwrap.dedent('''\
    stub() {
      printf '%s\\n' "$*" >>"$FIXTURE/calls"
      if [[ -f $FIXTURE/slow-$1 ]]; then sleep 30 & wait; fi
      if [[ -f $FIXTURE/fail-$1 ]]; then exit 1; fi
    }
''')


class Fixture:
    def __init__(self, directory):
        self.base = Path(directory)
        self.sys, self.etc, self.run_root, self.proc = (self.base / name for name in ('sys', 'etc', 'run', 'proc'))
        self.home = self.base / 'home' / PERSON
        self.runtime = self.base / 'runtime'
        self.bin = self.base / 'bin'
        self.fixture = self.base / 'fixture'
        for path in (self.sys / 'bus/pci/devices', self.sys / 'bus/usb/devices', self.sys / 'class/power_supply',
                     self.sys / 'class/sound', self.sys / 'firmware/efi/efivars', self.etc / 'cybexos',
                     self.run_root, self.proc / 'sys/kernel/random', self.home, self.runtime / 'pulse',
                     self.runtime / 'hypr' / SIGNATURE, self.bin, self.fixture):
            path.mkdir(parents=True, exist_ok=True)
        for name, body in STUBS.items():
            script = self.bin / name
            script.write_text('#!' + shutil.which('bash') + '\n' + PRELUDE + body + '\n')
            script.chmod(0o755)
        (self.runtime / 'pulse/native').touch()
        (self.etc / 'hostname').write_text(HOST + '\n')
        (self.etc / 'machine-id').write_text(MACHINE_ID + '\n')
        (self.proc / 'sys/kernel/random/boot_id').write_text('9d0c6a1e-5b7f-4f3e-8a2b-1c2d3e4f5a6b\n')
        (self.proc / 'uptime').write_text('3600.00 7200.00\n')
        self.disks = {'/': (500 * GIB, 200 * GIB, 1)}
        self.healthy()

    # ---- builders ------------------------------------------------------

    def write(self, name, text):
        (self.fixture / name).write_text(text)

    def flag(self, name):
        (self.fixture / name).touch()

    def pci(self, slot, klass, vendor, device, driver=None):
        path = self.sys / 'bus/pci/devices' / slot
        path.mkdir(parents=True, exist_ok=True)
        for name, value in (('class', klass), ('vendor', vendor), ('device', device)):
            (path / name).write_text(value + '\n')
        if (path / 'driver').is_symlink():
            (path / 'driver').unlink()
        if driver:
            target = self.sys / 'bus/pci/drivers' / driver
            target.mkdir(parents=True, exist_ok=True)
            (path / 'driver').symlink_to(target)
        return path

    def usb(self, name, vendor, product, interfaces, manufacturer='', label=''):
        path = self.sys / 'bus/usb/devices' / name
        path.mkdir(parents=True, exist_ok=True)
        for key, value in (('idVendor', vendor), ('idProduct', product), ('manufacturer', manufacturer),
                           ('product', label), ('serial', 'S3R1ALUSB0042'), ('authorized', '1')):
            (path / key).write_text(value + '\n')
        for suffix, klass, subclass, protocol, driver in interfaces:
            interface = self.sys / 'bus/usb/devices' / f'{name}:{suffix}'
            interface.mkdir(parents=True, exist_ok=True)
            for key, value in (('bInterfaceClass', klass), ('bInterfaceSubClass', subclass),
                               ('bInterfaceProtocol', protocol)):
                (interface / key).write_text(value + '\n')
            if driver:
                target = self.sys / 'bus/usb/drivers' / driver
                target.mkdir(parents=True, exist_ok=True)
                (interface / 'driver').symlink_to(target)

    def battery(self, name='BAT0', full=48_000_000, design=57_000_000, kind='energy'):
        path = self.sys / 'class/power_supply' / name
        path.mkdir(parents=True, exist_ok=True)
        for key, value in (('type', 'Battery'), ('scope', ''), (f'{kind}_full', full), (f'{kind}_full_design', design),
                           ('cycle_count', 120), ('model_name', '5B10W51867'), ('manufacturer', 'SMP'),
                           ('serial_number', 'BATSERIAL123'), ('status', 'Discharging'),
                           ('charge_control_end_threshold', 80)):
            (path / key).write_text(f'{value}\n')

    def secure_boot(self, enabled):
        for name, value in (('SecureBoot', enabled), ('SetupMode', False)):
            (self.sys / 'firmware/efi/efivars' / f'{name}-{doctor.EFI_GLOBAL}').write_bytes(
                b'\x06\x00\x00\x00' + bytes([value]))

    def components(self, nvidia, root=None):
        components = {'cybexos': '1.0.0', 'kernel': '7.3.0', **({'nvidia': '580.95'} if nvidia else {})}
        path = (root or self.etc) / 'cybexos/components.json'
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps({'schema': 1, 'components': components}))

    def healthy(self):
        self.pci('0000:00:02.0', '0x030000', '0x8086', '0x7d55', 'i915')
        self.pci('0000:00:14.3', '0x028000', '0x8086', '0x7e40', 'iwlwifi')
        self.pci('0000:00:1f.3', '0x040380', '0x8086', '0x7e28', 'snd_hda_intel')
        self.pci('0000:00:0d.0', '0x0c0330', '0x8086', '0x7ec0', 'xhci_hcd')
        self.pci('0000:01:00.0', '0x010802', '0x144d', '0xa80a', 'nvme')
        # Never flagged without a driver: bridges, signal processing, vendor-specific.
        self.pci('0000:00:00.0', '0x060000', '0x8086', '0x7d01')
        self.pci('0000:00:12.0', '0x118000', '0x8086', '0x7e45')
        self.pci('0000:00:15.0', '0xff0000', '0x10a5', '0x9800')
        self.pci('0000:00:1f.5', '0x0c03fe', '0x8086', '0x7e7f')
        self.write('lspci', textwrap.dedent('''\
            0000:00:02.0 "VGA compatible controller [0300]" "Intel Corporation [8086]" "Meteor Lake-P [Intel Arc Graphics] [7d55]" -r08 -p00 "Lenovo [17aa]" "Device [2234]"
            0000:00:14.3 "Network controller [0280]" "Intel Corporation [8086]" "Meteor Lake PCH CNVi WiFi [7e40]" -r20 "Intel Corporation [8086]" "Device [0094]"
            0000:01:00.0 "3D controller [0302]" "NVIDIA Corporation [10de]" "AD107M [GeForce RTX 4060 Max-Q / Mobile] [28e0]" -ra1 "Lenovo [17aa]" "Device [2234]"
        '''))
        self.usb('3-10', '8087', '0033', [('1.0', 'e0', '01', '01', 'btusb'), ('1.1', 'e0', '01', '01', 'btusb')],
                 'Intel Corp.', 'AX211 Bluetooth')
        self.usb('3-6', '04f2', 'b7b4', [('1.0', '0e', '01', '00', 'uvcvideo'), ('1.1', '0e', '02', '00', 'uvcvideo')],
                 'Chicony Electronics', 'Integrated Camera')
        # A fingerprint reader is vendor-specific and driven from userspace.
        self.usb('3-9', '06cb', '00fc', [('1.0', 'ff', '00', '00', None)], 'Synaptics', 'Prometheus')
        (self.sys / 'class/sound/card0').mkdir(exist_ok=True)
        self.write('kernel.log', 'Linux version 7.3.0 #1-NixOS SMP\nusb 3-10: new full-speed USB device\n')
        self.write('system-failed', '')
        self.write('user-failed', '')
        self.write('sinks.json', json.dumps([
            {'name': 'alsa_output.pci-0000_00_1f.3.analog-stereo', 'description': 'Meteor Lake-P HD Audio Speaker',
             'state': 'SUSPENDED', 'properties': {'device.bus': 'pci'}},
            {'name': 'bluez_output.A4_5E_60_C1_22_9F.1', 'description': "Anna's AirPods",
             'state': 'RUNNING', 'properties': {'device.bus': 'bluetooth', 'api.bluez5.address': 'A4:5E:60:C1:22:9F'}},
        ]))
        self.secure_boot(True)
        (self.etc / 'cybexos/boot.json').write_text(json.dumps({'loader': 'grub'}))
        self.write('plan.json', '{"devices":[]}\n')
        self.battery()
        self.write('timedatectl', 'NTP=yes\nNTPSynchronized=yes\n')
        self.write('connectivity', 'full\n')
        self.write('configerrors', '[""]\n')
        self.write('shell.json', json.dumps({'safe': False, 'failures': [],
                                             'path': f'/home/{PERSON}/.local/state/cybexos/shell-recovery.json'}))
        self.write('environment', f'HOME=/home/{PERSON}\nHYPRLAND_INSTANCE_SIGNATURE={SIGNATURE}\n')
        self.components(False)

    # ---- running -------------------------------------------------------

    def environment(self, session=True):
        environment = {'PATH': f"{self.bin}:{os.environ['PATH']}", 'HOME': str(self.home), 'USER': PERSON,
                       'LOGNAME': PERSON, 'FIXTURE': str(self.fixture), 'SIGNATURE': SIGNATURE,
                       'XDG_RUNTIME_DIR': str(self.runtime), 'PYTHONDONTWRITEBYTECODE': '1'}
        if session:
            environment['HYPRLAND_INSTANCE_SIGNATURE'] = SIGNATURE
        return environment

    def usage(self, path):
        return self.disks.get(path)

    @contextlib.contextmanager
    def patched(self, session=True):
        environment = self.environment(session)
        with patch.dict(os.environ, environment, clear=True), \
             patch.object(doctor, 'SYS', self.sys), patch.object(doctor, 'ETC', self.etc), \
             patch.object(doctor, 'RUN', self.run_root), patch.object(doctor, 'PROC', self.proc), \
             patch.object(doctor, 'usage', side_effect=self.usage), \
             patch.object(doctor.socket, 'gethostname', return_value=HOST):
            yield

    def report(self, session=True, deadline=doctor.DEADLINE):
        with self.patched(session):
            return doctor.collect(deadline)

    def calls(self):
        path = self.fixture / 'calls'
        return path.read_text().splitlines() if path.exists() else []


def by_id(report):
    return {check['id']: check for check in report['checks']}


class Contract(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.fixture = Fixture(self.directory.name)

    def tearDown(self):
        self.directory.cleanup()

    def assertShape(self, report):
        self.assertEqual(set(report), {'version', 'checkedAt', 'overall', 'counts', 'checks', 'scope'})
        self.assertEqual(report['version'], 1)
        self.assertRegex(report['checkedAt'], r'^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$')
        self.assertEqual([check['id'] for check in report['checks']], ORDER)
        for check in report['checks']:
            self.assertEqual(set(check), {'id', 'state', 'title', 'summary', 'detail', 'facts'}, check['id'])
            self.assertIn(check['state'], ('ok', 'suggestion', 'problem', 'info', 'unknown'))
            self.assertTrue(check['title'] and check['summary'], check['id'])
            self.assertIsInstance(check['detail'], str)
            self.assertIsInstance(check['facts'], dict)
        self.assertEqual(report['counts'], {state: sum(check['state'] == state for check in report['checks'])
                                            for state in ('problem', 'suggestion', 'ok', 'info', 'unknown')})
        self.assertEqual(report['scope'],
                         'Read-only checks of this computer. They do not qualify hardware or change anything.')
        json.dumps(report)

    def test_a_healthy_computer_is_ok_and_private(self):
        report = self.fixture.report()
        self.assertShape(report)
        checks = by_id(report)
        self.assertEqual({identifier: check['state'] for identifier, check in checks.items()},
                         {identifier: 'ok' for identifier in ORDER}, json.dumps(report, indent=1))
        self.assertEqual(report['overall'], 'ok')
        self.assertEqual(report['counts']['ok'], 11)
        self.assertEqual(checks['graphics']['facts']['gpus'], [
            {'name': 'Intel Corporation Meteor Lake-P [Intel Arc Graphics]', 'vendorDevice': '8086:7d55',
             'driver': 'i915', 'slot': '0000:00:02.0'}])
        self.assertEqual(checks['battery']['facts']['batteries'][0]['capacityPercent'], 84.2)
        self.assertEqual(checks['battery']['facts']['batteries'][0]['chargeLimit'], 80)
        self.assertEqual(checks['audio']['facts']['outputs'][1],
                         {'description': 'Bluetooth audio device', 'bus': 'bluetooth', 'state': 'running'})
        everything = json.dumps(report, ensure_ascii=False)
        for value in PRIVATE + (str(self.fixture.home),):
            self.assertNotIn(value, everything, value)
        # The sound server is addressed explicitly, so pactl cannot autospawn one.
        pactl = next(call for call in self.fixture.calls() if call.startswith('pactl '))
        self.assertIn(f'--server=unix:{self.fixture.runtime}/pulse/native', pactl)

    def test_nothing_is_changed_or_fetched(self):
        self.fixture.report()
        calls = self.fixture.calls()
        self.assertTrue(calls)
        for call in calls:
            words = call.split()[1:]
            self.assertFalse({'start', 'stop', 'restart', 'enable', 'disable', 'refresh', 'update', 'install',
                              'set-ntp', 'safe', 'recover', 'reload', 'dispatch', 'keyword'} & set(words), call)
        self.assertIn('firmware plan', calls)

    def test_problems_raise_overall_and_info_or_unknown_never_do(self):
        report = self.fixture.report()
        self.assertEqual(report['overall'], 'ok')
        self.fixture.write('kernel.log', KERNEL_LOG)
        (self.fixture.sys / 'firmware/efi').rename(self.fixture.base / 'no-efi')
        self.fixture.flag('fail-timedatectl')
        report = self.fixture.report()
        states = {check['id']: check['state'] for check in report['checks']}
        self.assertEqual((states['firmware-files'], states['secure-boot'], states['time']), ('info', 'info', 'unknown'))
        self.assertEqual(report['overall'], 'ok')
        self.fixture.write('plan.json', json.dumps({'devices': [{'id': 'f' * 40, 'name': 'UEFI dbx', 'vendor': 'Lenovo',
                                                                 'from': '217', 'to': '371', 'needsReboot': True}]}))
        self.assertEqual(self.fixture.report()['overall'], 'suggestion')
        self.fixture.write('system-failed', 'broken.service loaded failed failed Broken\n')
        report = self.fixture.report()
        self.assertEqual((report['overall'], report['counts']['problem'], report['counts']['suggestion']),
                         ('problem', 1, 1))

    def test_a_probe_that_hangs_or_breaks_becomes_unknown(self):
        def hang():
            time.sleep(5)
            return doctor.finding('ok', 'late')
        with patch.object(doctor, 'check_battery', side_effect=hang), \
             patch.object(doctor, 'check_time', side_effect=RuntimeError('boom /home/' + PERSON)):
            started = time.monotonic()
            report = self.fixture.report(deadline=0.5)
            self.assertLess(time.monotonic() - started, 3)
        self.assertShape(report)
        checks = by_id(report)
        self.assertEqual((checks['battery']['state'], checks['battery']['summary']),
                         ('unknown', 'This check did not finish in time.'))
        self.assertEqual((checks['time']['state'], checks['time']['facts']), ('unknown', {'error': 'RuntimeError'}))
        self.assertNotIn(PERSON, json.dumps(report))

    def test_command_timeouts_stop_the_whole_process_group(self):
        started = time.monotonic()
        code, output, _ = doctor.run([shutil.which('bash'), '-c', 'sleep 30 & wait'], timeout=0.5)
        self.assertEqual((code, output), (124, ''))
        self.assertLess(time.monotonic() - started, 5)
        self.assertEqual(doctor.run(['/nonexistent/cybexos-tool'])[0], 127)

    def test_slow_tools_degrade_to_unknown_within_the_time_limit(self):
        for name in ('firmware', 'pactl', 'timedatectl', 'journalctl', 'system-failed', 'user-failed', 'hyprctl',
                     'cybex', 'show-environment'):
            self.fixture.flag(f'slow-{name}')
        with patch.object(doctor, 'COMMAND_TIMEOUT', 0.5), patch.object(doctor, 'FIRMWARE_TIMEOUT', 0.5):
            started = time.monotonic()
            report = self.fixture.report()
            self.assertLess(time.monotonic() - started, 6)
        self.assertShape(report)
        states = {check['id']: check['state'] for check in report['checks']}
        for identifier in ('firmware-files', 'services', 'audio', 'firmware-updates', 'time', 'desktop'):
            self.assertEqual(states[identifier], 'unknown', identifier)
        self.assertEqual(by_id(report)['firmware-updates']['summary'],
                         'The firmware update service did not answer in time.')


class Checks(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.fixture = Fixture(self.directory.name)

    def tearDown(self):
        self.directory.cleanup()

    def check(self, identifier, session=True):
        return by_id(self.fixture.report(session))[identifier]

    def test_nvidia_without_its_driver_is_a_suggestion(self):
        self.fixture.pci('0000:01:00.0', '0x030200', '0x10de', '0x28e0', 'nouveau')
        check = self.check('graphics')
        self.assertEqual(check['state'], 'suggestion')
        self.assertIn('nouveau', check['summary'])
        self.assertIn('cybexos.hardware.nvidia', check['detail'])
        self.assertIn({'name': 'NVIDIA Corporation AD107M [GeForce RTX 4060 Max-Q / Mobile]', 'vendorDevice': '10de:28e0',
                       'driver': 'nouveau', 'slot': '0000:01:00.0'}, check['facts']['gpus'])
        self.assertIs(check['facts']['nvidiaDriverSelected'], False)
        (self.fixture.sys / 'bus/pci/devices/0000:01:00.0/driver').unlink()
        self.assertEqual(self.check('graphics')['state'], 'suggestion')

    def test_a_selected_nvidia_driver_that_is_not_in_use_is_a_problem_unless_a_restart_is_pending(self):
        self.fixture.pci('0000:01:00.0', '0x030200', '0x10de', '0x28e0', 'nouveau')
        self.fixture.components(True)
        check = self.check('graphics')
        self.assertEqual(check['state'], 'problem')
        self.assertIn('nvidiaOpen = false', check['detail'])
        booted, current = self.fixture.base / 'system-booted', self.fixture.base / 'system-current'
        self.fixture.components(False, booted / 'etc')
        self.fixture.components(True, current / 'etc')
        (self.fixture.run_root / 'booted-system').symlink_to(booted)
        (self.fixture.run_root / 'current-system').symlink_to(current)
        check = self.check('graphics')
        self.assertEqual((check['state'], check['facts']['restartPending']), ('suggestion', True))
        self.assertIn('Restart', check['summary'])

    def test_nvidia_on_its_driver_and_other_gpus_without_one(self):
        self.fixture.pci('0000:01:00.0', '0x030200', '0x10de', '0x28e0', 'nvidia')
        self.fixture.components(True)
        self.assertEqual(self.check('graphics')['state'], 'ok')
        self.fixture.pci('0000:03:00.0', '0x030000', '0x1002', '0x15bf')
        check = self.check('graphics')
        self.assertEqual(check['state'], 'problem')
        self.assertIn('AMD device 1002:15bf has no driver', check['summary'])

    def test_unreadable_pci_is_unknown(self):
        shutil.rmtree(self.fixture.sys / 'bus/pci')
        self.assertEqual(self.check('graphics')['state'], 'unknown')
        self.assertEqual(self.check('drivers')['state'], 'ok')
        shutil.rmtree(self.fixture.sys / 'bus/usb')
        self.assertEqual(self.check('drivers')['state'], 'unknown')

    def test_important_devices_without_a_driver_are_problems(self):
        self.fixture.pci('0000:02:00.0', '0x028000', '0x14e4', '0x43a0')
        self.fixture.usb('3-4', '0bda', 'c829', [('1.0', 'e0', '01', '01', None)], 'Realtek', 'Bluetooth Radio')
        self.fixture.usb('3-5', '046d', '085e', [('1.0', '0e', '01', '00', None), ('1.1', '0e', '02', '00', None)],
                         'Logitech', 'BRIO')
        check = self.check('drivers')
        self.assertEqual(check['state'], 'problem')
        self.assertTrue(check['summary'].startswith('3 devices without a driver: '), check['summary'])
        self.assertEqual(check['facts']['missing'], [
            {'bus': 'pci', 'kind': 'network', 'name': 'Broadcom device 14e4:43a0', 'vendorDevice': '14e4:43a0',
             'class': '0280', 'slot': '0000:02:00.0'},
            {'bus': 'usb', 'kind': 'Bluetooth', 'name': 'Realtek Bluetooth Radio', 'vendorDevice': '0bda:c829'},
            {'bus': 'usb', 'kind': 'camera', 'name': 'Logitech BRIO', 'vendorDevice': '046d:085e'}])

    def test_known_benign_unbound_devices_are_not_flagged(self):
        # AMD's audio coprocessor declines machines without digital microphones,
        # SR-IOV functions bind on demand and unauthorized USB devices have no interfaces bound.
        self.fixture.pci('0000:04:00.5', '0x048000', '0x1022', '0x15e2')
        self.fixture.pci('0000:05:00.1', '0x020000', '0x8086', '0x1515')
        (self.fixture.sys / 'bus/pci/devices/0000:05:00.1/physfn').symlink_to(self.fixture.sys / 'bus/pci/devices/0000:00:14.3')
        self.fixture.usb('3-7', '1234', '5678', [('1.0', '01', '01', '00', None)], 'Example', 'Headset')
        (self.fixture.sys / 'bus/usb/devices/3-7/authorized').write_text('0\n')
        self.assertEqual(self.check('drivers')['state'], 'ok')

    def test_missing_firmware_files_are_information_only(self):
        self.fixture.write('kernel.log', KERNEL_LOG)
        check = self.check('firmware-files')
        self.assertEqual(check['state'], 'info')
        self.assertEqual(check['facts']['missing'], [
            {'driver': 'Bluetooth', 'file': 'intel/ibt-0040-0041.sfi', 'error': -2},
            {'driver': 'i915', 'file': 'i915/adlp_dmc.bin', 'error': -2},
            {'driver': 'iwlwifi', 'file': 'iwlwifi-so-a0-gf-a0-88.ucode', 'error': -2},
            {'driver': 'iwlwifi', 'file': 'iwlwifi-so-a0-gf-a0-89.ucode', 'error': -2},
            {'driver': 'platform', 'file': 'regulatory.db', 'error': -2}])
        self.assertNotIn('Neighbours', json.dumps(check))

    def test_an_unreadable_kernel_log_is_unknown(self):
        self.fixture.write('kernel.log', '')
        self.assertEqual(self.check('firmware-files')['state'], 'unknown')
        self.fixture.flag('fail-journalctl')
        self.assertEqual(self.check('firmware-files')['state'], 'unknown')

    def test_failed_units_are_problems_per_scope_and_private(self):
        self.fixture.write('system-failed', textwrap.dedent(f'''\
            {HOST}-backup.service loaded failed failed Nightly backup
            systemd-fsck@dev-disk-by\\x2duuid-c0ffee00\\x2d1234.service loaded failed failed File System Check
            not-a-unit-line
        '''))
        self.fixture.write('user-failed', f'home-{PERSON}-sync.service loaded failed failed Sync\n')
        check = self.check('services')
        self.assertEqual(check['state'], 'problem')
        self.assertEqual(check['facts'], {
            'system': ['[hostname]-backup.service', 'systemd-fsck@dev-disk-by\\x2duuid-[device].service'],
            'user': ['home-[user]-sync.service']})
        self.assertIn('systemctl --user status', check['detail'])
        self.fixture.write('system-failed', '')
        self.fixture.write('user-failed', '')
        self.fixture.flag('fail-user-failed')
        check = self.check('services')
        self.assertEqual((check['state'], check['facts']['user']), ('ok', None))
        self.fixture.flag('fail-system-failed')
        self.assertEqual(self.check('services')['state'], 'unknown')

    def test_audio_without_real_outputs(self):
        self.fixture.write('sinks.json', json.dumps([{'name': 'auto_null', 'description': 'Dummy Output',
                                                      'state': 'IDLE', 'properties': {}}]))
        check = self.check('audio')
        self.assertEqual((check['state'], check['summary']), ('problem', 'No speakers or headphones found.'))
        self.fixture.write('sinks.json', '[]')
        self.assertEqual(self.check('audio')['state'], 'problem')
        shutil.rmtree(self.fixture.sys / 'class/sound/card0')
        self.assertEqual(self.check('audio')['state'], 'info')

    def test_an_unreachable_sound_server_is_unknown_without_starting_one(self):
        (self.fixture.runtime / 'pulse/native').unlink()
        self.assertEqual(self.check('audio')['state'], 'unknown')
        self.assertFalse(any(call.startswith('pactl') for call in self.fixture.calls()))
        (self.fixture.runtime / 'pulse/native').touch()
        self.fixture.flag('fail-pactl')
        self.assertEqual(self.check('audio')['state'], 'unknown')

    def test_secure_boot_off_is_expected_information(self):
        self.fixture.secure_boot(False)
        check = self.check('secure-boot')
        self.assertEqual(check['state'], 'info')
        self.assertIn('would not start', check['detail'])
        self.assertEqual(check['facts'], {'mode': 'uefi', 'secureBoot': False, 'setupMode': False, 'bootLoader': 'grub'})
        for path in (self.fixture.sys / 'firmware/efi/efivars').iterdir():
            path.unlink()
        self.fixture.write('bootctl', 'System:\n      Firmware: UEFI 2.70\n   Secure Boot: enabled (user)\n')
        self.assertEqual(self.check('secure-boot')['state'], 'ok')
        self.fixture.write('bootctl', '')
        self.assertEqual(self.check('secure-boot')['state'], 'unknown')
        shutil.rmtree(self.fixture.sys / 'firmware/efi')
        check = self.check('secure-boot')
        self.assertEqual((check['state'], check['facts']['mode']), ('info', 'legacy'))

    def test_firmware_updates_use_the_read_only_plan(self):
        self.fixture.write('plan.json', 'fwupd warning on stdout\n' + json.dumps({'devices': [
            {'id': 'a' * 40, 'name': 'UEFI dbx', 'vendor': 'Lenovo', 'from': '217', 'to': '371', 'needsReboot': False},
            {'id': 'b' * 40, 'name': 'System Firmware', 'vendor': 'Lenovo', 'from': '0.1.25', 'to': '0.1.27',
             'needsReboot': True}]}))
        check = self.check('firmware-updates')
        self.assertEqual(check['state'], 'suggestion')
        self.assertEqual(check['summary'], 'Firmware updates are available for 2 devices: UEFI dbx, System Firmware.')
        self.assertIn('next restart', check['detail'])
        self.assertEqual(check['facts']['updates'][1], {'name': 'System Firmware', 'vendor': 'Lenovo',
                                                        'from': '0.1.25', 'to': '0.1.27', 'needsReboot': True})
        self.assertNotIn('a' * 40, json.dumps(check))
        self.fixture.flag('fail-firmware')
        self.assertEqual(self.check('firmware-updates')['state'], 'unknown')

    def test_storage_thresholds(self):
        for disks, expected in (({'/': (500 * GIB, 74 * GIB, 1)}, 'suggestion'),
                                ({'/': (500 * GIB, 24 * GIB, 1)}, 'problem'),
                                ({'/': (64 * GIB, 4 * GIB, 1)}, 'problem'),
                                ({'/': (500 * GIB, 100 * GIB, 1), '/home': (100 * GIB, 4 * GIB, 2)}, 'problem'),
                                ({'/': (500 * GIB, 100 * GIB, 1), '/home': (100 * GIB, 4 * GIB, 1)}, 'ok'),
                                ({'/': (500 * GIB, 100 * GIB, 1), '/nix': (500 * GIB, 100 * GIB, 3)}, 'ok')):
            with self.subTest(disks=disks):
                self.fixture.disks = disks
                check = self.check('storage')
                self.assertEqual(check['state'], expected, check['summary'])
                self.assertEqual(len(check['facts']['filesystems']), 2 if expected == 'problem' and '/home' in disks else 1)
        self.fixture.disks = {}
        self.assertEqual(self.check('storage')['state'], 'unknown')

    def test_battery_capacity(self):
        self.fixture.battery(full=30_000_000, design=57_000_000)
        check = self.check('battery')
        self.assertEqual(check['state'], 'suggestion')
        self.assertIn('52.6 %', check['summary'])
        self.fixture.battery(full=4_000_000, design=4_500_000, kind='charge')
        shutil.rmtree(self.fixture.sys / 'class/power_supply/BAT0')
        self.fixture.battery('BAT1', full=4_000_000, design=4_500_000, kind='charge')
        self.assertEqual(self.check('battery')['state'], 'ok')
        (self.fixture.sys / 'class/power_supply/BAT1/charge_full_design').write_text('0\n')
        self.assertEqual(self.check('battery')['state'], 'info')
        shutil.rmtree(self.fixture.sys / 'class/power_supply/BAT1')
        # A mouse's battery is not the computer's.
        mouse = self.fixture.sys / 'class/power_supply/BAT-hid'
        self.fixture.battery('BAT-hid', full=1, design=10)
        (mouse / 'scope').write_text('Device\n')
        check = self.check('battery')
        self.assertEqual((check['state'], check['summary']), ('ok', 'No battery.'))

    def test_time_synchronization(self):
        self.fixture.write('timedatectl', 'NTP=yes\nNTPSynchronized=no\n')
        self.assertEqual(self.check('time')['state'], 'suggestion')
        self.fixture.write('connectivity', 'none\n')
        self.assertEqual(self.check('time')['state'], 'info')
        self.fixture.write('connectivity', 'full\n')
        (self.fixture.proc / 'uptime').write_text('120.0 240.0\n')
        self.assertEqual(self.check('time')['state'], 'info')
        self.fixture.write('timedatectl', 'NTP=no\nNTPSynchronized=no\n')
        check = self.check('time')
        self.assertEqual((check['state'], check['summary']), ('suggestion', 'Automatic network time is off.'))

    def test_desktop_errors_safe_mode_and_sessions(self):
        self.fixture.write('configerrors', json.dumps([
            f'{self.fixture.home}/.config/cybexos/hypr/user.lua:3: monitor 192.168.1.23 unknown', '',
            f'/home/{PERSON}/.config/hypr/old.conf: ignored']))
        self.fixture.write('shell.json', json.dumps({'safe': True, 'reason': 'The desktop failed three times within two minutes'}))
        check = self.check('desktop')
        self.assertEqual(check['state'], 'problem')
        self.assertEqual(check['facts']['hyprland']['configErrors'],
                         ['~/.config/cybexos/hypr/user.lua:3: monitor [address] unknown',
                          '/home/[user]/.config/hypr/old.conf: ignored'])
        self.assertIn('safe mode', check['summary'])
        self.assertIn('cybex shell recover', check['detail'])
        self.fixture.write('configerrors', '[""]')
        self.fixture.write('shell.json', '{"safe": false}')
        # A service started before Hyprland finds the session through systemd.
        self.assertEqual(self.check('desktop', session=False)['state'], 'ok')
        self.fixture.write('environment', 'HOME=/x\n')
        check = self.check('desktop', session=False)
        self.assertEqual((check['state'], check['facts']['hyprland']['session']), ('unknown', False))
        self.fixture.flag('fail-cybex')
        self.assertEqual(self.check('desktop')['state'], 'unknown')
        self.fixture.write('configerrors', 'not json')
        self.assertEqual(self.check('desktop')['state'], 'unknown')


FIXTURE_ENTRY = """
import importlib.machinery, importlib.util, json, os, sys
from pathlib import Path
loader = importlib.machinery.SourceFileLoader('fixture_doctor', os.environ['CYBEXOS_DOCTOR'])
spec = importlib.util.spec_from_loader(loader.name, loader)
doctor = importlib.util.module_from_spec(spec)
loader.exec_module(doctor)
roots = json.loads(os.environ['FIXTURE_ROOTS'])
for name in ('SYS', 'ETC', 'RUN', 'PROC'):
    setattr(doctor, name, Path(roots[name]))
disks = {path: tuple(value) for path, value in roots['disks'].items()}
doctor.usage = disks.get
doctor.socket.gethostname = lambda: roots['host']
sys.exit(doctor.main(sys.argv[1:]))
"""


class CommandLine(unittest.TestCase):
    def run_cli(self, fixture, *argv):
        environment = {**fixture.environment(), 'CYBEXOS_DOCTOR': str(HELPER), 'FIXTURE_ROOTS': json.dumps({
            'SYS': str(fixture.sys), 'ETC': str(fixture.etc), 'RUN': str(fixture.run_root),
            'PROC': str(fixture.proc), 'host': HOST, 'disks': fixture.disks})}
        entry = fixture.bin / 'cybexos-doctor'
        entry.write_text(f'#!{sys.executable}\n' + FIXTURE_ENTRY)
        entry.chmod(0o755)
        # `cybex doctor` goes through the lifecycle CLI to the packaged helper.
        command = [sys.executable, '-c', 'import sys; sys.path.insert(0, sys.argv.pop(1)); sys.argv[0] = "cybex"; '
                   'from cybexos import cli; cli.main()', str(ROOT / 'lifecycle'), 'doctor', *argv]
        return subprocess.run(command, env=environment, text=True, capture_output=True, timeout=60,
                              stdin=subprocess.DEVNULL)

    def test_cybex_doctor_text_and_json(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = Fixture(directory)
            fixture.write('system-failed', f'{HOST}-backup.service loaded failed failed Backup\n')
            fixture.write('plan.json', json.dumps({'devices': [{'name': 'UEFI dbx', 'from': '1', 'to': '2'}]}))
            fixture.secure_boot(False)
            result = self.run_cli(fixture, '--json')
            self.assertEqual(result.returncode, 0, result.stderr)
            report = json.loads(result.stdout)
            self.assertEqual([check['id'] for check in report['checks']], ORDER)
            self.assertEqual((report['overall'], report['counts']['problem'], report['counts']['suggestion']),
                             ('problem', 1, 1))
            result = self.run_cli(fixture)
            self.assertEqual(result.returncode, 0, result.stderr)
            lines = result.stdout.splitlines()
            self.assertEqual(lines[0], 'Cybex OS system check: 1 problem, 1 suggestion')
            rows = [line for line in lines if line and not line.startswith(' ')][1:-1]
            self.assertEqual(len(rows), 11)
            self.assertTrue(rows[0].startswith('Problem     Services: 1 service failed: [hostname]-backup.service'))
            self.assertTrue(rows[1].startswith('Suggestion  Firmware updates:'))
            self.assertIn('Note        Secure Boot: Secure Boot is off.', rows)
            self.assertEqual(lines[-1], doctor.SCOPE)
            for output in (result.stdout, json.dumps(report)):
                for value in PRIVATE:
                    self.assertNotIn(value, output, value)
            usage = self.run_cli(fixture, '--fix')
            self.assertEqual(usage.returncode, 2)
            self.assertIn('usage: cybex doctor', usage.stderr)

    def test_dispatch_matches_the_other_user_helpers(self):
        sys.path.insert(0, str(ROOT / 'lifecycle'))
        try:
            from cybexos import cli
        finally:
            sys.path.remove(str(ROOT / 'lifecycle'))
        with patch.object(sys, 'argv', ['cybex', 'doctor', '--json']), \
             patch.object(cli.os, 'execvp', side_effect=SystemExit(0)) as execute, self.assertRaises(SystemExit):
            cli.main()
        execute.assert_called_once_with('cybexos-doctor', ['cybexos-doctor', '--json'])


if __name__ == '__main__':
    unittest.main()
