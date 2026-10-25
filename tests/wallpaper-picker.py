#!/usr/bin/env python3
"""Exercise the real shell/picker under private headless Sway, never a session.

Run in nix develop with grim on PATH. Only screenshots are retained in the
requested output directory; every process, copied runtime and HOME is private
and removed in finally. Two live API requests (listing/details) are allowed.
"""
from __future__ import annotations
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import tempfile
import time

import shell_fonts

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = Path(os.environ.get('CYBEXOS_WALLPAPER_SCREENSHOTS', '/data/tmp/cybexos-onboarding-wallpaper'))
QML_ERRORS = re.compile(r'TypeError|ReferenceError|Binding loop|is not a type|Type \w+ unavailable'
                        r'|Cannot assign|Unable to assign|Illegal method name|Failed to load configuration')


def process_guard(owned_runtime=None):
    main = subprocess.run(['systemctl', '--user', 'show', 'quickshell.service', '-p', 'MainPID', '--value'],
                          capture_output=True, text=True).stdout.strip()
    pids = set()
    for name in ('qs', '.quickshell-wra'):
        result = subprocess.run(['pgrep', '-u', str(os.getuid()), '-x', name], capture_output=True, text=True)
        pids.update(result.stdout.split())
    for pid in sorted(pids):
        proc = Path('/proc') / pid
        if proc.exists():
            print(f'qs PID {pid}, MainPID={main or "absent"}: '
                  + (proc / 'cmdline').read_bytes().replace(b'\0', b' ').decode(errors='replace')
                  + '\n' + (proc / 'cgroup').read_text())
    if owned_runtime:
        for pid in pids:
            environment = Path('/proc') / pid / 'environ'
            if environment.exists():
                assert ('XDG_RUNTIME_DIR=' + str(owned_runtime)).encode() not in environment.read_bytes().split(b'\0'), pid
        print('process guard: no task-owned Quickshell processes remain')
    else:
        assert main in ('', '0'), 'A managed desktop shell is active'
        for pid in pids:
            environment = dict(part.split(b'=', 1) for part in (Path('/proc') / pid / 'environ').read_bytes().split(b'\0') if b'=' in part)
            other_runtime = environment.get(b'XDG_RUNTIME_DIR', b'').decode()
            assert other_runtime.startswith(('/tmp/', '/data/tmp/')), 'An unrelated real desktop session is active'
        print('process guard: no managed desktop; unrelated private tests are preserved')


