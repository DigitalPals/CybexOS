#!/usr/bin/env python3
"""Exercise the real first-login guide under a private headless compositor.

Run through nix develop, with grim, wtype, ImageMagick and Pillow on PATH.
The shell runs from a private git copy of this checkout with one test-only
IPC target injected, reached through the same `cybexos-runtime` dev-source
route as an installation. All service probes and writes inherit a private
HOME/XDG tree; hyprctl is a fake that serves shortcut state from that tree.
The real cybexos-assistant service runs beside the shell with a scripted
`claude` (signed out until its login command runs), `cybex doctor` serves a
fixture report, and 1Password is a desktop entry for a recording script.
No installed desktop is modified. Only requested screenshots survive
teardown; failed logs are printed inline.
"""
from __future__ import annotations
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import signal
import socket
import sqlite3
import subprocess
import sys
import tempfile
import time

import shell_fonts

ROOT = Path(__file__).resolve().parents[1]
ERRORS = re.compile(r'TypeError|ReferenceError|Binding loop|is not a type|Type \w+ unavailable'
                    r'|Cannot assign|Unable to assign|Illegal method name|Failed to load configuration')
# Action IDs the guide shows. The launcher is remapped and Close window is
# disabled, so keycaps prove they come from Keybindings, not from defaults.
ACTIONS = {
    'shell.launcher': ('Shell', 'Launcher', ['SUPER + ALT + L'], ['SUPER + SPACE']),
    'shell.settings': ('Shell', 'Cybex OS Settings', ['SUPER + comma'], ['SUPER + comma']),
    'shell.shortcuts': ('Shell', 'Keyboard shortcuts', ['SUPER + K'], ['SUPER + K']),
    'apps.terminal': ('Apps', 'Terminal', ['SUPER + Return'], ['SUPER + Return']),
    'apps.browser': ('Apps', 'Browser', ['SUPER + B'], ['SUPER + B']),
    'apps.files': ('Apps', 'Files', ['SUPER + E'], ['SUPER + E']),
    'windows.close': ('Windows', 'Close window', [], ['SUPER + W']),
    'windows.overview': ('Windows', 'Overview', ['SUPER + TAB'], ['SUPER + TAB']),
    'workspaces.switch.1': ('Workspaces', 'Switch to workspace 1', ['SUPER + 1'], ['SUPER + 1']),
    'workspaces.switch.2': ('Workspaces', 'Switch to workspace 2', ['SUPER + 2'], ['SUPER + 2']),
}
FAKE_HYPRCTL = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
state = Path(os.environ['XDG_RUNTIME_DIR']) / 'cybexos/keybindings-state.json'
if sys.argv[1:] == ['-j', 'binds']:
    masks = {'SUPER': 64, 'CTRL': 4, 'ALT': 8, 'SHIFT': 1}
    binds = []
    for row in json.loads(state.read_text())['actions']:
        for key in row['keys']:
            parts = key.split(' + ')
            binds.append({'modmask': sum(masks[p] for p in parts[:-1]), 'key': parts[-1],
                          'description': row['group'] + ': ' + row['label']})
    print(json.dumps(binds))
else:
    sys.exit(1)
'''
# Claude Code as the assistant service sees it: signed out until its own
# login command runs, then a stream-json session that records each question.
FAKE_CLAUDE = r'''
import json, os, sys
from pathlib import Path
home = Path(os.environ["HOME"])
signed_out = home / "signed-out-claude"
args = sys.argv[1:]
if args == ["auth", "status"]:
    sys.exit(int(signed_out.exists()))
if args == ["auth", "login"]:
    signed_out.unlink(missing_ok=True)
    sys.exit(0)
