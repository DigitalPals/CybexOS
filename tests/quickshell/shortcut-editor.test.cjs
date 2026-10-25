const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const {spawnSync} = require('node:child_process');
const {load, plain, root, luaBinary, stub} = require('./keybindings-support.cjs');
const S = load('ShortcutEditor.js');
const M = load('KeybindingsModel.js');
const row = (id, group, label, keys, extra = {}) => ({id, group, label, keys, defaultKeys: keys, editable: true,
    protected: false, hidden: false, changed: false, custom: false, source: 'default', ...extra});
const actions = [
    row('apps.terminal', 'Apps', 'Terminal', ['SUPER + Return']),
    row('apps.browser', 'Apps', 'Browser', ['SUPER + SHIFT + B'], {defaultKeys: ['SUPER + B'], changed: true, source: 'changed'}),
    row('shell.lock', 'Shell', 'Lock screen', ['SUPER + L'], {protected: true}),
    row('shell.settings', 'Shell', 'Cybex OS Settings', ['SUPER + ALT + S', 'SUPER + comma'], {protected: true, defaultKeys: ['SUPER + comma'], changed: true, source: 'changed'}),
    row('windows.move', 'Windows', 'Move window', ['SUPER + mouse:272'], {editable: false}),
    row('hardware.mute', 'Hardware keys', 'Mute', ['XF86AudioMute'], {editable: false, hidden: true}),
    row('custom.shortcut-1', 'Web', 'Docs', ['SUPER + H'], {defaultKeys: [], custom: true, changed: true, source: 'custom',
        run: {type: 'url', url: 'https://example.org'}}),
    row('webapps.slack', 'Web apps', 'Slack', ['SUPER + M']),
    row('apps.files', 'Apps', 'Files', ['SUPER + E'], {source: 'user', keys: ['SUPER + ALT + E']}),
    row('mine.thing', 'Mine', 'Thing', ['SUPER + U'], {defaultKeys: []})
];
const userBinds = [{group: 'Mine', label: 'Notes', keys: ['SUPER + N']}, {group: 'Other', label: 'Thing', keys: ['SUPER + M']}];
const ids = groups => plain(groups).flatMap(group => group.rows.map(entry => entry.id));

test('groups follow the Super+K sheet order and hide hardware keys', () => {
    const result = plain(S.groups(actions, userBinds, [], {}));
    assert.deepEqual(result.map(group => group.title), ['Shell', 'Apps', 'Web apps', 'Windows', 'Web', 'Mine']);
    assert.ok(!ids(result).includes('hardware.mute'));
    assert.ok(!ids(result).some(id => id.startsWith('user.')), 'user.lua rows belong to their own filter');
    const move = result.flatMap(group => group.rows).find(entry => entry.id === 'windows.move');
    assert.equal(move.readOnly, true, 'mouse drags are read-only');
    assert.equal(result.flatMap(group => group.rows).find(entry => entry.id === 'shell.lock').readOnly, false);
});

test('filters select changed, conflicting and user.lua rows', () => {
    assert.deepEqual(ids(S.groups(actions, userBinds, [], {filter: 'changed'})).sort(),
        ['apps.browser', 'custom.shortcut-1', 'shell.settings']);
    assert.deepEqual(ids(S.groups(actions, userBinds, [], {filter: 'user'})).sort(), ['apps.files', 'user.0', 'user.1']);
    // user.lua's Super+M collides with Slack; a Lua diagnostic adds its pair.
    const diagnostics = [{type: 'displaced', id: 'apps.terminal', keys: 'SUPER + Return', by: 'custom.shortcut-1'}];
    assert.deepEqual(ids(S.groups(actions, userBinds, diagnostics, {filter: 'conflicts'})).sort(),
        ['apps.terminal', 'custom.shortcut-1', 'user.1', 'webapps.slack']);
    assert.deepEqual(plain(S.counts(actions, userBinds, diagnostics)), {all: 9, changed: 3, conflicts: 4, user: 3});
    assert.equal(S.groups(actions, [], [], {filter: 'bogus'}).length, 6, 'unknown filters show everything');
});

