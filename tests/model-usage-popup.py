#!/usr/bin/env python3
"""Exercise the lazy popup with a private headless Wayland compositor."""
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def main():
    if not shutil.which('qs') or subprocess.run(['pgrep', '-x', 'qs'], stdout=subprocess.DEVNULL).returncode == 0:
        print('Model Usage popup test deferred to isolated CI')
        return
    with tempfile.TemporaryDirectory(prefix='nerdos-model-popup-') as temporary:
        base = Path(temporary)
        runtime = base / 'run'
        runtime.mkdir(mode=0o700)
        env = {**os.environ, 'HOME': str(base), 'XDG_RUNTIME_DIR': str(runtime),
               'XDG_CONFIG_HOME': str(base / 'config'), 'XDG_DATA_HOME': str(base / 'data'),
               'XDG_STATE_HOME': str(base / 'state'), 'QT_QPA_PLATFORM': 'wayland',
               'QT_LOGGING_RULES': 'qml.debug=true',
               'QT_QUICK_BACKEND': 'software', 'WLR_BACKENDS': 'headless',
               'WLR_RENDERER': 'pixman', 'WLR_LIBINPUT_NO_DEVICES': '1'}
        for name in ('DISPLAY', 'WAYLAND_DISPLAY'):
            env.pop(name, None)
        binary = base / 'sway'
        shutil.copyfile(shutil.which('sway'), binary)
        binary.chmod(0o700)
        config = base / 'sway.conf'
        config.write_text('output HEADLESS-1 mode 1280x720\n')
        shell = base / 'shell'
        shutil.copytree(ROOT / 'desktop/quickshell', shell)
        shutil.copyfile(ROOT / 'tests/model-usage-popup/shell.qml', shell / 'shell.qml')
        with (base / 'sway.log').open('w+') as log:
            sway = subprocess.Popen([str(binary), '-c', str(config)], env=env, stdout=log, stderr=subprocess.STDOUT)
            try:
                deadline = time.monotonic() + 10
                sockets = []
                while time.monotonic() < deadline and sway.poll() is None:
                    sockets = [p for p in runtime.glob('wayland-*') if p.is_socket()]
                    if sockets:
                        break
                    time.sleep(.05)
                if not sockets:
                    log.seek(0)
                    raise AssertionError(log.read())
                env['WAYLAND_DISPLAY'] = sockets[0].name
                process = subprocess.Popen(['dbus-run-session', '--', 'qs', '--no-color', '-p', str(shell)],
                                           env=env, text=True, stdout=subprocess.PIPE,
                                           stderr=subprocess.STDOUT, start_new_session=True)
                try:
                    output, _ = process.communicate(timeout=15)
                finally:
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    process.wait()
                assert process.returncode == 0 and 'lazy popup lifecycle passed' in output, f'exit={process.returncode}\n{output}'
                assert not any(error in output for error in ('TypeError', 'ReferenceError', 'Binding loop', 'TEST FAILED')), output
                print('Model Usage lazy popup creation, focus, retained drafts and view switching passed')
            finally:
                sway.terminate()
                try:
                    sway.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    sway.kill()
                    sway.wait()


if __name__ == '__main__':
    if os.geteuid() == 0:
        raise SystemExit(subprocess.call(['runuser', '-u', 'nobody', '--', sys.executable, __file__]))
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    main()
