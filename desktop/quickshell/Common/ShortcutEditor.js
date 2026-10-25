.pragma library
.import "KeybindEditor.js" as Editor
.import "KeybindHelpers.js" as KeybindHelpers

// Pure view logic for Settings → Keyboard shortcuts, the recorder and the
// keyboard map. Keybindings.qml owns the draft; this file only decides what
// to show and what an edit should be, so it stays testable under Node.
// User-visible copy lives in QML: functions here return codes.

var FILTERS = ["all", "changed", "conflicts", "user"];
// The web apps cybexos-webapp seeds (assets/scripts/cybexos-webapp DEFAULTS).
var WEBAPPS = [
    { id: "slack", name: "Slack" }, { id: "whatsapp", name: "WhatsApp" },
    { id: "youtube", name: "YouTube" }, { id: "google-photos", name: "Google Photos" },
    { id: "x", name: "X" }
];
var RUN_TYPES = ["app", "url", "webapp", "command"];
var DEFAULT_GROUPS = { app: "Apps", url: "Web", webapp: "Web apps", command: "Apps" };
// The keyboard map's rows, in keyboard order. Letters are keysyms, so a
// non-QWERTY layout still finds its keys; only the drawing is QWERTY.
var MAP_ROWS = ["1234567890", "QWERTYUIOP", "ASDFGHJKL", "ZXCVBNM"];

function lower(value) { return String(value || "").toLowerCase(); }

// Query tokens against one combination: every token must name one of its
// parts, the last token may be a prefix ("super+sh" while typing).
var ALIASES = { super: ["super", "win", "meta", "mod"], ctrl: ["ctrl", "control"],
    alt: ["alt"], shift: ["shift"] };
function comboParts(keys) {
    var normal = Editor.normalize(keys);
    if (!normal)
        return [];
    var parts = normal.split(" + ");
    var key = parts.pop();
    var out = [];
    parts.forEach(function(mod) { out.push(ALIASES[mod.toLowerCase()]); });
    out.push([lower(key), lower(KeybindHelpers.keyName(key))]);
    return out;
}
function keysMatch(keys, query) {
    var tokens = lower(query).split(/[\s+]+/).filter(Boolean);
    if (!tokens.length)
        return false;
    return (keys || []).some(function(combo) {
        var parts = comboParts(combo);
        if (!parts.length)
            return false;
        // Each token names a different part, so "super+alt+s" is not
        // satisfied by Super+Alt+E through the S of "super".
        var used = [];
        return tokens.every(function(token, index) {
            var last = index === tokens.length - 1;
            var at = -1;
            parts.forEach(function(names, part) {
                if (at < 0 && used.indexOf(part) < 0 && names.some(function(name) {
                    return name === token || (last && name.indexOf(token) === 0);
                }))
                    at = part;
            });
            used.push(at);
            return at >= 0;
        });
    });
}
function matches(row, query, translate) {
    var q = lower(query).trim();
    if (!q)
        return true;
    var tr = translate || function(text) { return text; };
    var text = [row.label, row.group, tr(row.label), tr(row.group)].map(lower).join(" ");
    return text.indexOf(q) >= 0 || keysMatch(row.keys, q);
}

// Rows whose keys collide: Lua's diagnostics for the saved state, plus
// duplicate combinations among the rows shown (a pending draft, user.lua).
function conflictIds(actions, userBinds, diagnostics) {
    var ids = {};
    (diagnostics || []).forEach(function(entry) {
        if (entry.type === "conflict" || entry.type === "displaced") {
            ids[entry.id] = true;
            if (entry.by)
                ids[entry.by] = true;
        }
    });
    var owners = {};
    function claim(id, keys) {
        (keys || []).forEach(function(key) {
            var token = lower(Editor.normalize(key));
            if (!token)
                return;
            owners[token] = owners[token] || [];
            if (owners[token].indexOf(id) < 0)
                owners[token].push(id);
        });
    }
    (actions || []).forEach(function(row) { claim(row.id, row.keys); });
    (userBinds || []).forEach(function(row, index) { claim("user." + index, row.keys); });
    Object.keys(owners).forEach(function(token) {
        if (owners[token].length > 1)
            owners[token].forEach(function(id) { ids[id] = true; });
    });
    return ids;
}

