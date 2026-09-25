const test = require("node:test");
const assert = require("node:assert/strict");
const { load } = require("./shell.cjs");

const H = load("LayoutHelpers.js");
const SettingsHelpers = load("SettingsHelpers.js");

test("the clock pill and the status pill group per the edge-drawer design", () => {
    const defaults = SettingsHelpers.defaultMods();
    const defaultOptions = SettingsHelpers.defaultModOpts();
    const center = H.groupModules(defaults.center,
        id => SettingsHelpers.moduleGroup(id, defaultOptions));
    // Clock and weather share one filled "time" pill; indicators and Notes
    // each retain their own pointer target.
    assert.deepEqual(center.map(group => group.kind), ["solo", "time", "solo"]);
    assert.deepEqual(center[1].items.map(item => item.entry.id),
        ["clock", "weather"]);
    assert.deepEqual(center[2].items.map(item => item.entry.id), ["notes"]);
    assert.ok(SettingsHelpers.groupFilled("time"));

    const right = H.groupModules(defaults.right,
        id => SettingsHelpers.moduleGroup(id, defaultOptions));
    const notificationGroup = right.find(group =>
        group.items.some(item => item.entry.id === "notifications"));
    assert.equal(notificationGroup.kind, "status");
    const agentGroup = right.find(group =>
        group.items.some(item => item.entry.id === "hermes"));
    assert.equal(agentGroup.kind, "chip");
    assert.ok(!SettingsHelpers.groupFilled("chip"));
    assert.deepEqual(agentGroup.items.map(item => item.entry.id),
        ["gh", "t3", "hermes"]);
    // Notifications and the four status glyphs share one filled pill; each keeps its own
    // pointer target inside it (the pill is furniture, not a hit area).
    const statusGroup = right.find(group =>
        group.items.some(item => item.entry.id === "vol"));
    assert.equal(statusGroup.kind, "status");
    assert.ok(SettingsHelpers.groupFilled("status"));
    assert.deepEqual(statusGroup.items.map(item => item.entry.id),
        ["notifications", "vol", "wifi", "bt", "batt"]);

    const separateOptions = SettingsHelpers.defaultModOpts();
    separateOptions.notifications.group = "solo";
    const separated = H.groupModules(defaults.right,
        id => SettingsHelpers.moduleGroup(id, separateOptions));
    assert.equal(separated.find(group =>
        group.items.some(item => item.entry.id === "notifications")).kind, "solo");
    assert.deepEqual(separated.find(group =>
        group.items.some(item => item.entry.id === "vol"))
        .items.map(item => item.entry.id), ["vol", "wifi", "bt", "batt"]);
});

test("stacked drops subtract each column origin before finding the row", () => {
    const columns = [
        { id: "left", y: 0, height: 90, rowsStart: 20, pitch: 31, length: 2 },
        { id: "center", y: 98, height: 121, rowsStart: 20, pitch: 31, length: 3 },
        { id: "right", y: 227, height: 152, rowsStart: 20, pitch: 31, length: 4 }
    ];
    assert.deepEqual(H.stackedDropIndex(columns, 120), { col: "center", idx: 0 });
    assert.deepEqual(H.stackedDropIndex(columns, 174), { col: "center", idx: 2 });
    assert.deepEqual(H.stackedDropIndex(columns, 999), { col: "right", idx: 4 });
});

test("wide measured layouts remain detailed and centered", () => {
    const result = H.fitBar({
        width: 1440, sideMargin: 12, gutter: 8,
        widths: { left: 220, center: 240, right: 390 },
        entries: [
            { id: "media", col: "left", saving: 120, policy: "auto" },
            { id: "weather", col: "center", saving: 70, policy: "auto" }
        ]
    });
    assert.deepEqual(result.compact, []);
    assert.equal(result.centerOffset, 0);
    assert.equal(result.fits, true);
});

test("measured fitting compacts auto detail before prefer-detail", () => {
    const result = H.fitBar({
        width: 800, gutter: 8,
        widths: { left: 300, center: 220, right: 310 },
        entries: [
            { id: "media", col: "left", saving: 60, policy: "prefer" },
            { id: "weather", col: "center", saving: 30, policy: "auto" },
            { id: "clock", col: "center", saving: 45, policy: "auto" },
            { id: "t3", col: "right", saving: 60, policy: "auto" }
        ]
    });
    assert.deepEqual(result.compact, ["t3", "weather", "clock"]);
    assert.equal(result.compact.includes("media"), false);
    assert.equal(result.fits, true);
});

test("forced compact modules stay present and the center shifts last", () => {
    const result = H.fitBar({
        width: 800, gutter: 8,
        widths: { left: 330, center: 180, right: 250 },
        entries: [
            { id: "media", col: "left", saving: 20, policy: "compact" },
            { id: "weather", col: "center", saving: 10, policy: "auto" }
        ]
    });
    assert.ok(result.compact.includes("media"));
    assert.ok(result.compact.includes("weather"));
    assert.equal(result.fits, true);
    assert.equal(result.shifted, true);
    assert.ok(result.widths.left + 8 <= result.centerX);
    assert.ok(result.centerX + result.widths.center + 8
        <= 800 - result.widths.right);
});

test("all-auto detail follows the documented compaction order", () => {
    const entries = H.COMPACT_ORDER.map(id => ({
        id,
        col: id === "media" ? "left"
            : id === "clock" || id === "weather" ? "center" : "right",
        saving: 20,
        policy: "auto"
    }));
    const result = H.fitBar({
        width: 800, gutter: 8,
        widths: { left: 390, center: 300, right: 460 },
        entries
    });
    assert.deepEqual(result.compact, H.COMPACT_ORDER);
    assert.equal(entries.length, H.COMPACT_ORDER.length,
        "fitting changes detail, not module enablement");
});

