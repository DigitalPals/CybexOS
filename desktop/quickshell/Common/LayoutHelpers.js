// Pure geometry/input helpers shared by QML and Node tests.

// Which module gives up its detail text first when the bar runs out of room.
// Notification/update counts and other expendable labels give way before
// weather conditions, while the clock's own date remains a late resort.
var COMPACT_ORDER = ["media", "updates", "notifications", "t3", "hermes", "gh",
    "weather", "clock", "vol", "batt"];
var OVERFLOW_ORDER = ["media", "updates", "gh", "t3", "hermes", "modelusage",
    "weather", "tray", "bt", "notifications", "indicators"];

// Consecutive modules that draw the same way share one layout group: the
// T3/Hermes/GitHub chips retain their ordering and separator contract. "solo"
// modules bring their own pill and never merge, so two of them in a row stay
// two independent pointer targets.
//
// Grouping is by adjacency, not by kind: moving a module between others in
// the settings window splits or joins the pill exactly where it was dropped,
// which is the only behaviour that matches what the drag preview showed.
function groupModules(entries, groupOf) {
    var out = [];
    (entries || []).forEach(function(entry, index) {
        var kind = typeof groupOf === "function" ? groupOf(entry.id) : "solo";
        var last = out.length > 0 ? out[out.length - 1] : null;
        if (last && last.kind === kind && kind !== "solo") {
            last.items.push({ entry: entry, index: index, at: last.items.length });
            return;
        }
        out.push({
            kind: kind,
            key: kind + ":" + index,
            items: [{ entry: entry, index: index, at: 0 }]
        });
    });
    return out;
}

function clamp(value, min, max) {
    return Math.max(min, Math.min(max, value));
}

// Moving one widget is a splice out and a splice in, and the index the drop
// reported was measured against the list as it stood *before* the removal.
// Within one column a removal above the insertion point shifts it down by
// one; across columns nothing shifts. Both the settings list and the bar
// commit through here, so the two cannot come to disagree about where a drop
// landed — which they would, being measured in completely different units.
//
// Returns the rewritten columns together with the index the widget actually
// came to rest at, since that is what an announcement has to name and it is
// not always the index that was asked for.
function moveWidget(mods, fromCol, id, toCol, index) {
    var columns = ["left", "center", "right"];
    if (columns.indexOf(fromCol) === -1 || columns.indexOf(toCol) === -1)
        return null;

    var next = {};
    columns.forEach(function(col) {
        next[col] = (((mods || {})[col]) || []).map(function(entry) {
            return { id: entry.id, on: entry.on, detail: entry.detail };
        });
    });

    var from = -1;
    for (var i = 0; i < next[fromCol].length; i++) {
        if (next[fromCol][i].id === id) {
            from = i;
            break;
        }
    }
    if (from < 0)
        return null;

    var entry = next[fromCol][from];
    var to = clamp(index, 0, next[toCol].length);
    next[fromCol].splice(from, 1);
    if (toCol === fromCol && from < to)
        to--;
    next[toCol].splice(to, 0, entry);
    return { mods: next, col: toCol, idx: to };
}

// Which section of the bar a pointer at `x` is aiming at. The boundary sits
// midway across the empty run between two clusters rather than at a cluster's
// own edge, so a drop into that gap goes to the nearer side instead of always
// falling to whichever cluster happens to be drawn wider.
function barDropColumn(x, bounds) {
    bounds = bounds || {};
    var leftEnd = Number(bounds.leftEnd) || 0;
    var centerStart = Number(bounds.centerStart) || 0;
    var centerEnd = Number(bounds.centerEnd) || 0;
    var rightStart = Number(bounds.rightStart) || 0;
    if (x < (leftEnd + centerStart) / 2)
        return "left";
    if (x < (centerEnd + rightStart) / 2)
        return "center";
    return "right";
}

