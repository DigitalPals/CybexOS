// Pure normalization and range helpers for the EDS calendar bridge. Keep Qt
// APIs out of this file so the process/UI contract can be exercised by Node.

var DAY_MS = 24 * 60 * 60 * 1000;
var DEFAULT_COLOR = "#62a0ea";

function stringIn(value, fallback, limit) {
    var text = typeof value === "string" ? value : fallback;
    var max = limit === undefined ? 500 : limit;
    return text.slice(0, max);
}

function countIn(value) {
    return typeof value === "number" && Number.isFinite(value)
        ? Math.max(0, Math.floor(value)) : 0;
}

function colorIn(value) {
    return typeof value === "string" && /^#[0-9a-fA-F]{6}(?:[0-9a-fA-F]{2})?$/.test(value)
        ? value : DEFAULT_COLOR;
}

function normalizeCalendar(value) {
    if (!value || typeof value !== "object")
        return null;
    return {
        uid: stringIn(value.uid, "", 300),
        name: stringIn(value.name, "Calendar", 160),
        color: colorIn(value.color),
        isGoogle: value.isGoogle === true
    };
}

function normalizeEvent(value) {
    if (!value || typeof value !== "object")
        return null;
    var startMs = Number(value.startMs);
    var endMs = Number(value.endMs);
    if (!Number.isFinite(startMs) || !Number.isFinite(endMs) || endMs <= startMs)
        return null;
    var allDay = value.allDay === true;
    return {
        id: stringIn(value.id, "", 700),
        uid: stringIn(value.uid, "", 300),
        calendarUid: stringIn(value.calendarUid, "", 300),
        calendar: stringIn(value.calendar, "Calendar", 160),
        color: colorIn(value.color),
        isGoogle: value.isGoogle === true,
        summary: stringIn(value.summary, "(Untitled event)", 500)
            || "(Untitled event)",
        location: stringIn(value.location, "", 500),
        startMs: Math.floor(startMs),
        endMs: Math.floor(endMs),
        allDay: allDay
    };
}

function normalizePayload(value) {
    if (!value || typeof value !== "object" || Array.isArray(value))
        return null;

    var calendars = Array.isArray(value.calendars)
        ? value.calendars.map(normalizeCalendar).filter(function(item) { return item !== null; })
        : [];
    var seen = {};
    var events = [];
    if (Array.isArray(value.events)) {
        value.events.forEach(function(raw) {
            var event = normalizeEvent(raw);
            if (!event)
                return;
            var identity = "$" + (event.id || event.calendarUid + "\n" + event.uid
                + "\n" + event.summary + "\n" + event.startMs + "\n" + event.endMs);
            if (seen[identity])
                return;
            seen[identity] = true;
            events.push(event);
        });
    }
    events.sort(function(a, b) {
        return a.startMs - b.startMs || a.endMs - b.endMs
            || a.summary.localeCompare(b.summary);
    });

    var sourceErrors = Array.isArray(value.sourceErrors)
        ? value.sourceErrors.filter(function(item) {
            return item && typeof item === "object";
        }).map(function(item) {
            return {
                calendar: stringIn(item.calendar, "Calendar", 160),
                message: stringIn(item.message, "calendar could not be read", 200)
            };
        }) : [];

    return {
        available: value.available !== false,
        error: stringIn(value.error, "", 300),
        goaError: stringIn(value.goaError, "", 300),
        googleAccounts: countIn(value.googleAccounts),
        googleCalendarAccounts: countIn(value.googleCalendarAccounts),
        calendars: calendars,
        events: events,
        sourceErrors: sourceErrors,
        rangeStartMs: Number.isFinite(Number(value.rangeStartMs))
            ? Number(value.rangeStartMs) : 0,
        rangeEndMs: Number.isFinite(Number(value.rangeEndMs))
            ? Number(value.rangeEndMs) : 0
    };
}

// Half-open ranges make adjacent all-day events unambiguous: an event ending
// at midnight does not also appear on the following day.
function overlaps(event, startMs, endMs) {
    return !!event && event.startMs < endMs && event.endMs > startMs;
}

function eventsInRange(events, startMs, endMs, limit) {
    if (!Array.isArray(events) || !Number.isFinite(startMs)
            || !Number.isFinite(endMs) || endMs <= startMs)
        return [];
    var out = [];
    var max = limit === undefined ? Number.MAX_SAFE_INTEGER : Math.max(0, limit);
    for (var i = 0; i < events.length && out.length < max; i++) {
        if (overlaps(events[i], startMs, endMs))
            out.push(events[i]);
    }
    return out;
}

function upcoming(events, nowMs, endMs, limit) {
    if (!Array.isArray(events) || !Number.isFinite(nowMs)
            || !Number.isFinite(endMs) || endMs <= nowMs)
        return [];
    var out = events.filter(function(event) {
        return event && event.endMs > nowMs && event.startMs < endMs;
    });
    // Ongoing items belong first, then future start time. The stable fields
    // settle ties so refreshes cannot reshuffle two meetings at one time.
    out.sort(function(a, b) {
        var aOrder = Math.max(a.startMs, nowMs);
        var bOrder = Math.max(b.startMs, nowMs);
        return aOrder - bOrder || a.endMs - b.endMs
            || a.summary.localeCompare(b.summary);
    });
    return out.slice(0, limit === undefined ? out.length : Math.max(0, limit));
}

var exported = {
    DAY_MS: DAY_MS,
    DEFAULT_COLOR: DEFAULT_COLOR,
    normalizePayload: normalizePayload,
    overlaps: overlaps,
    eventsInRange: eventsInRange,
    upcoming: upcoming
};

if (typeof module !== "undefined" && module.exports)
    module.exports = exported;
