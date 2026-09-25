// The Hyprland system theme target: scripts/theme_hyprland.py renders a
// data-only table of compositor colours, and looknfeel.lua applies it at
// config load and, through cybexos_system_theme(), to a running compositor.
const test = require("node:test");
const assert = require("node:assert/strict");
const childProcess = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");
const { shellDir } = require("./shell.cjs");
const {
    darkTokens, lightTokens, scratch, runDriver, renderTarget, stubBin,
} = require("./system-theme.cjs");

const template = fs.readFileSync(
    path.resolve(shellDir, "../../templates/looknfeel.lua.j2"), "utf8");
const luajit = ["/usr/bin/luajit", "/usr/local/bin/luajit"].find(file => fs.existsSync(file))
    || (childProcess.spawnSync("sh", ["-c", "command -v luajit"], { encoding: "utf8" })
        .stdout.trim() || null);
const needsLua = { skip: luajit ? false : "luajit is not installed" };

const COLOR = /^rgba?\((?:[0-9a-f]{6}|[0-9a-f]{8})\)$/;

function themeKeys() {
    const block = template.match(/local THEME_KEYS = \{([^]*?)\n\}/);
    assert.ok(block, "THEME_KEYS not found in looknfeel.lua.j2");
    return [...block[1].matchAll(/"([\w.]+)"/g)].map(m => m[1]);
}