// Where a drop at `x` lands in a column's *configured* list, which is longer
// than what the bar draws: a widget switched off, or ruled out by its own
// auto-rule (no player, no battery, no pending updates), holds an index but
// occupies no pixels. Only drawn widgets have a center to compare against, so
// the insertion point is the configured index of the first drawn widget past
// the pointer — which leaves any undrawn widgets ahead of it exactly where
// the user left them, rather than quietly resequencing things off screen.
function barDropIndex(entries, centers, x) {
    var list = entries || [];
    for (var i = 0; i < list.length; i++) {
        var center = centers ? centers[list[i].id] : undefined;
        if (typeof center !== "number")
            continue;
        if (x < center)
            return i;
    }
    return list.length;
}

function stackedDropIndex(columns, y) {
    if (!Array.isArray(columns) || columns.length === 0)
        return null;
    var column = columns[columns.length - 1];
    for (var i = 0; i < columns.length; i++) {
        var candidate = columns[i];
        if (y < candidate.y + candidate.height) {
            column = candidate;
            break;
        }
    }
    var local = y - column.y - column.rowsStart;
    var index = clamp(Math.floor((local + column.pitch / 2) / column.pitch), 0, column.length);
    return { col: column.id, idx: index };
}

function fitBar(options) {
    options = options || {};
    var available = Math.max(0, (options.width || 0) - 2 * (options.sideMargin || 0));
    var gutter = options.gutter === undefined ? 8 : options.gutter;
    var widths = {
        left: Math.max(0, options.widths && options.widths.left || 0),
        center: Math.max(0, options.widths && options.widths.center || 0),
        right: Math.max(0, options.widths && options.widths.right || 0)
    };
    var asymmetricCenter = !!options.centerExtents;
    var center = asymmetricCenter ? {
        left: Math.max(0, Number(options.centerExtents.left) || 0),
        right: Math.max(0, Number(options.centerExtents.right) || 0)
    } : {
        left: widths.center / 2,
        right: widths.center / 2
    };
    widths.center = center.left + center.right;
    var entries = Array.isArray(options.entries) ? options.entries : [];
    var compact = [];
    var overflow = [];

    function apply(entry) {
        if (!entry || compact.indexOf(entry.id) !== -1)
            return;
        compact.push(entry.id);
        if (entry.col in widths) {
            widths[entry.col] = Math.max(0, widths[entry.col] - Math.max(0, entry.saving || 0));
            if (entry.col === "center") {
                var amount = Math.max(0, entry.saving || 0);
                if (asymmetricCenter) {
                    var side = entry.centerSide === "left" ? "left" : "right";
                    center[side] = Math.max(0, center[side] - amount);
                } else {
                    center.left = Math.max(0, center.left - amount / 2);
                    center.right = Math.max(0, center.right - amount / 2);
                }
            }
        }
    }

    function geometry() {
        // Pin the semantic center (the clock slot), not the midpoint of a
        // center cluster whose left and right contents can have different
        // widths. Revealing quick actions then grows outward from the clock.
        var desired = available / 2 - center.left;
        var rightX = available - widths.right;
        return {
            desired: desired,
            rightX: rightX,
            fits: widths.left + gutter <= desired
                && desired + center.left + center.right + gutter <= rightX
        };
    }

    entries.filter(function(entry) { return entry.policy === "compact"; }).forEach(apply);
    var ordered = [];
    ["auto", "prefer"].forEach(function(policy) {
        COMPACT_ORDER.forEach(function(id) {
            var entry = entries.find(function(item) {
                return item.id === id && item.policy === policy
                    && Math.max(0, item.saving || 0) > 0;
            });
            if (entry)
                ordered.push(entry);
        });
    });

    var state = geometry();
    for (var i = 0; !state.fits && i < ordered.length; i++) {
        apply(ordered[i]);
        state = geometry();
    }

    var centerX = state.desired;
    var shifted = false;
    if (!state.fits) {
        var minX = widths.left + gutter;
        var maxX = state.rightX - gutter - center.left - center.right;
        if (maxX >= minX) {
            centerX = clamp(state.desired, minX, maxX);
            shifted = Math.abs(centerX - state.desired) > 0.01;
            state.fits = true;
        }
    }

    // The semantic centre could not be fitted even after every eligible label
    // was compacted and the cluster shifted. Reserve the More button, then
    // remove low-priority modules until the three lanes no longer collide.
    if (!state.fits) {
        widths.right += Math.max(0, Number(options.overflowWidth) || 0);
        state = geometry();
        centerX = state.desired;
        shifted = false;
        for (var j = 0; !state.fits && j < OVERFLOW_ORDER.length; j++) {
            var hidden = entries.find(function(item) {
                return item.id === OVERFLOW_ORDER[j];
            });
            if (!hidden || !(hidden.col in widths))
                continue;
            overflow.push(hidden.id);
            var fullWidth = Math.max(0, Number(hidden.width) || 0);
            var hiddenWidth = Math.max(0, fullWidth
                - (compact.indexOf(hidden.id) !== -1
                    ? Math.max(0, hidden.saving || 0) : 0));
            widths[hidden.col] = Math.max(0, widths[hidden.col] - hiddenWidth);
            if (hidden.col === "center") {
                var hiddenSide = hidden.centerSide === "left" ? "left" : "right";
                center[hiddenSide] = Math.max(0, center[hiddenSide] - hiddenWidth);
            }
            state = geometry();
            centerX = state.desired;
            shifted = false;
            if (!state.fits) {
                var overflowMinX = widths.left + gutter;
                var overflowMaxX = state.rightX - gutter - center.left - center.right;
                if (overflowMaxX >= overflowMinX) {
                    centerX = clamp(state.desired, overflowMinX, overflowMaxX);
                    shifted = Math.abs(centerX - state.desired) > 0.01;
                    state.fits = true;
                }
            }
        }
    }

    return {
        compact: compact,
        overflow: overflow,
        widths: widths,
        centerExtents: center,
        centerX: centerX,
        centerOffset: centerX - state.desired,
        shifted: shifted,
        fits: state.fits
    };
}

