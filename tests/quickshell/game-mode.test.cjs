// Game mode trades the compositor's polish for frame time while a game runs:
// looknfeel.lua turns animations, blur, shadows, rounding and gaps off and
// puts back exactly what it replaced, the game-mode helper records the state
// (tests/game-mode.py), and the menubar shows an indicator only while it is on.
const test = require("node:test");
const assert = require("node:assert/strict");
const childProcess = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { shellDir, load } = require("./shell.cjs");

function read(relative) {
    return fs.readFileSync(path.join(shellDir, relative), "utf8");
}

const luajit = ["/usr/bin/luajit", "/usr/local/bin/luajit"].find(file => fs.existsSync(file))
    || (childProcess.spawnSync("sh", ["-c", "command -v luajit"], { encoding: "utf8" })
        .stdout.trim() || null);

// Renders looknfeel.lua.j2 (its one Jinja expression is a hardware gate) and
// runs `driver` after it under luajit with a recording `hl` double. `state`
// is written as the helper's runtime file; `env` adds to the environment.
function runLookAndFeel(driver, { state, env } = {}) {
    const scratch = fs.mkdtempSync(path.join(os.tmpdir(), "cybexos-game-mode-"));
    try {
        const template = fs.readFileSync(
            path.resolve(shellDir, "../../templates/looknfeel.lua.j2"), "utf8");
        const look = path.join(scratch, "looknfeel.lua");
        fs.writeFileSync(look, template.replace(/\{\{.*?\}\}/g, "false"));
        const home = path.join(scratch, "home");
        const runtime = path.join(scratch, "runtime");
        fs.mkdirSync(home);
        fs.mkdirSync(path.join(runtime, "cybexos"), { recursive: true });
        if (state !== undefined)
            fs.writeFileSync(path.join(runtime, "cybexos/game-mode.json"), state);
        const script = path.join(scratch, "driver.lua");
        fs.writeFileSync(script, `
local look = ${JSON.stringify(look)}
local live = {}
local listeners = {}
local workspace_rules = {}
local monitors = {}
local function merge(target, source)
  for key, value in pairs(source) do
    if type(value) == "table" and not value.top then
      if type(target[key]) ~= "table" then target[key] = {} end
      merge(target[key], value)
    else
      target[key] = value
    end
  end
end
hl = {}
function hl.config(values) merge(live, values) end
function hl.get_config(key)
  local node = live
  for part in key:gmatch("[^.]+") do
    if type(node) ~= "table" then return nil end
    node = node[part]
  end
  return node
end
function hl.curve() end
function hl.animation() end
function hl.window_rule() end
function hl.layer_rule() return { set_enabled = function() end } end
function hl.workspace_rule(spec)
  local rule = { spec = spec, enabled = true }
  function rule:set_enabled(value) self.enabled = value end
  workspace_rules[#workspace_rules + 1] = rule
  return rule
end
function hl.get_monitors() return monitors end
function hl.on(event, callback)
  listeners[event] = listeners[event] or {}
  table.insert(listeners[event], callback)
  return { remove = function() end }
end
local function emit(event)
  for _, callback in ipairs(listeners[event] or {}) do callback() end
end
local function get(key) return hl.get_config(key) end
local function enabled_rules()
  local count = 0
  for _, rule in ipairs(workspace_rules) do if rule.enabled then count = count + 1 end end
  return count
end
local function in_game_mode()
  return get("animations.enabled") == false and get("decoration.blur.enabled") == false
    and get("decoration.shadow.enabled") == false and get("decoration.rounding") == 0
    and get("general.gaps_in") == 0 and get("general.gaps_out") == 0
end
${driver}
print("GAME_MODE_OK")
`);
        const result = childProcess.spawnSync(luajit, [script], {
            encoding: "utf8",
            env: { PATH: process.env.PATH, HOME: home, XDG_RUNTIME_DIR: runtime,
                   HYPRLAND_INSTANCE_SIGNATURE: "instance-one", ...(env || {}) }
        });
        assert.equal(result.status, 0, result.stderr || result.stdout);
        assert.match(result.stdout, /GAME_MODE_OK/);
    } finally {
        fs.rmSync(scratch, { recursive: true, force: true });
    }
}

