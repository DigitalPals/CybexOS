// Power saver is the user's explicit request to trade polish for battery.
// The shell follows it with its reduced-motion path; the compositor follows
// it with fewer blur passes and no animations.
const test = require("node:test");
const assert = require("node:assert/strict");
const childProcess = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const vm = require("node:vm");
const { shellDir } = require("./shell.cjs");

function read(relative) {
    return fs.readFileSync(path.join(shellDir, relative), "utf8");
}

function functionSource(source, name) {
    const match = source.match(new RegExp("^    function " + name + "\\([^]*?^    }", "m"));
    assert.ok(match, `function ${name} not found`);
    return match[0];
}

const luajit = ["/usr/bin/luajit", "/usr/local/bin/luajit"].find(file => fs.existsSync(file))
    || (childProcess.spawnSync("sh", ["-c", "command -v luajit"], { encoding: "utf8" })
        .stdout.trim() || null);

// Renders looknfeel.lua.j2 (its one Jinja expression is a hardware gate) and
// runs `driver` after it under luajit with a recording `hl` double.
function runLookAndFeel(driver, files) {
    const scratch = fs.mkdtempSync(path.join(os.tmpdir(), "cybexos-looknfeel-"));
    try {
        const template = fs.readFileSync(
            path.resolve(shellDir, "../../templates/looknfeel.lua.j2"), "utf8");
        const look = path.join(scratch, "looknfeel.lua");
        fs.writeFileSync(look, template.replace(/\{\{.*?\}\}/g, "false"));
        const home = path.join(scratch, "home");
        fs.mkdirSync(home);
        for (const [relative, text] of Object.entries(files || {})) {
            fs.mkdirSync(path.dirname(path.join(home, relative)), { recursive: true });
            fs.writeFileSync(path.join(home, relative), text);
        }
        const script = path.join(scratch, "driver.lua");
        fs.writeFileSync(script, `
local look = ${JSON.stringify(look)}
local live = {}
local config_calls = 0
local layer_rules = {}
local function merge(target, source)
  for key, value in pairs(source) do
    if type(value) == "table" then
      if type(target[key]) ~= "table" then target[key] = {} end
      merge(target[key], value)
    else
      target[key] = value
    end
  end
end
hl = {}
function hl.config(values) config_calls = config_calls + 1; merge(live, values) end
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
function hl.layer_rule(spec)
  local rule = { enabled = spec.enabled }
  function rule:set_enabled(value) self.enabled = value end
  layer_rules[spec.name] = rule
  return rule
end
function hl.workspace_rule() return { set_enabled = function() end } end
function hl.get_monitors() return {} end
function hl.on() return { remove = function() end } end
local function passes() return hl.get_config("decoration.blur.passes") end
local function animations() return hl.get_config("animations.enabled") end
local function calls() return config_calls end
${driver}
print("LOOKNFEEL_OK")
`);
        const result = childProcess.spawnSync(luajit, [script], {
            encoding: "utf8", env: { PATH: process.env.PATH, HOME: home }
        });
        assert.equal(result.status, 0, result.stderr || result.stdout);
        assert.match(result.stdout, /LOOKNFEEL_OK/);
    } finally {
        fs.rmSync(scratch, { recursive: true, force: true });
    }
}

