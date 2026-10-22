// The Power page's idle timeline as data: where Screen off, Lock and Suspend
// sit along the axis, how their labels stack when they crowd each other, and
// what their order means in words. Pure — no Qt APIs — so the same code runs
// under Node in tests; IdleTimeline.qml only measures and draws.

// In marker order: at one delay the labels read top to bottom in the order
// the events happen, screen before lock before suspend.
var EVENTS = [
    { key: "idleScreenOffMins", label: "Screen off", icon: "monitor" },
    { key: "idleLockMins", label: "Lock", icon: "lock" },
    { key: "idleSuspendMins", label: "Suspend", icon: "bedtime" }
];

// Every delay any of the rows offers, ascending, without Never (0). The axis
// is ordinal: 1 min and 2 h are as far apart as the choices between them,
// not 120 times as far, which would crush the short delays into one point.
function axis(lists) {
    var seen = {};
    var out = [];
    for (var i = 0; i < lists.length; i++) {
        for (var j = 0; j < lists[i].length; j++) {
            var mins = Number(lists[i][j]);
            if (mins > 0 && !seen[mins]) {
                seen[mins] = true;
                out.push(mins);
            }
        }
    }
    return out.sort(function(a, b) { return a - b; });
}

function tickLabel(mins) {
    return mins >= 60 ? (mins / 60) + "h" : mins + "m";
}

// The dropdown labels and the summary line share this wording.
function durationLabel(mins) {
    if (!(mins > 0))
        return "Never";
    if (mins < 60)
        return mins + " min";
    var hours = mins / 60;
    return hours + (hours === 1 ? " hour" : " hours");
}

// A gap between two events, spelled out: "20 minutes", "1 hour 45 minutes".
function spanLabel(mins) {
    var hours = Math.floor(mins / 60);
    var rest = mins % 60;
    var parts = [];
    if (hours > 0)
        parts.push(hours + (hours === 1 ? " hour" : " hours"));
    if (rest > 0 || hours === 0)
        parts.push(rest + (rest === 1 ? " minute" : " minutes"));
    return parts.join(" ");
}

// A delay's place along the axis, 0…1, or null for Never. The settings
// merge keeps every value on its row's list, so off-axis only means Never.
function fraction(axisValues, mins) {
    var index = axisValues.indexOf(Number(mins));
    if (!(mins > 0) || index < 0)
        return null;
    return axisValues.length > 1 ? index / (axisValues.length - 1) : 0;
}

// Events at one delay share a marker. Groups run along the axis, with the
// Never group (fraction null) last, where the Never zone is drawn.
function groups(values, axisValues) {
    var out = [];
    for (var i = 0; i < EVENTS.length; i++) {
        var event = EVENTS[i];
        var mins = Number(values[event.key]) || 0;
        var f = fraction(axisValues, mins);
        var group = null;
        for (var j = 0; j < out.length; j++) {
            if (out[j].fraction === f) {
                group = out[j];
                break;
            }
        }
        if (!group) {
            group = { fraction: f, mins: f === null ? 0 : mins, events: [] };
            out.push(group);
        }
        group.events.push({ key: event.key, label: event.label, icon: event.icon });
    }
    out.sort(function(a, b) {
        return (a.fraction === null ? 2 : a.fraction) - (b.fraction === null ? 2 : b.fraction);
    });
    return out;
}

// Places each group's labels so that no two overlap. A label box sits
// centred over its marker, or flush with the marker at either end of the
// axis so it does not hang past it, and rises on a longer stem above any
// earlier box — or earlier stem — it would otherwise cross. Heights are
// measured up from the top of the marker's dot.
//
// metrics: left/right — the axis ends; neverCenter/neverRight — the Never
// zone; widths — label → box width; lineHeight/lineGap — one label line and
// the gap between lines; boxGap — clearance beside a box; baseStem and
// neverStem — the resting gap under a marker's labels and a Never label's;
// dotRadius.
//
// Returns { groups: [{ never, x, boxLeft, boxWidth, align, stem, height,
// events }], lines, top }. `lines` is every label on its own, top to bottom
// within its group, with `lift` — the height of its bottom edge above the
// dot — so a view can draw them from one flat list. `top` is the tallest
// stack.
function layout(groupList, metrics) {
    var placed = [];
    var lines = [];
    var top = 0;
    for (var i = 0; i < groupList.length; i++) {
        var group = groupList[i];
        var never = group.fraction === null;
        var x = never ? metrics.neverCenter
            : metrics.left + group.fraction * (metrics.right - metrics.left);
        var width = 0;
        for (var j = 0; j < group.events.length; j++)
            width = Math.max(width, metrics.widths[group.events[j].label] || 0);
        var height = group.events.length * metrics.lineHeight
            + (group.events.length - 1) * metrics.lineGap;

        var boxLeft = x - width / 2;
        var align = "center";
        if (never) {
            if (boxLeft + width > metrics.neverRight) {
                boxLeft = metrics.neverRight - width;
                align = "right";
            }
        } else if (boxLeft < metrics.left - metrics.dotRadius) {
            boxLeft = x - metrics.dotRadius;
            align = "left";
        } else if (boxLeft + width > metrics.right + metrics.dotRadius) {
            boxLeft = x + metrics.dotRadius - width;
            align = "right";
        }

        var stem = never ? metrics.neverStem : metrics.baseStem;
        // Each pass can only raise the box, and every obstacle is passed at
        // most once per raise, so this settles within placed.length passes.
        for (var pass = 0; pass <= placed.length; pass++) {
            var raised = false;
            for (var k = 0; k < placed.length; k++) {
                var other = placed[k];
                var besideBox = boxLeft < other.boxLeft + other.boxWidth + metrics.boxGap
                    && other.boxLeft < boxLeft + width + metrics.boxGap;
                var crossesBox = besideBox && stem < other.stem + other.height + metrics.lineGap
                    && other.stem < stem + height + metrics.lineGap;
                var crossesStem = !other.never && other.x > boxLeft - metrics.boxGap
                    && other.x < boxLeft + width + metrics.boxGap && stem < other.stem;
                if (crossesBox || crossesStem) {
                    stem = other.stem + other.height + metrics.lineGap;
                    raised = true;
                }
            }
            if (!raised)
                break;
        }

        var entry = { never: never, x: x, boxLeft: boxLeft, boxWidth: width, align: align,
            stem: stem, height: height, events: group.events };
        placed.push(entry);
        top = Math.max(top, stem + height);
        for (var n = 0; n < group.events.length; n++) {
            var event = group.events[n];
            lines.push({ key: event.key, label: event.label, icon: event.icon, never: never,
                align: align, boxLeft: boxLeft, boxWidth: width,
                lift: stem + (group.events.length - 1 - n) * (metrics.lineHeight + metrics.lineGap) });
        }
    }
    return { groups: placed, lines: lines, top: top };
}

