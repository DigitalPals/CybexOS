pragma ComponentBehavior: Bound
pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "CalendarHelpers.js" as CalendarHelpers
import "ProcHelpers.js" as ProcHelpers

// System-calendar state backed by GNOME Online Accounts + Evolution Data
// Server. The child process receives only a time window; GOA and EDS keep the
// OAuth tokens and cached calendars outside the shell.
Singleton {
    id: root

    readonly property bool enabled: Settings.modOpts.clock.showEvents
    readonly property int daysAhead: Settings.modOpts.clock.daysAhead
    readonly property int pollIntervalSecs: Settings.modOpts.clock.pollMins * 60

    property bool ready: false
    property bool loading: false
    property bool available: true
    property string fetchError: ""
    property string goaError: ""
    property double updatedAt: 0
    property double rangeStartMs: 0
    property double rangeEndMs: 0
    property double requestStartMs: 0
    property double requestEndMs: 0
    // Whether the last request was the rolling default window (month grid +
    // upcoming horizon) rather than a month the user browsed to. Only the
    // default window has to move with the clock.
    property bool requestIsDefault: false
    property double browsedAt: 0
    property int googleAccounts: 0
    property int googleCalendarAccounts: 0
    property var calendars: []
    property var events: []
    property var sourceErrors: []

    readonly property bool googleConnected: googleAccounts > 0
        || calendars.some(calendar => calendar.isGoogle)
    readonly property bool googleCalendarEnabled: googleCalendarAccounts > 0
        || calendars.some(calendar => calendar.isGoogle)
    readonly property string partialWarning: sourceErrors.length === 0 ? ""
        : sourceErrors.length === 1 ? "One calendar could not be read"
        : sourceErrors.length + " calendars could not be read"

    function dayStart(value) {
        const date = value instanceof Date ? value : new Date(value);
        return new Date(date.getFullYear(), date.getMonth(), date.getDate()).getTime();
    }

    function monthWindow(value) {
        const date = value instanceof Date ? value : new Date(value);
        const first = new Date(date.getFullYear(), date.getMonth(), 1);
        const mondayOffset = (first.getDay() + 6) % 7;
        const startDate = new Date(first.getFullYear(), first.getMonth(),
            1 - mondayOffset);
        const endDate = new Date(startDate.getFullYear(), startDate.getMonth(),
            startDate.getDate() + 42);
        return { start: startDate.getTime(), end: endDate.getTime() };
    }

    function defaultWindow() {
        const now = new Date();
        const month = monthWindow(now);
        // Include the complete visible month grid and the configured upcoming
        // horizon in one EDS query. Local-midnight construction survives DST.
        const upcomingEnd = new Date(now.getFullYear(), now.getMonth(),
            now.getDate() + daysAhead + 1).getTime();
        return { start: month.start, end: Math.max(month.end, upcomingEnd) };
    }

    function startRange(startMs, endMs) {
        if (!enabled)
            return;
        const start = Math.floor(Number(startMs) / 1000) * 1000;
        const end = Math.ceil(Number(endMs) / 1000) * 1000;
        if (!Number.isFinite(start) || !Number.isFinite(end) || end <= start)
            return;
        requestStartMs = start;
        requestEndMs = end;
        requestIsDefault = false;
        loading = true;
        fetchProc.staleRuns += fetchProc.running ? 1 : 0;
        fetchProc.running = false;
        fetchProc.running = true;
    }

    function refreshDefault() {
        const window = defaultWindow();
        startRange(window.start, window.end);
        requestIsDefault = enabled;
    }

    // The poll recomputes the default window, so upcoming() keeps working
    // across midnight and days of uptime. A month the user browsed to within
    // the last poll interval is refreshed in place instead; after that the
    // poll returns to the default window.
    function pollRefresh() {
        if (!requestIsDefault && requestEndMs > requestStartMs
                && Date.now() - browsedAt < pollIntervalSecs * 1000)
            startRange(requestStartMs, requestEndMs);
        else
            refreshDefault();
    }

    // Ends a fetch that never reported back, so `loading` cannot stick.
    function abandonFetch(reason) {
        if (fetchProc.running) {
            fetchProc.staleRuns++;
            fetchProc.running = false;
        } else {
            fetchProc.staleRuns = 0;
        }
        loading = false;
        fetchError = reason;
        console.warn("calendar fetch failed:", reason);
    }

    function msUntilNextDay() {
        const now = new Date();
        const next = new Date(now.getFullYear(), now.getMonth(),
            now.getDate() + 1).getTime();
        return Math.max(1000, next - now.getTime() + 5000);
    }

    function refresh() {
        if (requestStartMs > 0 && requestEndMs > requestStartMs)
            startRange(requestStartMs, requestEndMs);
        else
            refreshDefault();
    }

    function ensureMonth(value, force) {
        if (!enabled)
            return;
        const window = monthWindow(value);
        const heldStart = loading ? requestStartMs : rangeStartMs;
        const heldEnd = loading ? requestEndMs : rangeEndMs;
        if (!force && heldStart <= window.start && heldEnd >= window.end)
            return;
        const today = new Date();
        const sameMonth = value.getFullYear() === today.getFullYear()
            && value.getMonth() === today.getMonth();
        if (sameMonth) {
            refreshDefault();
            return;
        }
        browsedAt = Date.now();
        startRange(window.start, window.end);
    }

    function eventsForDay(value, limit) {
        const start = dayStart(value);
        const date = new Date(start);
        const end = new Date(date.getFullYear(), date.getMonth(),
            date.getDate() + 1).getTime();
        return CalendarHelpers.eventsInRange(events, start, end, limit);
    }

    function upcoming(limit) {
        const now = Date.now();
        const date = new Date(now);
        const end = new Date(date.getFullYear(), date.getMonth(),
            date.getDate() + daysAhead + 1).getTime();
        return CalendarHelpers.upcoming(events, now, end, limit);
    }

    function manageAccounts() {
        // The Online Accounts panel is installed and fully functional under
        // Hyprland, but its desktop file hides it outside GNOME. This override
        // applies only to the launched Settings process; it does not change
        // the session desktop or start GNOME Shell.
        Quickshell.execDetached([
            "env", "XDG_CURRENT_DESKTOP=GNOME",
            "gnome-control-center", "online-accounts"
        ]);
    }

    function openCalendar(value) {
        const date = value instanceof Date ? value : new Date(value);
        const pad = number => String(number).padStart(2, "0");
        const isoDate = date.getFullYear() + "-" + pad(date.getMonth() + 1)
            + "-" + pad(date.getDate());
        Quickshell.execDetached(["gnome-calendar", "--date", isoDate]);
    }

    function settle(exitCode, body, errText) {
        loading = false;
        if (exitCode !== 0) {
            fetchError = ProcHelpers.commandError("calendar-events.py", exitCode, errText);
            console.warn("calendar fetch failed:", fetchError);
            return;
        }

        let raw = null;
        try {
            raw = JSON.parse(body);
        } catch (error) {
            console.warn("calendar response parse failed:", error);
        }
        const payload = CalendarHelpers.normalizePayload(raw);
        if (!payload) {
            fetchError = "calendar-events.py returned output this shell could not read";
            return;
        }

        available = payload.available;
        fetchError = payload.available ? "" : payload.error
            || "GNOME calendar support is unavailable";
        goaError = payload.goaError;
        googleAccounts = payload.googleAccounts;
        googleCalendarAccounts = payload.googleCalendarAccounts;
        calendars = payload.calendars;
        events = payload.events;
        sourceErrors = payload.sourceErrors;
        rangeStartMs = payload.rangeStartMs || requestStartMs;
        rangeEndMs = payload.rangeEndMs || requestEndMs;
        updatedAt = Date.now();
        ready = true;
    }

    Process {
        id: fetchProc

        property int staleRuns: 0
        property string body: ""
        property string errText: ""
        property bool exitSeen: false
        property int lastExit: 0

        command: [
            "timeout", "30s",
            "python3", Quickshell.shellDir + "/scripts/calendar-events.py",
            String(Math.floor(root.requestStartMs / 1000)),
            String(Math.ceil(root.requestEndMs / 1000))
        ]

        stdout: StdioCollector {
            onStreamFinished: fetchProc.body = text
        }
        stderr: StdioCollector {
            onStreamFinished: fetchProc.errText = text
        }
        onExited: (exitCode, exitStatus) => {
            fetchProc.exitSeen = true;
            fetchProc.lastExit = exitCode;
        }
        onRunningChanged: {
            if (running) {
                body = "";
                errText = "";
                exitSeen = false;
                lastExit = 0;
            } else if (staleRuns > 0) {
                staleRuns--;
            } else {
                root.settle(exitSeen ? lastExit : ProcHelpers.NOT_STARTED, body, errText);
            }
        }
    }

    Timer {
        interval: root.pollIntervalSecs * 1000
        running: root.enabled
        repeat: true
        onTriggered: root.pollRefresh()
    }

    // The helper answers within its own 15 s deadline and `timeout` kills it
    // at 30 s; this is the last resort for a run whose exit never arrives.
    Timer {
        interval: 45000
        running: root.loading
        onTriggered: root.abandonFetch("Calendar request timed out")
    }

    // The default window starts from today: move it at local midnight rather
    // than waiting for the next poll. Re-armed after every firing, so a
    // suspend or DST change only delays it to the following check.
    Timer {
        id: dayRollover
        interval: root.msUntilNextDay()
        running: root.enabled
        onTriggered: {
            if (root.requestIsDefault)
                root.refreshDefault();
            interval = root.msUntilNextDay();
            restart();
        }
    }

    onEnabledChanged: {
        if (enabled)
            refreshDefault();
        else {
            fetchProc.staleRuns += fetchProc.running ? 1 : 0;
            fetchProc.running = false;
            loading = false;
            fetchError = "";
        }
    }
    onDaysAheadChanged: {
        if (enabled)
            refreshDefault();
    }

    // Not needed for the first frame: the bar shows no events, and opening a
    // calendar surface fetches its own window. Kept off the startup burst.
    Timer {
        id: warmUp
        interval: 12000
        onTriggered: {
            if (root.enabled && !root.ready && !root.loading)
                root.refreshDefault();
        }
    }

    Component.onCompleted: {
        if (enabled)
            warmUp.start();
    }
}
