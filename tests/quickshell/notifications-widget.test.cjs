const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { shellDir, load } = require("./shell.cjs");

function read(relative) {
    return fs.readFileSync(path.join(shellDir, relative), "utf8");
}

const moduleSource = read("Bar/Modules/Notifications.qml");

test("notification history is an always-eligible reorderable widget", () => {
    const settings = load("SettingsHelpers.js");
    const catalog = load("WidgetCatalog.js");
    const defaults = settings.defaultMods();
    const rightIds = defaults.right.map(entry => entry.id);

    assert.equal(rightIds[rightIds.indexOf("tray") + 1], "notifications");
    assert.equal(rightIds[rightIds.indexOf("notifications") + 1], "vol");
    assert.equal(defaults.right.find(entry => entry.id === "notifications").on, true);
    assert.equal(settings.moduleGroup("notifications", settings.defaultModOpts()), "status");
    assert.equal(settings.moduleGroup("notifications",
        { notifications: { group: "solo" } }), "solo");
    assert.equal(catalog.WIDGETS.notifications.name, "Notifications");
    assert.equal(catalog.WIDGETS.notifications.detail, true);
    assert.match(read("Bar/Bar.qml"),
        /notifications:\s*"Modules\/Notifications\.qml"/);
    assert.match(read("Settings/ModulesPage.qml"),
        /hasDetail:\s*page\.selected \? page\.selected\.detail : false/,
        "a detail-only widget must still expose its compaction policy");
});

test("notification widget shows an unread mark and compact glyph state", () => {
    assert.match(moduleSource, /moduleId:\s*"notifications"/);
    assert.match(moduleSource, /panelName:\s*"notifications"/);
    // The edge-drawer design trades the bar count for an accent unread dot;
    // the count lives in the tooltip and the drawer's Notifications tab.
    assert.match(moduleSource, /visible:\s*Notifs\.count > 0/);
    assert.match(moduleSource,
        /color:\s*Notifs\.hasUrgent \? Theme\.barRedText : Theme\.barAccent/);
    assert.doesNotMatch(moduleSource, /label:\s*Notifs\.count/,
        "the bell carries a dot, not a number");
    assert.match(moduleSource, /Notifs\.count \+ " notifications"/,
        "the tooltip still says how many");
    assert.match(moduleSource,
        /glyph:\s*Notifs\.dnd \? "notifications_off" : "notifications"/);
    assert.match(moduleSource, /alert:\s*Notifs\.hasUrgent/);
    assert.match(moduleSource, /active:\s*Notifs\.dnd && !Notifs\.hasUrgent/);
});

test("opening notification history does not consume its retained entries", () => {
    const notifs = read("Common/Notifs.qml");
    assert.match(notifs, /readonly property int count:\s*entries\.length/);
    assert.match(notifs, /function dismiss\(entry\)[\s\S]{0,100}?removeEntry\(entry\.key\)/);
    assert.match(notifs, /function clearAll\(\)[\s\S]{0,100}?entries = \[\]/);
    assert.doesNotMatch(moduleSource, /Notifs\.(?:dismiss|clearAll|removeEntry)\(/,
        "opening the panel must not mark retained session history as read");
});

test("the retired bell id is not reused for the new widget", () => {
    const settings = load("SettingsHelpers.js");
    assert.ok(settings.RETIRED_MODULE_IDS.includes("bell"));
    assert.ok(!settings.MODULE_IDS.includes("bell"));
    assert.ok(settings.MODULE_IDS.includes("notifications"));
    assert.equal(fs.existsSync(path.join(shellDir, "Bar/Modules/Bell.qml")), false);
});