function userRows(userBinds) {
    return (userBinds || []).map(function(row, index) {
        return { id: "user." + index, group: row.group, label: row.label, keys: row.keys.slice(),
            defaultKeys: [], editable: false, protected: false, hidden: false, changed: false,
            custom: false, source: "user", userBind: true };
    });
}
function included(row, filter, conflicts) {
    if (filter === "changed")
        return !row.userBind && (row.changed || row.custom || row.source === "changed" || row.source === "custom");
    if (filter === "conflicts")
        return !!conflicts[row.id];
    if (filter === "user")
        return row.source === "user";
    return !row.userBind;
}
// Groups in the Super+K sheet's order: the vendor order first, then groups
// in the order they first appear, "Other" last.
function groups(actions, userBinds, diagnostics, options) {
    options = options || {};
    var filter = FILTERS.indexOf(options.filter) >= 0 ? options.filter : "all";
    var conflicts = conflictIds(actions, userBinds, diagnostics);
    var rows = (actions || []).filter(function(row) { return !row.hidden; }).concat(userRows(userBinds));
    var byTitle = {}, order = [];
    rows.forEach(function(row) {
        if (!included(row, filter, conflicts) || !matches(row, options.query, options.translate))
            return;
        var out = Object.assign({}, row, { conflict: !!conflicts[row.id],
            readOnly: !!row.userBind || !row.editable });
        if (!byTitle[row.group]) {
            byTitle[row.group] = { title: row.group, rows: [] };
            order.push(row.group);
        }
        byTitle[row.group].rows.push(out);
    });
    function rank(title) {
        var vendor = KeybindHelpers.GROUP_ORDER.indexOf(title);
        if (vendor >= 0)
            return vendor;
        if (title === KeybindHelpers.OTHER_GROUP)
            return 1000;
        return KeybindHelpers.GROUP_ORDER.length + order.indexOf(title);
    }
    return order.slice().sort(function(a, b) { return rank(a) - rank(b); })
        .map(function(title) { return byTitle[title]; });
}
function counts(actions, userBinds, diagnostics) {
    var out = {};
    FILTERS.forEach(function(filter) {
        out[filter] = groups(actions, userBinds, diagnostics, { filter: filter })
            .reduce(function(total, group) { return total + group.rows.length; }, 0);
    });
    return out;
}

