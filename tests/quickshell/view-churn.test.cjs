// View-layer churn: rows that survive a list change keep their delegates,
// hidden views stop animating and polling, and nothing redraws faster than
// what it displays can change. Source contracts for QML wiring that has no
// Node surface.
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { shellDir } = require("./shell.cjs");

function read(relative) {
    return fs.readFileSync(path.join(shellDir, relative), "utf8");
}

test("drawer Bluetooth rows survive discovery churn", () => {
    const drawer = read("Popovers/Drawer/DrawerBluetooth.qml");

    // A fixed section model; an array literal holding the live lists was a
    // new model on every BlueZ add, rename or expiry.
    assert.match(drawer, /model:\s*\["connected", "paired", "nearby"\]/);
    assert.doesNotMatch(drawer, /devices:\s*root\.\w+Devices,\s*show:/);
    assert.match(drawer, /required property string modelData\s*\n\s*readonly property var devices:/);
    // Rows are diffed by device identity.
    assert.match(drawer, /model:\s*ScriptModel \{\s*values:\s*section\.devices\s*\}/);
    assert.doesNotMatch(drawer, /section\.modelData\.devices/);
});

test("drawer Sound rows survive streams coming and going", () => {
    const drawer = read("Popovers/Drawer/DrawerSound.qml");

    assert.match(drawer, /model:\s*ScriptModel \{\s*values:\s*root\.visibleSinks\s*\}/);
    assert.match(drawer, /model:\s*ScriptModel \{\s*values:\s*root\.readyStreams\s*\}/);
    assert.doesNotMatch(drawer, /model:\s*root\.(?:visibleSinks|readyStreams)\b/,
        "a fresh node array as the model rebuilds every row, a dragged slider included");
});

test("the Sound tab samples the mic meter and releases a muted source", () => {
    const drawer = read("Popovers/Drawer/DrawerSound.qml");
    const monitor = drawer.match(/PwNodePeakMonitor \{[\s\S]*?\n    \}/)?.[0] ?? "";

    assert.match(monitor, /enabled:\s*root\.visible && !!Audio\.source && !Audio\.sourceMuted/,
        "a muted source must not hold a capture stream open");
    // The peak arrives at the PipeWire buffer rate; the meter reads a ~15 Hz
    // sample of it, in whole pixels.
    assert.match(drawer,
        /Timer \{\s*interval:\s*66\s*repeat:\s*true\s*running:\s*inputPeak\.enabled\s*onTriggered:\s*root\.micPeak = Format\.clamp01\(inputPeak\.peak\)/);
    assert.match(drawer, /if \(!running\)\s*root\.micPeak = 0;/);
    assert.match(drawer, /width:\s*Math\.round\(parent\.width \* root\.micPeak\)/);
    assert.equal((drawer.match(/inputPeak\.peak/g) ?? []).length, 1,
        "only the sampling timer may read the live peak");
});
