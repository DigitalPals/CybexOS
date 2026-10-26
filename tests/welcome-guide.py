#!/usr/bin/env python3
"""Exercise the real first-login guide under a private headless compositor.

Run through nix develop, with grim, wtype, ImageMagick and Pillow on PATH.
The shell runs from a private git copy of this checkout with one test-only
IPC target injected, reached through the same `cybexos-runtime` dev-source
route as an installation. All service probes and writes inherit a private
HOME/XDG tree; hyprctl is a fake that serves shortcut state from that tree.
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
import subprocess
import tempfile
import time

import shell_fonts

ROOT = Path(__file__).resolve().parents[1]
TITLE = 'Welcome to Cybex OS'
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
            const grid = shell.testFind(shell.testItem("wallpaperPicker"), item => item.visible && item.online === true && item.focusItem !== undefined);
            grid.focusItem(grid.currentIndex);
        }
        function focusSearch(): void { shell.testItem("wallhavenSearch").forceActiveFocus(); }
        function colour(): string {
            const filter = shell.testItem("wallhavenColour");
            if (!filter) return "missing";
            filter.open();
            return "ok";
        }
        function colourOpen(): string { const filter = shell.testItem("wallhavenColour"); return String(!!filter && filter.opened); }
        function focusRoot(): void { shell.testItem("welcomeView").focusInitial(); }
        function state(): string {
            const picker = shell.testItem("wallpaperPicker");
            const view = shell.testItem("welcomeView");
            const search = shell.testItem("wallhavenSearch");
            const keys = {};
            for (const id of ACTION_IDS) keys[id] = Keybindings.keysFor(id);
            return JSON.stringify({picker: picker !== null, tab: picker ? picker.tab : "",
                showSources: picker ? picker.showSources : true,
                applyOnSelect: picker ? picker.applyOnSelect : false,
                selected: picker && picker.selected ? picker.selected.fileName || "" : "",
                wall: Settings.wall, current: Wallpaper.current, peeking: view ? view.peeking : false,
                shortHeight: view ? view.shortHeight : null, footer: Theme.scaled(76), margins: [Theme.scaled(16), Theme.scaled(28)], step: Theme.scaled(520),
                railShown: view ? view.railShown : null,
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
        (base / 'bin/hyprctl').write_text(FAKE_HYPRCTL)
        (base / 'bin/hyprctl').chmod(0o700)
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
            **shell_fonts.fontconfig(base)}
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
        text = entry.read_text().replace('import "Common"\n', 'import "Common"\nimport "Common" as TestCommon\n')
        assert text.count('    WelcomeWindow {}\n') == 1
        entry.write_text(text.replace('    WelcomeWindow {}\n', '    WelcomeWindow { id: welcomeWindow }\n'
            + TEST_IPC.replace('const keys = {};', ids + '\n            const keys = {};'), 1))
        for name, owner in (('Settings/WallpaperPicker.qml', 'wallpaperPicker'), ('Welcome/WelcomeView.qml', 'welcomeView')):
            path = shell / name
            text = path.read_text()
            assert '    id: root\n' in text, name
            path.write_text(text.replace('    id: root\n', f'    id: root\n    objectName: "{owner}"\n', 1))
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

    def start(self, argv, name):
        log = self.base / name
        self.logs.append(log)
        with log.open('w') as output:
            process = subprocess.Popen(argv, env=self.env, stdout=output, stderr=subprocess.STDOUT,
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
        """The guide's content rectangle in output coordinates, or None."""
        def walk(node):
            if node.get('name') == TITLE and node.get('visible'):
                rect, inner = node['rect'], node['window_rect']
                return {'x': rect['x'] + inner['x'], 'y': rect['y'] + inner['y'],
                        'width': inner['width'], 'height': inner['height']}
            for child in node.get('nodes', []) + node.get('floating_nodes', []):
                found = walk(child)
                if found:
                    return found
            return None
        return walk(json.loads(self.sway('-t', 'get_tree')))

    def focus(self):
        self.sway(f'[title="{TITLE}"] focus')

    def key(self, *args):
        self.focus()
        subprocess.run(['wtype', '-s', '200', *args, '-s', '100'], env=self.env, check=True, timeout=10)
        time.sleep(.25)

    def capture(self, directory, name, settle=.8):
        # Let async wallpaper thumbnails and the short step fade settle.
        time.sleep(settle)
        path = directory / name
        subprocess.run(['grim', str(path)], env=self.env, check=True, timeout=15)
        return path

    def capture_guide(self, directory, name, settle=1.0):
        """A screenshot cropped to the guide window, for reviewing its layout."""
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
            conf.write_text('output HEADLESS-1 mode 1440x900\nseat seat0 fallback true\n'
                # No decorations: `resize set` then sizes the guide's own surface.
                f'for_window [title="{TITLE}"] floating enable, border none, move position center\n')
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
            session.start_shell('qs-first.log')
            session.wait(lambda: session.state().get('open'), 'first-login auto opening')
            assert session.state()['step'] == 'hello'
            rect = session.wait(session.guide_rect, 'mapped guide')

            # Fresh installation: an empty Settings.wall shows the bundled
            # default behind the guide's first frame.
            first = session.capture(shots, 'welcome-hello-en.png', settle=.3)
            probe = session.probe()
            assert probe['wall'] == '' and probe['current'].endswith('/assets/wallpapers/moon-mountains.png'), probe
            assert not (session.home / 'Pictures/Wallpapers').exists(), 'the default must not be imported'
            width, height = Image.open(first).size
            # Left of the guide, below the bar and above any dock.
            strip = (8, int(height * .3), rect['x'] - 8, int(height * .7))
            assert strip[2] - strip[0] > 40, rect
            expected = {name: ImageOps.fit(Image.open(ROOT / 'assets/wallpapers' / name).convert('RGB'), (width, height),
                        method=Image.Resampling.BILINEAR) for name in ('moon-mountains.png', 'quiet-fjord.png')}
            default_diff = region_difference(first, expected['moon-mountains.png'], strip)
            other_diff = region_difference(first, expected['quiet-fjord.png'], strip)
            assert default_diff < 6 and other_diff > default_diff * 3, (default_diff, other_diff)

            session.wait(lambda: session.probe().get('paletteActive'), 'default wallpaper palette')
            assert session.probe()['paletteError'] == ''
            assert session.ipc('open', 'keys') == 'unknown'
            assert session.ipc('open', 'unknown') == 'unknown'
            for step in ('hello', 'wallpaper', 'style', 'shortcuts', 'finish'):
                assert session.ipc('open', step) == 'ok'
                session.wait(lambda: session.state().get('step') == step, step)
                if step == 'wallpaper':
                    session.wait(lambda: (p := session.probe()).get('picker') and p.get('tab') == 'online', 'Wallhaven picker')
                if step == 'shortcuts':
                    session.wait(lambda: session.probe().get('keysLoaded'), 'Keybindings loaded')
                session.capture(shots, 'welcome-' + step + '-en.png')

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

            # Enter activates the primary action with initial page focus.
            session.ipc('open', 'finish')
            session.call('welcome-test', 'focusRoot')
            session.key('-k', 'Return')
            session.wait(lambda: session.state().get('status') == 'completed', 'Finish')
            assert not session.state()['open']
            session.wait(lambda: session.probe().get('watchers') == 0, 'Keybindings claim released on close')
            session.ipc('open', '')
            assert session.state()['step'] == 'hello'

            # Selecting an online tile applies immediately, without visiting
            # the preview's Apply action. The scripted download saves a real
            # image; the real Matugen must drive the next step's palette.
            session.ipc('open', 'wallpaper')
            session.wait(lambda: session.probe().get('tab') == 'online', 'Wallhaven tab')
            probe = session.probe()
            assert not probe['showSources'] and probe['applyOnSelect'], probe
            assert probe['selected'] == '' and probe['wall'] == '', probe
            assert probe['requests'] == 0, 'unknown metering must not contact Wallhaven'
            session.call('welcome-test', 'seedWallhaven')
            keyboard = session.start(['wtype', '-s', '800', '-d', '100', '-k', 'Right', '-k', 'Return',
                                      '-s', '200'], 'keyboard.log')
            time.sleep(.25)
            session.focus()
            session.call('welcome-test', 'focusGrid')
            session.wait(lambda: session.probe().get('selected') == 'wallhaven-bbb222.png', 'keyboard selection')
            assert keyboard.wait(timeout=10) == 0, 'wtype failed'
            applied = session.wait(lambda: (p := session.probe()).get('wall') == 'wallhaven-bbb222.png' and p,
                                   'online wallpaper automatically applied')
            assert session.state()['step'] == 'wallpaper', 'Enter in the picker must not continue'
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
            # Attach the virtual keyboard first: a new one moves seat focus.
            typing = session.start(['wtype', '-s', '1000', 'sea', '-P', 'space', '-s', '1200', '-p', 'space',
                                    'side', '-s', '100'], 'typing.log')
            time.sleep(.25)
            session.focus()
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

            # Hold Space: the window fades and the actual desktop shows.
            session.ipc('close')
            session.wait(lambda: session.guide_rect() is None, 'guide unmapped')
            desktop = session.capture(base, 'desktop.png')
            session.ipc('open', 'wallpaper')
            rect = session.wait(session.guide_rect, 'guide mapped again')
            shown = session.capture(base, 'shown.png')
            box = inset(rect, 40)
            assert region_difference(shown, desktop, box) > 15, 'the window must cover the compared region'
            session.focus()
            session.call('welcome-test', 'focusGrid')  # a focused thumbnail still peeks
            # One virtual keyboard owns the entire press/release pair.
            # Disconnecting wtype between them releases every pressed key.
            # wtype: -P presses and -p releases; it rejects unknown flags
            # before sending anything, so its exit status is checked.
            peek = session.start(['wtype', '-s', '200', '-P', 'space', '-s', '2000', '-p', 'space'], 'peek.log')
            # Past Sway's 600 ms repeat delay, so repeated release/press
            # pairs have arrived and must not have ended the peek.
            time.sleep(1.2)
            assert session.probe()['peeking'], 'holding Space peeks'
            peeked = session.capture(shots, 'welcome-wallpaper-peek-en.png', settle=0)
            assert peek.wait(timeout=10) == 0, 'wtype failed'
            session.wait(lambda: not session.probe().get('peeking'), 'release ends the peek')
            assert session.state()['open'], 'Space keeps the window mapped'
            peek_diff = region_difference(peeked, desktop, box)
            assert peek_diff < 2, f'Space must reveal the actual wallpaper (difference {peek_diff:.2f})'
            back = session.capture(base, 'back.png')
            assert region_difference(back, shown, box) < 2, 'release restores the guide'

            # The picker fits the guide's minimum size. Smaller windows
            # scroll the step rather than clipping the picker.
            session.sway(f'[title="{TITLE}"] resize set 640 480')
            session.wait(lambda: (r := session.guide_rect()) and (r['width'], r['height']) == (640, 480), 'minimum size')
            session.capture(shots, 'welcome-wallpaper-minimum-en.png')
            # The short layout starts when the 520 px step area no longer fits
            # under the 28 px top margin and above the 76 px footer (all
            # scaled). With the 16 px short margin, a window height up to
            # 12 px lower than that used to flip the condition back and forth
            # through the margin it changes: a binding loop. Sweep through the
            # band, up and down, and require a settled layout and a clean log.
            assert not session.binding_loops(), session.binding_loops()
            limits = session.probe()
            threshold = limits['footer'] + limits['margins'][1] + limits['step']
            band = range(threshold - limits['margins'][1] + limits['margins'][0] - 8, threshold + 8)
            for sweep in list(band) + list(reversed(band)):
                session.sway(f'[title="{TITLE}"] resize set 1080 {sweep}')
                session.wait(lambda: (r := session.guide_rect()) and r['height'] == sweep, f'{sweep} px guide')
                session.wait(lambda: session.probe().get('shortHeight') == (sweep < threshold), f'short layout at {sweep} px')
            assert not session.binding_loops(), session.binding_loops()
            session.sway(f'[title="{TITLE}"] resize set 1080 800')

            session.key('-M', 'ctrl', '-k', 'Next', '-m', 'ctrl')
            session.wait(lambda: session.state().get('step') == 'style', 'Ctrl+PageDown')
            session.key('-M', 'ctrl', '-k', 'Prior', '-m', 'ctrl')
            assert session.state()['step'] == 'wallpaper'
            # Escape inside the picker dismisses like Escape elsewhere.
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

            # Text-size and density extremes at the minimum window size.
            for scale, density in (('larger', 'comfortable'), ('default', 'compact')):
                session.stop_process(session.shell)
                session.patch_settings(textScale=scale, interfaceDensity=density)
                session.start_shell(f'qs-{scale}.log')
                for step in ('wallpaper', 'shortcuts'):
                    session.ipc('open', step)
                    session.wait(session.guide_rect, 'guide')
                    session.sway(f'[title="{TITLE}"] resize set 640 480')
                    session.capture(shots, f'welcome-{step}-minimum-{scale}-{density}-en.png', settle=1.2)
                session.ipc('close')
            session.stop_process(session.shell)
            session.patch_settings(textScale='default', interfaceDensity='default')

            # The whole guide in English and Dutch, at the default and the
            # minimum size, cropped to the window for layout review.
            for language in ('en', 'nl'):
                session.env['CYBEXOS_LANG'] = language
                session.start_shell(f'qs-tour-{language}.log')
                for size, (width, height) in (('normal', (1080, 800)), ('minimum', (640, 480))):
                    for step in ('hello', 'wallpaper', 'style', 'shortcuts', 'finish'):
                        assert session.ipc('open', step) == 'ok'
                        session.wait(lambda: session.state().get('step') == step and session.guide_rect(), step)
                        session.sway(f'[title="{TITLE}"] resize set {width} {height}')
                        session.wait(lambda: (r := session.guide_rect()) and (r['width'], r['height']) == (width, height),
                                     f'{size} guide')
                        session.capture_guide(shots, f'tour-{language}-{size}-{step}.png')
                    # Wallhaven's colour grid opens over the picker and
                    # Escape closes only the grid. Metering is unknown here,
                    # so nothing is requested.
                    session.ipc('open', 'wallpaper')
                    session.wait(lambda: session.call('welcome-test', 'colour') == 'ok', 'colour filter')
                    session.wait(lambda: session.call('welcome-test', 'colourOpen') == 'true', 'colour grid open')
                    session.capture_guide(shots, f'tour-{language}-{size}-colours.png')
                    session.key('-k', 'Escape')
                    session.wait(lambda: session.call('welcome-test', 'colourOpen') == 'false', 'Escape closes the grid')
                    assert session.state()['open'], 'Escape in the colour grid must not dismiss the guide'
                    assert session.probe()['requests'] == 0, 'the colour grid must not contact Wallhaven'
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
            print('PASS: fresh-install default wallpaper, first login, all five steps, Keybindings keycaps '
                  '(remapped/unbound) and claim lifecycle, picker apply, Space typing in search, Space peek '
                  'versus the desktop-only frame, minimum size and text extremes, Finish, keyboard navigation, '
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
