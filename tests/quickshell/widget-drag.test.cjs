const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { shellDir, load } = require("./shell.cjs");

const H = load("LayoutHelpers.js");
const CATALOG = load("WidgetCatalog.js");
const SETTINGS = load("SettingsHelpers.js");

function read(relative) {
    return fs.readFileSync(path.join(shellDir, relative), "utf8");
}

function mods(left, center, right) {
    const column = ids => ids.map(id => ({ id, on: true, detail: "auto" }));
    return { left: column(left), center: column(center), right: column(right) };
}

function ids(list) {
    return list.map(entry => entry.id);
}

// ---- the catalog ------------------------------------------------------

test("every configurable widget id has a display name", () => {
    for (const id of SETTINGS.MODULE_IDS)
        assert.ok(CATALOG.WIDGETS[id], `${id} has no catalog entry`);
    for (const id of Object.keys(CATALOG.WIDGETS))
        assert.ok(SETTINGS.MODULE_IDS.includes(id),
            `${id} is named but is not a configurable widget`);
});

test("an unknown id still names itself rather than drawing blank", () => {
    assert.equal(CATALOG.widgetName("nonesuch"), "nonesuch");
});

// ---- moveWidget: the one set of drop rules ----------------------------

test("moving down within a column accounts for its own removal", () => {
    // Dropping "a" at index 3 of [a, b, c, d] means "after c", and the
    // removal of `a` shifts that gap down by one.
    const result = H.moveWidget(mods(["a", "b", "c", "d"], [], []),
        "left", "a", "left", 3);
    assert.deepEqual(ids(result.mods.left), ["b", "c", "a", "d"]);
    assert.equal(result.idx, 2);
});

test("moving up within a column does not shift the insertion point", () => {
    const result = H.moveWidget(mods(["a", "b", "c", "d"], [], []),
        "left", "d", "left", 1);
    assert.deepEqual(ids(result.mods.left), ["a", "d", "b", "c"]);
    assert.equal(result.idx, 1);
});

test("a drop onto a widget's own position is a no-op, not an off-by-one", () => {
    const result = H.moveWidget(mods(["a", "b", "c"], [], []),
        "left", "b", "left", 1);
    assert.deepEqual(ids(result.mods.left), ["a", "b", "c"]);
});

test("crossing columns splices without the same-column correction", () => {
    const result = H.moveWidget(mods(["a", "b"], ["c"], ["d", "e"]),
        "left", "a", "right", 1);
    assert.deepEqual(ids(result.mods.left), ["b"]);
    assert.deepEqual(ids(result.mods.right), ["d", "a", "e"]);
    assert.equal(result.col, "right");
    assert.equal(result.idx, 1);
});

test("a move carries the widget's enablement and detail policy with it", () => {
    const source = mods(["a"], [], []);
    source.left[0] = { id: "a", on: false, detail: "compact" };
    const result = H.moveWidget(source, "left", "a", "center", 0);
    assert.deepEqual(result.mods.center[0], { id: "a", on: false, detail: "compact" });
});

test("moveWidget never mutates the columns it was handed", () => {
    const source = mods(["a", "b"], [], []);
    H.moveWidget(source, "left", "a", "right", 0);
    assert.deepEqual(ids(source.left), ["a", "b"]);
    assert.deepEqual(ids(source.right), []);
});

test("an unknown widget or column is refused rather than guessed at", () => {
    assert.equal(H.moveWidget(mods(["a"], [], []), "left", "zz", "right", 0), null);
    assert.equal(H.moveWidget(mods(["a"], [], []), "nope", "a", "right", 0), null);
});

test("an out-of-range index is clamped to the destination's ends", () => {
    const past = H.moveWidget(mods(["a"], ["b", "c"], []), "left", "a", "center", 99);
    assert.deepEqual(ids(past.mods.center), ["b", "c", "a"]);
    const before = H.moveWidget(mods(["a"], ["b", "c"], []), "left", "a", "center", -5);
    assert.deepEqual(ids(before.mods.center), ["a", "b", "c"]);
});

// ---- resolving a pointer on the bar ----------------------------------

test("the section boundary sits midway across the gap between clusters", () => {
    const bounds = { leftEnd: 200, centerStart: 400, centerEnd: 600, rightStart: 900 };
    assert.equal(H.barDropColumn(299, bounds), "left");
    assert.equal(H.barDropColumn(301, bounds), "center");
    assert.equal(H.barDropColumn(749, bounds), "center");
    assert.equal(H.barDropColumn(751, bounds), "right");
});

