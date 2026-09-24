#!/usr/bin/env python3
"""Run both managed launchers with disposable fake compositor processes."""
import json
import os
from pathlib import Path
import shlex
import signal
import subprocess
import tempfile
import time
import unittest

import jinja2


ROOT = Path(__file__).resolve().parents[1]
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
