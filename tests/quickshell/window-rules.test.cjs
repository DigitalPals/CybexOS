const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { shellDir } = require("./shell.cjs");

const repo = path.resolve(shellDir, "../../../..");
const rules = fs.readFileSync(path.join(repo, "roles/desktop/templates/looknfeel.lua.j2"), "utf8");

test("window sizes are expressions, never percentage strings Hyprland ignores", () => {
    // Hyprland 0.56 applies `size = "monitor_w*0.6 monitor_h*0.7"` but
    // silently drops `size = { "60%", "70%" }`: the window keeps whatever
    // size its client asked for.
    assert.doesNotMatch(rules, /size\s*=\s*\{\s*"[^"]*%"/);
});

test("the welcome window floats centred at a share of its monitor", () => {
    const welcome = rules.split("\n").find(line => line.includes("Welcome to CybexOS"));
    assert.ok(welcome, "looknfeel.lua has a rule for the welcome window");
    assert.match(welcome, /match = \{ class = \[\[\^cybex\$\]\], title = \[\[\^Welcome to CybexOS\$\]\] \}/);
    assert.match(welcome, /float = true, center = true/);
    assert.match(welcome, /size = "min\(monitor_w-32,max\(760,monitor_w\*0\.5\)\) min\(monitor_h-64,max\(660,monitor_h\*0\.48\)\)"/);
    const window = fs.readFileSync(path.join(repo, "image/rootfs/usr/share/cybexos/welcome/Main.qml"), "utf8");
    assert.match(window, /welcome\.availableWorkArea\(screen \? screen\.name : ""\)/);
    assert.match(window, /width: Math\.min\(availableWidth, Math\.max\(760,/);
    assert.match(window, /height: Math\.min\(availableHeight, Math\.max\(660,/);
});
