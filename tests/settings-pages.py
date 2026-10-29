#!/usr/bin/env python3
"""Exercise the redesigned Settings window (2026-10) in the real shell, under a
private headless Sway. Never touches a session, the user's config or the host.

Run through nix develop with grim and wtype on PATH, e.g.
  nix develop -c nix shell nixpkgs#grim nixpkgs#wtype -c python3 -B tests/settings-pages.py

It opens every page and tab, follows legacy page ids (shortcuts, storage,
about), drives Back, the palette (Enter jumps and highlights, Ctrl+Enter
flips a switch in place), Home's Recently changed with Undo, and drafts on
two pages reviewed and applied from the header's Changes sheet. `cybex` is a
fake that records every call and answers the doctor, so the regional change
the sheet prepares is checked as the one combined `cybex config region` call
it sends, and nothing reaches pkexec. Only the PNG screenshots survive, and
only in CYBEXOS_SETTINGS_SCREENSHOTS when it is set.
"""
from __future__ import annotations
import atexit
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time

import shell_fonts

ROOT = Path(__file__).resolve().parents[1]
KEEP = os.environ.get('CYBEXOS_SETTINGS_SCREENSHOTS')
OUTPUT = Path(KEEP) if KEEP else Path(tempfile.mkdtemp(prefix='cybexos-settings-'))
if not KEEP:
    atexit.register(shutil.rmtree, OUTPUT, True)
QML_ERRORS = re.compile(r'TypeError|ReferenceError|Binding loop|is not a type|Type \w+ unavailable'
                        r'|Cannot assign|Unable to assign|Illegal method name|Failed to load configuration'
                        r'|Cannot anchor|Cannot specify anchors|Duplicate|non-existent')

# The shortcut editor's fake hyprctl (real bindings.lua through the Node
# tests' Lua stub) and its guard against touching a live desktop.
_spec = importlib.util.spec_from_file_location('shortcut_editor', Path(__file__).with_name('shortcut-editor.py'))
EDITOR = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(EDITOR)

DOCTOR = {'version': 1, 'checkedAt': '2026-10-28T12:00:00Z', 'overall': 'suggestion',
          'counts': {'problem': 0, 'suggestion': 1, 'ok': 9, 'info': 1, 'unknown': 0},
          'scope': 'Read-only checks of this computer. They do not qualify hardware or change anything.',
          'checks': [{'id': check, 'state': state, 'title': check, 'summary': '', 'detail': '', 'facts': {}}
                     for check, state in (('graphics', 'ok'), ('drivers', 'ok'), ('firmware-files', 'info'),
                                          ('services', 'ok'), ('audio', 'ok'), ('secure-boot', 'ok'),
                                          ('firmware-updates', 'suggestion'), ('storage', 'ok'), ('battery', 'ok'),
                                          ('time', 'ok'), ('desktop', 'ok'))]}
MAINTENANCE = {'schema': 1, 'state': 'idle', 'policy': {'automatic': True, 'keepConfirmed': 5, 'keepDays': 30},
               'desiredPolicy': {'automatic': True, 'keepConfirmed': 5, 'keepDays': 30},
               'configurationError': '', 'configurationChanged': False, 'recoveryPending': False,
               'space': {'total': 1000 * 1024**3, 'available': 214 * 1024**3, 'low': False},
               'deployments': [{'id': 'a' * 32, 'confirmed': True, 'retired': False, 'eligible': False,
                                'pinned': False, 'reasons': ['Running system']}]}
# Records every call; answers what Settings reads. Anything that would ask
# for authorization succeeds here without doing anything.
FAKE_CYBEX = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
home = Path(os.environ["HOME"])
args = sys.argv[1:]
with (home / "cybex-calls").open("a") as log:
    log.write(json.dumps(args) + "\n")
if args == ["doctor", "--json"]:
    sys.stdout.write((home / "doctor.json").read_text()); sys.exit(0)
