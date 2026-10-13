#!/usr/bin/env python3
"""Run both managed launchers with disposable fake compositor processes."""
import json
import os
from pathlib import Path
import shlex
import shutil
import signal
import subprocess
import tempfile
import time
import unittest

import jinja2


ROOT = Path(__file__).resolve().parents[1]
AUTOSTART_DRIVER = '''
local start
local calls = 0
hl = {
  on = function(event, callback)
    assert(event == "hyprland.start" and start == nil)
    start = callback
  end,
  exec_cmd = function(command)
    calls = calls + 1
    io.write(command)
  end,
}
dofile(arg[1])
assert(calls == 0, "services must wait for the compositor's startup event")
assert(start, "the session startup callback was not registered")
start()
assert(calls == 1, "session publication must stay in one ordered process")
'''
COMPOSITOR = '''#!/usr/bin/python3
import json, os, signal, sys
from pathlib import Path
root = Path(os.environ['FIXTURE_ROOT'])
with (root / 'starts.jsonl').open('a') as stream:
    stream.write(json.dumps(sys.argv[1:]) + '\\n')
(root / 'compositor.pid').write_text(str(os.getpid()))
if os.environ['FIXTURE_EXIT'] == 'kill':
    signal.pause()
else:
    sys.exit(int(os.environ['FIXTURE_EXIT']))
'''


class SessionAutostartTests(unittest.TestCase):
    """Execute the startup event against each installation's helper layout.

    Development mode on an ISO reads the unmodified checkout Lua, bypassing
    the image packager's /usr/local/libexec -> /usr/libexec rewriting.
    """

    def exercise(self, layout, *, missing=False, nonexecutable_local=False):
        with tempfile.TemporaryDirectory(prefix='cybex-session-start.') as directory:
            root = Path(directory) / 'fixture root'
            binaries = root / 'bin'
            binaries.mkdir(parents=True)
            log = root / 'calls.log'
            local = root / 'usr/local/libexec/cybexos-hyprland-session-start'
            packaged = root / 'usr/libexec/cybexos-hyprland-session-start'
            starter = local if layout == 'checkout' else packaged
            if not missing:
                starter.parent.mkdir(parents=True)
                shutil.copyfile(ROOT / 'roles/desktop/files/hyprland-session-start', starter)
                starter.chmod(0o755)
            if nonexecutable_local:
                local.parent.mkdir(parents=True)
                local.write_text('not executable\n')
                local.chmod(0o644)
            source = (ROOT / 'roles/desktop/files/autostart.lua').read_text()
            if layout == 'image':
                # Keep the packaging rule tied to the actual image builder;
                # the development case deliberately omits this transform.
                rule = 'content.replace("/usr/local/libexec/cybexos-", "/usr/libexec/cybexos-")'
                self.assertIn(rule, (ROOT / 'image/package').read_text())
                source = source.replace('/usr/local/libexec/cybexos-', '/usr/libexec/cybexos-')
            autostart = root / 'autostart.lua'
            autostart.write_text(source)
            selected = subprocess.run(['luajit', '-', str(autostart)], input=AUTOSTART_DRIVER,
                                      text=True, capture_output=True, timeout=5)
            self.assertEqual(selected.returncode, 0, selected.stderr)
            command = selected.stdout
            # Redirect only absolute helper paths into this disposable tree;
            # execute the emitted shell logic and real ordered starter.
            for prefix in ('/usr/local/libexec', '/usr/libexec'):
                command = command.replace(prefix, shlex.quote(str(root / prefix.lstrip('/'))))
            for name in ('systemctl', 'dbus-update-activation-environment', 'sleep'):
                executable = binaries / name
                executable.write_text('#!/bin/sh\n'
                                      f'printf "%s %s\\n" {shlex.quote(name)} "$*" >>"$SESSION_TEST_LOG"\n')
                executable.chmod(0o755)
            environment = dict(os.environ, PATH=f'{binaries}:/usr/bin:/bin',
                               XDG_RUNTIME_DIR=str(root / 'run'), SESSION_TEST_LOG=str(log),
                               WAYLAND_DISPLAY='wayland-fixture', XDG_CURRENT_DESKTOP='Hyprland',
                               HYPRLAND_INSTANCE_SIGNATURE='fixture')
            result = subprocess.run(['sh', '-c', command], env=environment,
                                    text=True, capture_output=True, timeout=5)
            if missing:
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('cybexos-hyprland-session-start', result.stderr)
                self.assertFalse(log.exists())
                return []
            self.assertEqual(result.returncode, 0, result.stderr)
            calls = log.read_text().splitlines()
            self.assertEqual(calls, [
                'systemctl --user import-environment WAYLAND_DISPLAY XDG_CURRENT_DESKTOP HYPRLAND_INSTANCE_SIGNATURE',
                'dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP HYPRLAND_INSTANCE_SIGNATURE',
                'systemctl --user start hyprland-session.target',
                'sleep 1',
                'systemctl --user restart xdg-desktop-portal-hyprland.service xdg-desktop-portal.service',
            ])
            return calls

    def test_checkout_image_and_image_development_start_the_same_session(self):
        expected = self.exercise('checkout')
        for layout in ('image', 'image-development'):
            with self.subTest(layout=layout):
                self.assertEqual(self.exercise(layout), expected)

    def test_image_development_ignores_nonexecutable_local_helper(self):
        self.exercise('image-development', nonexecutable_local=True)

    def test_missing_helper_fails_without_starting_session_services(self):
        for layout in ('checkout', 'image', 'image-development'):
            with self.subTest(layout=layout):
                self.exercise(layout, missing=True)


