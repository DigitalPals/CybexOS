const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {spawnSync} = require('node:child_process');
const {root, luaBinary, stub} = require('./keybindings-support.cjs');
const lua = luaBinary();
function run(source, features = '', preferences, raw) {
    assert.ok(lua, 'Lua is required: run these tests through nix develop');
    const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'cybexos-keybindings-'));
    try {
        for (const dir of ['config/cybexos','runtime/cybexos','data','state']) fs.mkdirSync(path.join(temporary, dir), {recursive:true});
        if (preferences !== undefined || raw !== undefined)
            fs.writeFileSync(path.join(temporary, 'config/cybexos/keybindings.json'), raw === undefined ? JSON.stringify(preferences) : raw);
        const result = spawnSync(lua, ['-'], {input:
            `package.path = ${JSON.stringify(path.join(root, 'desktop/hypr/?.lua'))} .. ';' .. package.path\n`
            + `package.preload.features = function() return {${features}} end\n` + stub + source,
            encoding:'utf8', env:{...process.env, HOME:temporary, XDG_CONFIG_HOME:path.join(temporary,'config'),
                XDG_DATA_HOME:path.join(temporary,'data'), XDG_STATE_HOME:path.join(temporary,'state'), XDG_RUNTIME_DIR:path.join(temporary,'runtime')}});
        assert.equal(result.status, 0, result.stderr);
        const statePath = path.join(temporary, 'runtime/cybexos/keybindings-state.json');
        return {output:result.stdout.split(temporary).join('<TEST_HOME>').trim().split('\n').filter(Boolean).map(line => JSON.parse(line)),
            state:fs.existsSync(statePath) ? JSON.parse(fs.readFileSync(statePath)) : null,
            leftovers:fs.readdirSync(path.dirname(statePath)).filter(name => name.startsWith('.keybindings-'))};
    } finally { fs.rmSync(temporary, {recursive:true, force:true}); }
}
test('defaults exactly match 6f4aa2d, including dispatchers, descriptions, flags and gates', () => {
    const baseline = path.join(root, 'tests/fixtures/keybindings/bindings-6f4aa2d.lua');
    for (const features of ['', 'developer_tools=true, podman=true', 'assistant=true, private_portal=true, proprietary_apps=true',
        'developer_tools=true, podman=true, assistant=true, private_portal=true, proprietary_apps=true, connected_widgets=true, xps_2026=true']) {
        const old = run(`dofile(${JSON.stringify(baseline)})\nprint(json.encode(registered()))`, features).output[0];
        const current = run(`require('bindings')\nrequire('keybinding_preferences')\nprint(json.encode(registered()))`, features);
        assert.deepEqual(current.output[0], old, features);
        assert.equal(current.state.error, null);
        assert.deepEqual(current.leftovers, []);
    }
});
test('reloading removes prior handles and never stacks bindings', () => {
    const {output} = run(`local first=require('bindings')\nrequire('keybinding_preferences')
print(json.encode(registered()))
package.loaded.bindings=nil; package.loaded.keybinding_preferences=nil
require('bindings'); require('keybinding_preferences')
print(json.encode(registered()))`, '', {v:1, actions:{'apps.browser':{keys:['SUPER + ALT + B']}}});
    assert.deepEqual(output[1], output[0]);
    assert.equal(output[0].filter(row => row.keys === 'SUPER + ALT + B').length, 1);
    assert.equal(output[0].some(row => row.keys === 'SUPER + B'), false);
});
test('Lua normalizes, compares and resolves all shared JS vectors', () => {
    const fixture = name => JSON.stringify(path.join(root,'tests/fixtures/keybindings',name+'.json'));
    run(`local helpers=require('keybinding_helpers')
local decoder=require('displays')
local function read(path) local f=assert(io.open(path)); local value=assert(decoder.decode(f:read('*a'))); f:close(); return value end
for _, v in ipairs(read(${fixture('normalize')})) do assert(helpers.normalize(v.input)==v.output, v.input) end
for _, v in ipairs(read(${fixture('same')})) do assert(helpers.same(v.a,v.b)==v.equal, v.a) end
local vectors=read(${fixture('resolution')})
for _, v in ipairs(vectors.cases) do
  local result=helpers.resolve(vectors.catalog,v.preferences)
  for i,row in ipairs(result.actions) do
    assert(#row.keys==#v.keys[i],v.name..' length '..row.id)
    for j,key in ipairs(row.keys) do assert(key==v.keys[i][j],v.name..' key '..row.id) end
  end
  for i,row in ipairs(result.custom) do
    assert(#row.keys==#v.custom[i],v.name..' custom length')
    for j,key in ipairs(row.keys) do assert(key==v.custom[i][j],v.name..' custom key') end
  end
  assert(#result.diagnostics==#v.diagnostics,v.name..' diagnostics length')
  for i,d in ipairs(result.diagnostics) do
    for k,value in pairs(d) do assert(value==v.diagnostics[i][k],v.name..' diagnostic '..k) end
  end
end`);
});
test('invalid, duplicate-key and oversized data keep defaults and publish the reason', () => {
    for (const raw of ['{"v":1,"v":1}', '{"v":2}', '{"v":1,"custom":{}}', ' '.repeat(65537), Buffer.from([0xff]),
        '{"v":1,"actions":{"apps.browser":{"keys":["SUPER + B; os.execute(\'false\')"]}}}']) {
        const {output,state,leftovers} = run(`require('bindings'); local prefs=require('keybinding_preferences'); print(json.encode(registered()))`, '', undefined, raw);
        assert.equal(typeof state.error, 'string');
        assert.ok(output[0].some(row => row.keys === 'SUPER + B' && row.options.description === 'Apps: Browser'));
        assert.deepEqual(leftovers, []);
    }
});
test('all custom launch types are data; only command entries deliberately reach the shell verbatim', () => {
    const site = "https://example.org/'; touch /tmp/should-never-exist; echo '";
    const entries = [
        {id:'custom.site',run:{type:'url',url:site}},
        {id:'custom.app',run:{type:'app',desktopId:'org.gnome.Calculator.desktop'}},
        {id:'custom.web',run:{type:'webapp',id:'gmail'}},
        {id:'custom.command',run:{type:'command',command:'kitty -e nvim ~/notes.md'}}
    ].map((row,i) => ({...row,group:'Personal',label:row.id,keys:['SUPER + ALT + F'+(i+1)]}));
    const {output,state} = run(`require('bindings'); require('keybinding_preferences'); print(json.encode(registered()))`, '', {v:1,custom:entries});
    assert.equal(state.error, null);
    const commands = output[0].filter(row => row.options.description.startsWith('Personal:')).map(row => row.dispatcher.args[0]);
    assert.deepEqual(commands, ["cybexos-apps browser 'https://example.org/'\\''; touch /tmp/should-never-exist; echo '\\'''",
        "cybexos-runtime ipc launcher launchDesktop 'org.gnome.Calculator.desktop'", "cybexos-webapp launch 'gmail'", 'kitty -e nvim ~/notes.md']);
    for (const runValue of [{type:'app',desktopId:'gimp.desktop; false'}, {type:'webapp',id:'$(false)'}, {type:'url',url:'file:///etc/passwd'}]) {
        const invalid = run(`require('bindings'); require('keybinding_preferences')`, '', {v:1,custom:[{...entries[0],run:runValue}]});
        assert.equal(typeof invalid.state.error, 'string');
    }
});
test('required public IDs exist and mouse/hardware actions are not editable', () => {
    const {state} = run(`require('bindings'); require('keybinding_preferences')`, 'assistant=true');
    for (const id of ['shell.launcher','shell.settings','shell.shortcuts','shell.control-panel','shell.notifications','shell.lock','shell.exit','shell.assistant',
        'apps.terminal','apps.browser','apps.files','windows.close','windows.overview','windows.toggle-floating','webapps.slack','webapps.whatsapp','webapps.youtube','webapps.google-photos','webapps.x','clipboard.history','capture.region', 'windows.zoom-in','windows.zoom-out',
        ...Array.from({length:10},(_,i)=>'workspaces.switch.'+(i+1)),...Array.from({length:10},(_,i)=>'workspaces.move.'+(i+1))])
        assert.ok(state.actions.some(row => row.id === id), id);
    assert.equal(new Set(state.actions.map(row => row.id)).size, state.actions.length);
    for (const row of state.actions.filter(row => row.hidden || row.keys.some(key => key.includes('mouse:')))) assert.equal(row.editable, false);
    for (const id of ['shell.lock','shell.exit','shell.settings','shell.shortcuts']) assert.equal(state.actions.find(row => row.id === id).protected, true);
});
test('a protected remap to a keysym that does not exist still leaves the reserved keys bound', () => {
    const {output, state} = run(`require('bindings'); require('keybinding_preferences'); print(json.encode(registered()))`, '',
        {v:1, actions:{'shell.lock':{keys:['SUPER + Lcok']}, 'shell.exit':{keys:['SUPER + ALT + X']}}});
    assert.equal(state.error, null);
    const lock = state.actions.find(row => row.id === 'shell.lock');
    assert.deepEqual(lock.keys, ['SUPER + Lcok', 'SUPER + L']);
    assert.equal(lock.changed, true);
    const bound = output[0].filter(row => row.options.description === 'Shell: Lock screen').map(row => row.keys);
    assert.deepEqual(bound, ['SUPER + Lcok', 'SUPER + L']);
    assert.ok(state.actions.find(row => row.id === 'shell.exit').keys.length === 2);
});
test('custom entries copy only schema fields; unknown nested data cannot change the state\'s shape', () => {
    const raw = '{"v":1,"custom":[{"id":"custom.big","group":"Apps","label":"Big","keys":["SUPER + ALT + F1"],'
        + '"run":{"type":"command","command":"true","extra":{"n":3}},"weight":1e308,"nested":{"n":3},"list":[1,2]}]}';
    const {state, output} = run(`require('bindings'); require('keybinding_preferences'); print(json.encode(registered()))`, '', undefined, raw);
    assert.equal(state.error, null);
    assert.deepEqual(Object.keys(state.custom[0]).sort(), ['group', 'id', 'keys', 'label', 'run']);
    assert.deepEqual(state.custom[0].run, {type:'command', command:'true'});
    assert.ok(output[0].some(row => row.keys === 'SUPER + ALT + F1'));
});
test('numbers that overflow are rejected by the decoder, so the state file stays valid and defaults apply', () => {
    for (const number of ['1e999', '-1e999']) {
        const raw = `{"v":1,"custom":[{"id":"custom.big","group":"Apps","label":"Big","keys":["SUPER + ALT + F1"],`
            + `"run":{"type":"command","command":"true"},"weight":${number}}]}`;
        const {state, output} = run(`require('bindings'); require('keybinding_preferences'); print(json.encode(registered()))`, '', undefined, raw);
        assert.match(state.error, /invalid number/);
        assert.deepEqual(state.custom, []);
        assert.ok(output[0].some(row => row.keys === 'SUPER + B'));
    }
});
test('the state encoder writes non-finite numbers as null instead of invalid JSON', () => {
    const {output} = run(`local encoder=require('keybinding_json')
print(encoder.encode({a=math.huge,b=-math.huge,c=0/0,d=1.5}))`);
    assert.deepEqual(output[0], {a:null, b:null, c:null, d:1.5});
});
