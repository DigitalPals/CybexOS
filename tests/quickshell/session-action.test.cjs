const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { shellDir } = require("./shell.cjs");

const helper = path.resolve(shellDir, "../cybexos-session-action");

// `locker` is what the lock unit does once started: "locks" (hyprctl reports
// the session locked after `lockDelay` more queries), "hangs" (the unit stays
// active and never locks), or "exits" (the unit is not active).
function fixture({ initiallyLocked = false, locker = "locks", lockDelay = 0,
        onBattery = "b false", lockedHint = "no" } = {}) {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), "cybexos-session-action."));
    const bin = path.join(root, "bin");
    const state = path.join(root, "locked");
    const pending = path.join(root, "pending");
    const queries = path.join(root, "queries");
    const log = path.join(root, "calls");
    fs.mkdirSync(bin);
    if (initiallyLocked) fs.writeFileSync(state, "");

    // Queries are counted apart from the call log, so tests can assert that
    // nothing with an effect ran without listing every poll.
    fs.writeFileSync(path.join(bin, "hyprctl"), `#!/usr/bin/env bash
if [[ $1 == locked ]]; then
  printf 'x' >> "$TEST_QUERIES"
  if [[ ! -f $TEST_STATE && -f $TEST_PENDING ]]; then
    left=$(<"$TEST_PENDING")
    if ((left <= 0)); then : > "$TEST_STATE"; else printf '%s\\n' $((left - 1)) > "$TEST_PENDING"; fi
  fi
  [[ -f $TEST_STATE ]] && printf 'true\\n' || printf 'false\\n'
  exit 0
fi
printf 'hyprctl %s\\n' "$*" >> "$TEST_LOG"
`);
    fs.writeFileSync(path.join(bin, "loginctl"), `#!/usr/bin/env bash
printf '%s\\n' "$TEST_LOCKED_HINT"
`);
    fs.writeFileSync(path.join(bin, "systemctl"), `#!/usr/bin/env bash
printf 'systemctl %s\\n' "$*" >> "$TEST_LOG"
if [[ $* == *'start cybexos-session-lock.service'* && $TEST_LOCKER == locks ]]; then
  printf '%s\\n' "$TEST_LOCK_DELAY" > "$TEST_PENDING"
fi
if [[ $* == *'is-active'* ]]; then
  [[ $TEST_LOCKER != exits ]]
fi
`);
    fs.writeFileSync(path.join(bin, "busctl"), `#!/usr/bin/env bash
printf 'busctl %s\\n' "$*" >> "$TEST_LOG"
[[ -n $TEST_ON_BATTERY ]] || exit 1
printf '%s\\n' "$TEST_ON_BATTERY"
`);
    fs.writeFileSync(path.join(bin, "sleep"), "#!/usr/bin/env bash\nexit 0\n");
    for (const name of fs.readdirSync(bin)) fs.chmodSync(path.join(bin, name), 0o755);

    return {
        root,
        run(action, ...args) {
            return spawnSync("bash", [helper, action, ...args], {
                encoding: "utf8",
                env: {
                    ...process.env,
                    PATH: `${bin}:${process.env.PATH}`,
                    TEST_STATE: state,
                    TEST_PENDING: pending,
                    TEST_QUERIES: queries,
                    TEST_LOG: log,
                    TEST_LOCKER: locker,
                    TEST_LOCK_DELAY: String(lockDelay),
                    TEST_LOCKED_HINT: lockedHint,
                    TEST_ON_BATTERY: onBattery
                }
            });
        },
        calls() { return fs.existsSync(log) ? fs.readFileSync(log, "utf8") : ""; },
        queries() { return fs.existsSync(queries) ? fs.readFileSync(queries, "utf8").length : 0; },
        locked() { return fs.existsSync(state); }
    };
}

test("an already locked session does not start a second locker", t => {
    const f = fixture({ initiallyLocked: true });
    t.after(() => fs.rmSync(f.root, { recursive: true, force: true }));
    const result = f.run("lock");
    assert.equal(result.status, 0, result.stderr);
    assert.equal(f.calls(), "");
});

test("suspend happens only after the singleton locker reports ready", t => {
    const f = fixture();
    t.after(() => fs.rmSync(f.root, { recursive: true, force: true }));
    const result = f.run("suspend");
    assert.equal(result.status, 0, result.stderr);
    const calls = f.calls();
    assert.ok(calls.indexOf("start cybexos-session-lock.service") >= 0);
    assert.ok(calls.indexOf("systemctl suspend") > calls.indexOf("start cybexos-session-lock.service"));
});

