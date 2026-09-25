local mainMod = "SUPER"
local terminal = "kitty"
local home = os.getenv("HOME")
local features = require("features")
local browser = "firefox"
local privateBrowser = "firefox --private-window"
if features.proprietary_apps then
  browser = "brave-origin-stable --enable-features=TouchpadOverscrollHistoryNavigation,PipeWireCamera --restore-last-session --hide-crash-restore-bubble"
  privateBrowser = browser .. " --incognito"
end

local function web_app(url)
  if features.proprietary_apps then return browser .. " --app=" .. url end
  return browser .. " " .. url
end

local previous = rawget(_G, "__fedora_hypr_binds") or {}
for _, keybind in ipairs(previous) do
  if keybind and keybind.remove then keybind:remove()
  elseif keybind and keybind.unbind then keybind:unbind() end
end
_G.__fedora_hypr_binds = {}

-- Every binding the user should know about carries a description, "Group:
-- Label". The Super+K cheatsheet is drawn from `hyprctl binds -j`, so these
-- strings are the cheatsheet: a binding without one does not appear there.
-- Bindings added in ~/.config/cybexos/hypr/user.lua join it the same way.
local function bind(keys, dispatcher, opts)
  hl.unbind(keys)
  local keybind = hl.bind(keys, dispatcher, opts)
  table.insert(_G.__fedora_hypr_binds, keybind)
  return keybind
end

local function send_shortcut_once(mods, key)
  hl.dispatch(hl.dsp.send_key_state({ mods = mods, key = key, state = "down" }))
  hl.dispatch(hl.dsp.send_key_state({ mods = mods, key = key, state = "up" }))
end

bind(mainMod .. " + Return", hl.dsp.exec_cmd(terminal), { description = "Apps: Terminal" })
if features.podman then
  bind(mainMod .. " + SHIFT + F", hl.dsp.exec_cmd(terminal .. " -e " .. home .. "/.local/bin/dev-fedora-shell"),
    { description = "Development: Fedora container shell" })
  bind(mainMod .. " + SHIFT + A", hl.dsp.exec_cmd(terminal .. " -e " .. home .. "/.local/bin/dev-arch-shell"),
    { description = "Development: Arch container shell" })
  bind(mainMod .. " + SHIFT + D", hl.dsp.exec_cmd(terminal .. " -e " .. home .. "/.local/bin/dev-debian-shell"),
    { description = "Development: Debian container shell" })
end
bind(mainMod .. " + SPACE", hl.dsp.global("quickshell:launcherToggle"), { description = "Shell: Launcher" })
bind(mainMod .. " + CTRL + SHIFT + A", hl.dsp.exec_cmd(home .. "/.local/bin/cybex agent --window"),
  { description = "Apps: AI agent" })
-- The shell runs from the CybexOS runtime by path, where a bare
-- `qs ipc call` finds no configuration; cybexos-runtime names the active one.
bind(mainMod .. " + comma", hl.dsp.exec_cmd(home .. "/.local/bin/cybexos-runtime ipc settings toggle"),
  { description = "Shell: CybexOS Settings" })
-- Shell surfaces the menubar also opens by click.
bind(mainMod .. " + N", hl.dsp.exec_cmd(home .. "/.local/bin/cybexos-runtime ipc popouts toggle notifications"),
  { description = "Shell: Notifications" })
bind(mainMod .. " + A", hl.dsp.exec_cmd(home .. "/.local/bin/cybexos-runtime ipc popouts toggle control"),
  { description = "Shell: Control Panel" })
bind(mainMod .. " + K", hl.dsp.exec_cmd(home .. "/.local/bin/cybexos-runtime ipc session keys"),
  { description = "Shell: Keyboard shortcuts" })
bind(mainMod .. " + E", hl.dsp.exec_cmd("nautilus --new-window"), { description = "Apps: Files" })
bind(mainMod .. " + B", hl.dsp.exec_cmd(browser), { description = "Apps: Browser" })
bind(mainMod .. " + SHIFT + B", hl.dsp.exec_cmd(privateBrowser), { description = "Apps: Private browser window" })
bind(mainMod .. " + M", hl.dsp.exec_cmd(web_app("https://app.slack.com/")), { description = "Web apps: Slack" })
if features.private_portal then
  bind(mainMod .. " + P", hl.dsp.exec_cmd(home .. "/.local/bin/portal-launcher"), { description = "Apps: Portal" })
