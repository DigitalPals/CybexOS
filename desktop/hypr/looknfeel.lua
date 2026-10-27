-- Keep compositor blur in step with the shell's persisted glass setting from
-- the first frame. Quickshell updates the named rule below at runtime; this
-- lightweight read covers compositor reloads and restarts before the shell has
-- a reason to emit a setting change. Without a stored choice glass is off, as
-- it is in the shell's defaults. High contrast turns glass off in the shell
-- (Theme.glassActive, Settings.applyGlassEffect), so it turns blur off here
-- too; reading glassEnabled alone brought blur back on every reload.
local function persisted_glass_enabled()
  local home = os.getenv("HOME")
  if not home then return false end

  local file = io.open(home .. "/.config/cybexos/shell.json", "r")
  if not file then
    file = io.open(home .. "/.local/state/quickshell/shell-settings.json", "r")
  end
  if not file then return false end
  local contents = file:read("*a")
  file:close()

  local function enabled(key)
    return contents:match('[,{]%s*"' .. key .. '"%s*:%s*(%a+)') == "true"
  end
  return enabled("glassEnabled") and not enabled("highContrast")
end

hl.config({
  general = {
    gaps_in = 5,
    gaps_out = 10,
    border_size = 0,
    layout = "dwindle",
    -- The colours in this table are the system theme's for the default dark
    -- appearance (theme_hyprland.py); the theme below replaces them.
    col = { active_border = "rgb(60a5fa)", inactive_border = "rgb(3a3936)" },
  },
  cursor = { no_hardware_cursors = false },
  decoration = {
    -- Match Quickshell's Theme.hugCornerSize so tiled window corners continue
    -- the menubar's inverted edge curve at the reserved boundary.
    rounding = 16,
    -- Blur separates translucent surfaces from the wallpaper. One pass keeps
    -- compositing work down on high-resolution, high-refresh-rate displays;
    -- vibrancy stands in for the design's saturate(1.7).
    blur = {
      enabled = true, size = 6, passes = 1, new_optimizations = true,
      vibrancy = 0.25, noise = 0.012,
    },
    shadow = { enabled = true, range = 4, render_power = 3, color = "rgba(1a1917ee)" },
  },
  animations = { enabled = true },
  -- SDDM owns crash recovery: a new desktop requires a new authenticated login.
  -- Hyprland's random splash line (one reads "Segmentation fault (core
  -- dumped)") shows wherever no wallpaper covers the background, as in the
  -- image's installation-only session.
  misc = { force_default_wallpaper = 0, disable_hyprland_logo = true, disable_splash_rendering = true,
           focus_on_activate = false, disable_watchdog_warning = true },
  xwayland = {
    force_zero_scaling = false,
  },
  group = {
    col = {
      border_active = "rgb(60a5fa)", border_inactive = "rgb(3a3936)",
      border_locked_active = "rgb(ff8f8f)", border_locked_inactive = "rgb(3a3936)",
    },
    groupbar = {
      col = {
        active = "rgb(60a5fa)", inactive = "rgb(3a3936)",
        locked_active = "rgb(ff8f8f)", locked_inactive = "rgb(3a3936)",
      },
      text_color = "rgb(f2f0ea)", text_color_inactive = "rgb(b3afa4)",
      text_color_locked_active = "rgb(f2f0ea)", text_color_locked_inactive = "rgb(b3afa4)",
    },
  },
  dwindle = { preserve_split = true, split_width_multiplier = 1.0 },
})

