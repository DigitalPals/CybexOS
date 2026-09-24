const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { shellDir, load } = require("./shell.cjs");

const H = load("KeybindHelpers.js");

const SUPER = 64;
const SHIFT = 1;
const CTRL = 4;

function bind(modmask, key, description, extra = {}) {
    return {
        modmask, key, keycode: 0, submap: "", mouse: false, locked: false,
        dispatcher: "__lua", arg: "1", has_description: description !== "",
        description, ...extra
    };
}

function rows(groups, title) {
    const group = groups.find(entry => entry.title === title);
    assert.ok(group, `no ${title} group`);
    return group.rows;
}

// ---- key caps ----------------------------------------------------------------

test("modifiers read in the conventional order, whatever the mask order", () => {
    assert.deepEqual(H.modifierNames(SUPER | CTRL | SHIFT), ["Super", "Ctrl", "Shift"]);
    assert.deepEqual(H.modifierNames(SUPER | 8), ["Super", "Alt"]);
    assert.deepEqual(H.modifierNames(0), []);
    assert.deepEqual(H.modifierNames(undefined), []);
});

test("keysyms become the words printed on the keys", () => {
    for (const [key, cap] of [
        ["Return", "Enter"], ["SPACE", "Space"], ["comma", ","], ["SLASH", "/"],
        ["grave", "`"], ["BACKSPACE", "Backspace"], ["left", "←"], ["q", "Q"],
        ["F9", "F9"], ["Print", "Print"], ["mouse_down", "Scroll down"],
        ["mouse:272", "Left button"], ["mouse:273", "Right button"],
        ["XF86AudioRaiseVolume", "Volume up"], ["XF86AudioMicMute", "Mic mute"],
        ["XF86MonBrightnessDown", "Brightness down"],
        ["XF86Launch5", "Launch5"], ["XF86KbdLightOnOff", "Kbd Light On Off"],
        ["code:10", "Key 10"], ["Caps_Lock", "Caps Lock"]
    ])
        assert.equal(H.keyName(key), cap, key);
    assert.equal(H.keyName("", 38), "Key 38");
});

test("descriptions split into group and label at the first colon-space", () => {
    assert.deepEqual(H.parseDescription("Apps: Terminal"), { group: "Apps", label: "Terminal" });
    assert.deepEqual(H.parseDescription("Capture: Copy text: OCR"),
        { group: "Capture", label: "Copy text: OCR" });
    assert.deepEqual(H.parseDescription("Open my notes"), { group: "Other", label: "Open my notes" });
    assert.deepEqual(H.parseDescription("Weird:no space"), { group: "Other", label: "Weird:no space" });
});

// ---- grouping ----------------------------------------------------------------

test("only described bindings are drawn, vendor groups first", () => {
    const groups = H.groupsFromBinds([
        bind(SUPER, "Z", "Personal: Zen mode"),
        bind(SUPER, "Q", "Windows: Close window"),
        bind(SUPER, "Return", "Apps: Terminal"),
        bind(SUPER, "H", ""),
        bind(SUPER, "O", "Open my notes"),
        bind(SUPER, "space", "Shell: Launcher")
    ]);
    assert.deepEqual(groups.map(group => group.title),
        ["Shell", "Apps", "Windows", "Personal", "Other"]);
    assert.deepEqual(rows(groups, "Apps"), [{ label: "Terminal", combos: [["Super", "Enter"]] }]);
    assert.equal(groups.flatMap(group => group.rows).length, 5, "the undescribed Super+H is hidden");
});

test("several bindings for one action become alternatives, duplicates vanish", () => {
    const groups = H.groupsFromBinds([
        bind(SUPER, "grave", "Capture: Screenshot a region"),
        bind(0, "Print", "Capture: Screenshot a region"),
        bind(0, "Print", "Capture: Screenshot a region"),
        bind(0, "XF86AudioPlay", "Media: Play or pause"),
        bind(0, "XF86AudioPause", "Media: Play or pause")
    ]);
    assert.deepEqual(rows(groups, "Capture"),
        [{ label: "Screenshot a region", combos: [["Super", "`"], ["Print"]] }]);
    assert.deepEqual(rows(groups, "Media"),
        [{ label: "Play or pause", combos: [["Play"], ["Pause"]] }]);
});