function accumulateWheel(accumulator, delta, threshold) {
    var limit = Math.max(1, threshold || 120);
    var total = (Number(accumulator) || 0) + (Number(delta) || 0);
    var steps = total < 0 ? Math.ceil(total / limit) : Math.floor(total / limit);
    return { accumulator: total - steps * limit, steps: steps };
}

// Shorten only the flare that would cross a rounded outer bar tangent. A
// roomy edge popout and the side opposite its island retain the full radius.
function edgeFlareRadii(options) {
    options = options || {};
    var island = options.island;
    var barRadius = Math.max(0, Number(options.barRadius) || 0);
    var popRadius = Math.max(0, Number(options.popRadius) || 0);
    var radii = { left: popRadius, right: popRadius };
    if (!options.floating || barRadius <= 0 || popRadius <= 0)
        return radii;

    var sideMargin = Number(options.sideMargin) || 0;
    var bodyX = Number(options.bodyX) || 0;
    var bodyW = Math.max(0, Number(options.bodyW) || 0);
    if (island === "left") {
        var leftRoom = bodyX - (sideMargin + barRadius);
        radii.left = Math.max(1, Math.min(popRadius, leftRoom));
    } else if (island === "right") {
        var rightTangent = (Number(options.width) || 0) - sideMargin - barRadius;
        var rightRoom = rightTangent - (bodyX + bodyW);
        radii.right = Math.max(1, Math.min(popRadius, rightRoom));
    }
    return radii;
}

var exported = {
    COMPACT_ORDER: COMPACT_ORDER,
    OVERFLOW_ORDER: OVERFLOW_ORDER,
    clamp: clamp,
    groupModules: groupModules,
    moveWidget: moveWidget,
    barDropColumn: barDropColumn,
    barDropIndex: barDropIndex,
    stackedDropIndex: stackedDropIndex,
    fitBar: fitBar,
    accumulateWheel: accumulateWheel,
    edgeFlareRadii: edgeFlareRadii
};

if (typeof module !== "undefined" && module.exports)
    module.exports = exported;