// Why the recorder refuses a combination, "" when it may be recorded.
function reservedReason(keys) {
    var normal = Editor.normalize(keys);
    if (!normal)
        return "invalid";
    if (/mouse/i.test(normal))
        return "mouse";
    var parts = normal.split(" + "), key = lower(parts.pop());
    if (/^(xf86poweroff|xf86sleep|xf86suspend|xf86hibernate)$/.test(key))
        return "power";
    if (Editor.isReserved(normal) && parts.length === 0)
        return "modifier";
    return Editor.isReserved(normal) ? "system" : "";
}
// The recorder's verdict on one combination. A reserved combination keeps
// listening and says why; otherwise conflicts decide the buttons:
//   free     — use it;
//   replace  — other actions hold it; Replace unbinds them in the draft;
//   maybe    — only `uncertain` holders (a Shift combination the layout map
//              could not name): a warning, "Use anyway", nothing is unbound;
//   blocked  — a protected action's reserved default, user.lua or a
//              non-editable action (a hardware key) holds it; an edit here
//              cannot take it away (user.lua loads last).
// `lookup(id)` returns a holder's row: a protected action's extra keys are
// ordinary claims, so only its reserved defaults block.
function decide(keys, conflicts, lookup) {
    var reason = reservedReason(keys);
    if (reason)
        return { kind: "reserved", reason: reason, blockers: [], replace: [], maybe: [] };
    function locked(row) {
        if (!row.protected)
            return false;
        var action = lookup ? lookup(row.id) : null;
        return !action || (action.defaultKeys || []).some(function(key) { return Editor.same(key, keys); });
    }
    var certain = (conflicts || []).filter(function(row) { return !row.uncertain; });
    function fixed(row) { return row.editable === false; }
    var blockers = certain.filter(function(row) { return locked(row) || row.source === "user" || fixed(row); });
    var replace = certain.filter(function(row) { return !locked(row) && row.source !== "user" && !fixed(row); });
    var maybe = (conflicts || []).filter(function(row) { return !!row.uncertain; });
    return {
        kind: blockers.length ? "blocked" : replace.length ? "replace" : maybe.length ? "maybe" : "free",
        reason: blockers.some(function(row) { return row.protected; }) ? "protected"
            : blockers.some(function(row) { return row.source === "user"; }) ? "user"
            : blockers.some(function(row) { return row.hidden; }) ? "hardware"
            : blockers.length ? "fixed" : "",
        blockers: blockers,
        replace: replace,
        maybe: maybe
    };
}
// A protected action always keeps its reserved defaults (§1.3): they are
// shown locked and the editor only ever edits the keys beyond them.
function lockedKeys(row) {
    if (!row || !row.protected)
        return [];
    return (row.defaultKeys || []).filter(function(key) {
        return (row.keys || []).some(function(other) { return Editor.same(key, other); });
    });
}
function editableKeys(row) {
    if (!row)
        return [];
    var locked = lockedKeys(row);
    return (row.keys || []).filter(function(key) {
        return !locked.some(function(other) { return Editor.same(key, other); });
    });
}
// What a recorded combination does to the row's keys: replace them all, or
// join them as another alternative (at most four).
function nextKeys(current, combo, mode) {
    var keys = (current || []).filter(function(key) { return !Editor.same(key, combo); });
    if (mode === "add")
        return keys.length >= 4 ? null : keys.concat([Editor.normalize(combo)]);
    return [Editor.normalize(combo)];
}
function withoutKey(keys, combo) {
    return (keys || []).filter(function(key) { return !Editor.same(key, combo); });
}
// Recorder keyboard handling: Escape cancels, a bare Backspace/Delete
// clears, Return accepts a finished combination when no modifier is held.
function recorderCommand(event, hasCombo) {
    var mods = (Number(event.modifiers) || 0) & (0x10000000 | 0x04000000 | 0x08000000 | 0x02000000);
    var key = Number(event.key);
    if (mods === 0 && key === 0x01000000)
        return "cancel";
    if (mods === 0 && (key === 0x01000003 || key === 0x01000007))
        return "clear";
    if (mods === 0 && hasCombo && (key === 0x01000004 || key === 0x01000005))
        return "accept";
    return "record";
}

// Cap labels for a combination being pressed: a complete one as the sheet
// draws it, held modifiers alone ("SUPER + SHIFT") by name.
var MOD_NAMES = { SUPER: "Super", CTRL: "Ctrl", ALT: "Alt", SHIFT: "Shift" };
function liveCaps(keys) {
    var caps = Editor.display(keys);
    if (caps.length)
        return caps;
    return String(keys || "").split("+").map(function(part) { return MOD_NAMES[part.trim().toUpperCase()]; })
        .filter(Boolean);
}
// The held modifiers left after a key is released while recording. Qt may
// still report the released modifier in the event's own mask.
var MODIFIER_KEYS = { 0x01000021: 0x04000000, 0x01000022: 0x10000000, 0x01000023: 0x08000000,
    0x01000020: 0x02000000, 0x01000053: 0x10000000, 0x01000054: 0x10000000 };
function releaseCombo(event, current) {
    var key = Number(event.key);
    if (!Object.prototype.hasOwnProperty.call(MODIFIER_KEYS, key))
        return current;
    var left = (Number(event.modifiers) || 0) & ~MODIFIER_KEYS[key];
    return Editor.fromKeyEvent({ key: 0x01000020, modifiers: left }).keys;
}