test('search matches labels, groups, translations and key combinations', () => {
    const search = (query, translate) => ids(S.groups(actions, userBinds, [], {query, translate}));
    assert.deepEqual(search('brow'), ['apps.browser']);
    assert.deepEqual(search('Web apps'), ['webapps.slack']);
    assert.deepEqual(search('Bestanden', text => text === 'Files' ? 'Bestanden' : text), ['apps.files']);
    assert.deepEqual(search('super+shift+b'), ['apps.browser']);
    assert.deepEqual(search('Super Enter'), ['apps.terminal'], 'keycap names work too');
    assert.deepEqual(search('win+l'), ['shell.lock', 'windows.move'], 'a last-token prefix also reaches Left button');
    assert.deepEqual(search('super+alt+s'), ['shell.settings']);
    assert.ok(search('super + sh').includes('apps.browser'), 'the last token may be a prefix');
    assert.deepEqual(search('ctrl+q'), []);
    assert.equal(S.keysMatch(['SUPER + B'], ''), false);
    assert.equal(S.keysMatch(['SUPER + B'], 'super b'), true);
    assert.equal(S.keysMatch(['SUPER + BackSpace'], 'super b'), true, 'prefix while typing');
    assert.equal(S.keysMatch(['SUPER + BackSpace'], 'b super'), false, 'only the last token is a prefix');
});

test('recorder decisions: reserved keys keep listening, protected and user.lua block, others replace', () => {
    assert.deepEqual(plain(S.decide('B', [])), {kind: 'reserved', reason: 'modifier', blockers: [], replace: [], maybe: []});
    assert.equal(S.decide('CTRL + ALT + F2', []).reason, 'system');
    assert.equal(S.decide('CTRL + ALT + Delete', []).reason, 'system');
    assert.equal(S.decide('XF86PowerOff', []).reason, 'power');
    assert.equal(S.decide('SUPER + mouse:272', []).reason, 'mouse');
    assert.equal(S.decide('', []).reason, 'invalid');
    assert.equal(S.decide('F9', []).kind, 'free', 'unmodified function keys are allowed');
    const slack = {id: 'webapps.slack', group: 'Web apps', label: 'Slack', protected: false, source: 'default'};
    const lock = {id: 'shell.lock', group: 'Shell', label: 'Lock screen', protected: true, source: 'default'};
    const user = {id: 'user.0', group: 'Mine', label: 'Notes', protected: false, source: 'user'};
    assert.equal(S.decide('SUPER + M', [slack]).kind, 'replace');
    assert.deepEqual(plain(S.decide('SUPER + M', [slack]).replace), [slack]);
    assert.deepEqual(plain(S.decide('SUPER + L', [slack, lock])), {kind: 'blocked', reason: 'protected', blockers: [lock], replace: [slack], maybe: []});
    assert.equal(S.decide('SUPER + N', [user]).reason, 'user');
    assert.equal(S.decide('SUPER + J', []).kind, 'free');
});

test('a decision follows the model conflicts, including protected defaults after a remap', () => {
    const fixtures = JSON.parse(fs.readFileSync(path.join(root, 'tests/fixtures/keybindings/resolution.json')));
    const model = M.create();
    const masks = {SUPER: 64, CTRL: 4, ALT: 8, SHIFT: 1};
    const binds = fixtures.catalog.flatMap(action => action.keys.map(key => {
        const parts = key.split(' + ');
        return {modmask: parts.slice(0, -1).reduce((mask, mod) => mask | masks[mod], 0), key: parts.at(-1),
            description: action.group + ': ' + action.label};
    }));
    M.ingest(model, {state: {v: 1, actions: fixtures.catalog, custom: [], diagnostics: []}, preferences: {v: 1}, version: 'a', binds});
    M.setKeys(model, 'shell.lock', ['SUPER + ALT + L']);
    assert.equal(S.decide('SUPER + L', M.conflicts(model, 'SUPER + L', 'apps.first')).kind, 'blocked',
        'the resolver still reserves a remapped protected default');
    assert.equal(S.decide('SUPER + M', M.conflicts(model, 'SUPER + M', 'apps.first')).kind, 'replace');
    assert.equal(S.decide('SUPER + J', M.conflicts(model, 'SUPER + J', 'apps.first')).kind, 'free');
});

