-- Display preferences saved by Settings -> Displays.
--
-- ~/.config/cybexos/displays.json is data, never code. It is parsed here by a
-- strict, bounded JSON reader and turned into hl.monitor() rules, so an EDID
-- string can never become Lua and a hostile or truncated file costs bounded
-- work. A missing file changes nothing. An unreadable or invalid one is
-- reported in $XDG_RUNTIME_DIR/cybexos/displays-status.json and ignored as a
-- whole: the vendor rules stay in effect and Hyprland always starts.
--
-- hyprland.lua requires this module after the vendor `monitors` module and
-- before ~/.config/cybexos/hypr/user.lua. Hyprland resolves monitor rules
-- last-first, so a saved choice overrides the vendor rule for its monitor and
-- user.lua still overrides both. Each rule starts from the vendor rules that
-- match the same monitor, which keeps vendor-only fields such as bitdepth,
-- colour management or a VRR policy unless the user chose otherwise.
--
-- Settings applies an unconfirmed change through
--   hyprctl eval 'require("displays").apply_trial(PATH)'
-- which runs this same code on a candidate file; reverting is a config
-- reload, which rebuilds every rule from the files on disk.
local M = {}

local home = os.getenv("HOME") or ""
local config_home = os.getenv("XDG_CONFIG_HOME") or (home .. "/.config")
local runtime_dir = os.getenv("XDG_RUNTIME_DIR")

M.path = config_home .. "/cybexos/displays.json"
M.status_path = runtime_dir and (runtime_dir .. "/cybexos/displays-status.json") or nil
M.MAX_BYTES = 262144
M.MAX_ENTRIES = 64
M.MAX_DEPTH = 16

-- ---------------------------------------------------------------- JSON ----

local NULL = setmetatable({}, { __tostring = function() return "null" end })
M.null = NULL

local ESCAPES = {
  ['"'] = '"', ["\\"] = "\\", ["/"] = "/",
  b = "\b", f = "\f", n = "\n", r = "\r", t = "\t",
}

