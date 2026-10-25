local home = assert(os.getenv("HOME"), "HOME is required")
local config_home = os.getenv("XDG_CONFIG_HOME") or (home .. "/.config")
local data_home = os.getenv("XDG_DATA_HOME") or (home .. "/.local/share")
local generated_dir = "/etc/cybexos/runtime/hypr"
local source_dir = generated_dir
local user_dir = config_home .. "/cybexos/hypr"

-- Development mode substitutes only source-controlled modules. Rendered
-- machine facts remain in the installed runtime, so selecting a checkout can
-- never make the compositor consume an unrendered Jinja template.
local source_file = io.open(config_home .. "/cybexos/dev-source", "r")
if source_file then
  local checkout = source_file:read("*l")
  local trailing = source_file:read("*l")
  source_file:close()
  if checkout and checkout:sub(1, 1) == "/" and not trailing then
    local required = io.open(checkout .. "/desktop/hypr/bindings.lua", "r")
    if required then
      required:close()
      source_dir = checkout .. "/desktop/hypr"
    end
  end
end

package.path = source_dir .. "/?.lua;" .. source_dir .. "/?/init.lua;"
  .. generated_dir .. "/?.lua;" .. generated_dir .. "/?/init.lua;"
  .. user_dir .. "/?.lua;" .. user_dir .. "/?/init.lua;" .. package.path

for _, module in ipairs({ "features", "monitors", "input", "input_preferences", "bindings", "keybinding_preferences", "keybinding_helpers", "keybinding_json", "looknfeel", "autostart", "displays",
    "workspaces", "workspace_model", "workspace_state", "workspace_layouts" }) do
  package.loaded[module] = nil
end

-- Record independent float rules from managed configuration and user.lua.
-- Floating workspace opening rules must pass over those applications/dialogs.
-- Keep the native function across reloads instead of wrapping a wrapper.
local native_window_rule = rawget(_G, "__cybexos_native_window_rule") or hl.window_rule
_G.__cybexos_native_window_rule = native_window_rule
local window_rules = {}
hl.window_rule = function(spec)
  window_rules[#window_rules + 1] = spec
  return native_window_rule(spec)
end

require("monitors")
-- Settings -> Displays. Its saved file is user data that must never stop the
-- compositor from starting, so even an unexpected module error is contained;
-- the vendor monitor rules above then stay in effect. Diagnose one with
--   hyprctl repl 'return __cybexos_displays_error'
local displays_ok, displays_error = pcall(require, "displays")
if not displays_ok then
  _G.__cybexos_displays_error = tostring(displays_error)
end
require("input")
local input_ok, input_error = pcall(require, "input_preferences")
if not input_ok then _G.__cybexos_input_error = tostring(input_error) end
require("bindings")
-- Personal shortcuts are data, with defaults already registered above. A
-- contained failure stays visible to Settings without blocking the desktop.
local keybindings_ok, keybindings_error = pcall(require, "keybinding_preferences")
if not keybindings_ok then _G.__cybexos_keybindings_error = tostring(keybindings_error) end
require("looknfeel")
require("autostart")

-- The user layer is deliberately last. It is optional and never synthesized
-- or changed by Cybex OS.
local user_entry = io.open(user_dir .. "/user.lua", "r")
if user_entry then
  user_entry:close()
  dofile(user_dir .. "/user.lua")
end

local exclusions, float_tags = { class = {}, title = {} }, {}
for _, rule in ipairs(window_rules) do
  if rule.float == true and rule.match and rule.match.tag then float_tags[rule.match.tag] = true end
end
for _, rule in ipairs(window_rules) do
  local match = rule.match or {}
  if rule.float == true or (type(rule.tag) == "string" and float_tags[rule.tag:gsub("^%+", "")]) then
    for _, key in ipairs({ "class", "title" }) do
      if type(match[key]) == "string" then exclusions[key][#exclusions[key] + 1] = "(?:" .. match[key] .. ")" end
    end
  end
end
_G.__cybexos_float_exclusions = exclusions
hl.window_rule = native_window_rule
local workspaces_ok, workspaces_error = pcall(require, "workspaces")
if not workspaces_ok then _G.__cybexos_workspaces_error = tostring(workspaces_error)
else _G.__cybexos_workspaces_error = nil end

-- The existing system-theme owner remains the trigger; titlebars consume its
-- bounded JSON tokens and need no polling or compositor reload on theme edits.
if workspaces_ok and type(cybexos_system_theme) == "function" then
  local apply_theme = cybexos_system_theme
  cybexos_system_theme = function(path)
    apply_theme(path)
    require("workspaces").refresh_theme()
  end
end
