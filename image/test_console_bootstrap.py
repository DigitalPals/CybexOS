"""Mocked installed-console transport: no VM or host session is touched."""
import tempfile
import unittest
from unittest.mock import patch

from vm_testing import TestVM, console_output, sudo_password_prompt


class ConsoleBootstrapTests(unittest.TestCase):
    def exercise(self, *, passworded=False, german=False, failure=None,
                 sudo_prompt='[sudo] password for qualification:'):
        password = 'private-fixture-secret'
        state = {'phase': 'login', 'time': 0, 'typed': []}
        def clock():
            state['time'] += 0.1
            return state['time']
        def sleep(seconds):
            state['time'] += seconds
        def typing(text):
            state['typed'].append(text)
            if text == 'qualification\n':
                state['phase'] = 'password'
            elif text == password + '\n':
                state['phase'] = 'shell' if state['phase'] == 'password' else 'authorized'
            elif text.startswith('echo CONSOLEWORKS'):
                state['phase'] = 'probe'
            elif text == 'clear\n':
                state['phase'] = 'shell'
            elif text.startswith('sudo echo'):
                state['phase'] = 'sudo' if passworded else 'authorized'
            elif text.startswith('HISTFILE=') and 'CONSOLE%sREADY' in text:
                state['phase'] = 'bash'
        def screen():
            phase = state['phase']
            return {
                'login': 'fedora login:', 'password': 'Password:',
                'shell': 'a custom Fish prompt without user or host',
                'probe': ('custom prompt echo CONSOLEWORKS y' if failure == 'shell' else
                          'custom prompt echo CONSOLEWORKS y\nCONSOLE WORKS ' + ('z' if german else 'y')),
                'sudo': sudo_prompt,
                'authorized': 'CONSOLE AUTH',
                'bash': ('echo ' + password if failure == 'bash' else
                         "bash-5.3$ printf 'CONSOLE%sREADY' BASH\nCONSOLEBASHREADY"),
            }[phase]
        with tempfile.TemporaryDirectory() as directory:
            vm = TestVM(directory)
            vm.key.with_suffix('.pub').write_text('ssh-ed25519 public-fixture')
            with patch.object(vm, 'keypress'), patch.object(vm, 'alive'), \
                    patch.object(vm, 'type', side_effect=typing), \
                    patch.object(vm, 'screen_text', side_effect=screen), \
                    patch.object(vm, 'wait_ssh') as ssh, \
                    patch('vm_testing.time.monotonic', side_effect=clock), \
                    patch('vm_testing.time.sleep', side_effect=sleep):
                if failure:
                    with self.assertRaises(RuntimeError) as error:
                        vm.bootstrap_installed_ssh(password, timeout=50)
                    self.assertNotIn(password, str(error.exception))
                    ssh.assert_not_called()
                else:
                    vm.bootstrap_installed_ssh(password, timeout=50)
                    ssh.assert_called_once()
        return state['typed']

    def test_passwordless_fish_prompt_and_german_keymap(self):
        typed = self.exercise(german=True)
        self.assertEqual(typed.count('private-fixture-secret\n'), 1)
        self.assertIn('sudo loadkezs us\n', typed)
        self.assertIn('exec env HISTFILE=/dev/null bash --noprofile --norc\n', typed)
        self.assertTrue(any('authorized_keys' in command for command in typed))

    def test_passworded_sudo_authenticates_once(self):
        typed = self.exercise(passworded=True)
        self.assertEqual(typed.count('private-fixture-secret\n'), 2)
        self.assertIn('sudo loadkeys us\n', typed)

    def test_dutch_sudo_ocr_misread_authenticates_once(self):
        typed = self.exercise(passworded=True,
                              sudo_prompt='[sudo] uachtwoord voor qualification:')
        self.assertEqual(typed.count('private-fixture-secret\n'), 2)
        self.assertIn('sudo loadkeys us\n', typed)

    def test_echoed_command_alone_never_proves_shell(self):
        typed = self.exercise(failure='shell')
        self.assertEqual(typed.count('echo CONSOLEWORKS y\n'), 3)
        self.assertFalse(any(command.startswith('sudo') for command in typed))

    def test_failed_bash_confirmation_never_sends_setup(self):
        typed = self.exercise(failure='bash')
        self.assertFalse(any('authorized_keys' in command for command in typed))

    def test_output_only_and_explicit_sudo_prompts(self):
        self.assertFalse(console_output('prompt sudo echo CONSOLEAUTH', 'CONSOLEAUTH'))
        self.assertTrue(console_output('CONSOLE AUTH', 'CONSOLEAUTH'))
        for prompt in ('[sudo] password for qualification:', 'Passwort für qualification:',
                       'wachtwoord voor qualification:', '[sudo] uachtwoord voor qualification:'):
            self.assertTrue(sudo_password_prompt(prompt))
        for prompt in ('Password:', 'password for john:', 'qualification login:',
                       'uachtwoord voor qualification:', '[sudo] uachtwoord voor john:'):
            self.assertFalse(sudo_password_prompt(prompt))


if __name__ == '__main__':
    unittest.main()
