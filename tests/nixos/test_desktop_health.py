"""Health-command fixtures, not graphical runtime qualification."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'lifecycle'))
from nerdos.common import Failure
from nerdos.desktop_check import compositor_command, verify_compositor
from nerdos.health import LIVE_BEGIN, LIVE_END, desktop, system_services, user_services

SYSTEM = '/nix/store/' + 'a' * 32 + '-nixos-system-test'
GUARD = Path(__file__).resolve().parents[1] / 'lib/quickshell-live'
INVOCATION, RESTARTED = 'a' * 32, 'b' * 32

# A stateful fake user manager for the real guard. Every systemctl/kill call is
# logged; any unit or process mutation is recorded separately so read-only
# checks can prove that none happened.
FAKE_SYSTEMD = r"""
STATE=__STATE__
systemctl() {
    printf '%s\n' "$*" >>"$STATE/calls"
    [[ $1 == --user ]] || return 90
    case $2 in
        is-active) [[ $(<"$STATE/active") == active ]] ;;
        show)
            case " $* " in
                *' MainPID '*) cat "$STATE/pid" ;;
                *' InvocationID '*) cat "$STATE/invocation" ;;
                *' ControlGroup '*) echo /managed ;;
                *) return 91 ;;
            esac ;;
        status) return 0 ;;
        *) printf '%s\n' "$*" >>"$STATE/mutations"; echo active >"$STATE/active"
           echo 303 >"$STATE/pid"; echo cccccccccccccccccccccccccccccccc >"$STATE/invocation" ;;
    esac
}
journalctl() {
    local argument
    for argument; do
        if [[ $argument == _SYSTEMD_INVOCATION_ID=* ]]; then
            printf '%s\n' "${argument#*=}" >>"$STATE/journals"
            cat "$STATE/journal-${argument#*=}" 2>/dev/null
        fi
    done
    return 0
}
id() { echo 1000; }
pgrep() { [[ $1 == -u && $2 == 1000 ]] || return 90; cat "$STATE/pid"; }
ps() { echo 1000; }
kill() { [[ $1 == -0 ]] && return 0; printf 'kill %s\n' "$*" >>"$STATE/mutations"; }
qs() { [[ $1 == ipc && $2 == --pid ]] || return 0; printf '%s\n' "$3" >>"$STATE/ipc"; echo ok; }
"""


class SystemHealthTests(unittest.TestCase):
    def test_only_declared_services_are_required(self):
        calls = []
        system_services(lambda *args: calls.append(args) or 'active',
                        {'schema': 1, 'units': ['NetworkManager.service', 'ipsec.service', 'personal.service']})
        self.assertEqual(calls, [('systemctl', 'is-active', unit) for unit in
                                 ['NetworkManager.service', 'ipsec.service', 'personal.service']])
        calls.clear()
        system_services(lambda *args: calls.append(args) or 'active',
                        {'schema': 1, 'units': ['NetworkManager.service']})
        self.assertEqual(len(calls), 1)

    def test_failed_service_gives_actionable_failure(self):
        def inactive(*args):
            raise subprocess.CalledProcessError(3, args)
        with self.assertRaisesRegex(Failure, 'ipsec.service.*systemctl status'):
            system_services(inactive, {'schema': 1, 'units': ['ipsec.service']})

    def test_invalid_or_missing_declaration_cannot_skip_health(self):
        for declaration in (None, {'schema': 1, 'units': []}, {'schema': 2, 'units': ['ipsec.service']},
                            {'schema': 1, 'units': ['--all']}, {'schema': 1, 'units': [None]}):
            with self.subTest(declaration=declaration), self.assertRaises(Failure):
                system_services(lambda *args: 'active', declaration)

    def test_selected_hardware_services_and_user_audio_are_required(self):
        units = ['xps-ipu7-abi.service', 'v4l2-relayd-ipu7.service', 'xps-haptic-touchpad.service']
        for failed in units:
            def run(*args):
                return 'failed' if args[-1] == failed else 'active'
            with self.subTest(unit=failed), self.assertRaisesRegex(Failure, failed):
                system_services(run, {'schema': 1, 'units': units})
        calls = []
        declaration = {'schema': 1, 'userUnits': ['xps-speaker-tuning.service']}
        user_services(['runuser', '-u', 'owner', '--'], lambda *args: calls.append(args) or 'active', declaration)
        self.assertEqual(calls, [('runuser', '-u', 'owner', '--', 'systemctl', '--user', 'is-active', 'xps-speaker-tuning.service')])
        with self.assertRaisesRegex(Failure, 'xps-speaker-tuning.service.*systemctl --user status'):
            user_services([], lambda *args: 'failed', declaration)
        user_services([], lambda *args: self.fail('Disabled optional audio must not be checked'),
                      {'schema': 1, 'userUnits': []})
        for invalid in (None, {'schema': 1}, {'schema': 1, 'userUnits': ['--all']}):
            with self.subTest(invalid=invalid), self.assertRaises(Failure):
                user_services([], lambda *args: 'active', invalid)


class ShellProcessGuardTests(unittest.TestCase):
    def guard(self, extra=False):
        guard = Path(__file__).resolve().parents[1] / 'lib/quickshell-live'
        script = r"""
