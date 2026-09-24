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
    const size = /size = "max\((\d+),monitor_w\*0\.5\) max\((\d+),monitor_h\*0\.48\)"/.exec(welcome);
    assert.ok(size, "half the monitor's width and 48% of its height");

    // The rule's floor is the window's own minimum, so neither side can
    // squeeze the layout the other one allows.
    const window = fs.readFileSync(path.join(repo, "image/rootfs/usr/share/cybexos/welcome/Main.qml"), "utf8");
    assert.equal(size[1], /minimumWidth: (\d+)/.exec(window)[1]);
    assert.equal(size[2], /minimumHeight: (\d+)/.exec(window)[1]);
    assert.match(window, /width: Math\.max\(minimumWidth, Math\.round\(Screen\.width \* 0\.5\)\)/);
    assert.match(window, /height: Math\.max\(minimumHeight, Math\.round\(Screen\.height \* 0\.48\)\)/);
});
