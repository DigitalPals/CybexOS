const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const helper = path.resolve(__dirname, "../../assets/scripts/quickshell-reminder");

function executable(file, source) {
    fs.writeFileSync(file, source, { mode: 0o755 });
}

function fixture() {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), "quickshell-reminder-"));
    const bin = path.join(root, "bin");
    const state = path.join(root, "state");
    const active = path.join(root, "active");
    fs.mkdirSync(bin);
    fs.mkdirSync(active);

    executable(path.join(bin, "systemd-run"), `#!/usr/bin/env bash
set -euo pipefail
printf 'CALL\\0' >> "$MOCK_SYSTEMD_LOG"
printf '%s\\0' "$@" >> "$MOCK_SYSTEMD_LOG"
printf '\\n' >> "$MOCK_SYSTEMD_LOG"
for arg in "$@"; do
  if [[ $arg == --unit=* ]]; then
    unit=\${arg#--unit=}
    : > "$MOCK_ACTIVE_DIR/$unit.timer"
  fi
done
`);
    executable(path.join(bin, "systemctl"), `#!/usr/bin/env bash
set -euo pipefail
if [[ " $* " == *" is-active "* ]]; then
  unit=\${!#}
  [[ -f "$MOCK_ACTIVE_DIR/$unit" ]]
  exit
fi
for arg in "$@"; do
  [[ $arg == *.timer || $arg == *.service ]] && rm -f -- "$MOCK_ACTIVE_DIR/$arg"
done
`);
    executable(path.join(bin, "notify-send"), `#!/usr/bin/env bash
set -euo pipefail
printf '%s\\0' "$@" > "$MOCK_NOTIFY_LOG"
[[ \${MOCK_NOTIFY_FAIL:-0} != 1 ]]
`);
    // The shell runs by path, so the refresh must go through the runtime
    // resolver; a bare qs is recorded only to prove nothing calls it.
    executable(path.join(bin, "qs"), `#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >> "$MOCK_QS_LOG"
`);
    const home = path.join(root, "home");
    fs.mkdirSync(path.join(home, ".local/bin"), { recursive: true });
    executable(path.join(home, ".local/bin/cybexos-runtime"), `#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >> "$MOCK_RUNTIME_LOG"
`);

    const env = {
        ...process.env,
        HOME: home,
        PATH: `${bin}:${process.env.PATH}`,
        QUICKSHELL_REMINDER_STATE_DIR: state,
        MOCK_ACTIVE_DIR: active,
        MOCK_SYSTEMD_LOG: path.join(root, "systemd.log"),
        MOCK_NOTIFY_LOG: path.join(root, "notify.log"),
        MOCK_QS_LOG: path.join(root, "qs.log"),
        MOCK_RUNTIME_LOG: path.join(root, "runtime.log")
    };
    return { root, bin, state, active, env };
}

function run(f, args, extraEnv = {}) {
    const result = spawnSync(helper, args, {
        env: { ...f.env, ...extraEnv }, encoding: "utf8"
    });
    return result;
}

function ok(result) {
    assert.equal(result.status, 0, result.stderr || result.stdout);
    return result.stdout.trim();
}

function list(f) {
    return JSON.parse(ok(run(f, ["list", "--json"])));
}

test("add stores safely quoted canonical JSON and list sorts by due time", () => {
    const f = fixture();
    const marker = path.join(f.root, "must-not-exist");
    const message = `quote " dollar $(touch ${marker}) and ' apostrophe`;
    const later = ok(run(f, ["add", "15", message]));
    const sooner = ok(run(f, ["add", "5", "Sooner"]));
    const records = list(f);

    assert.deepEqual(records.map(record => record.id), [sooner, later]);
    assert.equal(records[1].message, message);
    assert.equal(records[1].minutes, 15);
    assert.equal(fs.existsSync(marker), false, "message content must never be evaluated by a shell");
    assert.deepEqual(fs.readdirSync(f.state).filter(name => name.startsWith(".")), [],
        "atomic temporary records must be renamed away");

    const log = fs.readFileSync(f.env.MOCK_SYSTEMD_LOG, "utf8");
    assert.match(log, /--on-calendar=@\d+/);
    assert.match(log, /--timer-property=Persistent=true/);
    assert.match(log, /--timer-property=AccuracySec=1s/);
});

test("cancel and clear remove records and their named timer units", () => {
    const f = fixture();
    const first = ok(run(f, ["add", "5", "First"]));
    const second = ok(run(f, ["add", "15", "Second"]));
    ok(run(f, ["cancel", first]));
    assert.deepEqual(list(f).map(record => record.id), [second]);
    assert.equal(fs.existsSync(path.join(f.active, `quickshell-reminder-${first}.timer`)), false);
    ok(run(f, ["clear"]));
    assert.deepEqual(list(f), []);
    assert.equal(fs.existsSync(path.join(f.active, `quickshell-reminder-${second}.timer`)), false);
});

