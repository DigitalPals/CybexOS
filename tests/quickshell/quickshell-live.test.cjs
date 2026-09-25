const test = require("node:test");
const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const path = require("node:path");
const fs = require("node:fs");
const os = require("node:os");

const repoDir = path.resolve(__dirname, "../..");
const liveHelper = path.join(repoDir, "tests/lib/quickshell-live");

test("live process guard waits for IPC clients and only terminates developer instances", () => {
    for (const [command, expectedSignal] of [
        ["qs ipc --any-display -p /fixture/quickshell call wallpaper list", ""],
        ["qs -d -p /fixture/quickshell", "-TERM 222\n"],
    ]) {
        const directory = fs.mkdtempSync(path.join(os.tmpdir(), "cybexos-qs-process-test-"));
        try {
            fs.writeFileSync(path.join(directory, "state"), "live");
            fs.writeFileSync(path.join(directory, "signals"), "");
            const result = spawnSync("bash", ["-c", String.raw`
source "$1"
qs_live_main_pid() { echo 111; }
qs_live_control_group() { echo /fixture/quickshell.service; }
qs_live_pid_command() { echo "$QS_TEST_COMMAND"; }
qs_live_pid_cgroup() { echo /fixture/welcome.service; }
id() { echo 1000; }
ps() { echo 1000; }
pgrep() { echo 111; [[ $(cat "$QS_TEST_DIR/state") == live ]] && echo 222; }
kill() {
  if [[ $1 == -0 ]]; then [[ $(cat "$QS_TEST_DIR/state") == live ]]; return; fi
  printf '%s\n' "$*" >> "$QS_TEST_DIR/signals"
  printf gone > "$QS_TEST_DIR/state"
}
sleep() { printf gone > "$QS_TEST_DIR/state"; }
qs_live_reconcile_processes
`, "quickshell-process-test", liveHelper], {
                cwd: repoDir,
                encoding: "utf8",
                env: { ...process.env, QS_TEST_DIR: directory, QS_TEST_COMMAND: command },
            });
            assert.equal(result.status, 0, result.stderr);
            assert.equal(fs.readFileSync(path.join(directory, "signals"), "utf8"), expectedSignal);
        } finally {
            fs.rmSync(directory, { recursive: true, force: true });
        }
    }
});

function checkJournal(log) {
    return spawnSync("bash", ["-c", String.raw`
set -u
source "$1"
qs_live_current_journal() {
    printf '%s\n' "$QS_TEST_JOURNAL"
}
qs_live_check_journal
`, "quickshell-live-test", liveHelper], {
        cwd: repoDir,
        encoding: "utf8",
        env: { ...process.env, QS_TEST_JOURNAL: log },
    });
}

test("live journal guard allows the known benign clipping warning", () => {
    const result = checkJournal(
        "WARN qt.qml.propertyCache.append: Member data overrides a base member");
    assert.equal(result.status, 0, result.stderr);
});

test("live journal guard rejects QML JavaScript evaluation errors", async t => {
    for (const [name, diagnostic] of [
        ["TypeError", "Cannot call method 'trim' of null"],
        ["ReferenceError", "missingValue is not defined"],
        ["RangeError", "Maximum call stack size exceeded"],
    ]) {
        await t.test(name, () => {
            const result = checkJournal(
                `WARN scene: @Common/Theme.qml[23:-1]: ${name}: ${diagnostic}`);
            assert.equal(result.status, 1,
                `${name} unexpectedly passed the live journal guard`);
            assert.match(result.stderr, /contains QML\/runtime errors/);
            assert.match(result.stderr, new RegExp(name));
        });
    }
});

test("live journal guard rejects QML component load failures", async t => {
    for (const [name, diagnostic] of [
        ["unavailable type", "Type DrawerUsage unavailable"],
        ["invalid property", "Invalid property assignment: implicitHeight is read-only"],
    ]) {
        await t.test(name, () => {
            const result = checkJournal(
                `WARN scene: @DrawerUsage.qml[1:1]: ${diagnostic}`);
            assert.equal(result.status, 1,
                `${name} unexpectedly passed the live journal guard`);
            assert.match(result.stderr, /contains QML\/runtime errors/);
            assert.match(result.stderr, new RegExp(diagnostic.split(":")[0]));
        });
    }
});