source "$1"
QS_LIVE_READ_ONLY=1
qs_live_main_pid() { echo 101; }
qs_live_control_group() { echo /managed; }
id() { echo 1000; }
pgrep() {
    [[ $1 == -u && $2 == 1000 && $3 == -x ]] || return 90
    echo 101
    [[ $EXTRA == 1 ]] && echo 202
    return 0
}
qs_live_pid_command() { echo 'qs -p /personal/dev'; }
qs_live_pid_cgroup() { echo /developer; }
ps() { echo 1000; }
kill() { [[ $1 == -0 ]] || { echo unexpected-termination >&2; exit 99; }; }
qs_live_reconcile_processes
"""
        import os
        return subprocess.run(['bash', '-c', script, 'guard-fixture', str(guard)],
                              env=os.environ | {'EXTRA': '1' if extra else '0'}, capture_output=True, text=True)

    def test_process_scan_is_scoped_to_the_authenticated_user(self):
        result = self.guard()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_updater_health_does_not_terminate_a_developer_process(self):
        result = self.guard(extra=True)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn('stop it before applying or confirming', result.stderr)
        self.assertNotIn('unexpected-termination', result.stderr)


class FakeUserManager:
    """Service state shared by the real guard script and Python probes."""

    def __init__(self, test):
        directory = tempfile.TemporaryDirectory(prefix='nerdos-health-live-')
        test.addCleanup(directory.cleanup)
        self.state = Path(directory.name)
        self.reset()
        # The installed guard is sourced first; the fake user manager replaces
        # only the external commands it invokes.
        self.guard = self.state / 'guard'
        self.guard.write_text(f'source {GUARD}\nQS_LIVE_TIMEOUT=2\n' + FAKE_SYSTEMD.replace('__STATE__', str(self.state)))

    def reset(self):
        self.run(active='active', pid='101', invocation=INVOCATION)
        for name in ('calls', 'mutations', 'journals', 'ipc'):
            (self.state / name).write_text('')

    def run(self, **values):
        for name, value in values.items():
            (self.state / name).write_text(value + '\n')

    def restart(self, pid='202', invocation=RESTARTED):
        self.run(pid=pid, invocation=invocation)

    def journal(self, invocation, text):
        (self.state / f'journal-{invocation}').write_text(text)

    def lines(self, name):
        return (self.state / name).read_text().splitlines()

    def script(self, body, read_only=True):
        script = f'export QS_LIVE_READ_ONLY={1 if read_only else 0}\nsource "$1"\n{body}'
        return subprocess.run(['bash', '-c', script, 'live-fixture', str(self.guard)],
                              capture_output=True, text=True, timeout=60)


class ShellInvocationGuardTests(unittest.TestCase):
    def setUp(self):
        self.manager = FakeUserManager(self)

    def bracket(self, between='', read_only=True):
        return self.manager.script(f'qs_live_begin || exit 10\n{between}\nqs_live_end', read_only)

    def test_unchanged_invocation_passes_and_validates_its_journal(self):
        result = self.bracket('qs_live_wait_ipc 1 shell ping >/dev/null || exit 11')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.manager.lines('journals'), [INVOCATION])
        self.assertEqual(self.manager.lines('ipc'), ['101'])
        self.assertEqual(self.manager.lines('mutations'), [])

    def test_restart_or_crash_during_read_only_check_fails_without_mutation(self):
        manager = self.manager
        cases = {'restart': f'echo 202 >{manager.state}/pid; echo {RESTARTED} >{manager.state}/invocation',
                 'invocation only': f'echo {RESTARTED} >{manager.state}/invocation',
                 'pid only': f'echo 202 >{manager.state}/pid',
                 'stopped': f'echo inactive >{manager.state}/active'}
        for name, between in cases.items():
            with self.subTest(name):
                manager.reset()
                result = self.bracket(between)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertEqual(manager.lines('mutations'), [], 'read-only health changed a unit or process')
                self.assertFalse(any(call.split()[1:2] in (['start'], ['restart'], ['stop']) for call in manager.lines('calls')))
                # The invocation that was inspected is always validated.
                self.assertIn(INVOCATION, manager.lines('journals'))
                self.assertRegex(result.stderr, 'restarted during the test' if name != 'stopped' else 'read-only health does not start it')

    def test_errors_in_the_original_invocation_fail_after_a_clean_replacement(self):
        self.manager.journal(INVOCATION, 'qml: ReferenceError: panel is not defined\n')
        result = self.bracket(f'echo 202 >{self.manager.state}/pid; echo {RESTARTED} >{self.manager.state}/invocation')
        self.assertEqual(result.returncode, 1)
        self.assertIn(f'service invocation {INVOCATION} contains QML/runtime errors', result.stderr)
        self.assertEqual(self.manager.lines('journals'), [INVOCATION, RESTARTED])
        self.manager.reset()
        result = self.bracket()
        self.assertEqual(result.returncode, 1, 'an unchanged invocation with QML errors passed')

    def test_developer_recovery_restores_the_service_but_still_fails(self):
        result = self.bracket(f'echo inactive >{self.manager.state}/active', read_only=False)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(self.manager.lines('mutations'), ['--user start quickshell.service'])
        self.assertIn('restoring it, but the test has failed', result.stderr)
        self.assertEqual(self.manager.lines('journals'), [INVOCATION, 'c' * 32])

    def test_end_without_a_recorded_invocation_fails(self):
        for read_only in (True, False):
            with self.subTest(read_only=read_only):
                result = self.manager.script('qs_live_end', read_only)
                self.assertEqual(result.returncode, 1)
                self.assertIn('did not record the service invocation', result.stderr)
        self.assertEqual(self.manager.lines('mutations'), [])

    def test_begin_requires_a_valid_invocation_and_rebaselines(self):
        self.manager.run(invocation='')
        result = self.manager.script('qs_live_begin')
        self.assertEqual(result.returncode, 1)
        self.assertIn('no valid InvocationID', result.stderr)
        # An intentional restart is accepted only after a fresh begin.
        self.manager.run(invocation=INVOCATION)
        result = self.bracket(f'echo {RESTARTED} >{self.manager.state}/invocation; qs_live_begin || exit 12')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.manager.lines('journals'), [RESTARTED])


class HealthTests(unittest.TestCase):
    def setUp(self):
        self.calls = []
        self.actual = '0.56.2'
        self.configerrors = []
        self.lua = 'ok'
        self.plugins = {'plugins': [], 'errors': {}, 'discovering': False, 'discoveryError': ''}

    def command(self, *args):
        self.calls.append(args)
        if LIVE_BEGIN in args:
            return f'quickshell live check: waiting for IPC client PID 7 to finish\nqs-live-identity 123 {INVOCATION}'
        if LIVE_END in args:
            self.assertEqual(args[-2:], ('123', INVOCATION))
            return ''
        if 'show-environment' in args:
            return 'HYPRLAND_INSTANCE_SIGNATURE=test-instance\n'
        if args[-2:] == ('-j', 'version'):
            return json.dumps({'version': self.actual})
        if args[-2:] == ('-j', 'configerrors'):
            return json.dumps(self.configerrors)
        if 'eval' in args:
            return self.lua
        if 'listPlugins' in args:
            return json.dumps(self.plugins)
        return ''

    def test_healthy_desktop_and_exact_managed_ipc_pid(self):
        desktop(['env', 'XDG_RUNTIME_DIR=/run/user/1000'], self.command, '/guard', {'hyprland': '0.56.2'})
        self.assertIn(('--pid', '123'), tuple(args[i:i+2] for args in self.calls for i in range(len(args)-1)))

    def test_compositor_errors_and_contained_lua_failures(self):
        for attribute, value in [('actual', '0.55.4'), ('configerrors', ['bad option']), ('lua', 'Lua assertion failed')]:
            with self.subTest(attribute=attribute):
                self.setUp()
                setattr(self, attribute, value)
                with self.assertRaises(Failure):
                    desktop([], self.command, '/guard', {'hyprland': '0.56.2'})

    def test_empty_compositor_error_buffer_accepts_only_blank_strings(self):
        for errors in ([], [''], ['', ' \t\n']):
            self.configerrors = errors
            with self.subTest(healthy=errors):
                desktop([], self.command, '/guard')
        for errors in (None, {}, '', [None], [False], [0], [{}], ['', 'unknown config key']):
            self.configerrors = errors
            with self.subTest(invalid=errors), self.assertRaisesRegex(Failure, 'Hyprland configuration errors'):
                desktop([], self.command, '/guard')

    def test_personal_plugin_failures_are_not_accepted_as_healthy(self):
        for plugins in [{'errors': {'personal:bar': 'API failed'}},
                        {'plugins': [{'id': 'personal', 'enabled': True, 'error': 'unsupported API'}]},
                        {'discoveryError': 'Cannot inspect personal registry'}]:
            self.setUp()
            self.plugins.update(plugins)
            with self.subTest(plugins=plugins), self.assertRaises(Failure):
                desktop([], self.command, '/guard')

    def test_discovery_must_settle_before_accepting_last_good_entries(self):
        calls = 0
        def discovering(*args):
            nonlocal calls
            if 'listPlugins' in args:
                calls += 1
                self.plugins['discovering'] = calls == 1
            return self.command(*args)
        with patch('nerdos.health.time.sleep') as sleep:
            desktop([], discovering, '/guard')
        self.assertEqual(calls, 2)
        sleep.assert_called_once_with(1)

    def test_unavailable_or_stuck_discovery_cannot_pass_health(self):
        for value in (None, True):
            self.plugins['discovering'] = value
            with self.subTest(value=value), patch('nerdos.health.time.sleep'), self.assertRaises(Failure):
                desktop([], self.command, '/guard')

    def test_end_guard_cannot_mask_failed_begin(self):
        with tempfile.TemporaryDirectory(prefix='nerdos-health-guard-') as directory:
            guard = Path(directory) / 'guard'
            guard.write_text('qs_live_begin() { return 1; }\nqs_live_end() { return 0; }\n')
            def run(*args):
                if args[0] == 'bash':
                    return subprocess.check_output(args, text=True)
                return self.command(*args)
            with self.assertRaises(subprocess.CalledProcessError):
                desktop([], run, guard)
        self.assertEqual(self.calls, [], 'probes ran after a failed guard begin')

    def test_every_probe_is_bracketed_by_the_original_invocation(self):
        for name, change in {'healthy': None, 'restart': 'restart', 'crash': 'crash'}.items():
            with self.subTest(name):
                self.setUp()
                manager = FakeUserManager(self)
                def run(*args):
                    if args[0] == 'bash':
                        return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT, timeout=60).strip()
                    if 'listPlugins' in args and change == 'restart':
                        manager.restart()
                    elif 'listPlugins' in args and change == 'crash':
                        manager.run(active='inactive')
                    return self.command(*args)
                if change is None:
                    desktop([], run, manager.guard)
                else:
                    with self.assertRaises(subprocess.CalledProcessError) as raised:
                        desktop([], run, manager.guard)
                    self.assertIn('restarted during the test' if change == 'restart' else 'does not start it', raised.exception.output)
                # Plugin IPC addressed the recorded process, not a replacement.
                self.assertIn(('--pid', '101'), tuple(args[i:i+2] for args in self.calls for i in range(len(args)-1)))
                self.assertEqual(manager.lines('mutations'), [])
                self.assertEqual(manager.lines('journals')[:1], [INVOCATION])

    def test_unparseable_guard_identity_blocks_probes(self):
        for output in ('', 'qs-live-identity 0 ' + INVOCATION, 'qs-live-identity 12 short',
                       f'qs-live-identity 1 {INVOCATION}\nqs-live-identity 2 {INVOCATION}'):
            self.calls.clear()
            with self.subTest(output=output), self.assertRaisesRegex(Failure, 'service identity is unavailable'):
                desktop([], lambda *args: output if args[0] == 'bash' else self.command(*args), '/guard')
            self.assertEqual(self.calls, [])


class ConfigurationSandboxTests(unittest.TestCase):
    def test_candidate_absolute_paths_are_bound_without_host_configuration(self):
        with patch('nerdos.desktop_check.shutil.which', side_effect=lambda name: '/nix/store/test/bin/' + name):
            command = compositor_command(SYSTEM, '/tmp/task-check.lua')
        self.assertIn('--unshare-all', command)
        self.assertIn('--clearenv', command)
        self.assertIn('--verify-config', command)
        binds = [command[i+1:i+3] for i, value in enumerate(command) if value == '--ro-bind']
        self.assertIn([SYSTEM + '/etc/nerdos', '/etc/nerdos'], binds)
        self.assertNotIn(['/etc', '/etc'], binds)
        self.assertFalse(any(source.startswith('/home/') for source, target in binds))

    def test_namespace_or_compositor_failure_blocks_staging(self):
        with tempfile.TemporaryDirectory(prefix='nerdos-compositor-check-') as directory:
            with patch('nerdos.desktop_check.shutil.which', return_value='/nix/store/test/bin/command'):
                with self.assertRaises(Failure):
                    verify_compositor(SYSTEM, directory,
                                      run=lambda *args, **kwargs: subprocess.CompletedProcess(args, 1, '', 'namespace unavailable'))


if __name__ == '__main__':
    unittest.main()
