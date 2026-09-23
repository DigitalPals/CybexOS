const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { shellDir, load } = require("./shell.cjs");

const Calendar = load("CalendarHelpers.js");

function read(relative) {
    return fs.readFileSync(path.join(shellDir, relative), "utf8");
}

function event(summary, startMs, endMs, extra = {}) {
    return {
        id: summary,
        uid: summary,
        calendarUid: "work",
        calendar: "Work",
        color: "#123456",
        summary,
        startMs,
        endMs,
        ...extra
    };
}

test("calendar payloads are bounded, sorted and deduplicated", () => {
    const payload = Calendar.normalizePayload({
        available: true,
        googleAccounts: 1.8,
        googleCalendarAccounts: 1,
        calendars: [
            { uid: "work", name: "Work", color: "#abc123", isGoogle: true },
            null
        ],
        events: [
            event("Later", 3000, 4000, { color: "not-a-color" }),
            event("First", 1000, 2000),
            event("First", 1000, 2000),
            event("Broken", 5000, 4000)
        ],
        sourceErrors: [{ calendar: "Private", message: "offline" }]
    });

    assert.equal(payload.googleAccounts, 1);
    assert.equal(payload.googleCalendarAccounts, 1);
    assert.deepEqual(payload.events.map(item => item.summary), ["First", "Later"]);
    assert.equal(payload.events[1].color, Calendar.DEFAULT_COLOR);
    assert.deepEqual(payload.calendars, [
        { uid: "work", name: "Work", color: "#abc123", isGoogle: true }
    ]);
    assert.deepEqual(payload.sourceErrors,
        [{ calendar: "Private", message: "offline" }]);
    assert.equal(Calendar.normalizePayload([]), null);
});

test("event windows use half-open boundaries", () => {
    const midnight = Date.UTC(2026, 7, 28);
    const next = midnight + Calendar.DAY_MS;
    const previousAllDay = event("Previous", midnight - Calendar.DAY_MS, midnight,
        { allDay: true });
    const currentAllDay = event("Current", midnight, next, { allDay: true });
    const crossing = event("Crossing", midnight - 1000, midnight + 1000);

    assert.equal(Calendar.overlaps(previousAllDay, midnight, next), false);
    assert.equal(Calendar.overlaps(currentAllDay, midnight, next), true);
    assert.equal(Calendar.overlaps(crossing, midnight, next), true);
    assert.deepEqual(
        Calendar.eventsInRange([previousAllDay, currentAllDay, crossing], midnight, next, 1)
            .map(item => item.summary),
        ["Current"]
    );
});

test("upcoming events retain ongoing items and obey the configured limit", () => {
    const now = 10_000;
    const rows = Calendar.upcoming([
        event("Past", 1000, 9000),
        event("Ongoing", 5000, 20_000),
        event("Soon", 12_000, 13_000),
        event("Outside", 50_000, 60_000)
    ], now, 40_000, 2);
    assert.deepEqual(rows.map(item => item.summary), ["Ongoing", "Soon"]);
});

