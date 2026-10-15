#!/usr/bin/env python3
"""Fingerprint and security-key policy, with authselect, fprintd and pamu2fcfg stubbed.

Nothing here touches the host's PAM, D-Bus or devices: the root helper runs
against a temporary root, and the Settings helper against fake services.
"""
from importlib.machinery import SourceFileLoader
import importlib.util
import io
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
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[1]
SCRIPTS = REPO / 'roles/desktop/files/quickshell/scripts'
sys.path.insert(0, str(SCRIPTS))


def load(name, path):
    loader = SourceFileLoader(name, str(path))
    spec = importlib.util.spec_from_loader(name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


policy = load('cybexos_auth_policy', REPO / 'roles/base/files/cybexos-auth-policy')
security = load('system_settings_security', SCRIPTS / 'system_settings_security.py')

SUDO = '''#%PAM-1.0
auth       include      system-auth
account    include      system-auth
password   include      system-auth
session    optional     pam_keyinit.so revoke
session    required     pam_limits.so
session    include      system-auth
'''


class Authselect:
    """A stand-in for authselect and restorecon over a temporary root."""

    def __init__(self, profile='sssd', features=('with-silent-lastlog', 'with-mdns4'), managed=True,
                 supported=('with-fingerprint', 'with-pam-u2f', 'with-pam-u2f-2fa', 'with-mdns4')):
        self.profile, self.features, self.managed = profile, list(features), managed
        self.supported = supported
        self.calls = []

    def __call__(self, argv):
        self.calls.append(argv)
        if argv[0] == 'restorecon':
            return 0, '', ''
        if argv[:2] == ['authselect', 'current']:
            if not self.managed:
                return 2, '', 'No existing configuration detected.'
            return 0, ' '.join([self.profile, *self.features]) + '\n', ''
        if argv[:2] == ['authselect', 'list-features']:
            return 0, '\n'.join(self.supported) + '\n', ''
        if argv[:2] == ['authselect', 'enable-feature']:
            if argv[2] not in self.features:
                self.features.append(argv[2])
            return 0, '', ''
        if argv[:2] == ['authselect', 'disable-feature']:
            self.features = [feature for feature in self.features if feature != argv[2]]
            return 0, '', ''
        raise AssertionError(f'unexpected command {argv}')


class AuthPolicy(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        (self.root / 'etc/pam.d').mkdir(parents=True)
        (self.root / 'etc/pam.d/sudo').write_text(SUDO)
        (self.root / 'usr/lib/pam.d').mkdir(parents=True)
        (self.root / 'usr/lib/pam.d/polkit-1').write_text(policy.POLKIT_VENDOR_DEFAULT)
        module = self.root / policy.FPRINTD_MODULE
        module.parent.mkdir(parents=True)
        module.write_text('fixture')
        self.authselect = Authselect()

    def apply(self):
        return policy.Policy(self.root, self.authselect).apply()

    def read(self, relative):
        return (self.root / relative).read_text()

    def test_keys_reach_exactly_sudo_polkit_and_the_lock_screen_ahead_of_the_password(self):
        result = self.apply()
        self.assertEqual(result['securityKeys'], 'cybexos')
        for relative in ('etc/pam.d/sudo', 'etc/pam.d/polkit-1', 'etc/pam.d/cybexos-lock'):
            lines = [line for line in self.read(relative).splitlines() if line and not line.startswith('#')]
            # Every key step is optional (-auth), sufficient, and the first auth
            # step, ahead of the unchanged include that ends in the password.
            self.assertEqual(lines[0], policy.U2F_LINE, relative)
            self.assertTrue(lines[0].startswith('-auth      sufficient   pam_u2f.so '))
            for argument in ('nouserok', 'userpresence=1', 'cue', 'origin=pam://cybexos',
                             'appid=pam://cybexos', 'authfile=.config/Yubico/u2f_keys'):
                self.assertIn(argument, lines[0].split())
            self.assertEqual(sum('pam_u2f.so' in line for line in lines), 1, relative)
        self.assertEqual(self.read('etc/pam.d/sudo'), SUDO.replace(
            '#%PAM-1.0\n', '#%PAM-1.0\n' + policy.U2F_LINE + '\n'))
        polkit = self.read('etc/pam.d/polkit-1')
        for kind in ('auth', 'account', 'password', 'session'):
            self.assertRegex(polkit, rf'(?m)^{kind}\s+include\s+system-auth$')
        lock = self.read('etc/pam.d/cybexos-lock')
        stack = ''.join(line for line in lock.splitlines(keepends=True) if not line.startswith('#'))
        # The lock screen reads fingerprints itself: no pam_fprintd, and the
        # password stack without one.
        self.assertNotIn('pam_fprintd', stack)
        self.assertNotIn('system-auth', stack)
        self.assertRegex(stack, r'(?m)^auth\s+include\s+password-auth$')

    def test_fingerprint_is_enabled_once_and_then_left_to_the_person(self):
        self.assertEqual(self.apply()['fingerprint'], 'enabled')
        self.assertIn('with-fingerprint', self.authselect.features)
        self.assertNotIn('with-pam-u2f', self.authselect.features,
                         "authselect's u2f feature would reach SDDM through password-auth")
        self.assertTrue((self.root / policy.ADOPTED).is_file())
        # The Settings switch turns it off; installs and reconciliation keep that.
        policy.Policy(self.root, self.authselect).set_fingerprint(False)
        result = self.apply()
        self.assertEqual(result['fingerprint'], 'disabled')
        self.assertNotIn('with-fingerprint', self.authselect.features)
        self.assertFalse(result['changed'])
        self.assertFalse(any(call[:2] == ['authselect', 'enable-feature'] for call in self.authselect.calls[-4:]))

    def test_converging_twice_changes_nothing(self):
        self.assertTrue(self.apply()['changed'])
        before = {path: path.read_bytes() for path in (self.root / 'etc/pam.d').iterdir()}
        result = self.apply()
        self.assertFalse(result['changed'], result)
        self.assertEqual(before, {path: path.read_bytes() for path in (self.root / 'etc/pam.d').iterdir()})

    def test_no_fprintd_module_or_unmanaged_authselect_never_touches_fingerprint_pam(self):
        (self.root / policy.FPRINTD_MODULE).unlink()
        self.assertEqual(self.apply()['fingerprint'], 'unavailable')
        self.assertNotIn('with-fingerprint', self.authselect.features)
        self.assertFalse((self.root / policy.ADOPTED).exists(), 'a later run with the package must still adopt')
        self.authselect.managed = False
        self.assertEqual(self.apply()['fingerprint'], 'unmanaged')
        with self.assertRaises(ValueError):
            policy.Policy(self.root, self.authselect).set_fingerprint(True)

    def test_an_administrators_own_pam_u2f_keeps_its_meaning(self):
        # A required second factor must not gain a sufficient key step before it.
        own = SUDO.replace('auth       include', 'auth       required     pam_u2f.so cue\nauth       include', 1)
        (self.root / 'etc/pam.d/sudo').write_text(own)
        polkit_override = '#%PAM-1.0\nauth required pam_u2f.so\nauth include system-auth\n'
        (self.root / 'etc/pam.d/polkit-1').write_text(polkit_override)
        lock = '#%PAM-1.0\nauth include login\n'
        (self.root / 'etc/pam.d/cybexos-lock').write_text(lock)
        self.apply()
        self.assertEqual(self.read('etc/pam.d/sudo'), own)
        self.assertEqual(self.read('etc/pam.d/polkit-1'), polkit_override)
        self.assertEqual(self.read('etc/pam.d/cybexos-lock'), lock, 'a file without our header is not ours')

    def test_authselect_u2f_features_take_over_and_retire_our_steps(self):
        self.apply()
        self.authselect.features.append('with-pam-u2f-2fa')
        result = self.apply()
        self.assertEqual(result['securityKeys'], 'authselect')
        self.assertEqual(self.read('etc/pam.d/sudo'), SUDO)
        self.assertFalse((self.root / 'etc/pam.d/polkit-1').exists(), 'Polkit falls back to its vendor file')
        self.assertNotIn('pam_u2f', self.read('etc/pam.d/cybexos-lock'))
        self.assertRegex(self.read('etc/pam.d/cybexos-lock'), r'(?m)^auth\s+include\s+password-auth$')

    def test_polkit_override_follows_the_vendor_stack(self):
        self.apply()
        vendor = self.root / 'usr/lib/pam.d/polkit-1'
        vendor.write_text(policy.POLKIT_VENDOR_DEFAULT + 'session    optional     pam_fixture.so\n')
        self.apply()
        self.assertIn('pam_fixture.so', self.read('etc/pam.d/polkit-1'))

    def test_removal_restores_the_stock_files_and_keeps_authselect_as_chosen(self):
        self.apply()
        result = policy.Policy(self.root, self.authselect).remove()
        self.assertTrue(result['changed'])
        self.assertEqual(self.read('etc/pam.d/sudo'), SUDO)
        self.assertFalse((self.root / 'etc/pam.d/polkit-1').exists())
        self.assertFalse((self.root / 'etc/pam.d/cybexos-lock').exists())
        self.assertIn('with-fingerprint', self.authselect.features)
        self.assertTrue((self.root / policy.ADOPTED).exists())

    def test_command_line_reports_json_and_refuses_unprivileged_use(self):
        with patch.object(policy.os, 'geteuid', return_value=1000), \
                patch('sys.stdout', new=io.StringIO()) as output:
            self.assertEqual(policy.main(['apply']), 1)
        self.assertFalse(json.loads(output.getvalue())['success'])
        # As root, a prepared tree is never a target.
        with patch.object(policy.os, 'geteuid', return_value=0), \
                patch('sys.stdout', new=io.StringIO()) as output:
            self.assertEqual(policy.main(['--root', str(self.root), 'apply']), 1)
        self.assertFalse((self.root / 'etc/pam.d/cybexos-lock').exists())
        with patch.object(policy, 'run', self.authselect), patch.object(policy.os, 'geteuid', return_value=1000), \
                patch('sys.stdout', new=io.StringIO()) as output:
            self.assertEqual(policy.main(['--root', str(self.root), 'fingerprint', 'off']), 0)
        self.assertEqual(json.loads(output.getvalue()), {'success': True, 'enabled': False, 'changed': False})
        # An explicit switch is a recorded choice even before the first converge.
        self.assertTrue((self.root / policy.ADOPTED).exists())
        self.assertEqual(policy.Policy(self.root, self.authselect).apply()['fingerprint'], 'disabled')


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
        self.authselect = self.root / 'authselect.conf'
        self.authselect.write_text('sssd\nwith-fingerprint\nwith-mdns4\n')
        self.pam = self.root / 'sudo'
        self.pam.write_text('-auth sufficient pam_u2f.so cue origin=pam://cybexos appid=pam://cybexos\n')
        helper = self.root / 'cybexos-auth-policy'
        helper.write_text('#!/bin/sh\n')
        helper.chmod(0o755)
        self.fprintd = FakeFprintd(fingers=['right-index-finger'])
        self.runner = Runner()
        self.service = security.SecuritySettings(
            fprintd=self.fprintd, account=account, runner=self.runner, authselect=self.authselect,
            pam_files=[self.pam], helpers=[self.root / 'absent', helper],
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
        self.authselect.unlink()
        snapshot = self.service.dispatch({})
        self.assertFalse(snapshot['fingerprintAuth'])
        self.assertFalse(snapshot['fingerprintManaged'])

    def test_key_support_states(self):
        self.assertEqual(self.service.key_state(['with-fingerprint']), 'ready')
        self.assertEqual(self.service.key_state(['with-pam-u2f']), 'authselect')
        self.pam.write_text('auth include system-auth\n')
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

    def test_the_switch_runs_the_policy_helper_through_pkexec(self):
        self.runner.results['pkexec'] = (0, '{"success": true, "enabled": false, "changed": true}\n', '')
        result = self.service.dispatch({'action': 'fingerprint-auth', 'enabled': False})
        self.assertEqual(self.runner.calls[-1], ['pkexec', str(self.root / 'cybexos-auth-policy'), 'fingerprint', 'off'])
        self.assertIn('off', result['message'])
        self.runner.results['pkexec'] = (126, '', '')
        with self.assertRaisesRegex(ValueError, 'cancelled or denied'):
            self.service.dispatch({'action': 'fingerprint-auth', 'enabled': True})
        self.runner.results['pkexec'] = (1, '{"success": false, "error": "authselect refused"}\n', '')
        with self.assertRaisesRegex(ValueError, 'authselect refused'):
            self.service.dispatch({'action': 'fingerprint-auth', 'enabled': True})
        with self.assertRaises(ValueError):
            self.service.dispatch({'action': 'fingerprint-auth', 'enabled': 'yes'})

    def test_adding_keys_writes_a_private_mapping_with_the_fixed_origin(self):
        self.runner.results['pamu2fcfg'] = (0, ':' + CREDENTIAL, '')
        self.service.dispatch({'action': 'add-key'})
        argv = self.runner.calls[0]
        self.assertEqual(argv[1:], ['-n', '-o', 'pam://cybexos', '-i', 'pam://cybexos'])
        mapping = self.home / '.config/Yubico/u2f_keys'
        self.assertEqual(mapping.read_text(), 'alice:' + CREDENTIAL + '\n')
        self.assertEqual(stat.S_IMODE(mapping.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(mapping.parent.stat().st_mode), 0o700)
        self.assertIn(['restorecon', '-R', str(mapping.parent)], self.runner.calls)
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
        self.pam.write_text('auth include system-auth\n')
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
        bus = subprocess.Popen(['dbus-daemon', '--session', '--nofork', '--print-address=1'],
                               stdout=subprocess.PIPE, text=True)
        self.addCleanup(bus.stdout.close)
        self.addCleanup(bus.wait, 10)
        self.addCleanup(bus.terminate)
        address = bus.stdout.readline().strip()
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
