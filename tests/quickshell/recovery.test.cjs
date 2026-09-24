const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { shellDir, load } = require("./shell.cjs");

const helpers = load("RecoveryHelpers.js");
const read = name => fs.readFileSync(path.join(shellDir, name), "utf8");

test("a recovery boot is recognised only by a well-formed identifier", () => {
    assert.equal(helpers.recoveryBootId("root=UUID=x ro cybexos.recovery=20260901T120000Z-17 quiet"),
        "20260901T120000Z-17");
    assert.equal(helpers.recoveryBootId("root=UUID=x ro rootflags=subvol=root"), "");
    assert.equal(helpers.recoveryBootId("cybexos.recovery=../../etc"), "");
    assert.equal(helpers.recoveryBootId(undefined), "");
});

test("the published index is bounded and typed before the page shows it", () => {
    const index = helpers.parseIndex(JSON.stringify({
        version: 1, supported: true, message: "", recoveryBoot: "20260901T120000Z-1",
        pendingReboot: false, bootMenu: true,
        points: [
            { id: "20260901T120000Z-1", description: "update 20260901-1", created: "2026-09-01T12:00:00Z",
              kernel: "6.20.1", bootable: true, reason: "" },
            { id: "not-an-id", description: "dropped" },
            { id: "20260831T120000Z-2", description: 7, bootable: "yes" }
        ],
        replaced: [{ name: "root.replaced-20260902T080000Z", restoredFrom: "20260901T120000Z-1" },
            { name: "root" }]
    }));
    assert.equal(index.valid, true);
    assert.deepEqual(index.points.map(point => point.id), ["20260901T120000Z-1", "20260831T120000Z-2"]);
    assert.equal(index.points[1].description, "");
    assert.equal(index.points[1].bootable, false);
    assert.deepEqual(index.replaced.map(root => root.name), ["root.replaced-20260902T080000Z"]);
    assert.equal(helpers.parseIndex("{").valid, false);
    assert.equal(helpers.parseIndex(JSON.stringify({ version: 2 })).valid, false);
});

test("points read as times and purposes rather than identifiers", () => {
    assert.equal(helpers.pointTime("20260923T173128Z-3082302"), "2026-09-23 17:31 UTC");
    assert.equal(helpers.pointLabel({ description: "update 20260923-173127-4711-123" }), "Before an update");
    assert.equal(helpers.pointLabel({ description: "manual recovery point" }), "manual recovery point");
    assert.equal(helpers.pointStatus({ bootable: true, kernel: "6.20.1" }), "In the boot menu · kernel 6.20.1");
    assert.equal(helpers.pointStatus({ bootable: false, reason: "kernel 6.19 is no longer installed" }),
        "Restore only · kernel 6.19 is no longer installed");
});

test("restore runs only the known helper through a Polkit-authorized system unit", () => {
    const command = helpers.restoreCommand(helpers.INSTALLED_HELPER, "20260901T120000Z-1", 1727000000000);
    assert.deepEqual(command.slice(0, 7),
        ["systemd-run", "--system", "--quiet", "--collect", "--wait", "--pipe",
            "--unit=cybexos-recovery-restore-1727000000000"]);
    assert.deepEqual(command.slice(-4), ["--", helpers.INSTALLED_HELPER, "restore", "20260901T120000Z-1"]);
    assert.ok(!command.some(arg => /sudo|pkexec|--property=User/.test(arg)));
    assert.deepEqual(helpers.restoreCommand(helpers.INSTALLED_HELPER, "20260901T120000Z-1; reboot", 1), []);
    assert.deepEqual(helpers.restoreCommand("/tmp/evil", "20260901T120000Z-1", 1), []);
    assert.equal(helpers.helperPath("20260901T120000Z-1", true), helpers.RECOVERY_HELPER);
    assert.equal(helpers.helperPath("20260901T120000Z-1", false), helpers.INSTALLED_HELPER);
    assert.equal(helpers.helperPath("", true), helpers.INSTALLED_HELPER);
});

test("restore failures are explained in words", () => {
    assert.equal(helpers.restoreError(1, "Error: Interactive authentication required."),
        "Authorization was cancelled, so nothing was changed.");
    assert.equal(helpers.restoreError(1, "warning\ncybexos-system-snapshot: recovery point not found: x\n"),
        "Recovery point not found: x");
    assert.equal(helpers.restoreError(3, ""), "Restore failed (exit 3).");
});

test("the recovery UI is wired into the shell and the System page", () => {
    const qmldir = read("Common/qmldir");
    const shell = read("shell.qml");
    const service = read("Common/Recovery.qml");
    const page = read("Settings/SystemPage.qml");
    const search = load("SettingsSearchData.js").ROWS;

    assert.match(qmldir, /^singleton Recovery Recovery\.qml$/m);
    assert.match(shell, /void Recovery\.recoveryBoot;/, "a recovery boot announces itself at login");
    assert.match(service, /path: RecoveryHelpers\.INDEX_PATH[\s\S]{0,80}watchChanges: true/);
    assert.match(service, /"--urgency=critical"/, "the notice persists until dismissed");
    assert.match(service, /Settings\.showSetting\("system", "recoveryPoints", ""\)/);
    assert.match(page, /readonly property string settingKey: "recoveryPoints"/);
    assert.match(page, /"Confirm restore"/, "restore always takes a second, explicit press");
    assert.match(page, /hold Shift \(or press Esc\)/);
    assert.ok(search.some(row => row.page === "system" && row.group === "Recovery points"
        && /rollback/.test(row.terms)));
});