test('a hidden hardware key blocks instead of offering a Replace that cannot work', () => {
    const catalog = [
        row('apps.terminal', 'Apps', 'Terminal', ['SUPER + Return']),
        row('hardware.mute-audio', 'Hardware keys', 'Mute audio', ['XF86AudioMute'], {editable: false, hidden: true}),
        row('hardware.volume-up', 'Hardware keys', 'Volume up', ['XF86AudioRaiseVolume', 'F10'], {editable: false, hidden: true}),
        row('windows.move', 'Windows', 'Move window', ['SUPER + mouse:272'], {editable: false}),
        row('webapps.slack', 'Web apps', 'Slack', ['SUPER + M'])
    ];
    const model = M.create();
    // The live binds of the catalog above, so no row looks like a user.lua remap.
    const binds = [['Return', 'Apps: Terminal', 64], ['XF86AudioMute', 'Hardware keys: Mute audio', 0],
        ['XF86AudioRaiseVolume', 'Hardware keys: Volume up', 0], ['F10', 'Hardware keys: Volume up', 0],
        ['mouse:272', 'Windows: Move window', 64], ['M', 'Web apps: Slack', 64]]
        .map(([key, description, modmask]) => ({modmask, key, description}));
    M.ingest(model, {state: M.resolve(catalog, {v: 1}), preferences: {v: 1}, version: 'a', binds});
    const conflicts = M.conflicts(model, 'XF86AudioMute', 'apps.terminal');
    assert.deepEqual(plain(conflicts).map(entry => [entry.id, entry.editable, entry.hidden]), [['hardware.mute-audio', false, true]]);
    const verdict = plain(S.decide('XF86AudioMute', conflicts, id => M.action(model, id)));
    assert.equal(verdict.kind, 'blocked');
    assert.equal(verdict.reason, 'hardware');
    assert.deepEqual(verdict.blockers.map(entry => entry.id), ['hardware.mute-audio']);
    assert.deepEqual(verdict.replace, [], 'nothing is offered to Replace');
    // The edit really is refused, so Replace could never have worked.
    assert.throws(() => M.setKeys(model, 'hardware.mute-audio', []), /cannot be edited/);
    // Editable holders keep their flags and stay replaceable.
    const editable = plain(M.conflicts(model, 'SUPER + M', 'apps.terminal'));
    assert.deepEqual(editable.map(entry => [entry.id, entry.editable, entry.hidden]), [['webapps.slack', true, false]]);
    assert.equal(S.decide('SUPER + M', editable).kind, 'replace');
    // A hardware holder next to a replaceable one still blocks, and a user.lua holder wins the reason.
    const mixed = plain(S.decide('F10', [...plain(M.conflicts(model, 'F10', 'apps.terminal')), editable[0]]));
    assert.equal(mixed.kind, 'blocked');
    assert.deepEqual(mixed.replace.map(entry => entry.id), ['webapps.slack']);
    assert.equal(S.decide('F10', [...conflicts, {id: 'user.0', source: 'user', editable: false}]).reason, 'user');
    // A read-only holder that is not hidden has its own reason.
    assert.equal(S.decide('SUPER + P', [{id: 'windows.move', source: 'default', protected: false, editable: false, hidden: false}]).reason, 'fixed');
});

test('uncertain holders warn without blocking or being unbound', () => {
    const slack = {id: 'webapps.slack', group: 'Web apps', label: 'Slack', protected: false, source: 'default'};
    const move = {id: 'workspaces.move.1', group: 'Workspaces', label: 'Move window to workspace 1', protected: false,
        source: 'default', uncertain: true};
    const lock = {id: 'shell.lock', group: 'Shell', label: 'Lock screen', protected: true, source: 'default', uncertain: true};
    const user = {id: 'user.0', group: 'Mine', label: 'Notes', protected: false, source: 'user', uncertain: true};
    const maybe = plain(S.decide('SUPER + SHIFT + code:10', [move, lock, user]));
    assert.equal(maybe.kind, 'maybe', 'uncertain protected and user.lua holders do not block');
    assert.deepEqual(maybe.maybe.map(entry => entry.id), ['workspaces.move.1', 'shell.lock', 'user.0']);
    assert.deepEqual(maybe.replace, [], 'an uncertain holder is never unbound');
    assert.deepEqual(maybe.blockers, []);
    const mixed = plain(S.decide('SUPER + SHIFT + code:10', [slack, move]));
    assert.equal(mixed.kind, 'replace');
    assert.deepEqual(mixed.replace.map(entry => entry.id), ['webapps.slack']);
    assert.deepEqual(mixed.maybe.map(entry => entry.id), ['workspaces.move.1']);
    const certain = {...lock, uncertain: undefined};
    assert.equal(S.decide('SUPER + SHIFT + code:10', [move, certain]).kind, 'blocked', 'a certain protected holder still blocks');
    // The real model without a layout map reports uncertain holders.
    const fixtures = JSON.parse(fs.readFileSync(path.join(root, 'tests/fixtures/keybindings/resolution.json')));
    const model = M.create();
    const rows = [{id: 'workspaces.move.1', group: 'Workspaces', label: 'Move', keys: ['SUPER + SHIFT + 1'],
        defaultKeys: ['SUPER + SHIFT + 1'], editable: true, protected: false, hidden: false, custom: false}];
    M.ingest(model, {state: M.resolve(rows, {v: 1}), preferences: {v: 1}, version: 'a',
        binds: [{modmask: 65, key: '1', description: 'Workspaces: Move'}]});
    const verdict = plain(S.decide('SUPER + SHIFT + code:10', M.conflicts(model, 'SUPER + SHIFT + code:10', 'apps.x')));
    assert.equal(verdict.kind, 'maybe');
    assert.ok(fixtures.catalog.length > 0);
});

