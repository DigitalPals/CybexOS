const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const {load, shellDir} = require('./shell.cjs');
const W = load('WelcomeHelpers.js');
test('state validates, round trips, and protects malformed or future documents', () => {
    const state = W.visit(W.initial('1.0.0-beta.3'), 'keys');
    state.practice.launcher = true;
    state.checklist.backup = 'later';
    assert.deepEqual(W.parse(W.serialize(state)).value, state);
    for (const raw of ['', 'null', '[]', '{}', '{', ' '.repeat(65537)])
        assert.equal(W.parse(raw).error, 'invalid');
    for (const patch of [{v: 2}, {step: 'missing'}, {status: 'finished'}, {seen: ['hello', 'hello']},
        {seen: ['unknown']}, {practice: {terminal: 'yes'}}, {practice: {unknown: true}},
        {checklist: {backup: 'done'}}, {notified: 1}, {future: true}]) {
        const value = Object.assign({}, state, patch);
        assert.equal(W.validate(value), false, JSON.stringify(patch));
        assert.throws(() => W.serialize(value));
    }
});
test('dismissal resumes progress, completion starts at hello, explicit steps take precedence', () => {
    const saved = {...W.visit(W.initial(), 'wallpaper'), status: 'dismissed'};
    assert.equal(W.resume(saved, '').step, 'wallpaper');
    assert.equal(W.resume({...saved, status: 'completed'}, '').step, 'hello');
    assert.equal(W.resume({...saved, status: 'completed'}, 'keys').step, 'keys');
    assert.equal(W.resume(saved, 'bad'), null);
    assert.equal(saved.status, 'dismissed', 'reducers never mutate saved state');
    assert.deepEqual(W.STEPS, ['hello', 'wallpaper', 'style', 'keys', 'shortcuts', 'finish']);
});
test('window practice requires a newly observed window to disappear, never a baseline window', () => {
    let tracker = W.sequence(1, ['existing']);
    let done = {};
    const event = ids => { const result = W.reduce(done, tracker, {type: 'windows', ids}); done = result.practice; tracker = result.tracker; };
    event([]); assert.equal(done.terminal, undefined);
    event(['new']); assert.equal(done.terminal, undefined);
    event(['new', 'another']); assert.equal(done.terminal, undefined);
    event(['another']); assert.equal(done.terminal, true);
    const reset = W.reduce({}, W.sequence(null, ['new']), {type: 'windows', ids: []});
    assert.equal(reset.practice.terminal, undefined, 're-entry resets transient baseline');
});
test('workspace practice requires leaving and returning to its starting workspace', () => {
    let result = {practice: {}, tracker: W.sequence(4, [])};
    const event = id => { result = W.reduce(result.practice, result.tracker, {type: 'workspace', id}); };
    event(4); assert.equal(result.practice.workspace, undefined);
    event(null); assert.equal(result.tracker.away, false);
    event(2); assert.equal(result.practice.workspace, undefined);
    event(3); assert.equal(result.practice.workspace, undefined);
    event(4); assert.equal(result.practice.workspace, true);
    assert.equal(W.reduce({}, W.sequence(null, []), {type: 'workspace', id: 1}).practice.workspace, undefined);
});
test('opening observations finish overlay tasks; clicks and closed overlays never do', () => {
    for (const type of ['launcher', 'overview', 'shortcuts']) {
        assert.deepEqual(W.reduce({}, W.sequence(1, []), {type, open: false}).practice, {});
        assert.deepEqual(W.reduce({}, W.sequence(1, []), {type, clicked: true}).practice, {});
        assert.deepEqual(W.reduce({}, W.sequence(1, []), {type, open: true}).practice, {[type]: true});
    }
});
test('checklist derives actual readiness independently of Later or opening Settings', () => {
    const facts = {assistantAvailable: true, assistant: false, reader: false, backupKnown: false, accountsKnown: false};
    let rows = W.checklist(facts, {assistant: 'later'});
    assert.equal(rows.find(row => row.id === 'assistant').done, false);
    assert.equal(rows.find(row => row.id === 'assistant').later, true);
    assert.equal(rows.some(row => row.id === 'fingerprint'), false);
    assert.equal(rows.find(row => row.id === 'webapps').done, null);
    assert.equal(rows.find(row => row.id === 'backup').done, null);
    rows = W.checklist({...facts, assistant: true, reader: true, fingerprint: true, backupKnown: true, backup: true,
        accountsKnown: true, accounts: true}, {});
    assert.ok(rows.filter(row => !['webapps', 'security'].includes(row.id)).every(row => row.done));
});
test('passwd name uses the first GECOS word, with a username fallback', () => {
    assert.equal(W.firstName('john:x:1000:1000:John Doe,Room,Phone:/home/john:/bin/bash', 'john'), 'John');
    assert.equal(W.firstName('john:x:1000:1000::/home/john:/bin/bash', 'john'), 'john');
    assert.equal(W.firstName('', 'cybexqa'), 'cybexqa');
});
test('guide wiring stays out of safe mode and exposes its stable IPC and launcher routes', () => {
    const read = name => fs.readFileSync(path.join(shellDir, name), 'utf8');
    assert.doesNotMatch(read('safe-mode/shell.qml'), /Welcome|welcome/);
    assert.match(read('shell.qml'), /WelcomeWindow \{\}/);
    assert.match(read('shell.qml'), /target: "welcome"/);
    assert.match(read('shell.qml'), /onFrameSwapped/);
    assert.ok(load('LauncherProviders.js').BUILTIN_ACTIONS.find(action => action.id === 'welcome').command.includes('welcome'));
    const window = read('WelcomeWindow.qml');
    assert.match(window, /hl\.dsp\.window\.pin/);
    assert.match(window, /window\.pinned !== Welcome\.practicing/);
});
test('FileView writes coalesce changes, protect unreadable data and retry identical failures', () => {
    const qml = fs.readFileSync(path.join(shellDir, 'Common/Welcome.qml'), 'utf8');
    const context = vm.createContext({Helpers: W, loaded: true, protectedFile: false, writeInFlight: false,
        resetPending: false, directoryReady: true, document: W.initial(), persistedText: '', storeText: '',
        writeSnapshot: '', makeDirectory: {}, FileViewError: {FileNotFound: 2}, error: '',
        I18n: {tr: value => value}, saveTimer: {restart() {}}, resetRequest: {}, console});
    let pending;
    const writes = [];
    context.store = {setText(text) { if (text === context.storeText) return; writes.push(text); pending = text; }};
    for (const name of ['saveNow', 'settled', 'loadFailed']) {
        const match = qml.match(new RegExp('^    function ' + name + '\\([^]*?^    }', 'm'));
        assert.ok(match, name); vm.runInContext(match[0], context);
    }
    context.root = context; context.maybeOpen = () => {};
    context.saveNow(); assert.equal(writes.length, 1);
    context.document = W.visit(context.document, 'keys'); context.saveNow();
    assert.equal(writes.length, 1, 'one in-flight write at a time');
    context.settled(true); context.saveNow(); assert.equal(W.parse(pending).value.step, 'keys');
    context.settled(false); context.saveNow();
    assert.equal(writes.length, 3); assert.ok(writes[2].endsWith('\n\n'), 'same bytes are retried with a newline');
    context.settled(true); context.loadFailed(3); context.document = W.visit(context.document, 'finish'); context.saveNow();
    assert.equal(writes.length, 3, 'unreadable data closes every write path');
});
