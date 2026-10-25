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
        [{id:'apps.first',group:'Apps',label:'apps.first',protected:false,source:'user',editable:true,hidden:false}]);
});
test('setManyKeys changes several rows at once or none, keeping earlier draft edits', () => {
    const data = model();
    M.setKeys(data,'shell.settings',['SUPER + comma','SUPER + ALT + S']);
    const before = plain(data.draft);
    assert.throws(() => M.setManyKeys(data,[{id:'apps.first',keys:[]},{id:'apps.second',keys:['SUPER + Y']},
        {id:'hardware.mute',keys:[]}]),/cannot be edited/);
    assert.deepEqual(plain(data.draft),before,'a refused step restores the draft');
    assert.deepEqual(plain(M.keysFor(data,'apps.first')),['SUPER + B']);
    assert.deepEqual(plain(M.keysFor(data,'apps.second')),['SUPER + M']);
    assert.throws(() => M.setManyKeys(data,[{id:'apps.first',keys:[]},{id:'shell.lock',keys:[]}]),/at least one/);
    assert.deepEqual(plain(data.draft),before,'every validation error rolls back');
    M.setManyKeys(data,[{id:'apps.first',keys:[]},{id:'apps.second',keys:['SUPER + Y']}]);
    assert.deepEqual(plain(M.keysFor(data,'apps.first')),[]);
    assert.deepEqual(plain(M.keysFor(data,'apps.second')),['SUPER + Y']);
    assert.deepEqual(plain(M.keysFor(data,'shell.settings')),['SUPER + ALT + S','SUPER + comma']);
    // A rejected file stays refused, and a failed batch keeps the pending reset.
    const broken = model();
    broken.problem = 'bad';
    broken.recover = true;
    assert.throws(() => M.setManyKeys(broken,[{id:'apps.first',keys:[]}]),/Reset all/);
    assert.equal(broken.recover,true);
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
const shiftRows = [
    {id:'workspaces.move.1',group:'Workspaces',label:'Move to 1',keys:['SUPER + SHIFT + 1'],defaultKeys:['SUPER + SHIFT + 1'],editable:true,protected:false,hidden:false,custom:false},
    {id:'workspaces.move.2',group:'Workspaces',label:'Move to 2',keys:['SUPER + SHIFT + 2'],defaultKeys:['SUPER + SHIFT + 2'],editable:true,protected:false,hidden:false,custom:false},
    {id:'tools.grave',group:'Tools',label:'Grave',keys:['SUPER + SHIFT + grave'],defaultKeys:['SUPER + SHIFT + grave'],editable:true,protected:false,hidden:false,custom:false},
    {id:'apps.letter',group:'Apps',label:'Letter',keys:['SUPER + SHIFT + B'],defaultKeys:['SUPER + SHIFT + B'],editable:true,protected:false,hidden:false,custom:false},
    {id:'workspaces.switch.1',group:'Workspaces',label:'Switch to 1',keys:['SUPER + 1'],defaultKeys:['SUPER + 1'],editable:true,protected:false,hidden:false,custom:false},
    {id:'shell.lock',group:'Shell',label:'Lock',keys:['SUPER + SHIFT + Delete'],defaultKeys:['SUPER + SHIFT + Delete'],editable:true,protected:true,hidden:false,custom:false}
];
function shiftModel(keymap) {
    const out = M.create(), preferences = {v:1}, masks = {SUPER:64, SHIFT:1};
    const live = shiftRows.map(row => { const parts = row.keys[0].split(' + '), key = parts.pop();
        return bind(key, row.group + ': ' + row.label, parts.reduce((mask, part) => mask | masks[part], 0)); });
    M.ingest(out, {state:M.resolve(shiftRows,preferences),preferences,version:'v',binds:live,keymap});
    return out;
}
test('a recorded Shift combination conflicts with the vendor bind once the layout map names it', () => {
    const us = JSON.parse(fs.readFileSync(path.join(root,'tests/fixtures/keybindings/keymap-us.json'),'utf8'));
    const fr = JSON.parse(fs.readFileSync(path.join(root,'tests/fixtures/keybindings/keymap-fr.json'),'utf8'));
    // The recorder translates first; a leftover code:N is translated again for the check.
    assert.deepEqual(plain(M.conflicts(shiftModel(us),'SUPER + SHIFT + 1')).map(row => row.id),['workspaces.move.1']);
    assert.deepEqual(plain(M.conflicts(shiftModel(us),'SUPER + SHIFT + code:10')).map(row => row.id),['workspaces.move.1']);
    assert.equal(M.conflicts(shiftModel(us),'SUPER + SHIFT + code:10')[0].uncertain,undefined);
    assert.deepEqual(plain(M.conflicts(shiftModel(us),'SUPER + SHIFT + code:49')).map(row => row.id),['tools.grave']);
    // AZERTY: the same physical key is ampersand, so the vendor SHIFT + 1 bind is a different key.
    assert.deepEqual(plain(M.conflicts(shiftModel(fr),'SUPER + SHIFT + code:10')),[]);
    assert.deepEqual(plain(M.conflicts(shiftModel(fr),'SUPER + SHIFT + ampersand')),[]);
});
test('without a layout map a Shift code:N key may conflict with any non-letter key with the same modifiers', () => {
    for (const keymap of [undefined, {}, {'11':'2'}]) {
        const data = shiftModel(keymap);
        const result = plain(M.conflicts(data,'SUPER + SHIFT + code:10'));
        assert.deepEqual(result.map(row => row.id).sort(),['shell.lock','tools.grave','workspaces.move.1','workspaces.move.2']);
        assert.ok(result.every(row => row.uncertain === true));
        assert.equal(result.find(row => row.id === 'shell.lock').protected,true);
        // Letters, other modifiers and the key itself being exactly stored are not guesses.
        assert.equal(result.some(row => row.id === 'apps.letter' || row.id === 'workspaces.switch.1'),false);
        assert.deepEqual(plain(M.conflicts(data,'SUPER + code:10')),[]);
        assert.deepEqual(plain(M.conflicts(data,'CTRL + SHIFT + code:10')),[]);
        assert.deepEqual(plain(M.conflicts(data,'SUPER + SHIFT + code:10','workspaces.move.1')).map(row => row.id).includes('workspaces.move.1'),false);
    }
    const data = shiftModel();
    M.setKeys(data,'apps.letter',['SUPER + SHIFT + code:10']);
    const draft = plain(M.conflicts(data,'SUPER + SHIFT + code:10','workspaces.move.2'));
    assert.ok(draft.some(row => row.id === 'apps.letter' && !row.uncertain));
    assert.ok(draft.some(row => row.id === 'workspaces.move.1' && row.uncertain));
});
test('the snapshot keymap is stored with the model, refreshed on every snapshot', () => {
    const data = shiftModel({'10':'1'});
    assert.deepEqual(plain(data.keymap),{'10':'1'});
    M.ingest(data,{state:data.state,preferences:{v:1},version:'v',binds:[],keymap:{'10':'ampersand'}});
    assert.deepEqual(plain(data.keymap),{'10':'ampersand'});
    M.ingest(data,{state:data.state,preferences:{v:1},version:'v',binds:[]});
    assert.deepEqual(plain(data.keymap),{});
});
