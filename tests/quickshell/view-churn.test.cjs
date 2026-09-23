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

test("spinners stop while their view is hidden", () => {
    // PopoutHost keeps an outgoing panel alive, invisible, until the popout
    // closes; an ungated spinner kept rendering behind the incoming one.
    const sites = {
        "Popovers/T3ThreadPage.qml": /running:\s*root\.working && workingGlyph\.visible/,
        "Popovers/HermesToolCard.qml": /running:\s*root\.running && statusGlyph\.visible/,
        "Ui/Button.qml": /running:\s*root\.iconSpinning && iconLabel\.visible/,
        "Ui/MultiSelect.qml": /running:\s*root\.loadingOptions && refreshButton\.visible/
    };
    for (const [file, pattern] of Object.entries(sites))
        assert.match(read(file), pattern, file);
    const updates = read("Popovers/UpdatesPopover.qml");
    assert.match(updates, /running:\s*root\.mode === "running" && headerMark\.visible/);
    assert.match(updates, /&& stepMark\.visible && !Theme\.reducedMotion/);
    // A stopped value source keeps its angle; the marks that replace the arc
    // must not inherit the tilt.
    for (const [file, id] of [["Popovers/UpdatesPopover.qml", "headerMark"],
            ["Popovers/UpdatesPopover.qml", "stepMark"],
            ["Popovers/HermesToolCard.qml", "statusGlyph"]])
        assert.match(read(file),
            new RegExp(`onRunningChanged: if \\(!running\\) ${id}\\.rotation = 0`), `${file} ${id}`);
});