const skip = { skip: luajit ? false : "luajit is not installed" };

test("game mode turns the polish off and restores exactly what it replaced", skip, () => {
    runLookAndFeel(`
dofile(look)
assert(get("animations.enabled") == true and get("decoration.rounding") == 16)
-- user.lua runs after looknfeel; its values are what must come back.
hl.config({ general = { gaps_in = { top = 2, right = 3, bottom = 2, left = 3 } }, decoration = { rounding = 7 } })
assert(cybexos_game_mode(true) == true)
assert(in_game_mode(), "game mode values")
assert(__cybexos_game_mode.restore["general.gaps_out"] == 10)
assert(cybexos_game_mode(true) == true and in_game_mode(), "a repeated request is a no-op")
assert(cybexos_game_mode(false) == false)
local gaps = get("general.gaps_in")
assert(type(gaps) == "table" and gaps.top == 2 and gaps.right == 3, "the user's gaps come back")
assert(get("decoration.rounding") == 7 and get("general.gaps_out") == 10)
assert(get("animations.enabled") == true and get("decoration.blur.enabled") == true
  and get("decoration.shadow.enabled") == true)
assert(cybexos_game_mode(false) == false and get("decoration.rounding") == 7, "off twice touches nothing")
`);
});

test("game mode and power saver hand animations back in either order", skip, () => {
    runLookAndFeel(`
dofile(look)
-- Game mode first, power saver second; game mode switched off first.
cybexos_game_mode(true)
cybexos_power_saver(true)
cybexos_game_mode(false)
assert(get("animations.enabled") == false and get("decoration.blur.passes") == 1,
  "power saver keeps animations off after game mode ends")
assert(get("decoration.rounding") == 16 and get("decoration.blur.enabled") == true)
cybexos_power_saver(false)
assert(get("animations.enabled") == true, "the original animations come back")

-- Game mode first, power saver second; power saver switched off first.
cybexos_game_mode(true)
cybexos_power_saver(true)
cybexos_power_saver(false)
assert(get("animations.enabled") == false, "game mode keeps animations off")
cybexos_game_mode(false)
assert(get("animations.enabled") == true)

-- Power saver first.
cybexos_power_saver(true)
cybexos_game_mode(true)
cybexos_game_mode(false)
assert(get("animations.enabled") == false, "power saver still holds animations off")
cybexos_power_saver(false)
assert(get("animations.enabled") == true)
cybexos_power_saver(true)
cybexos_game_mode(true)
cybexos_power_saver(false)
assert(get("animations.enabled") == false and in_game_mode())
cybexos_game_mode(false)
assert(get("animations.enabled") == true and get("decoration.blur.passes") == 1)
`);
});

test("game mode suspends the lone-window margins, including new ones", skip, () => {
    runLookAndFeel(`
monitors = { { name = "DP-1", width = 2560, height = 1440, scale = 1, transform = 0, is_mirror = false } }
dofile(look)
assert(enabled_rules() == 1, "an external display gets its lone-window margins")
cybexos_game_mode(true)
assert(enabled_rules() == 0, "game mode turns every gap off")
monitors[2] = { name = "HDMI-A-1", width = 1920, height = 1080, scale = 1, transform = 0, is_mirror = false }
emit("monitor.layout_changed")
assert(#workspace_rules == 2 and enabled_rules() == 0, "a display plugged in during game mode stays gapless")
cybexos_game_mode(false)
assert(enabled_rules() == 2)
`);
});