test("a drop lands before the first drawn widget past the pointer", () => {
    const entries = [{ id: "a" }, { id: "b" }, { id: "c" }];
    const centers = { a: 100, b: 200, c: 300 };
    assert.equal(H.barDropIndex(entries, centers, 50), 0);
    assert.equal(H.barDropIndex(entries, centers, 150), 1);
    assert.equal(H.barDropIndex(entries, centers, 250), 2);
    assert.equal(H.barDropIndex(entries, centers, 400), 3);
});

test("widgets the bar is not drawing hold their place instead of resequencing", () => {
    // `b` is switched off or ruled out, so it has no center. A drop to the
    // right of `a` must land after it — index 1, ahead of the undrawn `b` —
    // rather than skipping over `b` and quietly reordering it.
    const entries = [{ id: "a" }, { id: "b" }, { id: "c" }];
    const centers = { a: 100, c: 300 };
    assert.equal(H.barDropIndex(entries, centers, 150), 2,
        "the gap after `a` is the configured index of the next drawn widget");
    assert.equal(H.barDropIndex(entries, centers, 50), 0);
});

test("a column with nothing drawn in it still accepts a drop", () => {
    assert.equal(H.barDropIndex([], {}, 500), 0);
    assert.equal(H.barDropIndex([{ id: "a" }], {}, 500), 1);
});

// ---- how the bar is wired to it ---------------------------------------

