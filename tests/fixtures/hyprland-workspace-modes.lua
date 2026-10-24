package.path = "desktop/hypr/?.lua;" .. package.path
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
  get_loaded_plugins = function() return world.plugin_loaded and { { name = world.plugin_name or "hyprbars" } } or {} end }
function hl.plugin.load(path)
  assert(path == "/etc/cybexos/titlebars.so", "unexpected plugin path")
  world.plugin_declarations = world.plugin_declarations + 1
end
setmetatable(hl.plugin, { __index = function(_, key)
  assert(key == "hyprbars" and world.plugin_loaded and not world.plugin_name, "plugin callbacks accessed before native registry")
  world.plugin_namespace_reads = (world.plugin_namespace_reads or 0) + 1
  if world.plugin_api_missing then return {} end
  return { add_button = function()
      assert(not world.plugin_button_failure, "native button setup failed")
      world.plugin_button_adds = (world.plugin_button_adds or 0) + 1
      world.plugin_buttons = world.plugin_buttons + 1
    end,
    clear_buttons = function()
      world.plugin_clears = (world.plugin_clears or 0) + 1
      world.plugin_buttons = 0
    end }
end })
function hl.get_config(key)
  if key == "scrolling.column_width" and world.native_scrolling then return 0.5 end
  if key == "general.layout" then return world.general_layout end
  if key == "input.follow_mouse" then return 1 end
end
function hl.config(spec)
  world.config = spec
  if spec.plugin and spec.plugin.hyprbars then
    assert(world.plugin_loaded and not world.plugin_name, "plugin config accessed before native registry")
    assert(not world.plugin_config_failure, "native titlebar configuration failed")
    world.plugin_config_writes = (world.plugin_config_writes or 0) + 1
    world.plugin_rendering = spec.plugin.hyprbars.enabled
  end
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
local function deliver(event, ...)
  for _, sub in ipairs(world.listeners[event] or {}) do if sub.enabled then sub.callback(...) end end
end
local function emit(event, ...)
  deliver(event, ...)
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
  if spec.action == "toggle" and spec.window.group then
    for _, member in ipairs(members) do
      check(floating.tagged(member, floating.USER) and not floating.tagged(member, floating.FLOATED),
        "group toggle dispatched before every member released mode ownership")
    end
  end
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
-- Model the qualified efb5099 CWorkspace::matchesStaticSelector, independently
-- of model.regular. In particular n[false] tests the native ID class, not the
-- name: a renamed positive ID still matches it and a numeric named ID does not.
local function matches_workspace(selector, target)
  if selector:match("^%d+$") then return target.id == tonumber(selector) end
  if selector:sub(1, 5) == "name:" then return target.name == selector:sub(6) end
  if selector:sub(1, 7) == "special" then return target.name == selector end
  for part in selector:gmatch("%S+") do
    local low, high = part:match("^r%[(%d+)%-(%d+)%]$")
    local named = part:match("^n%[(%a+)%]$")
    local special = part:match("^s%[(%a+)%]$")
    if low then
      if target.id < tonumber(low) or target.id > tonumber(high) then return false end
    elseif named then
      assert(named == "true" or named == "false", "unsupported named selector")
      if (target.id <= -1337) ~= (named == "true") then return false end
    elseif special then
      assert(special == "true" or special == "false", "unsupported special selector")
      if (target.special == true) ~= (special == "true") then return false end
    else error("unsupported fixture workspace selector: " .. part) end
  end
  return true
end
local function excluded(value, expression)
  assert(expression:sub(1, 9) == "negative:", "unsupported fixture rule expression")
  -- Only the collector's simple class/title alternatives below are needed to
  -- replay the old opening rule; this is not a general RE2 implementation.
  for pattern in expression:sub(10):gmatch("[^|]+") do
    pattern = pattern:gsub("%(%?:", ""):gsub("[()]", ""):gsub("%-", "%%-")
    if (value or ""):match(pattern) then return true end
  end
  return false
