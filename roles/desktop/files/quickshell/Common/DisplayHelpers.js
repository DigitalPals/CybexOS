// Pure logic behind Settings -> Displays: mode lists, the scales Hyprland
// accepts, per-monitor identities, the saved document and the arrangement.
// No Qt APIs, so display-helpers.test.cjs runs it under Node.
//
// Geometry is in Hyprland layout coordinates (logical pixels): a monitor
// occupies its mode divided by its scale, with width and height swapped for
// a 90 or 270 degree transform.

var SCALE_PRESETS = [1, 1.25, 4 / 3, 1.5, 1.6, 5 / 3, 1.75, 2, 2.25, 2.4, 2.5, 3];
var TRANSFORMS = [
    { value: 0, label: "Normal" },
    { value: 1, label: "90°" },
    { value: 2, label: "180°" },
    { value: 3, label: "270°" }
];
var VRR_CHOICES = [
    { value: -1, label: "Default" },
    { value: 0, label: "Off" },
    { value: 1, label: "On" },
    { value: 2, label: "Fullscreen" }
];
var TRIAL_SECONDS = 15;
var SNAP_DISTANCE = 48;
// Neighbours share a real stretch of edge, not a corner, so the pointer can
// cross between them.
var MIN_SHARED_EDGE = 64;

function parseMode(text) {
    var match = /^(\d+)x(\d+)@([0-9]+(?:\.[0-9]+)?)Hz$/.exec(String(text || "").trim());
    if (!match)
        return null;
    var mode = { width: Number(match[1]), height: Number(match[2]), refresh: Number(match[3]) };
    if (mode.width < 1 || mode.height < 1 || !(mode.refresh > 0))
        return null;
    return mode;
}

function roundRefresh(value) {
    return Math.round(Number(value) * 1000) / 1000;
}

function refreshLabel(value) {
    var rounded = Math.round(Number(value) * 100) / 100;
    var text = rounded.toFixed(2).replace(/0+$/, "").replace(/\.$/, "");
    return text + " Hz";
}

function sizeLabel(width, height) {
    return width + " × " + height;
}

function sameRefresh(a, b) {
    return Math.abs(Number(a) - Number(b)) < 0.005;
}

// Resolutions, largest first, each with its refresh rates, fastest first.
// Hyprland lists duplicate modes (different timings at one rate); one row
// per rate is enough because the compositor picks the closest timing.
function modeGroups(availableModes) {
    var groups = [];
    var byResolution = {};
    var list = Array.isArray(availableModes) ? availableModes : [];
    for (var i = 0; i < list.length; i++) {
        var mode = parseMode(list[i]);
        if (!mode)
            continue;
        var id = mode.width + "x" + mode.height;
        var group = byResolution[id];
        if (!group) {
            group = { id: id, width: mode.width, height: mode.height,
                label: sizeLabel(mode.width, mode.height), refreshes: [] };
            byResolution[id] = group;
            groups.push(group);
        }
        var refresh = Math.round(mode.refresh * 100) / 100;
        if (!group.refreshes.some(function(r) { return sameRefresh(r, refresh); }))
            group.refreshes.push(refresh);
    }
    groups.sort(function(a, b) {
        return b.width * b.height - a.width * a.height || b.width - a.width;
    });
    for (var j = 0; j < groups.length; j++)
        groups[j].refreshes.sort(function(a, b) { return b - a; });
    return groups;
}

// Hyprland keeps a scale only when the mode divides into whole logical
// pixels, searching in steps of 1/120 otherwise (CMonitor::applyMonitorRule).
function scaleValid(width, height, scale) {
    var steps = Math.round(Number(scale) * 120);
    if (!(steps >= 30) || Math.abs(steps / 120 - Number(scale)) > 0.0005)
        return false;
    return (width * 120) % steps === 0 && (height * 120) % steps === 0;
}

