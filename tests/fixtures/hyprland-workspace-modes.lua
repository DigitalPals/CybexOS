package.path = "roles/desktop/files/?.lua;" .. package.path
local data = require("workspace_state")
local model = require("workspace_model")
local floating = require("workspace_layouts")
local assertions = 0
local function check(value, message)
  assertions = assertions + 1
  assert(value, message)
end
local function fails(callback, message) check(not pcall(callback), message) end
-- Native Hyprland reaps popen helpers through SIGCHLD before Lua pclose;
-- preserve the successful check token while modeling its actual ECHILD return.
local native_popen, preparations = io.popen, 0
io.popen = function(command, mode)
  preparations = preparations + 1
  local pipe = assert(native_popen(command, mode))
  return {
    read = function(_, amount) return pipe:read(amount) end,
    close = function() pipe:close(); return nil, "No child processes", 10 end,
  }
end
local echild_path = assert(os.getenv("XDG_CONFIG_HOME")) .. "/pipe-close-check/state.json"
check(data.write(echild_path, { v = 1 }), "native ECHILD lost a successful directory check")
check(data.write(echild_path, { v = 2 }) and preparations == 1, "event writes repeated directory preparation")
io.popen = function()
  return { read = function() return "" end, close = function() return nil, "No child processes", 10 end }
end
check(not data.write(echild_path .. "/unprepared/state.json", { v = 1 }), "ECHILD accepted a helper without a success token")
io.popen = function()
  return { read = function() return string.rep("a", 32) .. "\n" end, close = function() return nil, "exit", 1 end }
end
check(not data.write(echild_path .. "/failed/state.json", { v = 1 }), "explicit helper failure was ignored")
io.popen = native_popen
local function output(name, serial, x)
  return { name = name, id = x or 0, description = "Example display", serial = serial or "",
    width = 2560, height = 1440, scale = 1, x = x or 0, y = 0,
    reserved = { top = 32, bottom = 40 }, is_mirror = false }