end
local function open_window(pointer, target, opts)
  local win = window(pointer, target, opts)
  -- Replay static opening effects before openLate. This deliberately exposes
  -- ID-range rules that float a renamed workspace before Lua can claim it.
  for _, handle in ipairs(world.rules) do
    local spec, match = handle.spec, handle.spec.match
    if handle.enabled and spec.float ~= nil and match and match.workspace
      and matches_workspace(match.workspace, target)
      and (match.modal == nil or match.modal == (win.modal == true))
      and (not match.class or not excluded(win.class, match.class))
      and (not match.title or not excluded(win.title, match.title)) then
      win.floating = spec.float
      if spec.tag then win.tags[#win.tags + 1] = spec.tag:sub(2) .. "*" end
    end
  end
  deliver("window.open", win)
  -- Leave deferred timers pending: callers can assert the state at the end of
  -- the mapping callback, before a compositor could render its first frame.
  return win
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
  title = { "(?:^Cybex OS Settings$)", "(?:^Welcome to Cybex OS$)" },
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
  and not snapshot_row(ws, 1).layoutManaged and snapshot_row(ws, 1).layoutOverride == false, "custom workspace layout was mislabeled")
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
  and snapshot_row(ws, 1).layoutOverride == true
  and world.general_layout == "master", "explicit workspace Tiled choice was dropped under custom default")
