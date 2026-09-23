const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { shellDir, load } = require('./shell.cjs');
const H = load('SettingsHelpers.js');

function settingsHarness() {
    const source = fs.readFileSync(path.join(shellDir, 'Common/Settings.qml'), 'utf8');
    const context = vm.createContext({
        ...H.defaults(), defaults: H.defaults(), SettingsHelpers: H,
        resetSnapshot: null, resetLabel: '', migrationPending: false,
        resetTimer: { restart() {}, stop() {} },
        sectionKeys: { drawer: ['drawerTabs', 'drawerOverview', 'drawerHover', 'drawerWidth'] }
    });
    context.root = context;
    for (const name of ['resetKeys', 'resetModule', 'moduleDirty', 'undoReset', 'modulePresetIds']) {
        const body = source.match(new RegExp('^    function ' + name + '\\([^]*?^    }', 'm'));
        assert.ok(body, name);
        vm.runInContext(body[0], context);
    }
    return context;
}

test('every widget preset keeps the Control Center entry available on the bar', () => {
    const s = settingsHarness();
    for (const preset of ['focused', 'connected', 'everything'])
        assert.ok(s.modulePresetIds(preset).includes('control'));
});

test('Control Center widget reset and Undo preserve layout and other widget settings', () => {
    const s = settingsHarness();
    assert.equal(s.moduleDirty('control'), false);
    s.drawerWidth = 480;
    s.drawerHover = 'always';
    s.drawerOverview.media = false;
    s.drawerTabs.reverse();
    s.modOpts.usage.warnAt = 35;
    const before = JSON.stringify({ mods: s.mods, modOpts: s.modOpts });
    const drawer = JSON.stringify(s.sectionKeys.drawer.map(key => s[key]));
    assert.equal(s.moduleDirty('control'), true);
    s.resetModule('control', 'Control Center');
    assert.equal(s.moduleDirty('control'), false);
    assert.equal(JSON.stringify({ mods: s.mods, modOpts: s.modOpts }), before);
    s.undoReset();
    assert.equal(JSON.stringify(s.sectionKeys.drawer.map(key => s[key])), drawer);
    assert.equal(JSON.stringify({ mods: s.mods, modOpts: s.modOpts }), before);
});

test('Model usage reset adopts Provider CLIs and Undo restores source and polling', () => {
    const s = settingsHarness();
    s.modOpts.usage.source = 'cliproxy';
    s.modOpts.usage.cliproxyUrl = 'https://proxy.test';
    s.pollMax = 900;
    const before = JSON.stringify({ options: s.modOpts.usage, pollMax: s.pollMax });
    s.resetModule('usage', 'Model usage');
    assert.equal(s.modOpts.usage.source, 'direct');
    assert.equal(s.pollMax, s.defaults.pollMax);
    assert.equal(s.moduleDirty('usage'), false);
    s.undoReset();
    assert.equal(JSON.stringify({ options: s.modOpts.usage, pollMax: s.pollMax }), before);
});
