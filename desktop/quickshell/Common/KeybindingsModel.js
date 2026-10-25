.pragma library
.import "KeybindEditor.js" as Editor
.import "KeybindHelpers.js" as KeybindHelpers

function copy(value) { return JSON.parse(JSON.stringify(value)); }
function identity(key) { return Editor.normalize(key).toLowerCase(); }
function equal(a, b) {
    // Object member order is not a preference change; alternative-key order is.
    function stable(value) {
        if (Array.isArray(value)) return value.map(stable);
        if (value && typeof value === "object") {
            var out = {};
            Object.keys(value).sort().forEach(function(key) { out[key] = stable(value[key]); });
            return out;
        }
        return value;
    }
    return JSON.stringify(stable(a)) === JSON.stringify(stable(b));
}
// Used only for unsaved draft previews. Saved rows always come from Lua's
// state file. Shared fixtures keep the preview's claim order identical.
function resolve(catalog, document) {
    document = document || {};
    var reserved = Object.create(null), claims = Object.create(null), overridden = Object.create(null), diagnostics = [];
    var rows = catalog.map(function(action) {
        var row = copy(action);
        row.defaultKeys = (action.defaultKeys || action.keys).map(Editor.normalize);
        row.keys = row.defaultKeys.slice();
        row.changed = false;
        row.custom = false;
        if (row.protected)
            row.defaultKeys.forEach(function(key) { reserved[identity(key)] = row.id; });
        var override = (document.actions || {})[row.id];
        if (override && row.editable && (!row.protected || override.keys.length)) {
            row.keys = override.keys.map(Editor.normalize);
            overridden[row.id] = true;
        }
        return row;
    });
    function claim(row) {
        var accepted = [];
        row.keys.forEach(function(key) {
            var token = identity(key), owner = reserved[token] || claims[token];
            if (owner && owner !== row.id)
                diagnostics.push({ type: "conflict", id: row.id, keys: key, by: owner });
            else if (!accepted.some(function(other) { return Editor.same(other, key); })) {
                claims[token] = row.id;
                accepted.push(key);
            }
        });
        row.keys = accepted;
        // Protected actions always keep their reserved defaults, as in Lua.
        if (row.protected)
            row.defaultKeys.forEach(function(key) {
                if (!row.keys.some(function(other) { return Editor.same(other, key); })) row.keys.push(key);
            });
    }
    rows.forEach(function(row) { if (overridden[row.id]) claim(row); });
    var custom = (document.custom || []).map(function(entry) {
        var row = copy(entry);
        row.keys = row.keys.map(Editor.normalize);
        claim(row);
        return row;
    });
    rows.forEach(function(row) {
        if (!overridden[row.id]) {
            row.keys = row.keys.filter(function(key) {
                var owner = claims[identity(key)];
                if (owner && owner !== row.id) {
                    diagnostics.push({ type: "displaced", id: row.id, keys: key, by: owner });
                    return false;
                }
                return true;
            });
        }
        row.changed = !equal(row.keys.map(identity), row.defaultKeys.map(identity));
    });
    return { v: 1, actions: rows, custom: custom, diagnostics: diagnostics };
}
function bindKey(bind) {
    var mods = KeybindHelpers.modifierNames(bind.modmask).map(function(mod) { return mod.toUpperCase(); });
    var key = Number(bind.keycode) > 0 ? "code:" + bind.keycode : String(bind.key || "");
    return Editor.normalize(mods.concat([key]).join(" + "));
}
function merge(state, binds) {
    var rows = copy(state.actions || []).concat((state.custom || []).map(function(entry) {
        return Object.assign({}, copy(entry), { defaultKeys: [], editable: true, protected: false,
            hidden: false, changed: true, custom: true });
    }));
    var knownDescriptions = Object.create(null);
    rows.forEach(function(row) {
        var description = row.group + ": " + row.label;
        knownDescriptions[description] = knownDescriptions[description] || [];
        knownDescriptions[description].push(row);
    });
    var live = (binds || []).filter(function(bind) { return !bind.submap; });
    rows.forEach(function(row) {
        var description = row.group + ": " + row.label;
        var expected = row.keys.slice();
        // Descriptions are shared by distinct actions (focus directions and
        // zoom steps). Match each key too, so those actions stay independent.
        var actual = live.filter(function(bind) { return bind.description === description; }).map(bindKey).filter(Boolean);
        var missing = expected.some(function(key) {
            return !actual.some(function(other) { return Editor.same(key, other); });
        });
        var shared = knownDescriptions[description].length > 1;
        var extra = !shared && actual.some(function(key) {
            return !expected.some(function(other) { return Editor.same(key, other); });
        });
        row.source = missing || extra ? "user" : row.custom ? "custom" : row.changed ? "changed" : "default";
        if (missing || extra) {
            // A missing key is no longer effective. Extra keys with a unique
            // description are a useful remap; ambiguous shared labels cannot
            // identify which dispatcher user.lua meant, so don't guess.
            row.keys = shared ? expected.filter(function(key) {
                return actual.some(function(other) { return Editor.same(key, other); });
            }) : actual;
        }
    });
    var user = [];
    (binds || []).forEach(function(bind) {
        if (!bind.description) return;
        var key = bindKey(bind);
        if (!key) return;
        var known = knownDescriptions[bind.description];
        if (!bind.submap && known && (known.length === 1 || known.some(function(row) {
            return row.keys.some(function(other) { return Editor.same(key, other); });
        }))) return;
        var parsed = KeybindHelpers.parseDescription(bind.description);
        var label = parsed.label + (bind.submap ? " (" + bind.submap + ")" : "");
        var existing = user.find(function(row) { return row.group === parsed.group && row.label === label; });
        if (!existing) {
            existing = { keys: [], group: parsed.group, label: label };
            user.push(existing);
        }
        if (!existing.keys.some(function(other) { return Editor.same(other, key); })) existing.keys.push(key);
    });
    return { actions: rows, userBinds: user, diagnostics: copy(state.diagnostics || []) };
}
function create() {
    return { loaded: false, version: "", saved: {v: 1}, draft: {v: 1},
        state: {actions: [], custom: [], diagnostics: []}, binds: [], pending: null };
}
function dirty(model) { return !equal(model.saved, model.draft); }
function ingest(model, snapshot) {
    model.binds = copy(snapshot.binds || []);
    if (!model.loaded || !dirty(model)) {
        model.state = copy(snapshot.state);
        model.saved = copy(snapshot.preferences);
        model.draft = copy(snapshot.preferences);
        model.version = snapshot.version;
    }
    model.loaded = true;
}
function view(model) {
    var state = dirty(model) ? resolve(model.state.actions, model.draft) : model.state;
    var result = merge(state, model.binds);
    if (dirty(model)) {
        // Draft keys have not reached Hyprland. Only compare saved rows with
        // user.lua, then overlay those rows whose draft choice is unchanged.
        var saved = merge(model.state, model.binds);
        result.actions.forEach(function(row) {
            var before = saved.actions.find(function(other) { return other.id === row.id; });
            var original = (model.state.actions || []).concat(model.state.custom || [])
                .find(function(other) { return other.id === row.id; });
            var resolved = (state.actions || []).concat(state.custom || []).find(function(other) { return other.id === row.id; });
            row.keys = resolved.keys.slice();
            row.source = row.custom ? "custom" : row.changed ? "changed" : "default";
            if (before && before.source === "user" && original && equal(original.keys.map(identity), resolved.keys.map(identity))) {
                row.keys = before.keys;
                row.source = "user";
            }
        });
    }
    return result;
}
function action(model, id) { return view(model).actions.find(function(row) { return row.id === id; }) || null; }
function keysFor(model, id) { var row = action(model, id); return row ? row.keys.slice() : []; }
function conflicts(model, key, exceptId) {
    var result = [], current = view(model);
    current.actions.forEach(function(row) {
        var protectedDefault = row.protected && row.defaultKeys.some(function(other) { return Editor.same(key, other); });
        if (row.id !== exceptId && (protectedDefault || row.keys.some(function(other) { return Editor.same(key, other); })))
            result.push({ id: row.id, group: row.group, label: row.label, protected: row.protected, source: row.source });
    });
    // user.lua runs after the next apply too. A draft remap must not hide
    // a live personal key that will still be present after the reload.
    merge(model.state, model.binds).actions.forEach(function(row) {
        if (row.source === "user" && row.id !== exceptId
                && !result.some(function(other) { return other.id === row.id; })
                && row.keys.some(function(other) { return Editor.same(key, other); }))
            result.push({ id: row.id, group: row.group, label: row.label, protected: row.protected, source: "user" });
    });
    current.userBinds.forEach(function(row, index) {
        if (row.keys.some(function(other) { return Editor.same(key, other); }))
            result.push({ id: "user." + index, group: row.group, label: row.label, protected: false, source: "user" });
    });
    // Competing claims can be dropped by resolution; keep them visible while
    // editing so a second pending assignment never appears conflict-free.
    var claimed = Object.keys(model.draft.actions || {}).map(function(id) {
        var row = action(model, id);
        return row ? Object.assign({}, row, {keys: model.draft.actions[id].keys}) : null;
    }).concat(model.draft.custom || []);
    claimed.forEach(function(row) {
        if (row && row.id !== exceptId && !result.some(function(other) { return other.id === row.id; })
                && row.keys.some(function(other) { return Editor.same(key, other); }))
            result.push({ id: row.id, group: row.group, label: row.label, protected: !!row.protected,
                source: row.custom || row.id.indexOf("custom.") === 0 ? "custom" : "changed" });
    });
    return result;
}
function checkedKeys(keys) {
    if (!Array.isArray(keys) || keys.length > 4) throw new Error("Choose at most four keys per shortcut");
    var out = keys.map(Editor.normalize);
    if (out.some(function(key, index) {
        return !key || /mouse/i.test(key) || out.slice(0, index).some(function(other) { return Editor.same(key, other); });
    })) throw new Error("Invalid or duplicate shortcut key");
    return out;
}
function setKeys(model, id, keys) {
    var row = action(model, id);
    if (!row || !row.editable) throw new Error("This shortcut cannot be edited");
    keys = checkedKeys(keys);
    if (row.protected && !keys.length) throw new Error("This shortcut must keep at least one key");
    // The reserved defaults stay bound whatever is stored, so only extra keys
    // are kept in the file; nothing extra means the plain default.
    if (row.protected) {
        keys = keys.filter(function(key) {
            return !row.defaultKeys.some(function(other) { return Editor.same(key, other); });
        });
        if (!keys.length) keys = row.defaultKeys.slice();
    }
    if (row.custom) {
        model.draft.custom.find(function(entry) { return entry.id === id; }).keys = keys;
    } else {
        model.draft.actions = model.draft.actions || {};
        if (equal(keys.map(identity), row.defaultKeys.map(identity))) delete model.draft.actions[id];
        else model.draft.actions[id] = Object.assign({}, model.draft.actions[id] || {}, {keys: keys});
        if (!Object.keys(model.draft.actions).length) delete model.draft.actions;
    }
}
function reset(model, id) {
    if (id.indexOf("custom.") === 0) {
        var saved = (model.saved.custom || []).find(function(row) { return row.id === id; });
        removeCustom(model, id);
        if (saved) { model.draft.custom = model.draft.custom || []; model.draft.custom.push(copy(saved)); }
    } else if (model.draft.actions) {
        delete model.draft.actions[id];
        if (!Object.keys(model.draft.actions).length) delete model.draft.actions;
    }
}
function resetAll(model) {
    delete model.draft.actions;
    delete model.draft.custom;
}
function checkCustom(entry) {
    if (!entry || typeof entry.group !== "string" || typeof entry.label !== "string"
            || !entry.group.length || !entry.label.length || Array.from(entry.group).length > 64
            || Array.from(entry.label).length > 64 || /[:\x00-\x1f\x7f-\x9f]/.test(entry.group)
            || /[\x00-\x1f\x7f-\x9f]/.test(entry.label)) throw new Error("Invalid shortcut group or label");
    entry.keys = checkedKeys(entry.keys);
    var run = entry.run || {}, valid = false;
    if (run.type === "app") valid = typeof run.desktopId === "string" && /^[A-Za-z0-9_@.+-]+\.desktop$/.test(run.desktopId) && run.desktopId.length <= 255;
    if (run.type === "webapp") valid = typeof run.id === "string" && /^[a-z0-9][a-z0-9-]{0,63}$/.test(run.id);
    if (run.type === "url") valid = typeof run.url === "string" && /^https?:\/\/[^/\s]+/.test(run.url) && byteLength(run.url) <= 2048;
    if (run.type === "command") valid = typeof run.command === "string" && run.command.length > 0 && byteLength(run.command) <= 512;
    if (!valid || Object.keys(run).some(function(key) { return typeof run[key] === "string" && /[\x00-\x1f\x7f-\x9f]/.test(run[key]); }))
        throw new Error("Invalid shortcut launch");
    return entry;
}
function byteLength(value) { return unescape(encodeURIComponent(value)).length; }
function addCustom(model, entry) {
    entry = checkCustom(copy(entry));
    var index = 1;
    var all = (model.saved.custom || []).concat(model.draft.custom || []);
    while (all.some(function(row) { return row.id === "custom.shortcut-" + index; })) index++;
    entry.id = "custom.shortcut-" + index;
    model.draft.custom = model.draft.custom || [];
    model.draft.custom.push(entry);
    return entry.id;
}
function updateCustom(model, id, patch) {
    var index = (model.draft.custom || []).findIndex(function(row) { return row.id === id; });
    if (index < 0) throw new Error("Unknown custom shortcut");
    if (Object.keys(patch).some(function(key) { return ["group", "label", "keys", "run"].indexOf(key) < 0; }))
        throw new Error("Invalid custom shortcut change");
    model.draft.custom[index] = checkCustom(Object.assign({}, model.draft.custom[index], copy(patch)));
}
function removeCustom(model, id) {
    model.draft.custom = (model.draft.custom || []).filter(function(row) { return row.id !== id; });
    if (!model.draft.custom.length) delete model.draft.custom;
}
function discard(model) { model.draft = copy(model.saved); }
function request(model) {
    model.pending = copy(model.draft);
    return {action: "apply", version: model.version, preferences: copy(model.pending)};
}
function applied(model, result) {
    model.version = result.version;
    model.saved = copy(result.preferences || model.pending);
    model.state = resolve(model.state.actions, model.saved);
    model.pending = null;
    // Edits made while the request was running remain a dirty draft.
}
var exported = { create: create, ingest: ingest, view: view, resolve: resolve, merge: merge, dirty: dirty,
    action: action, keysFor: keysFor, conflicts: conflicts, setKeys: setKeys, reset: reset, resetAll: resetAll,
    addCustom: addCustom, updateCustom: updateCustom, removeCustom: removeCustom, discard: discard,
    request: request, applied: applied, checkedKeys: checkedKeys };
if (typeof module !== "undefined" && module.exports) module.exports = exported;