def main():
    process_guard()
    OUTPUT.mkdir(parents=True, exist_ok=True)
    processes = []
    with tempfile.TemporaryDirectory(prefix='private-', dir=OUTPUT) as temporary:
        base = Path(temporary)
        runtime, home = base / 'run', base / 'home'
        runtime.mkdir(mode=0o700)
        (home / '.config/cybexos').mkdir(parents=True)
        (home / '.config/cybexos/shell.json').write_text(json.dumps({'v': 30, 'wall': ''}))
        shell = base / 'runtime/quickshell'
        shutil.copytree(ROOT / 'desktop/quickshell', shell)
        shutil.copytree(ROOT / 'assets/wallpapers', shell.parent / 'wallpapers')
        native = base / 'native'
        with (base / 'native.log').open('w') as build_log:
            subprocess.run(['cmake', '-S', str(ROOT / 'desktop/notification-images'), '-B', str(native),
                            '-DBUILD_TESTING=OFF'], stdout=build_log, stderr=subprocess.STDOUT, check=True)
            subprocess.run(['cmake', '--build', str(native), '--parallel', '2'],
                           stdout=build_log, stderr=subprocess.STDOUT, check=True)
        entry = shell / 'shell.qml'
        source = entry.read_text().replace('import "Common"', 'import "Common"\nimport "Common" as TestCommon').replace('SettingsWindow {}', 'SettingsWindow { id: wallpaperSettings }')
        source = source.replace('    id: shell', '''    id: shell
    function focusNames(item) {
        let names = item.activeFocus ? [String(item)] : [];
        for (const child of item.children || []) names = names.concat(focusNames(child));
        return names;
    }
    function findPicker(item) {
        if (item.objectName === "wallpaperPicker") return item;
        for (const child of item.children || []) {
            const found = findPicker(child);
            if (found) return found;
        }
        return null;
    }
    IpcHandler {
        target: "wallpaper-test"
        function tab(value: string): void { OnlineWallpapers.view = value; }
        function focusLocal(): void {
            const picker = shell.findPicker(wallpaperSettings.contentItem);
            picker.children[1].children[0].focusItem(0);
        }
        function focusRoot(): void { shell.findPicker(wallpaperSettings.contentItem).forceActiveFocus(); }
        function automatic(): void { OnlineWallpapers.ensureLoaded(true); }
        function meter(known: bool, value: bool): void {
            OnlineWallpapers.meteredKnown = known;
            OnlineWallpapers.metered = value;
        }
        function budget(): string {
            OnlineWallpapers.requestTimes = Array(45).fill(Date.now());
            return OnlineWallpapers.reserveRequest() ? "allowed" : "paused";
        }
        function selectFirst(): void {
            if (OnlineWallpapers.results.length) OnlineWallpapers.select(OnlineWallpapers.results[0].id);
        }
        function state(): string {
            const picker = shell.findPicker(wallpaperSettings.contentItem);
            return JSON.stringify({ picker: picker !== null, tab: picker ? picker.tab : "",
                selected: picker ? picker.selected : null, focus: picker ? shell.focusNames(picker) : [], wall: Settings.wall,
                paletteReady: TestCommon.Palette.ready, paletteBusy: TestCommon.Palette.busy,
                current: Wallpaper.current, identity: Wallpaper.currentIdentity,
                themeWallpaper: SystemTheme.tokens.wallpaper, results: OnlineWallpapers.results.length,
                searched: OnlineWallpapers.searched, busy: OnlineWallpapers.busy,
                detailsBusy: OnlineWallpapers.detailsBusy, details: OnlineWallpapers.details,
                requests: OnlineWallpapers.requestTimes.length,
                error: OnlineWallpapers.error, directoryError: Wallpaper.directoryError,
                importError: Wallpaper.importError, files: Wallpaper.files.length,
                meteredKnown: OnlineWallpapers.meteredKnown, metered: OnlineWallpapers.metered });
        }
    }''')
        entry.write_text(source)
        picker = shell / 'Settings/WallpaperPicker.qml'
        picker.write_text(picker.read_text().replace('    id: root', '    id: root\n    objectName: "wallpaperPicker"', 1))
        env = {**os.environ, 'HOME': str(home), 'XDG_RUNTIME_DIR': str(runtime),
               'XDG_CONFIG_HOME': str(home / '.config'), 'XDG_DATA_HOME': str(home / '.local/share'),
               'XDG_STATE_HOME': str(home / '.local/state'), 'XDG_CACHE_HOME': str(home / '.cache'),
               'QT_QPA_PLATFORM': 'wayland', 'QT_QUICK_BACKEND': 'software', 'WLR_BACKENDS': 'headless',
               'WLR_RENDERER': 'pixman', 'WLR_LIBINPUT_NO_DEVICES': '1', 'CYBEXOS_ASSISTANT': '0',
               'CYBEXOS_CONNECTED_WIDGETS': '0', 'CYBEXOS_DEVELOPER_TOOLS': '0', 'CYBEXOS_WELCOME': '0',
               'QT_PLUGIN_PATH': subprocess.check_output(['qtpaths', '--query', 'QT_INSTALL_PLUGINS'], text=True).strip(),
               'SSL_CERT_FILE': '/etc/ssl/certs/ca-certificates.crt', 'CYBEXOS_LANG': os.environ.get('CYBEXOS_LANG', 'en'),
               'QML_IMPORT_PATH': str(native / 'qml') + ':' + os.environ.get('CYBEXOS_QML_IMPORT_PATH', ''),
               **shell_fonts.fontconfig(base)}
        for name in ('DISPLAY', 'WAYLAND_DISPLAY', 'HYPRLAND_INSTANCE_SIGNATURE', 'SWAYSOCK'):
            env.pop(name, None)

        def start(argv, log):
            handle = (base / log).open('w')
            proc = subprocess.Popen(argv, env=env, stdout=handle, stderr=subprocess.STDOUT, start_new_session=True)
            handle.close()
            processes.append(proc)
            return proc

        def wait(predicate, label, seconds=25):
            until = time.monotonic() + seconds
            while time.monotonic() < until:
                value = predicate()
                if value:
                    return value
                time.sleep(0.2)
            raise AssertionError(f'Timeout: {label}\n' + (base / 'qs.log').read_text(errors='replace'))

        def ipc(target, method, *args):
            result = subprocess.run(['qs', 'ipc', '-p', str(shell), 'call', target, method, *args],
                                    env=env, capture_output=True, text=True, timeout=10)
            return result.stdout.strip() if result.returncode == 0 else "ipc-unavailable"

        def state():
            try:
                return json.loads(ipc('wallpaper-test', 'state'))
            except (json.JSONDecodeError, subprocess.TimeoutExpired):
                return {}

        def screenshot(name):
            time.sleep(0.7)
            target = OUTPUT / name
            subprocess.run(['grim', str(target)], env=env, check=True, timeout=10)
            print(str(target))

        try:
            (base / 'sway.conf').write_text('output HEADLESS-1 mode 1440x900\nseat seat0 fallback true\n'
                'for_window [title="Cybex OS Settings"] floating enable, resize set 1000 740, move position center\n')
            sway = base / 'sway'
            shutil.copyfile(os.environ.get('CYBEXOS_SWAY_BINARY') or shutil.which('sway'), sway)
            sway.chmod(0o700)
            start([str(sway), '-c', str(base / 'sway.conf')], 'sway.log')
            sockets = wait(lambda: [p for p in runtime.glob('wayland-*') if p.is_socket()], 'Sway')
            env['WAYLAND_DISPLAY'] = sockets[0].name
            env['SWAYSOCK'] = str(next(runtime.glob('sway-ipc.*.sock')))
            dbus = ['dbus-run-session']
            if env.get('CYBEXOS_DBUS_SESSION_CONFIG'):
                dbus += ['--config-file', env['CYBEXOS_DBUS_SESSION_CONFIG']]
            start([*dbus, '--', 'qs', '--no-color', '-p', str(shell)], 'qs.log')
            wait(lambda: ipc('settings', 'open', 'wallpaper') == '', 'Settings IPC')
            initial = wait(lambda: state().get('selected') and state(), 'bundled preview')
            assert initial['wall'] == '' and not initial['paletteReady'] and not initial['paletteBusy'], initial
            assert initial['current'].endswith('/moon-mountains.png'), initial
            assert initial['themeWallpaper'].endswith('/moon-mountains.png'), initial
            screenshot('collection.png')
            ipc('wallpaper-test', 'automatic')
            assert state()['requests'] == 0, 'Unknown metering auto-loaded a listing'
            ipc('wallpaper-test', 'meter', 'true', 'true')
            ipc('wallpaper-test', 'automatic')
            assert state()['requests'] == 0, 'Metered connection auto-loaded a listing'
            ipc('wallpaper-test', 'meter', 'false', 'true')
            # Keep one virtual keyboard attached across the whole sequence.
            # Creating/destroying it for every key changes Sway's seat focus.
            keyboard = start(['wtype', '-s', '800', '-d', '100', '-k', 'Right', '-k', 'Return',
                              '-s', '1200', '-k', 'Tab', '-k', 'Return', '-s', '200'], 'keyboard.log')
            time.sleep(0.25)
            subprocess.run(['swaymsg', '[title="Cybex OS Settings"]', 'focus'], env=env, check=True, capture_output=True)
            ipc('wallpaper-test', 'focusLocal')
            wait(lambda: state().get('selected', {}).get('fileName') == 'quiet-fjord.png', 'keyboard selection')
            assert state()['wall'] == '', 'Keyboard selection unexpectedly applied the wallpaper'
            keyboard.wait(timeout=5)
            chosen = wait(lambda: state().get('wall', '').startswith('cybexos-') and state(), 'bundled import')
            assert chosen['importError'] == '' and chosen['wall'] == 'cybexos-quiet-fjord.png', chosen
            wait(lambda: state().get('files') == 1, 'folder model update')
            ipc('wallpaper-test', 'tab', 'library')
            wait(lambda: state().get('tab') == 'library' and state().get('selected'), 'library preview')
            screenshot('my-pictures.png')
            if os.environ.get('CYBEXOS_WALLPAPER_KEYBOARD_ONLY') == '1':
                return
            ipc('wallpaper', 'browse')
            online = wait(lambda: state().get('searched') and not state().get('busy') and state(), 'Wallhaven listing')
            assert online['results'] > 0 and not online['error'], online
            previous = online['wall']
            ipc('wallpaper-test', 'selectFirst')
            detail = wait(lambda: not state().get('detailsBusy') and state().get('details') and state(), 'Wallhaven details')
            assert detail['wall'] == previous, 'Preview unexpectedly applied the online image'
            requests = detail['requests']
            ipc('wallpaper-test', 'selectFirst')
            assert state()['requests'] == requests, 'Cached selection made another API request'
            screenshot('wallhaven.png')
            print(json.dumps({'initial': initial, 'selectedOnline': detail}, indent=2))
            # Selection and thumbnail loading must never save the original.
            assert len(list((home / 'Pictures/Wallpapers').glob('*'))) == 1
            assert ipc('wallpaper-test', 'budget') == 'paused', '45-request budget was exceeded'
            keyboard = start(['wtype', '-s', '500', '-k', 'Escape', '-s', '100'], 'escape.log')
            time.sleep(0.2)
            ipc('wallpaper-test', 'focusRoot')
            keyboard.wait(timeout=5)
            wait(lambda: json.loads(ipc('settings', 'status')).get('open') is False, 'Escape closes Settings')
            errors = QML_ERRORS.findall((base / 'qs.log').read_text(errors='replace'))
            assert not errors, errors
            print('PASS: default, bundled apply, folder tab, online selection/details, no full-image download or QML errors')
        except Exception:
            print((base / 'qs.log').read_text(errors='replace') if (base / 'qs.log').exists()
                  else (base / 'sway.log').read_text(errors='replace'))
            raise
        finally:
            for proc in reversed(processes):
                try: os.killpg(proc.pid, signal.SIGTERM)
                except ProcessLookupError: pass
            for proc in reversed(processes):
                try: proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(proc.pid, signal.SIGKILL)
                    proc.wait()
            # dbus-run-session owns qs; allow its just-exited descendant to
            # be reaped before the final comparison, with no blanket signals.
            for _ in range(50):
                if all(subprocess.run(['pgrep', '-u', str(os.getuid()), '-x', name],
                       stdout=subprocess.DEVNULL).returncode != 0 for name in ('qs', '.quickshell-wra')):
                    break
                time.sleep(0.1)
            process_guard(runtime)


if __name__ == '__main__':
    main()