test("power saver takes the reduced-motion path without changing the setting", () => {
    const theme = read("Common/Theme.qml");
    assert.match(theme,
        /readonly property bool reducedMotion:\s*Settings\.reducedMotion \|\| Activity\.powerSaver\s*\|\|/);
    // The Appearance switch keeps showing what the user chose.
    for (const file of ["Common/Theme.qml", "Common/Activity.qml"])
        assert.doesNotMatch(read(file), /Settings\.(?:set\("reducedMotion"|reducedMotion\s*=[^=])/, file);
    // Everything that moves reads Theme's answer, plugins included; the raw
    // setting misses power saver and the environment override.
    const walk = dir => fs.readdirSync(dir, { withFileTypes: true }).flatMap(entry => {
        const full = path.join(dir, entry.name);
        if (entry.isDirectory())
            return entry.name === "scripts" ? [] : walk(full);
        return /\.(?:qml|js)$/.test(entry.name) ? [full] : [];
    });
    for (const file of walk(shellDir)) {
        const label = path.relative(shellDir, file);
        if (label === path.join("Common", "Theme.qml"))
            continue;
        assert.doesNotMatch(fs.readFileSync(file, "utf8"), /Settings\.reducedMotion\b(?!\s*=[^=])/,
            `${label} must read Theme.reducedMotion`);
    }
    assert.match(read("Bar/UserWidgets.qml"), /reducedMotion: Theme\.reducedMotion/,
        "plugin widgets follow power saver too");
});

test("the clock's text transition snaps instead of animating at zero duration", () => {
    const text = read("Common/AnimatedText.qml");
    assert.match(text,
        /Behavior on text \{\s*enabled: root\.animateChange && !Theme\.reducedMotion/,
        "a zero-duration transition still runs through the animation driver every minute");
});

test("power saver drops compositor blur and animations, and restores what it replaced",
    { skip: luajit ? false : "luajit is not installed" }, () => {
    runLookAndFeel(`
dofile(look)
assert(passes() == 3 and animations() == true, "the configured values")
-- A user.lua override is what comes back afterwards.
hl.config({ decoration = { blur = { passes = 2 } } })

cybexos_power_saver(true)
assert(passes() == 1 and animations() == false, "power saver")
local before = calls()
cybexos_power_saver(true)
assert(calls() == before, "a repeated request is a no-op")

-- A config reload re-applies the full values and must take the saver back up.
dofile(look)
assert(passes() == 1 and animations() == false, "power saver survives a reload")

cybexos_power_saver(false)
assert(passes() == 2 and animations() == true, "restores what the saver replaced")
before = calls()
cybexos_power_saver(false)
assert(calls() == before, "the shell's startup request touches nothing when off")

-- A compositor restart starts a fresh state; the shell re-sends its request.
_G.__cybexos_power_saver = nil
dofile(look)
assert(passes() == 3 and animations() == true)
`);
});

test("the shell sends the power profile to the compositor on startup and on change", () => {
    const settings = read("Common/Settings.qml");
    const context = {
        Activity: { powerSaver: true },
        powerSaverProc: { running: false, command: [] },
        dispatchedPowerSaver: false
    };
    vm.createContext(context);
    vm.runInContext(functionSource(settings, "applyPowerSaver"), context);
    context.applyPowerSaver();
    assert.deepEqual([...context.powerSaverProc.command],
        ["hyprctl", "eval", "cybexos_power_saver(true)"]);
    assert.equal(context.powerSaverProc.running, true);
    context.Activity.powerSaver = false;
    context.applyPowerSaver();
    assert.equal(context.dispatchedPowerSaver, true, "a busy hyprctl is replayed, not raced");

    assert.match(settings,
        /Connections \{\s*target: Activity\s*function onPowerSaverChanged\(\) \{\s*root\.applyPowerSaver\(\);/);
    assert.match(settings, /Component\.onCompleted: \{[\s\S]*?applyPowerSaver\(\);\s*\}\s*\}\s*$/);
    const proc = settings.slice(settings.indexOf("id: powerSaverProc"));
    assert.match(proc, /exitSeen \? lastExit : ProcHelpers\.NOT_STARTED/);
    assert.match(proc,
        /if \(root\.dispatchedPowerSaver !== Activity\.powerSaver\)\s*powerSaverReplayTimer\.restart\(\)/);
    const look = fs.readFileSync(
        path.resolve(shellDir, "../../templates/looknfeel.lua.j2"), "utf8");
    assert.match(look, /^function cybexos_power_saver\(enabled\)$/m,
        "the eval handle must be a global");
});

test("compositor blur follows the shell's glass default when nothing is stored",
    { skip: luajit ? false : "luajit is not installed" }, () => {
    const defaults = require("./shell.cjs").load("SettingsHelpers.js").defaults();
    assert.equal(defaults.glassEnabled, false, "this test pins the Lua fallback to that default");
    const glass = value => `dofile(look)
assert(layer_rules["quickshell-blur"].enabled == ${value},
  "quickshell-blur enabled = " .. tostring(layer_rules["quickshell-blur"].enabled))`;
    runLookAndFeel(glass(false));
    runLookAndFeel(glass(false), { ".config/cybexos/shell.json": '{"v": 23, "barHeight": 40}' });
    runLookAndFeel(glass(true), { ".config/cybexos/shell.json": '{"v": 23, "glassEnabled": true}' });
    runLookAndFeel(glass(false), { ".config/cybexos/shell.json": '{"v": 23, "glassEnabled": false}' });
    runLookAndFeel(glass(true),
        { ".local/state/quickshell/shell-settings.json": '{\n  "glassEnabled": true\n}' });
});
