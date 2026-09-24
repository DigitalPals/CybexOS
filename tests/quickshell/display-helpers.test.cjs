const test = require("node:test");
const assert = require("node:assert/strict");
const path = require("node:path");
const { load } = require("./shell.cjs");

const D = load("DisplayHelpers.js");
const docked = require(path.join(__dirname, "../displays/monitors-docked.json"));
const LAPTOP = "desc:Example Display Co. 0x4100 0x00000001";
const EXTERNAL = "desc:Example Monitors Inc. UHD32 SERIAL0001";

function drafts() {
    return D.draftsFromSnapshot(JSON.parse(JSON.stringify(docked)), null);
}

function byKey(list, key) {
    return list.find(item => item.key === key);
}

test("modes group by resolution, drop duplicate timings and sort fastest first", () => {
    const groups = D.modeGroups(["1920x1080@60.00Hz", "3840x2160@60.00Hz", "3840x2160@119.88Hz",
        "3840x2160@120.00Hz", "3840x2160@60.00Hz", "bogus", "0x10@60Hz"]);
    assert.deepEqual(groups.map(group => group.id), ["3840x2160", "1920x1080"]);
    assert.deepEqual(groups[0].refreshes, [120, 119.88, 60]);
    assert.equal(D.refreshLabel(119.88), "119.88 Hz");
    assert.equal(D.refreshLabel(120.001), "120 Hz");
    assert.equal(D.refreshLabel(59.94), "59.94 Hz");
    assert.equal(D.parseMode("2880x1800@120.00Hz").refresh, 120);
});

test("scales follow Hyprland's whole-logical-pixel rule", () => {
    // 3840x2160: 1.5 -> 2560x1440 and 4/3 -> 2880x1620 are exact; 1.75 is not.
    assert.equal(D.scaleValid(3840, 2160, 1.5), true);
    assert.equal(D.scaleValid(3840, 2160, 4 / 3), true);
    assert.equal(D.scaleValid(3840, 2160, 1.75), false);
    assert.equal(D.scaleValid(2880, 1800, 1.6), true);
    assert.equal(D.scaleValid(1366, 768, 1.25), false);
    assert.equal(D.scaleValid(1920, 1080, 0.1), false);
    const labels = D.scaleChoices(3840, 2160).map(choice => choice.label);
    assert.deepEqual(labels.slice(0, 5), ["Auto", "100%", "125%", "133%", "150%"]);
    assert.ok(!labels.includes("175%"));
    // A valid current scale outside the presets stays selectable.
    assert.ok(D.scaleChoices(1920, 1200, 1.2).some(choice => choice.label === "120%"));
});

test("identities follow the physical monitor unless a description is ambiguous", () => {
    const list = drafts();
    assert.deepEqual(list.map(draft => draft.key), [LAPTOP, EXTERNAL]);
    const twins = [
        { name: "DP-1", description: "Acme 27" },
        { name: "DP-2", description: "Acme 27" },
        { name: "DP-3", description: "Acme 27 Pro" },
        { name: "HDMI-A-1", description: "" },
    ];
    assert.deepEqual(twins.map(monitor => D.monitorKey(monitor, twins)),
        ["DP-1", "DP-2", "desc:Acme 27 Pro", "HDMI-A-1"],
        "a description that prefixes another cannot be a desc: selector");
    assert.equal(D.keyMatches("desc:Acme 27", twins[2]), true);
});

test("drafts mirror the live outputs and start clean", () => {
    const list = drafts();
    const external = byKey(list, EXTERNAL);
    assert.deepEqual(external.mode, { width: 3840, height: 2160, refresh: 120 });
    assert.equal(external.scale, 1.5);
    assert.deepEqual(D.logicalSize(external), { width: 2560, height: 1440 });
    assert.equal(D.validate(list), "");
    assert.equal(D.draftSignature(list), D.draftSignature(drafts()));
    const saved = { v: 1, monitors: { [LAPTOP]: { mode: "preferred", scale: "auto", vrr: 0 } } };
    const laptop = byKey(D.draftsFromSnapshot(docked, saved), LAPTOP);
    assert.equal(laptop.mode, "preferred");
    assert.equal(laptop.scale, "auto");
    assert.equal(laptop.vrr, 0);
});

