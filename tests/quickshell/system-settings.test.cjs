const test = require("node:test");
const assert = require("node:assert/strict");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const vm = require("node:vm");
const { shellDir } = require("./shell.cjs");

test("system settings preserve profiles, roll back trials and validate changing device identities", () => {
    const result = spawnSync("python3", [path.join(__dirname, "../system-settings.py")], {
        encoding: "utf8", timeout: 30000,
        env: { ...process.env, PYTHONDONTWRITEBYTECODE: "1" },
    });
    assert.equal(result.status, 0, result.stdout + result.stderr);
});

function backend() {
    const source = fs.readFileSync(path.join(shellDir, "Common/SystemSettingsBackend.qml"), "utf8");
    const calls = [];
    const context = vm.createContext({
        watchers: 0, preview: null, busy: false, loading: false, revision: 0,
        refreshQueued: false, error: "", message: "",
        snapshotProc: { running: false, signal: value => calls.push(["stop-snapshot", value]) },
        actionProc: { running: false },
    });
    for (const name of ["acquire", "release", "refresh", "run", "decode"]) {
        const match = source.match(new RegExp(`^    function ${name}\\([^]*?^    }`, "m"));
        assert.ok(match, name);
        vm.runInContext(match[0], context);
    }
    return { context, calls };
}

test("settings service claims share reads and release a pending trial only after the last consumer", () => {
    const { context: c, calls } = backend();
    c.acquire();
    assert.equal(c.snapshotProc.running, true);
    c.acquire();
    c.preview = { checkpoint: "/trial" };
    c.release();
    assert.equal(c.actionProc.running, false);
    c.release();
    assert.equal(c.watchers, 0);
    assert.deepEqual(JSON.parse(JSON.stringify(c.request)), { action: "rollback", checkpoint: "/trial" });
    assert.deepEqual(calls, [["stop-snapshot", 15]]);
});

test("a trial blocks a second network edit and overlapping reads are queued", () => {
    const { context: c } = backend();
    c.preview = { checkpoint: "/trial" };
    assert.equal(c.run({ action: "apply" }), false);
    assert.equal(c.actionProc.running, false);
    assert.equal(c.run({ action: "confirm" }), true);
    c.loading = true;
    c.refresh();
    assert.equal(c.refreshQueued, true);
});

test("broken service output becomes a bounded error rather than a parser exception", () => {
    const { context: c } = backend();
    assert.equal(c.decode("not JSON", 0).success, false);
    for (const body of ["null", "[]", "42", '"text"', "{}"])
        assert.equal(c.decode(body, 0).success, false);
    assert.equal(c.decode('{"success":true}', 2).success, false);
    assert.equal(c.decode('{"success":true}', 0).success, true);
});