end
local function document() return { v = 1, assignments = data.array() } end
local function live(id, monitor) return { id = id, name = tostring(id), monitor = monitor, windows = 1 } end
-- Persisted physical identities: same panel across dock connector changes,
-- duplicate/missing serials, removal of one of a pair, deterministic ambiguity.
local saved, a, b = document(), output("eDP-1", "A"), output("DP-1", "B", 2560)
local current = model.assign(saved, model.connected({ b, a }), { live(1, a), live(2, b) })
check(current[a.name].slots[1] == 1 and current[b.name].slots[1] == 2, "existing global workspaces were not adopted in place")
local id_b = current[b.name].identity
b.name = "DP-9"
current = model.assign(saved, model.connected({ a, b }), {}, { [a.name] = current[a.name].identity })
check(current[b.name].identity == id_b, "physical monitor lost its identity across connectors")
local duplicate = document()
local d1, d2 = output("DP-1", "duplicate"), output("DP-2", "duplicate")
local pair = model.assign(duplicate, { d1, d2 }, {})
check(pair[d1.name].identity ~= pair[d2.name].identity, "duplicate serials shared an identity")
local kept = pair[d2.name].identity
pair = model.assign(duplicate, { d2 }, {}, { [d2.name] = kept })
check(pair[d2.name].identity == kept, "removing one duplicate reassigned the survivor")
d2.name = "DP-8"
pair = model.assign(duplicate, { d2 }, {})
check(pair[d2.name].identity == duplicate.assignments[1].identity, "ambiguous reconnect must use documented deterministic order")
local missing = document()
local m1, m2 = output("HDMI-A-1", "0"), output("HDMI-A-2")
local missing_pair = model.assign(missing, { m1, m2 }, {})
check(missing_pair[m1.name].identity ~= missing_pair[m2.name].identity, "missing serials collided")
local mirrored = output("DP-MIRROR", "M"); mirrored.is_mirror = true
check(#model.connected({ a, mirrored }) == 1, "mirrored outputs acquired local slots")
-- Occupied IDs on other outputs and all persisted offline slots are reserved.
local used = {}
for _, row in ipairs(saved.assignments) do for _, id in ipairs(row.slots) do check(not used[id], "allocation collided"); used[id] = true end end
local c = output("HDMI-A-3", "C")
local foreign = live(100, "other")
current = model.assign(saved, { a, b, c }, { foreign })
for _, id in ipairs(current[c.name].slots) do check(id ~= 100, "occupied foreign ID was reused") end
check(#model.validate(assert(require("displays").decode(data.encode(saved)))).assignments == #saved.assignments, "assignment JSON roundtrip")
local corrupt = assert(require("displays").decode(data.encode(saved)))
corrupt.assignments[2].slots[1] = corrupt.assignments[1].slots[1]
fails(function() model.validate(corrupt) end, "corrupt duplicate persisted IDs were accepted")
fails(function() model.validate({ v = 1, assignments = {} }) end, "objects were accepted as arrays")
local renamed_state, named_monitor = document(), output("DP-named", "named")
local named_mapping = model.assign(renamed_state, { named_monitor }, {})
local original_slot = named_mapping[named_monitor.name].slots[1]
local named_workspace = { id = original_slot, name = "research", monitor = named_monitor }
named_mapping = model.assign(renamed_state, { named_monitor }, { named_workspace })
check(named_mapping[named_monitor.name].slots[1] ~= original_slot and named_workspace.name == "research",
  "a renamed workspace was reused or changed")
local untouched_named = { id = 1, name = "notes", monitor = named_monitor }
local named_fresh = model.assign(document(), { named_monitor }, { untouched_named })
for _, number in ipairs(named_fresh[named_monitor.name].slots) do check(number ~= 1, "positive named ID was allocated as a slot") end
-- A small compositor model includes the visible-workspace swap trap.
local world = { monitors = {}, workspaces = {}, windows = {}, rules = {}, listeners = {}, timers = {}, swaps = 0,
  native_scrolling = true, general_layout = "master", layout_writes = 0, plugin_loaded = false, plugin_declarations = 0, plugin_buttons = 0 }
local function monitor_named(name) for _, mon in ipairs(world.monitors) do if mon.name == name then return mon end end end
local function workspace(id) for _, ws in ipairs(world.workspaces) do if ws.id == tonumber(id) then return ws end end end
local function create(id, mon)
  local found = workspace(id)
  if found then return found end
  local target = mon or world.focused
  for _, rule in ipairs(world.rules) do
    if rule.enabled and rule.spec.workspace == tostring(id) and rule.spec.monitor then target = monitor_named(rule.spec.monitor) or target end
  end
  local ws = { id = id, name = tostring(id), monitor = target, windows = 0 }
  world.workspaces[#world.workspaces + 1] = ws
  return ws
end
local function lowest_free() local id = 1; while workspace(id) do id = id + 1 end; return id end
local function count_windows()
  for _, ws in ipairs(world.workspaces) do ws.windows = 0 end
  for _, win in ipairs(world.windows) do win.workspace.windows = win.workspace.windows + 1 end
end
local function move_workspace(ws, mon)
  local source = ws.monitor
  if source and source.active_workspace == ws then
    local replacement
    for _, candidate in ipairs(world.workspaces) do if candidate ~= ws and candidate.monitor == source and not candidate.special then replacement = candidate; break end end
    source.active_workspace = replacement or create(lowest_free(), source)
    if source == world.focused then mon.active_workspace = ws end
  end
  ws.monitor = mon
  for _, win in ipairs(world.windows) do if win.workspace == ws then win.monitor = mon end end
end
hl = { dsp = { window = {}, workspace = {} }, plugin = {},
  get_loaded_plugins = function() return world.plugin_loaded and { { name = "hyprbars" } } or {} end }
function hl.plugin.load(path)
  assert(path == "/usr/lib64/cybexos/titlebars.so", "unexpected plugin path")
  world.plugin_declarations = world.plugin_declarations + 1
end
setmetatable(hl.plugin, { __index = function(_, key)
  assert(key == "hyprbars" and world.plugin_loaded, "plugin callbacks accessed before native registry")
  return { add_button = function() world.plugin_buttons = world.plugin_buttons + 1 end,
    clear_buttons = function() world.plugin_buttons = 0 end }
end })
function hl.get_config(key)
  if key == "scrolling.column_width" and world.native_scrolling then return 0.5 end
  if key == "general.layout" then return world.general_layout end
  if key == "input.follow_mouse" then return 1 end
end
function hl.config(spec)
  world.config = spec
  if spec.general and spec.general.layout then
    world.general_layout, world.layout_writes = spec.general.layout, world.layout_writes + 1
  end
end
function hl.get_monitors() return world.monitors end
function hl.get_active_monitor() return world.focused end
function hl.get_workspace(value) return workspace(value) end
function hl.get_active_workspace() return world.focused and world.focused.active_workspace end
function hl.get_workspaces() local rows = {}; for _, ws in ipairs(world.workspaces) do rows[#rows + 1] = ws end; return rows end
function hl.get_windows() return world.windows end
function hl.get_active_window() return world.active_window end
function hl.on(event, callback)
  local sub = { callback = callback, enabled = true }
  function sub:remove() self.enabled = false end
  world.listeners[event] = world.listeners[event] or {}
  table.insert(world.listeners[event], sub)
  return sub
end
function hl.timer(callback)
  local timer = { callback = callback, enabled = true }
  function timer:set_enabled(value) self.enabled = value end
  world.timers[#world.timers + 1] = timer
  return timer
end
local function flush()
  local passes = 0
  while #world.timers > 0 do
    passes = passes + 1; assert(passes <= 20, "unbounded refresh loop")
    local timers = world.timers; world.timers = {}
    for _, timer in ipairs(timers) do if timer.enabled then timer.callback() end end
  end
end
local function emit(event, ...)
  for _, sub in ipairs(world.listeners[event] or {}) do if sub.enabled then sub.callback(...) end end
  flush()
end
local function rule(spec)
  if spec["hyprbars:no_bar"] then assert(world.plugin_loaded, "dynamic no-bar rule installed without native plugin effect") end
  local handle = { spec = spec, enabled = spec.enabled ~= false }
  function handle:set_enabled(value) self.enabled = value end
  world.rules[#world.rules + 1] = handle
  return handle
end
hl.workspace_rule, hl.window_rule = rule, rule
function hl.dispatch(callback) return callback() end
function hl.dsp.focus(spec) return function()
  if spec.monitor then world.focused = assert(monitor_named(spec.monitor)) end
  if spec.workspace then
    local ws = workspace(spec.workspace) or create(tonumber(spec.workspace))
    if ws.monitor ~= world.focused and ws.monitor.active_workspace == ws then
      world.swaps = world.swaps + 1
      local previous = world.focused.active_workspace
      previous.monitor, ws.monitor = ws.monitor, world.focused
      previous.monitor.active_workspace = previous
    end
    world.focused.active_workspace = ws
  end
  if spec.window then world.active_window = spec.window; world.focused = spec.window.monitor; world.focused.active_workspace = spec.window.workspace end
end end
function hl.dsp.workspace.move(spec) return function() move_workspace(assert(workspace(spec.workspace)), assert(monitor_named(spec.monitor))) end end
function hl.dsp.window.tag(spec) return function()
  local tags, value = spec.window.tags, spec.tag:sub(2)
  if spec.tag:sub(1, 1) == "+" then
    if not floating.tagged(spec.window, value) then tags[#tags + 1] = value end
  else
    for i = #tags, 1, -1 do if tags[i] == value then table.remove(tags, i) end end
  end
end end
function hl.dsp.window.float(spec) return function()
  local members = spec.window.group and spec.window.group.members or { spec.window }
  local enabled = spec.action == "on" or (spec.action == "toggle" and not spec.window.floating)
  for _, win in ipairs(members) do win.floating = enabled end
end end
function hl.dsp.window.resize(spec) return function() spec.window.size = { x = spec.x, y = spec.y } end end
function hl.dsp.window.move(spec) return function()
  local win = spec.window
  if spec.workspace then
    local destination
    if spec.workspace == "special:cybexos-minimized" then
      destination = workspace(-99)
      if not destination then destination = { id = -99, name = spec.workspace, special = true, monitor = win.monitor, windows = 0 }; world.workspaces[#world.workspaces + 1] = destination end
    else destination = workspace(spec.workspace) or create(tonumber(spec.workspace)) end
    for _, member in ipairs(win.group and win.group.members or { win }) do member.workspace, member.monitor = destination, destination.monitor end
    count_windows()
  else win.at = { x = spec.x, y = spec.y } end
end end
function hl.dsp.window.fullscreen_state(spec) return function() spec.window.fullscreen = spec.internal end end
local function add_monitor(mon, active)
  world.monitors[#world.monitors + 1] = mon
  function mon:set_workspace(spec) self.active_workspace = assert(workspace(spec.workspace)) end
  mon.active_workspace = create(active, mon)
  if not world.focused then world.focused = mon end
end
local function window(pointer, ws, opts)
  local win = { address = pointer, workspace = ws, monitor = ws.monitor, pid = tonumber(pointer:sub(3), 16),
    tags = {}, mapped = true, floating = false, fullscreen = 0, size = { x = 900, y = 600 }, at = { x = 20, y = 40 } }
  for key, value in pairs(opts or {}) do win[key] = value end
  world.windows[#world.windows + 1] = win
  count_windows(); return win
end
local function load()
  package.loaded.workspaces = nil
  return require("workspaces")
end
local function snapshot_row(module, target)
  for _, row in ipairs(module.snapshot.workspaces) do if row.id == target then return row end end
end
local internal, external = output("eDP-1", "internal"), output("DP-1", "external", 2560)
add_monitor(internal, 1); add_monitor(external, 2)
local first, second = window("0x1", workspace(1)), window("0x2", workspace(2))
world.active_window = first
-- hyprland.lua collects ordinary Lua arrays from looknfeel/user float rules.
-- Include actual generated-config patterns; these tables have no JSON .n tag.
local exclusions = {
  class = { "(?:^cybex$)", "(?:xdg-desktop-portal-gtk)" },
  title = { "(?:^CybexOS Settings$)", "(?:^Welcome to CybexOS$)" },
}
_G.__cybexos_float_exclusions = exclusions
local ws = load()
check(ws.snapshot.error == "", "nonempty generated float exclusions broke workspace refresh: " .. ws.snapshot.error)
check(exclusions.class.n == nil and exclusions.title.n == nil and #exclusions.class == 2 and #exclusions.title == 2,
  "workspace signature mutated externally owned exclusion arrays")
check(ws.snapshot.mode == "shared", "existing users did not retain Shared")
check(ws.snapshot.capabilities.scrolling == true, "native scrolling option was missed")
check(world.general_layout == "master" and world.layout_writes == 0, "first introduction overwrote user.lua native layout")
check(not ws.snapshot.defaultLayoutManaged and ws.snapshot.defaultLayout == "unmanaged"
  and ws.snapshot.nativeDefaultLayout == "master", "custom native default was mislabeled as managed Tiled")
check(snapshot_row(ws, 1).layout == "unmanaged" and snapshot_row(ws, 1).nativeLayout == "master"
  and not snapshot_row(ws, 1).layoutManaged, "custom workspace layout was mislabeled")
check(data.read(ws.path) == nil, "first introduction created a personal layout preference")
workspace(2).tiled_layout = "scrolling"; ws.refresh()
check(snapshot_row(ws, 2).layout == "scrolling" and not snapshot_row(ws, 2).layoutManaged,
  "unmanaged per-workspace native rule was ignored")
workspace(2).tiled_layout = nil
ws.set_titlebars_enabled(false); ws.set_titlebars_enabled(true)
ws = load()
check(world.layout_writes == 0 and not ws.snapshot.defaultLayoutManaged, "titlebar edits/reload took default layout ownership")
ws.set_layout(1, "dwindle")
check(snapshot_row(ws, 1).layout == "dwindle" and snapshot_row(ws, 1).layoutManaged
  and world.general_layout == "master", "explicit workspace Tiled choice was dropped under custom default")
ws.set_layout(1, "default")
check(snapshot_row(ws, 1).layout == "unmanaged" and not snapshot_row(ws, 1).layoutManaged, "reset failed to restore native inheritance")
ws.cycle_layout(1)
check(snapshot_row(ws, 1).layout == "dwindle", "cycling custom native layout did nothing")
ws.set_layout(1, "default")
local registered_gesture
hl.gesture = function(spec) registered_gesture = spec end
_G.__cybexos_gestures = { active = { { name = "workspace", fingers = 3, direction = "horizontal" } } }
function _G.__cybexos_gestures.remove(name)
  for i, entry in ipairs(_G.__cybexos_gestures.active) do
    if entry.name == name then table.remove(_G.__cybexos_gestures.active, i); return true end
  end
  return false
end
ws.set_mode("per-monitor")
check(ws.snapshot.mode == "per-monitor" and snapshot_row(ws, 1).localNumber == 1, "per-monitor transition failed")
check(world.layout_writes == 0 and not ws.snapshot.defaultLayoutManaged, "mode change reset the user's native default")
local external_slot = snapshot_row(ws, 2).localNumber
check(external_slot == 1, "external did not keep its existing workspace in a local slot")
check(type(registered_gesture.action) == "table", "local mode retained the native global swipe")
registered_gesture.action.start({ delta = { x = 0 } })
registered_gesture.action.update({ delta = { x = -80 } })
registered_gesture.action.finish({ cancelled = false })
check(snapshot_row(ws, internal.active_workspace.id).localNumber == 2, "swipe did not use focused monitor's local mapping")
ws.focus_id(1)
ws.focus(2, external.name)
local target = external.active_workspace.id
check(snapshot_row(ws, target).localNumber == 2 and world.focused == external, "local focus selected wrong output")
world.focused = internal
ws.move(first.address, 2, external.name); flush()
check(first.workspace.id == target, "local move selected wrong internal ID")
ws.move_id(first.address, 1); flush()
fails(function() ws.move_id("0xdead", 1) end, "move accepted a nonexistent live window")
fails(function() ws.focus_id(-1) end, "negative relative workspace target accepted")
fails(function() ws.focus_id(999999) end, "stale arbitrary workspace target accepted")
fails(function() ws.move_id('0x1);os.execute("bad")', 1) end, "executable address accepted")
-- Disconnect with all ten local slots occupied: retain guest ID and reach it.
local internal_ids
for _, row in ipairs(ws.snapshot.monitors) do if row.name == internal.name then internal_ids = row.workspaces end end
for _, id in ipairs(internal_ids) do if id ~= 1 then window("0x" .. string.format("%x", id + 100), create(id, internal)) end end
world.monitors = { internal }; world.focused = internal
move_workspace(workspace(2), internal); move_workspace(workspace(target), internal)
internal.active_workspace = workspace(1)
emit("monitor.layout_changed")
check(snapshot_row(ws, 2).guest and snapshot_row(ws, 2).monitor == internal.name, "full local list lost the offline guest")
ws.focus_id(2)
check(internal.active_workspace.id == 2, "guest windows became unreachable")
fails(function() ws.new_workspace(internal.name) end, "full list should report capacity, not steal an occupied ID")
-- Restore through a different connector, preserve unrelated visible workspace.
external.name = "DP-7"; world.monitors = { internal, external }; external.active_workspace = create(200, external)
internal.active_workspace = workspace(1)
emit("monitor.layout_changed")
check(second.workspace.monitor == external and internal.active_workspace.id == 1, "reconnect swapped an unrelated visible workspace")
check(world.swaps == 0, "reclaim used cross-monitor focus/swap semantics")
check(snapshot_row(ws, 2).localNumber == 1, "connector change lost local mapping")
-- Mirroring/lid close removes independent ownership and reopening reclaims it.
external.is_mirror = true
move_workspace(workspace(2), internal); emit("monitor.layout_changed")
check(#ws.snapshot.monitors == 1 and snapshot_row(ws, 2).guest, "mirror owned a workspace")
external.is_mirror = false; world.monitors = { external }; world.focused = external
move_workspace(workspace(1), external); emit("monitor.layout_changed")
check(snapshot_row(ws, 1).guest, "closed lid windows disappeared")
world.monitors = { internal, external }; emit("monitor.layout_changed")
check(first.workspace.monitor == internal, "lid reopen did not reclaim windows")
-- Reversible modes never change workspace IDs/windows or reset layouts.
ws.set_layout(1, "scrolling")
ws.set_mode("shared"); ws.set_mode("per-monitor")
check(first.workspace.id == 1 and snapshot_row(ws, 1).layout == "scrolling", "mode transition lost ID/layout")
-- Shared allocation must include positive IDs belonging to named workspaces.
ws.set_mode("shared")
local named_id = lowest_free()
for number = named_id, 18 do create(number, external) end
local named = workspace(18)
named.name = "research"
local special = { id = -77, name = "special:notes", special = true, monitor = external, windows = 1 }
world.workspaces[#world.workspaces + 1] = special
local created = ws.new_workspace(internal.name)
check(created == 19 and workspace(created).monitor == internal, "Shared allocation reused an occupied named ID")
check(named.name == "research" and named.monitor == external and special.monitor == external,
  "Shared allocation modified named/special workspaces")
ws.set_mode("per-monitor")
_G.__cybexos_gestures.remove("workspace")
registered_gesture = nil
ws.set_mode("shared"); ws.set_mode("per-monitor")
check(registered_gesture == nil, "mode transition ignored a workspace swipe opt-out")
-- Floating ownership: dialogs/independent floaters, fullscreen and groups.
local independent = window("0xabc", workspace(1), { floating = true })
local fullscreen = window("0xabd", workspace(1), { fullscreen = 2 })
local grouped1, grouped2 = window("0xabe", workspace(1)), window("0xabf", workspace(1))
local group = { members = { grouped1, grouped2 } }; grouped1.group, grouped2.group = group, group
ws.set_layout(1, "floating")
local opening_rule
for _, handle in ipairs(world.rules) do
  if handle.enabled and handle.spec.name == "cybexos-floating-open-1" then opening_rule = handle end
end
check(opening_rule and opening_rule.spec.match.class == "negative:" .. table.concat(exclusions.class, "|")
  and opening_rule.spec.match.title == "negative:" .. table.concat(exclusions.title, "|"),
  "nonempty class/title exclusions were lost from the floating opening rule")
local rules_before_refresh = #world.rules
ws.refresh()
check(#world.rules == rules_before_refresh, "unchanged nonempty exclusions rebuilt opening rules")
exclusions.title[#exclusions.title + 1] = "(?:^Extra dialog$)"
ws.refresh()
check(ws.snapshot.error == "" and not opening_rule.enabled and #world.rules > rules_before_refresh
  and exclusions.title.n == nil and #exclusions.title == 3, "in-place exclusion change was missed or mutated")
local refreshed_opening_rule
for _, handle in ipairs(world.rules) do
  if handle.enabled and handle.spec.name == "cybexos-floating-open-1" then refreshed_opening_rule = handle end
end
check(refreshed_opening_rule and refreshed_opening_rule.spec.match.title == "negative:" .. table.concat(exclusions.title, "|"),
  "updated exclusions were missing from replacement opening rules")
check(first.floating and floating.tagged(first, floating.FLOATED), "tiled window was not mode-owned")
check(independent.floating and not floating.tagged(independent, floating.FLOATED), "independent floating window was claimed")
check(not fullscreen.floating and fullscreen.fullscreen == 2, "fullscreen was disturbed")
check(floating.tagged(grouped1, floating.FLOATED) and floating.tagged(grouped2, floating.FLOATED), "not all group members were claimed before float")
local opened = window("0xac0", workspace(1), { floating = true, tags = { floating.OPENED .. "*" } })
emit("window.open", opened)
check(floating.tagged(opened, floating.FLOATED), "opening-rule float was not claimed")
ws.toggle_floating(opened.address); flush()
check(not opened.floating and floating.tagged(opened, floating.USER) and not floating.tagged(opened, floating.FLOATED),
  "manual tiling of a newly opened window was overridden by its opening tag")
emit("window.open", opened); ws = load(); flush()
check(not opened.floating and floating.tagged(opened, floating.USER), "opening tag reclaimed a manual choice after refresh/reload")
local pending_before = #world.timers
emit("window.move_to_workspace", first, workspace(2))
check(#world.timers == pending_before, "one-shot work leaked")
ws.set_layout(1, "dwindle")
check(not first.floating and independent.floating and not grouped1.floating and not grouped2.floating, "returning to tiled changed independent floating or stranded group")
check(not opened.floating, "opening rule ownership was not reversible")
ws.set_layout(1, "floating"); ws.toggle_floating(first.address); flush()
check(not first.floating and not floating.tagged(first, floating.FLOATED), "manual floating choice was overwritten")
ws.set_layout(1, "dwindle"); ws.set_layout(1, "floating")
-- Restore clamps geometry to scaled/rotated current usable bounds.
world.active_window, world.focused = independent, internal
ws.minimize(independent.address)
check(independent.workspace.name == "special:cybexos-minimized" and #ws.snapshot.minimized == 1, "minimize did not retain reachable metadata")
ws = load()
check(#ws.snapshot.minimized == 1, "Lua reload lost minimized origin")
internal.scale, internal.transform, internal.width, internal.height = 2, 1, 1920, 1080
ws.activate(independent.address)
check(independent.workspace.id == 1 and world.active_window == independent and #ws.snapshot.minimized == 0, "activation failed to restore minimized window")
local bounds = floating.bounds(internal)
check(independent.at.x >= bounds.x and independent.at.y >= bounds.y and independent.at.x + independent.size.x <= bounds.x + bounds.width
  and independent.at.y + independent.size.y <= bounds.y + bounds.height, "restored geometry escaped usable rotated/scaled bounds")
ws.minimize(grouped1.address)
check(#ws.snapshot.minimized == 2 and grouped2.workspace.special, "group minimize stranded another member")
ws.activate(grouped2.address)
check(#ws.snapshot.minimized == 0 and grouped1.workspace.id == 1, "group restore stranded another member")
-- Display move is separate from local number move and scales placement.
ws.move_monitor("right", independent.address); flush()
check(independent.monitor == external, "display move did not move to independent display")
-- Reload retires listeners and rules; fresh compositor state retains choices.
ws = load(); flush()
for event, entries in pairs(world.listeners) do
  local active = 0; for _, sub in ipairs(entries) do if sub.enabled then active = active + 1 end end
  check(active == 1, "reload leaked subscriptions for " .. event)
end
ws.set_default_layout("floating")
ws = load()
check(ws.snapshot.mode == "per-monitor" and ws.snapshot.defaultLayout == "floating", "reload lost personal mode/default")
check(ws.snapshot.defaultLayoutManaged and world.general_layout == "dwindle" and world.layout_writes > 0,
  "deliberate default selection did not take ownership")
-- Installed plugins are declared on each parse, never on event/runtime edits.
local native_open = io.open
io.open = function(path, mode)
  if path == "/usr/lib64/cybexos/titlebars.so" then return { close = function() end } end
  return native_open(path, mode)
end
ws = load()
check(world.plugin_declarations == 1 and not ws.snapshot.capabilities.titlebars and world.plugin_buttons == 0,
  "declarative load accessed callbacks before the plugin registry was ready")
world.plugin_loaded = true; ws.refresh()
check(ws.snapshot.capabilities.titlebars and world.plugin_buttons == 3, "loaded plugin did not configure titlebar buttons")
local csd_rule
for _, handle in ipairs(world.rules) do if handle.enabled and handle.spec["hyprbars:no_bar"] then csd_rule = handle end end
check(csd_rule and csd_rule.spec.match.class == "^(org[.]gnome[.]Nautilus|org[.]gnome[.]TextEditor)$",
  "known CSD exclusion was missing or matched arbitrary clients")
ws.set_titlebars_enabled(false); ws = load()
check(not csd_rule.enabled, "reload leaked the previous dynamic CSD rule")
check(world.plugin_declarations == 2 and not ws.snapshot.capabilities.titlebars,
  "disabled plugin was not declared on the next config parse")
ws.set_titlebars_enabled(true); ws.set_default_layout("floating"); ws.refresh_theme(); emit("window.open", opened)
check(world.plugin_declarations == 2 and ws.snapshot.capabilities.titlebars and world.plugin_buttons == 3,
  "runtime edits/events reloaded the native plugin or duplicated buttons")
io.open, world.plugin_loaded = native_open, false
-- Old schema-v1 preferences retain managed semantics when the flag is absent.
local old_preferences = assert(data.read(ws.path, function(value) return value end)); old_preferences.manageDefaultLayout = nil
check(data.write(ws.path, old_preferences), "could not prepare legacy v1 preference fixture")
ws = load()
check(ws.snapshot.defaultLayoutManaged and ws.snapshot.defaultLayout == "floating", "legacy explicit default lost ownership")
world.native_scrolling = false; ws = load()
check(not ws.snapshot.capabilities.scrolling, "missing scrolling capability was invented")
fails(function() ws.set_layout(1, "scrolling") end, "unavailable native layout was offered")
ws.cycle_layout(1)
check(snapshot_row(ws, 1).layout ~= "scrolling", "cycle selected unsupported scrolling")
-- Strict bounded data input, never execute malformed personal state.
local preferences_path = ws.path
local file = assert(io.open(preferences_path, "wb")); file:write('{"v":1,"mode":"shared","mode":"per-monitor"}'); file:close()
ws = load()
check(ws.snapshot.mode == "shared" and ws.snapshot.error ~= "", "corrupt personal state was not contained")
fails(function() ws.set_mode("per-monitor") end, "setter overwrote corrupt personal choices")
local json = require("displays")
check(json.decode(string.rep(" ", data.MAX_BYTES + 1)) == nil, "oversized input accepted")
check(json.decode('{"x":NaN}') == nil and json.decode('{"x":1} trailing') == nil, "strict JSON accepted executable extensions")
check(not ws.snapshot.capabilities.titlebars, "missing optional titlebar plugin was reported as working")
print("Hyprland workspace/mode behavioral fixtures passed (" .. assertions .. " assertions)")
