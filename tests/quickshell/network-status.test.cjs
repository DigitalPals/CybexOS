const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { shellDir, load } = require("./shell.cjs");

const H = load("NetworkStatusHelpers.js");

function read(relative) {
    return fs.readFileSync(path.join(shellDir, relative), "utf8");
}

test("only NetworkManager's global connected state is online", () => {
    assert.equal(H.onlineState("connected\n"), true);
    assert.equal(H.onlineState("connected (global)"), true);
    assert.equal(H.onlineState("connecting"), false);
    assert.equal(H.onlineState("connected (local only)"), false);
    assert.equal(H.onlineState("connected (site only)"), false);
    assert.equal(H.onlineState("disconnected"), false);
    assert.equal(H.onlineState("surprising future state"), null);
    assert.equal(H.onlineState(undefined), null);
});

test("one monitored NetworkManager snapshot drives online work", () => {
    const status = read("Common/NetworkStatus.qml");

    // Untranslated output comes from the process environment, not from an
    // extra `env` process per NetworkManager event.
    assert.match(status,
        /command: \["timeout", "5s", "nmcli", "--terse",[\s\S]*?"STATE", "general", "status"\][\s\S]{0,400}?environment: \(\{ LC_ALL: "C" \}\)/);
    assert.match(status, /command: \["nmcli", "monitor"\]\s*\/\/ qmllint disable incompatible-type\s*environment: \(\{ LC_ALL: "C" \}\)/);
    const ethernet = read("Common/EthernetState.qml");
    const updates = read("Common/Updates.qml");
    for (const [label, text] of [["NetworkStatus", status], ["EthernetState", ethernet],
        ["Updates", updates]])
        assert.doesNotMatch(text, /"env", "LC_ALL=C"/, `${label} must not wrap commands in env`);
    assert.match(ethernet, /"device", "show"\][\s\S]{0,400}?environment: \(\{ LC_ALL: "C" \}\)/);
    for (const binary of ["dnf", "flatpak", "fwupdmgr"])
        assert.match(updates, new RegExp(`command: \\["timeout", "45s", "${binary}",[^\\]]*\\][\\s\\S]{0,400}?environment: \\(\\{ LC_ALL: "C" \\}\\)`));
    assert.match(status,
        /onRead: line => \{\s*snapshotDebounce\.restart\(\);\s*root\.monitorEvent\(line\);/);
    assert.match(status, /signal monitorEvent\(string line\)/);
    assert.match(status, /Component\.onCompleted: refresh\(\)/);
    // The safety poll only runs while the event stream is down, and the
    // monitor reattaches with backoff rather than every five seconds.
    assert.match(status, /interval: 30000\s*running: !root\.monitorRunning/);
    assert.match(status,
        /monitorRestart\.interval = NetworkStatusHelpers\.monitorRestartDelay\(shortRuns\)/);
});

test("a single failed status read does not flip the online state", () => {
    assert.equal(H.FAILURES_BEFORE_UNKNOWN, 2);
    assert.equal(H.holdsKnownState(true, 1), true);
    assert.equal(H.holdsKnownState(true, 2), false);
    assert.equal(H.holdsKnownState(true, 5), false);
    // Nothing to hold before the first successful read.
    assert.equal(H.holdsKnownState(false, 1), false);

    const status = read("Common/NetworkStatus.qml");
    assert.match(status,
        /failures\+\+;[\s\S]{0,300}if \(NetworkStatusHelpers\.holdsKnownState\(known, failures\)\)\s*\{\s*confirmRetry\.restart\(\);\s*return;/);
    assert.match(status, /if \(next !== null\) \{\s*failures = 0;/);
});

test("monitor restarts back off from 5 s to 60 s and reset after a healthy run", () => {
    let runs = 0;
    const delays = [];
    for (let i = 0; i < 7; i++) {
        runs = H.monitorShortRuns(runs, 200);
        delays.push(H.monitorRestartDelay(runs));
    }
    assert.deepEqual(delays, [5000, 10000, 20000, 40000, 60000, 60000, 60000]);

    runs = H.monitorShortRuns(runs, H.MONITOR_HEALTHY_RUN_MS);
    assert.equal(runs, 1);
    assert.equal(H.monitorRestartDelay(runs), 5000);
    assert.equal(H.monitorShortRuns(0, NaN), 1);
    assert.equal(H.monitorRestartDelay(0), 5000);
    assert.equal(H.monitorRestartDelay(1000), 60000);
});

test("weather and update startup checks wait for the shared online edge", () => {
    const weather = read("Common/Weather.qml");
    const updates = read("Common/Updates.qml");

    assert.match(weather,
        /target: NetworkStatus[\s\S]*?function onOnlineChanged\(\)[\s\S]*?root\.refresh\(\)/);
    assert.match(weather, /running: NetworkStatus\.online/);
    assert.match(weather,
        /Component\.onCompleted:\s*\{[\s\S]*?if \(NetworkStatus\.online && wanted\)[\s\S]*?refresh\(\)/,
        "the startup fallback must retain the same online guard as the shared edge");

    assert.match(updates,
        /target: NetworkStatus[\s\S]*?function onOnlineChanged\(\)[\s\S]*?root\.automaticCheck\(true, false\)/);
    assert.match(updates,
        /function automaticCheck\(resetRetries, failedOnly\)\s*\{[\s\S]*?if \(!NetworkStatus\.online\)[\s\S]*?return;/,
        "all automatic startup paths must fail closed while offline");
    assert.match(updates, /checkFailureCount <= 4[\s\S]*?NetworkStatus\.online/);
});
