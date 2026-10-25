#!/usr/bin/env python3
"""Real QML model under private headless Sway; fake hyprctl, no real session."""
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
QML = r'''
import QtQuick
import Quickshell
import Quickshell.Io
import "Common"
ShellRoot {
    id: root
    property int appliedCount: 0
    property int failedCount: 0
    Connections {
        target: Keybindings
        function onApplied() { root.appliedCount++; }
        function onFailed(message) { root.failedCount++; }
    }
    IpcHandler {
        target: "keybindings-test"
        function status(): string {
            return JSON.stringify({loaded: Keybindings.loaded, busy: Keybindings.busy,
                error: Keybindings.error, dirty: Keybindings.dirty, actions: Keybindings.actions,
                watchers: SystemSettings.keybindings.watchers, applied: root.appliedCount,
                failed: root.failedCount});
        }
        function refresh(): void { Keybindings.refresh(); }
        function acquire(): void { Keybindings.acquire(); }
        function release(): void { Keybindings.release(); }
        function edit(): void { Keybindings.setKeys("apps.first", ["SUPER + T"]); }
        function apply(): void { Keybindings.apply(); }
    }
}
'''
FAKE_HYPRCTL = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
base = Path(os.environ['XDG_RUNTIME_DIR'])
with (base / 'hyprctl-calls').open('a') as log:
    log.write(json.dumps(sys.argv[1:]) + '\n')
state = base / 'cybexos/keybindings-state.json'
if sys.argv[1:] == ['-j', 'binds']:
    data = json.loads(state.read_text())
    binds = []
    for row in data['actions']:
        for key in row['keys']:
            parts = key.split(' + ')
            masks = {'SUPER':64, 'CTRL':4, 'ALT':8, 'SHIFT':1}
            binds.append({'modmask':sum(masks[p] for p in parts[:-1]), 'key':parts[-1],
                          'description':row['group'] + ': ' + row['label']})
    print(json.dumps(binds))
elif sys.argv[1:] == ['reload']:
    preferences = Path(os.environ['XDG_CONFIG_HOME']) / 'cybexos/keybindings.json'
    data = json.loads(state.read_text())
    document = json.loads(preferences.read_text()) if preferences.exists() else {'v':1}
    for row in data['actions']:
        row['keys'] = document.get('actions', {}).get(row['id'], {}).get('keys', row['defaultKeys'])
        row['changed'] = row['keys'] != row['defaultKeys']
    state.write_text(json.dumps(data))
    print('ok')
elif len(sys.argv) > 1 and sys.argv[1] == 'eval':
    print('ok')
else:
    sys.exit(1)
