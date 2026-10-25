const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {load, plain, root} = require('./keybindings-support.cjs');
const M = load('KeybindingsModel.js');
const fixtures = JSON.parse(fs.readFileSync(path.join(root,'tests/fixtures/keybindings/resolution.json')));
const catalog = fixtures.catalog;
const bind = (key,description, modmask=64,extra={}) => ({key,description,modmask,...extra});
const binds = [bind('B','Apps: apps.first'),bind('M','Apps: apps.second'),bind('L','Shell: shell.lock'),bind('comma','Shell: shell.settings'),bind('XF86AudioMute','Apps: hardware.mute',0)];
function model(preferences={v:1}) {
    const out = M.create();
    M.ingest(out, {state:M.resolve(catalog,preferences),preferences,version:'first',binds});
    return out;
}
test('draft resolution runs every shared Lua/JS vector', () => {
    for (const vector of fixtures.cases) {
        const result = plain(M.resolve(catalog,vector.preferences));
        assert.deepEqual(result.actions.map(row => row.keys),vector.keys,vector.name);
        assert.deepEqual(result.custom.map(row => row.keys),vector.custom,vector.name);
        assert.deepEqual(result.diagnostics,vector.diagnostics,vector.name);
    }
});
test('saved state is authoritative; user.lua removes/remaps keys and adds read-only rows', () => {
    const data = model();
    data.state.actions[0].keys = ['SUPER + T'];
    data.binds = [bind('T','Apps: apps.first'), bind('N','Apps: apps.second'), bind('P','Personal: Notes'), ...binds.slice(2)];
    assert.deepEqual(plain(M.keysFor(data,'apps.first')),['SUPER + T']);
    assert.equal(M.action(data,'apps.first').source,'default');
    assert.equal(M.action(data,'apps.second').source,'user');
    assert.deepEqual(plain(M.keysFor(data,'apps.second')),['SUPER + N']);
    assert.deepEqual(plain(M.view(data).userBinds),[{keys:['SUPER + P'],group:'Personal',label:'Notes'}]);
    assert.equal(M.action(data,'no-such-action'),null);
    assert.deepEqual(plain(M.keysFor(data,'no-such-action')),[]);
});
test('shared descriptions never copy one action\'s keys into another', () => {
    const state = {actions:[{...catalog[0],label:'Adjust zoom'},{...catalog[1],label:'Adjust zoom'}],custom:[],diagnostics:[]};
    const result = M.merge(state,[bind('B','Apps: Adjust zoom')]);
    assert.deepEqual(plain(result.actions.map(row=>row.keys)),[['SUPER + B'],[]]);
    assert.equal(result.actions[1].source,'user');
});
test('user.lua additions and revived disabled actions remain visible', () => {
    const data = model({v:1,actions:{'apps.first':{keys:[]}}});
    data.binds = [bind('T','Apps: apps.first'), ...binds.slice(1)];
    assert.equal(M.action(data,'apps.first').source,'user');
    assert.deepEqual(plain(M.keysFor(data,'apps.first')),['SUPER + T']);
    const shared = {actions:[{...catalog[0],label:'Shared'},{...catalog[1],label:'Shared'}],custom:[],diagnostics:[]};
    const merged = M.merge(shared,[bind('B','Apps: Shared'),bind('M','Apps: Shared'),bind('T','Apps: Shared'),
        bind('B','Apps: Shared',64,{submap:'resize'})]);
    assert.deepEqual(plain(merged.userBinds),[{keys:['SUPER + T'],group:'Apps',label:'Shared'},
        {keys:['SUPER + B'],group:'Apps',label:'Shared (resize)'}]);
});
test('draft editing, protected keys, conflict claims and discard work without a backend', () => {
    const data = model();
    assert.equal(M.dirty(data),false);
    assert.throws(()=>M.setKeys(data,'shell.lock',[]),/at least one/);
    assert.throws(()=>M.setKeys(data,'hardware.mute',['SUPER + Z']),/cannot be edited/);
    M.setKeys(data,'apps.first',['SUPER + M']);
    assert.equal(M.dirty(data),true);
    assert.deepEqual(plain(M.keysFor(data,'apps.first')),['SUPER + M']);
    assert.deepEqual(plain(M.keysFor(data,'apps.second')),[]);
    M.setKeys(data,'apps.first',['SUPER + T']);
    M.setKeys(data,'apps.second',['SUPER + T']);
    assert.deepEqual(plain(M.conflicts(data,'SUPER + T','apps.first')).map(row=>row.id),['apps.second']);
    assert.ok(M.conflicts(data,'SUPER + L','apps.first').some(row=>row.protected));
    data.binds.push(bind('P','Personal: Notes'));
    assert.equal(M.conflicts(data,'SUPER + P','apps.first')[0].source,'user');
    M.discard(data);
    assert.equal(M.dirty(data),false);
    M.setKeys(data,'apps.first',[]);
    M.reset(data,'apps.first');
    assert.equal(M.dirty(data),false);
});
test('draft remaps retain conflict warnings for keys user.lua will bind again', () => {
    const data = model();
    data.binds = [bind('N','Apps: apps.first'), ...binds.slice(1)];
    M.setKeys(data,'apps.first',['SUPER + T']);
    assert.deepEqual(plain(M.keysFor(data,'apps.first')),['SUPER + T']);
    assert.deepEqual(plain(M.conflicts(data,'SUPER + N','apps.second')),
        [{id:'apps.first',group:'Apps',label:'apps.first',protected:false,source:'user'}]);
});
test('custom CRUD preserves sparse preferences, validates, resets and checks conflicts', () => {
    const data = model();
    const id = M.addCustom(data,{group:'Apps',label:'Notes',keys:['SUPER + N'],run:{type:'command',command:'notes'}});
    assert.match(id,/^custom\.[a-z0-9-]{1,40}$/);
    assert.equal(M.action(data,id).source,'custom');
    M.updateCustom(data,id,{label:'New notes',keys:['SUPER + B']});
    assert.equal(M.action(data,id).label,'New notes');
    assert.deepEqual(plain(M.keysFor(data,'apps.first')),[]);
    assert.ok(M.conflicts(data,'SUPER + B','apps.second').some(row=>row.id===id));
    assert.throws(()=>M.updateCustom(data,id,{id:'custom.other'}),/Invalid/);
    assert.throws(()=>M.addCustom(data,{group:'Apps',label:'Bad',keys:['SUPER + A'],run:{type:'url',url:'file:///etc/passwd'}}),/Invalid/);
    M.removeCustom(data,id);
    assert.equal(M.dirty(data),false);
    M.addCustom(data,{group:'Apps',label:'Notes',keys:['SUPER + N'],run:{type:'command',command:'notes'}});
    M.resetAll(data);
    assert.equal(M.dirty(data),false);
});
test('refresh cannot overwrite a dirty draft or its concurrency version; successful apply uses exact request', () => {
    const data = model();
    M.setKeys(data,'apps.first',['SUPER + T']);
    M.ingest(data,{state:M.resolve(catalog,{v:1}),preferences:{v:1,actions:{'apps.second':{keys:[]}}},version:'external',binds});
    assert.equal(data.version,'first');
    assert.deepEqual(plain(M.keysFor(data,'apps.first')),['SUPER + T']);
    const request = M.request(data);
    assert.equal(request.version,'first');
    M.applied(data,{version:'second',preferences:request.preferences});
    assert.equal(M.dirty(data),false);
    assert.equal(data.version,'second');
    M.setKeys(data,'apps.first',['SUPER + T']);
    assert.equal(M.action(data,'apps.first').source,'user','live bind is still the old one until refresh');
});
test('singleton is registered, lazy and acquires/releases the existing backend', () => {
    const source = fs.readFileSync(path.join(root,'desktop/quickshell/Common/Keybindings.qml'),'utf8');
    assert.doesNotMatch(source,/Component\.onCompleted|Process\s*\{|running:\s*true/);
    assert.match(source,/function acquire\(/);
    assert.match(source,/backend\.acquire\(\)/);
    assert.match(source,/backend\.release\(\)/);
    assert.match(source,/Model\.request\(model\)/);
    assert.match(fs.readFileSync(path.join(root,'desktop/quickshell/Common/qmldir'),'utf8'),/singleton Keybindings Keybindings.qml/);
});

test('desktop launch IPC validates filenames and uses the Apps tab execute path', () => {
    const source = fs.readFileSync(path.join(root,'desktop/quickshell/LauncherWindow.qml'),'utf8');
    const body = source.match(/function launchDesktop\(desktopId: string\): string \{([\s\S]*?)\n        \}/)[1];
    const invoke = new Function('desktopId','DesktopEntries','Launcher',body);
    const calls = [];
    const app = {execute() {calls.push('execute');}};
    const entries = {byId(id) {calls.push(id); return id === 'gimp' ? app : null;}};
    const launcher = {recordLaunch(value) {assert.equal(value,app);calls.push('record');}};
    assert.equal(invoke('gimp.desktop',entries,launcher),'ok');
    assert.deepEqual(calls,['gimp','record','execute']);
    assert.equal(invoke('gimp.desktop; touch /tmp/x',entries,launcher),'invalid');
    assert.equal(calls.length,3);
    assert.equal(invoke('missing.desktop',entries,launcher),'unknown');
});
test('a protected remap keeps its reserved defaults and stores only the extra keys', () => {
    const data = model();
    M.setKeys(data,'shell.lock',['SUPER + T']);
    assert.deepEqual(plain(M.keysFor(data,'shell.lock')),['SUPER + T','SUPER + L']);
    assert.deepEqual(plain(data.draft.actions['shell.lock'].keys),['SUPER + T']);
    M.setKeys(data,'shell.lock',['SUPER + L','SUPER + T']);
    assert.deepEqual(plain(data.draft.actions['shell.lock'].keys),['SUPER + T']);
    M.setKeys(data,'shell.lock',['SUPER + L']);
    assert.equal(M.dirty(data),false);
    assert.throws(()=>M.setKeys(data,'shell.lock',[]),/at least one/);
});
test('a rejected keybindings.json refuses edits except resetAll, which is applied as an explicit replacement', () => {
    const data = model();
    const snapshot = {state:{v:1,error:'invalid number at byte 148',actions:catalog.map(row=>({...row,keys:row.defaultKeys})),custom:[],diagnostics:[]},
        preferences:{v:1},version:'broken-hash',binds,preferencesError:'Shortcut preferences are invalid.'};
    data.loaded = false;
    M.ingest(data, snapshot);
    assert.equal(data.loaded,true);
    assert.equal(M.broken(data),true);
    assert.deepEqual(plain(M.problem(data)),{file:'Shortcut preferences are invalid.',lua:'invalid number at byte 148'});
    assert.equal(M.dirty(data),false);
    for (const edit of [()=>M.setKeys(data,'apps.first',['SUPER + T']),()=>M.reset(data,'apps.first'),
        ()=>M.addCustom(data,{group:'Apps',label:'X',keys:['SUPER + T'],run:{type:'command',command:'true'}}),
        ()=>M.updateCustom(data,'custom.x',{label:'Y'}),()=>M.removeCustom(data,'custom.x')])
        assert.throws(edit,/Reset all shortcuts/);
    assert.equal(M.dirty(data),false);
    M.resetAll(data);
    assert.equal(M.dirty(data),true);
    assert.deepEqual(plain(M.request(data)),{action:'apply',version:'broken-hash',preferences:{v:1},replaceInvalid:true});
    M.discard(data);
    assert.equal(M.dirty(data),false);
    M.resetAll(data);
    M.applied(data,{version:'new-hash',preferences:{v:1}});
    assert.equal(M.broken(data),false);
    assert.equal(M.dirty(data),false);
    assert.equal(data.version,'new-hash');
    M.setKeys(data,'apps.first',['SUPER + T']);
    assert.equal(M.request(data).replaceInvalid,undefined);
});
test('Lua alone rejecting the file also makes the editor read only, and a healthy file is never read only', () => {
    const data = model();
    const state = {v:1,error:'catalog failed',actions:catalog.map(row=>({...row,keys:row.defaultKeys})),custom:[],diagnostics:[]};
    M.ingest(data,{state,preferences:{v:1},version:'h',binds,preferencesError:''});
    assert.equal(M.broken(data),true);
    M.ingest(data,{state:{...state,error:null},preferences:{v:1},version:'h',binds,preferencesError:''});
    assert.equal(M.broken(data),false);
    M.setKeys(data,'apps.first',['SUPER + T']);
});
