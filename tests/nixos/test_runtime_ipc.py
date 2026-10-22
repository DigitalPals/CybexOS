"""Isolated runtime resolver and real minimal headless IPC regression.

No live menubar or user service is started, stopped or replaced.
"""
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
QS = shutil.which('qs')


class RuntimeIpcTests(unittest.TestCase):
    def setUp(self):
        # Nix builders can have a long TMPDIR. Quickshell's IPC socket lives
        # below XDG_RUNTIME_DIR and must fit Linux's 108-byte sockaddr_un path.
        self.temporary = tempfile.TemporaryDirectory(prefix='cy-ipc.', dir='/tmp')
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name)
        vendor = root / 'vendor'; vendor.mkdir()
        self.shell = vendor / 'quickshell'; self.shell.mkdir()
        runtime = root / 'runtime'; runtime.symlink_to(vendor)
        self.alias_shell = runtime / 'quickshell'
        self.helper = self.alias_shell / 'compat/omarchy/bin/omarchy-shell'
        self.helper.parent.mkdir(parents=True)
        shutil.copy2(ROOT / 'desktop/quickshell/compat/omarchy/bin/omarchy-shell', self.helper)
        (self.shell / 'shell.qml').write_text('''import Quickshell
import Quickshell.Io
ShellRoot {
    IpcHandler {
        target: "shell"
        function ping(): string { return "pong" }
        function rescanPlugins(): string { return "rescanned" }
    }
}
''')
        (self.shell / 'scripts').mkdir()
        shutil.copy2(ROOT / 'desktop/quickshell/scripts/shell-recovery.py', self.shell / 'scripts/shell-recovery.py')
        self.command = root / 'nerdos-runtime'
        source = (ROOT / 'assets/scripts/nerdos-runtime').read_text()
        self.assertEqual(source.count('runtime_root=/etc/nerdos/runtime'), 1)
        self.command.write_text(source.replace('runtime_root=/etc/nerdos/runtime', 'runtime_root=' + shlex.quote(str(runtime))))
        self.command.chmod(0o755)
        xdg = root / 'xdg'; xdg.mkdir(mode=0o700)
        self.environment = os.environ | {
            'HOME': str(root / 'home'), 'XDG_RUNTIME_DIR': str(xdg),
            'XDG_CONFIG_HOME': str(root / 'config'), 'XDG_DATA_HOME': str(root / 'data'),
            'XDG_STATE_HOME': str(root / 'state'), 'QT_QPA_PLATFORM': 'offscreen',
            'QT_QUICK_BACKEND': 'software', 'NERDOS_RUNTIME_TESTING': '1',
        }
        self.environment.pop('DISPLAY', None)
        self.environment.pop('WAYLAND_DISPLAY', None)

    def run_command(self, *arguments):
        return subprocess.run(list(map(str, arguments)), env=self.environment,
                              capture_output=True, text=True, timeout=5)

    def test_immutable_runtime_alias_resolves_to_one_canonical_identity(self):
        result = self.run_command(self.command, 'path', 'quickshell')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), str(self.shell))

    @unittest.skipUnless(QS, 'Quickshell required for the real headless IPC regression')
    def test_service_launcher_runtime_ipc_and_omarchy_plugin_reload_share_identity(self):
        with tempfile.TemporaryFile(mode='w+') as log:
            process = subprocess.Popen([str(self.command), 'exec', 'quickshell'],
                                       env=self.environment, stdout=log, stderr=subprocess.STDOUT)
            try:
                deadline = time.monotonic() + 15
                while time.monotonic() < deadline:
                    result = self.run_command(self.command, 'ipc', 'shell', 'ping')
                    if result.returncode == 0 and result.stdout.strip() == 'pong':
                        break
                    if process.poll() is not None:
                        log.seek(0)
                        self.fail('Headless fixture exited: ' + log.read())
                    time.sleep(.1)
                else:
                    log.seek(0)
                    self.fail('Headless fixture IPC unavailable: ' + log.read())
                # The helper resolves its bundled path with pwd -P, including
                # when it is invoked through the installed runtime alias.
                helper = self.run_command(self.helper, 'shell', 'ping')
                self.assertEqual(helper.returncode, 0, helper.stderr)
                self.assertEqual(helper.stdout.strip(), 'pong')
                reload = self.run_command(self.command, 'plugin', 'reload')
                self.assertEqual(reload.returncode, 0, reload.stderr)
                self.assertEqual(reload.stdout.strip(), 'rescanned')
            finally:
                # Terminate only this test's own minimal fixture process.
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=5)
                self.assertIsNotNone(process.poll())


if __name__ == '__main__':
    unittest.main()
