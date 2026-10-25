#!/usr/bin/env python3
"""Exercise the real first-login guide under a private headless compositor.

Run through nix develop, with grim and wtype on PATH. All service probes and
writes inherit a private HOME/XDG tree. No installed desktop is modified.
Only requested screenshots survive teardown; failed logs are printed inline.
"""
from __future__ import annotations
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
ERRORS = re.compile(r'TypeError|ReferenceError|Binding loop|is not a type|Type \w+ unavailable'
                    r'|Cannot assign|Unable to assign|Illegal method name|Failed to load configuration')


class Session:
    def __init__(self, base, imports):
        self.base = base
        self.home = base / 'home'
        self.runtime = base / 'run'
        self.runtime.mkdir(mode=0o700)
        config = self.home / '.config/cybexos'
        config.mkdir(parents=True)
        wallpapers = self.home / 'Pictures/Wallpapers'
        wallpapers.mkdir(parents=True)
        for name in ('moon-mountains.png', 'quiet-fjord.png', 'blue-hour.png'):
            shutil.copyfile(ROOT / 'assets/wallpapers' / name, wallpapers / name)
        (config / 'dev-source').write_text(str(ROOT) + '\n')
        (config / 'shell.json').write_text(json.dumps({'v': 30, 'wall': 'moon-mountains.png',
            'wallDir': str(wallpapers), 'assistantShown': False, 'paletteMode': 'fixed'}))
        self.env = {**os.environ, 'HOME': str(self.home), 'XDG_RUNTIME_DIR': str(self.runtime),
            'XDG_CONFIG_HOME': str(self.home / '.config'), 'XDG_DATA_HOME': str(self.home / '.local/share'),
            'XDG_STATE_HOME': str(self.home / '.local/state'), 'XDG_CACHE_HOME': str(self.home / '.cache'),
            'QT_QPA_PLATFORM': 'wayland', 'QT_QUICK_BACKEND': 'software',
            'QT_PLUGIN_PATH': os.environ.get('CYBEXOS_QT_PLUGIN_PATH', ''),
            'WLR_BACKENDS': 'headless', 'WLR_RENDERER': 'pixman', 'WLR_LIBINPUT_NO_DEVICES': '1',
            'HYPRLAND_INSTANCE_SIGNATURE': '', 'CYBEXOS_LANG': 'en', 'CYBEXOS_WELCOME': '1',
            'CYBEXOS_CONNECTED_WIDGETS': '0', 'CYBEXOS_DEVELOPER_TOOLS': '0',
            'CYBEXOS_THEME_ROOT': str(self.home / '.local/share/cybexos/themes'),
            'QML_IMPORT_PATH': str(imports) + ':' + os.environ.get('CYBEXOS_QML_IMPORT_PATH', ''),
            'PATH': str(ROOT / 'assets/scripts') + ':' + os.environ['PATH']}
        for key in ('DISPLAY', 'WAYLAND_DISPLAY', 'SWAYSOCK', 'DBUS_SESSION_BUS_ADDRESS'):
            self.env.pop(key, None)
        self.processes = []
        self.shell = None
        self.logs = []

    def start(self, argv, name):
        log = self.base / name
        self.logs.append(log)
        with log.open('w') as output:
            process = subprocess.Popen(argv, env=self.env, stdout=output, stderr=subprocess.STDOUT,
                                       start_new_session=True)
        self.processes.append(process)
        return process

    def stop_process(self, process):
        if process is None:
            return
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=5)

    def stop(self):
        for process in reversed(self.processes):
            self.stop_process(process)

    def start_shell(self, name):
        if self.shell is not None:
            self.stop_process(self.shell)
        dbus = ['dbus-run-session']
        if os.environ.get('CYBEXOS_DBUS_SESSION_CONFIG'):
            dbus += ['--config-file', os.environ['CYBEXOS_DBUS_SESSION_CONFIG']]
        self.shell = self.start([*dbus, '--', 'qs', '--no-color', '-p', str(ROOT / 'desktop/quickshell')], name)
        self.wait(lambda: self.state(), 'welcome IPC')

    def ipc(self, *args):
        # The public runtime route resolves the source through this session's
        # private dev-source, exercising the same path identity as installation.
        result = subprocess.run([str(ROOT / 'assets/scripts/cybexos-runtime'), 'ipc', 'welcome', *args],
            env=self.env, capture_output=True, text=True, timeout=10)
        return result.stdout.strip() if result.returncode == 0 else ''

    def state(self):
        try:
            return json.loads(self.ipc('status'))
        except (json.JSONDecodeError, subprocess.TimeoutExpired):
            return {}

    def wait(self, predicate, label, timeout=30):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            value = predicate()
            if value:
                return value
            time.sleep(.15)
        raise AssertionError('Timed out: ' + label)

    def key(self, *args):
        subprocess.run(['swaymsg', '[title="Welcome to Cybex OS"] focus'], env=self.env, check=True, capture_output=True)
        subprocess.run(['wtype', '-s', '200', *args, '-s', '100'], env=self.env, check=True, timeout=10)
        time.sleep(.25)

    def capture(self, output, step):
        if output:
            # Let async wallpaper thumbnails and the short step fade settle.
            time.sleep(.8)
            subprocess.run(['grim', str(output / step)], env=self.env, check=True, timeout=15)

    @property
    def state_path(self):
        return self.home / '.local/state/cybexos/welcome.json'

    def check_logs(self):
        failures = []
        for path in self.logs:
            if not path.name.startswith('qs'):
                continue
            for line in path.read_text(errors='replace').splitlines():
                if ERRORS.search(line) or (('WARN' in line or 'ERROR' in line)
                        and re.search(r'(Welcome(?:Window|Helpers)?\.qml|Welcome/)', line)):
                    failures.append(line)
        assert not failures, '\n'.join(failures)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--screenshots', type=Path)
    args = parser.parse_args()
    for executable in ('qs', 'sway', 'grim', 'wtype', 'cmake'):
        if not shutil.which(executable):
            raise SystemExit(f'{executable} is required; use nix develop with grim and wtype')
    if args.screenshots:
        args.screenshots.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='cybexos-welcome-', dir=args.screenshots) as temporary:
        base = Path(temporary)
        native = base / 'native'
        subprocess.run(['cmake', '-S', str(ROOT / 'desktop/notification-images'), '-B', str(native),
                        '-DCMAKE_BUILD_TYPE=Release', '-DBUILD_TESTING=OFF'], check=True, capture_output=True)
        subprocess.run(['cmake', '--build', str(native), '--parallel', '2'], check=True, capture_output=True)
        session = Session(base, native / 'qml')
        try:
            conf = base / 'sway.conf'
            conf.write_text('output HEADLESS-1 mode 1440x900\nseat seat0 fallback true\n'
                'for_window [title="Welcome to Cybex OS"] floating enable, move position center\n')
            sway = base / 'sway'
            shutil.copyfile(os.environ.get('CYBEXOS_SWAY_BINARY') or shutil.which('sway'), sway)
            sway.chmod(0o700)
            session.start([str(sway), '-c', str(conf)], 'sway.log')
            sockets = session.wait(lambda: [p for p in session.runtime.glob('wayland-*') if p.is_socket()], 'Sway')
            session.env['WAYLAND_DISPLAY'] = sockets[0].name
            session.env['SWAYSOCK'] = str(session.wait(lambda: next(session.runtime.glob('sway-ipc.*.sock'), None), 'Sway IPC'))
            # Real seeded web apps, entirely offline and under private HOME.
            subprocess.run([str(ROOT / 'assets/scripts/cybexos-webapp'), 'seed'], env=session.env,
                           check=True, capture_output=True)
            session.start_shell('qs-first.log')
            session.wait(lambda: session.state().get('open'), 'first-login auto opening')
            assert session.state()['step'] == 'hello'
            assert session.ipc('open', 'unknown') == 'unknown'
            for step in ('hello', 'wallpaper', 'style', 'keys', 'shortcuts', 'finish'):
                assert session.ipc('open', step) == 'ok'
                session.wait(lambda: session.state().get('step') == step, step)
                session.capture(args.screenshots, 'welcome-' + step + '-en.png')
            # Enter activates the primary action with initial page focus.
            session.key('-k', 'Return')
            session.wait(lambda: session.state().get('status') == 'completed', 'Finish')
            assert not session.state()['open']
            session.ipc('open', '')
            assert session.state()['step'] == 'hello'
            session.ipc('open', 'wallpaper')
            # One virtual keyboard owns the entire press/release pair.
            # Disconnecting wtype between them releases every pressed key.
            subprocess.run(['swaymsg', '[title="Welcome to Cybex OS"] focus'], env=session.env, check=True, capture_output=True)
            peek = session.start(['wtype', '-s', '200', '-p', 'space', '-s', '2000', '-r', 'space'], 'peek.log')
            time.sleep(.5)
            session.capture(args.screenshots, 'welcome-wallpaper-peek-en.png')
            peek.wait(timeout=5)
            assert session.state()['open'], 'Space keeps the window mapped'
            if args.screenshots:
                from PIL import Image, ImageChops, ImageStat
                session.ipc('close')
                session.capture(session.base, 'desktop.png')
                peek_image = Image.open(args.screenshots / 'welcome-wallpaper-peek-en.png').convert('RGB')
                desktop = Image.open(session.base / 'desktop.png').convert('RGB')
                difference = ImageChops.difference(peek_image.crop((350, 240, 1300, 740)), desktop.crop((350, 240, 1300, 740)))
                assert max(ImageStat.Stat(difference).mean) < 2, 'Space must reveal the actual wallpaper'
                session.ipc('open', 'wallpaper')
            session.key('-M', 'ctrl', '-k', 'Next', '-m', 'ctrl')
            session.wait(lambda: session.state().get('step') == 'style', 'Ctrl+PageDown')
            session.key('-M', 'ctrl', '-k', 'Prior', '-m', 'ctrl')
            assert session.state()['step'] == 'wallpaper'
            session.key('-k', 'Tab')
            session.key('-k', 'Escape')
            session.wait(lambda: session.state().get('status') == 'dismissed', 'Escape dismiss')
            session.wait(lambda: session.state_path.exists() and json.loads(session.state_path.read_text()).get('status') == 'dismissed', 'saved dismissal')
            session.start_shell('qs-restart.log')
            time.sleep(1)
            assert not session.state()['open'] and session.state()['status'] == 'dismissed'
            session.ipc('open', '')
            assert session.state()['step'] == 'wallpaper'
            session.env['CYBEXOS_LANG'] = 'nl'
            session.start_shell('qs-dutch.log')
            session.ipc('open', 'hello')
            session.capture(args.screenshots, 'welcome-hello-nl.png')
            session.ipc('close')
            session.wait(lambda: json.loads(session.state_path.read_text())['status'] == 'dismissed', 'saved Dutch dismissal')
            session.stop_process(session.shell)
            session.state_path.write_text('{broken')
            session.env['CYBEXOS_LANG'] = 'en'
            session.start_shell('qs-invalid.log')
            assert not session.state()['open']
            session.ipc('open', 'style')
            session.ipc('close')
            time.sleep(.5)
            assert session.state_path.read_text() == '{broken', 'invalid bytes must survive manual use'
            # Reset removes only the guide file, including a protected document.
            sentinel = session.state_path.parent / 'unrelated.json'
            sentinel.write_text('keep')
            session.ipc('reset')
            session.wait(lambda: not session.state_path.exists(), 'reset')
            assert sentinel.read_text() == 'keep'
            session.env['CYBEXOS_WELCOME'] = '0'
            session.start_shell('qs-disabled.log')
            time.sleep(1)
            assert not session.state()['open'], 'environment suppression'
            session.check_logs()
            print('PASS: first login, all six steps, Finish, Space peek, keyboard navigation, dismissal/resume across restart, Dutch, protected invalid state, reset and environment suppression')
        except Exception:
            for log in session.logs:
                if log.name.startswith('qs'):
                    print(log.name + '\n' + log.read_text(errors='replace')[-20000:])
            raise
        finally:
            session.stop()


if __name__ == '__main__':
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(SystemExit(143)))
    main()