// The Super+letter and Super+digit keys. Each key names its owner (a
// catalog or custom action, or a read-only user.lua binding), whether it is a
// protected action's reserved default (locked), and whether it is free.
function keyboardMap(actions, userBinds) {
    var owners = {}, reserved = {};
    function token(key) { return lower(Editor.normalize(key)); }
    (actions || []).forEach(function(row) {
        if (row.protected)
            (row.defaultKeys || []).forEach(function(key) { reserved[token(key)] = row; });
        (row.keys || []).forEach(function(key) {
            var t = token(key);
            owners[t] = owners[t] || [];
            owners[t].push({ id: row.id, label: row.label, group: row.group, protected: !!row.protected,
                editable: !!row.editable && !row.hidden, source: row.source || "default" });
        });
    });
    (userBinds || []).forEach(function(row, index) {
        (row.keys || []).forEach(function(key) {
            var t = token(key);
            owners[t] = owners[t] || [];
            owners[t].push({ id: "user." + index, label: row.label, group: row.group, protected: false,
                editable: false, source: "user" });
        });
    });
    return MAP_ROWS.map(function(letters, rowIndex) {
        return letters.split("").map(function(letter, column) {
            var combo = "SUPER + " + letter;
            var t = token(combo), list = owners[t] || [];
            var guard = reserved[t];
            return {
                key: letter, combo: combo, row: rowIndex, column: column,
                owner: list.length ? list[0] : null, owners: list,
                shared: list.length > 1,
                // Only a protected action's reserved default is locked; its
                // extra keys can be moved like any other.
                protected: !!guard,
                reservedBy: guard && !list.some(function(owner) { return owner.id === guard.id; })
                    ? { id: guard.id, label: guard.label, group: guard.group } : null,
                free: list.length === 0 && !guard
            };
        });
    });
}
// The key a map focus move lands on, by row and column, clamped. Rows are
// staggered like a keyboard, so Up/Down keep the column where they can.
function mapMove(map, row, column, key) {
    var r = row, c = column;
    if (key === "left") c--;
    else if (key === "right") c++;
    else if (key === "up") r--;
    else if (key === "down") r++;
    else if (key === "home") c = 0;
    else if (key === "end") c = Infinity;
    r = Math.max(0, Math.min(map.length - 1, r));
    c = Math.max(0, Math.min(map[r].length - 1, c));
    return { row: r, column: c };
}