local function utf8_char(cp)
  if cp < 0x80 then
    return string.char(cp)
  elseif cp < 0x800 then
    return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
  elseif cp < 0x10000 then
    return string.char(0xE0 + math.floor(cp / 0x1000),
      0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
  end
  return string.char(0xF0 + math.floor(cp / 0x40000),
    0x80 + math.floor(cp / 0x1000) % 0x40,
    0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
end

-- RFC 8259 without extensions: no comments, trailing commas, NaN, duplicate
-- keys or unescaped control characters. Objects become tables with string
-- keys; arrays carry their length in `n`, so a JSON null never makes a hole.
function M.decode(text)
  if type(text) ~= "string" then
    return nil, "not text"
  end
  if #text > M.MAX_BYTES then
    return nil, "the file is larger than " .. M.MAX_BYTES .. " bytes"
  end
  local pos, depth = 1, 0

  local function fail(message)
    error({ json = message .. " at byte " .. pos }, 0)
  end

  local function skip()
    pos = text:find("[^ \t\r\n]", pos) or (#text + 1)
  end

  local parse_value

  local function parse_string()
    pos = pos + 1
    local parts = {}
    while true do
      -- NUL is checked separately: Lua 5.1 patterns cannot contain it and
      -- later versions deprecated %z.
      local at = text:find('["\\\1-\31]', pos)
      if not at then fail("unterminated string") end
      local chunk = text:sub(pos, at - 1)
      if chunk:find("\0", 1, true) then fail("control character in string") end
      parts[#parts + 1] = chunk
      local char = text:sub(at, at)
      if char == '"' then
        pos = at + 1
        return table.concat(parts)
      elseif char ~= "\\" then
        pos = at
        fail("control character in string")
      end
      local escape = text:sub(at + 1, at + 1)
      if ESCAPES[escape] then
        parts[#parts + 1] = ESCAPES[escape]
        pos = at + 2
      elseif escape == "u" then
        local hex = text:sub(at + 2, at + 5)
        if not hex:match("^%x%x%x%x$") then
          pos = at
          fail("invalid unicode escape")
        end
        local cp = tonumber(hex, 16)
        pos = at + 6
        if cp >= 0xD800 and cp <= 0xDBFF then
          local low = text:match("^\\u(%x%x%x%x)", pos)
          local low_cp = low and tonumber(low, 16)
          if not low_cp or low_cp < 0xDC00 or low_cp > 0xDFFF then
            fail("unpaired surrogate")
          end
          cp = 0x10000 + (cp - 0xD800) * 0x400 + (low_cp - 0xDC00)
          pos = pos + 6
        elseif cp >= 0xDC00 and cp <= 0xDFFF then
          fail("unpaired surrogate")
        end
        parts[#parts + 1] = utf8_char(cp)
      else
        pos = at
        fail("invalid escape")
      end
    end
  end

  local function parse_number()
    local start = pos
    local sign = text:match("^%-", pos) and 1 or 0
    local digits = text:match("^%d+", pos + sign)
    if not digits then fail("invalid number") end
    if #digits > 1 and digits:sub(1, 1) == "0" then fail("leading zero") end
    pos = pos + sign + #digits
    local fraction = text:match("^%.%d+", pos)
    if text:sub(pos, pos) == "." and not fraction then fail("invalid number") end
    if fraction then pos = pos + #fraction end
    local exponent = text:match("^[eE][-+]?%d+", pos)
    if text:match("^[eE]", pos) and not exponent then fail("invalid number") end
    if exponent then pos = pos + #exponent end
    local value = tonumber(text:sub(start, pos - 1))
    if not value or value ~= value or value == math.huge or value == -math.huge then
      fail("invalid number")
    end
    return value
  end

  local function parse_array()
    pos = pos + 1
    local result = { n = 0 }
    skip()
    if text:sub(pos, pos) == "]" then
      pos = pos + 1
      return result
    end
    while true do
      result.n = result.n + 1
      result[result.n] = parse_value()
      skip()
      local char = text:sub(pos, pos)
      pos = pos + 1
      if char == "]" then return result end
      if char ~= "," then
        pos = pos - 1
        fail("expected ',' or ']'")
      end
    end
  end

  local function parse_object()
    pos = pos + 1
    local result = {}
    skip()
    if text:sub(pos, pos) == "}" then
      pos = pos + 1
      return result
    end
    while true do
      skip()
      if text:sub(pos, pos) ~= '"' then fail("expected a string key") end
      local key = parse_string()
      if result[key] ~= nil then fail("duplicate key") end
      skip()
      if text:sub(pos, pos) ~= ":" then fail("expected ':'") end
      pos = pos + 1
      result[key] = parse_value()
      skip()
      local char = text:sub(pos, pos)
      pos = pos + 1
      if char == "}" then return result end
      if char ~= "," then
        pos = pos - 1
        fail("expected ',' or '}'")
      end
    end
  end

  parse_value = function()
    skip()
    local char = text:sub(pos, pos)
    if char == "{" or char == "[" then
      depth = depth + 1
      if depth > M.MAX_DEPTH then fail("nesting is too deep") end
      local value = char == "{" and parse_object() or parse_array()
      depth = depth - 1
      return value
    elseif char == '"' then
      return parse_string()
    elseif char == "-" or char:match("%d") then
      return parse_number()
    elseif text:sub(pos, pos + 3) == "true" then
      pos = pos + 4
      return true
    elseif text:sub(pos, pos + 4) == "false" then
      pos = pos + 5
      return false
    elseif text:sub(pos, pos + 3) == "null" then
      pos = pos + 4
      return NULL
    end
    fail("unexpected input")
  end

  local ok, value = pcall(function()
    local result = parse_value()
    skip()
    if pos <= #text then fail("trailing data") end
    return result
  end)
  if ok then return value end
  if type(value) == "table" and value.json then return nil, value.json end
  return nil, tostring(value)
end

local function encode_string(value)
  local out = {}
  for index = 1, #value do
    local byte = value:byte(index)
    if byte == 34 then
      out[index] = '\\"'
    elseif byte == 92 then
      out[index] = "\\\\"
    elseif byte < 32 or byte == 127 then
      out[index] = string.format("\\u%04x", byte)
    else
      out[index] = string.char(byte)
    end
  end
  return '"' .. table.concat(out) .. '"'
end

-- ---------------------------------------------------------- validation ----

local function is_array(value)
  return type(value) == "table" and value ~= NULL and type(value.n) == "number"
end

local function is_object(value)
  return type(value) == "table" and value ~= NULL and value.n == nil
end

local function is_integer(value, low, high)
  return type(value) == "number" and value == math.floor(value)
    and value >= low and value <= high
end

local function has_control(value)
  return value:find("[\1-\31\127]") ~= nil or value:find("\0", 1, true) ~= nil
end

local function trim(value)
  return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

function M.valid_key(key)
  if type(key) ~= "string" then return false end
  if key:sub(1, 5) == "desc:" then
    local description = key:sub(6)
    return #key <= 261 and trim(description) == description
      and description ~= "" and not has_control(description)
  end
  return key:match("^[A-Za-z0-9_.-]+$") ~= nil and #key <= 64
end

-- Refresh rates keep their three significant decimals (59.94, 119.88);
-- %.3f then trimming avoids Lua 5.4's integer/float tostring differences.
function M.format_number(value)
  local text = string.format("%.3f", value):gsub("0+$", ""):gsub("%.$", "")
  return text
end

local function validate_entry(key, raw)
  if not M.valid_key(key) then
    return nil, "invalid display identifier " .. encode_string(key)
  end
  if not is_object(raw) then
    return nil, key .. ": the entry is not an object"
  end
  local entry = { key = key }

  if raw.description ~= nil then
    if type(raw.description) ~= "string" or #raw.description > 256
        or has_control(raw.description) then
      return nil, key .. ": invalid description"
    end
    entry.description = raw.description
  elseif key:sub(1, 5) == "desc:" then
    entry.description = key:sub(6)
  end
  if raw.connector ~= nil then
    if type(raw.connector) ~= "string" or not raw.connector:match("^[A-Za-z0-9_.-]+$")
        or #raw.connector > 64 then
      return nil, key .. ": invalid connector"
    end
    entry.connector = raw.connector
  end

  if raw.enabled ~= nil and type(raw.enabled) ~= "boolean" then
    return nil, key .. ": enabled must be true or false"
  end
  entry.enabled = raw.enabled ~= false
  if not entry.enabled then
    local with = raw.disabledWith
    if not is_array(with) or with.n < 1 or with.n > 16 then
      return nil, key .. ": a disabled display needs 1-16 disabledWith identifiers"
    end
    entry.disabled_with = {}
    for index = 1, with.n do
      if not M.valid_key(with[index]) or with[index] == key then
        return nil, key .. ": invalid disabledWith identifier"
      end
      entry.disabled_with[index] = with[index]
    end
  end

  local mode = raw.mode
  if mode == "preferred" then
    entry.mode = "preferred"
  elseif mode ~= nil then
    if not is_object(mode) or not is_integer(mode.width, 1, 16384)
        or not is_integer(mode.height, 1, 16384) or type(mode.refresh) ~= "number"
        or mode.refresh < 1 or mode.refresh > 1000 then
      return nil, key .. ": invalid mode"
    end
    entry.mode = string.format("%dx%d@%s", mode.width, mode.height,
      M.format_number(mode.refresh))
  end

  local position = raw.position
  if position == "auto" then
    entry.position = "auto"
  elseif position ~= nil then
    if not is_object(position) or not is_integer(position.x, -65536, 65536)
        or not is_integer(position.y, -65536, 65536) then
      return nil, key .. ": invalid position"
    end
    entry.position = string.format("%dx%d", position.x, position.y)
  end

  local scale = raw.scale
  if scale == "auto" then
    entry.scale = "auto"
  elseif scale ~= nil then
    if type(scale) ~= "number" or scale < 0.25 or scale > 10 then
      return nil, key .. ": invalid scale"
    end
    entry.scale = string.format("%.6f", scale):gsub("0+$", ""):gsub("%.$", "")
  end

  if raw.transform ~= nil then
    if not is_integer(raw.transform, 0, 7) then
      return nil, key .. ": invalid transform"
    end
    -- Hyprland's integer fields reject Lua floats such as 1.0; math.floor
    -- returns an integer for them on Lua 5.3 and later.
    entry.transform = math.floor(raw.transform)
  end
  if raw.vrr ~= nil then
    if not is_integer(raw.vrr, 0, 3) then
      return nil, key .. ": invalid vrr"
    end
    entry.vrr = math.floor(raw.vrr)
  end
  if raw.mirror ~= nil then
    if type(raw.mirror) ~= "string" or (raw.mirror ~= "" and not M.valid_key(raw.mirror))
        or raw.mirror == key then
      return nil, key .. ": invalid mirror"
    end
    entry.mirror = raw.mirror
  end
  return entry
end

-- The whole document is rejected when any part is invalid: applying half a
-- layout can leave outputs overlapping or unreachable.
function M.validate(document)
  if not is_object(document) then
    return nil, "the document is not an object"
  end
  if document.v ~= 1 then
    return nil, "unsupported version (expected v = 1)"
  end
  local monitors = document.monitors
  if monitors == nil then monitors = {} end
  if not is_object(monitors) then
    return nil, "monitors is not an object"
  end
  local keys = {}
  for key in pairs(monitors) do
    if type(key) ~= "string" then
      return nil, "invalid display identifier"
    end
    keys[#keys + 1] = key
  end
  if #keys > M.MAX_ENTRIES then
    return nil, "more than " .. M.MAX_ENTRIES .. " displays"
  end
  table.sort(keys)
  local entries = {}
  for _, key in ipairs(keys) do
    local entry, err = validate_entry(key, monitors[key])
    if not entry then return nil, err end
    entries[#entries + 1] = entry
  end
  return entries
end

function M.read(path)
  local file = io.open(path, "rb")
  if not file then
    return nil, nil
  end
  local text = file:read(M.MAX_BYTES + 1)
  file:close()
  if text == nil then text = "" end
  local document, err = M.decode(text)
  if document == nil then
    return nil, "invalid JSON: " .. err
  end
  local entries, invalid = M.validate(document)
  if not entries then
    return nil, invalid
  end
  return entries
end

-- -------------------------------------------------------------- rules ----

local function monitor_matches(key, monitor)
  if key:sub(1, 5) == "desc:" then
    local prefix = trim(key:sub(6))
    local description = monitor.description or ""
    return prefix ~= "" and description:sub(1, #prefix) == prefix
  end
  return monitor.name == key
end
M.monitor_matches = monitor_matches

local function vendor_matches(selector, entry)
  if selector == "" then return true end
  if selector:sub(1, 5) == "desc:" then
    local prefix = trim(selector:sub(6))
    local description = entry.description
    return prefix ~= "" and description ~= nil and description:sub(1, #prefix) == prefix
  end
  return entry.connector == selector or entry.key == selector
end

function M.vendor_rules()
  local rules = rawget(_G, "__cybexos_vendor_monitor_rules")
  return type(rules) == "table" and rules or {}
end

-- A saved display is turned off only while one of the displays it was turned
-- off beside (`disabledWith`) is connected and on. Unplugging those companions
-- turns it back on, and at least one enabled output always remains: a display
-- is removed from `remaining` only while a different one stays in it.
function M.decide(entries, monitors)
  local remaining = {}
  for _, monitor in ipairs(monitors or {}) do
    remaining[#remaining + 1] = monitor
  end
  local disabled = {}
  for _, entry in ipairs(entries) do
    if not entry.enabled then
      local companion = false
      for _, other in ipairs(entry.disabled_with) do
        for _, monitor in ipairs(remaining) do
          if monitor_matches(other, monitor) and not monitor_matches(entry.key, monitor) then
            companion = true
            break
          end
        end
        if companion then break end
      end
      if companion then
        disabled[entry.key] = true
        local kept = {}
        for _, monitor in ipairs(remaining) do
          if not monitor_matches(entry.key, monitor) then
            kept[#kept + 1] = monitor
          end
        end
        remaining = kept
      end
    end
  end
  return disabled
end

function M.rule_for(entry, disabled, vendor)
  local rule = {}
  for _, candidate in ipairs(vendor or M.vendor_rules()) do
    if type(candidate) == "table" and type(candidate.output) == "string"
        and vendor_matches(candidate.output, entry) then
      for field, value in pairs(candidate) do
        if field ~= "output" then rule[field] = value end
      end
    end
  end
  -- Every field this page owns is explicit: hl.monitor() merges into an
  -- existing rule with the same output, so an omitted field would keep the
  -- previous trial's value.
  rule.output = entry.key
  rule.mode = entry.mode or rule.mode or "preferred"
  rule.position = entry.position or rule.position or "auto"
  rule.scale = entry.scale or rule.scale or "auto"
  rule.transform = entry.transform or rule.transform or 0
  rule.mirror = entry.mirror or ""
  if entry.vrr ~= nil then
    rule.vrr = entry.vrr
  elseif rule.vrr == nil then
    rule.vrr = -1
  end
  rule.disabled = disabled == true
  return rule
end

-- ------------------------------------------------------------ runtime ----

local previous = rawget(_G, "__cybexos_displays")
if previous then
  for _, subscription in ipairs(previous.subscriptions or {}) do
    if subscription and subscription.remove then subscription:remove() end
  end
end

local state = {
  subscriptions = {},
  entries = {},
  decisions = {},
  source = M.path,
}
_G.__cybexos_displays = state

local function current_monitors()
  local ok, monitors = pcall(hl.get_monitors)
  if not ok or type(monitors) ~= "table" then return {} end
  local result = {}
  for _, monitor in ipairs(monitors) do
    local name = monitor.name
    local description = monitor.description
    if type(name) == "string" then
      result[#result + 1] = {
        name = name,
        description = type(description) == "string" and description or "",
      }
    end
  end
  return result
end

local function write_status(status)
  if not M.status_path then return end
  local fields = {
    '"loaded":' .. tostring(status.loaded == true),
    '"source":' .. encode_string(status.source or ""),
    '"entries":' .. tostring(status.entries or 0),
    '"error":' .. encode_string(status.error or ""),
    '"time":' .. tostring(os.time()),
  }
  pcall(function()
    local temporary = M.status_path .. ".tmp"
    local file = io.open(temporary, "wb")
    if not file then return end
    file:write("{" .. table.concat(fields, ",") .. "}\n")
    file:close()
    os.rename(temporary, M.status_path)
  end)
end

local function emit(entries, only_changed)
  local decisions = M.decide(entries, current_monitors())
  local vendor = M.vendor_rules()
  for _, entry in ipairs(entries) do
    local disabled = decisions[entry.key] == true
    if not only_changed or (state.decisions[entry.key] == true) ~= disabled then
      hl.monitor(M.rule_for(entry, disabled, vendor))
    end
  end
  state.decisions = decisions
end

local function reevaluate()
  if #state.entries > 0 then emit(state.entries, true) end
end

-- Apply a validated document; `source` names where it came from.
function M.apply_entries(entries, source)
  state.entries = entries
  state.source = source
  state.decisions = {}
  emit(entries, false)
  write_status({ loaded = true, source = source, entries = #entries })
end

-- Settings' unconfirmed trial. Errors propagate to `hyprctl eval`, which then
-- reports them instead of "ok"; nothing is applied from an invalid file.
function M.apply_trial(path)
  local entries, err = M.read(path)
  if entries == nil then
    error(err or "the trial file is missing", 0)
  end
  M.apply_entries(entries, path)
  return nil
end

local function load_saved()
  local entries, err = M.read(M.path)
  if entries then
    M.apply_entries(entries, M.path)
  elseif err then
    state.entries = {}
    write_status({ loaded = false, source = M.path, error = err })
  else
    state.entries = {}
    write_status({ loaded = false, source = M.path })
  end
end

if type(hl) == "table" and type(hl.monitor) == "function" then
  load_saved()
  if type(hl.on) == "function" then
    for _, event in ipairs({ "monitor.added", "monitor.removed" }) do
      local ok, subscription = pcall(hl.on, event, reevaluate)
      if ok and subscription then
        table.insert(state.subscriptions, subscription)
      end
    end
  end
end

return M
