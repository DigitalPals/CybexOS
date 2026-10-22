local function persisted_scroll_factor()
  local home = os.getenv("HOME")
  if not home then return 1.0 end

  local file = io.open(home .. "/.config/nerdos/shell.json", "r")
  if not file then
    file = io.open(home .. "/.local/state/quickshell/shell-settings.json", "r")
  end
  if not file then return 1.0 end
  local contents = file:read("*a")
  file:close()

  local value = tonumber(contents:match('"scrollFactor"%s*:%s*([%d%.]+)'))
  if value and value >= 0.2 and value <= 2.0 then return value end
  return 1.0
end

-- Saved input preferences reuse the release's option defaults.
_G.__nerdos_vendor_keyboard_options = "compose:caps,lv3:ralt_switch"

hl.config({
  input = {
    kb_layout = "us",
    kb_variant = "",
    -- Keep left Alt available to applications (for example Codex Alt+Up).
    kb_options = _G.__nerdos_vendor_keyboard_options,
    follow_mouse = 1,
    natural_scroll = true,
    repeat_rate = 40,
    repeat_delay = 600,
    numlock_by_default = true,
    touchpad = {
      natural_scroll = true,
      disable_while_typing = true,
      tap_to_click = true,
      scroll_factor = persisted_scroll_factor(),
    },
  },
})

-- Touchpad gestures: three fingers sideways switch workspace, three fingers
-- up open the overview. Settings -> Touchpad can turn the workspace swipe off
-- through input_preferences.lua, which calls _G.__nerdos_gestures.remove().
--
-- Hyprland rejects a gesture that an earlier one overshadows, so a personal
-- gesture in user.lua on the same fingers and direction would otherwise show
-- a configuration error. While the configuration loads, hl.gesture first
-- retires any NerdOS gesture the new one overlaps: user.lua keeps winning,
-- as it does for every other setting. Each reload starts a fresh Lua state,
-- so this wrapper never stacks.
local gestures = { active = {} }
_G.__nerdos_gestures = gestures
local add_gesture = hl.gesture
local SWIPE_DIRECTIONS = {
  left = { left = true }, l = { left = true },
  right = { right = true }, r = { right = true },
  up = { up = true }, u = { up = true }, top = { up = true }, t = { up = true },
  down = { down = true }, d = { down = true }, bottom = { down = true }, b = { down = true },
  horizontal = { left = true, right = true }, horiz = { left = true, right = true },
  vertical = { up = true, down = true }, vert = { up = true, down = true },
  swipe = { left = true, right = true, up = true, down = true },
}

local function swipe_directions(direction)
  return type(direction) == "string" and SWIPE_DIRECTIONS[direction:lower()] or nil
end

local function overlaps(first, second)
  for direction in pairs(first) do
    if second[direction] then return true end
  end
  return false
end

local function same_directions(first, second)
  for direction in pairs(first) do
    if not second[direction] then return false end
  end
  for direction in pairs(second) do
    if not first[direction] then return false end
  end
  return true
end

local function unset(entry)
  add_gesture({ fingers = entry.fingers, direction = entry.direction, action = "unset" })
end

-- Retires the named NerdOS gesture; false when it is not registered.
function gestures.remove(name)
  for index, entry in ipairs(gestures.active) do
    if entry.name == name then
      table.remove(gestures.active, index)
      unset(entry)
      return true
    end
  end
  return false
end

if type(add_gesture) == "function" then
  hl.gesture = function(spec)
    local wanted = type(spec) == "table" and (spec.mods == nil or spec.mods == "")
      and swipe_directions(spec.direction)
    if wanted then
      for index = #gestures.active, 1, -1 do
        local entry = gestures.active[index]
        local ours = swipe_directions(entry.direction)
        if entry.fingers == spec.fingers then
          if spec.action == "unset" then
            -- Hyprland removes only an exact match; the caller's own unset
            -- retires ours, so it must not be unset twice.
            if same_directions(ours, wanted) then table.remove(gestures.active, index) end
          elseif overlaps(ours, wanted) then
            table.remove(gestures.active, index)
            unset(entry)
          end
        end
      end
    end
    return add_gesture(spec)
  end

  local home = os.getenv("HOME") or ""
  local function vendor_gesture(name, spec)
    add_gesture(spec)
    gestures.active[#gestures.active + 1] = { name = name, fingers = spec.fingers, direction = spec.direction }
  end
  vendor_gesture("workspace", { fingers = 3, direction = "horizontal", action = "workspace" })
  -- The shell runs from the NerdOS runtime by path; nerdos-runtime names it.
  vendor_gesture("overview", {
    fingers = 3,
    direction = "up",
    action = function()
      hl.exec_cmd("nerdos-runtime ipc overview toggle")
    end,
  })
end