function scaleLabel(scale) {
    return scale === "auto" ? "Auto" : Math.round(Number(scale) * 100) + "%";
}

function scaleChoices(width, height, current) {
    var choices = [{ value: "auto", label: "Auto" }];
    var values = SCALE_PRESETS.slice();
    if (typeof current === "number" && values.every(function(v) { return Math.abs(v - current) > 0.001; }))
        values.push(current);
    values.sort(function(a, b) { return a - b; });
    for (var i = 0; i < values.length; i++) {
        var value = Math.round(values[i] * 120) / 120;
        if (scaleValid(width, height, value))
            choices.push({ value: value, label: scaleLabel(value) });
    }
    return choices;
}

// Saved choices follow the physical monitor: `desc:` plus Hyprland's
// description (make, model, serial). Two identical panels without serials
// share a description, and a `desc:` selector matches by prefix, so the
// connector name is used whenever the description could match another one.
function monitorKey(monitor, monitors) {
    var description = String(monitor.description || "").trim();
    if (description !== "" && !/[\u0000-\u001f\u007f]/.test(description)
            && description.length <= 256) {
        var clash = (monitors || []).some(function(other) {
            return other !== monitor && other.name !== monitor.name
                && String(other.description || "").trim().indexOf(description) === 0;
        });
        if (!clash)
            return "desc:" + description;
    }
    return String(monitor.name);
}

function keyMatches(key, monitor) {
    if (key.indexOf("desc:") === 0) {
        var prefix = key.slice(5).trim();
        return prefix !== "" && String(monitor.description || "").indexOf(prefix) === 0;
    }
    return key === monitor.name;
}

function displayName(monitor) {
    var parts = [String(monitor.make || "").trim(), String(monitor.model || "").trim()]
        .filter(function(part) { return part !== "" && !/^0x[0-9a-f]+$/i.test(part); });
    var label = parts.join(" ");
    if (monitor.name === "eDP-1" || /^eDP/.test(monitor.name || ""))
        label = label === "" ? "Built-in display" : "Built-in · " + label;
    return label === "" ? String(monitor.name) : label;
}

function connectorEntry(monitors, monitor) {
    if (!Object.prototype.hasOwnProperty.call(monitors, monitor.name))
        return null;
    var entry = monitors[monitor.name];
    // Early saved files used connector names without recording a description.
    // They still target this output; a recorded different description does not.
    return entry && (!entry.description || entry.description === (monitor.description || ""))
        ? entry : null;
}

function storedEntry(document, monitor, key) {
    var monitors = document && document.monitors && typeof document.monitors === "object"
        ? document.monitors : {};
    if (Object.prototype.hasOwnProperty.call(monitors, key))
        return monitors[key];
    return connectorEntry(monitors, monitor);
}

function currentMode(monitor) {
    var groups = modeGroups(monitor.availableModes);
    for (var i = 0; i < groups.length; i++) {
        if (groups[i].width !== monitor.width || groups[i].height !== monitor.height)
            continue;
        var best = null;
        for (var j = 0; j < groups[i].refreshes.length; j++) {
            var rate = groups[i].refreshes[j];
            if (best === null || Math.abs(rate - monitor.refreshRate) < Math.abs(best - monitor.refreshRate))
                best = rate;
        }
        if (best !== null && Math.abs(best - monitor.refreshRate) < 0.6)
            return { width: groups[i].width, height: groups[i].height, refresh: best };
    }
    return { width: Number(monitor.width), height: Number(monitor.height),
        refresh: Math.round(Number(monitor.refreshRate) * 100) / 100 };
}

