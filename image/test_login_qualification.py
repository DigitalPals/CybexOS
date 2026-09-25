"""Source fixtures for guest-only login checks; never touch a host session."""
from contextlib import redirect_stdout
import io
import os
from pathlib import Path
from types import SimpleNamespace
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch

import login_qualification
import qualification
from vm_testing import QUALIFICATION_DISK_SERIAL, TestVM, is_disk_prompt


class DiskPromptTests(unittest.TestCase):
    def test_disposable_disk_identity_fits_the_virtio_protocol(self):
        self.assertGreater(len(QUALIFICATION_DISK_SERIAL), 0)
        self.assertLessEqual(len(QUALIFICATION_DISK_SERIAL.encode('ascii')), 20)

    def test_passwordless_sudo_never_receives_the_fixture_password_as_shell_code(self):
        vm = SimpleNamespace(ssh=['ssh', 'disposable-fixture'])
        for status in (0, 1):
            with patch.object(qualification.subprocess, 'run', return_value=SimpleNamespace(returncode=status)), \
                 patch.object(qualification, 'run') as execute:
                qualification.root_script(vm, 'echo fixture\n', 'private-synthetic-fixture')
            self.assertNotIn('private-synthetic-fixture', ' '.join(execute.call_args.args[0]))
            expected = 'echo fixture\n' if status == 0 else 'private-synthetic-fixture\necho fixture\n'
            self.assertEqual(execute.call_args.kwargs['input'], expected)

    def test_only_an_encryption_prompt_allows_password_injection(self):
        self.assertTrue(is_disk_prompt('Please enter passphrase for disk QEMU HARDDISK (luks-abcd):'))
        self.assertTrue(is_disk_prompt('Unlock encrypted volume\nPassword:'))
        for unrelated in ('qualification login:', 'Password:', 'Unlock Login Keyring',
                          'Enter password to log in', 'CybexOS', 'Disk recovery console'):
            self.assertFalse(is_disk_prompt(unrelated))

    def test_successful_disk_unlock_types_exactly_once(self):
        with tempfile.TemporaryDirectory() as directory:
            vm = TestVM(directory)
            vm.qmp_path.touch()
            with patch.object(vm, 'alive'), patch.object(vm, 'screen_text', return_value='LUKS disk password:'), \
                    patch.object(vm, 'type') as typing:
                vm.unlock_disk('synthetic-password')
            typing.assert_called_once_with('synthetic-password\n')

    def test_timeout_never_types_a_secret_into_an_unrecognized_screen(self):
        with tempfile.TemporaryDirectory() as directory:
            vm = TestVM(directory)
            vm.qmp_path.touch()
            with patch('vm_testing.time.monotonic', side_effect=[0, 1, 2, 181]), \
                    patch('vm_testing.time.sleep'), patch.object(vm, 'alive'), \
                    patch.object(vm, 'screen_text', return_value='qualification login:'), \
                    patch.object(vm, 'type') as typing:
                with self.assertRaisesRegex(RuntimeError, 'no password was typed'):
                    vm.unlock_disk('synthetic-password')
            typing.assert_not_called()

    def test_ssh_setup_only_types_private_payload_after_shell_output(self):
        for recognized in (False, True):
            with tempfile.TemporaryDirectory() as directory:
                vm = TestVM(directory)
                vm.ssh = ['ssh', 'synthetic-fixture']
                vm.qmp_path.touch()
                vm.key.with_suffix('.pub').write_text('ssh-ed25519 public-fixture')
                screen = 'CYBEXOSREADY7320' if recognized else 'Password:'
                results = [SimpleNamespace(returncode=1), SimpleNamespace(returncode=0)]
                with patch.object(vm, 'alive'), patch.object(vm, 'keypress'), \
                        patch.object(vm, 'screen_text', side_effect=['Make yourself at home.', screen]), \
                        patch('vm_testing.time.sleep'), patch('vm_testing.subprocess.run', side_effect=results), \
                        patch.object(vm, 'type') as typing:
                    vm.wait_ssh(setup_password='private-fixture')
                payloads = [call.args[0] for call in typing.call_args_list]
                self.assertEqual(any('private-fixture' in payload for payload in payloads), recognized)
                self.assertNotIn('CYBEXOSREADY7320', payloads[0])

    def test_ssh_bootstrap_never_types_shell_commands_into_grub(self):
        for screen in ('GRUB version 2.12', '', 'Please enter passphrase for disk'):
            with tempfile.TemporaryDirectory() as directory:
                vm = TestVM(directory)
                vm.ssh = ['ssh', 'synthetic-fixture']
                vm.qmp_path.touch()
                vm.key.with_suffix('.pub').write_text('ssh-ed25519 public-fixture')
                with patch.object(vm, 'alive'), patch.object(vm, 'keypress') as keys, \
                        patch.object(vm, 'screen_text', return_value=screen), \
                        patch('vm_testing.time.monotonic', side_effect=[0, 1, 2, 3, 301]), \
                        patch('vm_testing.time.sleep'), \
                        patch('vm_testing.subprocess.run', return_value=SimpleNamespace(returncode=1)), \
                        patch.object(vm, 'type') as typing:
                    with self.assertRaisesRegex(RuntimeError, 'readiness deadline'):
                        vm.wait_ssh()
                keys.assert_not_called()
                typing.assert_not_called()


