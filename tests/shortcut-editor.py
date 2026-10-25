#!/usr/bin/env python3
"""Exercise Settings → Keyboard shortcuts in the real shell, under a private
headless Sway. Never touches a session, the user's config or user.lua.

Run through nix develop with grim and wtype on PATH, e.g.
  nix develop -c nix shell nixpkgs#grim nixpkgs#wtype -c python3 -B tests/shortcut-editor.py

A fake `hyprctl` resolves keybindings.json with the real bindings.lua and
keybinding_preferences.lua (through the Lua stub the Node tests use), so the
written file and the resolved state are the actual Lua contract. It also
reports one described binding as if user.lua had added it. Only the PNG
screenshots survive in OUTPUT; every process, HOME and runtime is private and
removed in finally.
"""
from __future__ import annotations
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
OUTPUT = Path(os.environ.get('CYBEXOS_SHORTCUT_SCREENSHOTS', '/data/tmp/cybexos-onboarding-B'))
QML_ERRORS = re.compile(r'TypeError|ReferenceError|Binding loop|is not a type|Type \w+ unavailable'
                        r'|Cannot assign|Unable to assign|Illegal method name|Failed to load configuration'
                        r'|Cannot anchor|Cannot specify anchors')

FAKE_HYPRCTL = r'''#!/usr/bin/env python3
import json, os, subprocess, sys
from pathlib import Path
base = Path(os.environ['XDG_RUNTIME_DIR'])
state = base / 'cybexos/keybindings-state.json'
with (base / 'hyprctl-calls').open('a') as log:
    log.write(json.dumps(sys.argv[1:]) + '\n')
MASKS = {'SUPER': 64, 'CTRL': 4, 'ALT': 8, 'SHIFT': 1}
# One personal binding, as user.lua would add it after the resolved state.
USER = [{'modmask': 64 | 8, 'key': 'N', 'keycode': 0, 'description': 'Mine: Notes', 'submap': ''}]
if sys.argv[1:] in (['-j', 'binds'], ['binds', '-j']):
    data = json.loads(state.read_text())
    binds = []
    for row in data['actions'] + data.get('custom', []):
        for key in row['keys']:
            parts = key.split(' + ')
            last = parts[-1]
            code = int(last[5:]) if last.startswith('code:') else 0
            binds.append({'modmask': sum(MASKS[p] for p in parts[:-1]), 'key': '' if code else last,
                          'keycode': code, 'description': row['group'] + ': ' + row['label'], 'submap': ''})
    print(json.dumps(binds + USER))
elif sys.argv[1:] == ['reload']:
    result = subprocess.run([os.environ['CYBEXOS_TEST_LUA'], os.environ['CYBEXOS_TEST_RESOLVER']],
                            capture_output=True, text=True)
    print('ok' if result.returncode == 0 else result.stderr)
elif len(sys.argv) > 1 and sys.argv[1] == 'eval':
    error = json.loads(state.read_text()).get('error')
    print('ok' if error is None else error)
else:
    sys.exit(1)
'''

TEST_IPC = '''
    function findNamed(item, name) {
        if (!item) return null;
        if (item.objectName === name) return item;
        for (const child of item.children || []) {
            const found = shell.findNamed(child, name);
            if (found) return found;
        }
        if (item.contentItem && item.contentItem !== item) return shell.findNamed(item.contentItem, name);
        return null;
    }
    function shortcutsPage() { return shell.findNamed(shortcutSettings.contentItem, "shortcutsPage"); }
    IpcHandler {
        target: "shortcut-test"
        function state(): string {
            const page = shell.shortcutsPage();
            const recorder = page ? shell.findNamed(page, "shortcutRecorder") : null;
            const row = id => Keybindings.action(id);
            return JSON.stringify({ page: page !== null, loaded: Keybindings.loaded, dirty: Keybindings.dirty,
                busy: Keybindings.busy, error: Keybindings.error, view: page ? page.view : "",
                groups: page ? page.groups.map(group => group.title) : [],
                userCount: page ? page.counts.user : 0, userBinds: Keybindings.userBinds,
                recorder: recorder ? { shown: recorder.shown, listening: recorder.listening,
                    paused: recorder.paused, combo: recorder.combo, complete: recorder.complete,
                    reserved: recorder.reserved, kind: recorder.verdict.kind, reason: recorder.verdict.reason,
                    inhibiting: recorder.inhibiting, inhibitorEnabled: recorder.inhibitorEnabled,
                    windowActive: recorder.Window.active, status: recorder.status } : null,
                browser: row("apps.browser"), slack: row("webapps.slack"), lock: row("shell.lock"),
                custom: Keybindings.actions.filter(item => item.custom) });
        }
        function edit(id: string): void { shell.shortcutsPage().edit(id); }
        function view(value: string): void { shell.shortcutsPage().view = value; }
        function filter(value: string): void { shell.shortcutsPage().filter = value; }
        function search(value: string): void { shell.shortcutsPage().query = value; }
        function select(combo: string): void { shell.findNamed(shell.shortcutsPage(), "settingsShortcutMap").selected = combo; }
        function add(combo: string, type: string): void { shell.shortcutsPage().add(combo, type); }
        function scroll(y: real): void { shell.shortcutsPage().contentY = y; }
        function addWebsite(url: string): string {
            const form = shell.findNamed(shell.shortcutsPage(), "shortcutForm");
            form.url = url;
            form.suggest();
            return String(form.save());
        }
        function apply(): string { return String(Keybindings.apply()); }
        function mark(text: string): void { console.log("TEST-MARK " + text); }
    }'''


