-- One compositor owner for workspace numbering, layout and minimized windows.
-- Personal configuration and runtime data contract: docs/customization.md.
local data = require("workspace_state")
local model = require("workspace_model")
local floating = require("workspace_layouts")
local M = {}
local home = os.getenv("HOME") or ""
local config = os.getenv("XDG_CONFIG_HOME") or (home .. "/.config")
local state_home = os.getenv("XDG_STATE_HOME") or (home .. "/.local/state")
local runtime = os.getenv("XDG_RUNTIME_DIR")
local session = os.getenv("HYPRLAND_INSTANCE_SIGNATURE") or ""
-- Hyprland's documented --verify-config parses declarations without creating
-- the event loop, but still emits config.reloaded. Calling hl.timer from that
-- event crashes 0.56.2. Only timer scheduling is inapplicable in this mode;
-- module loading, configuration declarations and initial refresh still run.
local verify_config = false
do
  local process = io.open("/proc/self/cmdline", "rb")
  if process then
    local arguments = process:read(65536) or ""
    process:close()
    for argument in arguments:gmatch("[^%z]+") do
      if argument == "--verify-config" then verify_config = true; break end
    end
  end
end
M.path = config .. "/cybexos/workspaces.json"
M.assignments_path = state_home .. "/cybexos/workspace-assignments.json"
M.snapshot_path = runtime and runtime .. "/cybexos/workspaces.json" or nil
M.session_path = runtime and runtime .. "/cybexos/workspace-session.json" or nil
local MINIMIZED = "special:cybexos-minimized"
local MIN_TAG = "cybexos-minimized-"
local valid_layout = { dwindle = true, scrolling = true, floating = true }
local function id(value) return data.integer(value, 1, model.MAX_ID) end
local function address(value)
  return type(value) == "string" and #value >= 3 and #value <= 18 and value:match("^0x%x+$") ~= nil
end
local function validate_preferences(document)
  assert(data.object(document) and document.v == 1, "unsupported workspace preferences")
  assert(document.mode == "shared" or document.mode == "per-monitor", "invalid workspace mode")
  assert(valid_layout[document.defaultLayout], "invalid default layout")
  assert(document.manageDefaultLayout == nil or type(document.manageDefaultLayout) == "boolean", "invalid default layout ownership")
  -- Earlier v1 files already represented a deliberate managed preference.
  if document.manageDefaultLayout == nil then document.manageDefaultLayout = true end
  assert(type(document.titlebarsEnabled) == "boolean", "invalid titlebar preference")
  assert(data.object(document.layouts), "invalid workspace layouts")
  local count = 0
  for key, layout in pairs(document.layouts) do
    count = count + 1
    assert(count <= 1024 and type(key) == "string" and key:match("^[1-9]%d*$")
      and id(tonumber(key)) and valid_layout[layout], "invalid workspace layout entry")
  end
  return document
end
local preferences, preference_error = data.read(M.path, validate_preferences)
preferences = preferences or { v = 1, mode = "shared", defaultLayout = "dwindle", manageDefaultLayout = false,
  titlebarsEnabled = true, layouts = {} }
local assignments, assignment_error = data.read(M.assignments_path, model.validate)
assignments = assignments or { v = 1, assignments = data.array() }
local previous = rawget(_G, "__cybexos_workspaces")
if previous and previous.retire then previous.retire() end
local state = { subscriptions = {}, rules = {}, current = {}, identities = {}, minimized = {},
  busy = false, pending = nil, retired = false, error = preference_error or assignment_error or "",
  capabilities = { scrolling = false, titlebars = false } }
_G.__cybexos_workspaces = state
-- Plugin loads are declarations: Hyprland clears its configured plugin list
-- on each config parse, then reloads if that list changed. Always declare an
-- installed optional plugin, even when currently disabled or already loaded.
-- Runtime refreshes only toggle rendering; they never load/unload a plugin.
do
  local file = io.open("/etc/cybexos/titlebars.so", "rb")
  if file then
    file:close()
    local ok, err = pcall(hl.plugin.load, "/etc/cybexos/titlebars.so")
    if not ok then state.error = "titlebar plugin unavailable: " .. tostring(err) end
  end
end
-- Capability checks query a registered native option; unknown layouts silently
-- fall back in Hyprland and must never be mistaken for scrolling support.
local scrolling_ok, scrolling_value = pcall(hl.get_config, "scrolling.column_width")
state.capabilities.scrolling = scrolling_ok and scrolling_value ~= nil
local function native_layout(value)
  return type(value) == "string" and #value <= 64 and value:match("^[%w_-]+$") and value or nil
end
local function native_default_layout()
  local ok, value = pcall(hl.get_config, "general.layout")
  return (ok and native_layout(value)) or "dwindle"
end
local function default_layout()
  if not preferences.manageDefaultLayout then return native_default_layout() end
  if preferences.defaultLayout == "scrolling" and not state.capabilities.scrolling then return "dwindle" end
  return preferences.defaultLayout
