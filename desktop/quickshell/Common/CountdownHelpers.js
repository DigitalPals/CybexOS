// Reminder countdowns read in whole minutes (and hours) until their final
// minute, then in whole seconds. Everything here takes the time left in
// milliseconds, so a view can wake exactly when a label changes instead of
// re-reading a seconds clock for as long as it is open.

function remainingLabel(leftMs) {
    var seconds = Math.max(0, Math.ceil(Number(leftMs) / 1000));
    if (seconds < 60)
        return seconds + "s";
    var minutes = Math.ceil(seconds / 60);
    if (minutes < 60)
        return minutes + "m";
    var hours = Math.floor(minutes / 60);
    return hours + "h " + (minutes % 60) + "m";
}

// Milliseconds until remainingLabel(leftMs) next reads differently, or 0 once
// the countdown has run out. A minute label steps when the time left reaches
// a whole minute; inside the final minute the label steps every second.
function nextChangeMs(leftMs) {
    var left = Number(leftMs);
    if (!(left > 0))
        return 0;
    var unit = left > 60000 ? 60000 : 1000;
    return left - unit * (Math.ceil(left / unit) - 1);
}

// The soonest label change across due times given in epoch seconds, or 0
// when nothing is still counting down.
function soonestChangeMs(dueSecs, nowMs) {
    var list = Array.isArray(dueSecs) ? dueSecs : [];
    var wait = 0;
    for (var i = 0; i < list.length; i++) {
        var next = nextChangeMs(Number(list[i]) * 1000 - nowMs);
        if (next > 0 && (wait === 0 || next < wait))
            wait = next;
    }
    return wait;
}

if (typeof module !== "undefined" && module.exports) {
    module.exports = { remainingLabel: remainingLabel,
        nextChangeMs: nextChangeMs, soonestChangeMs: soonestChangeMs };
}
