const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {spawnSync} = require('node:child_process');
const {root, luaBinary, stub} = require('./keybindings-support.cjs');
const shellDir = path.join(root, 'desktop/quickshell');
const read = name => fs.readFileSync(path.join(shellDir, name), 'utf8');

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

// Every quoted action ID in the guide's sources.
function guideIds() {
    const sources = fs.readdirSync(path.join(shellDir, 'Welcome')).map(name => read('Welcome/' + name))
        .concat([read('Common/Welcome.qml'), read('Common/WelcomeHelpers.js'), read('WelcomeWindow.qml')]);
    const ids = new Set();
    for (const source of sources)
        for (const match of source.matchAll(/"((?:shell|apps|windows|workspaces|webapps|clipboard|capture)\.[a-z0-9.-]+[a-z0-9])"/g))
            ids.add(match[1]);
    return [...ids].sort();
}

test('every action ID the welcome guide uses exists in the ungated vendor catalog', () => {
    const state = catalog();
    const ids = guideIds();
    for (const id of ['shell.launcher', 'apps.terminal', 'windows.close', 'windows.overview', 'shell.shortcuts'])
        assert.ok(ids.includes(id), 'scan found ' + id);
    for (const id of ids) {
        const row = state.actions.find(action => action.id === id);
        assert.ok(row, id + ' is missing from bindings.lua');
        assert.equal(row.hidden, false, id);
        assert.ok(row.keys.length > 0, id + ' has a default key');
    }
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