test('protected rows lock their defaults; Replace edits only the extra keys', () => {
    const lock = row('shell.lock', 'Shell', 'Lock screen', ['SUPER + T', 'SUPER + L'],
        {protected: true, defaultKeys: ['SUPER + L'], changed: true});
    assert.deepEqual(plain(S.lockedKeys(lock)), ['SUPER + L']);
    assert.deepEqual(plain(S.editableKeys(lock)), ['SUPER + T']);
    assert.deepEqual(plain(S.lockedKeys(actions[0])), [], 'ordinary rows lock nothing');
    assert.deepEqual(plain(S.editableKeys(actions[0])), ['SUPER + Return']);
    assert.deepEqual(plain(S.nextKeys(S.editableKeys(lock), 'SUPER + Y', 'replace')), ['SUPER + Y']);
    assert.deepEqual(plain(S.nextKeys(S.editableKeys(lock), 'SUPER + Y', 'add')), ['SUPER + T', 'SUPER + Y']);
    // Only a protected holder's reserved default blocks; its extra key is an
    // ordinary claim that Replace may take.
    const holder = {id: 'shell.lock', group: 'Shell', label: 'Lock screen', protected: true, source: 'changed'};
    const lookup = id => id === 'shell.lock' ? lock : null;
    assert.equal(S.decide('SUPER + L', [holder], lookup).kind, 'blocked');
    assert.equal(S.decide('SUPER + T', [holder], lookup).kind, 'replace');
    assert.equal(S.decide('SUPER + T', [holder]).kind, 'blocked', 'without a lookup, protected holders block');
});

const lua = luaBinary();
function resolveWithLua(preferences) {
    assert.ok(lua, 'Lua is required: run these tests through nix develop');
    const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'cybexos-shortcut-editor-'));
    try {
        for (const dir of ['config/cybexos', 'runtime/cybexos']) fs.mkdirSync(path.join(temporary, dir), {recursive: true});
        if (preferences) fs.writeFileSync(path.join(temporary, 'config/cybexos/keybindings.json'), JSON.stringify(preferences));
        const result = spawnSync(lua, ['-'], {encoding: 'utf8', input:
            `package.path = ${JSON.stringify(path.join(root, 'desktop/hypr/?.lua'))} .. ';' .. package.path\n`
            + 'package.preload.features = function() return {} end\n' + stub
            + "\nrequire('bindings')\nrequire('keybinding_preferences')\n",
            env: {...process.env, HOME: temporary, XDG_CONFIG_HOME: path.join(temporary, 'config'),
                XDG_RUNTIME_DIR: path.join(temporary, 'runtime')}});
        assert.equal(result.status, 0, result.stderr);
        return JSON.parse(fs.readFileSync(path.join(temporary, 'runtime/cybexos/keybindings-state.json')));
    } finally { fs.rmSync(temporary, {recursive: true, force: true}); }
}
function liveBinds(state) {
    const masks = {SUPER: 64, CTRL: 4, ALT: 8, SHIFT: 1};
    return state.actions.concat(state.custom || []).flatMap(action => action.keys.map(key => {
        const parts = key.split(' + ');
        return {modmask: parts.slice(0, -1).reduce((mask, mod) => mask | masks[mod], 0), key: parts.at(-1),
            description: action.group + ': ' + action.label};
    }));
}

