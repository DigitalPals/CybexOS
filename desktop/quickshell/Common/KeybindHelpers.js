// Turns Hyprland's live binding list (`hyprctl binds -j`) into the groups the
// keyboard cheatsheet draws. Keep this file free of Qt APIs so the same logic
// stays testable under Node.
//
// A binding appears only when it carries a description. Descriptions use the
// convention "Group: Label", split at the first ": ". The vendor groups come
// first in GROUP_ORDER; groups introduced by ~/.config/cybexos/hypr/user.lua
// follow in the order Hyprland lists them, and a description with no group
// lands in "Other", last.

// Hyprland's modifier mask, drawn in the conventional reading order.
var MODIFIERS = [
    { bit: 64, name: "Super" },
    { bit: 4, name: "Ctrl" },
    { bit: 8, name: "Alt" },
    { bit: 1, name: "Shift" },
    { bit: 128, name: "AltGr" },
    { bit: 2, name: "Caps" },
    { bit: 16, name: "Mod2" },
    { bit: 32, name: "Mod3" }
];

var GROUP_ORDER = [
    "Shell", "Apps", "Web apps", "Development", "Windows", "Workspaces",
    "Clipboard", "Capture", "Dictation"
];

// Described in bindings.lua (so `hyprctl binds` still explains them) but left
// off the sheet: volume, brightness and media keys are labelled on the keys
// themselves, and listing them doubled the sheet's length for nothing.
var HIDDEN_GROUPS = ["Hardware keys"];

var OTHER_GROUP = "Other";

// Keysym names as Hyprland reports them, lowercased, to what a key cap says.
var KEY_NAMES = {
    "return": "Enter", "enter": "Enter", "kp_enter": "Enter",
    "space": "Space", "tab": "Tab", "escape": "Esc", "backspace": "Backspace",
    "delete": "Del", "insert": "Ins", "home": "Home", "end": "End",
    "page_up": "PgUp", "prior": "PgUp", "page_down": "PgDn", "next": "PgDn",
    "print": "Print", "pause": "Pause", "menu": "Menu",
    "left": "←", "right": "→", "up": "↑", "down": "↓",
    "comma": ",", "period": ".", "slash": "/", "backslash": "\\",
    "semicolon": ";", "apostrophe": "'", "grave": "`", "minus": "-",
    "equal": "=", "bracketleft": "[", "bracketright": "]",
    "mouse_down": "Scroll down", "mouse_up": "Scroll up",
    "mouse_left": "Scroll left", "mouse_right": "Scroll right",
    "mouse:272": "Left button", "mouse:273": "Right button",
    "mouse:274": "Middle button", "mouse:275": "Back button",
    "mouse:276": "Forward button",
    "xf86audioraisevolume": "Volume up", "xf86audiolowervolume": "Volume down",
    "xf86audiomute": "Mute", "xf86audiomicmute": "Mic mute",
    "xf86audioplay": "Play", "xf86audiopause": "Pause",
    "xf86audionext": "Next track", "xf86audioprev": "Previous track",
    "xf86audiostop": "Stop", "xf86monbrightnessup": "Brightness up",
    "xf86monbrightnessdown": "Brightness down", "xf86calculator": "Calculator",
    "xf86poweroff": "Power", "xf86sleep": "Sleep"
};

var ARROWS = ["←", "→", "↑", "↓"];
// The digit row in keyboard order: workspace 10 lives on the 0 key.
var DIGITS = "1234567890";

function modifierNames(modmask) {
    var mask = Number(modmask) || 0;
    var names = [];
    for (var i = 0; i < MODIFIERS.length; i++) {
        if (mask & MODIFIERS[i].bit)
            names.push(MODIFIERS[i].name);
    }
    return names;
}

function keyName(key, keycode) {
    var raw = String(key || "");
    if (raw === "" && Number(keycode) > 0)
        return "Key " + Number(keycode);
    var lower = raw.toLowerCase();
    if (Object.prototype.hasOwnProperty.call(KEY_NAMES, lower))
        return KEY_NAMES[lower];
    if (/^code:\d+$/.test(lower))
        return "Key " + lower.slice(5);
    if (/^mouse:\d+$/.test(lower))
        return "Button " + lower.slice(6);
    if (/^xf86/.test(lower))
        return raw.slice(4).replace(/([a-z])([A-Z])/g, "$1 $2");
    if (raw.length === 1)
        return raw.toUpperCase();
    // Named keys such as F9 or Caps_Lock: underscores read as spaces.
    return raw.charAt(0).toUpperCase() + raw.slice(1).replace(/_/g, " ");
}