def process_guard(owned_runtime=None):
    main = subprocess.run(['systemctl', '--user', 'show', 'quickshell.service', '-p', 'MainPID', '--value'],
                          capture_output=True, text=True).stdout.strip()
    pids = set()
    for name in ('qs', '.quickshell-wra'):
        result = subprocess.run(['pgrep', '-u', str(os.getuid()), '-x', name], capture_output=True, text=True)
        pids.update(result.stdout.split())
    for pid in sorted(pids):
        proc = Path('/proc') / pid
        try:
            print(f'qs PID {pid}, MainPID={main or "absent"}: '
                  + (proc / 'cmdline').read_bytes().replace(b'\0', b' ').decode(errors='replace'))
        except OSError:
            pass  # exited meanwhile
    if owned_runtime:
        for pid in pids:
            try:
                environment = (Path('/proc') / pid / 'environ').read_bytes()
            except OSError:
                continue
            assert ('XDG_RUNTIME_DIR=' + str(owned_runtime)).encode() not in environment.split(b'\0'), pid
        print('process guard: no task-owned Quickshell processes remain')
    else:
        assert main in ('', '0'), 'A managed desktop shell is active'
        for pid in pids:
            try:
                raw = (Path('/proc') / pid / 'environ').read_bytes()
            except OSError:
                continue  # exited meanwhile
            environment = dict(part.split(b'=', 1) for part in raw.split(b'\0') if b'=' in part)
            other_runtime = environment.get(b'XDG_RUNTIME_DIR', b'').decode()
            assert other_runtime.startswith(('/tmp/', '/data/tmp/')), 'An unrelated real desktop session is active'
        print('process guard: no managed desktop; unrelated private tests are preserved')


