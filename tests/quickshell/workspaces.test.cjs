const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { shellDir, load } = require("./shell.cjs");

const Motion = load("WorkspaceMotion.js");

function read(rel) {
    return fs.readFileSync(path.join(shellDir, rel), "utf8");
}

test("workspace states restore the accent-number-and-dot hierarchy", () => {
    const workspaces = read("Bar/Workspaces.qml");
    const theme = read("Common/Theme.qml");

    assert.match(workspaces, /color:\s*Theme\.barWsCurrent\b/,
        "the current lozenge needs the semantic accent role");
    assert.match(workspaces, /slot\.focused\s*\?\s*Theme\.barWsCurrentFg/,
        "numbered current workspaces need a foreground derived from the lozenge");
    assert.match(workspaces, /showNumber:\s*root\.numbered && exists/,
        "number mode must keep empty workspaces as dots");
    assert.match(workspaces, /showNumber[\s\S]{0,120}?Theme\.barChip : "transparent"/,
        "occupied numbers rest directly on the slab and gain only a hover fill");
    assert.match(workspaces, /exists\s*\?\s*Theme\.barWsOccupied\s*:\s*Theme\.barWsEmpty/,
        "dot slots need a dedicated occupied tone");
    for (const token of ["barWsCurrent", "barWsCurrentFg", "barWsCurrentGlow",
                         "barWsOccupied", "barWsEmpty"])
        assert.match(theme, new RegExp(`readonly property color ${token}:`),
            `${token} must be a semantic theme token`);
    assert.match(theme, /barWsCurrent:\s*barAccent\b/);
    assert.match(theme, /barWsCurrentFg:\s*barAccentFg\b/);
    assert.match(theme, /barWsOccupied:\s*barTextLow\b/);
    assert.match(theme, /barWsEmpty:\s*barDotDim\b/);
    assert.match(workspaces, /exists\s*\?\s*", occupied"\s*:\s*", empty"/,
        "assistive output must announce the same distinction shown visually");
});

test("workspace cells and hide-empty geometry stay deterministic", () => {
    assert.equal(Motion.CELL_WIDTH, 22);
    assert.deepEqual(Motion.visibleIds(5, [1, 3], 1, false), [1, 2, 3, 4, 5]);
    assert.deepEqual(Motion.visibleIds(5, [1, 3], 1, true), [1, 3]);
    assert.deepEqual(Motion.visibleIds(5, [1, 3], 4, true), [1, 3, 4]);
    assert.deepEqual(Motion.indicatorBounds([1, 3, 4], 3), { left: 20, right: 46 });
    assert.equal(Motion.indicatorBounds([1, 3], 2), null);
});

test("the lozenge assigns 120ms to its leading and 300ms to trailing edge", () => {
    assert.deepEqual(Motion.edgeDurations(2, 5, true), {
        left: 300, right: 120, direction: 1
    });
    assert.deepEqual(Motion.edgeDurations(5, 2, true), {
        left: 120, right: 300, direction: -1
    });
    assert.deepEqual(Motion.edgeDurations(2, 5, false), {
        left: 0, right: 0, direction: 0
    });
    assert.deepEqual(Motion.edgeDurations(-1, 2, true), {
        left: 0, right: 0, direction: 0
    });
});

test("the pager snaps structural changes and animates only focus transitions", () => {
    const workspaces = read("Bar/Workspaces.qml");
    assert.match(workspaces, /width:\s*WorkspaceMotion\.CELL_WIDTH/);
    assert.match(workspaces, /height:\s*Theme\.chipHeight/);
    assert.match(workspaces,
        /x:\s*index \* WorkspaceMotion\.CELL_WIDTH[\s\S]{0,320}?z:\s*2/,
        "workspace content must stack above the travelling accent chip");
    assert.match(workspaces, /property real leftEdge/);
    assert.match(workspaces, /property real rightEdge/);
    assert.match(workspaces, /Behavior on leftEdge/);
    assert.match(workspaces, /Behavior on rightEdge/);
    assert.match(workspaces, /onStructureKeyChanged:[\s\S]{0,100}?snapRequested = true/);
    assert.match(workspaces,
        /function onModOptsChanged\(\)[\s\S]{0,100}?snapRequested = true/);
    assert.match(workspaces, /Component\.onCompleted:[\s\S]{0,140}?settleIndicator\(false\)/);
    assert.match(workspaces, /Accessible\.onPressAction/);
    assert.match(workspaces, /Theme\.barRed/);
    assert.match(workspaces, /visible:\s*slot\.showNumber/);
});

test("the scratchpad and other special workspaces never become numbered pips", () => {
    // Hyprland lists special workspaces with negative ids next to the
    // numbered ones; Super+minus creates special:scratchpad (-98).
    const listed = [
        { id: 3, name: "3" }, { id: -98, name: "special:scratchpad" },
        { id: 1, name: "1" }, { id: -99, name: "special:special" },
        { id: 7, name: "special:odd" }, null, { id: 2.5 }
    ];
    assert.deepEqual(Motion.regularIds(listed), [1, 3]);
    // Quickshell hands QML an array-like list, not an Array.
    assert.deepEqual(Motion.regularIds({ length: 2, 0: { id: 4 }, 1: { id: -98 } }), [4]);
    assert.deepEqual(Motion.regularIds(undefined), []);
    assert.deepEqual(Motion.visibleIds(5, Motion.regularIds(listed), -98, true), [1, 3],
        "a focused special workspace adds no slot");
    assert.equal(Motion.indicatorBounds(Motion.visibleIds(5, [1, 3], -98, false), -98), null);

    const workspaces = read("Bar/Workspaces.qml");
    assert.match(workspaces,
        /readonly property var existingIds: WorkspaceMotion\.regularIds\(Hyprland\.workspaces\.values\)/);
    assert.match(workspaces,
        /readonly property int slots: Math\.max\(Settings\.modOpts\.ws\.minSlots, \.\.\.existingIds\)/,
        "slots count numbered workspaces only");
    assert.doesNotMatch(workspaces, /Hyprland\.workspaces\.values\.map\(workspace => workspace\.id\)/);
});
