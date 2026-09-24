local home = assert(os.getenv("HOME"), "HOME is required")
local config_home = os.getenv("XDG_CONFIG_HOME") or (home .. "/.config")
local data_home = os.getenv("XDG_DATA_HOME") or (home .. "/.local/share")
local generated_dir = data_home .. "/cybexos/runtime/hypr"
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
    local required = io.open(checkout .. "/roles/desktop/files/bindings.lua", "r")
    if required then
      required:close()
      source_dir = checkout .. "/roles/desktop/files"
    end
  end
end

package.path = source_dir .. "/?.lua;" .. source_dir .. "/?/init.lua;"
  .. generated_dir .. "/?.lua;" .. generated_dir .. "/?/init.lua;"
  .. user_dir .. "/?.lua;" .. user_dir .. "/?/init.lua;" .. package.path

for _, module in ipairs({ "features", "monitors", "input", "bindings", "looknfeel", "autostart", "displays" }) do
  package.loaded[module] = nil
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
require("bindings")
require("looknfeel")
require("autostart")

-- The user layer is deliberately last. It is optional and never synthesized
-- or changed by CybexOS.
local user_entry = io.open(user_dir .. "/user.lua", "r")
if user_entry then
  user_entry:close()
  dofile(user_dir .. "/user.lua")
end