test('a protected action edited the editor\'s way matches the real Lua resolver', () => {
    const model = M.create();
    let state = resolveWithLua(null);
    const ingest = preferences => M.ingest(model, {state, preferences, version: 'v', binds: liveBinds(state)});
    ingest({v: 1});
    const record = (id, combo, mode) => M.setKeys(model, id, S.nextKeys(S.editableKeys(M.action(model, id)), combo, mode));
    const commit = () => {
        const {preferences} = M.request(model);
        state = resolveWithLua(preferences);
        assert.equal(state.error, null);
        M.applied(model, {version: 'v', preferences});
        ingest(preferences);
        return preferences;
    };
    let lock = M.action(model, 'shell.lock');
    assert.deepEqual(plain(S.lockedKeys(lock)), ['SUPER + L']);
    assert.deepEqual(plain(S.editableKeys(lock)), []);

    record('shell.lock', 'SUPER + T', 'replace');
    const preview = plain(M.keysFor(model, 'shell.lock'));
    assert.deepEqual(preview, ['SUPER + T', 'SUPER + L']);
    assert.deepEqual(plain(commit().actions), {'shell.lock': {keys: ['SUPER + T']}}, 'only the extra key is stored');
    assert.deepEqual(plain(state.actions.find(entry => entry.id === "shell.lock").keys), preview, 'the draft preview is what Lua binds');

    // Replace changes only the extra key; the default stays bound.
    record('shell.lock', 'SUPER + I', 'replace');
    assert.deepEqual(plain(commit().actions), {'shell.lock': {keys: ['SUPER + I']}});
    assert.deepEqual(plain(state.actions.find(entry => entry.id === "shell.lock").keys), ['SUPER + I', 'SUPER + L']);
    record('shell.lock', 'SUPER + U', 'add');
    assert.deepEqual(plain(commit().actions), {'shell.lock': {keys: ['SUPER + I', 'SUPER + U']}});
    lock = M.action(model, 'shell.lock');
    assert.deepEqual(plain(lock.keys), ['SUPER + I', 'SUPER + U', 'SUPER + L']);
    assert.deepEqual(plain(S.lockedKeys(lock)), ['SUPER + L']);

    // The map and the row agree: only the default is locked.
    const map = plain(S.keyboardMap(M.view(model).actions, [])).flat();
    assert.equal(map.find(key => key.key === 'L').protected, true);
    assert.equal(map.find(key => key.key === 'I').protected, false);
    assert.equal(map.find(key => key.key === 'I').owner.id, 'shell.lock');

    // Another action may take the extra key; Replace leaves the default.
    const lookup = id => M.action(model, id);
    const taken = S.decide('SUPER + I', M.conflicts(model, 'SUPER + I', 'apps.browser'), lookup);
    assert.equal(taken.kind, 'replace');
    assert.equal(S.decide('SUPER + L', M.conflicts(model, 'SUPER + L', 'apps.browser'), lookup).kind, 'blocked');
    M.setKeys(model, 'shell.lock', S.withoutKey(M.keysFor(model, 'shell.lock'), 'SUPER + I'));
    record('apps.browser', 'SUPER + I', 'replace');
    assert.deepEqual(plain(commit().actions), {'shell.lock': {keys: ['SUPER + U']}, 'apps.browser': {keys: ['SUPER + I']}});
    assert.deepEqual(plain(state.actions.find(entry => entry.id === "shell.lock").keys), ['SUPER + U', 'SUPER + L']);
    assert.deepEqual(state.diagnostics, []);

    // Recording the default itself removes the override; it cannot be disabled.
    record('shell.lock', 'SUPER + L', 'replace');
    assert.equal(M.request(model).preferences.actions['shell.lock'], undefined);
    assert.throws(() => M.setKeys(model, 'shell.lock', []), /at least one/);
});

test('recorded keys replace or join the row, and replacement removes only that key', () => {
    assert.deepEqual(plain(S.nextKeys(['Print', 'SUPER + grave'], 'super + p', 'replace')), ['SUPER + P']);
    assert.deepEqual(plain(S.nextKeys(['Print'], 'SUPER + P', 'add')), ['Print', 'SUPER + P']);
    assert.deepEqual(plain(S.nextKeys(['Print', 'SUPER + P'], 'SUPER + P', 'add')), ['Print', 'SUPER + P'], 'no duplicates');
    assert.equal(S.nextKeys(['A1', 'A2', 'A3', 'A4'].map(k => 'SUPER + ' + k), 'SUPER + Z', 'add'), null);
    assert.deepEqual(plain(S.withoutKey(['SUPER + M', 'SUPER + ALT + M'], 'super + m')), ['SUPER + ALT + M']);
});

test('live caps name held modifiers and releases drop only the released one', () => {
    assert.deepEqual(plain(S.liveCaps('SUPER + SHIFT')), ['Super', 'Shift']);
    assert.deepEqual(plain(S.liveCaps('SUPER + comma')), ['Super', ',']);
    assert.deepEqual(plain(S.liveCaps('')), []);
    const meta = 0x10000000, shift = 0x02000000;
    assert.equal(S.releaseCombo({key: 0x01000020, modifiers: meta | shift}, 'SUPER + SHIFT'), 'SUPER');
    assert.equal(S.releaseCombo({key: 0x01000022, modifiers: meta}, 'SUPER'), '');
    assert.equal(S.releaseCombo({key: 0x01000053, modifiers: meta | shift}, 'SUPER + SHIFT'), 'SHIFT');
    assert.equal(S.releaseCombo({key: 66, modifiers: meta}, 'SUPER'), 'SUPER', 'a released letter keeps the held modifiers');
});

