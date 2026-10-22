// Duration and ratio formatting shared across the shell. Pure — no Qt APIs —
// so the same code runs under Node in tests.
//
// The coarse duration labels (the battery estimate, Notifs' "5m ago", and
// T3's two working-timer variants) deliberately stay with their surfaces:
// they render different shapes for different contexts and share only the
// arithmetic below, which is what this file
// carries. Folding them into one function would need a format argument per
// caller, which is the duplication again with extra indirection.

// Seconds per unit, and the millisecond equivalents. Named because 86400000
// in a binding says nothing about what it measures.
var MINUTE = 60;
var HOUR = 3600;
var DAY = 86400;
var MS_SECOND = 1000;
var MS_MINUTE = MINUTE * MS_SECOND;
var MS_HOUR = HOUR * MS_SECOND;
var MS_DAY = DAY * MS_SECOND;

function pad2(value) {
    return String(value).padStart(2, "0");
}

// A ratio safe to feed a width, an opacity or a fill fraction.
function clamp01(value) {
    return Math.max(0, Math.min(1, value));
}

// "m:ss" — a media position, a poll countdown. Missing, negative and
// non-finite inputs read as zero rather than as a stray minus sign.
function mmss(seconds) {
    var total = typeof seconds === "number" && isFinite(seconds) && seconds > 0
        ? Math.floor(seconds) : 0;
    return Math.floor(total / MINUTE) + ":" + pad2(total % MINUTE);
}

var exported = {
    MINUTE: MINUTE,
    HOUR: HOUR,
    DAY: DAY,
    MS_SECOND: MS_SECOND,
    MS_MINUTE: MS_MINUTE,
    MS_HOUR: MS_HOUR,
    MS_DAY: MS_DAY,
    pad2: pad2,
    clamp01: clamp01,
    mmss: mmss
};

if (typeof module !== "undefined" && module.exports)
    module.exports = exported;