def main():
    for executable in ('qs', 'sway', 'grim', 'wtype', 'cmake', 'node'):
        if not shutil.which(executable):
            raise SystemExit(f'{executable} is required; use nix develop with grim and wtype')
    lua = next((name for name in (os.environ.get('CYBEXOS_TEST_LUA'), 'lua', 'lua5.4', 'luajit')
                if name and shutil.which(name)), None)
    if not lua:
        raise SystemExit('Lua is required; use nix develop')
    process_guard()
    OUTPUT.mkdir(parents=True, exist_ok=True)
    processes = []
    with tempfile.TemporaryDirectory(prefix='private-', dir=OUTPUT) as temporary:
        base = Path(temporary)
        runtime, home = base / 'run', base / 'home'
        runtime.mkdir(mode=0o700)
        (runtime / 'cybexos').mkdir()
        (home / '.config/cybexos/hypr').mkdir(parents=True)
        (home / '.config/cybexos/shell.json').write_text(json.dumps({'v': 30, 'wall': '', 'assistantShown': False}))
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
        source = entry.read_text().replace('SettingsWindow {}', 'SettingsWindow { id: shortcutSettings }')
        assert 'shortcutSettings' in source
        source = source.replace('    id: shell', '    id: shell' + TEST_IPC, 1)
        entry.write_text(source)

        # The resolver Hyprland would run at each reload: real bindings.lua
        # and keybinding_preferences.lua, with the Node tests' Lua stub.
        stub = subprocess.run(['node', '-e', "process.stdout.write(require(process.argv[1]).stub)",
                               str(ROOT / 'tests/quickshell/keybindings-support.cjs')],
                              capture_output=True, text=True, check=True).stdout
        resolver = base / 'resolve.lua'
        resolver.write_text(f'package.path = {json.dumps(str(ROOT / "desktop/hypr/?.lua"))} .. ";" .. package.path\n'
                            'package.preload.features = function() return {} end\n'
                            + stub + "\nrequire('bindings')\nrequire('keybinding_preferences')\n")
        (base / 'bin').mkdir()
        hyprctl = base / 'bin/hyprctl'
        hyprctl.write_text(FAKE_HYPRCTL)
        hyprctl.chmod(0o700)

        env = {**os.environ, 'HOME': str(home), 'XDG_RUNTIME_DIR': str(runtime),
               'XDG_CONFIG_HOME': str(home / '.config'), 'XDG_DATA_HOME': str(home / '.local/share'),
               'XDG_STATE_HOME': str(home / '.local/state'), 'XDG_CACHE_HOME': str(home / '.cache'),
               'QT_QPA_PLATFORM': 'wayland', 'QT_QUICK_BACKEND': 'software', 'WLR_BACKENDS': 'headless',
               'WLR_RENDERER': 'pixman', 'WLR_LIBINPUT_NO_DEVICES': '1', 'CYBEXOS_ASSISTANT': '0',
               'CYBEXOS_CONNECTED_WIDGETS': '0', 'CYBEXOS_DEVELOPER_TOOLS': '0', 'CYBEXOS_WELCOME': '0',
               'CYBEXOS_LANG': os.environ.get('CYBEXOS_LANG', 'en'),
               'CYBEXOS_TEST_LUA': shutil.which(lua), 'CYBEXOS_TEST_RESOLVER': str(resolver),
               'PATH': str(base / 'bin') + os.pathsep + os.environ['PATH'],
               'QT_PLUGIN_PATH': subprocess.check_output(['qtpaths', '--query', 'QT_INSTALL_PLUGINS'], text=True).strip(),
               'QML_IMPORT_PATH': str(native / 'qml') + ':' + os.environ.get('CYBEXOS_QML_IMPORT_PATH', ''),
               'PYTHONDONTWRITEBYTECODE': '1'}
        for name in ('DISPLAY', 'WAYLAND_DISPLAY', 'HYPRLAND_INSTANCE_SIGNATURE', 'SWAYSOCK', 'DBUS_SESSION_BUS_ADDRESS'):
            env.pop(name, None)
        subprocess.run([str(hyprctl), 'reload'], env=env, check=True, capture_output=True)
        initial_state = json.loads((runtime / 'cybexos/keybindings-state.json').read_text())
        assert initial_state['error'] is None and len(initial_state['actions']) > 40, initial_state['error']

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
                time.sleep(0.15)
            raise AssertionError(f'Timeout: {label}\n{json.dumps(state(), indent=1)[:4000]}')

        def ipc(target, method, *args):
            try:
                result = subprocess.run(['qs', 'ipc', '-p', str(shell), 'call', target, method, *args],
                                        env=env, capture_output=True, text=True, timeout=10)
            except subprocess.TimeoutExpired:
                return 'ipc-timeout'
            return result.stdout.strip() if result.returncode == 0 else 'ipc-unavailable'

        def state():
            try:
                return json.loads(ipc('shortcut-test', 'state'))
            except json.JSONDecodeError:
                return {}

        def recorder():
            return state().get('recorder') or {}

        def screenshot(name):
            ipc('shortcut-test', 'mark', name)
            time.sleep(0.6)
            target = OUTPUT / name
            subprocess.run(['grim', str(target)], env=env, check=True, timeout=10)
            print(target)

        def focus_settings():
            ipc('shortcut-test', 'mark', 'focus')
            subprocess.run(['swaymsg', '[title="Cybex OS Settings"]', 'focus'], env=env, check=True, capture_output=True)

        try:
            (base / 'sway.conf').write_text('output HEADLESS-1 mode 1440x900\nseat seat0 fallback true\n'
                'for_window [title="Cybex OS Settings"] floating enable, resize set 1000 760, move position center\n'
                'for_window [title="Welcome to Cybex OS"] floating enable, resize set 1180 820, move position center\n')
            sway = base / 'sway'
            shutil.copyfile(os.environ.get('CYBEXOS_SWAY_BINARY') or shutil.which('sway'), sway)
            sway.chmod(0o700)
            start([str(sway), '-c', str(base / 'sway.conf')], 'sway.log')
            sockets = wait(lambda: [p for p in runtime.glob('wayland-*') if p.is_socket()], 'Sway')
            env['WAYLAND_DISPLAY'] = sockets[0].name
            env['SWAYSOCK'] = str(wait(lambda: next(runtime.glob('sway-ipc.*.sock'), None), 'Sway IPC'))
            dbus = ['dbus-run-session']
            if env.get('CYBEXOS_DBUS_SESSION_CONFIG'):
                dbus += ['--config-file', env['CYBEXOS_DBUS_SESSION_CONFIG']]
            start([*dbus, '--', 'qs', '--no-color', '-p', str(shell)], 'qs.log')
            # The headless seat has no keyboard of its own. When a key-sending
            # wtype disconnects, Qt deactivates the window and nothing would
            # re-enter it; an idle virtual keyboard keeps the seat's keyboard.
            start(['wtype', '-s', '600000'], 'seat-keyboard.log')
            wait(lambda: ipc('settings', 'open', 'shortcuts') == '', 'Settings IPC')
            loaded = wait(lambda: (s := state()).get('loaded') and not s.get('busy') and s, 'loaded shortcuts page')
            assert loaded['page'] and not loaded['dirty'] and not loaded['error'], loaded
            assert loaded['groups'][:2] == ['Shell', 'Apps'], loaded['groups']
            assert loaded['userBinds'] == [{'keys': ['SUPER + ALT + N'], 'group': 'Mine', 'label': 'Notes'}], loaded['userBinds']
            assert loaded['userCount'] == 1, loaded
            assert loaded['browser']['keys'] == ['SUPER + B'] and loaded['slack']['keys'] == ['SUPER + M']
            screenshot('shortcuts-page.png')
            ipc('shortcut-test', 'filter', 'user')
            wait(lambda: state().get('groups') == ['Mine'], 'From user.lua filter')
            screenshot('shortcuts-user-filter.png')
            ipc('shortcut-test', 'filter', 'all')

            # Record through the real recorder: an unmodified key is refused,
            # the protected Super+L blocks, Super+M (Slack) offers Replace.
            ipc('shortcut-test', 'edit', 'apps.browser')
            wait(lambda: recorder().get('listening'), 'recorder listening')
            focus_settings()
            wait(lambda: recorder().get('inhibiting'), 'ShortcutInhibitor active while recording')
            keyboard = start(['wtype', '-s', '600', '-k', 'b', '-s', '1200',
                              '-M', 'logo', '-k', 'l', '-m', 'logo', '-s', '1500',
                              '-k', 'Return', '-s', '800',
                              '-M', 'logo', '-k', 'm', '-m', 'logo', '-s', '4000',
                              '-k', 'Return', '-s', '300'], 'keyboard.log')
            refused = wait(lambda: (r := recorder()).get('reserved') and r, 'unmodified key refused', 10)
            assert refused['reserved'] == 'modifier' and refused['listening'], refused
            blocked = wait(lambda: (r := recorder()).get('kind') == 'blocked' and r, 'protected key blocked', 10)
            assert blocked['combo'] == 'SUPER + L' and blocked['reason'] == 'protected', blocked
            assert not blocked['listening'] and not blocked['inhibiting'], 'inhibitor must be released after capture'
            replace = wait(lambda: (r := recorder()).get('kind') == 'replace' and r, 'Slack conflict offers Replace', 10)
            assert replace['combo'] == 'SUPER + M', replace
            screenshot('shortcuts-recorder-conflict.png')
            keyboard.wait(timeout=15)
            edited = wait(lambda: (s := state()).get('dirty') and not s['recorder']['shown'] and s, 'Replace accepted')
            assert edited['browser']['keys'] == ['SUPER + M'], edited['browser']
            assert edited['slack']['keys'] == [], edited['slack']
            assert not edited['recorder']['inhibiting'] and not edited['recorder']['listening']
            screenshot('shortcuts-pending.png')

            # Focus loss pauses recording and releases the inhibitor.
            ipc('shortcut-test', 'edit', 'apps.terminal')
            # Disconnecting wtype's virtual keyboard can move Sway's seat focus.
            focus_settings()
            wait(lambda: recorder().get('inhibiting'), 'inhibitor for the second recording')
            subprocess.run(['swaymsg', 'workspace', '2'], env=env, check=True, capture_output=True)
            paused = wait(lambda: (r := recorder()).get('paused') and r, 'focus loss pauses')
            assert not paused['listening'] and not paused['inhibiting'], paused
            subprocess.run(['swaymsg', 'workspace', '1'], env=env, check=True, capture_output=True)
            focus_settings()
            keyboard = start(['wtype', '-s', '500', '-k', 'Escape', '-s', '200'], 'escape.log')
            wait(lambda: recorder().get('shown') is False, 'Escape cancels the recorder')
            keyboard.wait(timeout=5)
            assert ipc('settings', 'status') and json.loads(ipc('settings', 'status')).get('open') is True, \
                'Escape in the recorder must not close Settings'

            # A custom shortcut through the Add form, prefilled from the map.
            ipc('shortcut-test', 'view', 'map')
            ipc('shortcut-test', 'select', 'SUPER + B')
            wait(lambda: state().get('view') == 'map', 'keyboard map view')
            screenshot('shortcuts-keyboard-map.png')
            ipc('shortcut-test', 'add', 'SUPER + B', 'url')
            screenshot('shortcuts-add-form.png')
            assert ipc('shortcut-test', 'addWebsite', 'docs.example.org/start') == 'true'
            custom = wait(lambda: (s := state()).get('custom') and s['custom'], 'custom shortcut in the draft')
            assert custom[0]['keys'] == ['SUPER + B'] and custom[0]['label'] == 'docs.example.org', custom

            assert ipc('shortcut-test', 'apply') == 'true'
            committed = wait(lambda: (s := state()).get('loaded') and not s['dirty'] and not s['busy'] and s, 'applied', 30)
            assert not committed['error'], committed['error']
            preferences = json.loads((home / '.config/cybexos/keybindings.json').read_text())
            assert preferences == {'v': 1, 'actions': {'apps.browser': {'keys': ['SUPER + M']},
                                                       'webapps.slack': {'keys': []}},
                                   'custom': [{'id': 'custom.shortcut-1', 'group': 'Web', 'label': 'docs.example.org',
                                               'keys': ['SUPER + B'],
                                               'run': {'type': 'url', 'url': 'https://docs.example.org/start'}}]}, preferences
            resolved = json.loads((runtime / 'cybexos/keybindings-state.json').read_text())
            browser = next(row for row in resolved['actions'] if row['id'] == 'apps.browser')
            assert resolved['error'] is None and browser['keys'] == ['SUPER + M'] and browser['changed'], browser
            assert [row['keys'] for row in resolved['custom']] == [['SUPER + B']], resolved['custom']
            assert committed['browser']['source'] == 'changed', committed['browser']
            calls = (runtime / 'hyprctl-calls').read_text()
            assert '["reload"]' in calls and '"eval"' in calls, calls
            assert not (home / '.config/cybexos/hypr/user.lua').exists(), 'user.lua must never be written'
            ipc('shortcut-test', 'view', 'list')
            ipc('shortcut-test', 'filter', 'changed')
            wait(lambda: state().get('groups') == ['Apps', 'Web apps', 'Web'], 'Changed filter after apply')
            ipc('shortcut-test', 'scroll', '0')
            screenshot('shortcuts-changed-filter.png')

            # The welcome guide's step uses the same map and keycaps.
            ipc('settings', 'close')
            assert ipc('welcome', 'open', 'shortcuts') == 'ok'
            time.sleep(1.5)
            screenshot('welcome-shortcuts.png')
            ipc('welcome', 'close')

            errors = [line for line in (base / 'qs.log').read_text(errors='replace').splitlines()
                      if QML_ERRORS.search(line) or 'activeFocusOnTab' in line
                      or re.search(r'(WARN|ERROR).*(Shortcut\w*\.qml|Keybind\w*\.qml|ShortcutEditor\.js|ShortcutsStep)', line)]
            assert not errors, '\n'.join(errors)
            print('PASS: real page, user.lua rows, recorder with ShortcutInhibitor, reserved/protected/Replace '
                  'decisions, focus-loss release, Escape, map, apply through the real Lua resolver')
        except Exception:
            for query in ('get_seats', 'get_tree'):
                result = subprocess.run(['swaymsg', '-t', query], env=env, capture_output=True, text=True)
                print(query, re.findall(r'"(?:name|focused|app_id|shell|focus)": [^,\n]*', result.stdout)[:80])
            print((base / 'qs.log').read_text(errors='replace')[-20000:] if (base / 'qs.log').exists()
                  else (base / 'sway.log').read_text(errors='replace'))
            raise
        finally:
            for proc in reversed(processes):
                try:
                    os.killpg(proc.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
            for proc in reversed(processes):
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(proc.pid, signal.SIGKILL)
                    proc.wait()
            for _ in range(50):
                if not any(b'XDG_RUNTIME_DIR=' + str(runtime).encode() in environ for environ in owned_environs()):
                    break
                time.sleep(0.1)
            process_guard(runtime)


def owned_environs():
    out = []
    for name in ('qs', '.quickshell-wra'):
        result = subprocess.run(['pgrep', '-u', str(os.getuid()), '-x', name], capture_output=True, text=True)
        for pid in result.stdout.split():
            try:
                out.append((Path('/proc') / pid / 'environ').read_bytes())
            except OSError:
                pass
    return out


if __name__ == '__main__':
    main()
