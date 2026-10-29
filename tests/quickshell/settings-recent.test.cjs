// Home's "Recently changed" list (2026-10 Settings redesign): what is kept,
// how a second change to one setting folds into the first, what Undo
// returns to, and what the state file may hold.
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { load, shellDir, untranslated } = require("./shell.cjs");

const R = load("SettingsRecentHelpers.js");
const { ROWS } = load("SettingsSearchData.js");
const MIN = 60 * 1000;

test("only settings the search index can name are recorded", () => {
    assert.deepEqual(R.record([], ROWS, "clock24", true, false, 1), [{ key: "clock24", before: true, after: false, at: 1 }]);
    assert.equal(R.record([], ROWS, "assistantX", 10, 20, 1).length, 0, "bookkeeping has no row to show");
    const same = [];
    assert.equal(R.record(same, ROWS, "clock24", true, true, 1), same, "no change, no entry");
});

test("a second change keeps where the person started, and changing back drops it", () => {
    let entries = R.record([], ROWS, "notifPosition", "top-right", "top-left", 1);
    entries = R.record(entries, ROWS, "clock24", true, false, 2);
    entries = R.record(entries, ROWS, "notifPosition", "top-left", "bottom-left", 3);
    assert.deepEqual(entries.map(entry => [entry.key, entry.before, entry.after]),
        [["notifPosition", "top-right", "bottom-left"], ["clock24", true, false]], "newest first, first 'before' kept");
    entries = R.record(entries, ROWS, "notifPosition", "bottom-left", "top-right", 4);
    assert.deepEqual(entries.map(entry => entry.key), ["clock24"]);
    assert.deepEqual(R.remove(entries, "clock24"), []);
});

test("the list stays short", () => {
    let entries = [];
    const keys = ROWS.filter(row => row.key !== "" && row.key !== "mods").map(row => row.key);
    for (const [index, key] of [...new Set(keys)].slice(0, R.LIMIT + 4).entries())
        entries = R.record(entries, ROWS, key, index, index + 1, index);
    assert.equal(entries.length, R.LIMIT);
});

test("Home shows entries whose setting still holds the recorded value, in words", () => {
    const now = Date.UTC(2026, 9, 28, 12, 0);
    const entries = [{ key: "clock24", before: true, after: false, at: now - 5 * MIN },
        { key: "notifPosition", before: "top-right", after: "top-left", at: now - 2 * 60 * MIN }];
    const current = { clock24: false, notifPosition: "bottom-right" };
    const rows = R.visible(entries, ROWS, key => current[key], now);
    assert.deepEqual(rows.map(row => row.key), ["clock24"], "a value moved on since is not offered");
    assert.equal(rows[0].label, "Clock");
    assert.equal(rows[0].page, "region");
    assert.equal(rows[0].before, "On");
    assert.equal(rows[0].after, "Off");
    assert.equal(rows[0].when, "5 minutes ago");
    assert.equal(rows[0].entry, entries[0], "Undo restores the recorded value");
});

test("values read as words or not at all, and times read relatively", () => {
    assert.equal(R.formatValue(true), "On");
    assert.equal(R.formatValue(0.75), "0.75");
    assert.equal(R.formatValue("nights"), "Nights");
    assert.equal(R.formatValue("#60a5fa"), "", "a colour is not a word");
    assert.equal(R.formatValue({ left: [] }), "");
    const now = new Date(2026, 9, 28, 12, 0).getTime();
    assert.equal(R.relative(now - 10 * 1000, now), "just now");
    assert.equal(R.relative(now - MIN, now), "1 minute ago");
    assert.equal(R.relative(now - 3 * 60 * MIN, now), "3 hours ago");
    assert.equal(R.relative(new Date(2026, 9, 27, 23, 0).getTime(), now), "yesterday");
    assert.equal(R.relative(new Date(2026, 9, 20, 9, 0).getTime(), now), "20 Oct");
});

test("the state file holds well-formed entries only", () => {
    const entries = [{ key: "clock24", before: true, after: false, at: 1 }];
    assert.deepEqual(R.parse(R.serialize(entries)), entries);
    for (const text of ["", "{", "[]", '{"version":2,"entries":[]}',
            '{"version":1,"entries":[{"key":1,"at":1,"before":1,"after":2}]}'])
        assert.deepEqual(R.parse(text), [], text);
});

test("the recorder writes only while the Settings window is open, and Undo is not a change", () => {
    const source = untranslated(fs.readFileSync(path.join(shellDir, "Common/SettingsRecent.qml"), "utf8"));
    assert.match(source, /if \(root\.restoring \|\| !Settings\.panelOpen\)\s*return;/);
    assert.match(source, /restoring = true;\s*Settings\.set\(row\.key, row\.entry\.before\);\s*restoring = false;/);
    assert.match(source, /\/\.local\/state\/cybexos\/shell\/settings-recent\.json"/, "a private state file, not shell.json");
    assert.match(source, /atomicWrites: true/);
    const settings = fs.readFileSync(path.join(shellDir, "Common/Settings.qml"), "utf8");
    assert.match(settings, /const before = root\[key\];\s*root\[key\] = SettingsHelpers\.normalizeKey\(key, value\);\s*valueSet\(key, before, root\[key\]\);/);
    // The view creates the recorder before the first change can happen.
    assert.match(fs.readFileSync(path.join(shellDir, "Settings/SettingsView.qml"), "utf8"),
        /readonly property int recentCount: SettingsRecent\.entries\.length/);
});