test("notification count participates in responsive compaction", () => {
    assert.ok(H.COMPACT_ORDER.includes("notifications"));
    const result = H.fitBar({
        width: 600, gutter: 8,
        widths: { left: 240, center: 180, right: 250 },
        entries: [
            { id: "notifications", col: "right", saving: 24, policy: "auto" }
        ]
    });
    assert.deepEqual(result.compact, ["notifications"]);
});

test("Hermes activity detail participates in responsive compaction", () => {
    assert.ok(H.COMPACT_ORDER.includes("hermes"));
    assert.ok(H.COMPACT_ORDER.indexOf("hermes") > H.COMPACT_ORDER.indexOf("t3"));
});

test("narrow bars overflow low-priority modules but retain core status", () => {
    const entries = [
        { id: "ws", col: "left", width: 90, saving: 0, policy: "auto" },
        { id: "media", col: "left", width: 120, saving: 40, policy: "auto" },
        { id: "indicators", col: "center", width: 60, saving: 0, policy: "auto", centerSide: "left" },
        { id: "clock", col: "center", width: 100, saving: 30, policy: "auto", centerSide: "right" },
        { id: "gh", col: "right", width: 60, saving: 20, policy: "auto" },
        { id: "wifi", col: "right", width: 40, saving: 0, policy: "auto" },
        { id: "batt", col: "right", width: 55, saving: 15, policy: "auto" }
    ];
    const result = H.fitBar({
        width: 430, gutter: 8, overflowWidth: 30,
        widths: { left: 210, center: 160, right: 155 },
        centerExtents: { left: 60, right: 100 },
        entries
    });
    assert.equal(result.fits, true);
    assert.ok(result.overflow.includes("media") || result.overflow.includes("gh"));
    for (const critical of ["ws", "clock", "wifi", "batt"])
        assert.equal(result.overflow.includes(critical), false);
    assert.deepEqual(H.OVERFLOW_ORDER.slice(0, 5),
        ["media", "updates", "gh", "t3", "hermes"]);
});

test("asymmetric center extents pin the clock while actions reveal on its left", () => {
    const hidden = H.fitBar({
        width: 1200, gutter: 8,
        widths: { left: 220, center: 180, right: 260 },
        centerExtents: { left: 40, right: 140 },
        entries: []
    });
    const revealed = H.fitBar({
        width: 1200, gutter: 8,
        widths: { left: 220, center: 330, right: 260 },
        centerExtents: { left: 190, right: 140 },
        entries: []
    });
    assert.equal(hidden.centerX + 40, 600);
    assert.equal(revealed.centerX + 190, 600,
        "the semantic clock point must stay fixed as the left extent grows");
    assert.equal(hidden.centerOffset, 0);
    assert.equal(revealed.centerOffset, 0);
});

test("asymmetric center extents shift only when a side collision requires it", () => {
    const result = H.fitBar({
        width: 800, gutter: 8,
        widths: { left: 360, center: 300, right: 120 },
        centerExtents: { left: 210, right: 90 },
        entries: []
    });
    assert.equal(result.fits, true);
    assert.equal(result.shifted, true);
    assert.ok(result.centerX >= result.widths.left + 8);
    assert.ok(result.centerX + result.centerExtents.left
        + result.centerExtents.right + 8 <= 800 - result.widths.right);
});

test("high resolution wheel deltas emit only accumulated steps", () => {
    let accumulator = 0;
    let steps = 0;
    for (let i = 0; i < 4; i++) {
        const result = H.accumulateWheel(accumulator, 30, 120);
        accumulator = result.accumulator;
        steps += result.steps;
    }
    assert.equal(steps, 1);
    assert.equal(accumulator, 0);
    assert.deepEqual(H.accumulateWheel(0, -240, 120), { accumulator: 0, steps: -2 });
});

test("edge joins shorten only the island side when it nears the bar tangent", () => {
    const base = {
        floating: true,
        barRadius: 9,
        popRadius: 14,
        sideMargin: 12,
        width: 1920
    };

    assert.deepEqual(H.edgeFlareRadii({
        ...base, island: "left", bodyX: 26, bodyW: 400
    }), { left: 5, right: 14 });
    assert.deepEqual(H.edgeFlareRadii({
        ...base, island: "right", bodyX: 1494, bodyW: 400
    }), { left: 14, right: 5 });
});

test("roomy edge popouts retain full flares on both sides", () => {
    const base = {
        floating: true,
        barRadius: 9,
        popRadius: 14,
        sideMargin: 12,
        width: 1920,
        bodyX: 700,
        bodyW: 520
    };

    assert.deepEqual(H.edgeFlareRadii({ ...base, island: "left" }), {
        left: 14, right: 14
    });
    assert.deepEqual(H.edgeFlareRadii({ ...base, island: "right" }), {
        left: 14, right: 14
    });
});

test("center and square attached bars retain full flares", () => {
    const base = {
        floating: true, barRadius: 9, popRadius: 14,
        sideMargin: 12, width: 1920, bodyX: 26, bodyW: 1868
    };
    assert.deepEqual(H.edgeFlareRadii({ ...base, island: "center" }), {
        left: 14, right: 14
    });
    assert.deepEqual(H.edgeFlareRadii({
        ...base, island: "right", floating: false
    }), { left: 14, right: 14 });
});
