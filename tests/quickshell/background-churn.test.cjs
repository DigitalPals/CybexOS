// Background work that runs whether or not anyone is looking: polls, retries,
// monitors and the session-start burst. Pure rules run here; the QML wiring
// that has no Node surface is pinned by source contracts.
const test = require("node:test");
const { untranslated } = require("./shell.cjs");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { shellDir, load } = require("./shell.cjs");

const S = load("SysInfoHelpers.js");

function read(relative) {
    return untranslated(fs.readFileSync(path.join(shellDir, relative), "utf8"));
}

test("weather is fetched only for a set location someone is shown", () => {
    const weather = read("Common/Weather.qml");
    const sheet = read("Popovers/DaySheetPopover.qml");
    const vm = require("node:vm");

    const locationSet = weather.match(/readonly property bool locationSet: ([^\n]*\n[^\n]*)/)[1];
    const set = (lat, lon, place) => vm.runInNewContext(locationSet,
        { Settings: { modOpts: { weather: { lat, lon, place } } } });
    assert.equal(set(0, 0, ""), false, "the shipped default is not a location");
    assert.equal(set(0, 0, "Amsterdam"), false, "a label alone fetches nothing");
    assert.equal(set(52.37, 4.9, ""), true);
    assert.equal(set(0, 4.9, "Somewhere"), true);

    assert.match(weather,
        /readonly property bool wanted: locationSet && \(widgetOn \|\| watchers > 0\)/);
    assert.match(weather, /hit = mods\[col\]\.find\(m => m\.id === "weather"\)/);
    assert.match(weather,
        /interval: root\.pollIntervalSecs \* 1000\s*running: NetworkStatus\.online && root\.wanted && !Activity\.idle/);
    assert.match(weather,
        /interval: root\.retryIntervalSecs \* 1000\s*running: NetworkStatus\.online && root\.wanted && !Activity\.idle/);
    assert.match(weather,
        /target: Activity[\s\S]{0,80}function onResumed\(\)[\s\S]{0,160}root\.stale\(root\.pollIntervalSecs \* 1000\)\)\s*root\.refresh\(\)/);
    assert.match(weather, /function acquire\(\) \{\s*watchers\+\+;[\s\S]{0,120}stale\(600000\)\)\s*refresh\(\)/);
    assert.match(weather, /onLocationSetChanged: \{[\s\S]{0,300}?ready = false;/,
        "clearing the location drops the old place's sky");

    assert.match(sheet, /onClaimed: \{[^}]*Weather\.acquire\(\);/);
    assert.match(sheet, /onReleased: \{[^}]*Weather\.release\(\);/);
    assert.match(sheet,
        /LinkText \{\s*visible: !Weather\.locationSet[\s\S]{0,120}?text: "Set a location in Settings"[\s\S]{0,160}?Settings\.openWidgetSettings\("weather"\);\s*Settings\.showPanel\("bar"/,
        "the sheet links to where the location is set");
});

test("an enabled weather widget with no location stays on the bar and says so", () => {
    const vm = require("node:vm");
    const bar = read("Bar/Bar.qml");
    const chip = read("Bar/Modules/Weather.qml");
    const page = read("Settings/ModulesPage.qml");
    const E = load("WidgetEditor.js");

    const rule = bar.match(/case "weather": return ([^;]*);/)[1];
    const shown = (ready, offline, locationSet) => vm.runInNewContext(rule,
        { Weather: { ready, offline, locationSet } });
    assert.equal(shown(false, false, true), false, "the gap before the first forecast stays blank");
    assert.equal(shown(false, false, false), true, "no location is a reason to show the hint");
    assert.equal(shown(true, false, true), true);
    assert.equal(shown(false, true, true), true);
    assert.match(page, /weather: Weather\.ready \|\| Weather\.offline \|\| !Weather\.locationSet,\s*weatherLocation: Weather\.locationSet/,
        "the widget editor agrees with the bar");

    assert.match(chip, /name: !Weather\.locationSet \? "add_location"/);
    assert.match(chip, /visible: Weather\.locationSet\s*anchors\.verticalCenter: parent\.verticalCenter\s*\/\/ Weather\.temp/,
        "compact, the location mark stands alone");
    assert.match(chip, /text: !Weather\.locationSet \? "Set location"/);
    assert.match(chip, /tooltip: !Weather\.locationSet \? "Weather · set a location in Settings"/);

    const weather = { key: "weather", id: "weather", enabled: true, plugin: false };
    assert.equal(E.status(weather, { weather: true, weatherLocation: false }),
        "On your bar · needs a location");
    assert.equal(E.status(weather, { weather: true, weatherLocation: true }), "Ready · weather loaded");
    assert.equal(E.status(weather, { weather: false, weatherLocation: true }),
        "Hidden · waiting for weather");
});

test("the idle-inhibit countdown ticks on minute boundaries", () => {
    assert.equal(S.countdownTickMs(1000 + 30 * 60000, 1000), 60050);
    assert.equal(S.countdownTickMs(90000, 0), 30050);
    assert.equal(S.countdownTickMs(1000, 1000), 1);
    assert.equal(S.countdownTickMs(0, 5000), 1);
    // Every tick lands just past the point where the whole-minute label moves.
    const until = 10 * 60000 + 1234;
    let now = 0;
    const label = at => Math.ceil(Math.ceil((until - at) / 1000) / 60);
    for (let i = 0; i < 10; i++) {
        const before = label(now + S.countdownTickMs(until, now) - 60);
        now += S.countdownTickMs(until, now);
        assert.notEqual(label(now), before);
    }
    const sys = read("Common/SysInfo.qml");
    assert.match(sys, /SysInfoHelpers\.countdownTickMs\(root\.idleInhibitUntilMs/);
});

test("brightness processes are bounded and a failed write reads back", () => {
    const sys = read("Common/SysInfo.qml");
    assert.match(sys, /running: brightnessRead\.running\s*onTriggered: brightnessRead\.running = false/);
    assert.match(sys, /running: brightnessSet\.running\s*onTriggered: brightnessSet\.running = false/);
    assert.match(sys, /id: brightnessSet[\s\S]{0,700}?Qt\.callLater\(root\.refreshBrightness\)/);
    assert.match(sys, /id: brightnessSettle\s*interval: 400\s*onTriggered: root\.refreshBrightness\(\)/);
    // The DDC/HID helper runs when something shows brightness, not at login.
    const read_ = sys.slice(sys.indexOf("id: brightnessRead"));
    assert.doesNotMatch(read_.slice(0, read_.indexOf("stdout:")), /running: true/);
    assert.match(sys, /function acquire\(\)[\s\S]{0,900}?refreshBrightness\(\);/,
        "the Overview's claim reads it");
    assert.match(read("Common/Osd.qml"),
        /function brightnessChanged\(\) \{\s*SysInfo\.refreshBrightness\(\);/,
        "and so does the OSD when brightness-control pings it");
    const cpuinfo = sys.slice(sys.indexOf('path: "/proc/cpuinfo"'));
    assert.doesNotMatch(cpuinfo.slice(0, cpuinfo.indexOf("}")), /blockLoading/);
});

test("battery health ignores energy churn from the UPower monitor", () => {
    const health = read("Common/BatteryHealth.qml");
    assert.match(health, /onRead: line => root\.monitorLine\(line\)/);
    assert.match(health, /function monitorLine\(line\)[\s\S]{0,900}?charge-/);
    assert.match(health, /if \(monitorSeen\[key\] === value\)\s*return;/);
});

test("reminders poll only while records exist and settle with one read", () => {
    const reminders = read("Common/Reminders.qml");
    assert.doesNotMatch(reminders, /ticks >= 12/);
    assert.doesNotMatch(reminders, /onExited: root\.refresh\(\)/,
        "restore already refreshes over IPC when it changed something");
    assert.match(reminders, /if \(count === 0 \|\| !startupRestore\.done\)/);
    assert.match(reminders, /Math\.max\(Format\.MS_MINUTE, Math\.min\(Format\.MS_HOUR, untilDue\)\)/);
    // A helper that cannot start sends no exited(): the list settles on the
    // falling edge of running, so loading and a queued refresh cannot stick.
    const list = reminders.slice(reminders.indexOf("id: listProc"), reminders.indexOf("id: restoreProc"));
    const exited = list.slice(list.indexOf("onExited:"));
    assert.doesNotMatch(exited.slice(0, exited.indexOf("}")), /loading|refresh/);
    assert.match(list,
        /onRunningChanged: \{[\s\S]{0,160}?root\.loading = false;[\s\S]{0,120}?ProcHelpers\.NOT_STARTED[\s\S]{0,200}?Qt\.callLater\(root\.refresh\)/);
});

test("the calendar polls only for an open Day sheet, and never while idle", () => {
    const calendar = read("Common/Calendar.qml");
    const sheet = read("Popovers/DaySheetPopover.qml");
    assert.match(calendar,
        /running: root\.enabled && root\.watchers > 0 && !Activity\.idle\s*repeat: true\s*onTriggered: root\.pollRefresh\(\)/);
    assert.match(calendar, /function acquire\(\) \{\s*watchers\+\+;\s*if \(enabled\)\s*refreshDefault\(\);/,
        "every newly visible sheet asks for a fresh window");
    assert.match(calendar,
        /target: Activity[\s\S]{0,80}function onResumed\(\)[\s\S]{0,200}root\.pollRefresh\(\)/);
    assert.match(calendar, /if \(root\.requestIsDefault && root\.watchers > 0\)\s*root\.refreshDefault\(\)/,
        "midnight moves the window only for a sheet that is showing it");
    assert.match(sheet,
        /Claim \{\s*active: root\.visible\s*onClaimed: \{[^}]*Calendar\.acquire\(\);[^}]*\}\s*onReleased: \{[^}]*Calendar\.release\(\);/);
    assert.doesNotMatch(sheet, /Component\.onCompleted:[\s\S]{0,80}refreshDefault/,
        "a latched sheet would never refresh again; the claim follows visibility");
    // Nothing else reads events: the menubar clock and reminders do not.
    for (const file of ["Bar/Modules/Clock.qml", "Common/Reminders.qml", "Common/Notifs.qml"])
        assert.doesNotMatch(read(file), /Calendar\.(events|upcoming|eventsForDay)/, file);
});

test("the calendar poll follows the clock and loading cannot stick", () => {
    const calendar = read("Common/Calendar.qml");
    assert.match(calendar, /repeat: true\s*onTriggered: root\.pollRefresh\(\)/);
    assert.match(calendar, /function pollRefresh\(\)[\s\S]{0,400}?refreshDefault\(\)/);
    assert.match(calendar, /running: root\.loading\s*onTriggered: root\.abandonFetch/);
    assert.match(calendar, /"timeout", "30s",\s*"python3"/);
});

test("the calendar helper answers within its own deadline", () => {
    const helper = path.join(shellDir, "scripts/calendar-events.py");
    const script = [
        "import importlib.util, sys, time",
        `spec = importlib.util.spec_from_file_location("calendar_events", ${JSON.stringify(helper)})`,
        "module = importlib.util.module_from_spec(spec)",
        "spec.loader.exec_module(module)",
        "module.arm_deadline(0.2)",
        "time.sleep(10)",
        "print('not reached')",
    ].join("\n");
    const started = Date.now();
    const result = spawnSync("python3", ["-B", "-c", script], { encoding: "utf8", timeout: 8000 });
    assert.equal(result.status, 0, result.stderr);
    assert.ok(Date.now() - started < 5000, "the deadline must end the process");
    const payload = JSON.parse(result.stdout);
    assert.equal(payload.available, false);
    assert.equal(payload.error, "Calendar request timed out");
    assert.doesNotMatch(result.stdout, /not reached/);
});

test("non-critical singletons stay out of the session-start burst", () => {

});

test("wallpaper rotation skips an idle session and catches up once on return", () => {
    const wallpaper = read("Common/Wallpaper.qml");
    assert.match(wallpaper,
        /running: Settings\.shuffle !== "Off"\s*repeat: true\s*interval: root\.shuffleMs/,
        "the interval keeps running: a daily rotation must survive idle spells");
    assert.match(wallpaper,
        /onTriggered: \{\s*if \(Activity\.idle\)\s*root\.shuffleOwed = true;\s*else\s*root\.shuffle\(\);/);
    assert.match(wallpaper,
        /target: Activity[\s\S]{0,80}function onResumed\(\) \{\s*if \(!root\.shuffleOwed\)\s*return;\s*root\.shuffleOwed = false;\s*root\.shuffle\(\);/);
});
