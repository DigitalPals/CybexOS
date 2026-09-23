const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { shellDir } = require("./shell.cjs");

const helper = path.resolve(shellDir, "../cybexos-session-action");

function fixture({ initiallyLocked = false, lockStarts = true, onBattery = "b false" } = {}) {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), "cybexos-session-action."));
    const bin = path.join(root, "bin");
    const state = path.join(root, "locked");
    const log = path.join(root, "calls");
    fs.mkdirSync(bin);
    if (initiallyLocked) fs.writeFileSync(state, "yes\n");

    fs.writeFileSync(path.join(bin, "loginctl"), `#!/usr/bin/env bash
if [[ $1 == show-session ]]; then
  [[ -f $TEST_STATE ]] && cat "$TEST_STATE" || printf 'no\\n'
elif [[ $1 == show-user ]]; then
  printf 'test-session\\n'
fi
`);
    fs.writeFileSync(path.join(bin, "systemctl"), `#!/usr/bin/env bash
printf 'systemctl %s\\n' "$*" >> "$TEST_LOG"
if [[ $* == *'start cybexos-session-lock.service'* && $TEST_LOCK_STARTS == yes ]]; then
  printf 'yes\\n' > "$TEST_STATE"
fi
if [[ $* == *'is-active'* ]]; then
  [[ $TEST_LOCK_STARTS == yes ]]
fi
`);
    fs.writeFileSync(path.join(bin, "hyprctl"), `#!/usr/bin/env bash
printf 'hyprctl %s\\n' "$*" >> "$TEST_LOG"
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
                    XDG_SESSION_ID: "test-session",
                    TEST_STATE: state,
                    TEST_LOG: log,
                    TEST_LOCK_STARTS: lockStarts ? "yes" : "no",
                    TEST_ON_BATTERY: onBattery
                }
            });
        },
        calls() { return fs.existsSync(log) ? fs.readFileSync(log, "utf8") : ""; }
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

test("a failed lock leaves the machine awake", t => {
    const f = fixture({ lockStarts: false });
    t.after(() => fs.rmSync(f.root, { recursive: true, force: true }));
    const result = f.run("suspend");
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /lock screen exited/);
    assert.doesNotMatch(f.calls(), /systemctl suspend/);
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
        assert.match(f.calls(), /busctl --system get-property org\.freedesktop\.UPower/);
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

test("idle suspend rejects an unknown condition without suspending", t => {
    const f = fixture();
    t.after(() => fs.rmSync(f.root, { recursive: true, force: true }));
    const result = f.run("idle-suspend", "always");
    assert.equal(result.status, 2);
    assert.match(result.stderr, /Usage:/);
    assert.equal(f.calls(), "");
});
