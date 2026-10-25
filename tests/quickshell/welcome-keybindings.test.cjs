const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const {spawnSync} = require('node:child_process');
const {root, luaBinary, stub, load, plain} = require('./keybindings-support.cjs');
const shellDir = path.join(root, 'desktop/quickshell');
const read = name => fs.readFileSync(path.join(shellDir, name), 'utf8');
const W = load('WelcomeHelpers.js');
const E = load('KeybindEditor.js');

// The real catalog, resolved by the vendor Lua with every feature gate off:
// the guide must not depend on an optional feature's actions.
function catalog() {
    const lua = luaBinary();
    assert.ok(lua, 'Lua is required: run these tests through nix develop');
    const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'cybexos-welcome-keys-'));
    try {
        for (const dir of ['config/cybexos', 'runtime/cybexos', 'data', 'state'])
            fs.mkdirSync(path.join(temporary, dir), {recursive: true});
        const result = spawnSync(lua, ['-'], {encoding: 'utf8', input:
            `package.path = ${JSON.stringify(path.join(root, 'desktop/hypr/?.lua'))} .. ';' .. package.path\n`
            + 'package.preload.features = function() return {} end\n' + stub
            + "require('bindings'); require('keybinding_preferences')\n",
            env: {...process.env, HOME: temporary, XDG_CONFIG_HOME: path.join(temporary, 'config'),
                XDG_DATA_HOME: path.join(temporary, 'data'), XDG_STATE_HOME: path.join(temporary, 'state'),
                XDG_RUNTIME_DIR: path.join(temporary, 'runtime')}});
        assert.equal(result.status, 0, result.stderr);
        return JSON.parse(fs.readFileSync(path.join(temporary, 'runtime/cybexos/keybindings-state.json')));
    } finally { fs.rmSync(temporary, {recursive: true, force: true}); }
}

// Every quoted action ID in the guide's sources, plus each workspace pair
// the practice step can show.
function guideIds() {
    const sources = fs.readdirSync(path.join(shellDir, 'Welcome')).map(name => read('Welcome/' + name))
        .concat([read('Common/Welcome.qml'), read('Common/WelcomeHelpers.js'), read('WelcomeWindow.qml')]);
    const ids = new Set();
    for (const source of sources)
        for (const match of source.matchAll(/"((?:shell|apps|windows|workspaces|webapps|clipboard|capture)\.[a-z0-9.-]+[a-z0-9])"/g))
            ids.add(match[1]);
    for (const start of [null, 1, 2, 3, 10, 11, -1, 'special'])
        W.workspaceActions(start).forEach(id => ids.add(id));
    return [...ids].sort();
}

test('every action ID the welcome guide uses exists in the ungated vendor catalog', () => {
    const state = catalog();
    const ids = guideIds();
    for (const id of ['shell.launcher', 'apps.terminal', 'windows.close', 'windows.overview', 'shell.shortcuts',
        'workspaces.switch.1', 'workspaces.switch.2', 'workspaces.switch.3', 'workspaces.switch.10'])
        assert.ok(ids.includes(id), 'scan found ' + id);
    for (const id of ids) {
        const row = state.actions.find(action => action.id === id);
        assert.ok(row, id + ' is missing from bindings.lua');
        assert.equal(row.hidden, false, id);
        assert.ok(row.keys.length > 0, id + ' has a default key');
    }
});

test('workspace practice keycaps follow the observed start and return to it', () => {
    assert.deepEqual(plain(W.workspaceActions(null)), ['workspaces.switch.2', 'workspaces.switch.1']);
    assert.deepEqual(plain(W.workspaceActions(1)), ['workspaces.switch.2', 'workspaces.switch.1']);
    assert.deepEqual(plain(W.workspaceActions(2)), ['workspaces.switch.1', 'workspaces.switch.2']);
    assert.deepEqual(plain(W.workspaceActions(7)), ['workspaces.switch.2', 'workspaces.switch.7']);
    assert.deepEqual(plain(W.workspaceActions(11)), ['workspaces.switch.2'], 'no numbered return key exists');
    assert.deepEqual(plain(W.workspaceActions(-98)), ['workspaces.switch.2'], 'special workspaces have no number key');
    // Following the returned keys in order is exactly what reduce() ticks.
    for (const start of [1, 2, 7]) {
        let result = {practice: {}, tracker: W.sequence(start, [])};
        for (const id of W.workspaceActions(start).map(action => Number(action.split('.').pop())))
            result = W.reduce(result.practice, result.tracker, {type: 'workspace', id});
        assert.equal(result.practice.workspace, true, String(start));
    }
});

test('Welcome.keysFor renders Keybindings effective keys as keycaps, with no hyprctl reads of its own', () => {
    const qml = read('Common/Welcome.qml');
    assert.doesNotMatch(qml, /liveBinds|hyprctl", "binds"|INTEGRATION/);
    const match = qml.match(/^    function keysFor\([^]*?^    }/m);
    assert.ok(match, 'keysFor');
    const keys = {'shell.launcher': ['SUPER + ALT + SPACE', 'SUPER + code:65'], 'windows.close': []};
    const context = vm.createContext({KeybindEditor: E, Keybindings: {keysFor: id => (keys[id] || []).slice()}});
    vm.runInContext(match[0], context);
    assert.deepEqual(plain(context.keysFor('shell.launcher')), [['Super', 'Alt', 'Space'], plain(E.display('SUPER + code:65'))]);
    assert.deepEqual(plain(context.keysFor('windows.close')), []);
    assert.deepEqual(plain(context.keysFor('unknown.action')), []);
});

test('the guide holds a Keybindings claim only while its window is shown', () => {
    const window = read('WelcomeWindow.qml');
    assert.match(window, /Claim \{\s*active: window\.visible\s*onClaimed: Keybindings\.acquire\(\)\s*onReleased: Keybindings\.release\(\)\s*\}/);
    assert.doesNotMatch(read('Common/Welcome.qml'), /Keybindings\.(acquire|refresh)\(/,
        'the singleton itself never starts the backend');
    const keys = read('Welcome/KeysStep.qml');
    assert.match(keys, /Welcome\.keysFor\(action\.modelData\)/);
    assert.match(keys, /Keybindings\.loaded \? I18n\.tr\("Not bound"\)/);
});

test('the wallpaper step embeds the shared picker and keeps Space typing in text fields', () => {
    const step = read('Welcome/WallpaperStep.qml');
    assert.match(step, /SettingsUi\.WallpaperPicker \{[^}]*embedded: true[^}]*automaticOnlineLoad: true[^}]*onEscapeRequested: Welcome\.dismiss\(\)/);
    assert.doesNotMatch(step, /WallpaperPage|INTEGRATION/);
    const view = read('Welcome/WelcomeView.qml');
    assert.match(view, /enabled: Welcome\.open && Welcome\.step === "wallpaper" && !root\.typing/);
    assert.match(view, /typing: focusedItem instanceof TextInput \|\| focusedItem instanceof TextEdit/);
    assert.match(view, /event\.key === Qt\.Key_Space && !event\.isAutoRepeat/, 'repeat releases must not end a peek');
});