test("hardware keys stay described in Hyprland but off the sheet", () => {
    const groups = H.groupsFromBinds([
        bind(0, "XF86AudioRaiseVolume", "Hardware keys: Volume up"),
        bind(0, "XF86MonBrightnessUp", "Hardware keys: Brightness up"),
        bind(SUPER, "K", "Shell: Keyboard shortcuts")
    ]);
    assert.deepEqual(groups.map(group => group.title), ["Shell"]);
    assert.ok(H.HIDDEN_GROUPS.includes("Hardware keys"));
    assert.equal(H.GROUP_ORDER.includes("Hardware keys"), false);
});

test("columns split the groups in reading order with balanced heights", () => {
    const group = (title, count) => ({ title, rows: Array(count).fill({}) });
    const groups = [group("Shell", 7), group("Apps", 10), group("Web apps", 5),
        group("Development", 4), group("Windows", 8), group("Workspaces", 4),
        group("Clipboard", 4), group("Capture", 4), group("Dictation", 2)];
    const titles = columns => columns.map(column => column.map(entry => entry.title));

    assert.deepEqual(titles(H.columnsFor(groups, 3)), [
        ["Shell", "Apps"],
        ["Web apps", "Development", "Windows"],
        ["Workspaces", "Clipboard", "Capture", "Dictation"]
    ]);
    assert.deepEqual(titles(H.columnsFor(groups, 1)), [groups.map(entry => entry.title)]);
    assert.deepEqual(H.columnsFor(groups, 2).flat(), groups, "nothing is dropped or reordered");
    assert.equal(H.columnsFor(groups, 40).length, groups.length, "never more columns than groups");
    assert.deepEqual(H.columnsFor([], 3), [[]]);
    assert.deepEqual(H.columnsFor(groups.slice(0, 2), 0).length, 1);
});

test("numbered workspace bindings collapse into one row per modifier set", () => {
    const binds = [];
    for (let i = 1; i <= 10; i++) {
        binds.push(bind(SUPER, String(i % 10), `Workspaces: Switch to workspace ${i}`));
        binds.push(bind(SUPER | SHIFT, String(i % 10), `Workspaces: Move window to workspace ${i}`));
    }
    binds.push(bind(SUPER, "mouse_down", "Workspaces: Next workspace"));
    assert.deepEqual(rows(H.groupsFromBinds(binds), "Workspaces"), [
        { label: "Switch to workspace 1–10", combos: [["Super", "1…0"]] },
        { label: "Move window to workspace 1–10", combos: [["Super", "Shift", "1…0"]] },
        { label: "Next workspace", combos: [["Super", "Scroll down"]] }
    ]);
});

test("a partial or broken digit run stays readable", () => {
    const groups = H.groupsFromBinds([
        bind(SUPER, "1", "Tags: Tag 1"),
        bind(SUPER, "2", "Tags: Tag 2"),
        bind(SUPER, "3", "Tags: Tag 3"),
        bind(SUPER, "5", "Tags: Tag 5"),
        bind(SUPER, "7", "Solo: Only 7")
    ]);
    assert.deepEqual(rows(groups, "Tags"), [{ label: "Tag 1–3, 5", combos: [["Super", "1…3 5"]] }]);
    assert.deepEqual(rows(groups, "Solo"), [{ label: "Only 7", combos: [["Super", "7"]] }]);
});

test("the arrow keys share one cap", () => {
    const groups = H.groupsFromBinds(["left", "right", "up", "down"]
        .map(key => bind(SUPER, key, "Windows: Move focus")));
    assert.deepEqual(rows(groups, "Windows"), [{ label: "Move focus", combos: [["Super", "← → ↑ ↓"]] }]);
});

test("submap bindings say which mode they belong to", () => {
    const groups = H.groupsFromBinds([bind(0, "h", "Resize: Shrink left", { submap: "resize" })]);
    assert.deepEqual(rows(groups, "Resize"), [{ label: "Shrink left (resize mode)", combos: [["H"]] }]);
});

test("unreadable hyprctl output is an error, not an empty sheet", () => {
    assert.match(H.fromJson("not json").error, /could not be read/);
    assert.match(H.fromJson('{"ok":true}').error, /could not be read/);
    assert.deepEqual(H.fromJson("[]"), { groups: [], error: "" });
    assert.deepEqual(H.groupsFromBinds(null), []);
});

// ---- the shipped bindings ----------------------------------------------------

