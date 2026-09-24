const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { shellDir } = require("./shell.cjs");

const repo = path.resolve(__dirname, "../..");
const read = file => fs.readFileSync(path.join(shellDir, file), "utf8");

test("display helper: trials, restore timers, atomic saves and shared validation", () => {
    const result = spawnSync("python3", [path.join(__dirname, "../display-settings.py")], {
        encoding: "utf8", timeout: 60000,
        env: { ...process.env, PYTHONDONTWRITEBYTECODE: "1" },
    });
    assert.equal(result.status, 0, result.stdout + result.stderr);
});

test("displays.lua: strict JSON, vendor merging, hotplug and reload hygiene", () => {
    const result = spawnSync("bash", [path.join(repo, "tests/hyprland-displays")], {
        encoding: "utf8", timeout: 60000,
    });
    assert.equal(result.status, 0, result.stdout + result.stderr);
});

test("Hyprland loads saved displays after vendor monitors and before user.lua, contained", () => {
    const entry = fs.readFileSync(path.join(repo, "roles/desktop/files/hyprland.lua"), "utf8");
    const monitors = entry.indexOf('require("monitors")');
    const displays = entry.indexOf('pcall(require, "displays")');
    const user = entry.indexOf('dofile(user_dir .. "/user.lua")');
    assert.ok(monitors > 0 && monitors < displays && displays < user);
    assert.match(entry, /"autostart", "displays" \}\) do\s+package\.loaded\[module\] = nil/,
        "a reload evicts the module so saved changes and subscriptions are rebuilt");
    const template = fs.readFileSync(path.join(repo, "roles/desktop/templates/monitors.lua.j2"), "utf8");
    assert.doesNotMatch(template, /\bhl\.monitor\(\{/, "vendor rules go through the recording helper");
    assert.match(template, /_G\.__cybexos_vendor_monitor_rules = vendor_monitor_rules/);
    const tasks = fs.readFileSync(path.join(repo, "roles/desktop/tasks/main.yml"), "utf8");
    const install = tasks.slice(tasks.indexOf("Install Hyprland Lua configuration"),
        tasks.indexOf("Install ordered Hyprland session starter"));
    assert.ok(install.indexOf("- autostart.lua") < install.indexOf("- displays.lua")
        && install.indexOf("- displays.lua") < install.indexOf("- hyprland.lua"),
        "the module lands before the entrypoint that requires it");
    assert.match(tasks, /'displays\.lua', 'hyprland\.lua'/, "stale-entry pruning keeps the module");
    assert.match(fs.readFileSync(path.join(repo, "image/package"), "utf8"), /"autostart\.lua", "displays\.lua"/);
});

test("the Displays page is a System page with a guarded trial", () => {
    const view = read("Settings/SettingsView.qml");
    const page = read("Settings/DisplaysPage.qml");
    const service = read("Common/DisplaySettings.qml");
    const settings = read("Common/Settings.qml");
    assert.match(settings, /\{ id: "displays", group: "Devices", label: "Displays"[^}]*system: true \}/);
    assert.match(view, /case "displays": return displaysPage;/);
    assert.match(view, /systemServicePage: currentPage\.system === true/);
    assert.match(view, /pageLoader\.item as DisplaysPage[\s\S]{0,80}handleEscape\(\)/,
        "Escape reverts a pending trial before it closes Settings");
    assert.match(settings, /validPages: pages\.map\(entry => entry\.id\)/);
    assert.match(read("Settings/qmldir"), /^DisplaysPage DisplaysPage\.qml$/m);
    assert.match(read("Settings/qmldir"), /^DisplayArrangement DisplayArrangement\.qml$/m);
    assert.match(read("Common/qmldir"), /^singleton DisplaySettings DisplaySettings\.qml$/m);
    // The page restores on timeout, and releasing the last claim rolls back.
    assert.match(page, /secondsLeft === 0 && !page\.service\.busy\)\s+page\.revert\(\)/);
    assert.match(page, /onReleased: page\.service\.release\(\)/);
    assert.match(service, /if \(!watchers && preview && !busy\)\s+run\(\{action: "rollback"/);
    assert.match(page, /Displays\.canDisable\(page\.drafts, page\.selected\.key\)/);
    assert.match(page, /baseDigest: store\.digest/);
    assert.match(service, /scripts\/display-settings\.py/);
});
