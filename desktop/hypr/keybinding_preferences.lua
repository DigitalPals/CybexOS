-- Settings writes data, never Lua. Validate the complete document before
-- changing any bindings; a bad file leaves every vendor default usable.
local M = { MAX_BYTES = 65536 }
local json = require("displays")
local encoder = require("keybinding_json")
local helpers = require("keybinding_helpers")
local catalog = require("bindings")
local config = os.getenv("XDG_CONFIG_HOME") or ((os.getenv("HOME") or "") .. "/.config")
local runtime = os.getenv("XDG_RUNTIME_DIR")
M.path = config .. "/cybexos/keybindings.json"
M.state_path = runtime and runtime .. "/cybexos/keybindings-state.json"
local function object(value)
  return type(value) == "table" and value.n == nil and value ~= json.null
end
local function text(value, limit, bytes)
  return type(value) == "string" and value ~= "" and not value:find("[%z\1-\31\127]")
    and not value:find("\194[\128-\159]")
    and (bytes and #value or select(2, value:gsub("[^\128-\191]", ""))) <= limit
end
local function keys(value)
  assert(type(value) == "table" and type(value.n) == "number" and value.n <= 4, "invalid shortcut keys")
  local seen = {}
  for _, key in ipairs(value) do
    local normal = helpers.normalize(key)
    assert(normal ~= "" and not normal:lower():find("mouse", 1, true), "invalid shortcut key")
    assert(not seen[normal:lower()], "duplicate shortcut key")
    seen[normal:lower()] = true
  end
end
function M.validate(document)
  assert(object(document) and document.v == 1, "unsupported keybindings preferences version")
  assert(document.actions == nil or object(document.actions), "invalid shortcut overrides")
  for _, entry in pairs(document.actions or {}) do
    assert(object(entry), "invalid shortcut override")
    keys(entry.keys)
  end
  assert(document.custom == nil or (type(document.custom) == "table" and type(document.custom.n) == "number"),
    "invalid custom shortcuts")
  local ids = {}
  for _, entry in ipairs(document.custom or {}) do
    assert(object(entry) and type(entry.id) == "string" and entry.id:match("^custom%.[a-z0-9-]+$")
      and #entry.id <= 47 and not ids[entry.id], "invalid or duplicate custom shortcut ID")
    ids[entry.id] = true
    assert(text(entry.group, 64) and not entry.group:find(":", 1, true) and text(entry.label, 64),
      "invalid shortcut group or label")
    keys(entry.keys)
    local run = entry.run
    assert(object(run), "invalid shortcut launch")
    if run.type == "app" then
      assert(text(run.desktopId, 255, true) and run.desktopId:match("^[A-Za-z0-9_@.+-]+%.desktop$"), "invalid desktop ID")
    elseif run.type == "webapp" then
      assert(text(run.id, 64, true) and run.id:match("^[a-z0-9][a-z0-9-]*$"), "invalid web app ID")
    elseif run.type == "url" then
      assert(text(run.url, 2048, true) and (run.url:match("^https://[^/%s]+") or run.url:match("^http://[^/%s]+")),
        "invalid website URL")
    elseif run.type == "command" then assert(text(run.command, 512, true), "invalid shortcut command")
    else error("invalid shortcut launch type") end
  end
  return document
end
local function read()
  local file, reason, code = io.open(M.path, "rb")
  if not file then
    if code == 2 then return nil end
    error(reason or "cannot read shortcut preferences")
  end
  local contents = file:read(M.MAX_BYTES + 1)
  file:close()
  assert(contents and #contents <= M.MAX_BYTES, "shortcut preferences exceed 64 KiB")
  assert(encoder.valid_utf8(contents), "shortcut preferences are not UTF-8")
  local document, problem = json.decode(contents)
  assert(document, problem)
  return M.validate(document)
end
local function publish(state)
  assert(M.state_path, "XDG_RUNTIME_DIR is required for shortcut state")
  state.error = _G.__cybexos_keybindings_error or json.null
  for _, row in ipairs(state.actions) do encoder.array(row.keys); encoder.array(row.defaultKeys) end
  for _, row in ipairs(state.custom) do encoder.array(row.keys) end
  encoder.array(state.actions); encoder.array(state.custom); encoder.array(state.diagnostics)
  local quote = function(value) return "'" .. value:gsub("'", "'\\''") .. "'" end
  local directory = runtime .. "/cybexos"
  -- Hyprland's SIGCHLD handler can reap a child before Lua collects its
  -- status, so os.execute and pclose report nil,"No child processes",ECHILD
  -- even on success (see workspace_state.lua). mktemp prints its path only
  -- after mkdir succeeded; that path is the completion proof.
  local prefix = directory .. "/.keybindings-"
  local pipe = assert(io.popen("mkdir -p -m 700 -- " .. quote(directory) .. " && mktemp -- "
    .. quote(prefix .. "XXXXXX"), "r"))
  local temporary = pipe:read("*l")
  pipe:close()
  assert(temporary and temporary:sub(1, #prefix) == prefix, "cannot create shortcut state file")
  local ok, problem = pcall(function()
    local file = assert(io.open(temporary, "wb"))
    local written, reason = file:write(encoder.encode(state) .. "\n")
    local closed, close_reason = file:close()
    assert(written and closed, reason or close_reason)
    assert(os.rename(temporary, M.state_path))
  end)
  if not ok then os.remove(temporary); error(problem) end
end
function M.load()
  local ok, document = pcall(read)
  _G.__cybexos_keybindings_error = not ok and tostring(document) or nil
  local state = helpers.resolve(catalog.actions, ok and document or nil)
  if ok and document then
    local applied, problem = pcall(catalog.install, state)
    if not applied then
      catalog.install()
      _G.__cybexos_keybindings_error = tostring(problem)
      state = helpers.resolve(catalog.actions)
    end
  end
  publish(state)
  return state
end
M.state = M.load()
return M