test("fire deletes only after successful notification delivery", () => {
    const f = fixture();
    const message = `safe "message" with $ and ' characters`;
    const delivered = ok(run(f, ["add", "5", message]));
    ok(run(f, ["fire", delivered]));
    assert.deepEqual(list(f), []);
    const argv = fs.readFileSync(f.env.MOCK_NOTIFY_LOG).toString().split("\0").filter(Boolean);
    assert.deepEqual(argv.slice(-2), ["Reminder", message]);

    const retained = ok(run(f, ["add", "5", "Retry me"]));
    const failed = run(f, ["fire", retained], { MOCK_NOTIFY_FAIL: "1" });
    assert.notEqual(failed.status, 0);
    assert.equal(list(f)[0].id, retained,
        "failed delivery must retain the canonical record for restore");
});

test("restore recreates missing timers and delivers overdue records", () => {
    const f = fixture();
    const future = ok(run(f, ["add", "30", "Future"]));
    const timer = path.join(f.active, `quickshell-reminder-${future}.timer`);
    fs.rmSync(timer);
    ok(run(f, ["restore"]));
    assert.equal(fs.existsSync(timer), true, "a missing transient timer must be restored");

    const overdue = ok(run(f, ["add", "5", "Overdue after login"]));
    const file = path.join(f.state, `${overdue}.json`);
    const record = JSON.parse(fs.readFileSync(file, "utf8"));
    record.due = Math.floor(Date.now() / 1000) - 10;
    fs.writeFileSync(file, JSON.stringify(record));
    fs.rmSync(path.join(f.active, `quickshell-reminder-${overdue}.timer`));
    ok(run(f, ["restore"]));
    assert.equal(fs.existsSync(file), false, "overdue state should be delivered immediately");
    assert.deepEqual(list(f).map(item => item.id), [future]);
});

test("failed overdue delivery remains available for a later restore retry", () => {
    const f = fixture();
    const id = ok(run(f, ["add", "5", "Still pending"]));
    const file = path.join(f.state, `${id}.json`);
    const record = JSON.parse(fs.readFileSync(file, "utf8"));
    record.due = Math.floor(Date.now() / 1000) - 1;
    fs.writeFileSync(file, JSON.stringify(record));
    const failed = run(f, ["restore"], { MOCK_NOTIFY_FAIL: "1" });
    assert.notEqual(failed.status, 0);
    assert.equal(fs.existsSync(file), true);
});

function writeRecord(f, id, fields) {
    fs.mkdirSync(f.state, { recursive: true });
    fs.writeFileSync(path.join(f.state, `${id}.json`), JSON.stringify({
        id, minutes: 5, message: "Due", created: 0,
        due: Math.floor(Date.now() / 1000) - 10, ...fields
    }));
}

function logLines(file) {
    return fs.existsSync(file)
        ? fs.readFileSync(file, "utf8").split("\n").filter(Boolean)
        : [];
}

function shellCalls(f) {
    assert.deepEqual(logLines(f.env.MOCK_QS_LOG), [],
        "a bare qs ipc call finds no configuration for the path-run shell");
    return logLines(f.env.MOCK_RUNTIME_LOG);
}

test("one unreadable overdue record does not end the restore pass", t => {
    const f = fixture();
    t.after(() => fs.rmSync(f.root, { recursive: true, force: true }));
    writeRecord(f, "a-broken", { message: 42 });
    writeRecord(f, "b-deliverable", { message: "Later record" });
    writeRecord(f, "c-future", { due: Math.floor(Date.now() / 1000) + 3600 });

    const result = run(f, ["restore"]);
    assert.notEqual(result.status, 0, "the unreadable record is still reported");
    assert.equal(fs.existsSync(path.join(f.state, "a-broken.json")), true);
    assert.equal(fs.existsSync(path.join(f.state, "b-deliverable.json")), false,
        "records after a failing one must still be delivered");
    assert.equal(fs.existsSync(path.join(f.active, "quickshell-reminder-c-future.timer")),
        true, "records after a failing one must still be rescheduled");
    assert.deepEqual(shellCalls(f), ["ipc reminders refresh"],
        "a restore that changed something tells the shell exactly once");
});

test("restore with nothing to do does not call back into the shell", t => {
    const f = fixture();
    t.after(() => fs.rmSync(f.root, { recursive: true, force: true }));
    ok(run(f, ["add", "30", "Future"]));
    fs.rmSync(f.env.MOCK_RUNTIME_LOG, { force: true });
    ok(run(f, ["restore"]));
    assert.deepEqual(shellCalls(f), []);
});

test("fire keeps its exit codes as a command", t => {
    const f = fixture();
    t.after(() => fs.rmSync(f.root, { recursive: true, force: true }));
    assert.equal(run(f, ["fire", "bad id!"]).status, 2);
    assert.equal(run(f, ["fire", "missing"]).status, 0,
        "an already-removed record is done");
    writeRecord(f, "unreadable", { message: null });
    assert.equal(run(f, ["fire", "unreadable"]).status, 1);
});

test("clear refreshes the shell once, not once per record", t => {
    const f = fixture();
    t.after(() => fs.rmSync(f.root, { recursive: true, force: true }));
    for (const minutes of ["5", "10", "15"])
        ok(run(f, ["add", minutes, "Batch"]));
    fs.rmSync(f.env.MOCK_RUNTIME_LOG, { force: true });
    ok(run(f, ["clear"]));
    assert.deepEqual(list(f), []);
    assert.deepEqual(shellCalls(f), ["ipc reminders refresh"]);
});