function parseDescription(description) {
    var text = String(description || "").trim();
    var split = text.indexOf(": ");
    if (split > 0 && split < text.length - 2) {
        return {
            group: text.slice(0, split).trim(),
            label: text.slice(split + 2).trim()
        };
    }
    return { group: OTHER_GROUP, label: text };
}

// "Switch to workspace 3" and "Switch to workspace 4" differ only by their
// trailing number; rows like that collapse into one when their keys are
// digits under the same modifiers.
function numberedLabel(label) {
    var match = /^(.*\D)\s*(\d+)$/.exec(label);
    return match ? { stem: match[1].trim(), number: Number(match[2]) } : null;
}

function digitCap(keys) {
    var ordered = keys.slice().sort(function(a, b) {
        return DIGITS.indexOf(a) - DIGITS.indexOf(b);
    });
    var runs = [];
    for (var i = 0; i < ordered.length; i++) {
        var last = runs[runs.length - 1];
        if (last && DIGITS.indexOf(ordered[i]) === DIGITS.indexOf(last.end) + 1)
            last.end = ordered[i];
        else
            runs.push({ start: ordered[i], end: ordered[i] });
    }
    return runs.map(function(run) {
        return run.start === run.end ? run.start : run.start + "…" + run.end;
    }).join(" ");
}

// Alternative keys under the same modifiers: a digit run or the arrow keys
// share one cap; anything else stays a separate alternative.
function mergeCombos(combos) {
    var bySignature = {};
    var order = [];
    combos.forEach(function(combo) {
        var signature = combo.mods.join("+");
        if (!bySignature[signature]) {
            bySignature[signature] = [];
            order.push(signature);
        }
        if (bySignature[signature].indexOf(combo.key) < 0)
            bySignature[signature].push(combo.key);
    });
    var merged = [];
    order.forEach(function(signature) {
        var keys = bySignature[signature];
        var mods = signature === "" ? [] : signature.split("+");
        var allDigits = keys.length > 1 && keys.every(function(key) {
            return key.length === 1 && DIGITS.indexOf(key) >= 0;
        });
        var allArrows = keys.length > 1 && keys.every(function(key) {
            return ARROWS.indexOf(key) >= 0;
        });
        if (allDigits)
            merged.push(mods.concat([digitCap(keys)]));
        else if (allArrows)
            merged.push(mods.concat([ARROWS.filter(function(arrow) {
                return keys.indexOf(arrow) >= 0;
            }).join(" ")]));
        else
            keys.forEach(function(key) { merged.push(mods.concat([key])); });
    });
    return merged;
}

// 1, 2, 3, 5 reads as "1–3, 5".
function numberRuns(numbers) {
    var sorted = numbers.slice().sort(function(a, b) { return a - b; });
    var runs = [];
    sorted.forEach(function(number) {
        var last = runs[runs.length - 1];
        if (last && number === last.end + 1)
            last.end = number;
        else if (!last || number !== last.end)
            runs.push({ start: number, end: number });
    });
    return runs.map(function(run) {
        return run.start === run.end ? String(run.start) : run.start + "–" + run.end;
    }).join(", ");
}

function collapseNumbered(rows) {
    var out = [];
    var families = {};
    rows.forEach(function(row) {
        var numbered = numberedLabel(row.label);
        var digitKeys = row.combos.length > 0 && row.combos.every(function(combo) {
            return combo.key.length === 1 && DIGITS.indexOf(combo.key) >= 0;
        });
        if (!numbered || !digitKeys) {
            out.push(row);
            return;
        }
        var signature = numbered.stem + "\u0000" + row.combos.map(function(combo) {
            return combo.mods.join("+");
        }).join("|");
        var family = families[signature];
        if (!family) {
            family = { label: numbered.stem, numbers: [], combos: [], members: 0 };
            families[signature] = family;
            out.push(family);
        }
        family.members += 1;
        family.numbers.push(numbered.number);
        family.combos = family.combos.concat(row.combos);
        family.original = row;
    });
    return out.map(function(row) {
        if (row.members === undefined)
            return row;
        if (row.members === 1)
            return row.original;
        return { label: row.label + " " + numberRuns(row.numbers), combos: row.combos };
    });
}

