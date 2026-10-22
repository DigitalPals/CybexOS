"""Harmless real detached writer, with a fixture-only cgroup/manager boundary."""
import ctypes
import fcntl
import importlib.machinery
import importlib.util
import io
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import types
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]
loader = importlib.machinery.SourceFileLoader(
    'contained_provision_fixture', str(ROOT / 'image/rootfs/usr/libexec/cybexos-configure-installed'))
spec = importlib.util.spec_from_loader(loader.name, loader)
configure = importlib.util.module_from_spec(spec)
loader.exec_module(configure)
REAL_RUN = subprocess.run
REAL_POPEN = subprocess.Popen


class ProvisionContainment(unittest.TestCase):
    def test_journal_progress_and_failure_tail_are_scoped_to_each_launch(self):
        launches, reads, events = [], [], []
        cursors = {}
        def launch(command, **_options):
            launches.append(command)
            self.assertNotIn('--pipe', command)
            self.assertIn('--property=StandardOutput=journal', command)
            self.assertIn('--property=StandardError=journal', command)
            self.assertIn('--property=RuntimeMaxSec=2s', command)
            client = Mock()
            client.__enter__ = Mock(return_value=client)
            client.__exit__ = Mock(return_value=False)
            client.wait.side_effect = [subprocess.TimeoutExpired(command, 15), 42]
            client.poll.return_value = 42
            return client
        def journal(command, **options):
            identifier = next(item.split('=', 1)[1] for item in command
                              if item.startswith('SYSLOG_IDENTIFIER='))
            self.assertIn('--lines=100', command)
            self.assertEqual(options['timeout'], 5)
            reads.append(identifier)
            if identifier in cursors:
                self.assertIn('--after-cursor=' + cursors[identifier], command)
                events.append('failure-tail')
                return types.SimpleNamespace(stdout='worker failed\n-- cursor: final\n')
            cursors[identifier] = 'cursor-' + str(len(cursors))
            events.append('progress')
            return types.SimpleNamespace(stdout='worker running\n-- cursor: ' + cursors[identifier] + '\n')
        with patch.object(configure, 'drain', side_effect=lambda: events.append('drain')), \
                patch.object(configure.subprocess, 'Popen', side_effect=launch), \
                patch.object(configure.subprocess, 'run', side_effect=journal), \
                patch('sys.stdout', new_callable=io.StringIO) as output:
            for _ in range(2):
                with self.assertRaises(subprocess.CalledProcessError) as failure:
                    configure.contained(['fixture'], env={}, timeout=2)
                self.assertEqual(failure.exception.returncode, 42)
        self.assertEqual(events, ['drain', 'progress', 'drain', 'failure-tail'] * 2)
        identifiers = [next(item.split('=', 2)[2] for item in command
                            if item.startswith('--property=SyslogIdentifier=')) for command in launches]
        self.assertNotEqual(*identifiers)
        self.assertEqual(reads, [identifiers[0]] * 2 + [identifiers[1]] * 2)
        self.assertEqual(output.getvalue().count('worker failed'), 2)
        self.assertIn('still running', output.getvalue())
        self.assertNotIn('-- cursor:', output.getvalue())

    def test_journal_failure_does_not_hide_workload_failure_or_skip_drain(self):
        client = Mock()
        client.__enter__ = Mock(return_value=client)
        client.__exit__ = Mock(return_value=False)
        client.wait.return_value = client.poll.return_value = 23
        with patch.object(configure, 'drain') as drain, \
                patch.object(configure.subprocess, 'Popen', return_value=client), \
                patch.object(configure.subprocess, 'run', side_effect=subprocess.TimeoutExpired('journalctl', 5)), \
                patch('sys.stderr', new_callable=io.StringIO) as error:
            with self.assertRaises(subprocess.CalledProcessError) as failure:
                configure.contained(['fixture'], env={}, timeout=2)
        self.assertEqual(failure.exception.returncode, 23)
        self.assertEqual(drain.call_count, 2)
        self.assertIn('journal unavailable', error.getvalue())

    def test_journal_batch_output_is_bounded(self):
        with patch.object(configure.subprocess, 'run', return_value=types.SimpleNamespace(
                stdout='x' * 50000 + '\n-- cursor: next\n')), \
                patch('sys.stdout', new_callable=io.StringIO) as output:
            self.assertEqual(configure.provision_output('fixture'), 'next')
        self.assertLess(len(output.getvalue()), 33000)
        self.assertIn('truncated', output.getvalue())

    def test_detached_writer_cannot_write_or_overlap_retry_after_timeout(self):
        # No systemd unit/cgroup is created on the host. Only this temporary
        # writer process is real; manager/cgroup operations target its recorded
        # PID handles and cannot signal unrelated host processes.
        with tempfile.TemporaryDirectory(prefix='cybexos-contained-writer-') as temporary:
            root = Path(temporary)
            members, output, lockfile = root / 'members', root / 'writes', root / 'lock'
            worker = root / 'worker.py'
            worker.write_text('''import os,pathlib,signal,sys,time
members,output = map(pathlib.Path,sys.argv[1:])
child = os.fork()
if child == 0:
 os.setsid()
 signal.signal(signal.SIGTERM,signal.SIG_IGN)
 while True:
  with output.open('a') as stream: stream.write('descendant\\n')
  time.sleep(.01)
members.write_text(str(os.getpid())+' '+str(child))
time.sleep(60)
''')
            # Adopt and reap the detached child after its direct parent dies.
            # This setting is local to the fixture Python process.
            libc = ctypes.CDLL(None, use_errno=True)
            previous_subreaper = ctypes.c_int()
            self.assertEqual(libc.prctl(37, ctypes.byref(previous_subreaper), 0, 0, 0), 0)
            self.assertEqual(libc.prctl(36, 1, 0, 0, 0), 0)
            handles = []
            killed_while_locked = []
            events = []
            def alive(pid):
                path = Path('/proc') / str(pid) / 'stat'
                return path.exists() and path.read_text().split()[2] != 'Z'
            def member_pids():
                return [int(value) for value in members.read_text().split()] if members.exists() else []
            class GroupFile:
                def __init__(self, name):
                    self.name = name
                def read_text(self):
                    return 'populated ' + str(int(any(alive(pid) for pid in member_pids())))
                def write_text(self, value):
                    self.assert_kill(value)
                def assert_kill(self, value):
                    if self.name != 'cgroup.kill' or value != '1\n':
                        raise AssertionError('Unexpected cgroup write')
                    with lockfile.open('a') as other:
                        try:
                            fcntl.flock(other, fcntl.LOCK_EX | fcntl.LOCK_NB)
                        except BlockingIOError:
                            killed_while_locked.append(True)
                        else:
                            raise AssertionError('Serialization released before descendants stopped')
                    for pid in member_pids():
                        if alive(pid):
                            handle = os.pidfd_open(pid)
                            handles.append(handle)
                            signal.pidfd_send_signal(handle, signal.SIGKILL)
                    events.append('kill-all')
            class Group:
                def __truediv__(self, name):
                    return GroupFile(name)
            calls = []
            def manager(command, **options):
                calls.append(command)
                return types.SimpleNamespace(returncode=0, stdout='')
            def launch(command, **options):
                calls.append(command)
                if '--fixture-retry' in command:
                    self.assertFalse(any(alive(pid) for pid in member_pids()))
                    events.append('retry')
                    return REAL_POPEN([sys.executable, '-B', '-c', 'pass'])
                child = REAL_POPEN([sys.executable, '-B', str(worker), str(members), str(output)])
                wait = child.wait
                def bounded_wait(timeout=None):
                    if timeout is None:
                        return wait()
                    try:
                        return wait(timeout=.35)
                    finally:
                        # The setsid child ignores TERM and still writes
                        # until cgroup teardown, even after the client dies.
                        self.assertTrue(output.exists() and output.stat().st_size > 0)
                        self.assertTrue(any(alive(pid) for pid in member_pids()))
                        events.append('direct-timeout')
                child.wait = bounded_wait
                return child
            try:
                with patch.object(configure, 'WORK_CGROUP', Group()), \
                        patch.object(configure, 'require_manager'), \
                        patch.object(configure.subprocess, 'run', side_effect=manager), \
                        patch.object(configure.subprocess, 'Popen', side_effect=launch), \
                        patch.object(configure.time, 'monotonic', side_effect=[0, 0, 62, 63, 63]):
                    with lockfile.open('a') as lock:
                        fcntl.flock(lock, fcntl.LOCK_EX)
                        with self.assertRaises(subprocess.TimeoutExpired):
                            configure.contained(['fixture'], env={'PATH': '/usr/bin'}, timeout=1)
                    settled = output.read_bytes()
                    time.sleep(.1)
                    self.assertEqual(output.read_bytes(), settled)
                    with lockfile.open('a') as lock:
                        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                        configure.contained(['--fixture-retry'], env={'PATH': '/usr/bin'}, timeout=1)
                    self.assertEqual(output.read_bytes(), settled)
                self.assertTrue(killed_while_locked)
                self.assertEqual(events, ['direct-timeout', 'kill-all', 'retry'])
                launch = next(command for command in calls if command[0].endswith('systemd-run'))
                self.assertIn('--property=ExitType=cgroup', launch)
                self.assertIn('--property=KillMode=control-group', launch)
                self.assertIn('--property=RuntimeMaxSec=1s', launch)
                self.assertNotIn('--pipe', launch)
            finally:
                for pid in member_pids():
                    if alive(pid):
                        handle = os.pidfd_open(pid)
                        signal.pidfd_send_signal(handle, signal.SIGKILL)
                        os.close(handle)
                for handle in handles:
                    os.close(handle)
                for pid in member_pids():
                    try:
                        os.waitpid(pid, 0)
                    except ChildProcessError:
                        pass
                self.assertEqual(libc.prctl(36, previous_subreaper.value, 0, 0, 0), 0)

    def test_real_nonzero_result_is_preserved_after_drain(self):
        client = Mock()
        client.__enter__ = Mock(return_value=client)
        client.__exit__ = Mock(return_value=False)
        client.wait.return_value = client.poll.return_value = 42
        with patch.object(configure, 'drain') as drain, \
                patch.object(configure, 'provision_output') as output, \
                patch.object(configure.subprocess, 'Popen', return_value=client):
            with self.assertRaises(subprocess.CalledProcessError) as raised:
                configure.contained(['fixture'], env={}, timeout=1)
        self.assertEqual(raised.exception.returncode, 42)
        self.assertEqual(drain.call_count, 2)
        output.assert_called_once()
        client.kill.assert_not_called()

    def test_live_manager_failure_never_falls_back_to_uncontained_ansible(self):
        account = types.SimpleNamespace(pw_name='qualification', pw_gid=1000, pw_dir='/home/qualification')
        failure = subprocess.CalledProcessError(1, ['systemd-run'])
        with patch.object(configure.grp, 'getgrgid', return_value=types.SimpleNamespace(gr_name='qualification')), \
                patch.object(configure.grp, 'getgrnam', return_value=types.SimpleNamespace(gr_mem=[], gr_gid=10)), \
                patch.object(configure, 'drain'), \
                patch.object(configure, 'provision_output'), \
                patch.object(configure.subprocess, 'Popen', side_effect=failure) as run:
            with self.assertRaises(subprocess.CalledProcessError):
                configure.configure(account, offline=True)
        self.assertEqual(run.call_count, 1)
        self.assertEqual(run.call_args.args[0][0], '/usr/bin/systemd-run')

    def test_only_explicit_verified_offline_installer_target_uses_direct_ansible(self):
        for arguments, chroot in ((['--installer-target'], 0),
                                  (['--offline', '--installer-target'], 1)):
            with self.subTest(arguments=arguments, chroot=chroot), \
                    patch('sys.argv', ['configure-installed', *arguments]), \
                    patch.object(configure.os, 'geteuid', return_value=0), \
                    patch.object(configure.subprocess, 'run', return_value=types.SimpleNamespace(returncode=chroot)), \
                    patch.object(configure, 'configure') as apply:
                with self.assertRaises(SystemExit) as failure:
                    configure.main()
                self.assertEqual(failure.exception.code, 2)
                apply.assert_not_called()
        account = types.SimpleNamespace(pw_name='qualification', pw_gid=1000, pw_dir='/home/qualification')
        with patch.object(configure.grp, 'getgrgid', return_value=types.SimpleNamespace(gr_name='qualification')), \
                patch.object(configure.grp, 'getgrnam', return_value=types.SimpleNamespace(gr_mem=[], gr_gid=10)), \
                patch.object(configure, 'contained') as contained, \
                patch.object(configure.subprocess, 'run') as run:
            configure.configure(account, offline=True, installer_target=True)
        contained.assert_not_called()
        self.assertEqual(run.call_args.args[0][0], '/usr/bin/ansible-playbook')
        self.assertEqual(run.call_args.kwargs['timeout'], 2700)

    def test_installer_dispatch_and_live_manager_failure_precede_any_saved_choice_changes(self):
        with tempfile.TemporaryDirectory(prefix='cybexos-installer-context-') as temporary:
            root = Path(temporary)
            provision = root / 'provision'
            provision.mkdir()
            (root / 'run/lock').mkdir(parents=True)
            saved = root / 'etc/cybexos/config.yml'
            saved.parent.mkdir(parents=True)
            saved.write_text('personal saved choices')
            account = types.SimpleNamespace(pw_name='qualification', pw_uid=1000, pw_gid=1000,
                                            pw_dir='/home/qualification')
            def guest_path(value):
                return root / value.lstrip('/') if str(value).startswith('/') else Path(value)
            for installer in (True, False):
                with self.subTest(installer=installer), \
                        patch.object(configure, 'Path', side_effect=guest_path), \
                        patch.object(configure, 'PROVISION', provision), \
                        patch.object(configure.os, 'geteuid', return_value=0), \
                        patch.object(configure.pwd, 'getpwall', return_value=[account]), \
                        patch.object(configure, 'load') as settings, \
                        patch.object(configure, 'configure') as apply, \
                        patch.object(configure, 'retire_legacy_fish'), \
                        patch.object(configure.signal, 'signal'), \
                        patch.object(configure, 'require_manager', side_effect=subprocess.CalledProcessError(1, ['systemctl'])) as manager, \
                        patch.object(configure.subprocess, 'run', return_value=types.SimpleNamespace(returncode=0)) as command, \
                        patch('sys.argv', ['configure-installed', '--offline'] + (['--installer-target'] if installer else [])):
                    settings.return_value.ensure.return_value = False
                    if installer:
                        configure.main()
                        manager.assert_not_called()
                        command.assert_called_once_with(['/usr/bin/systemd-detect-virt', '--chroot', '--quiet'], check=False)
                        self.assertTrue(apply.call_args.kwargs['installer_target'])
                        self.assertEqual(apply.call_args.args[1:4], (True, False, False))
                    else:
                        with self.assertRaises(subprocess.CalledProcessError):
                            configure.main()
                        apply.assert_not_called()
                        settings.assert_not_called()
                    self.assertEqual(saved.read_text(), 'personal saved choices')

    def test_early_cancellation_does_not_attempt_drain_before_privilege_setup(self):
        updater = (ROOT / 'assets/scripts/cybexos-update-run').read_text()
        body = updater.split('finish_failed_transaction() {', 1)[1].split('\n}\n', 1)[0]
        script = ('set -uo pipefail\ntransaction_started=false\ncalled=false\n'
                  'drain_installed_provisioning() { called=true; }\n'
                  'finish_failed_transaction() {' + body + '\n}\n'
                  'finish_failed_transaction\n[[ $called == false ]] || exit 91\n'
                  'privileged_package=(fixture)\nfinish_failed_transaction\n'
                  '[[ $called == true ]] || exit 92\n')
        result = REAL_RUN(['bash', '-s'], input=script, text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_updater_probes_old_helper_and_propagates_new_drain_failure(self):
        updater = (ROOT / 'assets/scripts/cybexos-update-run').read_text()
        function = updater.split('drain_installed_provisioning() {', 1)[1].split('\n}\n', 1)[0]
        with tempfile.TemporaryDirectory(prefix='cybexos-drain-interface-') as temporary:
            root = Path(temporary)
            helper, marker = root / 'configure-installed', root / 'drained'
            function = function.replace('/usr/libexec/cybexos-configure-installed', str(helper))
            script = ('set -uo pipefail\nprivileged_package=()\nrun_dir=' + str(root) + '\n'
                      'drain_installed_provisioning() {' + function + '\n}\ndrain_installed_provisioning\n')
            for mode, result in (('old', 0), ('new', 0), ('failed', 23), ('broken-help', 9)):
                with self.subTest(mode=mode):
                    marker.unlink(missing_ok=True)
                    helper.write_text('#!/bin/sh\nif [ "$1" = --help ]; then\n' +
                                      ('exit 9\n' if mode == 'broken-help' else
                                       'echo "usage: --offline' + (' --drain' if mode != 'old' else '') + '"; exit 0\n') +
                                      'fi\n[ "$1" = --drain ] || exit 99\ntouch ' + str(marker) + '\n' +
                                      ('exit 23\n' if mode == 'failed' else 'exit 0\n'))
                    helper.chmod(0o700)
                    completed = REAL_RUN(['bash', '-s'], input=script, text=True, capture_output=True, timeout=10)
                    # A failed interface probe is fail-closed, not legacy support.
                    self.assertEqual(completed.returncode, 1 if mode == 'broken-help' else result)
                    self.assertEqual(marker.exists(), mode in ('new', 'failed'))


if __name__ == '__main__':
    unittest.main()
