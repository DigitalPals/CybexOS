-- Workspace data is never executable. Reuse the project's strict JSON parser.
local json = require("displays")
local M = { MAX_BYTES = 262144 }
function M.object(value)
  return type(value) == "table" and value ~= json.null and value.n == nil
end
function M.integer(value, low, high)
  return type(value) == "number" and value == math.floor(value) and value >= low and value <= high
end
function M.string(value, maximum)
  return type(value) == "string" and #value <= maximum and not value:find("[%z\1-\31\127]")
end
function M.array(values)
  values = values or {}
  values.n = #values
  return values
end
local function quote(value)
  return '"' .. value:gsub('[%z\1-\31\\"]', function(c)
    if c == '"' then return '\\"' end
    if c == '\\' then return '\\\\' end
    return string.format("\\u%04x", c:byte())
  end) .. '"'
end
function M.encode(value)
  local kind = type(value)
  if kind == "string" then return quote(value) end
  if kind == "boolean" then return tostring(value) end
  if kind == "number" then
    assert(value == value and math.abs(value) < math.huge, "invalid number")
    return tostring(value)
  end
  assert(kind == "table" and value ~= json.null, "invalid workspace JSON value")
  local out = {}
  if value.n ~= nil then
    for i = 1, value.n do out[i] = M.encode(value[i]) end
    return "[" .. table.concat(out, ",") .. "]"
  end
  local keys = {}
  for key in pairs(value) do assert(type(key) == "string"); keys[#keys + 1] = key end
  table.sort(keys)
  for _, key in ipairs(keys) do out[#out + 1] = quote(key) .. ":" .. M.encode(value[key]) end
  return "{" .. table.concat(out, ",") .. "}"
end
function M.read(path, validate)
  if not path then return nil end
  local file, reason, code = io.open(path, "rb")
  if not file then return nil, code ~= 2 and reason or nil end
  local contents = file:read(M.MAX_BYTES + 1)
  file:close()
  local value, err = json.decode(contents)
  if not value then return nil, err or "invalid JSON" end
  local ok, result = pcall(validate, value)
  if not ok then return nil, tostring(result) end
  return result
end
local sequence = 0
local function shell_quote(value) return "'" .. value:gsub("'", "'\\''") .. "'" end
-- Lua's standard filesystem API has neither lstat nor mkdir. Validate and
-- protect each directory once with the system Python, then do event writes
-- entirely in-process. A random per-directory temporary prefix prevents the
-- predictable .tmp symlink problem. The 0700 owner-checked directory is the
-- privacy boundary; no claim is made about a particular inherited file umask.
local directories = rawget(_G, "__nerdos_workspace_directories") or {}
_G.__nerdos_workspace_directories = directories
local PREPARE = [[
import os, secrets, stat, sys
path = sys.argv[1]
try:
    os.makedirs(path, mode=0o700, exist_ok=True)
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        info = os.fstat(fd)
        if info.st_uid != os.geteuid() or not stat.S_ISDIR(info.st_mode):
            raise PermissionError("workspace directory has a different owner")
        os.fchmod(fd, 0o700)
    finally:
        os.close(fd)
    print(secrets.token_hex(16))
except Exception:
    sys.exit(1)
]]
local function prepare(directory)
  if directories[directory] then return directories[directory] end
  local pipe = io.popen("python3 -c " .. shell_quote(PREPARE) .. " " .. shell_quote(directory), "r")
  if not pipe then return nil, "cannot validate workspace directory" end
  local random = pipe:read(65)
  local ok, reason, code = pipe:close()
  random = random and random:match("^(%x+)\n$")
  -- Hyprland's SIGCHLD handler can reap the completed helper before pclose.
  -- Native Lua then returns nil,"No child processes",ECHILD (10 on Linux),
  -- even though the helper completed successfully. The exact bounded token
  -- is emitted only after all directory checks pass and is the completion
  -- proof in that case. Other close failures and malformed output still fail.
  local completed = ok == true or ok == 0 or (ok == nil and code == 10 and reason ~= "exit" and reason ~= "signal")
  if not completed or not random or #random ~= 32 then return nil, "workspace directory must be owned, private and not a symlink" end
  directories[directory] = random
  return random
end
function M.write(path, value)
  if not path then return nil, "XDG_RUNTIME_DIR is unavailable" end
  local contents = M.encode(value) .. "\n"
  if #contents > M.MAX_BYTES then return nil, "workspace data exceeds storage bound" end
  local directory = assert(path:match("^(.*)/[^/]+$"))
  local random, err = prepare(directory)
  if not random then return nil, err end
  sequence = sequence + 1
  local temporary = directory .. "/.workspace-" .. random .. "-" .. sequence
  local file; file, err = io.open(temporary, "wb")
  if not file then return nil, err end
  local ok, reason = file:write(contents)
  local closed, close_error = file:close()
  if not ok or not closed then os.remove(temporary); return nil, reason or close_error end
  ok, reason = os.rename(temporary, path)
  if not ok then os.remove(temporary) end
  return ok, reason
end
return M