// One editable draft per connected monitor. The live state is the truth for
// what is on screen; the saved entry only says which values are automatic.
function draftsFromSnapshot(monitors, document) {
    var list = Array.isArray(monitors) ? monitors : [];
    var drafts = [];
    for (var i = 0; i < list.length; i++) {
        var monitor = list[i];
        var key = monitorKey(monitor, list);
        var entry = storedEntry(document, monitor, key) || {};
        var mirror = "";
        if (monitor.mirrorOf && monitor.mirrorOf !== "none") {
            var source = list.filter(function(other) {
                return other.name === monitor.mirrorOf || String(other.id) === String(monitor.mirrorOf);
            })[0];
            if (source)
                mirror = monitorKey(source, list);
        }
        drafts.push({
            key: key,
            name: String(monitor.name),
            label: displayName(monitor),
            description: String(monitor.description || ""),
            enabled: monitor.disabled !== true,
            mode: entry.mode === "preferred" ? "preferred" : currentMode(monitor),
            scale: entry.scale === "auto" ? "auto" : Math.round(Number(monitor.scale) * 120) / 120,
            transform: Number(monitor.transform) >= 0 ? Number(monitor.transform) : 0,
            mirror: mirror,
            vrr: typeof entry.vrr === "number" ? entry.vrr : -1,
            x: Math.round(Number(monitor.x) || 0),
            y: Math.round(Number(monitor.y) || 0),
            // Live values for automatic choices and the preview.
            liveWidth: Number(monitor.width) || 1,
            liveHeight: Number(monitor.height) || 1,
            liveScale: Number(monitor.scale) || 1,
            availableModes: Array.isArray(monitor.availableModes) ? monitor.availableModes.slice() : []
        });
    }
    return drafts;
}

function clone(value) {
    return JSON.parse(JSON.stringify(value));
}

function modeSize(draft) {
    if (draft.mode === "preferred" || !draft.mode)
        return { width: draft.liveWidth, height: draft.liveHeight };
    return { width: draft.mode.width, height: draft.mode.height };
}

function logicalSize(draft) {
    var size = modeSize(draft);
    var scale = draft.scale === "auto" ? draft.liveScale : Number(draft.scale);
    if (!(scale > 0))
        scale = 1;
    var width = Math.round(size.width / scale);
    var height = Math.round(size.height / scale);
    if (Number(draft.transform) % 2 === 1)
        return { width: height, height: width };
    return { width: width, height: height };
}

// The outputs that occupy space in the layout: on and not mirroring another.
function placed(drafts) {
    return drafts.filter(function(draft) { return draft.enabled && draft.mirror === ""; });
}

function rects(drafts) {
    return placed(drafts).map(function(draft) {
        var size = logicalSize(draft);
        return { key: draft.key, x: draft.x, y: draft.y, width: size.width, height: size.height };
    });
}

function overlaps(a, b) {
    return a.x < b.x + b.width && b.x < a.x + a.width
        && a.y < b.y + b.height && b.y < a.y + a.height;
}

function touches(a, b) {
    var horizontal = (a.x + a.width === b.x || b.x + b.width === a.x)
        && a.y < b.y + b.height && b.y < a.y + a.height;
    var vertical = (a.y + a.height === b.y || b.y + b.height === a.y)
        && a.x < b.x + b.width && b.x < a.x + a.width;
    return horizontal || vertical;
}

function clamp(value, low, high) {
    return Math.max(low, Math.min(high, value));
}

// Snap the free coordinate to a shared edge when it is close, so rows and
// columns line up without pixel hunting.
function align(value, size, start, extent) {
    if (Math.abs(value - start) <= SNAP_DISTANCE)
        return start;
    if (Math.abs(value + size - (start + extent)) <= SNAP_DISTANCE)
        return start + extent - size;
    return value;
}