function groupsFromBinds(binds) {
    if (!Array.isArray(binds))
        return [];
    var groups = {};
    var groupOrder = [];
    binds.forEach(function(bind) {
        if (!bind || typeof bind !== "object")
            return;
        var description = String(bind.description || "").trim();
        if (description === "")
            return;
        var parsed = parseDescription(description);
        if (HIDDEN_GROUPS.indexOf(parsed.group) >= 0)
            return;
        var label = parsed.label;
        if (bind.submap)
            label += " (" + bind.submap + " mode)";
        var group = groups[parsed.group];
        if (!group) {
            group = { title: parsed.group, rows: [], byLabel: {} };
            groups[parsed.group] = group;
            groupOrder.push(parsed.group);
        }
        var row = group.byLabel[label];
        if (!row) {
            row = { label: label, combos: [], seen: {} };
            group.byLabel[label] = row;
            group.rows.push(row);
        }
        var combo = { mods: modifierNames(bind.modmask), key: keyName(bind.key, bind.keycode) };
        var identity = combo.mods.join("+") + "+" + combo.key;
        if (row.seen[identity])
            return;
        row.seen[identity] = true;
        row.combos.push(combo);
    });

    var rank = function(title) {
        var vendor = GROUP_ORDER.indexOf(title);
        if (vendor >= 0)
            return vendor;
        if (title === OTHER_GROUP)
            return GROUP_ORDER.length + groupOrder.length;
        return GROUP_ORDER.length + groupOrder.indexOf(title);
    };
    return groupOrder.slice().sort(function(a, b) {
        return rank(a) - rank(b);
    }).map(function(title) {
        var rows = collapseNumbered(groups[title].rows.map(function(row) {
            return { label: row.label, combos: row.combos };
        }));
        return {
            title: title,
            rows: rows.map(function(row) {
                return { label: row.label, combos: mergeCombos(row.combos) };
            })
        };
    });
}

// Splits the groups, in order, into `count` columns of similar height: a
// group weighs its rows plus its title, and the contiguous split with the
// lightest heaviest column wins. Reading order stays top-to-bottom, then
// left-to-right, and no column is left empty while another has two groups.
function columnsFor(groups, count) {
    var list = Array.isArray(groups) ? groups : [];
    var columns = Math.max(1, Math.min(Math.floor(Number(count) || 1), list.length || 1));
    var weights = list.map(function(group) {
        return (group && Array.isArray(group.rows) ? group.rows.length : 0) + 1.5;
    });
    var prefix = [0];
    weights.forEach(function(weight) { prefix.push(prefix[prefix.length - 1] + weight); });
    var sum = function(from, to) { return prefix[to] - prefix[from]; };
    // best[k][i]: the lightest heaviest column for the first i groups in k
    // columns; cut[k][i] is where its last column starts.
    var best = [];
    var cut = [];
    for (var k = 0; k <= columns; k++) {
        best.push([]);
        cut.push([]);
        for (var i = 0; i <= list.length; i++) {
            best[k].push(Infinity);
            cut[k].push(0);
        }
    }
    best[0][0] = 0;
    for (k = 1; k <= columns; k++) {
        for (i = k; i <= list.length; i++) {
            for (var j = k - 1; j < i; j++) {
                var cost = Math.max(best[k - 1][j], sum(j, i));
                if (cost < best[k][i]) {
                    best[k][i] = cost;
                    cut[k][i] = j;
                }
            }
        }
    }
    var out = [];
    var end = list.length;
    for (k = columns; k >= 1; k--) {
        var start = list.length === 0 ? 0 : cut[k][end];
        out.unshift(list.slice(start, end));
        end = start;
    }
    return out;
}

// The complete step from hyprctl's stdout to what the overlay draws.
function fromJson(text) {
    var binds;
    try {
        binds = JSON.parse(String(text || ""));
    } catch (error) {
        return { groups: [], error: "Hyprland returned a binding list that could not be read." };
    }
    if (!Array.isArray(binds))
        return { groups: [], error: "Hyprland returned a binding list that could not be read." };
    return { groups: groupsFromBinds(binds), error: "" };
}

var exported = {
    GROUP_ORDER: GROUP_ORDER,
    HIDDEN_GROUPS: HIDDEN_GROUPS,
    OTHER_GROUP: OTHER_GROUP,
    columnsFor: columnsFor,
    modifierNames: modifierNames,
    keyName: keyName,
    parseDescription: parseDescription,
    groupsFromBinds: groupsFromBinds,
    fromJson: fromJson
};

if (typeof module !== "undefined" && module.exports)
    module.exports = exported;
