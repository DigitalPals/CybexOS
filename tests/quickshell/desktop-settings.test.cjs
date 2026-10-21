const { test } = require("node:test");
const assert = require("node:assert/strict");
const { load } = require("./shell.cjs");
const schema = load("SettingsHelpers.js");

test("notification additions preserve prior explicit choices and privacy defaults", () => {
    const settings = schema.merge({ v: 28, dock: false, notifDnd: true,
        notifDndUntilMs: 1900000000000, notifQuiet: "custom", notifQuietStart: 1200,
        notifQuietEnd: 480, notifPosition: "bottom-left", notifDuration: 17 });
    assert.equal(settings.dock, false);
    assert.equal(settings.notifDnd, true);
    assert.equal(settings.notifDndUntilMs, 1900000000000);
    assert.equal(settings.notifQuiet, "custom");
    assert.equal(settings.notifQuietStart, 1200);
    assert.equal(settings.notifQuietEnd, 480);
    assert.equal(settings.notifPosition, "bottom-left");
    assert.equal(settings.notifDuration, 17);
    assert.equal(settings.notifHistoryPersist, false);
    assert.equal(settings.notifHistoryCount, 50);
    assert.deepEqual(schema.merge(JSON.parse(schema.serialize(settings))), settings);
});

test("history, dedupe and popup settings have bounded typed values", () => {
    const bad = schema.merge({ notifHistoryPersist: "true", notifHistoryCount: 999999,
        notifHistoryHours: -1, notifHistoryBytes: Infinity, notifDedupeSeconds: 0,
        notifBurstLimit: 0, notifPopupGroups: 999, notifPopupPerGroup: "5",
        notifFullscreen: "execute" });
    assert.equal(bad.notifHistoryPersist, false);
    assert.equal(bad.notifHistoryCount, 200);
    assert.equal(bad.notifHistoryHours, 1);
    assert.equal(bad.notifHistoryBytes, 262144);
    assert.equal(bad.notifDedupeSeconds, 0);
    assert.equal(bad.notifBurstLimit, 1);
    assert.equal(bad.notifPopupGroups, 5);
    assert.equal(bad.notifPopupPerGroup, 3);
    assert.equal(bad.notifFullscreen, "away");
});