-- The system theme (docs/system-theme.md). The shell renders its colours into
-- ~/.local/state/cybexos/theme/hyprland.lua, a data-only table of the keys
-- below, and it is applied over the vendor colours above. That file is state
-- the shell rewrites, so nothing in it may stop the compositor from starting:
-- a missing file keeps the vendor colours, every file is loaded in an empty
-- environment and checked key by key, and a damaged one is ignored. Diagnose
-- one with
--   hyprctl repl 'return __cybexos_system_theme.error'
-- A theme change reaches a running compositor through
--   hyprctl eval 'cybexos_system_theme(PATH)'
-- rather than a config reload, which would also re-read glass and display
-- state the shell changes at runtime. user.lua loads after this and keeps
-- winning: a key whose live value is no longer the one the theme last applied
-- was set by someone else, and a live change leaves it alone until the next
-- config reload.
local system_theme = rawget(_G, "__cybexos_system_theme") or {}
_G.__cybexos_system_theme = system_theme
local THEME_KEYS = {
  "general.col.active_border", "general.col.inactive_border",
  "decoration.shadow.color",
  "group.col.border_active", "group.col.border_inactive",
  "group.col.border_locked_active", "group.col.border_locked_inactive",
  "group.groupbar.col.active", "group.groupbar.col.inactive",
  "group.groupbar.col.locked_active", "group.groupbar.col.locked_inactive",
  "group.groupbar.text_color", "group.groupbar.text_color_inactive",
  "group.groupbar.text_color_locked_active", "group.groupbar.text_color_locked_inactive",
}
local THEME_MAX_BYTES = 65536

local function system_theme_path()
  local state = os.getenv("XDG_STATE_HOME")
  if not state or state == "" then
    local home = os.getenv("HOME")
    if not home then return nil end
    state = home .. "/.local/state"
  end
  return state .. "/cybexos/theme/hyprland.lua"
end

-- {dotted key = colour} for the theme keys a file sets, nil when there is no
-- file, or an error. Keys this version does not know are ignored, so a newer
-- renderer never makes an older compositor config drop the whole theme.
local function read_system_theme(path)
  local file, reason, code = io.open(path, "r")
  if not file then
    if code == 2 then return nil end
    error(reason, 0)
  end
  local text = file:read(THEME_MAX_BYTES + 1)
  file:close()
  if not text or #text > THEME_MAX_BYTES then
    error(path .. ": empty or too large", 0)
  end
  local chunk, syntax = load(text, "=" .. path, "t", {})
  if not chunk then error(syntax, 0) end
  local data = chunk()
  if type(data) ~= "table" then error(path .. ": does not return a table", 0) end
  local values = {}
  for _, key in ipairs(THEME_KEYS) do
    local node = data
    for part in key:gmatch("[^.]+") do
      if type(node) ~= "table" then node = nil break end
      node = node[part]
    end
    if node ~= nil then
      if type(node) ~= "string" or not (node:match("^rgb%(%x%x%x%x%x%x%)$")
          or node:match("^rgba%(%x%x%x%x%x%x%x%x%)$")) then
        error(path .. ": " .. key .. " is not rgb(rrggbb) or rgba(rrggbbaa)", 0)
      end
      values[key] = node
    end
  end
  return values
end

