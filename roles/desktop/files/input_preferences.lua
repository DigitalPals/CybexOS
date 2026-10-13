-- Personal input data loads after vendor input and before user.lua. Reuse the
-- display module's bounded JSON reader; strings from this file are never code.
local M = {}
local json = require("displays")
local config = os.getenv("XDG_CONFIG_HOME") or ((os.getenv("HOME") or "") .. "/.config")
M.path = config .. "/cybexos/input.json"
local shortcuts = { [""] = true,
  ["grp:alt_shift_toggle"] = true, ["grp:ctrl_shift_toggle"] = true, ["grp:caps_toggle"] = true }
local function token(value)
  return type(value) == "string" and #value >= 1 and #value <= 64 and value:match("^[%w_-]+$")
end
function M.apply(document)
  assert(type(document) == "table" and document.v == 1, "unsupported input preferences version")
  local keyboard = document.keyboard == nil and {} or document.keyboard
  local touchpad = document.touchpad == nil and {} or document.touchpad
  assert(type(keyboard) == "table" and keyboard.n == nil and keyboard ~= json.null, "invalid keyboard preferences")
  assert(type(touchpad) == "table" and touchpad.n == nil and touchpad ~= json.null, "invalid touchpad preferences")
  local input = {}
  if keyboard.layouts ~= nil then
    assert(type(keyboard.layouts) == "table" and type(keyboard.layouts.n) == "number"
      and keyboard.layouts.n >= 1 and keyboard.layouts.n <= 4, "invalid keyboard layouts")
    local layouts, variants = {}, {}
    for _, entry in ipairs(keyboard.layouts) do
      assert(type(entry) == "table" and token(entry.layout), "invalid keyboard layout")
      assert(entry.variant == nil or entry.variant == "" or token(entry.variant), "invalid keyboard variant")
      layouts[#layouts + 1], variants[#variants + 1] = entry.layout, entry.variant or ""
    end
    input.kb_layout, input.kb_variant = table.concat(layouts, ","), table.concat(variants, ",")
  end
  if keyboard.shortcut ~= nil then
    assert(shortcuts[keyboard.shortcut], "invalid layout switching shortcut")
    -- Keep the shared vendor options; user.lua can still customize them.
    local options = {}
    for option in (_G.__cybexos_vendor_keyboard_options or ""):gmatch("[^,]+") do
      if not option:match("^grp:") and not (keyboard.shortcut == "grp:caps_toggle" and option == "compose:caps") then
        options[#options + 1] = option
      end
    end
    if keyboard.shortcut ~= "" then options[#options + 1] = keyboard.shortcut end
    input.kb_options = table.concat(options, ",")
  end
  input.touchpad = {}
  for saved, native in pairs({tap = "tap_to_click", naturalScroll = "natural_scroll"}) do
    if touchpad[saved] ~= nil then
      assert(type(touchpad[saved]) == "boolean", "invalid touchpad switch")
      input.touchpad[native] = touchpad[saved]
    end
  end
  if touchpad.sensitivity ~= nil then
    assert(type(touchpad.sensitivity) == "number" and touchpad.sensitivity >= -1 and touchpad.sensitivity <= 1,
      "invalid touchpad sensitivity")
    -- Hyprland exposes pointer sensitivity at input level; touchpads use it
    -- too, unless a user's per-device rule overrides it.
    input.sensitivity = touchpad.sensitivity
  end
  hl.config({ input = input })
end
local file = io.open(M.path, "rb")
if file then
  local contents = file:read(json.MAX_BYTES + 1)
  file:close()
  local document, error = json.decode(contents)
  local ok, reason = false, error
  if document ~= nil then ok, reason = pcall(M.apply, document) end
  _G.__cybexos_input_error = not ok and tostring(reason) or nil
else
  _G.__cybexos_input_error = nil
end
return M