function capitalize(text) {
    return text.charAt(0).toUpperCase() + text.slice(1);
}

function joinList(items) {
    if (items.length < 2)
        return items.join("");
    return items.slice(0, -1).join(", ") + " and " + items[items.length - 1];
}

// What the order means. The screen going dark before the session locks is
// the case the three dropdowns hide: waking it in that stretch skips the
// lock screen. That stretch comes back as `band` (axis fractions; `to` 1 is
// the end of the axis) with a warning. Suspending locks first, so a suspend
// before the lock closes the stretch too — but only one that happens on
// mains power as well, so not a battery-only suspend.
function assessment(values, batteryOnly, axisValues) {
    var screenOff = Number(values.idleScreenOffMins) || 0;
    var lock = Number(values.idleLockMins) || 0;
    var suspend = Number(values.idleSuspendMins) || 0;
    var suspendLocks = suspend > 0 && !batteryOnly && (lock === 0 || suspend < lock);
    var lockAt = suspendLocks ? suspend : lock;

    if (screenOff > 0 && (lockAt === 0 || screenOff < lockAt)) {
        var text;
        if (lockAt === 0 && suspend > 0) {
            text = "The screen turns off after " + durationLabel(screenOff)
                + " but only locks when the computer suspends on battery."
                + " Waking it before then skips the lock screen.";
        } else if (lockAt === 0) {
            text = "The screen turns off after " + durationLabel(screenOff)
                + " but never locks. Waking it skips the lock screen.";
        } else if (suspendLocks) {
            text = "The screen turns off " + spanLabel(lockAt - screenOff)
                + " before the computer suspends, which locks it."
                + " Waking it in that time skips the lock screen.";
        } else {
            text = "The screen turns off " + spanLabel(lockAt - screenOff)
                + " before it locks. Waking it in that time skips the lock screen.";
        }
        return {
            tone: "warning",
            text: text,
            band: {
                from: fraction(axisValues, screenOff),
                to: lockAt > 0 ? fraction(axisValues, lockAt) : 1
            }
        };
    }

    // Otherwise read the order back, soonest first; events at one delay
    // share their time ("locks and turns the screen off after 5 min").
    var steps = [];
    function add(mins, verb, suffix) {
        if (!(mins > 0))
            return;
        for (var i = 0; i < steps.length; i++) {
            if (steps[i].mins === mins) {
                steps[i].verbs.push(verb);
                steps[i].suffix = steps[i].suffix || suffix;
                return;
            }
        }
        steps.push({ mins: mins, verbs: [verb], suffix: suffix });
    }
    add(lock, "locks", "");
    add(screenOff, "turns the screen off", "");
    add(suspend, "suspends", batteryOnly ? " on battery" : "");
    steps.sort(function(a, b) { return a.mins - b.mins; });
    if (steps.length === 0)
        return { tone: "info", text: "Nothing happens while the computer is idle.", band: null };
    var phrases = steps.map(function(step) {
        return step.verbs.join(" and ") + " after " + durationLabel(step.mins) + step.suffix;
    });
    return { tone: "info", text: capitalize(joinList(phrases)) + ".", band: null };
}

var exported = {
    EVENTS: EVENTS,
    axis: axis,
    tickLabel: tickLabel,
    durationLabel: durationLabel,
    spanLabel: spanLabel,
    fraction: fraction,
    groups: groups,
    layout: layout,
    assessment: assessment
};

if (typeof module !== "undefined" && module.exports)
    module.exports = exported;