end
bind(mainMod .. " + S", hl.dsp.exec_cmd("spotify"), { description = "Apps: Spotify" })
if features.proprietary_apps then
  bind(mainMod .. " + SHIFT + SLASH", hl.dsp.exec_cmd("1password"), { description = "Apps: 1Password" })
end
if features.developer_tools then
  -- Docker group membership is root-equivalent and opt-in, so without it the
  -- socket is reachable only through sudo. The binary is resolved before
  -- sudo because sudo's secure_path need not include /usr/local/bin.
  local lazydocker = [[sh -c 'docker info >/dev/null 2>&1 && exec lazydocker; exec sudo "$(command -v lazydocker)"']]
  bind(mainMod .. " + D", hl.dsp.exec_cmd(terminal .. " -e " .. lazydocker),
    { description = "Development: Docker (lazydocker)" })
end
if features.connected_widgets then
  bind(mainMod .. " + T", hl.dsp.exec_cmd("t3code-desktop"), { description = "Apps: T3 Code" })
end
bind(mainMod .. " + SHIFT + T", hl.dsp.exec_cmd(terminal .. " -e btop"), { description = "Apps: System monitor" })
bind(mainMod .. " + W", hl.dsp.exec_cmd(web_app("https://web.whatsapp.com/")), { description = "Web apps: WhatsApp" })
bind(mainMod .. " + Y", hl.dsp.exec_cmd(web_app("https://youtube.com/")), { description = "Web apps: YouTube" })
bind(mainMod .. " + SHIFT + P", hl.dsp.exec_cmd(web_app("https://photos.google.com/")),
  { description = "Web apps: Google Photos" })
bind(mainMod .. " + SHIFT + X", hl.dsp.exec_cmd(web_app("https://x.com/")), { description = "Web apps: X" })
if features.developer_tools then
  bind(mainMod .. " + CTRL + X", hl.dsp.exec_cmd("voxtype --model base --language en record toggle"),
    { description = "Dictation: Dictate in English" })
  bind("F9", hl.dsp.exec_cmd("voxtype --model base --language en record toggle"),
    { description = "Dictation: Dictate in English" })
  bind("SHIFT + F9", hl.dsp.exec_cmd("voxtype --model base --language nl record toggle"),
    { description = "Dictation: Dictate in Dutch" })
end

bind(mainMod .. " + C", function() send_shortcut_once("CTRL", "Insert") end, { description = "Clipboard: Copy" })
bind(mainMod .. " + V", function() send_shortcut_once("SHIFT", "Insert") end, { description = "Clipboard: Paste" })
bind(mainMod .. " + X", function() send_shortcut_once("CTRL", "X") end, { description = "Clipboard: Cut" })
bind(mainMod .. " + SHIFT + V", hl.dsp.exec_cmd(home .. "/.local/bin/clipboard-image-to-file"),
  { description = "Clipboard: Save copied image to a file" })

bind(mainMod .. " + Q", hl.dsp.window.close(), { description = "Windows: Close window" })
bind(mainMod .. " + F", hl.dsp.window.float({ action = "toggle" }), { description = "Windows: Toggle floating" })
bind(mainMod .. " + J", hl.dsp.layout("togglesplit"), { description = "Windows: Toggle split" })
bind(mainMod .. " + BACKSPACE", hl.dsp.window.set_prop({ prop = "alpha", value = "0.85 toggle" }),
  { description = "Windows: Toggle transparency" })
bind(mainMod .. " + SHIFT + M", hl.dsp.exit(), { description = "Shell: Exit Hyprland" })
bind(mainMod .. " + L", hl.dsp.exec_cmd("systemctl --user start cybexos-session-lock.service"),
  { description = "Shell: Lock screen" })

for _, direction in ipairs({ "left", "right", "up", "down" }) do
  bind(mainMod .. " + " .. direction, hl.dsp.focus({ direction = direction }),
    { description = "Windows: Move focus" })
end
for i = 1, 10 do
  local key = i % 10
  bind(mainMod .. " + " .. key, hl.dsp.focus({ workspace = i }),
    { description = "Workspaces: Switch to workspace " .. i })
  bind(mainMod .. " + SHIFT + " .. key, hl.dsp.window.move({ workspace = i }),
    { description = "Workspaces: Move window to workspace " .. i })