class SessionLauncherTests(unittest.TestCase):
    def exercise(self, image, behavior):
        with tempfile.TemporaryDirectory(prefix='cybex-session-launcher.') as directory:
            home = Path(directory)
            binaries = home / '.local/bin'
            binaries.mkdir(parents=True)
            runtime = home / 'runtime'
            config = runtime / 'hypr/hyprland.lua'
            config.parent.mkdir(parents=True)
            config.write_text('-- disposable config\n')
            for name, source in {
                'Hyprland': COMPOSITOR,
                'start-hyprland': '#!/bin/sh\nprintf watchdog >"$FIXTURE_ROOT/watchdog"\nexit 93\n',
                'systemctl': '#!/bin/sh\nprintf "%s\\n" "$*" >>"$FIXTURE_ROOT/systemctl.log"\n',
                'dbus-update-activation-environment': '#!/bin/sh\nexit 0\n',
                'busctl': '#!/bin/sh\nprintf \'s "us"\\n\'\n',
                'user-init': '#!/bin/sh\nexit 0\n',
            }.items():
                path = binaries / name
                path.write_text(source)
                path.chmod(0o755)
            if image:
                source = (ROOT / 'image/rootfs/usr/bin/hyprland-quickshell').read_text()
                source = source.replace('/usr/libexec/cybexos-user-init', shlex.quote(str(binaries / 'user-init')))
                source = source.replace('/usr/share/cybexos/runtime/hypr/hyprland.lua', shlex.quote(str(config)))
            else:
                environment = jinja2.Environment(undefined=jinja2.StrictUndefined)
                environment.filters['quote'] = shlex.quote
                source = environment.from_string(
                    (ROOT / 'roles/desktop/templates/hyprland-quickshell.j2').read_text()
                ).render(cybexos_runtime_root=str(runtime))
            launcher = home / 'launcher'
            launcher.write_text(source)
            environment = dict(os.environ, HOME=str(home), XDG_RUNTIME_DIR=str(home / 'run'),
                               XDG_STATE_HOME=str(home / 'state'), PATH=f'{binaries}:/usr/bin:/bin',
                               FIXTURE_ROOT=str(home), FIXTURE_EXIT=behavior)
            process = subprocess.Popen(['bash', str(launcher), '--fixture-option'], env=environment,
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                       start_new_session=True)
            try:
                if behavior == 'kill':
                    deadline = time.monotonic() + 5
                    while not (home / 'compositor.pid').exists():
                        if process.poll() is not None or time.monotonic() >= deadline:
                            self.fail('The fixture compositor did not start')
                        time.sleep(0.01)
                    os.kill(int((home / 'compositor.pid').read_text()), signal.SIGKILL)
                _, stderr = process.communicate(timeout=5)
                expected = 128 + signal.SIGKILL if behavior == 'kill' else int(behavior)
                self.assertEqual(process.returncode, expected, stderr)
                starts = (home / 'starts.jsonl').read_text().splitlines()
                self.assertEqual(len(starts), 1, 'The compositor was restarted inside the old login')
                self.assertEqual(json.loads(starts[0]), ['--config', str(config), '--fixture-option'])
                self.assertFalse((home / 'watchdog').exists(), 'The restart watchdog was invoked')
                commands = (home / 'systemctl.log').read_text().splitlines()
                self.assertEqual(commands.count('--user stop hyprland-session.target'), 1)
                self.assertEqual(commands[-1], '--user stop hyprland-session.target')
            finally:
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.communicate(timeout=5)

    def test_compositor_sigkill_exits_both_sessions_without_restart(self):
        for image in (False, True):
            with self.subTest(image=image):
                self.exercise(image, 'kill')

    def test_startup_failure_and_normal_exit_both_stop_session_services(self):
        for image in (False, True):
            for status in ('0', '17'):
                with self.subTest(image=image, status=status):
                    self.exercise(image, status)


if __name__ == '__main__':
    unittest.main()