// Run bindings.lua against a stub `hl`, then shape what it registered the way
// `hyprctl binds -j` reports it, so the vendor file and the parser are checked
// together rather than against a copy of the list.
function vendorBinds(features) {
    const lua = `
local results = {}
local function dispatcher(value) return value or true end
hl = { dsp = { exec_cmd = dispatcher, global = dispatcher, send_key_state = dispatcher,
  layout = dispatcher, focus = dispatcher, exit = dispatcher,
  window = { close = dispatcher, float = dispatcher, move = dispatcher, set_prop = dispatcher,
    drag = dispatcher, resize = dispatcher } } }
local active, order = {}, {}
function hl.unbind(keys) active[keys] = nil end
function hl.bind(keys, _, options)
  if active[keys] == nil then table.insert(order, keys) end
  active[keys] = options or {}
  return { remove = function() end }
end
package.preload.features = function() return { ${features} } end
dofile(arg[1])
for _, keys in ipairs(order) do
  local options = active[keys]
  if options then
    print(keys .. "\\t" .. (options.description or ""))
  end
end
`;
    const result = spawnSync("luajit", ["-", path.resolve(shellDir, "../bindings.lua")],
        { input: lua, encoding: "utf8", env: { ...process.env, HOME: "/home/test" } });
    assert.equal(result.status, 0, result.stderr);
    const masks = { SUPER, SHIFT, CTRL, ALT: 8 };
    return result.stdout.trim().split("\n").map(line => {
        const [keys, description] = line.split("\t");
        const parts = keys.split(" + ");
        const key = parts.pop();
        const modmask = parts.reduce((mask, name) => mask | masks[name], 0);
        return bind(modmask, key, description);
    });
}

const luajit = spawnSync("luajit", ["-v"]).status === 0;

test("every shipped vendor group is ordered and the sheet reads well", { skip: !luajit && "luajit is not installed" }, () => {
    const full = vendorBinds("podman = true, developer_tools = true, connected_widgets = true, "
        + "proprietary_apps = true, private_portal = true");
    const minimal = vendorBinds("");
    for (const binds of [full, minimal]) {
        const groups = H.groupsFromBinds(binds);
        for (const group of groups)
            assert.ok(H.GROUP_ORDER.includes(group.title),
                `bindings.lua introduced "${group.title}", which GROUP_ORDER does not place`);
        assert.equal(groups.find(group => group.title === "Other"), undefined);
    }

    const groups = H.groupsFromBinds(full);
    const labels = Object.fromEntries(groups.flatMap(group =>
        group.rows.map(row => [`${group.title}: ${row.label}`, row.combos])));
    assert.deepEqual(labels["Shell: Keyboard shortcuts"], [["Super", "K"]]);
    assert.deepEqual(labels["Apps: AI agent"], [["Super", "Ctrl", "Shift", "A"]]);
    assert.deepEqual(labels["Workspaces: Switch to workspace 1–10"], [["Super", "1…0"]]);
    assert.deepEqual(labels["Windows: Move focus"], [["Super", "← → ↑ ↓"]]);
    assert.deepEqual(labels["Dictation: Dictate in English"],
        [["Super", "Ctrl", "X"], ["F9"], ["Mic mute"]]);
    assert.deepEqual(labels["Capture: Screenshot a region"], [["Super", "`"], ["Print"]]);
    assert.deepEqual(labels["Development: Docker (lazydocker)"], [["Super", "D"]]);
});

// ---- the overlay -------------------------------------------------------------

test("the sheet draws Hyprland's bindings, with no hand-written fallback", () => {
    const session = fs.readFileSync(path.join(shellDir, "Common/Session.qml"), "utf8");
    const overlay = fs.readFileSync(path.join(shellDir, "ShortcutsOverlay.qml"), "utf8");
    assert.match(session, /command: \["hyprctl", "binds", "-j"\]/);
    assert.match(session, /KeybindHelpers\.fromJson\(output\)/);
    assert.match(session, /function openKeys\(targetScreen\) \{[\s\S]*?refreshShortcuts\(\);[\s\S]*?keysOpen = true;/,
        "each opening reads the bindings again");
    assert.doesNotMatch(session, /label:\s*"[^"]+",\s*keys:\s*\[/, "a hand-written row survived");
    assert.match(overlay,
        /model: root\.visible\s*\?\s*KeybindHelpers\.columnsFor\(Session\.shortcutGroups, shortcutColumns\.count\) : \[\]/);
    assert.match(overlay, /Session\.shortcutsError/, "a failed read is shown");
    assert.match(overlay, /model: shortcut\.modelData\.combos/);
});