if args[:2] == ["maintenance", "status"]:
    sys.stdout.write((home / "maintenance.json").read_text()); sys.exit(0)
if args[:2] == ["config", "region"]:
    sys.exit(0)
sys.exit(127)
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
    function settingsView() { return shell.findNamed(pagesSettings.contentItem, "settingsView"); }
    IpcHandler {
        target: "settings-test"
        function state(): string {
            const view = shell.settingsView();
            const palette = view ? shell.findNamed(view, "settingsPalette") : null;
            const sheet = view ? shell.findNamed(view, "changesSheet") : null;
            const loader = view ? shell.findNamed(view, "settingsPageLoader") : null;
            return JSON.stringify({ open: Settings.panelOpen, page: Settings.page, tab: Settings.tab,
                history: Settings.pageHistory, canGoBack: view ? view.canGoBack : false,
                pageReady: !!(loader && loader.item), pageName: loader && loader.item ? String(loader.item.objectName) : "",
                changes: SettingsUi.SettingsChanges.items.map(item => item.id),
                plan: SettingsUi.SettingsChanges.plan, applying: SettingsUi.SettingsChanges.applying,
                changeError: SettingsUi.SettingsChanges.error,
                palette: palette ? { open: palette.open, choices: palette.choices.map(entry => entry.kind + ":" + entry.title) } : null,
                sheet: sheet ? sheet.open : null,
                recent: SettingsRecent.rows.map(row => row.key),
                regionLoaded: SystemSettings.region.loaded, regionDirty: SettingsUi.RegionDrafts.dirty,
                prepared: SettingsUi.RegionDrafts.prepared, highlight: Settings.highlightKey,
                shortcuts: shell.findNamed(pagesSettings.contentItem, "shortcutsPage") !== null,
                home: shell.findNamed(pagesSettings.contentItem, "settingsHomePage") !== null,
                dnd: Settings.notifDnd, clock24: Settings.clock24 });
        }
        function openPalette(text: string): void { shell.settingsView().openPalette(text); }
        function draftTouchpad(): void {
            const edit = SettingsUi.InputDrafts.touchpad;
            edit.draft = Object.assign({}, edit.draft, { tap: !edit.draft.tap });
        }
        function draftTimezone(value: string): void { SettingsUi.RegionDrafts.timezone = value; }
        function draftLocale(value: string): void { SettingsUi.RegionDrafts.locale = value; }
        function openReview(): void { shell.settingsView().openChanges(); }
        function applyChanges(): string { return String(SettingsUi.SettingsChanges.apply()); }
        function discardAll(): void { SettingsUi.SettingsChanges.discardAll(); }
        function goBack(): string { return String(shell.settingsView().goBack()); }
        function showPage(id: string): void { Settings.page = id; }
        function showTab(target: string, id: string): void { Settings.setTab(target, id); }
        function setValue(key: string, json: string): void { Settings.set(key, JSON.parse(json)); }
        function undoRecent(key: string): void { SettingsRecent.undo(SettingsRecent.rows.find(row => row.key === key)); }
        function pressEscape(): string { return String(shell.settingsView().handleEscape()); }
        function mark(text: string): void { console.log("TEST-MARK " + text); }
    }'''


def main():
    for executable in ('qs', 'sway', 'grim', 'wtype', 'cmake', 'node'):
        if not shutil.which(executable):
            raise SystemExit(f'{executable} is required; use nix develop with grim and wtype')
    lua = next((name for name in (os.environ.get('CYBEXOS_TEST_LUA'), 'lua', 'lua5.4', 'luajit')
                if name and shutil.which(name)), None)
    if not lua:
        raise SystemExit('Lua is required; use nix develop')
    EDITOR.process_guard()
    OUTPUT.mkdir(parents=True, exist_ok=True)
    processes = []
    with tempfile.TemporaryDirectory(prefix='private-', dir=OUTPUT) as temporary:
        base = Path(temporary)
        runtime, home = base / 'run', base / 'home'
        runtime.mkdir(mode=0o700)
        (runtime / 'cybexos').mkdir()
        (home / '.config/cybexos/hypr').mkdir(parents=True)
        (home / '.config/cybexos/shell.json').write_text(json.dumps({'v': 30, 'wall': '', 'assistantShown': False}))
        (home / 'doctor.json').write_text(json.dumps(DOCTOR))
        (home / 'maintenance.json').write_text(json.dumps(MAINTENANCE))
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
        source = entry.read_text().replace('SettingsWindow {}', 'SettingsWindow { id: pagesSettings }')
        source = source.replace('import "Common"\n', 'import "Common"\nimport "Settings" as SettingsUi\n', 1)
        assert 'pagesSettings' in source and 'SettingsUi' in source
        source = source.replace('    id: shell', '    id: shell' + TEST_IPC, 1)
        entry.write_text(source)

        stub = subprocess.run(['node', '-e', "process.stdout.write(require(process.argv[1]).stub)",
                               str(ROOT / 'tests/quickshell/keybindings-support.cjs')],
                              capture_output=True, text=True, check=True).stdout
        resolver = base / 'resolve.lua'
        resolver.write_text(f'package.path = {json.dumps(str(ROOT / "desktop/hypr/?.lua"))} .. ";" .. package.path\n'
                            'package.preload.features = function() return {} end\n'
                            + stub + "\nrequire('bindings')\nrequire('keybinding_preferences')\n")
        (base / 'bin').mkdir()
        for name, program in (('hyprctl', EDITOR.FAKE_HYPRCTL), ('cybex', FAKE_CYBEX)):
            path = base / 'bin' / name
            path.write_text(program)
            path.chmod(0o700)

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
               'PYTHONDONTWRITEBYTECODE': '1', **shell_fonts.fontconfig(base)}
        for name in ('DISPLAY', 'WAYLAND_DISPLAY', 'HYPRLAND_INSTANCE_SIGNATURE', 'SWAYSOCK', 'DBUS_SESSION_BUS_ADDRESS'):
            env.pop(name, None)
        subprocess.run([str(base / 'bin/hyprctl'), 'reload'], env=env, check=True, capture_output=True)

        def start(argv, log):
            handle = (base / log).open('w')
            proc = subprocess.Popen(argv, env=env, stdout=handle, stderr=subprocess.STDOUT, start_new_session=True)
            handle.close()
            processes.append(proc)
            return proc

        def ipc(target, method, *args):
            try:
                result = subprocess.run(['qs', 'ipc', '-p', str(shell), 'call', target, method, *args],
                                        env=env, capture_output=True, text=True, timeout=10)
            except subprocess.TimeoutExpired:
                return 'ipc-timeout'
            return result.stdout.strip() if result.returncode == 0 else 'ipc-unavailable'

        def state():
            try:
                return json.loads(ipc('settings-test', 'state'))
            except json.JSONDecodeError:
                return {}

        def wait(predicate, label, seconds=25):
            until = time.monotonic() + seconds
            while time.monotonic() < until:
                value = predicate()
                if value:
                    return value
                time.sleep(0.15)
            raise AssertionError(f'Timeout: {label}\n{json.dumps(state(), indent=1)[:4000]}')

        def screenshot(name):
            ipc('settings-test', 'mark', name)
            time.sleep(0.8)
            target = OUTPUT / name
            subprocess.run(['grim', str(target)], env=env, check=True, timeout=10)
            print(target)

        def focus_settings():
            subprocess.run(['swaymsg', '[title="Cybex OS Settings"]', 'focus'], env=env, check=True, capture_output=True)

        def keys(*argv):
            focus_settings()
            subprocess.run(['wtype', *argv], env=env, check=True, timeout=10)
            time.sleep(0.4)

        def show(page, tab=None):
            ipc('settings', 'open', page)
            expect = tab or ''
            return wait(lambda: (s := state()).get('pageReady') and s.get('tab', '') == expect and s, f'page {page}/{tab}')

        def calls():
            path = home / 'cybex-calls'
            return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

        try:
            (base / 'sway.conf').write_text('output HEADLESS-1 mode 1440x900\nseat seat0 fallback true\n'
                'for_window [title="Cybex OS Settings"] floating enable, resize set 1120 816, move position center\n')
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
            start(['wtype', '-s', '600000'], 'seat-keyboard.log')

            # Settings starts on Home, which replaced About.
            wait(lambda: ipc('settings', 'open', '') == '', 'Settings IPC')
            first = wait(lambda: (s := state()).get('home') and s, 'Home')
            assert first['page'] == 'home' and not first['canGoBack'], first
            time.sleep(2)
            screenshot('01-home.png')

            # Every page and tab loads; the tabbed pages keep their tab.
            for page, tab in (('appearance', None), ('wallpaper', None), ('bar', None), ('workspaces', None),
                              ('notifications', None), ('plugins', None), ('displays', None), ('sound', None),
                              ('network', None), ('touchpad', None), ('keyboard', 'layouts'), ('power', None),
                              ('security', None), ('accounts', None), ('assistant', None), ('applications', None),
                              ('region', None), ('backup', 'backups')):
                show(page, tab)
            show('keyboard', 'layouts')
            ipc('settings-test', 'showTab', 'keyboard', 'shortcuts')
            wait(lambda: state().get('shortcuts'), 'Keyboard › Shortcuts')
            show('backup', 'backups')
            ipc('settings-test', 'showTab', 'backup', 'recovery')
            wait(lambda: state().get('tab') == 'recovery', 'Recovery points tab')
            screenshot('02-backup-recovery.png')
            ipc('settings-test', 'showTab', 'backup', 'storage')
            wait(lambda: state().get('tab') == 'storage', 'Disk space tab')
            screenshot('03-backup-disk.png')

            # Legacy ids land on the merged pages and their tabs.
            show('shortcuts', 'shortcuts')
            assert state()['page'] == 'keyboard' and state()['shortcuts']
            screenshot('04-keyboard-shortcuts.png')
            show('storage', 'storage')
            assert state()['page'] == 'backup'
            show('about')
            assert state()['page'] == 'home'
            show('appearance')
            time.sleep(1)
            screenshot('05-appearance.png')

            # Back walks the pages visited since Settings opened.
            history = state()['history']
            assert history[-2:] == ['backup', 'home'], history
            assert ipc('settings-test', 'goBack') == 'true'
            wait(lambda: state()['page'] == 'home', 'Back to Home')
            keys('-M', 'alt', '-k', 'Left', '-m', 'alt')
            wait(lambda: state()['page'] == 'backup', 'Alt+Left back to Backup & storage')

            # The palette: "/" opens it, Enter jumps to the row and highlights it.
            show('appearance')
            keys('/')
            wait(lambda: (state().get('palette') or {}).get('open'), 'palette from /')
            keys('night')
            found = wait(lambda: 'row:Night light' in (state().get('palette') or {}).get('choices', []) and state(),
                         'Night light in the palette')
            screenshot('06-palette-night.png')
            choices = found['palette']['choices']
            for _ in range(choices.index('row:Night light')):
                keys('-k', 'Down')
            keys('-k', 'Return')
            landed = wait(lambda: (s := state()).get('page') == 'displays' and s, 'jump to Displays')
            assert landed['highlight'] == 'nightLight' and not landed['palette']['open'], landed
            # Ctrl+Enter flips a switch where it stands.
            dnd = state()['dnd']
            ipc('settings-test', 'openPalette', 'Do Not Disturb')
            wait(lambda: (state().get('palette') or {}).get('choices', [])[:1] == ['row:Do Not Disturb'], 'DND row')
            keys('-M', 'ctrl', '-k', 'Return', '-m', 'ctrl')
            wait(lambda: state()['dnd'] is (not dnd), 'Ctrl+Enter toggled Do Not Disturb')
            assert state()['palette']['open'], 'the palette stays open after a toggle'
            screenshot('07-palette-toggle.png')
            assert ipc('settings-test', 'pressEscape') == 'true'
            assert not state()['palette']['open']
            ipc('settings-test', 'setValue', 'notifDnd', json.dumps(dnd))

            # Recently changed: a change in the window appears on Home with
            # its earlier value, and Undo restores it.
            clock = state()['clock24']
            ipc('settings-test', 'setValue', 'clock24', json.dumps(not clock))
            show('home')
            wait(lambda: 'clock24' in state()['recent'], 'Recently changed lists the clock')
            screenshot('08-home-recent.png')
            ipc('settings-test', 'undoRecent', 'clock24')
            wait(lambda: state()['clock24'] is clock and 'clock24' not in state()['recent'], 'Undo restored the clock')

            # Drafts on two pages: the rail marks both, the chip counts them,
            # and the sheet reviews and applies them together.
            show('region')
            region_loaded = wait(lambda: (s := state()).get('pageReady') and s, 'region page')['regionLoaded']
            ipc('settings-test', 'draftTimezone', 'Europe/Berlin')
            ipc('settings-test', 'draftTouchpad')
            pending = wait(lambda: (s := state()) and {'region.timezone', 'touchpad.tap'} <= set(s['changes']) and s,
                           'two drafts')
            assert pending['plan']['steps'] == ['touchpad', 'region'], pending['plan']
            screenshot('09-region-drafts.png')
            ipc('settings-test', 'openReview')
            wait(lambda: state()['sheet'], 'review sheet')
            screenshot('10-review-sheet.png')
            if region_loaded:
                before = len(calls())
                assert ipc('settings-test', 'applyChanges') == 'true'
                wait(lambda: not state()['applying'], 'apply finished', 40)
                staged = [call for call in calls()[before:] if call[:2] == ['config', 'region']]
                assert len(staged) == 1 and staged[0][2:4] == ['timezone', 'Europe/Berlin'], staged
                assert state()['prepared'] == {'timezone': 'Europe/Berlin'}, state()
                print('combined region staging:', staged[0])
            else:
                print('region service unavailable here: staging is covered by test_native_input_region')
                ipc('settings-test', 'discardAll')
                wait(lambda: not state()['changes'], 'discard all')
            ipc('settings-test', 'discardAll')
            if state()['sheet']:
                assert ipc('settings-test', 'pressEscape') == 'true'

            # The narrow window: icon rail, compact chip.
            subprocess.run(['swaymsg', '[title="Cybex OS Settings"]', 'resize', 'set', '640', '620'],
                           env=env, check=True, capture_output=True)
            show('keyboard', 'layouts')
            time.sleep(1)
            screenshot('11-narrow.png')
            subprocess.run(['swaymsg', '[title="Cybex OS Settings"]', 'resize', 'set', '1120', '816'],
                           env=env, check=True, capture_output=True)
            ipc('settings-test', 'setValue', 'themeMode', json.dumps('light'))
            show('home')
            time.sleep(1.5)
            screenshot('12-home-light.png')
            ipc('settings-test', 'setValue', 'themeMode', json.dumps('dark'))

            ipc('settings', 'close')
            wait(lambda: not state()['open'] and not state()['history'], 'closing forgets the trail')
            log = (base / 'qs.log').read_text()
            problems = [line for line in log.splitlines() if QML_ERRORS.search(line)]
            assert not problems, '\n'.join(problems[:40])
            print('settings pages: all checks passed')
        except BaseException:
            for name in ('qs.log', 'sway.log'):
                path = base / name
                if path.exists():
                    print(f'--- {name}\n' + path.read_text()[-12000:])
            raise
        finally:
            for proc in reversed(processes):
                try:
                    os.killpg(proc.pid, 15)
                except ProcessLookupError:
                    pass
            for proc in processes:
                try:
                    proc.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(proc.pid, 9)
    EDITOR.process_guard(runtime)


if __name__ == '__main__':
    main()