class KeyringProbeTests(unittest.TestCase):
    def test_synthetic_secret_never_becomes_an_ssh_argument(self):
        vm = SimpleNamespace(ssh=['ssh', 'disposable-fixture'])
        with patch.object(login_qualification, 'run') as call:
            login_qualification.keyring_probe(vm, 'read', 'private-synthetic-fixture')
        self.assertNotIn('private-synthetic-fixture', ' '.join(call.call_args.args[0]))
        self.assertIn('private-synthetic-fixture', call.call_args.kwargs['input'])

    def exercise_probe(self, action, locked=False, returned_secret=b'fixture-secret'):
        # Real GVariant construction catches protocol signature mistakes while
        # the fake private bus guarantees no host credential store is accessed.
        from gi.repository import GLib
        methods = []
        def call(_service, _path, _interface, method, parameters, *_args):
            nonlocal locked
            methods.append(method)
            if method == 'ReadAlias':
                return GLib.Variant('(o)', ('/collection/login',))
            if method == 'Get':
                return GLib.Variant('(v)', (GLib.Variant('b', locked),))
            if method == 'Lock':
                self.assertEqual(parameters.get_type_string(), '(ao)')
                self.assertEqual(parameters.unpack(), (['/collection/login'],))
                locked = True
                return GLib.Variant('(aoo)', (['/collection/login'], '/'))
            if method == 'OpenSession':
                self.assertEqual(parameters.get_type_string(), '(sv)')
                return GLib.Variant('(vo)', (GLib.Variant('s', ''), '/session/fixture'))
            if method == 'CreateItem':
                self.assertEqual(parameters.get_type_string(), '(a{sv}(oayays)b)')
                return GLib.Variant('(oo)', ('/item/fixture', '/'))
            if method == 'SearchItems':
                return GLib.Variant('(aoao)', (['/item/fixture'], []))
            if method == 'GetSecret':
                return GLib.Variant('((oayays))', (('/session/fixture', b'', returned_secret, 'text/plain'),))
            if method == 'Delete':
                return GLib.Variant('(o)', ('/',))
            if method == 'Close':
                return GLib.Variant('()', ())
            self.fail('Unexpected secret-service operation: ' + method)
        gio = SimpleNamespace(BusType=SimpleNamespace(SESSION=1),
                              DBusCallFlags=SimpleNamespace(NONE=0),
                              bus_get_sync=lambda *_args: SimpleNamespace(call_sync=call))
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            keyrings = home / '.local/share/keyrings'
            keyrings.mkdir(parents=True)
            (keyrings / 'login.keyring').write_bytes(b'GnomeKeyring\n\r\0\n' + b'encrypted-fixture')
            with patch('gi.repository.Gio', gio, create=True), patch.object(Path, 'home', return_value=home), redirect_stdout(io.StringIO()):
                exec(login_qualification.KEYRING_PROBE, {'ACTION': action, 'EXPECTED': 'fixture-secret'})
        return methods

    def test_create_read_delete_roundtrip_uses_valid_wire_signatures(self):
        for action in ('create', 'read', 'delete'):
            methods = self.exercise_probe(action)
            self.assertNotIn('Unlock', methods)
            self.assertEqual(methods[-1], 'Close')

    def test_a_locked_success_path_is_a_failure_not_an_implicit_unlock(self):
        with self.assertRaisesRegex(AssertionError, 'lock state'):
            self.exercise_probe('read', locked=True)

    def test_secret_mismatch_closes_protocol_session_and_fails(self):
        with self.assertRaisesRegex(AssertionError, 'changed across login'):
            self.exercise_probe('read', returned_secret=b'wrong-synthetic-secret')

    def test_collection_is_explicitly_locked_without_opening_a_secret_session(self):
        with self.assertRaises(SystemExit) as result:
            self.exercise_probe('lock')
        self.assertEqual(result.exception.code, 0)