test("a configuration reload applies game mode again after user.lua", skip, () => {
    const on = JSON.stringify({ active: true, instance: "instance-one", since: 1 });
    runLookAndFeel(`
dofile(look)
assert(get("animations.enabled") == true, "nothing changes before the configuration has loaded")
-- user.lua, loaded after looknfeel, still counts as the value to restore.
hl.config({ general = { gaps_out = 24 } })
emit("config.reloaded")
assert(in_game_mode() and __cybexos_game_mode.error == nil)
cybexos_game_mode(false)
assert(get("general.gaps_out") == 24 and get("animations.enabled") == true)
`, { state: on });

    const untouched = `
dofile(look)
emit("config.reloaded")
assert(get("animations.enabled") == true and get("general.gaps_out") == 10)
assert(__cybexos_game_mode.restore == nil)
`;
    for (const state of [
        JSON.stringify({ active: true, instance: "instance-zero", since: 1 }),
        JSON.stringify({ active: false, instance: "instance-one" }),
        JSON.stringify({ active: "true", instance: "instance-one" }),
        JSON.stringify({ instance: "instance-one" }),
        '{"active": true, "instance": "instance-one"' + " ".repeat(5000) + "}",
        "{",
        "",
    ])
        runLookAndFeel(untouched, { state });
    runLookAndFeel(untouched, { state: on, env: { XDG_RUNTIME_DIR: "" } });
    runLookAndFeel(untouched, { state: on, env: { HYPRLAND_INSTANCE_SIGNATURE: "" } });
});

test("the shell reads game mode for this compositor instance only", () => {
    const state = load("GameModeState.js");
    const on = JSON.stringify({ active: true, instance: "a1", since: 3 });
    assert.equal(state.isActive(on, "a1"), true);
    assert.equal(state.isActive(on, "b2"), false, "a file from an earlier login");
    assert.equal(state.isActive(on, ""), false);
    for (const text of ["", "{", "[]", "null", '"on"', '{"active":"true","instance":"a1"}',
                        '{"active":true}', '{"active":false,"instance":"a1"}', undefined,
                        JSON.stringify({ active: true, instance: "a1", pad: "x".repeat(5000) })])
        assert.equal(state.isActive(text, "a1"), false, String(text).slice(0, 40));

    const singleton = read("Common/GameMode.qml");
    assert.match(singleton, /^pragma Singleton/m);
    assert.match(singleton, /"\/cybexos"/);
    assert.match(singleton, /path: root\.stateDir \+ "\/game-mode\.json"/);
    assert.match(singleton, /watchChanges: true/);
    assert.match(singleton, /GameModeState\.isActive\(text\(\), root\.instance\)/);
    assert.match(singleton, /Quickshell\.env\("HYPRLAND_INSTANCE_SIGNATURE"\)/);
    assert.match(singleton, /\["mkdir", "-p", "-m", "0700", root\.stateDir\]/,
        "the directory watch needs the directory before game mode first starts");
    assert.match(singleton,
        /function turnOff\(\) \{\s*Quickshell\.execDetached\(\[root\.helper, "off"\]\);/);
    assert.match(singleton, /Quickshell\.env\("HOME"\) \+ "\/\.local\/bin\/game-mode"/);
    assert.match(read("Common/qmldir"), /^singleton GameMode GameMode\.qml$/m);
});

test("the indicator appears only while game mode is on and its click turns it off", () => {
    const indicators = read("Bar/Modules/Indicators.qml");
    const helpers = load("SettingsHelpers.js");
    assert.ok(!helpers.INDICATOR_ACTION_IDS.includes("game-mode"),
        "game mode is not a configurable action with an inactive form");
    assert.match(indicators,
        /\.concat\(GameMode\.active \? \[gameModeAction\.id\] : \[\]\)/,
        "it joins the active block only while on");
    assert.match(indicators, /SysInfo\.idleInhibited, GameMode\.active\s*\]\.join/);
    assert.match(indicators, /case "game-mode": return GameMode\.active;/);
    assert.match(indicators, /case "game-mode":\s*return "Turn off game mode";/);
    assert.match(indicators, /case "game-mode":\s*GameMode\.turnOff\(\);\s*break;/);
    assert.match(indicators, /glyph: "sports_esports"/);
    // The inactive disclosure is built from the configurable actions alone.
    const inactive = indicators.match(/readonly property string inactiveActionsKey: \{([\s\S]*?)\n    \}/)[1];
    assert.doesNotMatch(inactive, /GameMode|gameMode/);
    assert.equal(load("TablerGlyphs.js").resolve("sports_esports").outline,
        load("TablerGlyphs.js").GLYPHS["device-gamepad-2"].outline);
});
