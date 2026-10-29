// Home's "Recently changed" list (2026-10 Settings redesign): the settings a
// person changed in the Settings window, newest first, each with the value it
// had before so Undo can put it back. Only rows the search index can name are
// kept, so every entry reads as a label rather than a schema key.
//
// Kept free of Qt APIs so settings-recent.test.cjs runs it under Node.

var LIMIT = 8;

function same(a, b) {
    return JSON.stringify(a) === JSON.stringify(b);
}

function clone(value) {
    return value === undefined ? null : JSON.parse(JSON.stringify(value));
}

// The search row that names a key, preferring one that is not inside a
// widget dialog, so Undo's jump lands on a page rather than a sub-page.
function rowFor(rows, key) {
    var keyed = (rows || []).filter(function(row) { return row.key === key; });
    return keyed.filter(function(row) { return !row.widget; })[0] || keyed[0] || null;
}

// A new change. A second change to the same key keeps the first one's
// "before", so Undo returns to where the person started; changing a value
// back to it drops the entry altogether.
function record(entries, rows, key, before, after, now) {
    if (!rowFor(rows, key) || same(before, after))
        return entries;
    var list = Array.isArray(entries) ? entries : [];
    var previous = list.filter(function(entry) { return entry.key === key; })[0];
    var rest = list.filter(function(entry) { return entry.key !== key; });
    var start = previous ? previous.before : clone(before);
    if (same(start, after))
        return rest;
    return [{ key: key, before: start, after: clone(after), at: now }].concat(rest).slice(0, LIMIT);
}

function remove(entries, key) {
    return (entries || []).filter(function(entry) { return entry.key !== key; });
}

// What the file may hold: a list of well-formed entries, nothing else.
function parse(text) {
    var value;
    try { value = JSON.parse(text); } catch (e) { return []; }
    if (!value || value.version !== 1 || !Array.isArray(value.entries))
        return [];
    return value.entries.filter(function(entry) {
        return entry && typeof entry.key === "string" && typeof entry.at === "number"
            && "before" in entry && "after" in entry;
    }).slice(0, LIMIT);
}

function serialize(entries) {
    return JSON.stringify({ version: 1, entries: entries || [] });
}

// A value short enough to read beside its label; anything else is left out
// rather than shown as raw data.
function formatValue(value) {
    if (typeof value === "boolean")
        return value ? "On" : "Off";
    if (typeof value === "number")
        return String(Math.round(value * 100) / 100);
    if (typeof value === "string" && value !== "" && value.length <= 24 && value.charAt(0) !== "#")
        return value.charAt(0).toUpperCase() + value.slice(1);
    return "";
}

// "just now", "5 minutes ago", "3 hours ago", "yesterday", then a date.
function relative(at, now) {
    var minutes = Math.floor(Math.max(0, now - at) / 60000);
    if (minutes < 1)
        return "just now";
    if (minutes < 60)
        return minutes === 1 ? "1 minute ago" : minutes + " minutes ago";
    var then = new Date(at), today = new Date(now);
    var startOfToday = new Date(today.getFullYear(), today.getMonth(), today.getDate()).getTime();
    var startOfYesterday = new Date(today.getFullYear(), today.getMonth(), today.getDate() - 1).getTime();
    if (at >= startOfToday) {
        var hours = Math.floor(minutes / 60);
        return hours === 1 ? "1 hour ago" : hours + " hours ago";
    }
    if (at >= startOfYesterday)
        return "yesterday";
    var months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
    return then.getDate() + " " + months[then.getMonth()];
}

// The rows Home lists: entries whose setting still holds the value they
// recorded (a reset or a change made elsewhere has moved on from them),
// with the words to show.
function visible(entries, rows, current, now) {
    return (entries || []).filter(function(entry) {
        return same(current(entry.key), entry.after);
    }).map(function(entry) {
        var row = rowFor(rows, entry.key);
        var before = formatValue(entry.before), after = formatValue(entry.after);
        return { key: entry.key, label: row.label, page: row.page, pageLabel: row.pageLabel,
            tab: row.tab || "", widget: row.widget || "", anchor: row.anchor || row.key,
            before: before, after: after, values: before !== "" && after !== "",
            when: relative(entry.at, now), entry: entry };
    });
}

var exported = {
    LIMIT: LIMIT,
    rowFor: rowFor,
    record: record,
    remove: remove,
    parse: parse,
    serialize: serialize,
    formatValue: formatValue,
    relative: relative,
    visible: visible
};

if (typeof module !== "undefined" && module.exports)
    module.exports = exported;
