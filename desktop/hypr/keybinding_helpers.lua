-- Pure key identities and resolution. Keep these rules in step with the
-- editor's draft preview; the shared vectors exercise both implementations.
local M = {}
local mods = { "SUPER", "CTRL", "ALT", "SHIFT" }
local modifier = { SUPER = true, CTRL = true, ALT = true, SHIFT = true }
function M.normalize(value)
  if type(value) ~= "string" or #value > 128 then return "" end
  local parts, seen = {}, {}
  for part in (value .. "+"):gmatch("(.-)%+") do
    part = part:match("^%s*(.-)%s*$")
    parts[#parts + 1] = part
  end
  local key = table.remove(parts)
  if not key or key == "" or modifier[key:upper()] then return "" end
  if not key:match("^[A-Za-z0-9_]+$") and not key:lower():match("^code:%d+$")
      and not key:lower():match("^mouse:%d+$") then return "" end
  for _, part in ipairs(parts) do
    if not modifier[part:upper()] then return "" end
    seen[part:upper()] = true
  end
  local out = {}
  for _, mod in ipairs(mods) do if seen[mod] then out[#out + 1] = mod end end
  if #key == 1 then key = key:upper()
  elseif key:lower():match("^code:") or key:lower():match("^mouse:") then key = key:lower() end
  out[#out + 1] = key
  return table.concat(out, " + ")
end
function M.same(a, b)
  local left, right = M.normalize(a), M.normalize(b)
  return left ~= "" and left:lower() == right:lower()
end
local function copy_keys(keys)
  local out = {}
  for _, key in ipairs(keys or {}) do out[#out + 1] = M.normalize(key) end
  return out
end
local function contains(keys, key)
  for _, candidate in ipairs(keys) do if M.same(candidate, key) then return true end end
  return false
end
function M.resolve(catalog, document)
  document = document or {}
  local rows, customs, diagnostics, reserved, claims, overridden = {}, {}, {}, {}, {}, {}
  local overrides = document.actions or {}
  for _, action in ipairs(catalog) do
    local row = {}
    for key, value in pairs(action) do row[key] = value end
    row.defaultKeys = copy_keys(action.defaultKeys or action.keys)
    row.keys = copy_keys(row.defaultKeys)
    row.changed, row.custom = false, false
    rows[#rows + 1] = row
    if row.protected then
      for _, key in ipairs(row.defaultKeys) do reserved[key:lower()] = row.id end
    end
    local override = overrides[row.id]
    if override and row.editable and (not row.protected or #override.keys > 0) then
      row.keys, overridden[row.id] = copy_keys(override.keys), true
    end
  end
  local function claim(row)
    local accepted = {}
    for _, key in ipairs(row.keys) do
      local identity = key:lower()
      local owner = reserved[identity] or claims[identity]
      if owner and owner ~= row.id then
        diagnostics[#diagnostics + 1] = { type = "conflict", id = row.id, keys = key, by = owner }
      elseif not contains(accepted, key) then
        claims[identity], accepted[#accepted + 1] = row.id, key
      end
    end
    row.keys = accepted
    -- A protected remap can lose all its claims. Its reserved defaults are
    -- still available, so it always has a working way into the session.
    if row.protected and #row.keys == 0 then row.keys = copy_keys(row.defaultKeys) end
  end
  for _, row in ipairs(rows) do if overridden[row.id] then claim(row) end end
  for _, entry in ipairs(document.custom or {}) do
    local row = {}
    for key, value in pairs(entry) do row[key] = value end
    row.keys = copy_keys(entry.keys)
    claim(row)
    customs[#customs + 1] = row
  end
  for _, row in ipairs(rows) do
    if not overridden[row.id] then
      local kept = {}
      for _, key in ipairs(row.keys) do
        local owner = claims[key:lower()]
        if owner and owner ~= row.id then
          diagnostics[#diagnostics + 1] = { type = "displaced", id = row.id, keys = key, by = owner }
        else kept[#kept + 1] = key end
      end
      row.keys = kept
    end
    row.changed = #row.keys ~= #row.defaultKeys
    if not row.changed then
      for i, key in ipairs(row.keys) do
        if not M.same(key, row.defaultKeys[i]) then row.changed = true; break end
      end
    end
  end
  return { v = 1, actions = rows, custom = customs, diagnostics = diagnostics }
end
return M