test("the calendar bridge delegates credentials and recurrence to GNOME", () => {
    const service = read("Common/Calendar.qml");
    const helper = read("scripts/calendar-events.py");
    const popover = read("Popovers/CalendarPopover.qml");
    const settings = read("Common/SettingsHelpers.js");
    const tasks = fs.readFileSync(path.resolve(shellDir, "../../tasks/main.yml"), "utf8");

    assert.match(service,
        /"env", "XDG_CURRENT_DESKTOP=GNOME",\s*"gnome-control-center", "online-accounts"/);
    assert.match(service, /scripts\/calendar-events\.py/);
    assert.match(service, /gnome-calendar", "--date"/);
    assert.match(helper, /SourceRegistry\.new_sync/);
    assert.match(helper, /generate_instances_sync/);
    assert.match(helper, /get_selected\(\)/);
    assert.match(helper, /Goa\.Client\.new_sync/);
    assert.doesNotMatch(helper, /get_oauth2_access_token|password|secret\.get/i,
        "the bridge must never retrieve credentials into the shell process");
    assert.match(popover, /CalendarHelpers\.upcoming/);
    assert.match(popover, /Connect Google Calendar/);
    assert.match(popover, /Calendar\.manageAccounts\(\)/);
    assert.match(settings,
        /showEvents: true, daysAhead: 14, pollMins: 15/);
    for (const packageName of ["gnome-online-accounts", "gnome-control-center",
        "gnome-calendar", "evolution-data-server", "python3-gobject"])
        assert.match(tasks, new RegExp(`- ${packageName.replaceAll("-", "\\-")}`));

    const syntax = spawnSync("python3", ["-c",
        "import ast,sys; ast.parse(sys.stdin.read())"], {
        input: helper,
        encoding: "utf8"
    });
    assert.equal(syntax.status, 0, syntax.stderr);
});

test("invalid helper ranges still return a machine-readable envelope", () => {
    const script = path.join(shellDir, "scripts", "calendar-events.py");
    const run = spawnSync("python3", [script, "20", "10"], { encoding: "utf8" });
    assert.equal(run.status, 0, run.stderr);
    const payload = JSON.parse(run.stdout);
    assert.equal(payload.available, false);
    assert.match(payload.error, /window is not valid/);
    assert.deepEqual(payload.events, []);
});

// A stand-in for the PyGObject EDS/GOA surface the helper touches, so its
// source handling runs without Evolution Data Server. Each source's connect
// sleeps `connectDelay` seconds and logs the connect-wait it was given.
const FAKE_GI_REPOSITORY = String.raw`
import json, os, threading, time

CONFIG = json.loads(os.environ["FAKE_EDS"])
LOG = os.environ["FAKE_EDS_LOG"]
LOG_LOCK = threading.Lock()


class _Time:
    def __init__(self, seconds):
        self.seconds = seconds
    def is_null_time(self):
        return False
    def get_timezone(self):
        return None
    def as_timet_with_zone(self, zone):
        return self.seconds
    def is_date(self):
        return False


class _Component:
    def __init__(self, spec):
        self.spec = spec
    def get_status(self):
        return self.spec.get("status", "confirmed")
    def get_uid(self):
        return self.spec["uid"]
    def get_summary(self):
        return self.spec.get("summary")
    def get_location(self):
        return ""


class _Client:
    def __init__(self, spec):
        self.spec = spec
    def set_default_timezone(self, zone):
        pass
    def generate_instances_sync(self, start, end, cancellable, callback, data):
        if self.spec.get("generateError"):
            raise RuntimeError(self.spec["generateError"])
        for event in self.spec.get("events", []):
            callback(_Component(event), _Time(event["start"]), _Time(event["end"]),
                     None, None)


class _Extension:
    def __init__(self, spec):
        self.spec = spec
    def get_selected(self):
        return True
    def get_color(self):
        return "#123456"
    def get_backend_name(self):
        return "local"


class _Source:
    def __init__(self, spec):
        self.spec = spec
    def get_enabled(self):
        return True
    def get_extension(self, name):
        return _Extension(self.spec)
    def has_extension(self, name):
        return False
    def get_uid(self):
        return self.spec["uid"]
    def get_display_name(self):
        return self.spec["name"]
    def get_parent(self):
        return ""


class _Registry:
    def list_sources(self, extension):
        return [_Source(spec) for spec in CONFIG["sources"]]
    def ref_source(self, uid):
        return None


class ICalGLib:
    class Timezone:
        @staticmethod
        def get_utc_timezone():
            return "UTC"
    class PropertyStatus:
        CANCELLED = "cancelled"
        DELETED = "deleted"


class ECal:
    class ClientSourceType:
        EVENTS = "events"
    @staticmethod
    def util_get_system_timezone():
        return "Europe/Amsterdam"
    class Client:
        @staticmethod
        def connect_sync(source, source_type, wait, cancellable):
            with LOG_LOCK, open(LOG, "a") as stream:
                stream.write(json.dumps({"uid": source.spec["uid"], "wait": wait}) + "\n")
            time.sleep(source.spec.get("connectDelay", 0))
            return _Client(source.spec)


class EDataServer:
    SOURCE_EXTENSION_CALENDAR = "Calendar"
    SOURCE_EXTENSION_GOA = "GNOME Online Accounts"
    SOURCE_EXTENSION_COLLECTION = "Collection"
    class SourceRegistry:
        @staticmethod
        def new_sync(cancellable):
            return _Registry()


class Goa:
    class Client:
        @staticmethod
        def new_sync(cancellable):
            return Goa
    @staticmethod
    def get_accounts():
        return []
`;

function runFakeEds(sources, deadlineSeconds) {
    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "calendar-eds-"));
    try {
        const gi = path.join(tmp, "gi");
        fs.mkdirSync(path.join(gi, "repository"), { recursive: true });
        fs.writeFileSync(path.join(gi, "__init__.py"),
            "def require_version(namespace, version):\n    pass\n");
        fs.writeFileSync(path.join(gi, "repository", "__init__.py"), FAKE_GI_REPOSITORY);
        const log = path.join(tmp, "connects.log");
        fs.writeFileSync(log, "");
        const helper = path.join(shellDir, "scripts", "calendar-events.py");
        const script = [
            "import importlib.util, sys, time",
            `sys.path.insert(0, ${JSON.stringify(tmp)})`,
            `spec = importlib.util.spec_from_file_location("calendar_events", ${JSON.stringify(helper)})`,
            "module = importlib.util.module_from_spec(spec)",
            "spec.loader.exec_module(module)",
            `module.arm_deadline(${deadlineSeconds})`,
            "started = time.monotonic()",
            "module.main(['1000', '100000'])",
            "sys.stderr.write(f'elapsed={time.monotonic() - started:.3f}\\n')",
        ].join("\n");
        const started = Date.now();
        const run = spawnSync("python3", ["-B", "-c", script], {
            encoding: "utf8",
            timeout: 15000,
            env: { ...process.env, FAKE_EDS: JSON.stringify({ sources }), FAKE_EDS_LOG: log },
        });
        return {
            run,
            wallMs: Date.now() - started,
            payload: run.stdout ? JSON.parse(run.stdout) : null,
            connects: fs.readFileSync(log, "utf8").trim().split("\n").filter(Boolean)
                .map(line => JSON.parse(line)),
        };
    } finally {
        fs.rmSync(tmp, { recursive: true, force: true });
    }
}