ws.set_layout(1, "default")
check(snapshot_row(ws, 1).layout == "unmanaged" and not snapshot_row(ws, 1).layoutManaged
  and snapshot_row(ws, 1).layoutOverride == false, "reset failed to restore native inheritance")
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
local rules_before_refresh = #world.rules
ws.refresh()
check(#world.rules == rules_before_refresh, "unchanged preferences rebuilt native layout rules")
exclusions.title[#exclusions.title + 1] = "(?:^Extra dialog$)"
ws.refresh()
check(ws.snapshot.error == "" and exclusions.title.n == nil and #exclusions.title == 3,
  "native floating rule collection was mutated")
check(first.floating and floating.tagged(first, floating.FLOATED), "tiled window was not mode-owned")
check(independent.floating and not floating.tagged(independent, floating.FLOATED), "independent floating window was claimed")
check(not fullscreen.floating and fullscreen.fullscreen == 2, "fullscreen was disturbed")
check(floating.tagged(grouped1, floating.FLOATED) and floating.tagged(grouped2, floating.FLOATED), "not all group members were claimed before float")
ws.toggle_floating(grouped1.address); flush()
check(not grouped1.floating and not grouped2.floating
  and floating.tagged(grouped1, floating.USER) and floating.tagged(grouped2, floating.USER),
  "manual group tiling was reversed by another member's mode ownership")
ws = load(); flush()
check(not grouped1.floating and not grouped2.floating
  and not floating.tagged(grouped1, floating.FLOATED) and not floating.tagged(grouped2, floating.FLOATED),
  "reload reclaimed a manually tiled group")
ws.set_layout(1, "dwindle"); ws.set_layout(1, "floating")
check(grouped1.floating and grouped2.floating and floating.tagged(grouped1, floating.FLOATED)
  and floating.tagged(grouped2, floating.FLOATED), "new Floating selection could not reclaim the tiled group")
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
-- Explicit choices remain distinct from inheritance even when values match.
check(not snapshot_row(ws, 2).layoutOverride and snapshot_row(ws, 2).layoutManaged,
  "managed default was mislabeled as an explicit workspace override")
ws.set_layout(1, "dwindle")
ws.set_default_layout("dwindle")
check(snapshot_row(ws, 1).layoutOverride == true and snapshot_row(ws, 1).layout == "dwindle",
  "selecting a matching default deleted an existing explicit Tiled choice")
ws = load(); ws.set_default_layout("floating")
check(snapshot_row(ws, 1).layoutOverride == true and snapshot_row(ws, 1).layout == "dwindle"
  and snapshot_row(ws, 2).layoutOverride == false and snapshot_row(ws, 2).layout == "floating",
  "default change altered explicit Tiled choice or missed an inherited workspace")
ws.set_layout(1, "default")
check(snapshot_row(ws, 1).layoutOverride == false and snapshot_row(ws, 1).layout == "floating"
  and snapshot_row(ws, 1).layoutManaged, "default reset did not restore managed inheritance")
ws.set_layout(1, "floating")
check(snapshot_row(ws, 1).layoutOverride == true, "explicit choice equal to current default was omitted")
ws = load(); ws.set_default_layout("dwindle")
check(snapshot_row(ws, 1).layoutOverride == true and snapshot_row(ws, 1).layout == "floating"
  and snapshot_row(ws, 2).layoutOverride == false and snapshot_row(ws, 2).layout == "dwindle",
  "reload/default edit lost an explicit choice equal to its previous default")
local recorded_preferences = assert(data.read(ws.path, function(value) return value end))
check(recorded_preferences.layouts["1"] == "floating" and recorded_preferences.layouts["2"] == nil,
  "persistence did not distinguish explicit choice from inherited default")
ws.set_layout(1, "default"); ws = load(); ws.set_default_layout("floating")
check(snapshot_row(ws, 1).layoutOverride == false and snapshot_row(ws, 1).layout == "floating",
  "explicit default reset did not survive reload and later default change")
-- R15: Hyprland's native selector boundary differs from our numbered policy.
-- Rename without a refresh before opening: a snapshot-filtered range could
-- still be stale here, and adding n[false] would not exclude this workspace.
local renamed = workspace(1)
renamed.name, renamed.tiled_layout = "research", "master"
local native_named = { id = -1337, name = "native-research", monitor = internal, windows = 0, tiled_layout = "scrolling" }
local numeric_named = { id = -1338, name = "1", monitor = internal, windows = 0, tiled_layout = "master" }
world.workspaces[#world.workspaces + 1], world.workspaces[#world.workspaces + 2] = native_named, numeric_named
check(matches_workspace("r[1-20] n[false]", renamed) and not model.regular(renamed),
  "fixture incorrectly treated n[false] as excluding renamed positive IDs")
check(matches_workspace("name:research", renamed) and matches_workspace("n[true]", native_named)
  and matches_workspace("name:1", numeric_named) and not matches_workspace("n[false]", numeric_named),
  "fixture lost native named/name selector semantics")
local research_client = open_window("0xd150", renamed)
check(not research_client.floating and not floating.tagged(research_client, floating.FLOATED)
  and not floating.tagged(research_client, floating.OPENED) and not floating.tagged(research_client, floating.FLOATING),
  "R15: default Floating floated an unowned client on a renamed positive-ID workspace")
local named_client = open_window("0xd151", native_named)
local numeric_client = open_window("0xd152", numeric_named)
local special_client = open_window("0xd153", special)
local named_floater = open_window("0xd154", renamed, { floating = true })
flush(); ws.set_default_layout("dwindle"); ws = load(); flush()
check(not research_client.floating and not named_client.floating and not numeric_client.floating and not special_client.floating
  and named_floater.floating and not floating.tagged(named_floater, floating.FLOATED),
  "default transition/reload changed native named/special floating state")
check(renamed.tiled_layout == "master" and native_named.tiled_layout == "scrolling" and numeric_named.tiled_layout == "master",
  "opening ownership changed a named workspace's native layout")
check(first.floating and not floating.tagged(first, floating.FLOATING),
  "leaving the numbered namespace tiled an existing window or retained its Floating titlebar tag")
renamed.name = "1"; emit("config.props_refreshed")
check(not first.floating and not floating.tagged(first, floating.FLOATED),
  "returning to a numbered Tiled workspace stranded its original mode-owned float")
-- Saved numeric overrides are suspended, rather than erased, by a rename.
local function native_override(target)
  for _, handle in ipairs(world.rules) do
    if handle.enabled and handle.spec.workspace == tostring(target) and handle.spec.layout then return handle.spec.layout end
  end
end
ws.set_layout(1, "scrolling")
check(native_override(1) == "scrolling", "explicit numbered native layout was not installed")
renamed.name = "research"; emit("config.props_refreshed")
check(native_override(1) == nil and renamed.tiled_layout == "master", "renamed ID retained a numbered native layout rule")
ws = load(); ws.set_default_layout("floating")
local saved_override = assert(data.read(ws.path, function(value) return value end))
check(native_override(1) == nil and saved_override.layouts["1"] == "scrolling",
  "reload/default change applied or discarded a suspended numbered override")
renamed.name = "1"; emit("config.props_refreshed")
check(native_override(1) == "scrolling" and snapshot_row(ws, 1).layoutOverride,
  "returning to the numbered namespace lost its explicit layout")
-- Opening obeys explicit overrides and completes before the deferred refresh.
ws.set_layout(1, "dwindle")
local tiled_open = open_window("0xd155", renamed)
check(not tiled_open.floating and not floating.tagged(tiled_open, floating.FLOATED),
  "default Floating overrode an explicit Tiled opening")
flush(); ws.set_layout(1, "scrolling")
local scrolling_open = open_window("0xd156", renamed)
check(not scrolling_open.floating, "default Floating overrode an explicit Scrolling opening")
flush(); ws.set_layout(1, "floating"); ws.set_default_layout("dwindle")
local regular_open = open_window("0xd157", renamed)
check(regular_open.floating and floating.tagged(regular_open, floating.FLOATED)
  and floating.tagged(regular_open, floating.FLOATING) and not floating.tagged(regular_open, floating.OPENED),
  "explicit Floating did not claim/decorate a new client before the mapping callback returned")
local app_open = open_window("0xd158", renamed, { floating = true, class = "cybex", title = "Cybex OS Settings" })
local dialog_open = open_window("0xd159", renamed, { floating = true, modal = true })
local full_open = open_window("0xd15a", renamed, { fullscreen = 2 })
local pinned_open = open_window("0xd15b", renamed, { floating = true, pinned = true })
check(app_open.floating and dialog_open.floating and not floating.tagged(app_open, floating.FLOATED)
  and not floating.tagged(dialog_open, floating.FLOATED) and app_open.at.x == 20 and dialog_open.size.x == 900,
  "synchronous opening claimed/repositioned native app floaters or dialogs")
check(not full_open.floating and full_open.fullscreen == 2 and pinned_open.floating
  and not floating.tagged(pinned_open, floating.FLOATED), "opening disturbed fullscreen/pinned state")
ws.toggle_floating(regular_open.address); flush(); ws = load(); flush()
check(not regular_open.floating and floating.tagged(regular_open, floating.USER)
  and not floating.tagged(regular_open, floating.FLOATED), "reload reversed a new client's explicit manual tiling")
ws.set_layout(1, "default")
check(not regular_open.floating and app_open.floating and dialog_open.floating,
  "returning to Tiled changed independent opening floaters")
ws.set_default_layout("floating")
local parent_open = open_window("0xd15c", renamed); flush()
local child_open = window("0xd15d", renamed, { floating = true })
local opening_group = { members = { parent_open, child_open } }
parent_open.group, child_open.group = opening_group, opening_group
deliver("window.open", child_open)
check(floating.tagged(child_open, floating.FLOATED) and floating.tagged(child_open, floating.FLOATING),
  "native automatic grouping stranded a newly floated member without ownership")
for i, win in ipairs(world.windows) do if win == parent_open then table.remove(world.windows, i); break end end
opening_group.members = { child_open }; count_windows(); emit("window.close", parent_open)
ws = load(); ws.set_default_layout("dwindle")
check(not child_open.floating and not floating.tagged(child_open, floating.FLOATED),
  "closing the original group owner stranded the new member through reload/transition")
ws.set_default_layout("floating")
-- R16: openLate runs after native automatic grouping. A tiled new member must
-- inherit the group's manual choice before arrange can float the whole group.
local manual1, manual2 = window("0xd160", renamed), window("0xd161", renamed)
local manual_group = { members = { manual1, manual2 } }
manual1.group, manual2.group = manual_group, manual_group
ws.refresh(); ws.toggle_floating(manual1.address); flush()
local manual_tiled_open = window("0xd162", renamed, { group = manual_group })
manual_group.members[#manual_group.members + 1] = manual_tiled_open
deliver("window.open", manual_tiled_open)
check(not manual1.floating and not manual2.floating and not manual_tiled_open.floating
  and floating.tagged(manual_tiled_open, floating.USER) and not floating.tagged(manual_tiled_open, floating.FLOATED),
  "R16: opening a grouped client reversed the group's manual tiling")
flush(); ws = load(); flush()
for _, member in ipairs(manual_group.members) do
  check(not member.floating and floating.tagged(member, floating.USER) and not floating.tagged(member, floating.FLOATED),
    "reload reclaimed a manually tiled group after opening a new member")
end
ws.toggle_floating(manual1.address); flush()
local manual_floating_open = window("0xd163", renamed, { floating = true, group = manual_group })
manual_group.members[#manual_group.members + 1] = manual_floating_open
deliver("window.open", manual_floating_open)
check(manual_floating_open.floating and floating.tagged(manual_floating_open, floating.USER)
  and not floating.tagged(manual_floating_open, floating.FLOATED),
  "opening a member of a manually floating group failed to inherit the manual choice")
flush(); ws = load(); flush()
for _, member in ipairs(manual_group.members) do
  check(member.floating and floating.tagged(member, floating.USER) and not floating.tagged(member, floating.FLOATED),
    "reload claimed a manually floating group after opening a new member")
end
ws.set_default_layout("dwindle")
for _, member in ipairs(manual_group.members) do
  check(member.floating and not floating.tagged(member, floating.FLOATED),
    "returning to Tiled changed a manually floating group's new member")
end
ws.set_default_layout("floating")
-- R18: origin provenance outlives a numbered workspace's name. New group
-- members must carry it through reload and back into the numbered namespace.
local named_manual_owner = open_window("0xd180", renamed); flush()
local named_manual_group = { members = { named_manual_owner } }
named_manual_owner.group = named_manual_group
ws.toggle_floating(named_manual_owner.address); flush()
renamed.name = "research-r18-manual"; emit("config.props_refreshed")
local named_manual_child = window("0xd181", renamed, { group = named_manual_group })
named_manual_group.members[#named_manual_group.members + 1] = named_manual_child
deliver("window.open", named_manual_child)
check(not named_manual_child.floating and floating.tagged(named_manual_child, floating.USER)
  and not floating.tagged(named_manual_child, floating.FLOATED) and not floating.tagged(named_manual_child, floating.FLOATING),
  "R18: new named group member lost its original group's manual tiling provenance")
flush(); ws = load(); flush()
renamed.name = "1"; emit("config.props_refreshed")
for _, member in ipairs(named_manual_group.members) do
  check(not member.floating and floating.tagged(member, floating.USER) and not floating.tagged(member, floating.FLOATED),
    "renumbering after reload reversed a named group's inherited manual choice")
end
for i, win in ipairs(world.windows) do if win == named_manual_owner then table.remove(world.windows, i); break end end
named_manual_group.members = { named_manual_child }; count_windows(); emit("window.close", named_manual_owner)
ws = load(); flush()
check(not named_manual_child.floating and floating.tagged(named_manual_child, floating.USER),
  "closing the original manual owner lost the named group's inherited choice through reload")
local named_mode_owner = open_window("0xd182", renamed); flush()
local named_mode_group = { members = { named_mode_owner } }
named_mode_owner.group = named_mode_group
renamed.name = "research-r18-mode"; emit("config.props_refreshed")
local named_mode_child = window("0xd183", renamed, { floating = true, group = named_mode_group,
  at = { x = 130, y = 170 }, size = { x = 500, y = 360 } })
named_mode_group.members[#named_mode_group.members + 1] = named_mode_child
deliver("window.open", named_mode_child)
check(named_mode_child.floating and floating.tagged(named_mode_child, floating.FLOATED)
  and not floating.tagged(named_mode_child, floating.USER) and not floating.tagged(named_mode_child, floating.FLOATING),
  "R18: new named group member lost its original group's mode provenance")
check(named_mode_child.at.x == 130 and named_mode_child.at.y == 170
  and named_mode_child.size.x == 500 and named_mode_child.size.y == 360,
  "inheriting mode provenance repositioned a named workspace's native floater")
local named_native_owner = open_window("0xd184", renamed, { floating = true })
local named_native_group = { members = { named_native_owner } }
named_native_owner.group = named_native_group
local named_native_child = window("0xd185", renamed, { floating = true, group = named_native_group })
named_native_group.members[#named_native_group.members + 1] = named_native_child
deliver("window.open", named_native_child)
for _, member in ipairs(named_native_group.members) do
  check(member.floating and not floating.tagged(member, floating.FLOATED)
    and not floating.tagged(member, floating.USER) and not floating.tagged(member, floating.FLOATING),
    "opening a named native floating group invented ownership or a Floating titlebar tag")
end
for i, win in ipairs(world.windows) do if win == named_mode_owner then table.remove(world.windows, i); break end end
named_mode_group.members = { named_mode_child }; count_windows(); emit("window.close", named_mode_owner)
ws = load(); flush()
check(named_mode_child.floating and floating.tagged(named_mode_child, floating.FLOATED)
  and not floating.tagged(named_mode_child, floating.FLOATING),
  "closing the original mode owner lost the named group's provenance through reload")
renamed.name = "1"; emit("config.props_refreshed"); ws.set_default_layout("dwindle")
check(not named_mode_child.floating and not floating.tagged(named_mode_child, floating.FLOATED),
  "returning a surviving named group member to numbered Tiled stranded its origin's mode float")
check(named_native_owner.floating and named_native_child.floating,
  "returning to numbered Tiled changed a named group's independent native floaters")
-- Layout provenance also survives other nonregular destinations. Exercise the
-- layout controller alone: minimize origin/session metadata stays with its
-- coordinator and is not manufactured by an opening ownership callback.
local origin_layout = floating.new(function() error("nonregular destination queried a managed layout") end)
local minimized_destination = { id = -99, name = "special:cybexos-minimized", special = true, monitor = internal }
for _, target in ipairs({ native_named, special, minimized_destination }) do
  for _, provenance in ipairs({ floating.USER, floating.FLOATED }) do
    local native_float = provenance == floating.FLOATED
    local owner = { workspace = target, floating = native_float, tags = { provenance, floating.FLOATING } }
    local child = { workspace = target, floating = native_float, tags = {} }
    local transient_group = { members = { owner, child } }; owner.group, child.group = transient_group, transient_group
    origin_layout:opened(child)
    check(child.floating == native_float and owner.floating == native_float and floating.tagged(child, provenance)
      and not floating.tagged(child, floating.FLOATING) and not floating.tagged(owner, floating.FLOATING),
      "nonregular destination changed native state or lost the group's origin provenance: " .. target.name)
  end
end
ws.set_default_layout("floating")
-- Installed plugins are declared on each parse, never on event/runtime edits.
local native_open = io.open
io.open = function(path, mode)
  if path == "/etc/cybexos/titlebars.so" then return { close = function() end } end
  return native_open(path, mode)
end
ws = load()
check(world.plugin_declarations == 1 and not ws.snapshot.capabilities.titlebars and world.plugin_buttons == 0,
  "declarative load accessed callbacks before the plugin registry was ready")
ws.set_default_layout("dwindle")
world.plugin_loaded = true; ws.refresh()
check(ws.snapshot.capabilities.titlebars and not world.plugin_rendering and world.plugin_buttons == 3,
  "loaded native titlebars were unavailable merely because the default was Tiled")
local config_writes, button_adds, button_clears = world.plugin_config_writes, world.plugin_button_adds, world.plugin_clears
ws.refresh(); emit("window.open", opened)
check(world.plugin_config_writes == config_writes and world.plugin_button_adds == button_adds
  and world.plugin_clears == button_clears, "unchanged Tiled events churned native setup/buttons")
local csd_rule
for _, handle in ipairs(world.rules) do if handle.enabled and handle.spec["hyprbars:no_bar"] then csd_rule = handle end end
check(csd_rule and csd_rule.spec.match.class == "^(org[.]gnome[.]Nautilus|org[.]gnome[.]TextEditor)$",
  "known CSD exclusion was missing or matched arbitrary clients")
ws.set_titlebars_enabled(false); ws.set_default_layout("floating")
check(ws.snapshot.capabilities.titlebars and not world.plugin_rendering and world.plugin_buttons == 3,
  "disabling Floating titlebars incorrectly removed native capability")
check(world.plugin_config_writes == config_writes and world.plugin_button_adds == button_adds
  and world.plugin_clears == button_clears, "disabled preferences repeated unchanged native setup")
ws = load()
check(not csd_rule.enabled, "reload leaked the previous dynamic CSD rule")
check(world.plugin_declarations == 2 and ws.snapshot.capabilities.titlebars and not world.plugin_rendering
  and world.plugin_buttons == 3, "disabled plugin lost declaration/capability or duplicated buttons on reload")
config_writes, button_adds, button_clears = world.plugin_config_writes, world.plugin_button_adds, world.plugin_clears
ws.set_titlebars_enabled(true)
check(ws.snapshot.capabilities.titlebars and world.plugin_rendering and world.plugin_buttons == 3,
  "available native titlebars did not render when Floating was enabled")
check(world.plugin_config_writes == config_writes + 1 and world.plugin_button_adds == button_adds
  and world.plugin_clears == button_clears, "rendering toggle rebuilt unchanged native buttons")
config_writes = world.plugin_config_writes
ws.set_default_layout("floating"); emit("window.open", opened); ws.refresh()
check(world.plugin_config_writes == config_writes and world.plugin_button_adds == button_adds
  and world.plugin_clears == button_clears, "unchanged Floating events churned native setup/buttons")
ws.refresh_theme()
check(world.plugin_declarations == 2 and ws.snapshot.capabilities.titlebars and world.plugin_buttons == 3
  and world.plugin_clears == button_clears + 1, "theme refresh reloaded the plugin or duplicated buttons")
-- Native failures must stay unavailable even when rendering is not requested.
world.plugin_config_failure = true; ws.set_titlebars_enabled(false); ws.set_default_layout("dwindle")
check(not ws.snapshot.capabilities.titlebars, "failed disabled native setup was reported available")
ws.set_titlebars_enabled(true); ws.set_default_layout("floating")
check(not ws.snapshot.capabilities.titlebars, "failed native setup reused a stale successful rendering cache")
world.plugin_config_failure = false; ws.set_titlebars_enabled(false); ws.set_default_layout("dwindle"); ws.refresh()
check(ws.snapshot.capabilities.titlebars and not world.plugin_rendering, "repaired native config did not recover while Tiled")
world.plugin_api_missing = true; ws.refresh()
check(not ws.snapshot.capabilities.titlebars, "loaded plugin with missing native API was reported usable")
world.plugin_api_missing = false; ws.refresh()
check(ws.snapshot.capabilities.titlebars and world.plugin_buttons == 3, "repaired native API did not reinitialize cleanly")
world.plugin_button_failure = true; ws.refresh_theme()
check(not ws.snapshot.capabilities.titlebars, "failed button setup was reported available while disabled")
world.plugin_button_failure = false; ws.refresh()
check(ws.snapshot.capabilities.titlebars and world.plugin_buttons == 3, "failed button setup recovery duplicated buttons")
local namespace_reads = world.plugin_namespace_reads
config_writes, button_adds, button_clears = world.plugin_config_writes, world.plugin_button_adds, world.plugin_clears
world.plugin_name = "unrelated"; ws.refresh()
check(not ws.snapshot.capabilities.titlebars and world.plugin_namespace_reads == namespace_reads
  and world.plugin_config_writes == config_writes and world.plugin_button_adds == button_adds
  and world.plugin_clears == button_clears, "unrelated registry entry enabled/accessed native titlebar APIs")
world.plugin_name = nil; world.plugin_loaded = false; ws.refresh(); ws = load()
check(world.plugin_declarations == 3 and not ws.snapshot.capabilities.titlebars
  and world.plugin_namespace_reads == namespace_reads and world.plugin_config_writes == config_writes,
  "installed ABI-incompatible/absent registry plugin was accessed or not declared on reload")
world.plugin_loaded = true; ws.refresh()
check(ws.snapshot.capabilities.titlebars and not world.plugin_rendering and world.plugin_buttons == 3,
  "native registry recovery reused stale setup or duplicated buttons")
ws.set_titlebars_enabled(true); ws.set_default_layout("floating")
check(world.plugin_declarations == 3 and ws.snapshot.capabilities.titlebars and world.plugin_rendering,
  "capability/rendering edits declared a runtime plugin load")
io.open, world.plugin_loaded = native_open, false
-- Old schema-v1 preferences retain managed semantics when the flag is absent.
local old_preferences = assert(data.read(ws.path, function(value) return value end)); old_preferences.manageDefaultLayout = nil
old_preferences.layouts["1"] = "dwindle"
check(data.write(ws.path, old_preferences), "could not prepare legacy v1 preference fixture")
ws = load()
check(ws.snapshot.defaultLayoutManaged and ws.snapshot.defaultLayout == "floating", "legacy explicit default lost ownership")
check(snapshot_row(ws, 1).layoutOverride == true and snapshot_row(ws, 1).layout == "dwindle"
  and snapshot_row(ws, 2).layoutOverride == false, "legacy sparse preferences lost recorded overrides or invented missing choices")
world.native_scrolling = false; ws = load()
check(not ws.snapshot.capabilities.scrolling, "missing scrolling capability was invented")
fails(function() ws.set_layout(1, "scrolling") end, "unavailable native layout was offered")
ws.cycle_layout(1)
check(snapshot_row(ws, 1).layout ~= "scrolling", "cycle selected unsupported scrolling")
-- The native verifier emits config.reloaded without an event loop. Keep all
-- declarations and the initial snapshot, but never call its unavailable timer.
local arguments = "Hyprland\0--verify-config\0"
io.open = function(path, mode)
  if path == "/proc/self/cmdline" then
    return { read = function() return arguments end, close = function() end }
  end
  return native_open(path, mode)
end
ws = load()
check(ws.snapshot and world.listeners["config.reloaded"], "verification skipped workspace declarations")
local native_timer = hl.timer
hl.timer = function() error("verifier has no event loop") end
emit("config.reloaded"); emit("config.props_refreshed")
check(ws.snapshot ~= nil, "verification lost its initial refresh")
hl.timer = native_timer
arguments = "Hyprland\0--verify-config-extra\0"
ws = load()
local timer_calls = 0
hl.timer = function(...) timer_calls = timer_calls + 1; return native_timer(...) end
emit("config.reloaded")
check(timer_calls > 0, "normal runtime scheduling was disabled by a partial flag match")
io.open, hl.timer = native_open, native_timer
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
