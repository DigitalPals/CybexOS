"""Source-only safety checks for the real-browser VM qualification path."""
from pathlib import Path
import ast
import importlib.machinery
import importlib.util
import json
import os
import subprocess
import tempfile
import types
import unittest
from unittest.mock import patch

import browser_qualification as browser
import qualification
import upgrade_qualification as upgrade
from vm_testing import QUALIFICATION_DISK_SERIAL, QUALIFICATION_UNUSED_SERIAL, TestVM


class BrowserTransportTests(unittest.TestCase):
    def test_missing_browser_dependencies_fail_before_vm_or_output_creation(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'qualification'
            iso = Path('/data/pxe/iso/fixture.iso')
            arguments = ['qualify', str(iso), '--output', str(output),
                         '--execute-vm', '--erase-disposable-disk']
            with patch('sys.argv', arguments), patch.object(qualification.signal, 'signal'), \
                    patch.object(qualification, 'require_test_iso', return_value=iso), \
                    patch.object(qualification, 'browser_dependencies',
                                 side_effect=RuntimeError('Missing playwright-core')) as dependencies, \
                    patch.object(qualification, 'TestVM') as vm:
                with self.assertRaisesRegex(RuntimeError, 'Missing playwright-core'):
                    qualification.main()
            dependencies.assert_called_once_with()
            vm.assert_not_called()
            self.assertFalse(output.exists())

    def test_only_exact_guest_loopback_installer_url_is_accepted(self):
        self.assertEqual(browser.validate_guest_url(
            'http://127.0.0.1:8080/cockpit/@localhost/cybexos-installer/index.html'), 8080)
        self.assertEqual(browser.validate_guest_url(
            'http://localhost/cockpit/@localhost/cybexos-installer/index.html'), 80)
        # Anaconda passes its original URL to the wrapper, which redirects the
        # actual browser to the CybexOS page. Both use the same loopback port.
        self.assertEqual(browser.validate_guest_url(
            'http://127.0.0.1/cockpit/@localhost/anaconda-webui/index.html'), 80)
        for value in ('http://example.com/cockpit/@localhost/cybexos-installer/index.html',
                      'http://127.0.0.1@evil.invalid/cockpit/@localhost/cybexos-installer/index.html',
                      'https://127.0.0.1/cockpit/@localhost/cybexos-installer/index.html',
                      'http://127.0.0.1/cockpit/@localhost/cybexos-installer/index.html?x=1'):
            with self.subTest(value=value), self.assertRaises(ValueError):
                browser.validate_guest_url(value)

    def test_guest_disk_names_must_match_both_fixed_serials(self):
        vm = types.SimpleNamespace(ssh=['ssh', 'guest'])
        valid = f'vda {QUALIFICATION_DISK_SERIAL}\nvdb {QUALIFICATION_UNUSED_SERIAL}\n'
        for listing, expected in ((valid, ('vda', 'vdb')),
                                  (valid.replace(QUALIFICATION_UNUSED_SERIAL, 'OTHER'), None),
                                  (valid + f'vdc {QUALIFICATION_DISK_SERIAL}\n', None)):
            with patch.object(qualification, 'run', return_value=types.SimpleNamespace(stdout=listing)):
                if expected is None:
                    with self.assertRaises(RuntimeError):
                        qualification.qualification_disks(vm)
                else:
                    self.assertEqual(qualification.qualification_disks(vm), expected)

    def test_qualification_attaches_guard_only_when_requested(self):
        with tempfile.TemporaryDirectory() as directory:
            ordinary = TestVM(Path(directory) / 'ordinary')
            guarded = TestVM(Path(directory) / 'guarded', guard_disk=True)
            self.assertFalse(ordinary.guard_disk)
            self.assertTrue(guarded.guard_disk)
            self.assertNotEqual(guarded.disk, guarded.unused_disk)


class UpgradeTests(unittest.TestCase):
    def test_recovery_requires_exact_booted_point_from_snapshot_index(self):
        source = Path(__file__).resolve().parents[1] / 'roles/base/files/cybexos-system-snapshot'
        loader = importlib.machinery.SourceFileLoader('qualification_snapshot_fixture', str(source))
        spec = importlib.util.spec_from_loader(loader.name, loader)
        snapshot = importlib.util.module_from_spec(spec)
        loader.exec_module(snapshot)
        point = '20260901T120000Z-1'
        for booted in (point, False, True, '', '20260901T120000Z-2'):
            with self.subTest(booted=booted):
                # Build the response with the real producer: recoveryBoot is
                # the booted ID, whereas bootMenu and bootable are booleans.
                layout = snapshot.Layout('recovery', recovery=booted)
                with patch.object(snapshot, 'describe_points',
                                  return_value=([{'id': point, 'bootable': True}], ['menu'])):
                    index, _ = snapshot.build_index(layout, None, {}, with_menu=True)
                calls = []
                def root_script(vm, script, password, **kwargs):
                    calls.append(script)
                    return types.SimpleNamespace(stdout=json.dumps(index))
                if booted == point:
                    upgrade.verify_recovery_boot(None, point, 'fixture-password', root_script)
                    self.assertEqual(calls[-1], f'{upgrade.SNAPSHOT} restore {point}\n')
                else:
                    with self.assertRaisesRegex(RuntimeError, 'requested recovery point'):
                        upgrade.verify_recovery_boot(None, point, 'fixture-password', root_script)
                    self.assertEqual(len(calls), 1, 'Restore must not run after a mismatched boot')

    def test_preference_fixture_changes_effective_default_and_rejects_invalid_position(self):
        for initial, expected in (({}, 'bottom'), ({'position': 'top'}, 'bottom'),
                                  ({'position': 'bottom'}, 'top'), ({'position': 'invalid'}, None)):
            with self.subTest(initial=initial), tempfile.TemporaryDirectory() as directory:
                home = Path(directory)
                kitty = home / '.config/kitty/cybexos.conf'
                settings = home / '.config/cybexos/shell.json'
                kitty.parent.mkdir(parents=True)
                settings.parent.mkdir(parents=True)
                kitty.write_text('font_size 12\n')
                settings.write_text(json.dumps(initial))
                def root_script(vm, script, password):
                    guest = script.split("python3 - <<'PY'\n", 1)[1].split('\nPY\n', 1)[0]
                    guest = guest.replace("Path('/home/qualification')", f'Path({directory!r})')
                    return subprocess.run(['python3', '-'], input=guest, text=True,
                                          capture_output=True, check=True, timeout=10)
                if expected is None:
                    with self.assertRaises(subprocess.CalledProcessError):
                        upgrade.prepare_user_choices(None, 'fixture-password', root_script)
                else:
                    self.assertEqual(upgrade.prepare_user_choices(None, 'fixture-password', root_script), expected)
                    self.assertEqual(json.loads(settings.read_text())['position'], expected)
                    self.assertIn(upgrade.MANAGED_MARKER, kitty.read_text())

    def test_user_preference_fixture_is_valid_guest_python(self):
        captured = []
        def root_script(vm, script, password):
            captured.append(script)
            return types.SimpleNamespace(stdout='bottom\n')
        self.assertEqual(upgrade.prepare_user_choices(None, 'fixture-password', root_script), 'bottom')
        guest = captured[0].split("python3 - <<'PY'\n", 1)[1].split('\nPY\n', 1)[0]
        compile(guest, '<guest-preference-fixture>', 'exec')

    def test_upgrade_rejects_same_or_older_rpm_before_dnf(self):
        vm = types.SimpleNamespace()
        for comparison in (0, -1):
            with patch.object(upgrade, 'copy_candidate', return_value='a' * 64), \
                 patch.object(upgrade, 'inspect_version', return_value={'comparison': comparison}), \
                 patch.object(upgrade, 'run') as command:
                with self.assertRaises(RuntimeError):
                    upgrade.upgrade(vm, '/fixture.rpm', 'fixture-password', lambda *args, **kwargs: None)
                command.assert_not_called()

    def test_candidate_symlink_is_refused_before_guest_transfer(self):
        with tempfile.TemporaryDirectory() as directory:
            real = Path(directory) / 'candidate.rpm'
            real.write_bytes(b'fixture')
            link = Path(directory) / 'link.rpm'
            link.symlink_to(real)
            with self.assertRaises(ValueError):
                upgrade.copy_candidate(types.SimpleNamespace(), link)


class InstalledAuditTests(unittest.TestCase):
    def test_generated_timezone_check_accepts_file_aliases_but_rejects_other_zone(self):
        script = qualification.installed_audit(False, False, 'us', 'us', 'en_US.UTF-8', 'UTC')
        guest = script.split("python3 - <<'CHECK'\n", 1)[1].split('\nCHECK\n', 1)[0]
        assertion = next(node for node in ast.parse(guest).body
                         if isinstance(node, ast.Assert) and isinstance(node.msg, ast.Constant)
                         and node.msg.value == 'Installed timezone differs')
        check = compile(ast.Module(body=[assertion], type_ignores=[]), '<guest-timezone-check>', 'exec')
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            zones = root / 'usr/share/zoneinfo'
            (zones / 'Etc').mkdir(parents=True)
            utc = zones / 'UTC'
            utc.write_bytes(b'fixture UTC zone')
            (zones / 'Etc/UTC').hardlink_to(utc)
            (zones / 'UTC-symlink').symlink_to('UTC')
            (zones / 'other-zone').write_bytes(b'fixture different zone')
            localtime = root / 'etc/localtime'
            localtime.parent.mkdir()
            for target, succeeds in (('UTC', True), ('Etc/UTC', True),
                                     ('UTC-symlink', True), ('other-zone', False)):
                with self.subTest(target=target):
                    localtime.unlink(missing_ok=True)
                    localtime.symlink_to('../usr/share/zoneinfo/' + target)
                    environment = {'Path': lambda value: root / value.lstrip('/'),
                                   'expected_timezone': 'UTC'}
                    if succeeds:
                        exec(check, environment)
                    else:
                        with self.assertRaisesRegex(AssertionError, 'Installed timezone differs'):
                            exec(check, environment)

    def test_python_traceback_survives_bounded_shell_failure_output(self):
        trap = next(line for line in qualification.INSTALLED_AUDIT.splitlines()
                    if line.startswith('trap '))
        script = trap + "\npython3 - <<'PY'\n#" + 'long fixture comment ' * 300
        script += "\nraise AssertionError('specific audit assertion')\nPY\n"
        result = subprocess.run(['bash', '-e', '-s'], input=script, text=True,
                                capture_output=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('AssertionError: specific audit assertion', result.stderr[-1000:])
        self.assertIn('Installed audit shell check failed at line', result.stderr)
        self.assertNotIn('long fixture comment', result.stderr)

    def test_shell_assertions_fail_on_forbidden_state_and_probe_errors(self):
        # Exercise the generated audit using the same bash -e mode as root_script.
        # Guest commands are stubs so no host accounts, packages or disks are read.
        stubs = r'''
getent() { return "${FIXTURE_GETENT:-2}"; }
getenforce() { echo Enforcing; }
findmnt() {
  if [[ "$*" == *FSTYPE* ]]; then echo btrfs; else
    echo '/dev/fixture[/root]'; return "${FIXTURE_FINDMNT:-0}"
  fi
}
lsblk() { printf '%s\n' "${FIXTURE_TYPES:-part}"; return "${FIXTURE_LSBLK:-0}"; }
systemctl() { if [[ "$1" == show ]]; then echo inherit; fi; }
rpm() { return "${FIXTURE_RPM:-1}"; }
python3() { cat >/dev/null; echo fixture-audit-complete; }
test() {
  if [[ "$1" == '!' && "$2" == '-e' ]]; then return 0; fi
  builtin test "$@"
}
'''
        cases = [
            ('plain', False, {}, True),
            ('encrypted', True, {'FIXTURE_TYPES': 'crypt\npart'}, True),
            ('live account', False, {'FIXTURE_GETENT': '0'}, False),
            ('account query error', False, {'FIXTURE_GETENT': '3'}, False),
            ('gdm installed', False, {'FIXTURE_RPM': '0'}, False),
            ('package query error', False, {'FIXTURE_RPM': '2'}, False),
            ('unexpected encryption', False, {'FIXTURE_TYPES': 'crypt\npart'}, False),
            ('missing encryption', True, {}, False),
            ('block query error', False, {'FIXTURE_LSBLK': '1'}, False),
            ('mount query error', False, {'FIXTURE_FINDMNT': '1'}, False),
        ]
        for name, encrypted, environment, succeeds in cases:
            with self.subTest(name=name):
                script = qualification.installed_audit(encrypted, False, 'us', 'us',
                                                       'en_US.UTF-8', 'UTC')
                result = subprocess.run(['bash', '-e', '-s'], input=stubs + script,
                                        env={**os.environ, **environment}, text=True,
                                        capture_output=True, timeout=10)
                self.assertEqual(result.returncode == 0, succeeds, result.stderr)
                self.assertEqual('fixture-audit-complete' in result.stdout, succeeds)

    def test_selected_install_settings_are_checked_in_target_and_desktop(self):
        script = qualification.installed_audit(True, True, 'nl', 'nl', 'nl_NL.UTF-8', 'Europe/Amsterdam')
        self.assertIn('export EXPECTED_KEYBOARD=nl', script)
        self.assertIn('export EXPECTED_BOOT_KEYMAP=nl', script)
        self.assertIn('export EXPECTED_LOCALE=nl_NL.UTF-8', script)
        self.assertIn('export EXPECTED_TIMEZONE=Europe/Amsterdam', script)
        guest = script.split("python3 - <<'CHECK'\n", 1)[1].split('\nCHECK\n', 1)[0]
        compile(guest, '<installed-audit>', 'exec')
        compile(qualification.DESKTOP_KEYBOARD_AUDIT, '<desktop-keyboard-audit>', 'exec')

    def test_failed_installed_audit_reports_check_without_exposing_password(self):
        failure = subprocess.CalledProcessError(1, ['ssh', 'guest'],
                                                output='earlier output fixture-secret',
                                                stderr='Installed audit shell check failed at line 7: test condition')
        with patch.object(qualification, 'root_script', side_effect=failure):
            with self.assertRaisesRegex(RuntimeError, 'line 7: test condition') as caught:
                qualification.verify_installed_audit(None, True, False, 'us', 'us',
                                                      'en_US.UTF-8', 'UTC', 'fixture-secret')
        self.assertNotIn('fixture-secret', str(caught.exception))
        self.assertIn('[redacted]', str(caught.exception))


if __name__ == '__main__':
    unittest.main()