test("suspend waits for hyprctl to report the session locked", t => {
    const f = fixture({ lockDelay: 5 });
    t.after(() => fs.rmSync(f.root, { recursive: true, force: true }));
    const result = f.run("suspend");
    assert.equal(result.status, 0, result.stderr);
    assert.ok(f.locked());
    assert.ok(f.queries() >= 7, "the helper polled until the lock was reported");
    const calls = f.calls();
    assert.ok(calls.indexOf("systemctl suspend") > calls.indexOf("start cybexos-session-lock.service"));
});

test("a stale logind LockedHint does not skip the lock before suspend", t => {
    const f = fixture({ lockedHint: "yes" });
    t.after(() => fs.rmSync(f.root, { recursive: true, force: true }));
    const result = f.run("suspend");
    assert.equal(result.status, 0, result.stderr);
    const calls = f.calls();
    assert.ok(calls.indexOf("start cybexos-session-lock.service") >= 0);
    assert.ok(calls.indexOf("systemctl suspend") > calls.indexOf("start cybexos-session-lock.service"));
});

test("a failed lock leaves the machine awake", t => {
    const f = fixture({ locker: "exits" });
    t.after(() => fs.rmSync(f.root, { recursive: true, force: true }));
    const result = f.run("suspend");
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /lock screen exited/);
    assert.doesNotMatch(f.calls(), /systemctl suspend/);
});

test("a lock screen that never confirms is left running and the machine stays awake", t => {
    for (const action of ["lock", "suspend"]) {
        const f = fixture({ locker: "hangs" });
        t.after(() => fs.rmSync(f.root, { recursive: true, force: true }));
        const result = f.run(action);
        assert.equal(result.status, 1);
        assert.match(result.stderr, /did not secure the session/);
        const calls = f.calls();
        assert.match(calls, /start cybexos-session-lock\.service/);
        assert.doesNotMatch(calls, /stop|kill/, "the only safe failure is to stay locked");
        assert.doesNotMatch(calls, /systemctl suspend/);
    }
});

test("log out asks Hyprland's Lua config for its exit dispatcher", t => {
    const f = fixture();
    t.after(() => fs.rmSync(f.root, { recursive: true, force: true }));
    const result = f.run("logout");
    assert.equal(result.status, 0, result.stderr);
    assert.equal(f.calls(), "hyprctl dispatch hl.dsp.exit()\n");
});

test("unknown actions fail without invoking a session command", t => {
    const f = fixture();
    t.after(() => fs.rmSync(f.root, { recursive: true, force: true }));
    const result = f.run("hibernate");
    assert.equal(result.status, 2);
    assert.match(result.stderr, /Usage:/);
    assert.equal(f.calls(), "");
});

test("idle suspend locks first and ignores the power source by default", t => {
    const f = fixture();
    t.after(() => fs.rmSync(f.root, { recursive: true, force: true }));
    const result = f.run("idle-suspend");
    assert.equal(result.status, 0, result.stderr);
    const calls = f.calls();
    assert.doesNotMatch(calls, /busctl/);
    assert.ok(calls.indexOf("systemctl suspend") > calls.indexOf("start cybexos-session-lock.service"));
});

test("battery-only idle suspend stays awake on mains or an unknown source", t => {
    for (const onBattery of ["b false", ""]) {
        const f = fixture({ onBattery });
        t.after(() => fs.rmSync(f.root, { recursive: true, force: true }));
        const result = f.run("idle-suspend", "on-battery");
        assert.equal(result.status, 0, result.stderr);
        assert.match(f.calls(), /busctl --system --timeout=2 get-property org\.freedesktop\.UPower/);
        assert.doesNotMatch(f.calls(), /systemctl/);
    }
});

test("battery-only idle suspend suspends on battery power", t => {
    const f = fixture({ onBattery: "b true" });
    t.after(() => fs.rmSync(f.root, { recursive: true, force: true }));
    const result = f.run("idle-suspend", "on-battery");
    assert.equal(result.status, 0, result.stderr);
    assert.match(f.calls(), /systemctl suspend/);
});

test("the on-battery condition answers without locking or suspending", t => {
    for (const [onBattery, status] of [["b true", 0], ["b false", 1], ["", 1]]) {
        const f = fixture({ onBattery });
        t.after(() => fs.rmSync(f.root, { recursive: true, force: true }));
        const result = f.run("on-battery");
        assert.equal(result.status, status, `${onBattery || "no answer"}: ${result.stderr}`);
        assert.doesNotMatch(f.calls(), /systemctl|hyprctl/);
        assert.equal(f.queries(), 0);
    }
});

test("idle suspend rejects an unknown condition without suspending", t => {
    const f = fixture();
    t.after(() => fs.rmSync(f.root, { recursive: true, force: true }));
    const result = f.run("idle-suspend", "always");
    assert.equal(result.status, 2);
    assert.match(result.stderr, /Usage:/);
    assert.equal(f.calls(), "");
});
