-- Pure identity/allocation policy. No compositor dispatch or filesystem access.
local data = require("workspace_state")
local M = { SLOTS = 10, MAX_MONITORS = 64, MAX_ID = 2147483646 }
local function object(value) assert(data.object(value), "expected an object"); return value end
local function text(value, length) assert(data.string(value, length), "invalid identity text"); return value end
function M.regular(workspace)
  return workspace and not workspace.special and data.integer(workspace.id, 1, M.MAX_ID)
    and (not workspace.name or workspace.name == tostring(workspace.id))
end
function M.validate(document)
  object(document)
  assert(document.v == 1, "unsupported assignments version")
  local rows = document.assignments
  assert(type(rows) == "table" and data.integer(rows.n, 0, M.MAX_MONITORS), "invalid assignments array")
  local identities, ids = {}, {}
  for _, row in ipairs(rows) do
    object(row)
    text(row.identity, 1600); text(row.fingerprint, 1536); text(row.connector, 128)
    assert(row.identity ~= "" and not identities[row.identity], "duplicate monitor identity")
    identities[row.identity] = true
    assert(type(row.slots) == "table" and row.slots.n == M.SLOTS, "invalid local workspace slots")
    for _, id in ipairs(row.slots) do
      assert(data.integer(id, 1, M.MAX_ID) and not ids[id], "duplicate or invalid workspace ID")
      ids[id] = true
    end
  end
  return document
end
local function clean(value)
  if type(value) ~= "string" then return "" end
  return value:gsub("[%z\1-\31\127]", ""):sub(1, 384):gsub("^%s+", ""):gsub("%s+$", "")
end
local function part(value) return #value .. ":" .. value end
function M.fingerprint(monitor)
  -- 0.56.2's HLMonitor exposes short description and serial, but no make/model.
  -- Short description excludes the serial and connector on the qualified API.
  local description, serial = clean(monitor.description), clean(monitor.serial)
  local lower = serial:lower()
  if lower == "unknown" or lower == "none" or lower == "null" or lower:match("^0+$") then serial = "" end
  if description == "" then description = serial ~= "" and "unknown-display" or clean(monitor.name) end
  return part(description) .. part(serial), serial == ""
end
function M.connected(monitors, gone)
  local result = {}
  for _, monitor in ipairs(monitors) do
    if not monitor.is_mirror and monitor.disabled ~= true and monitor.name ~= gone
        and data.string(monitor.name, 128) and monitor.name ~= "" then
      result[#result + 1] = monitor
    end
  end
  assert(#result <= M.MAX_MONITORS, "too many monitors")
  table.sort(result, function(a, b)
    local ai = a.name:match("^eDP") or a.name:match("^LVDS") or a.name:match("^DSI")
    local bi = b.name:match("^eDP") or b.name:match("^LVDS") or b.name:match("^DSI")
    if not not ai ~= not not bi then return not not ai end
    return a.name < b.name
  end)
  return result
end
function M.owner(assignments, id)
  for _, row in ipairs(assignments) do
    for local_number, owned in ipairs(row.slots) do
      if id == owned then return row, local_number end
    end
  end
end
-- Connector pins win while attached. Then saved connectors, then the sole
-- remaining matching identity; indistinguishable pairs use connector order.
-- No EDID can tell identical serial-less panels apart after both plugs move.
function M.assign(document, monitors, workspaces, previous)
  local rows, current, taken, fingerprints = document.assignments, {}, {}, {}
  local by_identity, used, occupied = {}, {}, {}
  for _, row in ipairs(rows) do
    by_identity[row.identity] = row
    for _, id in ipairs(row.slots) do used[id] = true end
  end
  for _, workspace in ipairs(workspaces) do
    if data.integer(workspace.id, 1, M.MAX_ID) then occupied[workspace.id] = workspace end
  end
  -- A user may rename an existing positive workspace. Its ID still occupies
  -- the global namespace, but it is no longer a numbered local slot. Leave
  -- the named workspace intact and allocate a replacement slot around it.
  local candidate = 1
  for _, row in ipairs(rows) do
    for number, owned in ipairs(row.slots) do
      if occupied[owned] and not M.regular(occupied[owned]) then
        while used[candidate] or occupied[candidate] do candidate = candidate + 1 end
        assert(candidate <= M.MAX_ID, "workspace IDs exhausted")
        row.slots[number], used[candidate] = candidate, true
      end
    end
  end
  for _, monitor in ipairs(monitors) do fingerprints[monitor.name] = M.fingerprint(monitor) end
  local function claim(monitor, row)
    if row and not taken[row.identity] and row.fingerprint == fingerprints[monitor.name] then
      current[monitor.name], taken[row.identity] = row, true
      row.connector = monitor.name
      return true
    end
  end
  for _, monitor in ipairs(monitors) do claim(monitor, by_identity[(previous or {})[monitor.name]]) end
  for _, monitor in ipairs(monitors) do
    if not current[monitor.name] then
      for _, row in ipairs(rows) do
        if row.connector == monitor.name and claim(monitor, row) then break end
      end
    end
  end
  for _, monitor in ipairs(monitors) do
    if not current[monitor.name] then
      local candidates = {}
      for _, row in ipairs(rows) do
        if row.fingerprint == fingerprints[monitor.name] and not taken[row.identity] then candidates[#candidates + 1] = row end
      end
      table.sort(candidates, function(a, b) return a.identity < b.identity end)
      claim(monitor, candidates[1])
    end
    if not current[monitor.name] then
      assert(#rows < M.MAX_MONITORS, "monitor assignment storage is full")
      local fingerprint, instance = fingerprints[monitor.name], 1
      while by_identity[fingerprint .. " #" .. instance] do instance = instance + 1 end
      local row = { identity = fingerprint .. " #" .. instance, fingerprint = fingerprint,
        connector = monitor.name, slots = data.array() }
      -- Adopt whole live workspaces only when they have no previous owner.
      local candidates = {}
      for id, workspace in pairs(occupied) do
        local name = type(workspace.monitor) == "string" and workspace.monitor or (workspace.monitor and workspace.monitor.name)
        if not used[id] and name == monitor.name and M.regular(workspace) then candidates[#candidates + 1] = id end
      end
      table.sort(candidates)
      for _, id in ipairs(candidates) do
        if #row.slots == M.SLOTS then break end
        row.slots[#row.slots + 1], used[id] = id, true
      end
      local candidate = 1
      while #row.slots < M.SLOTS do
        while used[candidate] or occupied[candidate] do candidate = candidate + 1 end
        assert(candidate <= M.MAX_ID, "workspace IDs exhausted")
        row.slots[#row.slots + 1], used[candidate] = candidate, true
      end
      row.slots.n = M.SLOTS
      rows[#rows + 1], rows.n = row, #rows + 1
      by_identity[row.identity] = row
      claim(monitor, row)
    end
  end
  return current
end
return M
