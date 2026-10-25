const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const { shellDir } = require("./shell.cjs");

const source = fs.readFileSync(path.join(shellDir, "Common/OnlineWallpapers.qml"), "utf8");
const view = fs.readFileSync(path.join(shellDir, "Settings/WallpaperOnlineView.qml"), "utf8");

// The real probe functions against fake Process and Timer objects.
function harness() {
    const calls = [];
    const timer = {
        running: false,
        start() { this.running = true; calls.push("timer-start"); },
        restart() { this.running = true; calls.push("timer-restart"); },
        stop() { this.running = false; calls.push("timer-stop"); },
    };
    const proc = { _running: false, starts: 0 };
    Object.defineProperty(proc, "running", {
        get() { return this._running; },
        set(value) { if (value && !this._running) this.starts++; this._running = value; },
    });
    const context = vm.createContext({ meteringWatchers: 0, meteredKnown: true, metered: false,
        meteredThrottle: timer, meteredProc: proc });
    for (const name of ["autoLoadAllowed", "watchMetering", "unwatchMetering", "refreshMetered",
        "meteringEvent", "meteredTick"]) {
        const match = source.match(new RegExp(`^    function ${name}\\(.*\\{.*\\}$`, "m"))
            || source.match(new RegExp(`^    function ${name}\\([^]*?^    }`, "m"));
        assert.ok(match, name);
        vm.runInContext(match[0], context);
    }
    return { c: context, timer, proc, calls };
}

test("NetworkManager events cost nothing while no online view is watching", () => {
    const { c, proc, timer } = harness();
    for (let i = 0; i < 20; i++) c.meteringEvent();
    assert.equal(proc.starts, 0);
    assert.equal(timer.running, false);
    c.meteredTick();
    assert.equal(proc.starts, 0);
});

test("the first watcher probes once; a burst of events is one probe per throttle interval", () => {
    const { c, proc, timer } = harness();
    c.watchMetering();
    assert.equal(proc.starts, 1);
    c.watchMetering();
    assert.equal(proc.starts, 1, "a second view does not probe again");
    proc.running = false;
    for (let i = 0; i < 50; i++) c.meteringEvent();
    assert.equal(timer.running, true);
    assert.equal(proc.starts, 1, "events only arm the throttle");
    c.meteredTick();
    assert.equal(proc.starts, 2);
    proc.running = false;
    timer.running = false;
    c.meteringEvent();
    c.meteredTick();
    assert.equal(proc.starts, 3);
});

test("a known metering state is kept while a probe is in flight, and a busy probe defers the next", () => {
    const { c, proc, timer } = harness();
    c.watchMetering();
    assert.equal(c.meteredKnown, true);
    assert.equal(c.metered, false);
    assert.equal(c.autoLoadAllowed(), true, "welcome may still list while re-probing");
    c.refreshMetered();
    assert.equal(proc.starts, 1, "no overlapping probes");
    c.meteringEvent();
    c.meteredTick();
    assert.equal(proc.starts, 1);
    assert.equal(timer.running, true, "the follow-up probe is re-armed, not lost");
});

test("the last watcher leaving stops a pending probe and later events are ignored", () => {
    const { c, proc, timer } = harness();
    c.watchMetering();
    c.watchMetering();
    proc.running = false;
    c.meteringEvent();
    c.unwatchMetering();
    assert.equal(timer.running, true, "one view is still watching");
    c.unwatchMetering();
    assert.equal(c.meteringWatchers, 0);
    assert.equal(timer.running, false);
    c.unwatchMetering();
    assert.equal(c.meteringWatchers, 0, "never negative");
    c.meteringEvent();
    assert.equal(timer.running, false);
    assert.equal(proc.starts, 1);
});

test("the NetworkStatus connection is enabled only while watched, and only a view holds a watch", () => {
    assert.match(source, /Connections \{\s*target: NetworkStatus\s*enabled: root\.meteringWatchers > 0\s*function onMonitorEvent\(line\) \{ root\.meteringEvent\(\); \}/);
    assert.doesNotMatch(source, /onMonitorEvent\(line\) \{ root\.refreshMetered/);
    assert.match(source, /Timer \{\s*id: meteredThrottle\s*interval: 4000/);
    assert.doesNotMatch(source.match(/function refreshMetered\(\)[^]*?^    }/m)[0], /meteredKnown = false|metered = true/);
    assert.match(view, /Claim \{\s*active: root\.visible\s*onClaimed: OnlineWallpapers\.watchMetering\(\)\s*onReleased: OnlineWallpapers\.unwatchMetering\(\)/);
    assert.doesNotMatch(view, /refreshMetered/);
    for (const file of ["Settings/WallpaperPicker.qml", "Common/OnlineWallpapers.qml"])
        assert.doesNotMatch(fs.readFileSync(path.join(shellDir, file), "utf8"), /Component\.onCompleted:[^\n]*Metering/);
});