'''


def shell_pids():
    result = set()
    for name in ('qs', '.quickshell-wra'):
        value = subprocess.run(['pgrep', '-u', str(os.getuid()), '-x', name], capture_output=True, text=True)
        result.update(int(pid) for pid in value.stdout.split())
    managed = subprocess.run(['systemctl', '--user', 'show', 'quickshell.service', '-p', 'MainPID', '--value'],
                             capture_output=True, text=True)
    main_pid = int(managed.stdout.strip() or '0') if managed.stdout.strip().isdigit() else 0
    for pid in result - {main_pid}:
        # Inspect without changing anyone else's process. This test refuses an
        # existing desktop rather than enrolling it in its own cleanup.
        print(f'existing qs PID {pid}: {(Path("/proc") / str(pid) / "cmdline").read_bytes()!r}')
        print((Path('/proc') / str(pid) / 'cgroup').read_text())
    return main_pid, result


def main():
    assert shell_pids() == (0, set()), 'run only with no existing desktop shell'
    processes = []
    with tempfile.TemporaryDirectory(prefix='cybexos-keybindings-engine-') as temporary:
        base = Path(temporary)
        runtime, home, shell = base / 'runtime', base / 'home', base / 'shell'
        runtime.mkdir(mode=0o700)
        home.mkdir()
        (runtime / 'cybexos').mkdir()
        (base / 'bin').mkdir()
        helper = base / 'bin/hyprctl'
        helper.write_text(FAKE_HYPRCTL)
        helper.chmod(0o700)
        shutil.copytree(ROOT / 'desktop/quickshell', shell)
        (shell / 'shell.qml').write_text(QML)
        sway_config = base / 'sway.conf'
        sway_config.write_text('output HEADLESS-1 resolution 1280x720\nseat seat0 fallback true\n')
        env = {**os.environ, 'HOME': str(home), 'XDG_RUNTIME_DIR': str(runtime),
               'XDG_CONFIG_HOME': str(home / '.config'), 'XDG_DATA_HOME': str(home / '.local/share'),
               'XDG_STATE_HOME': str(home / '.local/state'), 'QT_QPA_PLATFORM': 'wayland',
               'QT_QUICK_BACKEND': 'software', 'WLR_BACKENDS': 'headless', 'WLR_RENDERER': 'pixman',
               'WLR_LIBINPUT_NO_DEVICES': '1', 'PATH': str(base / 'bin') + os.pathsep + os.environ['PATH'],
               'QML_IMPORT_PATH': os.environ.get('CYBEXOS_QML_IMPORT_PATH', ''), 'PYTHONDONTWRITEBYTECODE': '1'}
        for key in ('DISPLAY', 'WAYLAND_DISPLAY', 'SWAYSOCK', 'HYPRLAND_INSTANCE_SIGNATURE'):
            env.pop(key, None)
        logs = []
        def start(argv, filename):
            log = (base / filename).open('w')
            logs.append(log)
            process = subprocess.Popen(argv, env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            processes.append(process)
            return process
        def wait(predicate, description, timeout=20):
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                result = predicate()
                if result:
                    return result
                time.sleep(0.1)
            raise AssertionError('timed out: ' + description + '\n' + (base / 'qs.log').read_text(errors='replace'))
        def ipc(method):
            value = subprocess.run(['qs', 'ipc', '-p', str(shell), 'call', 'keybindings-test', method],
                                   env=env, capture_output=True, text=True, timeout=5)
            return value.stdout.strip() if value.returncode == 0 else ''
        def status():
            try:
                return json.loads(ipc('status'))
            except ValueError:
                return {}
        try:
            bus = ['dbus-run-session']
            if os.environ.get('CYBEXOS_DBUS_SESSION_CONFIG'):
                bus += ['--config-file', os.environ['CYBEXOS_DBUS_SESSION_CONFIG']]
            start([*bus, '--', os.environ.get('CYBEXOS_SWAY_BINARY', 'sway'), '-c', str(sway_config)], 'sway.log')
            # The compositor is private and owns no devices or host service.
            for _ in range(200):
                sockets = list(runtime.glob('wayland-*'))
                sockets = [item for item in sockets if not item.name.endswith('.lock')]
                if sockets:
                    break
                time.sleep(0.05)
            assert sockets, (base / 'sway.log').read_text()
            env['WAYLAND_DISPLAY'] = sockets[0].name
            start(['qs', '-p', str(shell)], 'qs.log')
            initial = wait(status, 'QML IPC startup')
            assert not initial['loaded'] and not initial['busy'] and initial['watchers'] == 0, initial
            assert not (runtime / 'hyprctl-calls').exists(), 'singleton started a process before demand'
            ipc('refresh')
            unavailable = wait(lambda: (s if (s := status()).get('failed', 0) and not s['busy'] else None), 'graceful unavailable state')
            assert unavailable['error'] and not unavailable['loaded'], unavailable
            fixtures = json.loads((ROOT / 'tests/fixtures/keybindings/resolution.json').read_text())
            state = {'v':1, 'error':None, 'actions':fixtures['catalog'], 'custom':[], 'diagnostics':[]}
            (runtime / 'cybexos/keybindings-state.json').write_text(json.dumps(state))
            ipc('acquire')
            loaded = wait(lambda: (s if (s := status()).get('loaded') and not s['busy'] and not s['error'] else None), 'loaded model')
            assert loaded['watchers'] == 1
            ipc('edit')
            edited = status()
            assert edited['dirty'] and next(row for row in edited['actions'] if row['id'] == 'apps.first')['keys'] == ['SUPER + T'], edited
            ipc('apply')
            committed = wait(lambda: (s if (s := status()).get('applied', 0) == 1 and not s['busy'] else None), 'apply signal and snapshot')
            assert not committed['dirty'] and not committed['error'], committed
            preferences = json.loads((home / '.config/cybexos/keybindings.json').read_text())
            assert preferences['actions']['apps.first']['keys'] == ['SUPER + T']
            ipc('release')
            wait(lambda: (s := status()) and s['watchers'] == 0 and not s['busy'], 'claim release')
            output = (base / 'qs.log').read_text(errors='replace')
            assert not re.search(r'TypeError|ReferenceError|Binding loop|is not a type|Cannot assign|Unable to assign|Failed to load configuration', output), output
            print('PASS: real QML startup is lazy; missing backend fails gracefully; acquire/edit/apply/release work with fake Hyprland')
        finally:
            for process in reversed(processes):
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
            for process in reversed(processes):
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
            for log in logs:
                log.close()
    assert shell_pids() == (0, set()), 'the test left a shell process behind'


if __name__ == '__main__':
    main()
