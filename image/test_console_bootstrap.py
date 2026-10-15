"""Mocked installed-console transport: no VM or host session is touched."""
import tempfile
import unittest
from unittest.mock import patch

from vm_testing import TestVM, console_output, sudo_password_prompt


class ConsoleBootstrapTests(unittest.TestCase):
    def exercise(self, *, passworded=False, german=False, failure=None, late_greeter=False, refusals=0,
                 splash_switches=0, dropped_names=0,
                 sudo_prompt='[sudo] password for qualification:'):
        password = 'private-fixture-secret'
        state = {'phase': 'login', 'time': 0, 'typed': [], 'greeter': splash_switches > 0, 'keys': [],
                 'refusals': refusals, 'splash': splash_switches, 'dropped_names': dropped_names}
        def clock():
            state['time'] += 0.1
            return state['time']
        def sleep(seconds):
            state['time'] += seconds
        def typing(text):
            state['typed'].append(text)
            if text == 'qualification\n' and state['dropped_names']:
                state['dropped_names'] -= 1
                return  # The display manager took focus before getty received it.
            if text == 'qualification\n' and state['refusals']:
                # pam_nologin while systemd-user-sessions has not started.
                state['refusals'] -= 1
                state['phase'] = 'refused' if state['phase'] == 'login' else 'refused-again'
            elif text == 'qualification\n':
                state['phase'] = 'password'
                # SDDM starts now and switches the display to its greeter.
                state['greeter'] = late_greeter
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
        def keys(combination):
            state['keys'].append(combination)
            if combination == 'ctrl+alt+f3':
                # The first switches land while the boot splash or a starting
                # display manager still owns the screen.
                if state['splash']:
                    state['splash'] -= 1
                else:
                    state['greeter'] = False
        def screen():
            if state['greeter']:
                return 'Sessie CybexOS Kies je gebruikersnaam en voer wachtwoord in'
            phase = state['phase']
            return {
                'login': 'fedora login:', 'password': 'Password:',
                'refused': 'fedora login: qualification System is booting up. Unprivileged users are not '
                           'permitted to log in yet. fedora login:',
                'refused-again': 'fedora login: qualification System is booting up. fedora login: '
                                 'qualification System is booting up. fedora login:',
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
            with patch.object(vm, 'keypress', side_effect=keys), patch.object(vm, 'alive'), \
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
        return state['typed'] if not late_greeter else (state['typed'], state['keys'])

    def test_an_early_console_switch_is_repeated_until_the_login_prompt_shows(self):
        typed = self.exercise(splash_switches=2)
        self.assertEqual(typed.count('private-fixture-secret\n'), 1)

    def test_a_login_refused_while_booting_is_retried(self):
        # pam_nologin refuses logins until systemd-user-sessions has started
        # (2026-10-14 plain-nl run, after a first-boot unit ran before it).
        typed = self.exercise(refusals=2)
        self.assertEqual(typed.count('qualification\n'), 3)
        self.assertEqual(typed.count('private-fixture-secret\n'), 1)

    def test_lost_username_is_retried_at_an_empty_login_prompt(self):
        typed = self.exercise(dropped_names=1)
        self.assertEqual(typed.count('qualification\n'), 2)
        self.assertEqual(typed.count('private-fixture-secret\n'), 1)

    def test_empty_prompt_retries_are_bounded_and_never_send_a_secret(self):
        typed = self.exercise(dropped_names=99, failure='username')
        self.assertEqual(typed.count('qualification\n'), 4)
        self.assertNotIn('private-fixture-secret\n', typed)

    def test_a_late_greeter_does_not_hide_the_console_password_prompt(self):
        # The display manager can start after the switch to tty3 and take the
        # screen (2026-10-14 plain-nl run); tty3 still waits for the password.
        typed, keys = self.exercise(late_greeter=True)
        self.assertEqual(typed.count('private-fixture-secret\n'), 1)
        self.assertGreaterEqual(keys.count('ctrl+alt+f3'), 2)

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