// The run target a custom shortcut launches, from the Add form's fields.
// Returns { run } or { error: code } using the backend's own limits.
function byteLength(value) { return unescape(encodeURIComponent(value)).length; }
function runTarget(type, value) {
    var text = String(value || "").trim();
    if (/[\x00-\x1f\x7f-\x9f]/.test(text))
        return { error: "control" };
    if (type === "app") {
        if (!text)
            return { error: "app" };
        var id = /\.desktop$/.test(text) ? text : text + ".desktop";
        return /^[A-Za-z0-9_@.+-]+\.desktop$/.test(id) && id.length <= 255
            ? { run: { type: "app", desktopId: id } } : { error: "app" };
    }
    if (type === "url") {
        if (text && !/^[a-z][a-z0-9+.-]*:/i.test(text))
            text = "https://" + text;
        var scheme = /^(https?):\/\//i.exec(text);
        if (scheme)
            text = scheme[1].toLowerCase() + text.slice(scheme[1].length);
        return /^https?:\/\/[^/\s]+/.test(text) && byteLength(text) <= 2048
            ? { run: { type: "url", url: text } } : { error: "url" };
    }
    if (type === "webapp")
        return /^[a-z0-9][a-z0-9-]{0,63}$/.test(text) ? { run: { type: "webapp", id: text } } : { error: "webapp" };
    if (type === "command")
        return text && byteLength(text) <= 512 ? { run: { type: "command", command: text } } : { error: "command" };
    return { error: "type" };
}
function runValue(run) {
    if (!run)
        return "";
    return run.type === "app" ? String(run.desktopId || "").replace(/\.desktop$/, "")
        : run.type === "url" ? run.url : run.type === "webapp" ? run.id : run.command || "";
}
// Group and label checks, matching KeybindingsModel.checkCustom.
function labelError(group, label) {
    if (!String(label || "").trim())
        return "label";
    if (!String(group || "").trim() || /:/.test(group))
        return "group";
    if (Array.from(String(group)).length > 64 || Array.from(String(label)).length > 64)
        return "length";
    return /[\x00-\x1f\x7f-\x9f]/.test(group + label) ? "control" : "";
}
// The applications offered by the Add form's app picker: visible desktop
// entries whose IDs the backend accepts, filtered by name or ID.
function appChoices(entries, query, limit) {
    var q = lower(query).trim();
    var out = [];
    (entries || []).forEach(function(entry) {
        if (!entry || entry.noDisplay || !entry.id)
            return;
        var id = String(entry.id).replace(/\.desktop$/, "") + ".desktop";
        if (!/^[A-Za-z0-9_@.+-]+\.desktop$/.test(id) || id.length > 255)
            return;
        var name = String(entry.name || entry.id);
        if (q && (lower(name) + " " + lower(id) + " " + lower(entry.genericName)).indexOf(q) < 0)
            return;
        out.push({ desktopId: id, name: name, icon: entry.icon || "" });
    });
    out.sort(function(a, b) {
        var starts = (lower(b.name).indexOf(q) === 0) - (lower(a.name).indexOf(q) === 0);
        return starts || (a.name < b.name ? -1 : a.name > b.name ? 1 : 0);
    });
    return out.slice(0, limit || 6);
}
function webappChoices(installed) {
    var out = WEBAPPS.slice();
    (installed || []).forEach(function(app) {
        if (app && /^[a-z0-9][a-z0-9-]{0,63}$/.test(app.id) && !out.some(function(other) { return other.id === app.id; }))
            out.push({ id: app.id, name: String(app.name || app.id) });
    });
    return out;
}

// The workspace number of a "Switch to workspace N" label, for the map's
// shorter "Workspace N"; 0 for every other label.
function workspaceNumber(label) {
    var match = /^Switch to workspace (\d+)$/.exec(String(label || ""));
    return match ? Number(match[1]) : 0;
}

// Super+K sheet markers: "Group: Label" → "changed" or "user", for rows the
// sheet can name exactly. Collapsed numbered rows stay unmarked.
function sheetMarks(actions, userBinds) {
    var marks = {};
    (actions || []).forEach(function(row) {
        var source = row.source === "user" ? "user" : row.custom || row.changed || row.source === "changed" ? "changed" : "";
        var key = row.group + ": " + row.label;
        if (source && marks[key] !== "user")
            marks[key] = source;
    });
    (userBinds || []).forEach(function(row) { marks[row.group + ": " + row.label] = "user"; });
    return marks;
}

var exported = { FILTERS: FILTERS, WEBAPPS: WEBAPPS, RUN_TYPES: RUN_TYPES, DEFAULT_GROUPS: DEFAULT_GROUPS,
    MAP_ROWS: MAP_ROWS, keysMatch: keysMatch, matches: matches, conflictIds: conflictIds, groups: groups,
    counts: counts, reservedReason: reservedReason, decide: decide, nextKeys: nextKeys, withoutKey: withoutKey,
    lockedKeys: lockedKeys, editableKeys: editableKeys,
    recorderCommand: recorderCommand, keyboardMap: keyboardMap, mapMove: mapMove, runTarget: runTarget,
    runValue: runValue, labelError: labelError, appChoices: appChoices, webappChoices: webappChoices,
    sheetMarks: sheetMarks, liveCaps: liveCaps, releaseCombo: releaseCombo,
    workspaceNumber: workspaceNumber };
if (typeof module !== "undefined" && module.exports)
    module.exports = exported;