local function apply_system_theme(values)
  local config, any = {}, false
  for key, value in pairs(values) do
    local node, parts = config, {}
    for part in key:gmatch("[^.]+") do parts[#parts + 1] = part end
    for i = 1, #parts - 1 do
      node[parts[i]] = node[parts[i]] or {}
      node = node[parts[i]]
    end
    node[parts[#parts]] = value
    any = true
  end
  if any then hl.config(config) end
end

-- What each key holds now, comparable across calls: hl.get_config returns a
-- colour as "0xAARRGGBB" and a gradient as { colors = {...}, angle = n }.
local function system_theme_snapshot()
  local snapshot = {}
  if type(hl.get_config) ~= "function" then return snapshot end
  for _, key in ipairs(THEME_KEYS) do
    local ok, value = pcall(hl.get_config, key)
    if ok and type(value) == "table" then
      local colors = {}
      for i, color in ipairs(type(value.colors) == "table" and value.colors or {}) do
        colors[i] = tostring(color)
      end
      value = table.concat(colors, " ") .. " " .. tostring(value.angle)
    end
    snapshot[key] = ok and tostring(value) or nil
  end
  return snapshot
end

function cybexos_system_theme(path)
  local values = read_system_theme(path)
  if not values then error(path .. ": no such file", 0) end
  local applied, current, owned = system_theme.applied or {}, system_theme_snapshot(), {}
  for key, value in pairs(values) do
    if applied[key] == nil or applied[key] == current[key] then owned[key] = value end
  end
  apply_system_theme(owned)
  local after = system_theme_snapshot()
  for key in pairs(owned) do applied[key] = after[key] end
  system_theme.applied = applied
  system_theme.error = nil
end

system_theme.error = nil
local theme_path = system_theme_path()
if theme_path then
  local theme_ok, theme_values = pcall(read_system_theme, theme_path)
  if theme_ok and theme_values then
    theme_ok, theme_values = pcall(apply_system_theme, theme_values)
  end
  if not theme_ok then system_theme.error = tostring(theme_values) end
end
-- The baseline a live change compares against, taken before user.lua runs.
system_theme.applied = system_theme_snapshot()

hl.curve("myBezier", { type = "bezier", points = { { 0.05, 0.9 }, { 0.1, 1.0 } } })
hl.animation({ leaf = "windows", enabled = true, speed = 7, bezier = "myBezier" })
hl.animation({ leaf = "windowsOut", enabled = true, speed = 7, bezier = "default", style = "popin 80%" })
hl.animation({ leaf = "border", enabled = true, speed = 10, bezier = "default" })
hl.animation({ leaf = "borderangle", enabled = true, speed = 8, bezier = "default" })
hl.animation({ leaf = "fade", enabled = true, speed = 7, bezier = "default" })
hl.animation({ leaf = "workspaces", enabled = true, speed = 6, bezier = "default" })

-- Quickshell surfaces resize and remap as views open. Keep those operations
-- instantaneous so the menubar itself never replays a layer animation.
hl.layer_rule({
  name = "quickshell-no-animation",
  match = { namespace = [[^qs-(bar|bar-popout|launcher|notifications|osd|shortcuts|wallpaper|overview|dock|assistant|welcome|welcome-resume)$]] },
  no_anim = true,
})

-- Blur behind the glass. The wallpaper layer is deliberately absent: it is
-- opaque and at the bottom, so blurring it would only cost a pass. So is the
-- window overview: its backdrop is the wallpaper, and a blur behind live
-- window captures would be recomputed on every frame.
--
-- Blur is applied per pixel of the *surface*, and each of these spans more
-- than the shape it draws: the menubar's layer runs past the slab to leave room
-- for tooltips, a panel's runs past the card. Anything drawn into that margin
-- gets blurred along with the shape, at the full size of the layer — which is
-- why none of these surfaces carries a drop shadow any more. Glass over a real
-- blur already reads as floating; a shadow into the margin read as a haze band.
--
-- So ignore_alpha only has to skip pixels nothing was drawn on. Every surface
-- that must blur is well clear of it: the menubar's glass is 0.52, a panel's
-- 0.72, the full-screen scrims 0.42.
-- Intentionally global: Settings.qml reaches this stable handle through
-- `hyprctl eval` so switching glass never has to remap a layer surface.
quickshell_blur_rule = hl.layer_rule({
  name = "quickshell-blur",
  enabled = persisted_glass_enabled(),
  match = { namespace = [[^qs-(bar|bar-popout|launcher|notifications|osd|shortcuts|dock)$]] },
  blur = true,
  ignore_alpha = 0.1,
})

-- Power saver keeps blur to one pass and disables
-- animations. Quickshell calls cybexos_power_saver() through `hyprctl eval`
-- when it starts, whenever the power profile changes, and after every config
-- reload: Hyprland 0.56 rebuilds the Lua state on a reload, so _G does not
-- survive it and the shell sends the saver again (Settings.compositorReloaded).
-- What the saver replaced is read live, so switching it off later restores
-- what was there before, including an override from user.lua.
local power_saver = rawget(_G, "__cybexos_power_saver") or {}
_G.__cybexos_power_saver = power_saver
local power_saver_config = { decoration = { blur = { passes = 1 } }, animations = { enabled = false } }
-- Game mode (below) also holds animations off. Whichever of the two is
-- switched off first hands the value it replaced to the other, so the last
-- one off restores what was there before either.
local game_mode = { error = nil }
_G.__cybexos_game_mode = game_mode

function cybexos_power_saver(enabled)
  if enabled and not power_saver.restore then
    local restore = {
      passes = hl.get_config("decoration.blur.passes"),
      animations = hl.get_config("animations.enabled"),
    }
    if game_mode.restore then
      restore.animations = game_mode.restore["animations.enabled"]
      game_mode.restore["animations.enabled"] = false
    end
    hl.config(power_saver_config)
    power_saver.restore = restore
  elseif not enabled and power_saver.restore then
    if game_mode.restore then
      game_mode.restore["animations.enabled"] = power_saver.restore.animations
      hl.config({ decoration = { blur = { passes = power_saver.restore.passes } } })
    else
      hl.config({
        decoration = { blur = { passes = power_saver.restore.passes } },
        animations = { enabled = power_saver.restore.animations },
      })
    end
    power_saver.restore = nil
  end
end

if power_saver.restore then hl.config(power_saver_config) end

hl.window_rule({ match = { title = [[^Cybex OS Settings$]] }, float = true, center = true })
hl.window_rule({ match = { title = [[^Software Update$]] }, float = true, center = true })
hl.window_rule({ match = { class = [[xdg-desktop-portal-gtk]] }, float = true })
hl.window_rule({ match = { class = [[org\.gnome\.Nautilus]], title = [[Properties]] }, float = true })
hl.window_rule({ match = { class = [[org\.gnome\.Nautilus]], title = [[Open.*]] }, float = true })
hl.window_rule({ match = { class = [[org\.gnome\.Nautilus]], title = [[Save.*]] }, float = true })
-- A lone tiled window uses 70% of an external display's logical width.
-- Laptop displays and workspaces with multiple tiled windows keep normal gaps.
local previous = rawget(_G, "__cybexos_single_window_width")
if previous then
  previous.subscription:remove()
  for _, entry in pairs(previous.rules) do entry.rule:set_enabled(false) end
end
local policy = { rules = {}, suspended = false }
_G.__cybexos_single_window_width = policy

-- Game mode turns every gap off, these margins included.
function policy.suspend(value)
  policy.suspended = value
  for _, entry in pairs(policy.rules) do entry.rule:set_enabled(not value) end
end

local function update_single_window_width()
  local connected = {}
  for _, monitor in ipairs(hl.get_monitors()) do
    if not monitor.name:match("^eDP%-") and not monitor.name:match("^LVDS%-")
        and not monitor.is_mirror then
      connected[monitor.name] = true
      local rotated = monitor.transform % 2 == 1
      local width = (rotated and monitor.height or monitor.width) / monitor.scale
      local margin = math.floor(width * 0.15 + 0.5)
      local entry = policy.rules[monitor.name]
      if not entry or entry.margin ~= margin then
        if entry then entry.rule:set_enabled(false) end
        policy.rules[monitor.name] = {
          margin = margin,
          rule = hl.workspace_rule({
            workspace = "m[" .. monitor.name .. "] w[t1]",
            gaps_out = { top = 10, right = margin, bottom = 10, left = margin },
          }),
        }
        if policy.suspended then policy.rules[monitor.name].rule:set_enabled(false) end
      end
    end
  end
  for name, entry in pairs(policy.rules) do
    if not connected[name] then
      entry.rule:set_enabled(false)
      policy.rules[name] = nil
    end
  end
end

policy.subscription = hl.on("monitor.layout_changed", update_single_window_width)
update_single_window_width()

-- Game mode (the game-mode helper; docs/operations.md) turns animations,
-- blur, shadows, window rounding and gaps off for games, and the helper holds
-- idle locking off. `game-mode on|off` calls cybexos_game_mode() through
-- `hyprctl eval`; what it replaced is kept here and put back exactly.
--
-- A config reload starts a fresh Lua state with every value back at its
-- configured default, so the helper's state file is what carries game mode
-- across one: when $XDG_RUNTIME_DIR/cybexos/game-mode.json is on for this
-- compositor instance, game mode is applied again once the whole
-- configuration, user.lua included, has loaded, and turning it off then
-- restores the reloaded values. A new login is a new instance, so a file left
-- behind never applies there. The file is data the helper writes: two fields
-- are matched in it and nothing in it is evaluated. Diagnose with
--   hyprctl repl 'return __cybexos_game_mode.error'
local GAME_MODE_KEYS = {
  "animations.enabled", "decoration.blur.enabled", "decoration.shadow.enabled",
  "decoration.rounding", "general.gaps_in", "general.gaps_out",
}
local GAME_MODE_VALUES = {
  ["animations.enabled"] = false, ["decoration.blur.enabled"] = false,
  ["decoration.shadow.enabled"] = false, ["decoration.rounding"] = 0,
  ["general.gaps_in"] = 0, ["general.gaps_out"] = 0,
}
local GAME_MODE_MAX_BYTES = 4096

local function nested_config(values)
  local config = {}
  for _, key in ipairs(GAME_MODE_KEYS) do
    if values[key] ~= nil then
      local node, parts = config, {}
      for part in key:gmatch("[^.]+") do parts[#parts + 1] = part end
      for i = 1, #parts - 1 do
        node[parts[i]] = node[parts[i]] or {}
        node = node[parts[i]]
      end
      node[parts[#parts]] = values[key]
    end
  end
  return config
end

function cybexos_game_mode(enabled)
  if enabled and not game_mode.restore then
    local restore = {}
    for _, key in ipairs(GAME_MODE_KEYS) do restore[key] = hl.get_config(key) end
    hl.config(nested_config(GAME_MODE_VALUES))
    game_mode.restore = restore
    policy.suspend(true)
  elseif not enabled and game_mode.restore then
    hl.config(nested_config(game_mode.restore))
    game_mode.restore = nil
    policy.suspend(false)
  end
  game_mode.error = nil
  return game_mode.restore ~= nil
end

local function game_mode_requested()
  local runtime = os.getenv("XDG_RUNTIME_DIR")
  local instance = os.getenv("HYPRLAND_INSTANCE_SIGNATURE")
  if not runtime or runtime == "" or not instance or instance == "" then return false end
  local file = io.open(runtime .. "/cybexos/game-mode.json", "r")
  if not file then return false end
  local text = file:read(GAME_MODE_MAX_BYTES + 1)
  file:close()
  if not text or #text > GAME_MODE_MAX_BYTES then return false end
  return text:match('[,{]%s*"active"%s*:%s*(%a+)') == "true"
    and text:match('[,{]%s*"instance"%s*:%s*"([^"\\]*)"') == instance
end

if game_mode_requested() then
  hl.on("config.reloaded", function()
    local ok, failure = pcall(cybexos_game_mode, true)
    if not ok then game_mode.error = tostring(failure) end
  end)
end

hl.window_rule({ match = { class = [[.*]] }, suppress_event = "maximize" })
hl.window_rule({ match = { class = [[.*]] }, opacity = "1.0 1.0" })
hl.window_rule({ match = { class = [[1[pP]assword]] }, float = true, center = true, size = { 875, 600 }, no_screen_share = true })
hl.window_rule({ match = { class = [[org\.gnome\.NautilusPreviewer]] }, float = true, center = true, size = "monitor_w*0.6 monitor_h*0.7" })
hl.window_rule({ match = { class = [[localsend_app]] }, float = true, center = true, size = { 875, 600 } })
hl.window_rule({ match = { class = [[org\.gnome\.Calculator]] }, float = true })
hl.window_rule({ match = { class = [[(imv|mpv)]] }, float = true, center = true })
hl.window_rule({ match = { class = [[brave-(browser|origin)]], title = [[^Notification.*]] }, float = true, no_initial_focus = true, pin = true })
hl.window_rule({ match = { class = [[(vlc|mpv|imv|zoom)]] }, opacity = "1 1" })
