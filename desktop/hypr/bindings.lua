local mainMod = "SUPER"
local terminal = "cybexos-apps terminal --"
local home = os.getenv("HOME")
local features = require("features")
local browser = "cybexos-apps browser"
local privateBrowser = "cybexos-apps browser --private"

-- Web apps are installed per account (cybexos-webapp; Install web app… in
-- the launcher). The helper follows the selected browser and tells the
-- user how to reinstall one that was removed.
local function web_app(id)
  return "cybexos-webapp launch " .. id
end

local M = { actions = {}, registrations = {} }
local by_id = {}
local protected = { ["shell.lock"] = true, ["shell.exit"] = true,
  ["shell.settings"] = true, ["shell.shortcuts"] = true }

-- Descriptions still feed the Super+K sheet. Stable IDs belong to the data
-- contract; labels may change without invalidating a person's saved choices.
local function bind(keys, dispatcher, opts, id)
  assert(id and id:match("^[a-z0-9.-]+$"), "a binding needs a stable action ID")
  local group, label = opts.description:match("^(.-): (.*)$")
  local action = by_id[id]
  if not action then
    action = { id = id, group = group, label = label, keys = {}, defaultKeys = {},
      editable = opts.mouse ~= true and group ~= "Hardware keys",
      protected = protected[id] == true, hidden = group == "Hardware keys", custom = false }
    by_id[id] = action
    M.actions[#M.actions + 1] = action
  end
  action.keys[#action.keys + 1] = keys
  action.defaultKeys[#action.defaultKeys + 1] = keys
  M.registrations[#M.registrations + 1] = { id = id, keys = keys, dispatcher = dispatcher, options = opts }
end

local function send_shortcut_once(mods, key)
  hl.dispatch(hl.dsp.send_key_state({ mods = mods, key = key, state = "down" }))
  hl.dispatch(hl.dsp.send_key_state({ mods = mods, key = key, state = "up" }))
end

bind(mainMod .. " + Return", hl.dsp.exec_cmd(terminal), { description = "Apps: Terminal" }, "apps.terminal")
if features.podman then
  bind(mainMod .. " + SHIFT + F", hl.dsp.exec_cmd(terminal .. " dev-nix-shell"),
    { description = "Development: Nix development shell" }, "development.nix-development-shell")
  bind(mainMod .. " + SHIFT + A", hl.dsp.exec_cmd(terminal .. " dev-arch-shell"),
    { description = "Development: Arch container shell" }, "development.arch-container-shell")
  bind(mainMod .. " + SHIFT + D", hl.dsp.exec_cmd(terminal .. " dev-debian-shell"),
    { description = "Development: Debian container shell" }, "development.debian-container-shell")
end
bind(mainMod .. " + SPACE", hl.dsp.global("quickshell:launcherToggle"), { description = "Shell: Launcher" }, "shell.launcher")
-- A global shortcut also reports the key's release, which is what lets a
-- tap open the assistant's box and a hold record a question (docs/assistant.md).
if features.assistant then
  bind(mainMod .. " + I", hl.dsp.global("quickshell:assistantTalk"),
    { description = "Shell: Assistant" }, "shell.assistant")
end
bind(mainMod .. " + CTRL + SHIFT + A", hl.dsp.exec_cmd("cybex agent --window"),
  { description = "Apps: AI agent" }, "apps.ai-agent")
-- The shell runs from the Cybex OS runtime by path, where a bare
-- `qs ipc call` finds no configuration; cybexos-runtime names the active one.
bind(mainMod .. " + comma", hl.dsp.exec_cmd("cybexos-runtime ipc settings toggle"),
  { description = "Shell: Cybex OS Settings" }, "shell.settings")
-- Shell surfaces the menubar also opens by click.
bind(mainMod .. " + N", hl.dsp.exec_cmd("cybexos-runtime ipc popouts toggle notifications"),
  { description = "Shell: Notifications" }, "shell.notifications")
bind(mainMod .. " + A", hl.dsp.exec_cmd("cybexos-runtime ipc popouts toggle control"),
  { description = "Shell: Control Panel" }, "shell.control-panel")
bind(mainMod .. " + K", hl.dsp.exec_cmd("cybexos-runtime ipc session keys"),
  { description = "Shell: Keyboard shortcuts" }, "shell.shortcuts")
bind(mainMod .. " + E", hl.dsp.exec_cmd("nautilus --new-window"), { description = "Apps: Files" }, "apps.files")
bind(mainMod .. " + B", hl.dsp.exec_cmd(browser), { description = "Apps: Browser" }, "apps.browser")
bind(mainMod .. " + SHIFT + B", hl.dsp.exec_cmd(privateBrowser), { description = "Apps: Private browser window" }, "apps.private-browser-window")
bind(mainMod .. " + M", hl.dsp.exec_cmd(web_app("slack")), { description = "Web apps: Slack" }, "webapps.slack")
if features.private_portal then
  bind(mainMod .. " + P", hl.dsp.exec_cmd(home .. "/.local/bin/portal-launcher"), { description = "Apps: Portal" }, "apps.portal")
end
bind(mainMod .. " + S", hl.dsp.exec_cmd("spotify"), { description = "Apps: Spotify" }, "apps.spotify")
if features.proprietary_apps then
  bind(mainMod .. " + SHIFT + SLASH", hl.dsp.exec_cmd("1password"), { description = "Apps: 1Password" }, "apps.1password")
end
if features.developer_tools then
  -- Docker group membership is root-equivalent and opt-in, so without it the
  -- socket is reachable only through sudo. The binary is resolved before
  -- sudo because sudo's secure_path may differ from the user's package profile.
  local lazydocker = [[sh -c 'docker info >/dev/null 2>&1 && exec lazydocker; exec sudo "$(command -v lazydocker)"']]
  bind(mainMod .. " + D", hl.dsp.exec_cmd(terminal .. " " .. lazydocker),
    { description = "Development: Docker (lazydocker)" }, "development.docker-lazydocker")
end
if features.connected_widgets then
  bind(mainMod .. " + T", hl.dsp.exec_cmd("t3code-desktop"), { description = "Apps: T3 Code" }, "apps.t3-code")
end
bind(mainMod .. " + SHIFT + T", hl.dsp.exec_cmd(terminal .. " btop"), { description = "Apps: System monitor" }, "apps.system-monitor")
bind(mainMod .. " + W", hl.dsp.exec_cmd(web_app("whatsapp")), { description = "Web apps: WhatsApp" }, "webapps.whatsapp")
bind(mainMod .. " + Y", hl.dsp.exec_cmd(web_app("youtube")), { description = "Web apps: YouTube" }, "webapps.youtube")
bind(mainMod .. " + SHIFT + P", hl.dsp.exec_cmd(web_app("google-photos")),
  { description = "Web apps: Google Photos" }, "webapps.google-photos")
bind(mainMod .. " + SHIFT + X", hl.dsp.exec_cmd(web_app("x")), { description = "Web apps: X" }, "webapps.x")
if features.developer_tools then
  bind(mainMod .. " + CTRL + X", hl.dsp.exec_cmd("voxtype --model base --language en record toggle"),
    { description = "Dictation: Dictate in English" }, "dictation.dictate-in-english")
  bind("F9", hl.dsp.exec_cmd("voxtype --model base --language en record toggle"),
    { description = "Dictation: Dictate in English" }, "dictation.dictate-in-english")
  bind("SHIFT + F9", hl.dsp.exec_cmd("voxtype --model base --language nl record toggle"),
    { description = "Dictation: Dictate in Dutch" }, "dictation.dictate-in-dutch")
end

bind(mainMod .. " + C", function() send_shortcut_once("CTRL", "Insert") end, { description = "Clipboard: Copy" }, "clipboard.copy")
bind(mainMod .. " + V", function() send_shortcut_once("SHIFT", "Insert") end, { description = "Clipboard: Paste" }, "clipboard.paste")
bind(mainMod .. " + X", function() send_shortcut_once("CTRL", "X") end, { description = "Clipboard: Cut" }, "clipboard.cut")
bind(mainMod .. " + SHIFT + V", hl.dsp.exec_cmd("clipboard-image-to-file"),
  { description = "Clipboard: Save copied image to a file" }, "clipboard.save-copied-image-to-a-file")
bind(mainMod .. " + CTRL + V", hl.dsp.exec_cmd("cybexos-runtime ipc launcher open clipboard"),
  { description = "Clipboard: Clipboard history" }, "clipboard.history")

bind(mainMod .. " + Q", hl.dsp.window.close(), { description = "Windows: Close window" }, "windows.close")
bind(mainMod .. " + F", function() require("workspaces").toggle_floating() end, { description = "Windows: Toggle floating" }, "windows.toggle-floating")
bind(mainMod .. " + J", hl.dsp.layout("togglesplit"), { description = "Windows: Toggle split" }, "windows.toggle-split")
bind(mainMod .. " + BACKSPACE", hl.dsp.window.set_prop({ prop = "alpha", value = "0.85 toggle" }),
  { description = "Windows: Toggle transparency" }, "windows.toggle-transparency")
-- In-process through Quickshell's global shortcut, like the launcher; the
-- `overview` IPC target serves the touchpad gesture.
bind(mainMod .. " + TAB", hl.dsp.global("quickshell:overviewToggle"), { description = "Windows: Overview" }, "windows.overview")
bind(mainMod .. " + SHIFT + M", hl.dsp.exit(), { description = "Shell: Exit Hyprland" }, "shell.exit")
bind(mainMod .. " + L", hl.dsp.exec_cmd("cybexos-session-action lock"),
  { description = "Shell: Lock screen" }, "shell.lock")
-- Effects, gaps and idle lock off for games; the helper notifies and the
-- menubar shows an indicator while it is on.
bind(mainMod .. " + SHIFT + G", hl.dsp.exec_cmd("game-mode toggle"),
  { description = "Shell: Game mode" }, "shell.game-mode")

for _, direction in ipairs({ "left", "right", "up", "down" }) do
  bind(mainMod .. " + " .. direction, hl.dsp.focus({ direction = direction }),
    { description = "Windows: Move focus" }, "windows.focus." .. direction)
end
for i = 1, 10 do
  local key = i % 10
  local number = i
  bind(mainMod .. " + " .. key, function() require("workspaces").focus(number) end,
    { description = "Workspaces: Switch to workspace " .. i }, "workspaces.switch." .. i)
  bind(mainMod .. " + SHIFT + " .. key, function() require("workspaces").move(nil, number) end,
    { description = "Workspaces: Move window to workspace " .. i }, "workspaces.move." .. i)
end
bind(mainMod .. " + mouse_down", function() require("workspaces").next(1) end, { description = "Workspaces: Next workspace" }, "workspaces.next-workspace")
bind(mainMod .. " + mouse_up", function() require("workspaces").next(-1) end, { description = "Workspaces: Previous workspace" }, "workspaces.previous-workspace")
-- Super+L remains screen lock. These combinations were unused in the baseline.
bind(mainMod .. " + CTRL + L", function() require("workspaces").cycle_layout() end,
  { description = "Workspaces: Cycle workspace layout" }, "workspaces.cycle-workspace-layout")
bind(mainMod .. " + CTRL + ALT + M", function() require("workspaces").minimize() end,
  { description = "Windows: Minimize window" }, "windows.minimize-window")
bind(mainMod .. " + CTRL + M", function() require("workspaces").restore_last() end,
  { description = "Windows: Restore minimized window" }, "windows.restore-minimized-window")
for _, direction in ipairs({ "left", "right", "up", "down" }) do
  local selected = direction
  bind(mainMod .. " + CTRL + SHIFT + " .. direction, function() require("workspaces").move_monitor(selected) end,
    { description = "Windows: Move window to display" }, "windows.move-display." .. direction)
end

-- The scratchpad is a special workspace shown over the current one. Moving a
-- window there leaves it hidden until the scratchpad is shown.
bind(mainMod .. " + minus", hl.dsp.workspace.toggle_special("scratchpad"),
  { description = "Windows: Show or hide the scratchpad" }, "windows.show-or-hide-the-scratchpad")
bind(mainMod .. " + SHIFT + minus", hl.dsp.window.move({ workspace = "special:scratchpad", follow = false }),
  { description = "Windows: Move window to the scratchpad" }, "windows.move-window-to-the-scratchpad")
-- A group stacks windows in one tile with a tab bar; looknfeel themes it.
bind(mainMod .. " + G", hl.dsp.group.toggle(), { description = "Windows: Toggle window group" }, "windows.toggle-window-group")
bind(mainMod .. " + CTRL + G", hl.dsp.window.move({ out_of_group = true }),
  { description = "Windows: Move window out of group" }, "windows.move-window-out-of-group")
bind(mainMod .. " + ALT + left", hl.dsp.group.prev(), { description = "Windows: Previous or next window in group" }, "windows.group-previous")
bind(mainMod .. " + ALT + right", hl.dsp.group.next(), { description = "Windows: Previous or next window in group" }, "windows.group-next")

-- Cursor zoom magnifies the screen around the pointer. The factor is live
-- compositor state and a configuration reload returns it to 1x, so Super+Z
-- always has a way back.
local ZOOM_MIN, ZOOM_MAX, ZOOM_STEP = 1.0, 4.0, 0.5
local function zoom_factor()
  local ok, value = pcall(hl.get_config, "cursor.zoom_factor")
  return ok and tonumber(value) or ZOOM_MIN
end
local function set_zoom(value)
  hl.config({ cursor = { zoom_factor = math.max(ZOOM_MIN, math.min(ZOOM_MAX, value)) } })
end
-- A step moves to the next point on the step grid, even from a factor set
-- some other way.
local function step_zoom(direction)
  local position = zoom_factor() / ZOOM_STEP
  if direction > 0 then
    position = math.floor(position + 0.001) + 1
  else
    position = math.ceil(position - 0.001) - 1
  end
  set_zoom(position * ZOOM_STEP)
end
bind(mainMod .. " + Z", function() set_zoom(zoom_factor() > ZOOM_MIN + 0.01 and ZOOM_MIN or 2.0) end,
  { description = "Windows: Zoom in or out" }, "windows.zoom-in-or-out")
bind(mainMod .. " + CTRL + equal", function() step_zoom(1) end,
  { repeating = true, description = "Windows: Adjust zoom" }, "windows.zoom-in")
bind(mainMod .. " + CTRL + minus", function() step_zoom(-1) end,
  { repeating = true, description = "Windows: Adjust zoom" }, "windows.zoom-out")

bind(mainMod .. " + grave", hl.dsp.exec_cmd("screenshot region"),
  { description = "Capture: Screenshot a region or window" }, "capture.region")
bind(mainMod .. " + SHIFT + grave", hl.dsp.exec_cmd("screen-record"),
  { description = "Capture: Start or stop screen recording" }, "capture.start-or-stop-screen-recording")
bind("Print", hl.dsp.exec_cmd("screenshot region"),
  { description = "Capture: Screenshot a region or window" }, "capture.region")
bind("SHIFT + Print", hl.dsp.exec_cmd("screenshot fullscreen"),
  { description = "Capture: Screenshot the whole screen" }, "capture.screenshot-the-whole-screen")
bind(mainMod .. " + SHIFT + O", hl.dsp.exec_cmd("screen-ocr"),
  { description = "Capture: Copy text or QR code from a region" }, "capture.copy-text-or-qr-code-from-a-region")
-- Pressing the scrolling screenshot's key again finishes it, as do Enter and
-- Escape, which the script binds only while a capture runs.
bind("ALT + Print", hl.dsp.exec_cmd("screenshot scroll"),
  { description = "Capture: Scrolling screenshot" }, "capture.scrolling-screenshot")
bind(mainMod .. " + ALT + grave", hl.dsp.exec_cmd("screenshot scroll"),
  { description = "Capture: Scrolling screenshot" }, "capture.scrolling-screenshot")
bind(mainMod .. " + CTRL + SHIFT + grave", hl.dsp.exec_cmd("screen-record --webcam"),
  { description = "Capture: Record with webcam" }, "capture.record-with-webcam")
bind(mainMod .. " + Print", hl.dsp.exec_cmd("color-picker"),
  { description = "Capture: Pick a colour" }, "capture.pick-a-colour")
bind(mainMod .. " + SHIFT + C", hl.dsp.exec_cmd("color-picker"),
  { description = "Capture: Pick a colour" }, "capture.pick-a-colour")

local volumeUp = "wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%+"
local volumeDown = "wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-"
local volumeMute = "wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"
if features.xps_2026 then
  volumeUp = "xps-speaker-tuning control up || " .. volumeUp
  volumeDown = "xps-speaker-tuning control down || " .. volumeDown
  volumeMute = "xps-speaker-tuning control mute || " .. volumeMute
end
bind("XF86AudioRaiseVolume", hl.dsp.exec_cmd(volumeUp),
  { locked = true, repeating = true, description = "Hardware keys: Volume up" }, "hardware.volume-up")
bind("XF86AudioLowerVolume", hl.dsp.exec_cmd(volumeDown),
  { locked = true, repeating = true, description = "Hardware keys: Volume down" }, "hardware.volume-down")
bind("XF86MonBrightnessUp", hl.dsp.exec_cmd("brightness-control up 5"),
  { locked = true, repeating = true, description = "Hardware keys: Brightness up" }, "hardware.brightness-up")
bind("XF86MonBrightnessDown", hl.dsp.exec_cmd("brightness-control down 5"),
  { locked = true, repeating = true, description = "Hardware keys: Brightness down" }, "hardware.brightness-down")
bind("XF86AudioMute", hl.dsp.exec_cmd(volumeMute), { locked = true, description = "Hardware keys: Mute audio" }, "hardware.mute-audio")
if features.developer_tools then
  bind("XF86AudioMicMute", hl.dsp.exec_cmd("voxtype --model base --language en record toggle"),
    { locked = true, description = "Dictation: Dictate in English" }, "dictation.dictate-in-english")
  bind("SHIFT + XF86AudioMicMute", hl.dsp.exec_cmd("voxtype --model base --language nl record toggle"),
    { locked = true, description = "Dictation: Dictate in Dutch" }, "dictation.dictate-in-dutch")
else
  bind("XF86AudioMicMute", hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle"),
    { locked = true, description = "Hardware keys: Mute microphone" }, "hardware.mute-microphone")
end
bind("XF86AudioPlay", hl.dsp.exec_cmd("playerctl play-pause"), { locked = true, description = "Hardware keys: Play or pause" }, "hardware.play-or-pause")
bind("XF86AudioPause", hl.dsp.exec_cmd("playerctl play-pause"), { locked = true, description = "Hardware keys: Play or pause" }, "hardware.play-or-pause")
bind("XF86AudioNext", hl.dsp.exec_cmd("playerctl next"), { locked = true, description = "Hardware keys: Next track" }, "hardware.next-track")
bind("XF86AudioPrev", hl.dsp.exec_cmd("playerctl previous"), { locked = true, description = "Hardware keys: Previous track" }, "hardware.previous-track")
bind("XF86Calculator", hl.dsp.exec_cmd("gnome-calculator"), { locked = true, description = "Hardware keys: Calculator" }, "hardware.calculator")
bind(mainMod .. " + mouse:272", hl.dsp.window.drag(), { mouse = true, description = "Windows: Move window" }, "windows.move-window")
bind(mainMod .. " + mouse:273", hl.dsp.window.resize(), { mouse = true, description = "Windows: Resize window" }, "windows.resize-window")
bind(mainMod .. " + SHIFT + mouse:272", hl.dsp.window.resize(), { mouse = true, description = "Windows: Resize window" }, "windows.resize-window")

-- Remove handles from the previous load as well as replaced combinations.
-- user.lua still loads last and may replace any of these in the usual way.
function M.install(state)
  for _, keybind in ipairs(rawget(_G, "__cybexos_hypr_binds") or {}) do
    if keybind and keybind.remove then keybind:remove()
    elseif keybind and keybind.unbind then keybind:unbind() end
  end
  _G.__cybexos_hypr_binds = {}
  local function register(key, dispatcher, options)
    hl.unbind(key)
    local keybind = hl.bind(key, dispatcher, options)
    table.insert(_G.__cybexos_hypr_binds, keybind)
  end
  if not state then
    for _, entry in ipairs(M.registrations) do register(entry.keys, entry.dispatcher, entry.options) end
    return
  end
  local helpers = require("keybinding_helpers")
  local rows, emitted = {}, {}
  for _, row in ipairs(state.actions) do rows[row.id] = row end
  for _, entry in ipairs(M.registrations) do
    local row = rows[entry.id]
    if row and not emitted[row.id] then
      emitted[row.id] = true
      for _, key in ipairs(row.keys) do
        local original = entry
        -- Alternatives can have different flags (the dictation microphone
        -- key works while locked). Retain those when that key stays assigned.
        for _, candidate in ipairs(M.registrations) do
          if candidate.id == row.id and helpers.same(candidate.keys, key) then original = candidate; break end
        end
        register(key, original.dispatcher, original.options)
      end
    end
  end
  for _, entry in ipairs(state.custom) do
    local run = entry.run
    local quote = function(value) return "'" .. value:gsub("'", "'\\''") .. "'" end
    local command
    if run.type == "command" then command = run.command
    elseif run.type == "app" then command = "cybexos-runtime ipc launcher launchDesktop " .. quote(run.desktopId)
    elseif run.type == "webapp" then command = "cybexos-webapp launch " .. quote(run.id)
    elseif run.type == "url" then command = "cybexos-apps browser " .. quote(run.url) end
    for _, key in ipairs(entry.keys) do
      register(key, hl.dsp.exec_cmd(command), { description = entry.group .. ": " .. entry.label })
    end
  end
end
M.install()
return M