end
local layout = floating.new(function(workspace_id)
  local selected = preferences.layouts[tostring(workspace_id)]
  if not selected and not preferences.manageDefaultLayout then
    local workspace = hl.get_workspace(tostring(workspace_id))
    selected = workspace and native_layout(workspace.tiled_layout)
  end
  selected = selected or default_layout()
  if selected == "scrolling" and not state.capabilities.scrolling then return "dwindle" end
  return selected
end)
local function effective_layout(workspace_id) return layout.get_layout(workspace_id) end
local function monitors(gone) return model.connected(hl.get_monitors(), gone) end
local function monitor_name(value)
  return type(value) == "string" and value or (value and value.name)
end
local function get_workspace(workspace_id)
  -- Restrict numeric selectors before querying; negative IDs mean relative
  -- dispatch in Hyprland and named/special workspaces have separate semantics.
  if not id(workspace_id) then return nil end
  local workspace = hl.get_workspace(tostring(workspace_id))
  return model.regular(workspace) and workspace or nil
end
local function live_window(target)
  if target == nil then
    local window = hl.get_active_window()
    assert(window and address(window.address), "no focused window")
    target = window.address
  end
  assert(address(target), "invalid window address")
  -- A pointer-shaped string alone does not establish that the window exists.
  for _, window in ipairs(hl.get_windows()) do
    if window.address == target and window.mapped ~= false then return window end
  end
  error("window no longer exists", 0)