// The nearest position for `rect` that shares an edge with one of `others`
// and overlaps none of them. `prefer` ("left", "right", "up", "down") keeps a
// display on the side of its neighbours it was on, when that side has room.
// With nothing else placed it stays put.
function placeRect(rect, others, prefer) {
    if (!others.length)
        return { x: rect.x, y: rect.y };
    var candidates = [];
    for (var i = 0; i < others.length; i++) {
        var o = others[i];
        var shareY = Math.min(MIN_SHARED_EDGE, rect.height, o.height);
        var shareX = Math.min(MIN_SHARED_EDGE, rect.width, o.width);
        var y = align(clamp(rect.y, o.y - rect.height + shareY, o.y + o.height - shareY), rect.height, o.y, o.height);
        var x = align(clamp(rect.x, o.x - rect.width + shareX, o.x + o.width - shareX), rect.width, o.x, o.width);
        candidates.push({ side: "right", x: o.x + o.width, y: y });
        candidates.push({ side: "left", x: o.x - rect.width, y: y });
        candidates.push({ side: "down", x: x, y: o.y + o.height });
        candidates.push({ side: "up", x: x, y: o.y - rect.height });
    }
    var usable = candidates.filter(function(candidate) {
        var box = { x: candidate.x, y: candidate.y, width: rect.width, height: rect.height };
        return !others.some(function(o) { return overlaps(box, o); })
            && others.some(function(o) { return touches(box, o); });
    });
    if (prefer) {
        var preferred = usable.filter(function(candidate) { return candidate.side === prefer; });
        if (preferred.length)
            usable = preferred;
    }
    var best = null;
    var bestDistance = Infinity;
    for (var c = 0; c < usable.length; c++) {
        var dx = usable[c].x - rect.x;
        var dy = usable[c].y - rect.y;
        var distance = dx * dx + dy * dy;
        if (distance < bestDistance) {
            best = usable[c];
            bestDistance = distance;
        }
    }
    if (best)
        return { x: best.x, y: best.y };
    var right = Math.max.apply(null, others.map(function(o) { return o.x + o.width; }));
    return { x: right, y: others[0].y };
}

// Which side of `anchor` a display is on, judged by centres relative to the
// two displays' combined half-sizes.
function sideOf(rect, anchor) {
    var dx = (rect.x + rect.width / 2) - (anchor.x + anchor.width / 2);
    var dy = (rect.y + rect.height / 2) - (anchor.y + anchor.height / 2);
    var nx = dx / Math.max(1, (rect.width + anchor.width) / 2);
    var ny = dy / Math.max(1, (rect.height + anchor.height) / 2);
    if (Math.abs(nx) >= Math.abs(ny))
        return dx >= 0 ? "right" : "left";
    return dy >= 0 ? "down" : "up";
}

// Shift the layout so its top-left corner is 0x0.
function normalize(drafts) {
    var list = rects(drafts);
    if (!list.length)
        return drafts;
    var minX = Math.min.apply(null, list.map(function(r) { return r.x; }));
    var minY = Math.min.apply(null, list.map(function(r) { return r.y; }));
    return drafts.map(function(draft) {
        var next = clone(draft);
        if (draft.enabled && draft.mirror === "") {
            next.x = draft.x - minX;
            next.y = draft.y - minY;
        }
        return next;
    });
}

// Drop one display at (x, y); the others stay where they are.
function moveDisplay(drafts, key, x, y, prefer) {
    var next = clone(drafts);
    var moving = next.filter(function(draft) { return draft.key === key; })[0];
    if (!moving || !moving.enabled || moving.mirror !== "")
        return next;
    var size = logicalSize(moving);
    var others = rects(next).filter(function(rect) { return rect.key !== key; });
    var position = placeRect({ x: Math.round(x), y: Math.round(y), width: size.width, height: size.height },
        others, prefer);
    moving.x = position.x;
    moving.y = position.y;
    return normalize(next);
}

