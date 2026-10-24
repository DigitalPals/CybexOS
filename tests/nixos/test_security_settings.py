#!/usr/bin/env python3
"""Fingerprint enrollment and security-key credentials on the NixOS settings API.

Nothing here touches the host's PAM, D-Bus or devices: settings operate on
temporary account state and the real Gio adapter uses a private fixture bus.
"""
from importlib.machinery import SourceFileLoader
import importlib.util
import json
import os
from pathlib import Path
import pwd
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
import unittest

REPO = Path(__file__).resolve().parents[2]
SCRIPTS = REPO / 'desktop/quickshell/scripts'
sys.path.insert(0, str(SCRIPTS))


def load(name, path):
    loader = SourceFileLoader(name, str(path))
    spec = importlib.util.spec_from_loader(name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


security = load('system_settings_security', SCRIPTS / 'system_settings_security.py')


class FakeFprintd:
    def __init__(self, devices=('/dev/0',), fingers=(), stages=5, scan='press'):
        self._devices, self.enrolled = list(devices), list(fingers)
        self.stages, self.scan = stages, scan
        self.calls = []
        self.callback = None
        self.fail = {}

    def _call(self, name, *args):
        self.calls.append((name, *args))
        if name in self.fail:
            raise security.FprintError(self.fail[name])

    def devices(self):
        self._call('devices')
        return list(self._devices)

    def properties(self, path):
        self._call('properties', path)
        return {'name': 'Fixture Reader', 'scan-type': self.scan, 'num-enroll-stages': self.stages}

    def fingers(self, path, user):
        self._call('fingers', path, user)
        return list(self.enrolled)

    def claim(self, path):
        self._call('claim', path)

    def release(self, path):
        self._call('release', path)

    def delete(self, path, finger):
        self._call('delete', path, finger)
        self.enrolled.remove(finger)

    def enroll_start(self, path, finger):
        self._call('enroll_start', path, finger)

    def enroll_stop(self, path):
        self._call('enroll_stop', path)

    def subscribe(self, path, callback):
        self._call('subscribe', path)
        self.callback = callback


class Runner:
    def __init__(self):
        self.calls = []
        self.results = {}

    def __call__(self, argv, timeout):
        self.calls.append(argv)
        return self.results.get(Path(argv[0]).name, (0, '', ''))


CREDENTIAL = 'S2V5SGFuZGxlMQ==,UHVibGljS2V5MQ==,es256,+presence'


class SecuritySettingsTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.home = self.root / 'home'
        self.home.mkdir()
        account = pwd.struct_passwd(('alice', 'x', 1000, 1000, '', str(self.home), '/bin/bash'))
        self.nixos_policy = self.root / 'fingerprint-enabled'
        self.nixos_policy.write_text('enabled\n')
        self.pam = self.root / 'sudo'
        self.pam.write_text('auth sufficient pam_u2f.so cue nouserok=false userpresence=1 origin=pam://cybexos appid=pam://cybexos authfile=.config/Yubico/u2f_keys\n')
        self.fprintd = FakeFprintd(fingers=['right-index-finger'])
        self.runner = Runner()
        self.service = security.SecuritySettings(
            fprintd=self.fprintd, account=account, runner=self.runner, nixos_policy=self.nixos_policy,
            pam_files=[self.pam],
            which=lambda name: '/usr/bin/' + name)

    def test_snapshot_reports_reader_fingers_switch_and_keys(self):
        snapshot = self.service.dispatch({'action': 'snapshot'})
        self.assertEqual(snapshot['reader'], {'state': 'ready', 'name': 'Fixture Reader',
                                              'scanType': 'press', 'stages': 5})
        self.assertEqual(snapshot['fingers'], ['right-index-finger'])
        self.assertEqual(snapshot['freeFingers'][0], 'left-index-finger')
        self.assertTrue(snapshot['fingerprintAuth'])
        self.assertTrue(snapshot['fingerprintManaged'])
        self.assertEqual(snapshot['keys'], {'state': 'ready', 'error': '', 'entries': []})
        json.dumps(snapshot)

    def test_missing_reader_or_service_is_one_state_not_an_error(self):
        self.fprintd._devices = []
        self.assertEqual(self.service.dispatch({})['reader'], {'state': 'none'})
        self.fprintd.fail['devices'] = 'org.freedesktop.DBus.Error.ServiceUnknown'
        snapshot = self.service.dispatch({})
        self.assertEqual(snapshot['reader'], {'state': 'unavailable'})
        self.assertEqual(snapshot['fingers'], [])
        self.nixos_policy.unlink()
        snapshot = self.service.dispatch({})
        self.assertFalse(snapshot['fingerprintAuth'])
        self.assertTrue(snapshot['fingerprintManaged'], 'Disabled fingerprint policy remains managed by the NixOS module')

    def test_key_support_states(self):
        self.assertEqual(self.service.key_state(self.service.features()), 'ready')
        self.pam.write_text('auth sufficient pam_unix.so\n')
        self.assertEqual(self.service.key_state([]), 'inactive')
        self.service.which = lambda name: None
        self.assertEqual(self.service.key_state([]), 'missing')

    def test_removing_a_finger_needs_confirmation_and_releases_the_reader(self):
        with self.assertRaisesRegex(ValueError, 'Confirm'):
            self.service.dispatch({'action': 'delete-finger', 'finger': 'right-index-finger'})
        with self.assertRaises(ValueError):
            self.service.dispatch({'action': 'delete-finger', 'finger': '../etc', 'confirmed': True})
        self.service.dispatch({'action': 'delete-finger', 'finger': 'right-index-finger', 'confirmed': True})
        names = [call[0] for call in self.fprintd.calls]
        self.assertLess(names.index('claim'), names.index('delete'))
        self.assertLess(names.index('delete'), names.index('release'))
        self.assertEqual(self.fprintd.enrolled, [])
        # A cancelled authorization still releases the claim.
        self.fprintd.enrolled = ['left-thumb']
        self.fprintd.fail['delete'] = 'net.reactivated.Fprint.Error.PermissionDenied'
        self.fprintd.calls.clear()
        with self.assertRaisesRegex(ValueError, 'Authorization was cancelled'):
            self.service.dispatch({'action': 'delete-finger', 'finger': 'left-thumb', 'confirmed': True})
        self.assertEqual(self.fprintd.calls[-1][0], 'release')

    def test_authentication_policy_requires_local_preview_and_apply(self):
        before = self.nixos_policy.read_bytes()
        for enabled in (False, True):
            with self.subTest(enabled=enabled), self.assertRaisesRegex(
                    ValueError, r'cybexos\.authentication\.fingerprint.*stage local'):
                self.service.dispatch({'action': 'fingerprint-auth', 'enabled': enabled})
        with self.assertRaisesRegex(ValueError, 'Invalid fingerprint setting'):
            self.service.dispatch({'action': 'fingerprint-auth', 'enabled': 'yes'})
        self.assertEqual(self.nixos_policy.read_bytes(), before)
        self.assertEqual(self.runner.calls, [], 'Settings must never mutate PAM or bypass the lifecycle')

    def test_adding_keys_writes_a_private_mapping_with_the_fixed_origin(self):
        self.runner.results['pamu2fcfg'] = (0, ':' + CREDENTIAL, '')
        self.service.dispatch({'action': 'add-key'})
        argv = self.runner.calls[0]
        self.assertEqual(argv[1:], ['-n', '-o', 'pam://cybexos', '-i', 'pam://cybexos'])
        mapping = self.home / '.config/Yubico/u2f_keys'
        self.assertEqual(mapping.read_text(), 'alice:' + CREDENTIAL + '\n')
        self.assertEqual(stat.S_IMODE(mapping.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(mapping.parent.stat().st_mode), 0o700)
        second = CREDENTIAL.replace('MQ==', 'Mg==')
        self.runner.results['pamu2fcfg'] = (0, ':' + second + '\n', '')
        self.service.dispatch({'action': 'add-key'})
        self.assertEqual(mapping.read_text(), f'alice:{CREDENTIAL}:{second}\n')
        entries = self.service.dispatch({})['keys']['entries']
        self.assertEqual([entry['label'] for entry in entries], ['Security key 1', 'Security key 2'])

    def test_key_registration_failures_are_actionable_and_write_nothing(self):
        mapping = self.home / '.config/Yubico/u2f_keys'
        for result, message in (
                ((1, '', 'No FIDO authenticator found. Aborting.\n'), 'Insert a security key'),
                ((1, '', 'error: failed to read pin\n'), 'PIN'),
                ((124, '', 'timeout'), 'not touched in time'),
                ((0, ':not a credential', ''), 'does not recognise')):
            self.runner.results['pamu2fcfg'] = result
            with self.subTest(message=message), self.assertRaisesRegex(ValueError, message):
                self.service.dispatch({'action': 'add-key'})
            self.assertFalse(mapping.exists())
        self.pam.write_text('auth sufficient pam_unix.so\n')
        with self.assertRaisesRegex(ValueError, 'not available'):
            self.service.dispatch({'action': 'add-key'})

    def test_removing_a_key_keeps_other_accounts_lines_and_refuses_links(self):
        mapping = self.home / '.config/Yubico/u2f_keys'
        mapping.parent.mkdir(parents=True)
        second = CREDENTIAL.replace('MQ==', 'Mg==')
        mapping.write_text(f'bob:{CREDENTIAL}\nalice:{CREDENTIAL}:{second}\n')
        entries = self.service.dispatch({})['keys']['entries']
        with self.assertRaisesRegex(ValueError, 'Confirm'):
            self.service.dispatch({'action': 'remove-key', 'id': entries[0]['id']})
        self.service.dispatch({'action': 'remove-key', 'id': entries[0]['id'], 'confirmed': True})
        self.assertEqual(mapping.read_text(), f'bob:{CREDENTIAL}\nalice:{second}\n')
        with self.assertRaisesRegex(ValueError, 'no longer registered'):
            self.service.dispatch({'action': 'remove-key', 'id': entries[0]['id'], 'confirmed': True})
        mapping.unlink()
        target = self.root / 'elsewhere'
        target.write_text(f'alice:{CREDENTIAL}\n')
        mapping.symlink_to(target)
        self.assertEqual(self.service.dispatch({})['keys']['entries'], [])
        self.runner.results['pamu2fcfg'] = (0, ':' + second, '')
        with self.assertRaisesRegex(ValueError, 'is a link'):
            self.service.dispatch({'action': 'add-key'})
        self.assertEqual(target.read_text(), f'alice:{CREDENTIAL}\n')

    def test_last_key_removal_deletes_the_mapping(self):
        mapping = self.home / '.config/Yubico/u2f_keys'
        mapping.parent.mkdir(parents=True)
        mapping.write_text(f'alice:{CREDENTIAL}\n')
        entry = self.service.dispatch({})['keys']['entries'][0]
        self.service.dispatch({'action': 'remove-key', 'id': entry['id'], 'confirmed': True})
        self.assertFalse(mapping.exists())

    def test_unknown_requests_are_refused(self):
        with self.assertRaises(ValueError):
            self.service.dispatch({'action': 'shell'})


class EnrolmentTests(unittest.TestCase):
    def setUp(self):
        self.fprintd = FakeFprintd(stages=3)
        self.events = []
        self.stopped = []
        self.enrolment = security.Enrolment(self.fprintd, '/dev/0', 'right-index-finger',
                                            self.events.append, lambda: self.stopped.append(True))

    def test_progress_follows_enroll_status_and_completion_releases(self):
        self.enrolment.start()
        names = [call[0] for call in self.fprintd.calls]
        self.assertLess(names.index('subscribe'), names.index('enroll_start'),
                        'subscribe before starting, or the first status can be lost')
        self.assertEqual(self.events[0], {'event': 'started', 'finger': 'right-index-finger',
                                          'stages': 3, 'scanType': 'press'})
        callback = self.fprintd.callback
        callback('enroll-stage-passed', False)
        callback('enroll-finger-not-centered', False)
        callback('enroll-stage-passed', False)
        self.assertEqual([event.get('stage') for event in self.events[1:]], [1, 1, 2])
        callback('enroll-completed', True)
        self.assertEqual(self.events[-1], {'event': 'completed', 'finger': 'right-index-finger'})
        self.assertEqual(self.enrolment.code, 0)
        self.assertEqual([call[0] for call in self.fprintd.calls[-2:]], ['enroll_stop', 'release'])
        self.assertEqual(self.stopped, [True])
        callback('enroll-stage-passed', False)
        self.assertEqual(len(self.events), 5, 'nothing is reported after the end')

    def test_failure_cancellation_and_expiry_all_release_the_reader(self):
        for finish, event in ((lambda: self.fprintd.callback('enroll-duplicate', True), 'failed'),
                              (lambda: self.enrolment.cancel(), 'cancelled'),
                              (lambda: self.enrolment.expire(), 'failed')):
            self.setUp()
            self.enrolment.start()
            finish()
            self.assertEqual(self.events[-1]['event'], event)
            self.assertEqual([call[0] for call in self.fprintd.calls[-2:]], ['enroll_stop', 'release'])
            self.assertTrue(self.enrolment.finished)

    def test_a_refused_authorization_releases_without_stopping_an_enrolment(self):
        self.fprintd.fail['enroll_start'] = 'net.reactivated.Fprint.Error.PermissionDenied'
        with self.assertRaises(security.FprintError):
            self.enrolment.start()
        self.enrolment.finish({'event': 'failed', 'result': 'error'}, 1)
        names = [call[0] for call in self.fprintd.calls]
        self.assertIn('release', names)
        self.assertNotIn('enroll_stop', names)

    def test_command_line_validates_the_finger_and_reports_a_missing_reader(self):
        events = []
        self.assertEqual(security.enroll_main(['enroll', 'nose'], emit=events.append), 2)
        self.assertEqual(security.enroll_main(['enroll', 'left-thumb'],
                                              fprintd_factory=lambda: FakeFprintd(devices=()),
                                              emit=events.append), 1)
        self.assertEqual(events[-1]['result'], 'unavailable')

        def broken():
            raise RuntimeError('no system bus')
        self.assertEqual(security.enroll_main(['enroll', 'left-thumb'], fprintd_factory=broken,
                                              emit=events.append), 1)


MOCK_FPRINTD = r"""
import sys
import warnings
import gi
gi.require_version('Gio', '2.0')
from gi.repository import Gio, GLib

MANAGER = ('<node><interface name="net.reactivated.Fprint.Manager">'
           '<method name="GetDevices"><arg type="ao" direction="out"/></method>'
           '</interface></node>')
DEVICE = ('<node><interface name="net.reactivated.Fprint.Device">'
          '<method name="Claim"><arg type="s" direction="in"/></method>'
          '<method name="Release"/>'
          '<method name="ListEnrolledFingers"><arg type="s" direction="in"/><arg type="as" direction="out"/></method>'
          '<method name="DeleteEnrolledFinger"><arg type="s" direction="in"/></method>'
          '<method name="EnrollStart"><arg type="s" direction="in"/></method>'
          '<method name="EnrollStop"/>'
          '<signal name="EnrollStatus"><arg type="s"/><arg type="b"/></signal>'
          '<property name="name" type="s" access="read"/>'
          '<property name="num-enroll-stages" type="i" access="read"/>'
          '<property name="scan-type" type="s" access="read"/>'
          '</interface></node>')
PATH = '/net/reactivated/Fprint/Device/0'
# register_object with callables is the stable PyGObject override; its newer
# replacement is not in every supported release.
warnings.simplefilter('ignore', DeprecationWarning)
log = open(sys.argv[1], 'a', buffering=1)
enrolled = ['left-thumb']


def emit(connection, result, done):
    connection.emit_signal(None, PATH, 'net.reactivated.Fprint.Device', 'EnrollStatus',
                           GLib.Variant('(sb)', (result, done)))
    return False


def manager(connection, sender, path, interface, method, parameters, invocation):
    invocation.return_value(GLib.Variant('(ao)', ([PATH],)))


def device(connection, sender, path, interface, method, parameters, invocation):
    arguments = parameters.unpack()
    log.write(' '.join([method, *map(str, arguments)]) + '\n')
    if method == 'ListEnrolledFingers':
        invocation.return_value(GLib.Variant('(as)', (enrolled,)))
        return
    if method == 'DeleteEnrolledFinger':
        enrolled.remove(arguments[0])
    invocation.return_value(None)
    # The right index finger enrols; any other finger waits to be cancelled.
    if method == 'EnrollStart' and arguments[0] == 'right-index-finger':
        steps = [('enroll-stage-passed', False), ('enroll-finger-not-centered', False),
                 ('enroll-stage-passed', False), ('enroll-completed', True)]
        for index, (result, done) in enumerate(steps, 1):
            GLib.timeout_add(40 * index, emit, connection, result, done)


def prop(connection, sender, path, interface, name):
    return {'name': GLib.Variant('s', 'Mock Reader'), 'num-enroll-stages': GLib.Variant('i', 2),
            'scan-type': GLib.Variant('s', 'swipe')}[name]


def acquired(connection, name):
    connection.register_object('/net/reactivated/Fprint/Manager',
                               Gio.DBusNodeInfo.new_for_xml(MANAGER).interfaces[0], manager, None, None)
    connection.register_object(PATH, Gio.DBusNodeInfo.new_for_xml(DEVICE).interfaces[0], device, prop, None)


Gio.bus_own_name(Gio.BusType.SYSTEM, 'net.reactivated.Fprint', Gio.BusNameOwnerFlags.NONE,
                 acquired, lambda *_: log.write('ready\n'), None)
GLib.MainLoop().run()
"""


@unittest.skipUnless(shutil.which('dbus-daemon'), 'dbus-daemon is not installed')
class FprintdOverDBus(unittest.TestCase):
    """The real Gio code path against a stand-in fprintd on a private bus."""

    def setUp(self):
        try:
            import gi
            gi.require_version('Gio', '2.0')
        except (ImportError, ValueError, AttributeError):
            self.skipTest('PyGObject is not installed')
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        configuration = os.environ.get('CYBEXOS_DBUS_SESSION_CONFIG')
        bus_configuration = ['--config-file=' + configuration] if configuration else ['--session']
        bus = subprocess.Popen(['dbus-daemon', *bus_configuration, '--nofork', '--print-address=1'],
                               stdout=subprocess.PIPE, text=True)
        self.addCleanup(bus.stdout.close)
        self.addCleanup(bus.wait, 10)
        self.addCleanup(bus.terminate)
        address = bus.stdout.readline().strip()
        self.assertTrue(address, 'The private D-Bus fixture failed to start')
        self.environment = {**os.environ, 'DBUS_SYSTEM_BUS_ADDRESS': address, 'PYTHONDONTWRITEBYTECODE': '1'}
        self.log = self.root / 'calls'
        self.log.write_text('')
        (self.root / 'mock.py').write_text(MOCK_FPRINTD)
        mock = subprocess.Popen([sys.executable, str(self.root / 'mock.py'), str(self.log)], env=self.environment)
        self.addCleanup(mock.wait, 10)
        self.addCleanup(mock.terminate)
        for _ in range(200):
            if 'ready' in self.log.read_text():
                break
            time.sleep(0.05)
        else:
            self.fail('the stand-in fprintd did not start')

    def calls(self):
        return [line for line in self.log.read_text().splitlines() if line != 'ready']

    def enroll(self, finger):
        process = subprocess.Popen([sys.executable, '-B', str(SCRIPTS / 'system_settings_security.py'), 'enroll',
                                    finger], env=self.environment, stdout=subprocess.PIPE, text=True)
        self.addCleanup(process.stdout.close)
        return process

    def test_enrolment_streams_enroll_status_and_releases_the_reader(self):
        process = self.enroll('right-index-finger')
        output, _ = process.communicate(timeout=20)
        events = [json.loads(line) for line in output.splitlines()]
        self.assertEqual(process.returncode, 0, output)
        self.assertEqual(events[0], {'event': 'started', 'finger': 'right-index-finger', 'stages': 2,
                                     'scanType': 'swipe'})
        self.assertEqual([(event['result'], event['stage']) for event in events[1:-1]],
                         [('enroll-stage-passed', 1), ('enroll-finger-not-centered', 1), ('enroll-stage-passed', 2)])
        self.assertEqual(events[-1], {'event': 'completed', 'finger': 'right-index-finger'})
        self.assertEqual(self.calls(), ['Claim ', 'EnrollStart right-index-finger', 'EnrollStop', 'Release'])

    def test_cancelling_an_enrolment_stops_it_and_releases_the_reader(self):
        process = self.enroll('left-index-finger')
        self.assertEqual(json.loads(process.stdout.readline())['event'], 'started')
        process.send_signal(signal.SIGTERM)
        output, _ = process.communicate(timeout=20)
        self.assertEqual(process.returncode, 130)
        self.assertEqual(json.loads(output.splitlines()[-1]), {'event': 'cancelled'})
        self.assertEqual(self.calls()[-2:], ['EnrollStop', 'Release'])

    def test_settings_read_the_reader_and_remove_a_finger(self):
        def request(value):
            result = subprocess.run([sys.executable, '-B', str(SCRIPTS / 'system-settings.py'), 'security'],
                                    input=json.dumps(value) + '\n', env=self.environment,
                                    capture_output=True, text=True, timeout=20)
            return json.loads(result.stdout)
        snapshot = request({'action': 'snapshot'})
        self.assertTrue(snapshot['success'], snapshot)
        self.assertEqual(snapshot['reader'], {'state': 'ready', 'name': 'Mock Reader', 'scanType': 'swipe',
                                              'stages': 2})
        self.assertEqual(snapshot['fingers'], ['left-thumb'])
        removed = request({'action': 'delete-finger', 'finger': 'left-thumb', 'confirmed': True})
        self.assertTrue(removed['success'], removed)
        self.assertEqual(self.calls()[-3:], ['Claim ', 'DeleteEnrolledFinger left-thumb', 'Release'])
        self.assertEqual(request({'action': 'snapshot'})['fingers'], [])


class Mapping(unittest.TestCase):
    def test_parse_and_render_round_trip(self):
        text = f'bob:{CREDENTIAL}\n\nalice:{CREDENTIAL}:\n'
        credentials, others = security.parse_mapping(text, 'alice')
        self.assertEqual(credentials, [CREDENTIAL])
        self.assertEqual(others, [f'bob:{CREDENTIAL}'])
        self.assertEqual(security.render_mapping('alice', credentials, others),
                         f'bob:{CREDENTIAL}\nalice:{CREDENTIAL}\n')
        self.assertTrue(security.CREDENTIAL.match('*,UHVibGljS2V5MQ==,eddsa,+presence+pin'))
        self.assertFalse(security.CREDENTIAL.match('a:b,c,d,e'))


if __name__ == '__main__':
    os.environ.setdefault('PYTHONDONTWRITEBYTECODE', '1')
    unittest.main(verbosity=1)
