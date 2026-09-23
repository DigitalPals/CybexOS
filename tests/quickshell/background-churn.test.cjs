// Background work that runs whether or not anyone is looking: polls, retries,
// monitors and the session-start burst. Pure rules run here; the QML wiring
// that has no Node surface is pinned by source contracts.
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { shellDir, load } = require("./shell.cjs");

const U = load("UpdatesHelpers.js");
const S = load("SysInfoHelpers.js");

function read(relative) {
    return fs.readFileSync(path.join(shellDir, relative), "utf8");
}

test("dnf progress tokens find their pending row without scanning the feed", () => {
    const pending = {};
    U.addPendingRow(pending, "less", "0:704-4.fc44", 0);
    U.addPendingRow(pending, "less-color", "0:704-4.fc44", 1);
    U.addPendingRow(pending, "SDL3", "0:3.2.22-1.fc44", 2);
    U.addPendingRow(pending, "SDL3", "0:3.2.22-1.fc44", 3);
    U.addPendingRow(pending, "averyveryverylongpackagename", "0:1-1.fc44", 4);

    assert.equal(U.takePendingRow(pending, "less-color-0:704-4.fc"), 1);
    assert.equal(U.takePendingRow(pending, "less-0:704-4.fc44.x86"), 0);
    assert.equal(U.takePendingRow(pending, "less-0:704-4.fc44.x86"), -1,
        "a row is marked done once");
    assert.equal(U.takePendingRow(pending, "SDL3-0:3.2.22-1.fc44.i686"), 2,
        "multilib rows complete in table order");
    assert.equal(U.takePendingRow(pending, "SDL3-0:3.2.22-1.fc44.x86_64"), 3);
    assert.equal(U.takePendingRow(pending, "averyveryverylongpa"), 4,
        "a token clipped inside the name still falls back to a scan");
    assert.deepEqual(pending, {});
});

test("cleanup of an outgoing version matches nothing", () => {
    const pending = {};
    U.addPendingRow(pending, "tmux", "0:3.7c-1.fc44", 0);
    assert.equal(U.takePendingRow(pending, "tmux-0:3.7b-2.fc44.x86"), -1);
    assert.equal(U.takePendingRow(pending, ""), -1);
    assert.equal(U.takePendingRow(pending, "tmux-0:3.7c-1.fc44.x86_64"), 0);
});

test("a finished run rechecks once and retries only a failed or inconsistent count", () => {
    assert.equal(U.postRunRetryNeeded(true, "done", 0, 0, true), false);
    assert.equal(U.postRunRetryNeeded(false, "done", 0, 0, true), true);
    assert.equal(U.postRunRetryNeeded(true, "done", 3, 0, true), true,
        "a successful upgrade still listing packages is worth one retry");
    assert.equal(U.postRunRetryNeeded(true, "done", 0, 2, false), false,
        "Flatpak was not part of this run");
    assert.equal(U.postRunRetryNeeded(true, "failed", 5, 0, true), false,
        "a failed run leaves packages pending by design");

    const updates = read("Common/Updates.qml");
    assert.doesNotMatch(updates, /ticks > 15/, "no fifteen-minute recheck loop");
    const recheck = updates.slice(updates.indexOf("id: recheck"));
    assert.doesNotMatch(recheck.slice(0, recheck.indexOf("}")), /repeat: true/);
});

test("an online edge does not repeat a fresh complete update check", () => {
    assert.equal(U.checkIsFresh(0, 1000, 600000), false);
    assert.equal(U.checkIsFresh(1000, 1000 + 599999, 600000), true);
    assert.equal(U.checkIsFresh(1000, 1000 + 600000, 600000), false);
    assert.equal(U.checkIsFresh(5000, 1000, 600000), false,
        "a clock moved backwards is not fresh");

    const updates = read("Common/Updates.qml");
    assert.match(updates,
        /function onOnlineChanged\(\)[\s\S]{0,500}?root\.error !== ""[\s\S]{0,120}?checkIsFresh/);
    const weather = read("Common/Weather.qml");
    assert.match(weather,
        /function onOnlineChanged\(\)[\s\S]{0,500}?!root\.stale\(600000\)/);
    assert.match(weather, /function stale\(maxAgeMs\) \{[\s\S]{0,200}?Date\.now\(\) - updatedAt >= maxAgeMs/);
});

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
    assert.match(sheet, /if \(!Weather\.locationSet\)\s*return "Set a location in Settings";/);
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
    const result = spawnSync("python3", ["-c", script], { encoding: "utf8", timeout: 8000 });
    assert.equal(result.status, 0, result.stderr);
    assert.ok(Date.now() - started < 5000, "the deadline must end the process");
    const payload = JSON.parse(result.stdout);
    assert.equal(payload.available, false);
    assert.equal(payload.error, "Calendar request timed out");
    assert.doesNotMatch(result.stdout, /not reached/);
});

test("non-critical singletons stay out of the session-start burst", () => {
    const usage = read("Common/Usage.qml");
    assert.match(usage, /id: startupWarmUp\s*interval: 5000/);
    assert.match(usage, /if \(source !== "direct"\)\s*root\.checkManagementKey/);
    const updates = read("Common/Updates.qml");
    assert.match(updates, /id: startupCheck\s*interval: 20000/);
    assert.match(updates, /Component\.onCompleted: \{\s*initialized = true;\s*startupCheck\.start\(\);\s*refreshRunStatus\(\);/);
    const calendar = read("Common/Calendar.qml");
    assert.match(calendar, /id: warmUp\s*interval: 12000/);
    const reminders = read("Common/Reminders.qml");
    assert.match(reminders, /id: startupRestore[\s\S]{0,80}?interval: 8000/);
    assert.match(reminders, /Component\.onCompleted: \{\s*refresh\(\);\s*startupRestore\.start\(\);/);
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
