-- A small encoder for the resolved state. The decoder's `n` array marker
-- distinguishes [] from {}; state arrays created in Lua are marked here too.
local M = {}
local json = require("displays")
-- Hyprland uses Lua 5.5; the fixture harness also runs under LuaJIT. Check
-- raw UTF-8 before decoding so neither runtime can publish malformed JSON.
function M.valid_utf8(value)
  local pos = 1
  while pos <= #value do
    local first = value:byte(pos)
    local count = first < 128 and 1 or first >= 194 and first <= 223 and 2
      or first >= 224 and first <= 239 and 3 or first >= 240 and first <= 244 and 4
    if not count or pos + count - 1 > #value then return false end
    for i = 1, count - 1 do
      local byte = value:byte(pos + i)
      if byte < 128 or byte > 191 then return false end
    end
    local second = value:byte(pos + 1) or 0
    if (first == 224 and second < 160) or (first == 237 and second >= 160)
        or (first == 240 and second < 144) or (first == 244 and second >= 144) then return false end
    pos = pos + count
  end
  return true
end
function M.array(value) value.n = #value; return value end
function M.encode(value)
  if value == json.null or value == nil then return "null" end
  if type(value) == "string" then
    return '"' .. value:gsub('[%z\1-\31\\"]', function(char)
      return string.format("\\u%04x", char:byte())
    end) .. '"'
  end
  -- JSON has no infinity or NaN; tostring would write "inf" and corrupt the file.
  if type(value) == "number" and (value ~= value or value == math.huge or value == -math.huge) then return "null" end
  if type(value) == "boolean" or type(value) == "number" then return tostring(value) end
  assert(type(value) == "table", "cannot encode state value")
  local out = {}
  if value.n ~= nil then
    for i = 1, value.n do out[#out + 1] = M.encode(value[i]) end
    return "[" .. table.concat(out, ",") .. "]"
  end
  local keys = {}
  for key in pairs(value) do keys[#keys + 1] = key end
  table.sort(keys)
  for _, key in ipairs(keys) do out[#out + 1] = M.encode(key) .. ":" .. M.encode(value[key]) end
  return "{" .. table.concat(out, ",") .. "}"
end
return M