test('recorder commands: Escape cancels, bare Backspace/Delete clear, Return accepts a finished combo', () => {
    const meta = 0x10000000;
    assert.equal(S.recorderCommand({key: 0x01000000, modifiers: 0}, false), 'cancel');
    assert.equal(S.recorderCommand({key: 0x01000000, modifiers: meta}, false), 'record', 'Super+Escape can be recorded');
    assert.equal(S.recorderCommand({key: 0x01000003, modifiers: 0}, true), 'clear');
    assert.equal(S.recorderCommand({key: 0x01000007, modifiers: 0x20000000}, true), 'clear', 'keypad flag is not a modifier');
    assert.equal(S.recorderCommand({key: 0x01000003, modifiers: meta}, true), 'record');
    assert.equal(S.recorderCommand({key: 0x01000004, modifiers: 0}, true), 'accept');
    assert.equal(S.recorderCommand({key: 0x01000004, modifiers: 0}, false), 'record');
    assert.equal(S.recorderCommand({key: 66, modifiers: meta}, false), 'record');
});

test('keyboard map lays out Super+digit and letter rows with owners, protection and free keys', () => {
    const map = plain(S.keyboardMap(actions, userBinds));
    assert.deepEqual(map.map(line => line.map(key => key.key).join('')), ['1234567890', 'QWERTYUIOP', 'ASDFGHJKL', 'ZXCVBNM']);
    const key = letter => map.flat().find(entry => entry.key === letter);
    assert.equal(key('L').protected, true);
    assert.equal(key('L').owner.id, 'shell.lock');
    assert.equal(key('L').free, false);
    // Settings gained Super+Alt+S beside its locked Super+Comma, neither in the map;
    // Super+H is a custom shortcut and Super+M is shared with user.lua.
    assert.equal(key('H').owner.source, 'custom');
    assert.equal(key('M').shared, true);
    assert.deepEqual(key('M').owners.map(owner => owner.id), ['webapps.slack', 'user.1']);
    assert.equal(key('N').owner.editable, false, 'user.lua keys are read-only');
    assert.equal(key('B').free, true, 'the browser moved away from Super+B');
    assert.equal(key('E').free, true);
    assert.equal(key('Z').free, true);
    assert.equal(key('1').combo, 'SUPER + 1');
    // A protected default stays locked beside its extra keys, which are not.
    const remapped = plain(S.keyboardMap([row('shell.lock', 'Shell', 'Lock screen', ['SUPER + T', 'SUPER + L'],
        {protected: true, defaultKeys: ['SUPER + L'], changed: true, source: 'changed'})], []));
    const lock = remapped.flat().find(entry => entry.key === 'L');
    assert.equal(lock.free, false);
    assert.equal(lock.protected, true);
    assert.equal(lock.owner.id, 'shell.lock');
    assert.equal(lock.reservedBy, null, 'its own action holds it');
    const extra = remapped.flat().find(entry => entry.key === 'T');
    assert.equal(extra.owner.id, 'shell.lock');
    assert.equal(extra.protected, false, 'an extra key of a protected action can move');
    // Should user.lua unbind the default, the key is still reserved for it.
    const unbound = plain(S.keyboardMap([row('shell.lock', 'Shell', 'Lock screen', ['SUPER + T'],
        {protected: true, defaultKeys: ['SUPER + L'], source: 'user'})], []));
    assert.equal(unbound.flat().find(entry => entry.key === 'L').reservedBy.id, 'shell.lock');
});

test('map labels shorten workspace switches only', () => {
    assert.equal(S.workspaceNumber('Switch to workspace 10'), 10);
    assert.equal(S.workspaceNumber('Move window to workspace 3'), 0);
    assert.equal(S.workspaceNumber(undefined), 0);
});

test('keyboard map focus moves clamp to the staggered rows', () => {
    const map = S.keyboardMap([], []);
    assert.deepEqual(plain(S.mapMove(map, 0, 9, 'down')), {row: 1, column: 9});
    assert.deepEqual(plain(S.mapMove(map, 1, 9, 'down')), {row: 2, column: 8});
    assert.deepEqual(plain(S.mapMove(map, 3, 0, 'down')), {row: 3, column: 0});
    assert.deepEqual(plain(S.mapMove(map, 0, 0, 'left')), {row: 0, column: 0});
    assert.deepEqual(plain(S.mapMove(map, 2, 3, 'end')), {row: 2, column: 8});
    assert.deepEqual(plain(S.mapMove(map, 2, 3, 'home')), {row: 2, column: 0});
    assert.deepEqual(plain(S.mapMove(map, 2, 3, 'up')), {row: 1, column: 3});
});