// After `key` changes size (mode, scale, rotation) or joins the layout, keep
// it where it is and re-attach every other display, nearest first, so none
// overlaps it or floats free. `previous` is the layout before the change; a
// display keeps the side of the changed one it was on there.
function relayout(drafts, key, previous) {
    var next = clone(drafts);
    var all = rects(next);
    var anchor = all.filter(function(rect) { return rect.key === key; })[0] || all[0];
    if (!anchor)
        return next;
    var before = previous ? rects(previous) : [];
    var oldAnchor = before.filter(function(rect) { return rect.key === anchor.key; })[0];
    var done = [anchor];
    var rest = all.filter(function(rect) { return rect !== anchor; });
    rest.sort(function(a, b) {
        var da = Math.pow(a.x - anchor.x, 2) + Math.pow(a.y - anchor.y, 2);
        var db = Math.pow(b.x - anchor.x, 2) + Math.pow(b.y - anchor.y, 2);
        return da - db || (a.key < b.key ? -1 : 1);
    });
    for (var i = 0; i < rest.length; i++) {
        var rect = rest[i];
        var fits = !done.some(function(o) { return overlaps(rect, o); })
            && done.some(function(o) { return touches(rect, o); });
        if (!fits) {
            var oldRect = before.filter(function(r) { return r.key === rect.key; })[0];
            var prefer = oldAnchor && oldRect ? sideOf(oldRect, oldAnchor) : null;
            var position = placeRect(rect, done, prefer);
            rect.x = position.x;
            rect.y = position.y;
        }
        done.push(rect);
    }
    for (var d = 0; d < next.length; d++) {
        var moved = done.filter(function(rect) { return rect.key === next[d].key; })[0];
        if (moved) {
            next[d].x = moved.x;
            next[d].y = moved.y;
        }
    }
    return normalize(next);
}

// Arrow keys place the selected display beside the rest of the layout:
// top-aligned with the outermost display to the left or right, centred on it
// above or below.
function nudge(drafts, key, direction) {
    var all = rects(drafts);
    var others = all.filter(function(rect) { return rect.key !== key; });
    var self = all.filter(function(rect) { return rect.key === key; })[0];
    if (!self || !others.length)
        return clone(drafts);
    var edge = others[0];
    for (var i = 1; i < others.length; i++) {
        var o = others[i];
        if ((direction === "left" && o.x < edge.x)
                || (direction === "right" && o.x + o.width > edge.x + edge.width)
                || (direction === "up" && o.y < edge.y)
                || (direction === "down" && o.y + o.height > edge.y + edge.height))
            edge = o;
    }
    var x = self.x;
    var y = self.y;
    if (direction === "left" || direction === "right") {
        x = direction === "left" ? edge.x - self.width : edge.x + edge.width;
        y = edge.y;
    } else if (direction === "up" || direction === "down") {
        y = direction === "up" ? edge.y - self.height : edge.y + edge.height;
        x = Math.round(edge.x + (edge.width - self.width) / 2);
    }
    return moveDisplay(drafts, key, x, y, direction);
}

function enabledCount(drafts) {
    return drafts.filter(function(draft) { return draft.enabled; }).length;
}

function canDisable(drafts, key) {
    return drafts.some(function(draft) { return draft.key !== key && draft.enabled; });
}

// Returns "" or the reason the drafts cannot be applied.
function validate(drafts) {
    if (!drafts.length)
        return "No displays are connected.";
    if (enabledCount(drafts) === 0)
        return "At least one display must stay on.";
    for (var i = 0; i < drafts.length; i++) {
        var draft = drafts[i];
        if (!draft.enabled || draft.mirror === "")
            continue;
        var source = drafts.filter(function(other) { return other.key === draft.mirror; })[0];
        if (!source)
            return draft.label + " mirrors a display that is not connected.";
        if (source.key === draft.key)
            return draft.label + " cannot mirror itself.";
        if (!source.enabled)
            return draft.label + " mirrors a display that is off.";
        if (source.mirror !== "")
            return draft.label + " cannot mirror a display that is itself a mirror.";
    }
    if (placed(drafts).length === 0)
        return "At least one display must show its own picture.";
    var list = rects(drafts);
    for (var a = 0; a < list.length; a++)
        for (var b = a + 1; b < list.length; b++)
            if (overlaps(list[a], list[b]))
                return "Two displays overlap in the arrangement.";
    return "";
}