// {dotted key: value} for a rendered file. The format is small and fixed:
// one `key = {` or `key = "value",` per line.
function leaves(lua) {
    const values = {};
    const stack = [];
    for (const line of lua.split("\n")) {
        let m;
        if ((m = line.match(/^\s*(\w+) = \{$/)))
            stack.push(m[1]);
        else if ((m = line.match(/^\s*(\w+) = "([^"]*)",$/)))
            values[[...stack, m[1]].join(".")] = m[2];
        else if (/^\s*\},?$/.test(line))
            stack.pop();
    }
    return values;
}

function render(tokens) {
    const files = renderTarget("hyprland", tokens);
    assert.deepEqual(Object.keys(files), ["hyprland.lua"]);
    return files["hyprland.lua"];
}

test("the theme renders a data-only table of exactly the keys looknfeel accepts", () => {
    const keys = themeKeys();
    for (const tokens of [darkTokens(), lightTokens()]) {
        const lua = render(tokens);
        assert.equal(render(tokens), lua, "rendering is deterministic");
        const code = lua.split("\n").filter(line => !line.startsWith("--")).join("\n");
        assert.match(code, /^return \{\n[^]*\n\}\n$/);
        // No calls, no expressions: nothing but tables and colour strings.
        assert.doesNotMatch(code.replace(/"[^"\n]*"/g, '""'), /[()[\]+\-*/.:;#~^]/);
        const values = leaves(lua);
        assert.deepEqual(Object.keys(values).sort(), [...keys].sort());
        for (const [key, value] of Object.entries(values))
            assert.match(value, COLOR, key);
        // Rounding is Theme.surfaceRadius, never the theme's to change, and
        // glass and power saver own blur and animations.
        assert.doesNotMatch(code, /rounding|blur|animations|border_size/);
    }
});

test("the compositor colours follow the shell's tokens", () => {
    const dark = leaves(render(darkTokens()));
    assert.equal(dark["general.col.active_border"], "rgb(d3d283)");
    assert.equal(dark["general.col.inactive_border"], "rgb(3a3936)");
    assert.equal(dark["group.col.border_locked_active"], "rgb(ff8f8f)");
    assert.equal(dark["group.groupbar.col.active"], "rgb(d3d283)");
    assert.equal(dark["group.groupbar.text_color"], "rgb(f2f0ea)");
    assert.equal(dark["decoration.shadow.color"], "rgba(1a1917ee)");

    const tokens = lightTokens();
    tokens.colors.accent = "#3366cc";
    const light = leaves(render(tokens));
    assert.equal(light["general.col.active_border"], "rgb(3366cc)");
    assert.equal(light["group.col.border_active"], "rgb(3366cc)");
    assert.equal(light["group.col.border_locked_active"], "rgb(c22f2f)");
    assert.equal(light["group.groupbar.text_color"], "rgb(1f1d2b)");
    assert.equal(light["group.groupbar.text_color_inactive"], "rgb(43415a)");
    // A light shadow is the ink, faint; never the pale base nearly opaque.
    assert.equal(light["decoration.shadow.color"], "rgba(1f1d2b30)");
});

test("looknfeel's vendor colours are the theme for the default dark tokens", () => {
    // Text-level, so it runs without luajit: every rendered leaf name appears
    // exactly once in the vendor hl.config, with the rendered value.
    const vendor = template.slice(template.indexOf("hl.config({"),
        template.indexOf("\n})\n", template.indexOf("hl.config({")));
    for (const [key, value] of Object.entries(leaves(render(darkTokens())))) {
        const name = key.split(".").pop();
        const found = [...vendor.matchAll(new RegExp(`\\b${name} = "([^"]*)"`, "g"))];
        assert.equal(found.length, 1, `${name} appears once in the vendor config`);
        assert.equal(found[0][1], value, key);
    }
});

// Runs looknfeel.lua under luajit with a recording `hl` double and `driver`
// after it. `files` are written under the scratch HOME, and "$HOME" in an
// `env` value is replaced with it.
function runLook(t, driver, files, env) {
    const root = scratch(t);
    const look = path.join(root, "looknfeel.lua");
    fs.writeFileSync(look, template.replace(/\{\{.*?\}\}/g, "false"));
    const home = path.join(root, "home");
    fs.mkdirSync(home);
    for (const [relative, text] of Object.entries(files || {})) {
        fs.mkdirSync(path.dirname(path.join(home, relative)), { recursive: true });
        fs.writeFileSync(path.join(home, relative), text);
    }
    const expected = {
        dark: leaves(render(darkTokens())), light: leaves(render(lightTokens())),
    };
    const script = path.join(root, "driver.lua");
    fs.writeFileSync(script, `
local look = ${JSON.stringify(look)}
local home = ${JSON.stringify(home)}
local theme_file = home .. "/.local/state/cybexos/theme/hyprland.lua"
local keys = { ${themeKeys().map(k => JSON.stringify(k)).join(", ")} }
local expected = {
  dark = { ${Object.entries(expected.dark).map(([k, v]) => `["${k}"] = "${v}"`).join(", ")} },
  light = { ${Object.entries(expected.light).map(([k, v]) => `["${k}"] = "${v}"`).join(", ")} },
}
local live = {}
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
function hl.layer_rule(spec)
  local rule = { enabled = spec.enabled }
  function rule:set_enabled(value) self.enabled = value end
  layer_rules[spec.name] = rule
  return rule
end
function hl.workspace_rule() return { set_enabled = function() end } end
function hl.get_monitors() return {} end
function hl.on() return { remove = function() end } end
local function assert_theme(name)
  for _, key in ipairs(keys) do
    assert(hl.get_config(key) == expected[name][key], key .. " = " .. tostring(hl.get_config(key))
      .. ", expected the " .. name .. " theme's " .. expected[name][key])
  end
end
local function write(path, text)
  local file = assert(io.open(path, "w"))
  file:write(text)
  file:close()
end
${driver}
print("LOOKNFEEL_OK")
`);
    const result = childProcess.spawnSync(luajit, [script], {
        encoding: "utf8", env: {
            PATH: process.env.PATH, HOME: home,
            ...Object.fromEntries(Object.entries(env || {})
                .map(([name, value]) => [name, value.replace("$HOME", home)])),
        },
    });
    assert.equal(result.status, 0, result.stderr || result.stdout);
    assert.match(result.stdout, /LOOKNFEEL_OK/);
}

const THEME = ".local/state/cybexos/theme/hyprland.lua";

test("without a theme file the compositor starts on the default dark theme", needsLua, t => {
    runLook(t, `dofile(look)
assert_theme("dark")
assert(__cybexos_system_theme.error == nil, tostring(__cybexos_system_theme.error))`);
});

test("the compositor applies the rendered theme at config load", needsLua, t => {
    runLook(t, `dofile(look)
assert_theme("light")
assert(__cybexos_system_theme.error == nil, tostring(__cybexos_system_theme.error))
assert(hl.get_config("decoration.rounding") == 16, "rounding stays the shell's radius")`,
    { [THEME]: render(lightTokens()) });
    // XDG_STATE_HOME moves the state directory, as it does for theme-apply.py.
    runLook(t, `dofile(look)
assert_theme("light")`, { ["state/cybexos/theme/hyprland.lua"]: render(lightTokens()) },
    { XDG_STATE_HOME: "$HOME/state" });
});

test("a damaged theme file never stops the compositor", needsLua, t => {
    const light = render(lightTokens());
    const broken = {
        "a syntax error": "return { general = ",
        "a function call": 'return { general = { col = { active_border = os.exit(1) } } }',
        "a string method": 'return { general = { col = { active_border = ("x"):rep(3) } } }',
        "a bad colour": light.replace(/inactive_border = "[^"]*"/, 'inactive_border = "rgb(cfced6) ; exec"'),
        "a number": light.replace(/inactive_border = "[^"]*"/, "inactive_border = 4"),
        "not a table": 'return "rgb(ffffff)"',
        "an empty file": "",
        "a huge file": "return {}" + " ".repeat(70000),
    };
    for (const [label, text] of Object.entries(broken)) {
        runLook(t, `dofile(look)
assert_theme("dark")
assert(type(__cybexos_system_theme.error) == "string", ${JSON.stringify(label)} .. " was not reported")`,
        { [THEME]: text });
    }
    // Keys a newer renderer adds are ignored rather than rejecting the file.
    runLook(t, `dofile(look)
assert_theme("light")
assert(hl.get_config("misc.background_color") == nil)`,
    { [THEME]: light.replace("return {", 'return {\n  misc = { background_color = "rgb(ffffff)" },') });
});

test("a live theme change applies without a reload and keeps user.lua's keys", needsLua, t => {
    runLook(t, `dofile(look)
assert_theme("dark")
-- user.lua runs after looknfeel and pins one colour.
hl.config({ general = { col = { active_border = "rgb(ff0000)" } } })
write(theme_file, ${JSON.stringify(render(lightTokens()))})
cybexos_system_theme(theme_file)
assert(hl.get_config("general.col.active_border") == "rgb(ff0000)", "user.lua keeps its key")
assert(hl.get_config("general.col.inactive_border") == expected.light["general.col.inactive_border"])
assert(hl.get_config("group.groupbar.text_color") == expected.light["group.groupbar.text_color"])
-- A second change still leaves it alone, and still moves everything else.
write(theme_file, ${JSON.stringify(render(darkTokens()))})
cybexos_system_theme(theme_file)
assert(hl.get_config("general.col.active_border") == "rgb(ff0000)")
assert(hl.get_config("general.col.inactive_border") == expected.dark["general.col.inactive_border"])
-- A config reload takes a fresh baseline; user.lua is now gone.
live = {}
dofile(look)
write(theme_file, ${JSON.stringify(render(lightTokens()))})
cybexos_system_theme(theme_file)
assert_theme("light")
-- Errors reach hyprctl eval instead of half-applying anything.
write(theme_file, "return { general = ")
assert(not pcall(cybexos_system_theme, theme_file))
assert(not pcall(cybexos_system_theme, home .. "/missing.lua"))
assert_theme("light")`, { [THEME]: render(darkTokens()) });
});

test("user.lua's keys are recognised in Hyprland's own get_config shapes", needsLua, t => {
    // Hyprland returns a gradient as a fresh { colors = { "0xAARRGGBB" },
    // angle = n } table on every call and a plain colour as "0xAARRGGBB".
    runLook(t, `local raw = hl.get_config
function hl.get_config(key)
  local value = raw(key)
  if type(value) ~= "string" then return value end
  local hex = value:match("^rgb%((%x+)%)$")
  local color = hex and ("0xFF" .. hex:upper()) or value
  if key:match("text_color") then return color end
  return { colors = { color }, angle = 0 }
end
dofile(look)
hl.config({ group = { groupbar = { text_color = "rgb(ff0000)", col = { active = "rgb(00ff00)" } } } })
write(theme_file, ${JSON.stringify(render(lightTokens()))})
cybexos_system_theme(theme_file)
assert(raw("group.groupbar.text_color") == "rgb(ff0000)")
assert(raw("group.groupbar.col.active") == "rgb(00ff00)")
assert(raw("group.groupbar.col.inactive") == expected.light["group.groupbar.col.inactive"])
assert(raw("group.groupbar.text_color_inactive") == expected.light["group.groupbar.text_color_inactive"])`,
    { [THEME]: render(darkTokens()) });
});

test("the theme leaves glass and power saver alone", needsLua, t => {
    runLook(t, `dofile(look)
assert(layer_rules["quickshell-blur"].enabled == true)
cybexos_power_saver(true)
assert(hl.get_config("decoration.blur.passes") == 1)
cybexos_system_theme(theme_file)
assert(hl.get_config("decoration.blur.passes") == 1, "power saver survives a live theme change")
assert(hl.get_config("animations.enabled") == false)
assert(layer_rules["quickshell-blur"].enabled == true)
cybexos_power_saver(false)
assert(hl.get_config("decoration.blur.passes") == 3)`, {
        [THEME]: render(lightTokens()),
        ".config/cybexos/shell.json": '{"v": 23, "glassEnabled": true}',
    });
    assert.match(template, /^quickshell_blur_rule = hl\.layer_rule\(\{$/m);
    assert.match(template, /^function cybexos_power_saver\(enabled\)$/m);
    assert.match(template, /^function cybexos_system_theme\(path\)$/m,
        "the eval handle must be a global");
    // The load at startup is contained; only the eval handle raises.
    assert.match(template, /pcall\(read_system_theme, theme_path\)/);
    assert.match(template, /pcall\(apply_system_theme, theme_values\)/);
    assert.match(template, /load\(text, "=" \.\. path, "t", \{\}\)/,
        "the file is loaded as text in an empty environment");
});

function hyprctlStub(t, body) {
    return stubBin(t, { hyprctl: body === undefined ? "echo ok" : body });
}

function hyprctlCalls(stub) {
    return stub.calls().filter(line => line.startsWith("hyprctl"));
}

test("apply updates a running compositor through hyprctl eval", t => {
    const state = scratch(t);
    const stub = hyprctlStub(t);
    const env = { HYPRLAND_INSTANCE_SIGNATURE: "test" };
    const input = JSON.stringify(darkTokens()) + "\n";
    let run = runDriver(state, ["apply"], input, { bin: stub.bin, env });
    assert.deepEqual(run.report.targets.hyprland, { changed: true, error: null });
    assert.equal(fs.readFileSync(path.join(state, "hyprland.lua"), "utf8"), render(darkTokens()));
    assert.deepEqual(hyprctlCalls(stub),
        [`hyprctl eval cybexos_system_theme("${state}/hyprland.lua")`]);

    // Unchanged tokens touch nothing; --force re-sends.
    run = runDriver(state, ["apply"], input, { bin: stub.bin, env });
    assert.deepEqual(run.report.targets.hyprland, { changed: false, error: null });
    assert.equal(hyprctlCalls(stub).length, 1);
    run = runDriver(state, ["apply", "--force"], input, { bin: stub.bin, env });
    assert.deepEqual(run.report.targets.hyprland, { changed: false, error: null });
    assert.equal(hyprctlCalls(stub).length, 2);
});

test("outside a Hyprland session apply only writes the file", t => {
    const state = scratch(t);
    const stub = hyprctlStub(t);
    const run = runDriver(state, ["apply"], JSON.stringify(lightTokens()) + "\n",
        { bin: stub.bin });
    assert.deepEqual(run.report.targets.hyprland, { changed: true, error: null });
    assert.deepEqual(hyprctlCalls(stub), []);
    assert.equal(fs.readFileSync(path.join(state, "hyprland.lua"), "utf8"), render(lightTokens()));
});

test("a compositor that rejects the theme is reported, not ignored", t => {
    const env = { HYPRLAND_INSTANCE_SIGNATURE: "test" };
    const input = JSON.stringify(darkTokens()) + "\n";
    // hyprctl reports Lua errors on stdout, with exit status 0.
    let stub = hyprctlStub(t, "echo 'attempt to call a nil value (global cybexos_system_theme)'");
    let run = runDriver(scratch(t), ["apply"], input, { bin: stub.bin, env });
    assert.equal(run.report.success, false);
    assert.equal(run.report.targets.hyprland.error,
        "Hyprland did not apply the theme: attempt to call a nil value (global cybexos_system_theme)");
    stub = hyprctlStub(t, "echo 'no socket' >&2; exit 3");
    run = runDriver(scratch(t), ["apply"], input, { bin: stub.bin, env });
    assert.equal(run.report.targets.hyprland.error, "Hyprland did not apply the theme: no socket");
    run = runDriver(scratch(t), ["apply"], input, { env });
    assert.equal(run.report.targets.hyprland.error, "hyprctl is not installed");
});
