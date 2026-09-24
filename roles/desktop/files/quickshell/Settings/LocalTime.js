// Instants as people read them, in local time: "Today at 19:16",
// "Yesterday at 08:02", "Monday at 21:40", "12 Sep at 08:02", "12 Sep 2025".
// The About page uses it for the last deploy check and for recovery points.
// Pure — no Qt APIs — so the same code runs under Node in tests.

var DAY_MS = 86400000;
var MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
var WEEKDAYS = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday",
    "Friday", "Saturday"];

// ISO 8601, extended ("2026-09-24T17:16:48.655239+00:00") or basic
// ("20260924T171648Z", a recovery point's stamp), to epoch milliseconds, or
// NaN. Parsed by hand: Python writes six fractional digits and a numeric
// offset, which ECMAScript's date string format does not promise to accept,
// and Qt's engine and Node's disagree about it. No zone means local time.
function parse(value) {
    var match = /^(\d{4})-?(\d{2})-?(\d{2})[T ](\d{2}):?(\d{2})(?::?(\d{2})(?:[.,](\d+))?)?(Z|[+-]\d{2}(?::?\d{2})?)?$/
        .exec(String(value === undefined || value === null ? "" : value).trim());
    if (!match)
        return NaN;
    var year = Number(match[1]);
    var month = Number(match[2]) - 1;
    var day = Number(match[3]);
    var hours = Number(match[4]);
    var minutes = Number(match[5]);
    var seconds = Number(match[6] || 0);
    var millis = match[7] ? Math.floor(Number("0." + match[7]) * 1000) : 0;
    if (month > 11 || day < 1 || day > 31 || hours > 23 || minutes > 59 || seconds > 60)
        return NaN;
    if (!match[8])
        return new Date(year, month, day, hours, minutes, seconds, millis).getTime();
    var utc = Date.UTC(year, month, day, hours, minutes, seconds, millis);
    if (match[8] === "Z")
        return utc;
    var zone = match[8].replace(":", "");
    var offset = Number(zone.slice(1, 3)) * 60 + Number(zone.slice(3, 5) || 0);
    return utc - (zone.charAt(0) === "-" ? -offset : offset) * 60000;
}

function pad2(value) {
    return value < 10 ? "0" + value : String(value);
}

// The same clock the bar shows: "19:16", or "7:16 PM" on a 12-hour clock.
function clock(date, clock24) {
    var hours = date.getHours();
    var minutes = pad2(date.getMinutes());
    if (clock24)
        return pad2(hours) + ":" + minutes;
    return (hours % 12 || 12) + ":" + minutes + (hours < 12 ? " AM" : " PM");
}

// Calendar days from `thenMs` to `nowMs` in local time, so "yesterday"
// means the previous date rather than 24 hours ago. Rounded because a
// daylight-saving day is 23 or 25 hours long. Negative for the future.
function daysBetween(thenMs, nowMs) {
    var then = new Date(thenMs);
    var now = new Date(nowMs);
    then.setHours(0, 0, 0, 0);
    now.setHours(0, 0, 0, 0);
    return Math.round((now.getTime() - then.getTime()) / DAY_MS);
}

function label(ms, nowMs, clock24) {
    if (typeof ms !== "number" || !isFinite(ms))
        return "";
    var date = new Date(ms);
    var time = clock(date, clock24);
    var days = daysBetween(ms, nowMs);
    if (days === 0)
        return "Today at " + time;
    if (days === 1)
        return "Yesterday at " + time;
    if (days > 1 && days < 7)
        return WEEKDAYS[date.getDay()] + " at " + time;
    var dayMonth = date.getDate() + " " + MONTHS[date.getMonth()];
    return date.getFullYear() === new Date(nowMs).getFullYear()
        ? dayMonth + " at " + time : dayMonth + " " + date.getFullYear();
}

// A stored timestamp as a label, or `fallback` when it does not parse.
function fromText(value, nowMs, clock24, fallback) {
    var ms = parse(value);
    return isFinite(ms) ? label(ms, nowMs, clock24) : fallback;
}

var exported = {
    parse: parse,
    clock: clock,
    daysBetween: daysBetween,
    label: label,
    fromText: fromText
};

if (typeof module !== "undefined" && module.exports)
    module.exports = exported;