// The saved document: the previous file with this set of monitors' entries
// replaced. Entries for other monitors and unknown fields are kept.
function buildDocument(previous, drafts) {
    var document = previous && typeof previous === "object" && !Array.isArray(previous)
        ? clone(previous) : {};
    document.v = 1;
    var monitors = document.monitors && typeof document.monitors === "object"
        && !Array.isArray(document.monitors) ? document.monitors : {};
    var enabledKeys = drafts.filter(function(draft) { return draft.enabled; })
        .map(function(draft) { return draft.key; });
    for (var i = 0; i < drafts.length; i++) {
        var draft = drafts[i];
        // Move legacy connector entries to the physical identity, including
        // entries with no description. Keeping both lets the stale connector
        // rule override this edit when displays.lua emits sorted rules.
        var legacy = connectorEntry(monitors, draft);
        var entry = Object.assign({}, legacy || {}, monitors[draft.key] || {});
        if (draft.key !== draft.name && legacy)
            delete monitors[draft.name];
        entry.description = draft.description;
        entry.connector = draft.name;
        entry.enabled = draft.enabled;
        if (draft.enabled)
            delete entry.disabledWith;
        else
            entry.disabledWith = enabledKeys.slice(0, 16);
        entry.mode = draft.mode === "preferred" ? "preferred"
            : { width: draft.mode.width, height: draft.mode.height, refresh: roundRefresh(draft.mode.refresh) };
        entry.position = { x: Math.round(draft.x), y: Math.round(draft.y) };
        entry.scale = draft.scale === "auto" ? "auto" : Math.round(Number(draft.scale) * 1e6) / 1e6;
        entry.transform = Number(draft.transform);
        if (draft.vrr === -1 || draft.vrr === undefined || draft.vrr === null)
            delete entry.vrr;
        else
            entry.vrr = Number(draft.vrr);
        if (draft.mirror === "")
            delete entry.mirror;
        else
            entry.mirror = draft.mirror;
        if (entry.description === "")
            delete entry.description;
        monitors[draft.key] = entry;
    }
    document.monitors = monitors;
    return document;
}

// Compare only what the page edits, so a live refresh that changes nothing
// the user touched does not count as an edit.
function draftSignature(drafts) {
    return JSON.stringify(drafts.map(function(draft) {
        return [draft.key, draft.enabled, draft.mode, draft.scale, draft.transform,
            draft.mirror, draft.vrr, draft.x, draft.y];
    }));
}

function secondsLeft(expires, nowMs) {
    return Math.max(0, Math.ceil(Number(expires) - Number(nowMs) / 1000));
}

if (typeof module !== "undefined" && module.exports) {
    module.exports = {
        SCALE_PRESETS: SCALE_PRESETS, TRANSFORMS: TRANSFORMS, VRR_CHOICES: VRR_CHOICES,
        TRIAL_SECONDS: TRIAL_SECONDS, parseMode: parseMode, refreshLabel: refreshLabel,
        sizeLabel: sizeLabel,
        modeGroups: modeGroups, scaleValid: scaleValid, scaleLabel: scaleLabel,
        scaleChoices: scaleChoices, monitorKey: monitorKey, keyMatches: keyMatches,
        displayName: displayName, draftsFromSnapshot: draftsFromSnapshot,
        logicalSize: logicalSize, rects: rects, overlaps: overlaps, touches: touches,
        placeRect: placeRect, sideOf: sideOf, normalize: normalize, moveDisplay: moveDisplay,
        relayout: relayout, nudge: nudge, canDisable: canDisable, validate: validate,
        buildDocument: buildDocument, draftSignature: draftSignature, secondsLeft: secondsLeft
    };
}