end
local function target_monitor(name)
  if name == nil then
    local current = hl.get_active_monitor()
    name = current and current.name
  end
  assert(type(name) == "string" and #name <= 128, "invalid monitor name")
  for _, monitor in ipairs(monitors()) do if monitor.name == name then return monitor end end
  error("monitor is not connected independently", 0)
end
local function disable_rules()
  for _, rule in ipairs(state.rules) do rule:set_enabled(false) end
  state.rules, state.rules_signature = {}, nil
end
function state.retire()
  state.retired = true
  for _, subscription in ipairs(state.subscriptions) do subscription:remove() end
  if state.pending and state.pending.set_enabled then state.pending:set_enabled(false) end
  disable_rules()
  if state.titlebar_csd_rule then state.titlebar_csd_rule:set_enabled(false) end
  layout:retire()
end
local function save_preferences(candidate)
  assert(not preference_error, "workspace preferences need repair: " .. tostring(preference_error))
  validate_preferences(candidate)
  local ok, err = data.write(M.path, candidate)
  assert(ok, "cannot save workspace preferences: " .. tostring(err))
  preferences = candidate
end
local function copy_preferences()
  local copy = { v = 1, mode = preferences.mode, defaultLayout = preferences.defaultLayout,
    manageDefaultLayout = preferences.manageDefaultLayout, titlebarsEnabled = preferences.titlebarsEnabled, layouts = {} }
  for key, value in pairs(preferences.layouts) do copy.layouts[key] = value end
  return copy
end
local function validate_geometry(value)
  if value == nil then return nil end
  assert(data.object(value), "invalid minimized geometry")
  for _, key in ipairs({ "x", "y", "width", "height" }) do
    assert(type(value[key]) == "number" and value[key] >= 0 and value[key] <= 1, "invalid geometry coordinate")
  end
  return value
end
local function validate_session(document)
  assert(data.object(document) and document.v == 1 and document.session == session, "old compositor session")
  assert(type(document.minimized) == "table" and data.integer(document.minimized.n, 0, 256), "invalid minimized array")
  local seen = {}
  for _, row in ipairs(document.minimized) do
    assert(data.object(row) and address(row.address) and id(row.workspace) and not seen[row.address], "invalid minimized window")
    assert(data.string(row.monitor, 128) and data.integer(row.pid, 0, 2147483647), "invalid minimized origin")
    assert(type(row.floating) == "boolean" and data.integer(row.fullscreen, 0, 3), "invalid minimized state")
    assert(row.fullscreenClient == nil or data.integer(row.fullscreenClient, 0, 3), "invalid minimized client state")
    validate_geometry(row.geometry)
    seen[row.address] = true
  end
  return document
end
local saved_session = data.read(M.session_path, validate_session)
if saved_session then
  for _, row in ipairs(saved_session.minimized) do state.minimized[row.address] = row end
end
local function save_session()
  local rows = data.array()
  for _, row in pairs(state.minimized) do rows[#rows + 1] = row end
  table.sort(rows, function(a, b) return a.address < b.address end)
  rows.n = #rows
  local ok, err = data.write(M.session_path, { v = 1, session = session, minimized = rows })
  if not ok then state.error = "cannot save minimized state: " .. tostring(err) end
end
local function minimized_origin(window)
  for _, tag in ipairs(window.tags or {}) do
    local saved = tag:match("^cybexos%-minimized%-(%d+)$")
    if saved and id(tonumber(saved)) then return tonumber(saved) end
  end
end
local function is_minimized(window)
  return window.workspace and window.workspace.name == MINIMIZED
end
local function reconcile_minimized()
  local seen, changed = {}, false
  for _, window in ipairs(hl.get_windows()) do
    local entry = state.minimized[window.address]
    if is_minimized(window) then
      local origin = minimized_origin(window)
      -- Tags die with a window and protect against recycled addresses or stale
      -- session files. An external move out of the hidden workspace restores it.
      if not entry or entry.pid ~= (window.pid or 0) or entry.workspace ~= origin then
        entry = { address = window.address, pid = window.pid or 0,
          workspace = origin or 1, monitor = monitor_name(window.monitor) or "", floating = window.floating == true,
          fullscreen = 0, geometry = floating.geometry(window) }
        state.minimized[window.address], changed = entry, true
      end
      seen[window.address] = true
    elseif entry then
      state.minimized[window.address], changed = nil, true
      floating.tag(window, MIN_TAG .. entry.workspace, false)
    end
  end
  for key in pairs(state.minimized) do
    if not seen[key] then state.minimized[key], changed = nil, true end
  end
  if changed then save_session() end
end
local function titlebars()
  state.capabilities.titlebars = false
  -- Accessing hl.plugin.NAME creates a namespace even when no plugin is
  -- loaded. Check the native registry before touching its Lua callbacks.
  local function loaded_plugin()
    for _, entry in ipairs(hl.get_loaded_plugins()) do
      if entry.name == "hyprbars" then return hl.plugin.hyprbars end
    end
    return nil
  end
  local plugin = loaded_plugin()
  -- This dynamic effect exists only after the plugin registers it. Exact
  -- known GTK application classes are a policy, not generic CSD detection.
  if plugin and not state.titlebar_csd_rule then
    state.titlebar_csd_rule = hl.window_rule({ name = "cybexos-titlebars-known-csd",
      match = { class = "^(org[.]gnome[.]Nautilus|org[.]gnome[.]TextEditor)$" }, ["hyprbars:no_bar"] = true })
  elseif not plugin and state.titlebar_csd_rule then
    state.titlebar_csd_rule:set_enabled(false)
    state.titlebar_csd_rule = nil
  end
  local wanted = preferences.manageDefaultLayout and preferences.defaultLayout == "floating"
  for _, selected in pairs(preferences.layouts) do if selected == "floating" then wanted = true end end
  if not plugin or type(plugin.add_button) ~= "function" then
    state.titlebars_signature, state.titlebars_rendering, state.buttons_added = nil, nil, false
    return
  end
  -- Native availability is independent of the user's rendering preference and
  -- current layouts. Configure once even when hidden to verify usable APIs.
  local rendering = preferences.titlebarsEnabled and wanted
  if not state.titlebar_theme then
    local theme_dir = os.getenv("CYBEXOS_THEME_STATE_DIR") or state_home .. "/cybexos/theme"
    state.titlebar_theme = data.read(theme_dir .. "/tokens.json", function(document)
      assert(data.object(document) and document.v == 1 and data.object(document.colors) and data.object(document.font))
      for _, key in ipairs({ "surfaceRaised", "text" }) do
        assert(type(document.colors[key]) == "string" and document.colors[key]:match("^#%x%x%x%x%x%x$"))
      end
      assert(type(document.font.ui) == "string" and #document.font.ui <= 64 and document.font.ui:match("^[%w ._+%-]+$"))
      return { background = "rgb(" .. document.colors.surfaceRaised:sub(2) .. ")",
        foreground = "rgb(" .. document.colors.text:sub(2) .. ")", font = document.font.ui,
        size = data.integer(document.font.size, 6, 96) and document.font.size or 14 }
    end) or {}
  end
  local colors = rawget(_G, "__cybexos_titlebar_colors") or state.titlebar_theme
  local background, foreground = colors.background or "rgb(292b31)", colors.foreground or "rgb(e4e4e7)"
  local signature = data.encode(colors)
  local theme_changed = signature ~= state.titlebars_signature
  if not theme_changed and rendering == state.titlebars_rendering then state.capabilities.titlebars = true; return end
  local ok, err = pcall(function()
    if not theme_changed then
      hl.config({ plugin = { hyprbars = { enabled = rendering } } })
      return
    end
    hl.config({ plugin = { hyprbars = { enabled = rendering, workspace_tag = floating.FLOATING,
      bar_height = 30, bar_color = background, col = { text = foreground },
      bar_text_font = colors.font or "sans-serif", bar_text_size = math.floor((colors.size or 14) * 12 / 14), bar_text_align = "left",
      bar_buttons_alignment = "right", bar_part_of_window = true,
      bar_precedence_over_border = true, bar_padding = 10, bar_button_padding = 8,
      on_double_click = [[hyprctl dispatch 'hl.dsp.window.fullscreen({mode="maximized",action="toggle",window="address:%WINDOW%"})']] } } })
    if plugin.clear_buttons then plugin.clear_buttons(); state.buttons_added = false end
    if not state.buttons_added then
      for _, button in ipairs({
        { "×", [[hyprctl dispatch 'hl.dsp.window.close({window="address:%WINDOW%"})']] },
        { "□", [[hyprctl dispatch 'hl.dsp.window.fullscreen({mode="maximized",action="toggle",window="address:%WINDOW%"})']] },
        { "−", [[hyprctl eval 'require("workspaces").minimize("%WINDOW%")']] },
      }) do plugin.add_button({ bg_color = background, fg_color = foreground, size = 20, icon = button[1], action = button[2] }) end
      state.buttons_added = true
    end
  end)
  state.capabilities.titlebars = ok
  if ok then state.titlebars_signature, state.titlebars_rendering = signature, rendering end
  if not ok then
    state.titlebars_signature, state.titlebars_rendering, state.buttons_added = nil, nil, false
    state.error = "titlebar setup failed: " .. tostring(err)
  end
end
local function write_snapshot()
  local all_monitors, monitor_rows, workspace_rows, minimized_rows = monitors(), data.array(), data.array(), data.array()
  local by_name, included = {}, {}
  local live = hl.get_workspaces()
  local function add(row, workspace_id, number, guest, owner)
    if included[workspace_id] then return end
    included[workspace_id] = true
    row.workspaces[#row.workspaces + 1] = workspace_id
    local selected = effective_layout(workspace_id)
    workspace_rows[#workspace_rows + 1] = { id = workspace_id, localNumber = number,
      monitor = row.name, label = guest and (tostring(workspace_id) .. " · " .. ((owner and owner.connector) or row.name)) or tostring(number),
      layout = valid_layout[selected] and selected or "unmanaged", nativeLayout = selected == "floating" and "dwindle" or selected,
      layoutManaged = preferences.manageDefaultLayout or preferences.layouts[tostring(workspace_id)] ~= nil,
      layoutOverride = preferences.layouts[tostring(workspace_id)] ~= nil,
      guest = guest, ownerIdentity = owner and owner.identity or "" }
  end
  for _, monitor in ipairs(all_monitors) do
    local assignment = state.current[monitor.name]
    local row = { name = monitor.name, identity = assignment and assignment.identity or "", label = monitor.description or monitor.name,
      activeWorkspace = monitor.active_workspace and monitor.active_workspace.id or 0, workspaces = data.array() }
    monitor_rows[#monitor_rows + 1], by_name[monitor.name] = row, row
    if preferences.mode == "per-monitor" and assignment then
      for number, workspace_id in ipairs(assignment.slots) do add(row, workspace_id, number, false, assignment) end
    end
  end
  table.sort(live, function(a, b) return a.id < b.id end)
  for _, workspace in ipairs(live) do
    if model.regular(workspace) and not included[workspace.id] then
      local row = by_name[monitor_name(workspace.monitor)] or monitor_rows[1]
      if row then
        local owner = model.owner(assignments.assignments, workspace.id)
        add(row, workspace.id, preferences.mode == "shared" and workspace.id or 0, preferences.mode ~= "shared", owner)
      end
    end
  end
  -- Shared mode retains the existing 1–10 targets even before they exist.
  if preferences.mode == "shared" and monitor_rows[1] then
    for workspace_id = 1, 10 do
      if not included[workspace_id] then add(monitor_rows[1], workspace_id, workspace_id, false) end
    end
  end
  for _, row in ipairs(monitor_rows) do row.workspaces.n = #row.workspaces end
  for _, entry in pairs(state.minimized) do
    minimized_rows[#minimized_rows + 1] = { address = entry.address, workspace = entry.workspace, monitor = entry.monitor }
  end
  table.sort(minimized_rows, function(a, b) return a.address < b.address end)
  monitor_rows.n, workspace_rows.n, minimized_rows.n = #monitor_rows, #workspace_rows, #minimized_rows
  local selected_default = default_layout()
  local snapshot = { v = 1, mode = preferences.mode, defaultLayout = valid_layout[selected_default] and selected_default or "unmanaged",
    defaultLayoutManaged = preferences.manageDefaultLayout, nativeDefaultLayout = native_default_layout(),
    titlebarsEnabled = preferences.titlebarsEnabled, capabilities = state.capabilities, error = state.error,
    monitors = monitor_rows, workspaces = workspace_rows, minimized = minimized_rows }
  M.snapshot = snapshot
  local serialized = data.encode(snapshot)
  if serialized ~= state.snapshot_serialized then
    local ok, err = data.write(M.snapshot_path, snapshot)
    if ok then state.snapshot_serialized = serialized else state.error = tostring(err) end
  end
end
local function sync_policy()
  _G.__cybexos_workspace_mode = preferences.mode
  local shared = rawget(_G, "__cybexos_workspace_policy")
  if shared and shared.apply then shared.apply() end
  -- Replace only the registered vendor swipe, preserving Touchpad opt-outs
  -- and any user.lua gesture that already retired it. Native workspace swipes
  -- cannot traverse our explicit local ID list (which need not be contiguous).
  local gestures = rawget(_G, "__cybexos_gestures")
  if gestures and gestures.remove and state.gesture_mode ~= preferences.mode and type(hl.gesture) == "function" then
    state.gesture_mode = preferences.mode
    if gestures.remove("workspace") then
      local spec = { fingers = 3, direction = "horizontal", action = "workspace" }
      if preferences.mode == "per-monitor" then
        local distance = 0
        spec.action = {
          start = function(event) distance = (event.delta and event.delta.x) or 0 end,
          update = function(event) distance = distance + ((event.delta and event.delta.x) or 0) end,
          finish = function(event)
            if not event.cancelled and math.abs(distance) >= 40 and not state.retired then
              local invert = hl.get_config("gestures.workspace_swipe_invert")
              M.next((distance < 0) ~= (invert == true or invert == 1) and 1 or -1)
            end
          end,
        }
      end
      hl.gesture(spec)
      gestures.active[#gestures.active + 1] = { name = "workspace", fingers = 3, direction = "horizontal" }
    end
  end
end
local function show(monitor, workspace_id)
  local workspace = get_workspace(workspace_id)
  if workspace and monitor_name(workspace.monitor) ~= monitor.name then
    hl.dispatch(hl.dsp.workspace.move({ workspace = tostring(workspace_id), monitor = monitor.name }))
    workspace = get_workspace(workspace_id)
  end
  if workspace and monitor.set_workspace then monitor:set_workspace({ workspace = tostring(workspace_id) })
  else
    hl.dispatch(hl.dsp.focus({ monitor = monitor.name }))
    hl.dispatch(hl.dsp.focus({ workspace = tostring(workspace_id) }))
  end
end
local function reconcile_ownership(gone)
  assert(not assignment_error, "monitor assignments need repair: " .. tostring(assignment_error))
  local connected = monitors(gone)
  if #connected == 0 then return end
  local live = hl.get_workspaces()
  state.current = model.assign(assignments, connected, live, state.identities)
  state.identities = {}
  local by_identity, by_name, signature, active = {}, {}, {}, {}
  for _, monitor in ipairs(connected) do
    local assignment = state.current[monitor.name]
    state.identities[monitor.name], by_identity[assignment.identity], by_name[monitor.name] = assignment.identity, monitor, monitor
    active[monitor.name] = monitor.active_workspace and monitor.active_workspace.id
    signature[#signature + 1] = monitor.name .. ":" .. assignment.identity .. ":" .. data.encode(assignment.slots)
  end
  local assignments_serialized = data.encode(assignments)
  if assignments_serialized ~= state.assignments_serialized then
    assert(not assignment_error, "monitor assignments need repair: " .. tostring(assignment_error))
    local ok, err = data.write(M.assignments_path, assignments)
    assert(ok, "cannot persist monitor assignment: " .. tostring(err))
    state.assignments_serialized = assignments_serialized
  end
  signature = table.concat(signature, "\n")
  if signature ~= state.rules_signature then
    disable_rules()
    state.rules_signature = signature
    for _, monitor in ipairs(connected) do
      for _, workspace_id in ipairs(state.current[monitor.name].slots) do
        state.rules[#state.rules + 1] = hl.workspace_rule({ workspace = tostring(workspace_id), monitor = monitor.name })
      end
    end
  end
  local focused = hl.get_active_monitor()
  local focused_name = focused and focused.name
  for _, workspace in ipairs(live) do
    if model.regular(workspace) then
      local owner = model.owner(assignments.assignments, workspace.id)
      local destination = owner and by_identity[owner.identity]
      local source_name = monitor_name(workspace.monitor)
      -- An offline owner stays a guest with its ID. Explicitly rescue even if
      -- Hyprland still reports a disabled/lid-closed source for this event.
      destination = destination or (not by_name[source_name] and connected[1] or nil)
      if destination and source_name ~= destination.name then
        hl.dispatch(hl.dsp.workspace.move({ workspace = tostring(workspace.id), monitor = destination.name }))
      end
    end
  end
  -- Restore each output's own previously visible workspace without the focus
  -- dispatcher's cross-output swap semantics. Moving a visible guest home only
  -- replaces that guest on the source; unrelated active workspaces stay put.
  for _, monitor in ipairs(connected) do
    local wanted = active[monitor.name]
    local workspace = wanted and get_workspace(wanted)
    if not workspace or monitor_name(workspace.monitor) ~= monitor.name then
      local current = monitor.active_workspace
      if model.regular(current) and monitor_name(current.monitor) == monitor.name then
        local owner = model.owner(assignments.assignments, current.id)
        if not owner or not by_identity[owner.identity] or owner == state.current[monitor.name] then wanted = current.id
        else wanted = state.current[monitor.name].slots[1] end
      else wanted = state.current[monitor.name].slots[1] end
      workspace = get_workspace(wanted)
    end
    if model.regular(monitor.active_workspace) and wanted ~= monitor.active_workspace.id then show(monitor, wanted) end
  end
  if focused_name and by_name[focused_name] then hl.dispatch(hl.dsp.focus({ monitor = focused_name })) end
end
local refresh
refresh = function(gone)
  if state.retired or state.busy then return end
  state.busy = true
  local ok, err = pcall(function()
    sync_policy()
    if preferences.mode == "per-monitor" then reconcile_ownership(gone) else disable_rules() end
    layout:sync_rules(preferences)
    layout:arrange(hl.get_windows())
    reconcile_minimized()
    titlebars()
  end)
  if not ok then state.error = tostring(err) end
  state.busy = false
  write_snapshot()
end
function M.refresh() refresh() end
function M.refresh_theme()
  state.titlebar_theme, state.titlebars_signature = nil, nil
  refresh()
end
local function schedule()
  if verify_config or state.busy or state.retired or state.pending then return end
  state.pending = hl.timer(function()
    state.pending = nil
    if not state.retired then refresh() end
  end, { type = "oneshot", timeout = 1 })
end
local function destination(workspace_id)
  assert(id(workspace_id), "invalid regular workspace ID")
  local existing = hl.get_workspace(tostring(workspace_id))
  assert(not existing or model.regular(existing), "named workspaces have separate navigation")
  local live = get_workspace(workspace_id)
  local owner = model.owner(assignments.assignments, workspace_id)
  assert(live or owner or (preferences.mode == "shared" and workspace_id <= 10), "workspace no longer exists")
  if preferences.mode == "per-monitor" and owner then
    for name, assignment in pairs(state.current) do
      if owner.identity == assignment.identity then return target_monitor(name), workspace_id end
    end
    if live then return target_monitor(monitor_name(live.monitor)), workspace_id end
    return target_monitor(), workspace_id -- create an offline owner's reachable guest
  end
  return live and target_monitor(monitor_name(live.monitor)) or target_monitor(), workspace_id
end
function M.focus_id(workspace_id)
  local monitor, target = destination(workspace_id)
  show(monitor, target)
  hl.dispatch(hl.dsp.focus({ monitor = monitor.name }))
  refresh()
end
function M.focus(number, name)
  assert(data.integer(number, 1, 10), "local workspace number must be 1–10")
  local monitor = target_monitor(name)
  if preferences.mode == "per-monitor" then
    local assignment = assert(state.current[monitor.name], "monitor mapping not ready")
    M.focus_id(assignment.slots[number])
  else
    hl.dispatch(hl.dsp.focus({ monitor = monitor.name }))
    hl.dispatch(hl.dsp.focus({ workspace = tostring(number) }))
    refresh()
  end
end
local function perform_move(window, workspace_id, monitor)
  if monitor and get_workspace(workspace_id) == nil then
    -- A workspace rule creates the new destination on its intended output;
    -- Shared's caller has no rule and may select an output explicitly.
    if preferences.mode == "shared" then show(monitor, workspace_id) end
  end
  hl.dispatch(hl.dsp.window.move({ window = window, workspace = tostring(workspace_id), follow = false }))
  schedule()
end
function M.move_id(target, workspace_id)
  local window = live_window(target)
  local monitor, selected = destination(workspace_id)
  if is_minimized(window) then M.restore(window.address); window = live_window(window.address) end
  perform_move(window, selected, monitor)
end
function M.move(target, number, name)
  assert(data.integer(number, 1, 10), "local workspace number must be 1–10")
  local window, monitor = live_window(target), target_monitor(name)
  local selected = number
  if preferences.mode == "per-monitor" then selected = assert(state.current[monitor.name], "monitor mapping not ready").slots[number] end
  if is_minimized(window) then M.restore(window.address); window = live_window(window.address) end
  perform_move(window, selected, monitor)
end
function M.next(direction, name)
  assert(direction == 1 or direction == -1, "direction must be -1 or 1")
  local monitor = target_monitor(name)
  if preferences.mode == "shared" then
    hl.dispatch(hl.dsp.focus({ monitor = monitor.name }))
    hl.dispatch(hl.dsp.focus({ workspace = direction > 0 and "e+1" or "e-1" }))
    refresh(); return
  end
  local row
  for _, item in ipairs(M.snapshot.monitors) do if item.name == monitor.name then row = item; break end end
  assert(row and #row.workspaces > 0, "monitor mapping not ready")
  local position = 1
  for index, workspace_id in ipairs(row.workspaces) do if workspace_id == row.activeWorkspace then position = index; break end end
  M.focus_id(row.workspaces[(position - 1 + direction) % #row.workspaces + 1])
end
function M.new_workspace(name)
  local monitor = target_monitor(name)
  if preferences.mode == "per-monitor" then
    for _, workspace_id in ipairs(assert(state.current[monitor.name]).slots) do
      local live = get_workspace(workspace_id)
      if not live or (live.windows or 0) == 0 then M.focus_id(workspace_id); return workspace_id end
    end
    error("all ten local workspaces are occupied", 0)
  end
  local occupied = {}
  for _, workspace in ipairs(hl.get_workspaces()) do
    if id(workspace.id) then occupied[workspace.id] = true end
  end
  local selected = 1
  while occupied[selected] do selected = selected + 1 end
  assert(id(selected), "workspace IDs exhausted")
  show(monitor, selected); refresh(); return selected
end
function M.set_mode(mode)
  assert(mode == "shared" or mode == "per-monitor", "invalid workspace mode")
  assert(mode ~= "per-monitor" or not assignment_error, "monitor assignments need repair: " .. tostring(assignment_error))
  if preferences.mode ~= mode then local next_preferences = copy_preferences(); next_preferences.mode = mode; save_preferences(next_preferences) end
  refresh()
end
local function check_layout(value)
  assert(valid_layout[value], "invalid workspace layout")
  assert(value ~= "scrolling" or state.capabilities.scrolling, "native scrolling is unavailable")
end
function M.set_default_layout(value)
  check_layout(value)
  local candidate = copy_preferences(); candidate.defaultLayout, candidate.manageDefaultLayout = value, true
  save_preferences(candidate); refresh()
end
local function layout_id(workspace_id)
  if workspace_id == nil then
    local workspace = hl.get_active_workspace()
    assert(model.regular(workspace), "layouts require a regular numbered workspace")
    workspace_id = workspace.id
  end
  destination(workspace_id)
  return workspace_id
end
function M.set_layout(workspace_id, value)
  if value ~= "default" then check_layout(value) end
  workspace_id = layout_id(workspace_id)
  local candidate = copy_preferences()
  candidate.layouts[tostring(workspace_id)] = nil
  if value ~= "default" then candidate.layouts[tostring(workspace_id)] = value end
  save_preferences(candidate); refresh()
end
function M.cycle_layout(workspace_id)
  workspace_id = layout_id(workspace_id)
  local order = state.capabilities.scrolling and { "dwindle", "scrolling", "floating" } or { "dwindle", "floating" }
  local current = effective_layout(workspace_id)
  for i, value in ipairs(order) do if current == value then M.set_layout(workspace_id, order[i % #order + 1]); return end end
  M.set_layout(workspace_id, order[1])
end
function M.set_titlebars_enabled(enabled)
  assert(type(enabled) == "boolean", "invalid titlebar switch")
  local candidate = copy_preferences(); candidate.titlebarsEnabled = enabled
  save_preferences(candidate); refresh()
end
function M.toggle_floating(target)
  local window = live_window(target)
  local members = window.group and window.group.members or { window }
  assert(type(members) == "table", "cannot inspect window group")
  -- The compositor toggles the whole group. Release every member before the
  -- dispatch so no remaining mode-owned member can immediately float it back.
  for _, member in ipairs(members) do
    floating.tag(member, floating.FLOATED, false)
    floating.tag(member, floating.USER, true)
  end
  hl.dispatch(hl.dsp.window.float({ action = "toggle", window = window }))
  schedule()
end
function M.minimize(target)
  local window = live_window(target)
  if is_minimized(window) then return end
  assert(model.regular(window.workspace), "minimize requires a regular numbered workspace")
  assert(not window.pinned, "unpin the window before minimizing")
  local members = window.group and window.group.members or { window }
  assert(type(members) == "table", "cannot inspect window group")
  local count = 0; for _ in pairs(state.minimized) do count = count + 1 end
  assert(count + #members <= 256, "too many minimized windows")
  -- Record all members before the compositor propagates a group move.
  for _, member in ipairs(members) do
    assert(model.regular(member.workspace) and not member.pinned, "cannot minimize this group")
    local row = { address = member.address, pid = member.pid or 0, workspace = member.workspace.id,
      monitor = monitor_name(member.monitor) or "", floating = member.floating == true,
      fullscreen = member.fullscreen or 0, geometry = floating.geometry(member) }
    row.fullscreenClient = member.fullscreen_client or row.fullscreen
    state.minimized[member.address] = row
    floating.tag(member, MIN_TAG .. row.workspace, true)
  end
  save_session()
  -- Preserve fullscreen for restore; moving a fullscreen group directly into
  -- the special workspace otherwise makes a hidden fullscreen surface active.
  for _, member in ipairs(members) do
    if (member.fullscreen or 0) ~= 0 then
      hl.dispatch(hl.dsp.window.fullscreen_state({ internal = 0, client = 0, action = "set", window = member }))
    end
  end
  hl.dispatch(hl.dsp.window.move({ workspace = MINIMIZED, follow = false, window = window }))
  refresh()
end
function M.restore(target)
  local window = live_window(target)
  if not is_minimized(window) then return end
  local row = state.minimized[window.address]
  assert(row and row.pid == (window.pid or 0) and minimized_origin(window) == row.workspace, "minimized window origin unavailable")
  local monitor
  for _, item in ipairs(monitors()) do if item.name == row.monitor then monitor = item end end
  local owner = model.owner(assignments.assignments, row.workspace)
  if preferences.mode == "per-monitor" and owner then
    for name, assigned in pairs(state.current) do if owner.identity == assigned.identity then monitor = target_monitor(name) end end
  end
  monitor = monitor or target_monitor()
  local members = window.group and window.group.members or { window }
  local records = {}
  for _, member in ipairs(members) do records[member.address] = state.minimized[member.address] end
  if not get_workspace(row.workspace) then show(monitor, row.workspace) end
  hl.dispatch(hl.dsp.window.move({ workspace = tostring(row.workspace), follow = false, window = window }))
  for _, member in ipairs(members) do
    local saved = records[member.address]
    if saved then
      floating.tag(member, MIN_TAG .. saved.workspace, false)
      state.minimized[member.address] = nil
    end
  end
  layout:arrange(members)
  if window.floating and row.geometry then floating.place(window, row.geometry) end
  if row.fullscreen ~= 0 then
    hl.dispatch(hl.dsp.window.fullscreen_state({ internal = row.fullscreen, client = row.fullscreenClient or row.fullscreen, action = "set", window = window }))
  end
  save_session(); refresh()
end
function M.activate(target)
  local window = live_window(target)
  if is_minimized(window) then M.restore(window.address); window = live_window(window.address) end
  hl.dispatch(hl.dsp.focus({ window = window }))
  refresh()
end
function M.restore_last()
  local selected
  for _, entry in pairs(state.minimized) do if not selected or entry.address > selected then selected = entry.address end end
  assert(selected, "no minimized window")
  M.activate(selected)
end
function M.move_monitor(direction, target)
  local allowed = { left = true, right = true, up = true, down = true, next = true, previous = true }
  assert(allowed[direction], "invalid display direction")
  local window, connected = live_window(target), monitors()
  assert(#connected > 1, "no other independent display")
  local source_name = monitor_name(window.monitor)
  local source = target_monitor(source_name)
  local selected
  if direction == "next" or direction == "previous" then
    local index = 1
    for i, monitor in ipairs(connected) do if monitor.name == source_name then index = i end end
    selected = connected[(index - 1 + (direction == "next" and 1 or -1)) % #connected + 1]
  else
    local from = floating.bounds(source)
    local best
    for _, monitor in ipairs(connected) do
      if monitor.name ~= source_name then
        local bounds = floating.bounds(monitor)
        local dx, dy = bounds.x + bounds.width / 2 - from.x - from.width / 2,
          bounds.y + bounds.height / 2 - from.y - from.height / 2
        local axis = (direction == "left" and -dx) or (direction == "right" and dx)
          or (direction == "up" and -dy) or dy
        if axis > 0 then
          local score = dx * dx + dy * dy
          if not best or score < best then selected, best = monitor, score end
        end
      end
    end
  end
  assert(selected, "no display in that direction")
  if is_minimized(window) then M.restore(window.address); window = live_window(window.address) end
  local workspace = selected.active_workspace
  local target_id = model.regular(workspace) and workspace.id or nil
  if preferences.mode == "per-monitor" then
    local assignment = assert(state.current[selected.name], "monitor mapping not ready")
    local owner = target_id and model.owner(assignments.assignments, target_id)
    if not target_id or owner ~= assignment then target_id = assignment.slots[1] end
  end
  assert(target_id, "target display has no regular workspace")
  local geometry = window.floating and floating.geometry(window) or nil
  perform_move(window, target_id, selected)
  -- Move event finishes asynchronously; geometry belongs to the target bounds.
  hl.timer(function()
    if state.retired then return end
    local ok, moved = pcall(live_window, window.address)
    if ok and moved.floating and geometry then floating.place(moved, geometry) end
    refresh()
  end, { type = "oneshot", timeout = 1 })
end
for _, event in ipairs({ "monitor.layout_changed", "monitor.added", "monitor.focused", "workspace.active",
  "workspace.created", "workspace.removed", "workspace.move_to_monitor", "window.close",
  "window.move_to_workspace", "window.fullscreen", "window.pin", "config.reloaded", "config.props_refreshed", "hyprland.start" }) do
  state.subscriptions[#state.subscriptions + 1] = hl.on(event, schedule)
end
state.subscriptions[#state.subscriptions + 1] = hl.on("window.open", function(window)
  -- Qualified 0.56.2 emits this at openLate, with native float/dialog rules,
  -- grouping and the layout target established, before mapWindow returns.
  -- Float synchronously before rendering instead of using an ID-range rule:
  -- r[] and even n[false] also match renamed positive-ID workspaces.
  if not state.retired and not state.busy then layout:opened(window) end
  schedule()
end)
state.subscriptions[#state.subscriptions + 1] = hl.on("monitor.removed", function(monitor)
  refresh(monitor and monitor.name)
  schedule()
end)
refresh()
return M