end
bind(mainMod .. " + mouse_down", hl.dsp.focus({ workspace = "e+1" }), { description = "Workspaces: Next workspace" })
bind(mainMod .. " + mouse_up", hl.dsp.focus({ workspace = "e-1" }), { description = "Workspaces: Previous workspace" })

bind(mainMod .. " + grave", hl.dsp.exec_cmd(home .. "/.local/bin/screenshot region"),
  { description = "Capture: Screenshot a region" })
bind(mainMod .. " + SHIFT + grave", hl.dsp.exec_cmd(home .. "/.local/bin/screen-record"),
  { description = "Capture: Start or stop screen recording" })
bind("Print", hl.dsp.exec_cmd(home .. "/.local/bin/screenshot region"), { description = "Capture: Screenshot a region" })
bind("SHIFT + Print", hl.dsp.exec_cmd(home .. "/.local/bin/screenshot fullscreen"),
  { description = "Capture: Screenshot the whole screen" })
bind(mainMod .. " + SHIFT + O", hl.dsp.exec_cmd(home .. "/.local/bin/screen-ocr"),
  { description = "Capture: Copy text from a region (OCR)" })

local volumeUp = "wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%+"
local volumeDown = "wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-"
local volumeMute = "wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"
if features.xps_2026 then
  volumeUp = "/usr/local/libexec/xps-speaker-tuning control up || " .. volumeUp
  volumeDown = "/usr/local/libexec/xps-speaker-tuning control down || " .. volumeDown
  volumeMute = "/usr/local/libexec/xps-speaker-tuning control mute || " .. volumeMute
end
bind("XF86AudioRaiseVolume", hl.dsp.exec_cmd(volumeUp),
  { locked = true, repeating = true, description = "Hardware keys: Volume up" })
bind("XF86AudioLowerVolume", hl.dsp.exec_cmd(volumeDown),
  { locked = true, repeating = true, description = "Hardware keys: Volume down" })
bind("XF86MonBrightnessUp", hl.dsp.exec_cmd(home .. "/.local/bin/brightness-control up 5"),
  { locked = true, repeating = true, description = "Hardware keys: Brightness up" })
bind("XF86MonBrightnessDown", hl.dsp.exec_cmd(home .. "/.local/bin/brightness-control down 5"),
  { locked = true, repeating = true, description = "Hardware keys: Brightness down" })
bind("XF86AudioMute", hl.dsp.exec_cmd(volumeMute), { locked = true, description = "Hardware keys: Mute audio" })
if features.developer_tools then
  bind("XF86AudioMicMute", hl.dsp.exec_cmd("voxtype --model base --language en record toggle"),
    { locked = true, description = "Dictation: Dictate in English" })
  bind("SHIFT + XF86AudioMicMute", hl.dsp.exec_cmd("voxtype --model base --language nl record toggle"),
    { locked = true, description = "Dictation: Dictate in Dutch" })
else
  bind("XF86AudioMicMute", hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle"),
    { locked = true, description = "Hardware keys: Mute microphone" })
end
bind("XF86AudioPlay", hl.dsp.exec_cmd("playerctl play-pause"), { locked = true, description = "Hardware keys: Play or pause" })
bind("XF86AudioPause", hl.dsp.exec_cmd("playerctl play-pause"), { locked = true, description = "Hardware keys: Play or pause" })
bind("XF86AudioNext", hl.dsp.exec_cmd("playerctl next"), { locked = true, description = "Hardware keys: Next track" })
bind("XF86AudioPrev", hl.dsp.exec_cmd("playerctl previous"), { locked = true, description = "Hardware keys: Previous track" })
bind("XF86Calculator", hl.dsp.exec_cmd("gnome-calculator"), { locked = true, description = "Hardware keys: Calculator" })
bind(mainMod .. " + mouse:272", hl.dsp.window.drag(), { mouse = true, description = "Windows: Move window" })
bind(mainMod .. " + mouse:273", hl.dsp.window.resize(), { mouse = true, description = "Windows: Resize window" })
bind(mainMod .. " + SHIFT + mouse:272", hl.dsp.window.resize(), { mouse = true, description = "Windows: Resize window" })