test('run targets follow the backend limits and the model accepts them', () => {
    assert.deepEqual(plain(S.runTarget('app', 'org.gimp.GIMP')), {run: {type: 'app', desktopId: 'org.gimp.GIMP.desktop'}});
    assert.deepEqual(plain(S.runTarget('app', 'kitty.desktop')), {run: {type: 'app', desktopId: 'kitty.desktop'}});
    assert.equal(S.runTarget('app', '../evil').error, 'app');
    assert.deepEqual(plain(S.runTarget('url', 'example.org/docs')), {run: {type: 'url', url: 'https://example.org/docs'}});
    assert.deepEqual(plain(S.runTarget('url', 'HTTPS://example.org')), {run: {type: 'url', url: 'https://example.org'}});
    assert.equal(S.runTarget('url', 'ftp://example.org').error, 'url');
    assert.equal(S.runTarget('url', 'https://' + 'a'.repeat(2048)).error, 'url');
    assert.deepEqual(plain(S.runTarget('webapp', 'google-photos')), {run: {type: 'webapp', id: 'google-photos'}});
    assert.equal(S.runTarget('webapp', 'Google Photos').error, 'webapp');
    assert.deepEqual(plain(S.runTarget('command', ' kitty -e nvim ')), {run: {type: 'command', command: 'kitty -e nvim'}});
    assert.equal(S.runTarget('command', 'é'.repeat(257)).error, 'command', 'commands count UTF-8 bytes');
    assert.equal(S.runTarget('command', 'a\nb').error, 'control');
    assert.equal(S.runTarget('other', 'x').error, 'type');
    for (const [type, value] of [['app', 'gimp'], ['url', 'example.org'], ['webapp', 'slack'], ['command', 'true']]) {
        assert.equal(S.runValue(S.runTarget(type, value).run), type === 'url' ? 'https://example.org' : value);
        const model = M.create();
        M.ingest(model, {state: {v: 1, actions: [], custom: [], diagnostics: []}, preferences: {v: 1}, version: 'a', binds: []});
        assert.match(M.addCustom(model, {group: S.DEFAULT_GROUPS[type], label: 'Mine', keys: ['SUPER + H'],
            run: S.runTarget(type, value).run}), /^custom\.shortcut-1$/);
    }
    assert.equal(S.labelError('Apps', ''), 'label');
    assert.equal(S.labelError('A: B', 'x'), 'group');
    assert.equal(S.labelError('Apps', 'x'.repeat(65)), 'length');
    assert.equal(S.labelError('Apps', 'GIMP'), '');
});

test('app and web app pickers offer only launchable IDs; sheet marks name changed and user rows', () => {
    const entries = [{id: 'org.gimp.GIMP', name: 'GIMP'}, {id: 'kitty', name: 'kitty', genericName: 'Terminal'},
        {id: 'hidden', name: 'Hidden', noDisplay: true}, {id: 'bad id', name: 'Bad'}, {id: 'gnome-calculator', name: 'Calculator'}];
    assert.deepEqual(plain(S.appChoices(entries, '')).map(entry => entry.desktopId),
        ['gnome-calculator.desktop', 'org.gimp.GIMP.desktop', 'kitty.desktop']);
    assert.deepEqual(plain(S.appChoices(entries, 'term')).map(entry => entry.name), ['kitty']);
    assert.equal(S.appChoices(entries, '', 1).length, 1);
    assert.deepEqual(plain(S.webappChoices([{id: 'slack', name: 'Slack'}, {id: 'gmail', name: 'Gmail'}, {id: 'Bad!', name: 'x'}]))
        .map(entry => entry.id), ['slack', 'whatsapp', 'youtube', 'google-photos', 'x', 'gmail']);
    const marks = plain(S.sheetMarks(actions, userBinds));
    assert.equal(marks['Apps: Browser'], 'changed');
    assert.equal(marks['Web: Docs'], 'changed');
    assert.equal(marks['Apps: Files'], 'user');
    assert.equal(marks['Mine: Notes'], 'user');
    assert.equal(marks['Apps: Terminal'], undefined);
});