def emit(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()
emit({"type": "system", "subtype": "init", "session_id": "welcome-session"})
for line in sys.stdin:
    message = json.loads(line)
    if message.get("type") != "user":
        continue
    text = message["message"]["content"][0]["text"]
    with (home / "claude-questions.jsonl").open("a") as log:
        log.write(json.dumps(text) + "\n")
    reply = "I checked this computer." if "cybex doctor" in text else "I can help with Cybex OS."
    emit({"type": "result", "subtype": "success", "is_error": False, "result": reply, "session_id": "welcome-session"})
'''
# `cybex doctor --json` from a fixture; every other cybex call is absent, as
# on the test host.
FAKE_CYBEX = r'''
import os, sys
from pathlib import Path
if sys.argv[1:] == ["doctor", "--json"]:
    sys.stdout.write((Path(os.environ["HOME"]) / "doctor.json").read_text())
    sys.exit(0)
sys.exit(127)
'''
# The terminal a sign-in opens: record it and run the agent's login command.
FAKE_APPS = r'''
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
if args[:1] != ["terminal"]:
    os.execv(os.environ["CYBEXOS_TEST_REAL_APPS"], [os.environ["CYBEXOS_TEST_REAL_APPS"], *args])
Path(os.environ["HOME"]).joinpath("terminal-argv.json").write_text(json.dumps(args))
command = args[args.index("--") + 1:]
os.execv(command[0], command)
'''
DOCTOR = {'version': 1, 'checkedAt': '2026-10-28T12:00:00Z', 'overall': 'suggestion',
          'counts': {'problem': 0, 'suggestion': 2, 'ok': 8, 'info': 1, 'unknown': 0},
          'scope': 'Read-only checks of this computer. They do not qualify hardware or change anything.',
          'checks': [{'id': check, 'state': state, 'title': check, 'summary': '', 'detail': '', 'facts': {}}
                     for check, state in (('graphics', 'suggestion'), ('drivers', 'ok'), ('firmware-files', 'info'),
                                          ('services', 'ok'), ('audio', 'ok'), ('secure-boot', 'ok'),
                                          ('firmware-updates', 'suggestion'), ('storage', 'ok'), ('battery', 'ok'),
                                          ('time', 'ok'), ('desktop', 'ok'))]}
SYSTEM_CHECK = 'Check this computer for missing drivers and other problems.'
# Test-only instrumentation, injected into the private copy only.
TEST_IPC = '''
    function testFind(item, predicate) {
        if (!item) return null;
        if (predicate(item)) return item;
        for (const child of item.children || []) {
            const found = shell.testFind(child, predicate);
            if (found) return found;
        }
        return null;
    }
    function testItem(name) {
        return shell.testFind(welcomeWindow.contentItem, item => item.objectName === name);
    }
    IpcHandler {
        target: "welcome-test"
        function seedWallhaven(): void {
            const items = ["aaa111", "bbb222"].map((id, index) => ({id: id,
                fileName: "wallhaven-" + id + ".png", label: "Wallpaper " + id,
                image: "https://w.wallhaven.cc/full/" + id.slice(0, 2) + "/wallhaven-" + id + ".png",
                thumb: Wallpaper.url(Quickshell.shellDir + "/../../assets/wallpapers/"
                    + (index === 0 ? "moon-mountains.png" : "quiet-fjord.png")),
                page: "https://wallhaven.cc/w/" + id,
                width: 2560, height: 1440, size: 0, colors: []}));
            const details = {};
            for (const item of items)
                details[item.id] = Object.assign({}, item, {uploader: "", source: "", tags: []});
            OnlineWallpapers.detailsCache = details;
            OnlineWallpapers.results = items;
            OnlineWallpapers.searched = true;
        }
        function focusGrid(): void {
            const grid = shell.testItem("wallpaperGrid");
            grid.focusItem(grid.currentIndex);
        }
        function focusSearch(): void { shell.testItem("wallhavenSearch").forceActiveFocus(); }
        function focusRoot(): void { shell.testItem("welcomeView").focusInitial(); }
        function aside(): void { Welcome.stepAside(false); }
        function sheet(id: string): void { Welcome.openSheet(id); }
        function draftShortcut(): string { return String(Keybindings.setKeys("apps.terminal", ["F9"])); }
        function discardShortcuts(): string { return String(Keybindings.discard()); }
        function next(): void { Welcome.move(1); }
        // Activates a named control the way a click does, when it can be clicked.
        function press(name: string): string {
            const item = shell.testItem(name);
            if (!item || !item.visible || !item.enabled) return "false";
            item.clicked();
            return "true";
        }
        // Hyprland's window events, which this compositor does not send.
        function windowEvent(name: string, data: string): void {
            if (name === "openwindow") Welcome.windowOpened(data);
            else Welcome.windowClosed(data);
        }
        function launcher(open: bool): void { Launcher.open = open; }
        function state(): string {
            const view = shell.testItem("welcomeView");
            const step = shell.testItem("welcomeWallpaperStep");
            const search = shell.testItem("wallhavenSearch");
            const origin = view ? view.mapToItem(null, 0, 0) : {x: 0, y: 0};
            const keys = {};
            for (const id of ACTION_IDS) keys[id] = Keybindings.keysFor(id);
            return JSON.stringify({grid: shell.testItem("wallpaperGrid") !== null, tab: step ? step.tab : "",
                selected: OnlineWallpapers.selected ? OnlineWallpapers.selected.fileName || "" : "",
                wall: Settings.wall, current: Wallpaper.current, peeking: view ? view.peeking : false,
                zoom: TestGuide.Kiosk.zoom, mapped: welcomeWindow.contentItem ? welcomeWindow.contentItem.visible : false,
                view: view ? {x: origin.x, y: origin.y, width: view.width, height: view.height} : null,
                search: search ? search.text : null, searchFocus: search ? search.activeFocus : false,
                keysLoaded: Keybindings.loaded, watchers: SystemSettings.keybindings.watchers, keys: keys,
                paletteMode: Settings.paletteMode, paletteReady: TestCommon.Palette.ready, paletteBusy: TestCommon.Palette.busy,
                paletteError: TestCommon.Palette.error, paletteActive: Theme.paletteActive,
                paletteIdentity: TestCommon.Palette.wallpaperIdentity, primary: TestCommon.Palette.primary.toString(),
                themeMode: Settings.themeMode,
                requests: OnlineWallpapers.requestTimes.length});
        }
    }
'''


def keybindings_state():
    rows = [{'id': id, 'group': group, 'label': label, 'keys': keys, 'defaultKeys': defaults,
             'editable': True, 'protected': id in ('shell.settings', 'shell.shortcuts'), 'hidden': False,
             'changed': keys != defaults, 'custom': False}
            for id, (group, label, keys, defaults) in ACTIONS.items()]
    return {'v': 1, 'error': None, 'actions': rows, 'custom': [], 'diagnostics': []}


def own_processes(runtime):
    """PIDs whose environment names this test's private runtime directory."""
    marker = ('XDG_RUNTIME_DIR=' + str(runtime)).encode()
    found = []
    for entry in Path('/proc').iterdir():
        if not entry.name.isdigit():
            continue
        try:
            if entry.stat().st_uid == os.getuid() and marker in (entry / 'environ').read_bytes().split(b'\0'):
                found.append(int(entry.name))
        except OSError:
            continue
    return found


class Session:
    def __init__(self, base, imports):
        self.base = base
        self.home = base / 'home'
        self.runtime = base / 'run'
        self.runtime.mkdir(mode=0o700)
        (self.runtime / 'cybexos').mkdir()
        (self.runtime / 'cybexos/keybindings-state.json').write_text(json.dumps(keybindings_state()))
        self.source = base / 'source'
        self.copy_source()
        (base / 'bin').mkdir()
        for name, program in (('hyprctl', FAKE_HYPRCTL), ('cybex', FAKE_CYBEX), ('cybexos-apps', FAKE_APPS),
                              ('claude', FAKE_CLAUDE), ('fake-1password', 'import os, pathlib\n'
                              'pathlib.Path(os.environ["HOME"], "1password-launched").touch()\n')):
            (base / 'bin' / name).write_text(('' if name == 'hyprctl' else f'#!{sys.executable}\n') + program)
            (base / 'bin' / name).chmod(0o700)
        applications = self.home / '.local/share/applications'
        applications.mkdir(parents=True)
        (applications / '1password.desktop').write_text('[Desktop Entry]\nType=Application\nName=1Password\n'
                                                         f'Exec={base / "bin/fake-1password"}\n')
        self.home.joinpath('signed-out-claude').touch()
        self.home.joinpath('doctor.json').write_text(json.dumps(DOCTOR))
        config = self.home / '.config/cybexos'
        config.mkdir(parents=True)
        (config / 'dev-source').write_text(str(self.source) + '\n')
        # A fresh installation: no wallpaper chosen and no wallpaper folder.
        self.write_settings({'v': 30, 'assistantShown': False})
        self.env = {**os.environ, 'HOME': str(self.home), 'XDG_RUNTIME_DIR': str(self.runtime),
            'XDG_CONFIG_HOME': str(self.home / '.config'), 'XDG_DATA_HOME': str(self.home / '.local/share'),
            'XDG_STATE_HOME': str(self.home / '.local/state'), 'XDG_CACHE_HOME': str(self.home / '.cache'),
            'QT_QPA_PLATFORM': 'wayland', 'QT_QUICK_BACKEND': 'software',
            'QT_PLUGIN_PATH': os.environ.get('CYBEXOS_QT_PLUGIN_PATH', ''),
            'WLR_BACKENDS': 'headless', 'WLR_RENDERER': 'pixman', 'WLR_LIBINPUT_NO_DEVICES': '1',
            'HYPRLAND_INSTANCE_SIGNATURE': '', 'CYBEXOS_LANG': 'en', 'CYBEXOS_WELCOME': '1',
            'CYBEXOS_CONNECTED_WIDGETS': '0', 'CYBEXOS_DEVELOPER_TOOLS': '0', 'PYTHONDONTWRITEBYTECODE': '1',
            'CYBEXOS_THEME_ROOT': str(self.home / '.local/share/cybexos/themes'),
            'QML_IMPORT_PATH': str(imports) + ':' + os.environ.get('CYBEXOS_QML_IMPORT_PATH', ''),
            'PATH': str(base / 'bin') + ':' + str(self.source / 'assets/scripts') + ':' + os.environ['PATH'],
            'CYBEXOS_TEST_REAL_APPS': str(self.source / 'assets/scripts/cybexos-apps'),
            **shell_fonts.fontconfig(base)}
        self.service_env = {'PYTHONPATH': str(ROOT / 'desktop/assistant'), 'CYBEXOS_ASSISTANT_CLAUDE': str(base / 'bin/claude'),
                            'CYBEXOS_ASSISTANT_CODEX': str(base / 'no-codex'),
                            'CYBEXOS_ASSISTANT_STATUS': str(base / 'no-status.json')}
        for key in ('DISPLAY', 'WAYLAND_DISPLAY', 'SWAYSOCK', 'DBUS_SESSION_BUS_ADDRESS'):
            self.env.pop(key, None)
        self.processes = []
        self.shell = None
        self.shell_log = None
        self.logs = []

    def copy_source(self):
        # cybexos-runtime accepts only a git checkout as a dev source.
        self.source.mkdir()
        for name in ('desktop', 'assets'):
            shutil.copytree(ROOT / name, self.source / name, ignore=shutil.ignore_patterns('__pycache__'))
        shutil.copyfile(ROOT / 'VERSION', self.source / 'VERSION')
        subprocess.run(['git', 'init', '-q', str(self.source)], check=True)
        shell = self.source / 'desktop/quickshell'
        ids = 'const ACTION_IDS = ' + json.dumps(list(ACTIONS)) + ';'
        entry = shell / 'shell.qml'
        text = entry.read_text().replace('import "Common"\n', 'import "Common"\nimport "Common" as TestCommon\nimport "Welcome" as TestGuide\n')
        assert text.count('    WelcomeWindow {}\n') == 1
        entry.write_text(text.replace('    WelcomeWindow {}\n', '    WelcomeWindow { id: welcomeWindow }\n'
            + TEST_IPC.replace('const keys = {};', ids + '\n            const keys = {};'), 1))
        path = shell / 'Welcome/WelcomeView.qml'
        text = path.read_text()
        assert '    id: root\n' in text
        path.write_text(text.replace('    id: root\n', '    id: root\n    objectName: "welcomeView"\n', 1))
        # Scripted download boundary: no Wallhaven traffic in a UI regression.
        # The real singleton still runs its helper, saves, applies and emits
        # completion; Matugen and the QML palette path run unchanged.
        (shell / 'scripts/wallpaper-download.py').write_text('''import pathlib, shutil, sys
image, directory, size = sys.argv[1:]
destination = pathlib.Path(directory)
destination.mkdir(parents=True, exist_ok=True)
name = image.rsplit('/', 1)[-1]
source = pathlib.Path(__file__).resolve().parents[3] / 'assets/wallpapers'
shutil.copyfile(source / ('quiet-fjord.png' if 'bbb222' in name else 'moon-mountains.png'), destination / name)
print('done ' + name, flush=True)
''')

    @property
    def settings_path(self):
        return self.home / '.config/cybexos/shell.json'

    def write_settings(self, value):
        self.settings_path.write_text(json.dumps(value))

    def patch_settings(self, **values):
        current = json.loads(self.settings_path.read_text())
        current.update(values)
        self.write_settings(current)

    def start(self, argv, name, extra=None):
        log = self.base / name
        self.logs.append(log)
        with log.open('w') as output:
            process = subprocess.Popen(argv, env={**self.env, **(extra or {})}, stdout=output, stderr=subprocess.STDOUT,
                                       start_new_session=True)
        self.processes.append(process)
        return process

    def stop_process(self, process):
        if process is None or process.poll() is not None:
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
        self.shell = self.start([*dbus, '--', 'qs', '--no-color', '-p', str(self.source / 'desktop/quickshell')], name)
        self.shell_log = self.base / name
        self.wait(lambda: self.state(), 'welcome IPC')

    def call(self, target, *args):
        # The public runtime route resolves the source through this session's
        # private dev-source, exercising the same path identity as installation.
        result = subprocess.run([str(self.source / 'assets/scripts/cybexos-runtime'), 'ipc', target, *args],
            env=self.env, capture_output=True, text=True, timeout=10)
        return result.stdout.strip() if result.returncode == 0 else ''

    def ipc(self, *args):
        return self.call('welcome', *args)

    def json_call(self, target, *args):
        try:
            return json.loads(self.call(target, *args))
        except (json.JSONDecodeError, subprocess.TimeoutExpired):
            return {}

    def state(self):
        return self.json_call('welcome', 'status')

    def turn(self):
        """The assistant service's current turn, as its socket reports it."""
        with socket.socket(socket.AF_UNIX) as client:
            client.settimeout(10)
            client.connect(str(self.runtime / 'cybexos/assistant.sock'))
            client.sendall(json.dumps({'jsonrpc': '2.0', 'id': 1, 'method': 'hello',
                                       'params': {'client': 'welcome-test', 'protocol': 1}}).encode() + b'\n')
            buffer = b''
            while True:
                chunk = client.recv(65536)
                assert chunk, 'the assistant service closed the connection'
                buffer += chunk
                *lines, buffer = buffer.split(b'\n')
                for line in lines:
                    message = json.loads(line)
                    if message.get('id') == 1:
                        return message['result']['turn']

    def probe(self):
        return self.json_call('welcome-test', 'state')

    def wait(self, predicate, label, timeout=30):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            value = predicate()
            if value:
                return value
            time.sleep(.15)
        raise AssertionError('Timed out: ' + label + '\nlast probe: ' + json.dumps(self.probe()))

    def sway(self, *args):
        return subprocess.run(['swaymsg', *args], env=self.env, check=True, capture_output=True, text=True).stdout

    def guide_rect(self):
        """The guide's design canvas in output coordinates, or None while it is not on screen."""
        probe = self.probe()
        view = probe.get('view')
        if not probe.get('mapped') or not view:
            return None
        return {key: round(value) for key, value in view.items()}

    def output(self, width, height):
        self.sway('output', 'HEADLESS-1', 'mode', f'{width}x{height}')
        self.wait(lambda: (r := self.guide_rect()) is None or r['x'] + r['width'] <= width + 1
                  and r['height'] <= height + 1, f'{width}x{height} output')

    def key(self, *args):
        # The guide holds exclusive keyboard focus as an overlay layer.
        subprocess.run(['wtype', '-s', '200', *args, '-s', '100'], env=self.env, check=True, timeout=10)
        time.sleep(.25)

    def capture(self, directory, name, settle=.8):
        # Let async wallpaper thumbnails and the short step fade settle.
        time.sleep(settle)
        path = directory / name
        subprocess.run(['grim', str(path)], env=self.env, check=True, timeout=15)
        return path

    def capture_guide(self, directory, name, settle=1.0):
        """A screenshot cropped to the guide's canvas, for reviewing its layout."""
        from PIL import Image
        path = self.capture(directory, name, settle)
        rect = self.guide_rect()
        Image.open(path).crop((rect['x'], rect['y'], rect['x'] + rect['width'], rect['y'] + rect['height'])).save(path)
        return path

    @property
    def state_path(self):
        return self.home / '.local/state/cybexos/welcome.json'

    def binding_loops(self):
        """Binding-loop warnings in the running shell's log so far."""
        return [line for line in self.shell_log.read_text(errors='replace').splitlines() if 'Binding loop' in line]

    def check_logs(self):
        failures = []
        for path in self.logs:
            if not path.name.startswith('qs'):
                continue
            for line in path.read_text(errors='replace').splitlines():
                if ERRORS.search(line) or (('WARN' in line or 'ERROR' in line)
                        and re.search(r'(Welcome(?:Window|Helpers)?\.qml|Welcome/|WallpaperPicker\.qml)', line)):
                    failures.append(line)
        assert not failures, '\n'.join(failures)


def region_difference(first, second, box):
    from PIL import Image, ImageChops, ImageStat
    left = Image.open(first).convert('RGB').crop(box)
    right = (second if isinstance(second, Image.Image) else Image.open(second)).convert('RGB').crop(box)
    return max(ImageStat.Stat(ImageChops.difference(left, right)).mean)


def inset(rect, margin):
    return (rect['x'] + margin, rect['y'] + margin,
            rect['x'] + rect['width'] - margin, rect['y'] + rect['height'] - margin)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--screenshots', type=Path, required=True,
                        help='screenshot directory; image comparisons need real frames')
    args = parser.parse_args()
    for executable in ('qs', 'sway', 'grim', 'wtype', 'cmake', 'git'):
        if not shutil.which(executable):
            raise SystemExit(f'{executable} is required; use nix develop with grim and wtype')
    from PIL import Image, ImageOps
    shots = args.screenshots
    shots.mkdir(parents=True, exist_ok=True)
    # Keep XDG_RUNTIME_DIR short enough for Quickshell's Unix IPC socket,
    # even when requested screenshots live under a long task output path.
    with tempfile.TemporaryDirectory(prefix='cxw-') as temporary:
        base = Path(temporary)
        native = base / 'native'
        subprocess.run(['cmake', '-S', str(ROOT / 'desktop/notification-images'), '-B', str(native),
                        '-DCMAKE_BUILD_TYPE=Release', '-DBUILD_TESTING=OFF'], check=True, capture_output=True)
        subprocess.run(['cmake', '--build', str(native), '--parallel', '2'], check=True, capture_output=True)
        session = Session(base, native / 'qml')
        assert not own_processes(session.runtime)
        try:
            conf = base / 'sway.conf'
            conf.write_text('output HEADLESS-1 mode 1440x900\nseat seat0 fallback true\n')
            sway = base / 'sway'
            shutil.copyfile(os.environ.get('CYBEXOS_SWAY_BINARY') or shutil.which('sway'), sway)
            sway.chmod(0o700)
            session.start([str(sway), '-c', str(conf)], 'sway.log')
            sockets = session.wait(lambda: [p for p in session.runtime.glob('wayland-*') if p.is_socket()], 'Sway')
            session.env['WAYLAND_DISPLAY'] = sockets[0].name
            session.env['SWAYSOCK'] = str(session.wait(lambda: next(session.runtime.glob('sway-ipc.*.sock'), None), 'Sway IPC'))
            # Real seeded web apps, entirely offline and under private HOME.
            subprocess.run([str(session.source / 'assets/scripts/cybexos-webapp'), 'seed'], env=session.env,
                           check=True, capture_output=True)
            session.start([sys.executable, '-B', '-m', 'cybexos_assistant', 'serve'], 'assistant.log', session.service_env)
            session.wait(lambda: (session.runtime / 'cybexos/assistant.sock').exists(), 'assistant service')
            session.start_shell('qs-first.log')
            session.wait(lambda: session.state().get('open'), 'first-login auto opening')
            assert session.state()['step'] == 'hello'
            rect = session.wait(session.guide_rect, 'mapped guide')
            # The installer's canvas, zoomed by its rule and rounded down to
            # fit: 1440×900 gives 1.12, a 1434×896 canvas centred on the output.
            probe = session.probe()
            assert abs(probe['zoom'] - 1.12) < 1e-6, probe['zoom']
            assert (rect['width'], rect['height']) == (1434, 896) and (rect['x'], rect['y']) == (3, 2), rect
            first = session.capture(shots, 'welcome-hello-en.png', settle=.3)

            # Fresh installation: an empty Settings.wall shows the bundled
            # default. The guide covers the screen; stepping aside shows the
            # desktop behind it and leaves the resume pill.
            probe = session.probe()
            assert probe['wall'] == '' and probe['current'].endswith('/assets/wallpapers/moon-mountains.png'), probe
            assert not (session.home / 'Pictures/Wallpapers').exists(), 'the default must not be imported'
            session.call('welcome-test', 'aside')
            session.wait(lambda: session.state().get('aside') and not session.probe().get('mapped'), 'guide steps aside')
            behind = session.capture(shots, 'welcome-aside-en.png')
            width, height = Image.open(behind).size
            strip = (8, int(height * .3), int(width * .25), int(height * .7))
            expected = {name: ImageOps.fit(Image.open(ROOT / 'assets/wallpapers' / name).convert('RGB'), (width, height),
                        method=Image.Resampling.BILINEAR) for name in ('moon-mountains.png', 'quiet-fjord.png')}
            default_diff = region_difference(behind, expected['moon-mountains.png'], strip)
            other_diff = region_difference(behind, expected['quiet-fjord.png'], strip)
            assert default_diff < 6 and other_diff > default_diff * 3, (default_diff, other_diff)
            assert region_difference(first, behind, strip) > 15, 'the guide must cover the desktop'
            assert session.ipc('open', '') == 'ok'
            session.wait(lambda: not session.state().get('aside') and session.guide_rect(), 'open resumes the guide')

            session.wait(lambda: session.probe().get('paletteActive'), 'default wallpaper palette')
            assert session.probe()['paletteError'] == ''
            assert session.ipc('open', 'keys') == 'unknown'
            assert session.ipc('open', 'unknown') == 'unknown'
            for step in ('hello', 'connect', 'wallpaper', 'style', 'shortcuts', 'finish'):
                assert session.ipc('open', step) == 'ok'
                session.wait(lambda: session.state().get('step') == step, step)
                if step == 'connect':
                    session.wait(lambda: session.state()['connect'] == {'password': 'available', 'assistant': 'required'},
                                 'Connect offers 1Password and the assistant sign-in')
                if step == 'finish':
                    session.wait(lambda: session.state()['doctor']['attention']
                                 == ['graphics:suggestion', 'firmware-updates:suggestion'], 'the system check report')
                if step == 'wallpaper':
                    session.wait(lambda: (p := session.probe()).get('grid') and p.get('tab') == 'online', 'Wallhaven first')
                if step == 'shortcuts':
                    session.wait(lambda: session.probe().get('keysLoaded'), 'Keybindings loaded')
                session.capture(shots, 'welcome-' + step + '-en.png')

            # Hello's Continue leads to Connect, and Connect's to Wallpaper.
            session.ipc('open', 'hello')
            session.call('welcome-test', 'next')
            session.wait(lambda: session.state().get('step') == 'connect', 'Hello continues to Connect')
            assert session.state()['steps'] == ['hello', 'connect', 'wallpaper', 'style', 'shortcuts', 'finish']
            # 1Password: the guide steps aside for its window and comes back
            # when that window closes; only the window it opened counts.
            assert session.call('welcome-test', 'press', 'connectPassword') == 'true'
            session.wait(lambda: (session.home / '1password-launched').exists(), '1Password launched from its desktop entry')
            session.wait(lambda: session.state().get('aside'), 'the guide steps aside for 1Password')
            assert session.state()['connect']['password'] == 'opened'
            session.call('welcome-test', 'windowEvent', 'openwindow', 'a1b2,1,kitty,Terminal')
            session.call('welcome-test', 'windowEvent', 'openwindow', 'c3d4,1,1Password,Lock Screen, 1Password')
            session.call('welcome-test', 'windowEvent', 'closewindow', 'a1b2')
            time.sleep(.5)
            assert session.state()['aside'], 'another window closing does not bring the guide back'
            session.call('welcome-test', 'windowEvent', 'closewindow', 'c3d4')
            session.wait(lambda: not session.state().get('aside'), 'closing 1Password brings the guide back')
            assert session.state()['step'] == 'connect'
            session.capture(shots, 'welcome-connect-opened-en.png')
            # 1Password's database with no account leaves the card as it is; the
            # sign-in finishing while the guide shows gives it a tick.
            accounts = session.home / '.config/1Password/1password.sqlite'
            accounts.parent.mkdir(parents=True)
            onepassword = sqlite3.connect(accounts)
            onepassword.execute('PRAGMA journal_mode=WAL')
            onepassword.execute('CREATE TABLE accounts (account_uuid TEXT PRIMARY KEY NOT NULL, data BLOB NOT NULL)')
            onepassword.commit()
            time.sleep(5)
            assert session.state()['connect']['password'] == 'opened'
            onepassword.execute("INSERT INTO accounts VALUES ('personal', x'00')")
            onepassword.commit()
            session.wait(lambda: session.state()['connect']['password'] == 'ready', '1Password signed in', timeout=15)
            onepassword.close()
            session.capture(shots, 'welcome-connect-signed-in-en.png')
            # The assistant: its own login command runs in a terminal, and the
            # guide returns by itself once the service reports the sign-in.
            assert session.call('welcome-test', 'press', 'connectAgent-claude') == 'true'
            session.wait(lambda: session.state().get('aside'), 'the guide steps aside for the sign-in')
            argv = json.loads((session.home / 'terminal-argv.json').read_text())
            assert argv[0] == 'terminal' and argv[-3:] == [str(base / 'bin/claude'), 'auth', 'login'], argv
            session.wait(lambda: not session.state().get('aside') and session.state()['connect']['assistant'] == 'ready',
                         'the guide comes back once the assistant is signed in', timeout=40)
            assert session.state()['step'] == 'connect'
            session.capture(shots, 'welcome-connect-ready-en.png')
            # Ready: the check's findings, and the assistant asked about them.
            session.ipc('open', 'finish')
            session.wait(lambda: session.state()['doctor']['overall'] == 'suggestion', 'the system check report')
            session.capture(shots, 'welcome-finish-check-en.png')
            assert session.call('welcome-test', 'press', 'readyAskAssistant') == 'true'
            session.wait(lambda: session.state().get('aside'), 'the guide steps aside for the system check')
            turn = session.wait(lambda: (t := session.turn()) and t['status'] == 'completed' and t, 'the system check turn')
            assert turn['prompt'] == SYSTEM_CHECK, turn
            # The service turned the question's purpose into the note that
            # sends the agent to `cybex doctor`.
            assert turn['text'] == 'I checked this computer.', turn
            asked = [json.loads(line) for line in (session.home / 'claude-questions.jsonl').read_text().splitlines()]
            assert asked[-1].startswith('[Cybex OS: ') and asked[-1].endswith('\n' + SYSTEM_CHECK), asked[-1]
            session.ipc('open', '')
            session.wait(lambda: not session.state().get('aside'), 'resume after the system check')

            # Keycaps come from Keybindings: the remapped launcher, a
            # disabled action, and Close window marked "Not bound".
            session.ipc('open', 'shortcuts')
            session.wait(lambda: session.probe().get('watchers') == 1, 'shortcut claim')
            probe = session.probe()
            assert probe['watchers'] == 1, probe
            keys = probe['keys']
            assert keys['shell.launcher'] == ['SUPER + ALT + L'], keys
            assert keys['windows.close'] == [], keys
            assert keys['apps.terminal'] == ['SUPER + Return'], keys
            assert keys['workspaces.switch.2'] == ['SUPER + 2'], keys
            session.capture(shots, 'welcome-shortcuts-unbound-en.png')

            # A shell surface over the guide is transient: the guide steps
            # aside while it is open and comes back when it closes.
            session.call('welcome-test', 'launcher', 'true')
            session.wait(lambda: session.state().get('aside'), 'launcher makes the guide step aside')
            assert session.probe()['watchers'] == 0, 'a guide out of the way holds no claim'
            session.call('welcome-test', 'launcher', 'false')
            session.wait(lambda: not session.state().get('aside'), 'the guide resumes after the launcher')
            assert session.state()['step'] == 'shortcuts'

            # Enter activates the primary action with initial page focus.
            session.ipc('open', 'finish')
            session.call('welcome-test', 'focusRoot')
            session.key('-k', 'Return')
            session.wait(lambda: session.state().get('status') == 'completed', 'Finish')
            assert not session.state()['open']
            session.wait(lambda: session.probe().get('watchers') == 0, 'Keybindings claim released on close')
            session.ipc('open', '')
            assert session.state()['step'] == 'hello'

            # Selecting an online tile applies immediately. The scripted
            # download saves a real image; the real Matugen must drive the
            # next step's palette.
            session.ipc('open', 'wallpaper')
            session.wait(lambda: session.probe().get('tab') == 'online', 'Wallhaven tab')
            probe = session.probe()
            assert probe['selected'] == '' and probe['wall'] == '', probe
            assert probe['requests'] == 0, 'unknown metering must not contact Wallhaven'
            session.call('welcome-test', 'seedWallhaven')
            keyboard = session.start(['wtype', '-s', '800', '-d', '100', '-k', 'Right', '-k', 'Return',
                                      '-s', '200'], 'keyboard.log')
            time.sleep(.25)
            session.call('welcome-test', 'focusGrid')
            session.wait(lambda: session.probe().get('selected') == 'wallhaven-bbb222.png', 'keyboard selection')
            assert keyboard.wait(timeout=10) == 0, 'wtype failed'
            applied = session.wait(lambda: (p := session.probe()).get('wall') == 'wallhaven-bbb222.png' and p,
                                   'online wallpaper automatically applied')
            assert session.state()['step'] == 'wallpaper', 'Enter in the grid must not continue'
            assert json.loads(session.call('wallpaper', 'list'))['current'] == 'wallhaven-bbb222.png'
            session.ipc('open', 'style')
            generated = session.wait(lambda: (p := session.probe()).get('paletteReady')
                and not p['paletteBusy'] and p['paletteIdentity'].endswith('/wallhaven-bbb222.png') and p,
                'selected wallpaper palette')
            assert generated['paletteMode'] == 'wallpaper' and generated['paletteActive'], generated
            assert generated['paletteError'] == '', generated
            expected_palette = json.loads(subprocess.check_output(['matugen', 'image',
                str(ROOT / 'assets/wallpapers/quiet-fjord.png'), '--type', 'scheme-tonal-spot',
                '--source-color-index', '0', '--dry-run', '--json', 'hex', '--quiet'], env=session.env))
            assert generated['primary'] == expected_palette['colors']['primary']['dark']['color'], generated
            session.patch_settings(themeMode='light')
            session.wait(lambda: session.probe().get('primary') == expected_palette['colors']['primary']['light']['color'],
                         'light wallpaper palette')
            session.capture(shots, 'welcome-style-light-en.png')
            session.patch_settings(themeMode='dark', paletteMode='fixed')
            session.ipc('open', 'wallpaper')
            session.ipc('open', 'style')
            session.wait(lambda: session.probe().get('paletteMode') == 'fixed', 'explicit fixed colours preserved')
            session.call('welcome-test', 'focusRoot')
            session.key('-k', 'Return')
            session.wait(lambda: session.state().get('step') == 'shortcuts', 'Style continues directly to Shortcuts')
            session.patch_settings(paletteMode='wallpaper')
            session.ipc('open', 'wallpaper')
            session.capture(shots, 'welcome-wallpaper-applied-en.png')

            # Space types in Wallhaven search and does not peek. Metering is
            # unknown in this private session, so no request is made.
            session.wait(lambda: session.probe().get('search') is not None, 'Wallhaven view')
            typing = session.start(['wtype', '-s', '1000', 'sea', '-P', 'space', '-s', '1200', '-p', 'space',
                                    'side', '-s', '100'], 'typing.log')
            time.sleep(.25)
            session.call('welcome-test', 'focusSearch')
            session.wait(lambda: session.probe().get('searchFocus'), 'search focus')
            time.sleep(1.5)
            assert not session.probe()['peeking'], 'Space in a text field must not peek'
            assert typing.wait(timeout=10) == 0, 'wtype failed'
            searched = session.wait(lambda: (p := session.probe()).get('search', '').endswith('side') and p,
                                    'typing into search', timeout=8)
            # A held key repeats in a text field: one or more real spaces.
            assert re.fullmatch(r'sea +side', searched['search']), searched['search']
            assert searched['requests'] == 0, 'typing must not contact Wallhaven'
            session.capture(shots, 'welcome-wallpaper-search-en.png')

            # Hold Space: the guide fades and the actual desktop shows.
            session.ipc('close')
            session.wait(lambda: session.guide_rect() is None, 'guide unmapped')
            desktop = session.capture(base, 'desktop.png')
            session.ipc('open', 'wallpaper')
            rect = session.wait(session.guide_rect, 'guide mapped again')
            shown = session.capture(base, 'shown.png')
            box = inset(rect, 40)
            assert region_difference(shown, desktop, box) > 15, 'the guide must cover the compared region'
            session.call('welcome-test', 'focusGrid')  # a focused tile still peeks
            # One virtual keyboard owns the entire press/release pair.
            # wtype: -P presses and -p releases; it rejects unknown flags
            # before sending anything, so its exit status is checked.
            peek = session.start(['wtype', '-s', '200', '-P', 'space', '-s', '2000', '-p', 'space'], 'peek.log')
            # Past Sway's 600 ms repeat delay, so repeated release/press
            # pairs have arrived and must not have ended the peek.
            time.sleep(1.2)
            assert session.probe()['peeking'], 'holding Space peeks'
            peeked = session.capture(shots, 'welcome-wallpaper-peek-en.png', settle=.3)
            assert peek.wait(timeout=10) == 0, 'wtype failed'
            session.wait(lambda: not session.probe().get('peeking'), 'release ends the peek')
            assert session.state()['open'], 'Space keeps the guide open'
            peek_diff = region_difference(peeked, desktop, box)
            assert peek_diff < 2, f'Space must reveal the actual desktop (difference {peek_diff:.2f})'
            back = session.capture(base, 'back.png')
            assert region_difference(back, shown, box) < 2, 'release restores the guide'

            # A sheet opens over the guide and Escape closes only the sheet.
            session.call('welcome-test', 'sheet', 'keyboard')
            session.wait(lambda: session.state().get('sheet') == 'keyboard', 'keyboard sheet')
            session.capture(shots, 'welcome-sheet-keyboard-en.png')
            session.key('-k', 'Escape')
            session.wait(lambda: session.state().get('sheet') == '', 'Escape closes the sheet')
            assert session.state()['open'], 'Escape in a sheet must not dismiss the guide'

            # The canvas follows the installer's zoom on other outputs,
            # centred, with no binding loop.
            assert not session.binding_loops(), session.binding_loops()
            for (width, height), zoom in (((1280, 800), 1.0), ((1920, 1080), 1.35), ((1024, 600), .75)):
                session.output(width, height)
                session.wait(lambda: abs(session.probe().get('zoom', 0) - zoom) < 1e-6, f'zoom {zoom} at {width}x{height}')
                rect = session.wait(session.guide_rect, 'canvas')
                assert abs(rect['width'] - 1280 * zoom) <= 1 and abs(rect['height'] - 800 * zoom) <= 1, rect
                assert abs(rect['x'] * 2 + rect['width'] - width) <= 2, f'centred: {rect}'
                session.capture(shots, f'welcome-wallpaper-{width}x{height}-en.png')
            assert not session.binding_loops(), session.binding_loops()
            session.output(1440, 900)

            session.key('-M', 'ctrl', '-k', 'Next', '-m', 'ctrl')
            session.wait(lambda: session.state().get('step') == 'style', 'Ctrl+PageDown')
            session.key('-M', 'ctrl', '-k', 'Prior', '-m', 'ctrl')
            assert session.state()['step'] == 'wallpaper'
            # Escape inside the grid dismisses like Escape elsewhere.
            session.call('welcome-test', 'focusGrid')
            session.key('-k', 'Escape')
            session.wait(lambda: session.state().get('status') == 'dismissed', 'Escape dismiss')
            session.wait(lambda: session.state_path.exists() and json.loads(session.state_path.read_text()).get('status') == 'dismissed', 'saved dismissal')
            session.start_shell('qs-restart.log')
            time.sleep(1)
            assert not session.state()['open'] and session.state()['status'] == 'dismissed'
            assert session.probe()['watchers'] == 0, 'a closed guide holds no claim'
            session.ipc('open', '')
            assert session.state()['step'] == 'wallpaper'
            session.ipc('close')

            # The preview follows the largest text size; the guide keeps the
            # installer's layout.
            session.stop_process(session.shell)
            session.patch_settings(textScale='larger')
            session.start_shell('qs-larger.log')
            session.ipc('open', 'style')
            session.wait(session.guide_rect, 'guide')
            session.capture(shots, 'welcome-style-larger-en.png', settle=1.2)
            session.ipc('close')
            session.stop_process(session.shell)
            session.patch_settings(textScale='default')

            # The whole guide in English and Dutch at two output sizes,
            # cropped to the canvas for layout review.
            for language in ('en', 'nl'):
                session.env['CYBEXOS_LANG'] = language
                session.start_shell(f'qs-tour-{language}.log')
                for size, (width, height) in (('normal', (1440, 900)), ('small', (1024, 600))):
                    session.output(width, height)
                    for step in ('hello', 'connect', 'wallpaper', 'style', 'shortcuts', 'finish'):
                        assert session.ipc('open', step) == 'ok'
                        session.wait(lambda: session.state().get('step') == step and session.guide_rect(), step)
                        session.capture_guide(shots, f'tour-{language}-{size}-{step}.png')
                    for sheet in ('language', 'keyboard', 'timezone', 'theme'):
                        session.ipc('open', 'style' if sheet == 'theme' else 'hello')
                        session.call('welcome-test', 'sheet', sheet)
                        session.wait(lambda: session.state().get('sheet') == sheet, sheet)
                        session.capture_guide(shots, f'tour-{language}-{size}-sheet-{sheet}.png')
                        session.key('-k', 'Escape')
                        session.wait(lambda: session.state().get('sheet') == '', f'{sheet} closed')
                    # A shortcut change waiting: the footer note, then the
                    # question Continue asks, which Escape closes.
                    assert session.ipc('open', 'shortcuts') == 'ok'
                    session.wait(lambda: session.probe().get('keysLoaded'), 'shortcuts loaded')
                    assert session.call('welcome-test', 'draftShortcut') == 'true'
                    session.capture_guide(shots, f'tour-{language}-{size}-shortcuts-pending.png')
                    session.call('welcome-test', 'next')
                    session.wait(lambda: session.state().get('sheet') == 'shortcuts', 'shortcut question')
                    session.capture_guide(shots, f'tour-{language}-{size}-sheet-shortcuts.png')
                    session.key('-k', 'Escape')
                    session.wait(lambda: (s := session.state()).get('sheet') == '' and s.get('step') == 'shortcuts',
                                 'shortcut question closed')
                    assert session.call('welcome-test', 'discardShortcuts') == 'true'
                    session.call('welcome-test', 'aside')
                    session.wait(lambda: session.state().get('aside'), 'aside')
                    session.capture(shots, f'tour-{language}-{size}-aside.png')
                    session.ipc('open', '')
                session.output(1440, 900)
            session.ipc('open', 'hello')
            session.capture(shots, 'welcome-hello-nl.png')
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
            print(json.dumps({'defaultWallpaperDifference': round(default_diff, 2),
                              'otherWallpaperDifference': round(other_diff, 2),
                              'peekDifference': round(peek_diff, 2), 'applied': applied['wall']}))
            print('PASS: fresh-install default wallpaper behind the full-screen guide, installer zoom at four '
                  'output sizes, first login, all six steps, Connect (1Password aside and return on its window closing, its tick once an account appears, '
                  'the assistant\'s own sign-in and automatic return), the system check on Ready and the question it asks, '
                  'Keybindings keycaps (remapped/unbound) and claim '
                  'lifecycle, stepping aside for the launcher, tile apply, Space typing in search, Space peek '
                  'versus the desktop-only frame, sheets and Escape, Finish, keyboard navigation, '
                  'dismissal/resume across restart, Dutch, protected invalid state, reset and environment suppression')
        except Exception:
            for log in session.logs:
                if log.name.startswith('qs'):
                    print(log.name + '\n' + log.read_text(errors='replace')[-20000:])
            raise
        finally:
            session.stop()
            leftovers = []
            for _ in range(50):
                leftovers = own_processes(session.runtime)
                if not leftovers:
                    break
                time.sleep(.1)
            assert not leftovers, f'task-owned processes remain: {leftovers}'


if __name__ == '__main__':
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(SystemExit(143)))
    main()