test("both drag surfaces commit through the same helper", () => {
    for (const rel of ["Bar/Bar.qml", "Settings/ModulesPage.qml"])
        assert.match(read(rel), /LayoutHelpers\.moveWidget\(/,
            `${rel} must not carry its own splice semantics`);
});

test("the bar's drag handler leaves a plain click to the widget beneath it", () => {
    const bar = read("Bar/Bar.qml");
    assert.match(bar, /DragHandler\s*\{/,
        "a drag must be a pointer handler, not a MouseArea that swallows the press");
    assert.match(bar, /dragThreshold:\s*\d+/,
        "without a threshold every click on a widget would begin a drag");
    assert.match(bar, /grabPermissions:[\s\S]{0,160}CanTakeOverFromItems/,
        "the drag has to take the grab from the widget's own MouseArea");
    assert.match(bar, /acceptedButtons:\s*Qt\.LeftButton/,
        "right-click already opens Shell settings from the slab");
});

test("the drag handler sits on the widgets' ancestor, not on a layer above them", () => {
    // This shipped broken once. An Item carrying a pointer handler is
    // hit-tested like any other item: stacked above the widgets it swallowed
    // every press, and no widget opened its panel any more — the handler's
    // passive grab does not hand the press onward to a sibling below it.
    // From contentFrame, which every cluster is a child of, the chip's own
    // MouseArea is hit first and keeps its click while the handler still sees
    // the same press and can take the grab once a real drag starts.
    const bar = read("Bar/Bar.qml");

    const frame = bar.indexOf("id: contentFrame");
    const overlay = bar.indexOf("id: rearrangeLayer");
    const handler = bar.indexOf("id: widgetDrag");
    assert.ok(frame >= 0 && overlay >= 0 && handler >= 0);
    assert.ok(handler > frame && handler < overlay,
        "the DragHandler must be declared inside contentFrame, before the overlay");

    // The overlay draws the caret and the proxy and must stay inert.
    const overlayBody = bar.slice(overlay);
    assert.doesNotMatch(overlayBody, /DragHandler|TapHandler|MouseArea/,
        "any input target on the overlay puts the click regression straight back");
});

test("no bar widget prevents the drag from taking the grab", () => {
    const walk = dir => {
        const out = [];
        for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
            const full = path.join(dir, entry.name);
            if (entry.isDirectory()) out.push(...walk(full));
            else if (entry.name.endsWith(".qml")) out.push(full);
        }
        return out;
    };
    for (const file of walk(path.join(shellDir, "Bar")))
        assert.doesNotMatch(fs.readFileSync(file, "utf8"), /preventStealing:\s*true/,
            `${path.relative(shellDir, file)} would trap the press and block a drag`);
});

test("the dragged widget is dimmed in place, never taken out of the layout", () => {
    const slot = read("Bar/ModuleSlot.qml");
    assert.match(slot, /opacity:\s*host\.dragWidget/,
        "the slot must dim itself while it is the one being dragged");
    assert.doesNotMatch(slot, /active:[^\n]*dragWidget/,
        "unloading it mid-drag would move every measurement the drop uses");
});

test("a drag suppresses the hover transitions that would fight it", () => {
    assert.match(read("Bar/Bar.qml"),
        /function hoverPanelAt[\s\S]{0,220}rearranging/,
        "crossing a widget mid-drag is the drag, not a menu transition");
    assert.match(read("Bar/Bar.qml"),
        /function hoverPopout[\s\S]{0,200}rearranging \|\| Settings\.drawerHover === "off"/,
        "a widget's own hover must not reopen its panel over the drop gap");
    assert.doesNotMatch(read("Bar/Cluster.qml"), /groupMouse|ownsPointer/,
        "the cluster must not add a second hover route around its widgets");
});

test("the settings page still owns the keyboard path", () => {
    const page = read("Settings/ModulesPage.qml");
    assert.match(read("Settings/WidgetPill.qml"), /Qt\.Key_Space/);
    assert.match(page, /function keyboardMove/);
    assert.match(read("Settings/WidgetPill.qml"), /Qt\.Key_Escape/);
});

// ---- the rename -------------------------------------------------------

test("the settings surfaces call them widgets", () => {
    const view = read("Settings/SettingsView.qml");
    assert.match(view, /label: "Widgets"/);
    assert.match(view, /title: "Your bar"/);
    assert.doesNotMatch(view, /label: "Modules"|title: "Modules"/);

    const detail = read("Settings/ModuleDetailView.qml");
    assert.match(detail, /text: "Your bar"/);
    assert.match(detail, /Accessible\.name: "Back to your bar"/);

    const page = read("Settings/ModulesPage.qml");
    assert.doesNotMatch(page, /"Module list\.""?|ToolTip\.text: "Module settings"/);
    assert.match(page, /resetKeys\(\["mods"\], "Widgets"\)/);
});

test("the stable page id is untouched by the rename", () => {
    // Same contract BarLayoutPage keeps: the visible name moved, the id the
    // rest of the shell routes on did not.
    const settings = read("Common/Settings.qml");
    assert.match(settings, /validPages: \[[^\]]*"modules"/);
    assert.match(read("Settings/SettingsView.qml"), /\{ id: "modules"/);
});

// Run the actual QML methods with measured slots so plugin hit-testing and
// cancellation are covered without taking over the live desktop.
function barMethod(name, context) {
    const vm = require("node:vm");
    const source = read("Bar/Bar.qml");
    const start = source.indexOf(`    function ${name}(`);
    const end = source.indexOf("\n    }", start) + 6;
    return vm.runInNewContext(`(${source.slice(start, end)})`, context);
}

test("plugin hit-testing identifies the instance and ignores hidden widgets", () => {
    const slot = {
        width: 80, height: 30,
        mapFromItem: (_frame, x, y) => ({ x: x - 100, y }),
        mapToItem: (_frame, x, y) => ({ x: x + 100, y }),
    };
    const area = {
        entries: [{ key: "timer#one", name: "Timer" }, { key: "timer#two" }],
        slotFor: key => key === "timer#one" ? slot : null,
    };
    const context = {
        slotRegistryRevision: 0, contentFrame: {}, Theme: { chipHeight: 30 },
        pluginsFor: col => col === "right" ? area : { entries: [] },
        clusterFor: () => null,
    };
    const hit = barMethod("widgetAtPoint", context);
    assert.equal(hit({ x: 120, y: 15 }).pluginKey, "timer#one");
    assert.equal(hit({ x: 120, y: 40 }), null);
    assert.equal(hit({ x: 220, y: 15 }), null);
    const index = barMethod("pluginDropIndex", context);
    assert.equal(index("right", 120), 0);
    assert.equal(index("right", 150), 2);
    assert.equal(index("left", 120), 0);
});

test("plugin drops persist instance keys and cancelled drags do not write", () => {
    const writes = [];
    const context = {
        dragWidget: { pluginKey: "timer#two" },
        dragDrop: { col: "left", idx: 1 },
        UserPlugins: { moveWidget: (...args) => writes.push(args) },
        cancelWidgetDrag: () => { context.dragWidget = context.dragDrop = null; },
    };
    const commit = barMethod("commitWidgetDrag", context);
    commit();
    assert.deepEqual(writes, [["timer#two", "left", 1]]);
    assert.equal(context.dragWidget, null);
    context.dragWidget = { pluginKey: "timer#two" };
    commit();
    assert.equal(writes.length, 1);
});