test("calendar sources connect side by side with a one-second connect wait", () => {
    const { run, payload, connects } = runFakeEds([
        { uid: "work", name: "Work", connectDelay: 0.6,
            events: [{ uid: "standup", summary: "Standup", start: 3000, end: 3600 }] },
        { uid: "home", name: "Home", connectDelay: 0.6,
            events: [
                { uid: "dentist", summary: "Dentist", start: 2000, end: 2600 },
                { uid: "gone", summary: "Cancelled", start: 2500, end: 2600,
                    status: "cancelled" },
            ] },
        { uid: "broken", name: "Broken", connectDelay: 0.6, generateError: "offline" },
    ], 10);
    assert.equal(run.status, 0, run.stderr);
    // Three 0.6 s connects took 1.8 s one after another.
    const elapsed = Number(/elapsed=([\d.]+)/.exec(run.stderr)[1]);
    assert.ok(elapsed < 1.4, `sources were read one after another (${elapsed}s)`);
    assert.deepEqual(connects.map(connect => connect.wait), [1, 1, 1]);

    assert.equal(payload.available, true);
    assert.deepEqual(payload.events.map(event => [event.summary, event.startMs, event.calendar]),
        [["Dentist", 2000000, "Home"], ["Standup", 3000000, "Work"]]);
    assert.deepEqual(payload.calendars.map(calendar => calendar.name), ["Broken", "Home", "Work"]);
    assert.deepEqual(payload.sourceErrors, [{ calendar: "Broken", message: "offline" }]);
    assert.equal(payload.rangeStartMs, 1000000);
});

test("the deadline keeps the calendars that answered and names the one that did not", () => {
    const { run, wallMs, payload } = runFakeEds([
        { uid: "work", name: "Work",
            events: [{ uid: "standup", summary: "Standup", start: 3000, end: 3600 }] },
        { uid: "remote", name: "Remote", connectDelay: 30 },
    ], 1);
    assert.equal(run.status, 0, run.stderr);
    assert.ok(wallMs < 8000, `the deadline did not end the helper (${wallMs}ms)`);
    assert.equal(payload.available, true, "one slow calendar must not blank the rest");
    assert.deepEqual(payload.events.map(event => event.summary), ["Standup"]);
    assert.deepEqual(payload.sourceErrors,
        [{ calendar: "Remote", message: "Calendar request timed out" }]);
    const normalized = Calendar.normalizePayload(payload);
    assert.equal(normalized.available, true);
    assert.equal(normalized.sourceErrors.length, 1);
});

test("both event views say when a calendar could not be read", () => {
    // A timed-out calendar leaves the others' events on screen; without a
    // note the Day sheet's week and next events look complete.
    const warning = /Text \{\s*visible: Calendar\.partialWarning !== "" && Calendar\.ready[\s\S]{0,120}?text: Calendar\.partialWarning/;
    assert.match(read("Popovers/CalendarPopover.qml"), warning);
    assert.match(read("Popovers/DaySheetPopover.qml"), warning);
});