test("dropping a display snaps it to a shared edge without overlap", () => {
    const moved = D.moveDisplay(drafts(), LAPTOP, -700, 300);
    const rects = D.rects(moved);
    const laptop = byKey(rects, LAPTOP);
    const external = byKey(rects, EXTERNAL);
    assert.equal(D.overlaps(laptop, external), false);
    assert.equal(D.touches(laptop, external), true);
    assert.equal(laptop.x + laptop.width, external.x, "the laptop now sits to the left");
    assert.equal(Math.min(laptop.x, external.x), 0, "the layout is normalized to 0x0");
    assert.equal(Math.min(laptop.y, external.y), 0);
    const aligned = D.rects(D.moveDisplay(drafts(), LAPTOP, 5000, 20));
    assert.equal(byKey(aligned, LAPTOP).y, byKey(aligned, EXTERNAL).y, "tops within snapping distance align");
    const below = D.rects(D.nudge(drafts(), LAPTOP, "down"));
    assert.equal(byKey(below, LAPTOP).y, byKey(below, EXTERNAL).height, "the laptop sits below");
    assert.equal(byKey(below, LAPTOP).x, (2560 - 1440) / 2, "centred under the monitor");
    const left = D.rects(D.nudge(drafts(), LAPTOP, "left"));
    assert.deepEqual([byKey(left, LAPTOP).x, byKey(left, LAPTOP).y, byKey(left, EXTERNAL).x], [0, 0, 1440]);
    // A drop that only grazes a corner still gets a real shared edge.
    const corner = D.rects(D.moveDisplay(drafts(), LAPTOP, 1440 + 2560 - 2, 1440 - 2));
    const a = byKey(corner, LAPTOP);
    const b = byKey(corner, EXTERNAL);
    const shared = a.x === b.x + b.width || b.x === a.x + a.width
        ? Math.min(a.y + a.height, b.y + b.height) - Math.max(a.y, b.y)
        : Math.min(a.x + a.width, b.x + b.width) - Math.max(a.x, b.x);
    assert.ok(shared >= 64, "shared edge " + shared);
});

test("resizing keeps neighbours on their side and never overlapping", () => {
    const before = drafts();
    const next = JSON.parse(JSON.stringify(before));
    byKey(next, EXTERNAL).scale = 1;
    const rects = D.rects(D.relayout(next, EXTERNAL, before));
    assert.deepEqual(byKey(rects, EXTERNAL), { key: EXTERNAL, x: 0, y: 0, width: 3840, height: 2160 });
    assert.equal(byKey(rects, LAPTOP).x, 3840, "the laptop stays to the right");
    const rotated = JSON.parse(JSON.stringify(before));
    byKey(rotated, LAPTOP).transform = 1;
    const portrait = byKey(D.rects(D.relayout(rotated, LAPTOP, before)), LAPTOP);
    assert.deepEqual([portrait.width, portrait.height], [900, 1440]);
});

test("validation keeps one picture on screen and mirrors well-formed", () => {
    const list = drafts();
    assert.equal(D.canDisable(list, LAPTOP), true);
    byKey(list, EXTERNAL).enabled = false;
    assert.equal(D.canDisable(list, LAPTOP), false);
    byKey(list, LAPTOP).enabled = false;
    assert.match(D.validate(list), /At least one display/);
    const mirrored = drafts();
    byKey(mirrored, LAPTOP).mirror = EXTERNAL;
    assert.equal(D.validate(mirrored), "");
    assert.equal(D.rects(mirrored).length, 1, "a mirror takes no space in the layout");
    byKey(mirrored, EXTERNAL).mirror = LAPTOP;
    assert.match(D.validate(mirrored), /mirror/);
    const overlapping = drafts();
    byKey(overlapping, LAPTOP).x = byKey(overlapping, EXTERNAL).x;
    assert.match(D.validate(overlapping), /overlap/);
});

test("the saved document keeps other monitors and unknown fields and records companions", () => {
    const previous = {
        v: 1,
        future: { keep: true },
        monitors: {
            "desc:Projector 9000": { scale: 1, enabled: true, note: "kept" },
            "eDP-1": { description: "Example Display Co. 0x4100 0x00000001", scale: 1 },
            [EXTERNAL]: { custom: 42, vrr: 2, mirror: "eDP-1" },
        },
    };
    const list = drafts();
    byKey(list, LAPTOP).enabled = false;
    byKey(list, EXTERNAL).vrr = -1;
    const document = D.buildDocument(previous, list);
    assert.deepEqual(document.future, { keep: true });
    assert.deepEqual(document.monitors["desc:Projector 9000"], previous.monitors["desc:Projector 9000"]);
    assert.equal(document.monitors["eDP-1"], undefined, "the connector-keyed entry moved to its description key");
    const laptop = document.monitors[LAPTOP];
    assert.equal(laptop.enabled, false);
    assert.deepEqual(laptop.disabledWith, [EXTERNAL]);
    assert.equal(laptop.connector, "eDP-1");
    const external = document.monitors[EXTERNAL];
    assert.equal(external.custom, 42);
    assert.equal(external.vrr, undefined, "Default removes the explicit VRR choice");
    assert.equal(external.mirror, undefined);
    assert.deepEqual(external.mode, { width: 3840, height: 2160, refresh: 120 });
    assert.deepEqual(external.position, { x: 1440, y: 0 });
    assert.equal(previous.monitors[EXTERNAL].vrr, 2, "the previous document is not mutated");
});

test("the trial countdown never goes negative", () => {
    assert.equal(D.secondsLeft(100, 90000), 10);
    assert.equal(D.secondsLeft(100, 100500), 0);
    assert.equal(D.secondsLeft(100, 200000), 0);
    assert.equal(D.TRIAL_SECONDS, 15);
});