test('the editor UI is wired to the shared contract', () => {
    const shell = path.join(root, 'desktop/quickshell');
    const read = name => fs.readFileSync(path.join(shell, name), 'utf8');
    const page = read('Settings/ShortcutsPage.qml');
    const recorder = read('Settings/ShortcutRecorder.qml');
    const map = read('Settings/ShortcutKeyboardMap.qml');
    assert.match(page, /Claim \{[\s\S]*?active: page\.visible[\s\S]*?Keybindings\.acquire\(\)[\s\S]*?Keybindings\.release\(\)/);
    assert.match(page, /ApplyBar \{[\s\S]*?pending: Keybindings\.dirty/);
    assert.match(page, /onFailed/);
    assert.match(recorder, /ShortcutInhibitor \{[\s\S]*?window: root\.QsWindow\.window/);
    assert.match(recorder, /onListeningChanged: inhibitor\.enabled = listening/);
    assert.match(recorder, /Component\.onDestruction: \{[\s\S]*?inhibitor\.enabled = false/);
    assert.match(recorder, /Editor\.fromKeyEvent\([\s\S]*?, Keybindings\.keymap\)/, 'the layout keymap names Shift combinations');
    assert.match(recorder, /Helpers\.decide\([^\n]*Keybindings\.action\(id\)\)/);
    assert.match(recorder, /verdict\.kind === "maybe" \? I18n\.tr\("Use anyway"\)/);
    assert.match(page, /readOnly[\s\S]*?Keybindings\.preferencesError/);
    assert.match(page, /function handleEscape\(\): bool \{[\s\S]*?form\.opened[\s\S]*?form\.close\(\)/);
    assert.match(read('Settings/SettingsView.qml'), /pageLoader\.item as ShortcutsPage;[\s\S]*?shortcuts\.handleEscape\(\)/);
    assert.match(recorder, /Keybindings\.conflicts\(/);
    assert.match(recorder, /shown = false;\s*restoreFocus\(\);/, 'closing the card returns focus to its opener');
    assert.match(read('Welcome/ShortcutsStep.qml'), /fallbackFocus: root/);
    assert.match(recorder, /Keybindings\.setManyKeys\(changes\)/, 'Replace unbinds every holder in one edit');
    assert.doesNotMatch(recorder, /for \(const other of verdict\.replace\)/);
    assert.match(read('Common/Keybindings.qml'), /function setManyKeys\(changes\) \{ return edit\(\(\) => Model\.setManyKeys\(root\.model, changes\)\); \}/);
    assert.match(recorder, /onActiveChanged[\s\S]*?Window\.window\.active[\s\S]*?root\.listening = false/, 'focus loss ends recording');
    assert.match(recorder, /Component\.onDestruction/);
    assert.match(map, /signal editRequested/);
    assert.match(map, /signal addRequested/);
    const settings = read('Common/Settings.qml');
    assert.match(settings, /\{ id: "keyboard"[\s\S]*?\},\s*\{ id: "shortcuts", group: "Devices"/);
    assert.match(read('Settings/SettingsView.qml'), /case "shortcuts": return shortcutsPage;/);
    assert.match(read('Settings/qmldir'), /^ShortcutKeyboardMap ShortcutKeyboardMap\.qml$/m);
    assert.match(read('ShortcutsOverlay.qml'), /Settings\.showPanel\("shortcuts"\)/);
    const step = read('Welcome/ShortcutsStep.qml');
    assert.doesNotMatch(step, /INTEGRATION: stream B|Welcome\.keysFor/);
    assert.match(step, /ShortcutKeyboardMap \{/);
    assert.match(step, /Keybindings\.keysFor\(/);
    assert.match(step, /Keybindings\.preferencesError/);
    assert.match(step, /Keybindings\.resetAll\(\)/);
    for (const host of [page, step])
        assert.match(host, /Helpers\.nextKeys\(Helpers\.editableKeys\(/, 'protected defaults stay locked when recording');
});

test('numbered action labels translate through their stem, everywhere the editor names an action', () => {
    const I18nHelpers = load('I18nHelpers.js');
    const nl = require(path.join(root, 'desktop/quickshell/Common/i18n/nl.js')).MESSAGES;
    const singleton = fs.readFileSync(path.join(root, 'desktop/quickshell/Common/I18n.qml'), 'utf8');
    const body = singleton.match(/function actionLabel\(label: string\): string \{([\s\S]*?)\n    \}/)[1];
    const actionLabel = (catalog, label) => new Function('label', 'I18nHelpers', 'root', body)(label, I18nHelpers, {
        catalog, tr: text => I18nHelpers.translate(catalog, text), format: (text, args) => I18nHelpers.format(catalog, text, args)});
    assert.equal(actionLabel(nl, 'Switch to workspace 10'), 'Naar werkblad 10 gaan');
    assert.equal(actionLabel(nl, 'Move window to workspace 3'), 'Venster naar werkblad 3 verplaatsen');
    assert.equal(actionLabel(nl, 'Launcher'), I18nHelpers.translate(nl, 'Launcher'));
    assert.equal(actionLabel(nl, 'Notes 2'), 'Notes 2', 'a custom label without a stem entry stays as typed');
    assert.equal(actionLabel({}, 'Switch to workspace 10'), 'Switch to workspace 10');
    const shell = path.join(root, 'desktop/quickshell');
    for (const name of ['Settings/ShortcutRow.qml', 'Settings/ShortcutKeyboardMap.qml', 'Settings/ShortcutRecorder.qml',
        'ShortcutsOverlay.qml', 'Welcome/ShortcutsStep.qml'])
        assert.doesNotMatch(fs.readFileSync(path.join(shell, name), 'utf8'), /I18n\.tr\([\w.]*\.label\)/, name);
});
