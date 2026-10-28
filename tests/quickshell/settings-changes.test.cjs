// The header's Changes chip and its review (2026-10 Settings redesign): how
// each kind of draft is described, and what one Apply does with them.
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { shellDir } = require("./shell.cjs");

const M = require(path.join(shellDir, "Settings/ChangesModel.js"));
const read = rel => fs.readFileSync(path.join(shellDir, rel), "utf8");

test("session drafts are described as their pages name them", () => {
    const touchpad = M.touchpadItems({ tap: false, naturalScroll: true, sensitivity: 0 },
        { tap: true, naturalScroll: true, sensitivity: 0.25 }, { tap: true, sensitivity: 0.25 });
    assert.deepEqual(touchpad.map(item => [item.id, item.label, item.before, item.after, item.system]),
        [["touchpad.tap", "Tap to click", "Off", "On", false], ["touchpad.sensitivity", "Pointer sensitivity", "0.0", "0.3", false]]);
    const keyboard = M.keyboardItems({ layouts: [{ layout: "us", variant: "" }], shortcut: "" },
        { layouts: [{ layout: "us", variant: "" }, { layout: "nl", variant: "" }], shortcut: "grp:alt_shift_toggle" },
        { layouts: [], shortcut: "grp:alt_shift_toggle" });
    assert.deepEqual(keyboard.map(item => [item.label, item.before, item.after, item.tab]),
        [["Layouts", "us", "us, nl", "layouts"], ["Switch layouts", "None", "Alt + Shift", "layouts"]]);
    const shortcuts = M.shortcutItems([{ label: "Browser" }, { label: "Terminal" }, { label: "Files" }, { label: "Lock screen" }]);
    assert.deepEqual(shortcuts.map(item => [item.label, item.after, item.tab]),
        [["4 shortcuts", "Browser, Terminal, Files and 1 more", "shortcuts"]]);
    assert.deepEqual(M.shortcutItems([]), []);
});

test("regional and cleanup drafts are system changes", () => {
    const region = M.regionItems({ timezone: "Europe/Berlin", originalTimezone: "America/New_York",
        locale: "de_DE.UTF-8", originalLocale: "en_US.UTF-8" }, code => code === "de_DE.UTF-8" ? "German" : "English");
    assert.deepEqual(region.map(item => [item.id, item.before, item.after, item.system, item.page]),
        [["region.timezone", "America/New York", "Europe/Berlin", true, "region"],
            ["region.locale", "English", "German", true, "region"]]);
    assert.deepEqual(M.regionItems({ timezone: "UTC", originalTimezone: "UTC", locale: "", originalLocale: "" }), []);
    const policy = { automatic: true, keepConfirmed: 5, keepDays: 30 };
    assert.deepEqual(M.retentionItems(policy, policy, false), []);
    const [retention] = M.retentionItems({ ...policy, keepDays: 90 }, policy, true);
    assert.equal(retention.after, "5 deployments · 90 days · weekly cleanup on");
    assert.deepEqual([retention.page, retention.tab, retention.system], ["backup", "recovery", true]);
});

test("one Apply settles every session draft, then prepares one system change", () => {
    const items = group => ({ group, page: group });
    assert.deepEqual(M.plan(["shortcuts", "touchpad", "region", "keyboard"].map(items), false),
        { live: ["touchpad", "keyboard", "shortcuts"], system: "region", waiting: [],
            steps: ["touchpad", "keyboard", "shortcuts", "region"] });
    // The updater prepares one deployment at a time: cleanup waits for the
    // regional change, and both wait for one already on its way.
    assert.deepEqual(M.plan(["retention", "region"].map(items), false).waiting, ["retention"]);
    assert.deepEqual(M.plan(["retention", "region", "touchpad"].map(items), true),
        { live: ["touchpad"], system: "", waiting: ["region", "retention"], steps: ["touchpad"] });
    assert.deepEqual(M.plan([], false).steps, []);
    assert.deepEqual(M.pagesOf([{ page: "region" }, { page: "touchpad" }, { page: "region" }]), ["region", "touchpad"]);
});

test("the singleton applies one group at a time and prepares both regional changes in one request", () => {
    const changes = read("Settings/SettingsChanges.qml");
    assert.match(changes, /queue = plan\.steps\.slice\(\);/);
    assert.match(changes, /if \(root\.step === "" \|\| root\.busy\(root\.step\)\)\s*return;/,
        "the next group starts only when the last has settled");
    assert.match(changes, /case "region":\s*return RegionDrafts\.prepare\(\);/);
    const region = read("Settings/RegionDrafts.qml");
    assert.match(region, /return service\.run\(\{ action: "stage", changes: changes \}\);/);
    assert.match(region, /changes\.push\(\{ field: "timezone"[\s\S]*changes\.push\(\{ field: "locale"/);
    // Home asks the view to open the sheet it hosts.
    assert.match(changes, /signal reviewRequested\(\)/);
    assert.match(read("Settings/SettingsView.qml"), /function onReviewRequested\(\) \{ root\.openChanges\(\); \}/);
    assert.match(read("Settings/HomePage.qml"), /SettingsChanges\.reviewRequested\(\);/);
});
