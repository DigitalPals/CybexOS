const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { spawnSync } = require('node:child_process');
const root = path.resolve(__dirname, '../..');
const cache = {};
// QML's two declarative import directives are the only syntax Node lacks.
// Everything below them runs unchanged, with the actual imported helpers.
function load(name) {
    if (cache[name]) return cache[name];
    let source = fs.readFileSync(path.join(root, 'desktop/quickshell/Common', name), 'utf8');
    const context = { module: {exports: {}}, console };
    source = source.replace(/^\.pragma .*\n/gm, '').replace(/^\.import "([^"]+)" as (\w+)\n/gm,
        (_, file, alias) => { context[alias] = load(file); return ''; });
    vm.runInNewContext(source, context, {filename: name});
    cache[name] = context.module.exports;
    return cache[name];
}
function plain(value) { return JSON.parse(JSON.stringify(value)); }
function luaBinary() {
    return [process.env.CYBEXOS_TEST_LUA, 'lua', 'lua5.4', 'luajit']
        .filter(Boolean).find(name => spawnSync(name, ['-v']).status === 0);
}
const stub = `
local json = require('keybinding_json')
local active, order, events = {}, {}, {}
local function dispatcher(name)
  return function(...) return { name = name, args = json.array({...}) } end
end
hl = { dsp = {}, config = function(value) events[#events+1] = value end,
  get_config = function() return 1 end, dispatch = function(value) events[#events+1] = value end }
for _, name in ipairs({'exec_cmd','global','send_key_state','layout','focus','exit'}) do hl.dsp[name] = dispatcher(name) end
for group, names in pairs({window={'close','float','move','set_prop','drag','resize'},
  workspace={'toggle_special'}, group={'toggle','next','prev'}}) do
  hl.dsp[group] = {}
  for _, name in ipairs(names) do hl.dsp[group][name] = dispatcher(group .. '.' .. name) end
end
package.preload.workspaces = function()
  local out = {}
  for _, name in ipairs({'toggle_floating','focus','move','next','cycle_layout','minimize','restore_last','move_monitor'}) do
    out[name] = function(...) events[#events+1] = {name=name,args=json.array({...})} end
  end
  return out
end
function hl.unbind(key) active[key] = nil end
function hl.bind(key, action, options)
  local entry = { key=key, dispatcher=action, options=options }
  active[key] = entry
  order[#order+1] = entry
  return { remove=function() if active[key] == entry then active[key] = nil end end }
end
local function registered()
  local result = {}
  for _, entry in ipairs(order) do
    if active[entry.key] == entry then
      local action = entry.dispatcher
      if type(action) == 'function' then events = {}; action(); action = json.array(events) end
      result[#result+1] = { keys=entry.key, dispatcher=action, options=entry.options }
    end
  end
  return json.array(result)
end
`;
module.exports = {load, plain, luaBinary, root, stub};