class SessionExitTests(unittest.TestCase):
    def test_logout_uses_the_shared_lua_aware_helper_and_compositor_environment(self):
        manager = 'HYPRLAND_INSTANCE_SIGNATURE=fixture_123\nWAYLAND_DISPLAY=wayland-1\nIGNORED=value\n'
        with patch('subprocess.check_output', return_value=manager), patch('subprocess.run') as run:
            exec(login_qualification.LOGOUT, {})
        self.assertEqual(run.call_args.args[0], ['/usr/libexec/cybexos-session-action', 'logout'])
        self.assertEqual(run.call_args.kwargs['env']['HYPRLAND_INSTANCE_SIGNATURE'], 'fixture_123')
        self.assertEqual(run.call_args.kwargs['env']['WAYLAND_DISPLAY'], 'wayland-1')
        self.assertTrue(run.call_args.kwargs['check'])

    def test_no_compositor_environment_prevents_logout(self):
        with patch('subprocess.check_output', return_value='WAYLAND_DISPLAY=wayland-1\n'), \
                patch('subprocess.run') as run:
            with self.assertRaisesRegex(AssertionError, 'compositor environment'):
                exec(login_qualification.LOGOUT, {})
        run.assert_not_called()

    def test_missing_cache_fixture_preserves_pam_on_persistent_storage(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            pam, backup = root / 'sddm-autologin', root / 'root-backup'
            original = '-auth optional pam_systemd_loadkey.so\n-auth optional pam_gnome_keyring.so\n'
            pam.write_text(original)
            script = login_qualification.DISABLE_BOOT_CACHE.replace(
                '/etc/pam.d/sddm-autologin', str(pam)).replace(
                '/root/cybexos-qualification-pam-backup', str(backup))
            subprocess.run(['bash', '-e', '-s'], input=script, text=True, check=True)
            self.assertEqual(backup.read_text(), original)
            self.assertEqual(backup.stat().st_mode & 0o777, 0o600)
            self.assertIn('# qualification-cache-unavailable -auth optional pam_systemd_loadkey.so', pam.read_text())
            self.assertIn('\n-auth optional pam_gnome_keyring.so\n', pam.read_text())


class FailedAutologinTests(unittest.TestCase):
    def test_injected_failure_runs_once_and_restores_exact_launcher(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            launcher = root / 'usr/bin/hyprland-quickshell'
            backup = root / 'root/cybexos-qualification-launcher-backup'
            state = root / 'home/qualification/.local/state'
            marker = state / 'cybexos/qualification-launch-failed'
            launcher.parent.mkdir(parents=True)
            backup.parent.mkdir()
            original = b"#!/usr/bin/env bash\nprintf '%s\\n' real-launcher\n"
            launcher.write_bytes(original)
            launcher.chmod(0o755)
            def local_script(script):
                for path in ('/usr/bin/hyprland-quickshell', '/root/cybexos-qualification-launcher-backup',
                             '/home/qualification/.local/state/cybexos/qualification-launch-failed'):
                    script = script.replace(path, str(root) + path)
                return script.replace('restorecon ' + str(launcher), 'true')
            subprocess.run(['bash', '-e', '-s'], input=local_script(login_qualification.FAIL_FIRST_LAUNCH),
                           text=True, capture_output=True, check=True)
            self.assertEqual(backup.read_bytes(), original)
            environment = dict(os.environ, XDG_STATE_HOME=str(state))
            first = subprocess.run([str(launcher)], env=environment, text=True, capture_output=True)
            self.assertEqual(first.returncode, 1)
            self.assertEqual(first.stdout, '')
            self.assertEqual(marker.read_text(), 'first-autologin-failure\n')
            second = subprocess.run([str(launcher)], env=environment, text=True, capture_output=True)
            self.assertEqual(second.returncode, 0)
            self.assertEqual(second.stdout, 'real-launcher\n')
            subprocess.run(['bash', '-e', '-s'], input=local_script(login_qualification.RESTORE_LAUNCHER),
                           text=True, capture_output=True, check=True)
            self.assertEqual(launcher.read_bytes(), original)
            self.assertEqual(launcher.stat().st_mode & 0o777, 0o755)
            self.assertFalse(backup.exists())
            self.assertFalse(marker.exists())

    def test_failed_boot_restores_fixture_without_typing_login_password(self):
        vm, root_script = Mock(), Mock()
        with patch.object(login_qualification, 'reboot_installed', side_effect=RuntimeError('No working greeter')):
            with self.assertRaisesRegex(RuntimeError, 'No working greeter'):
                login_qualification.qualify_failed_autologin(vm, 'synthetic-password', root_script,
                                                            {'checks': []}, 'synthetic-secret')
        vm.type.assert_not_called()
        self.assertEqual(root_script.call_args.args[1], login_qualification.RESTORE_LAUNCHER)

    def test_reenabled_autologin_stops_before_password_injection_and_cleans_up(self):
        vm = Mock()
        def execute(_vm, script, _password):
            if 'RESTARTED = True' in script:
                raise AssertionError('Manager restart re-enabled failed autologin')
        root_script = Mock(side_effect=execute)
        with patch.object(login_qualification, 'reboot_installed'), \
                patch.object(login_qualification, 'wait_login_state'):
            with self.assertRaisesRegex(AssertionError, 're-enabled failed autologin'):
                login_qualification.qualify_failed_autologin(vm, 'synthetic-password', root_script,
                                                            {'checks': []}, 'synthetic-secret')
        vm.type.assert_not_called()
        self.assertEqual(root_script.call_args.args[1], login_qualification.RESTORE_LAUNCHER)


if __name__ == '__main__':
    unittest.main()
