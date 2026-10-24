// Settings → Backup & recovery: the helper contract the page relies on, and
// the page's place in the settings workspace. The helper itself is covered
// by tests/backup.py against stubbed restic and secret-tool.
const test = require("node:test");
const { untranslated } = require("./shell.cjs");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { shellDir, load } = require("./shell.cjs");

const helpers = load("BackupHelpers.js");
const read = name => untranslated(fs.readFileSync(path.join(shellDir, name), "utf8"));
const repo = path.resolve(__dirname, "../..");

function status(overrides) {
    return helpers.parseStatus(JSON.stringify(Object.assign({
        configured: true, running: false, progress: null, mediaRoot: "/run/media/tester",
        destination: { type: "local", display: "T7 · cybexos-backup", label: "T7", path: "/run/media/tester/T7/cybexos-backup" },
        automatic: true, reachable: true, unreachableReason: "", recoveryKeyConfirmed: true,
        lastSuccess: "2026-10-13T08:00:00+00:00", lastResult: "ok", lastError: "",
        nextDue: "2026-10-14T07:00:00+00:00", stale: false
    }, overrides)));
}

test("the helper's status is typed and bounded before the page shows it", () => {
    assert.equal(helpers.parseStatus("{").valid, false);
    assert.equal(helpers.parseStatus("null").valid, false);
    const empty = helpers.parseStatus(JSON.stringify({ configured: false, running: false }));
    assert.equal(empty.valid, true);
    assert.equal(empty.configured, false);
    assert.equal(empty.coverage, "");
    const coverage = helpers.parseStatus(JSON.stringify({configured: false,
        coverage: "included saves", consistency: "export databases"}));
    assert.equal(coverage.coverage, "included saves", "coverage is available before setup");
    assert.equal(coverage.consistency, "export databases");
    assert.equal(status({coverage: 42, consistency: "x".repeat(1500)}).coverage, "");
    assert.equal(status({consistency: "x".repeat(1500)}).consistency.length, 1000);
    const parsed = status({ destination: { type: "evil", display: "x".repeat(500) }, reachable: "yes",
        running: true, progress: { operation: "backup", percent: 7 }, mediaRoot: "relative" });
    assert.equal(parsed.destination.type, "local");
    assert.equal(parsed.destination.display.length, 200);
    assert.equal(parsed.reachable, null);
    assert.equal(parsed.progress.percent, 1);
    assert.equal(parsed.mediaRoot, "/", "only an absolute folder is browsed");
    assert.equal(status({ mediaRoot: "/run/media/tester" }).mediaRoot, "/run/media/tester");
});

test("the status line reads as last backup, its health and the next run", () => {
    const now = Date.parse("2026-10-13T12:00:00Z");
    const format = ms => "tomorrow after " + new Date(ms).toISOString().slice(11, 16);
    const due = Date.parse("2026-10-14T07:00:00Z");
    assert.equal(helpers.tone(status()), "ok");
    assert.equal(helpers.statusHint(status(), due, now, format), "Next backup tomorrow after 07:00.");
    assert.equal(helpers.statusHint(status(), now - 1, now, format), "Next backup within the hour.");
    assert.equal(helpers.statusHint(status({ automatic: false }), due, now, format), "Automatic backups are off.");
    assert.equal(helpers.statusHint(status({ reachable: false }), due, now, format),
        "Next backup when the destination is available.");
    const failed = status({ lastResult: "failed", lastError: "The backup destination is full." });
    assert.equal(helpers.tone(failed), "error");
    assert.equal(helpers.hintTone(failed), "error");
    assert.equal(helpers.statusHint(failed, due, now, format), "The backup destination is full.");
    const partial = status({lastResult: "partial", lastError: "Some container files could not be read. Export the data first."});
    assert.equal(helpers.tone(partial), "warning");
    assert.equal(helpers.hintTone(partial), "warning");
    assert.equal(helpers.statusHint(partial, due, now, format), partial.lastError);
    assert.match(helpers.statusHint(status({lastResult: "partial"}), due, now, format), /backup is incomplete/);
    const stale = status({ stale: true });
    assert.equal(helpers.tone(stale), "warning");
    assert.match(helpers.statusHint(stale, due, now, format), /^More than a week since the last backup\./);
    assert.equal(helpers.tone(status({ recoveryKeyConfirmed: false })), "warning",
        "an unsaved recovery key is a warning, not a healthy dot");
    const running = status({ running: true, progress: { operation: "backup", percent: 0.426 } });
    assert.equal(helpers.tone(running), "running");
    assert.equal(helpers.progressLabel(running.progress), "Backing up… 42%");
    assert.equal(helpers.progressLabel({ operation: "restore", percent: 0.1 }), "Restoring… 10%");
    assert.equal(helpers.tone(helpers.parseStatus(JSON.stringify({ configured: false }))), "off");
});

test("destinations are validated as data before the helper sees them", () => {
    const helper = "cybexos-backup";
    assert.equal(helpers.helperPath("/home/tester"), helper);
    assert.deepEqual(helpers.setupCommand(helper, "local", "/run/media/tester/T7", "", false),
        [helper, "setup", "local", "/run/media/tester/T7", "--json"]);
    assert.deepEqual(helpers.setupCommand(helper, "sftp", " nas ", "", true),
        [helper, "setup", "sftp", "nas", "cybexos-backup", "--existing", "--json"]);
    for (const host of ["-oProxyCommand=x", "a b", "h;reboot", "", "[::1]"])
        assert.deepEqual(helpers.setupCommand(helper, "sftp", host, "", false), [], host);
    for (const folder of ["../x", "a/../b", "~/x", "a;b"])
        assert.deepEqual(helpers.setupCommand(helper, "sftp", "nas", folder, false), [], folder);
    assert.deepEqual(helpers.setupCommand(helper, "local", "", "", false), []);
    assert.deepEqual(helpers.setupCommand(helper, "ftp", "x", "", false), []);
    assert.equal(helpers.validHost("me@nas.lan"), true);
    assert.equal(helpers.remotePath("backups/laptop/"), "backups/laptop");
});

test("backups and restores run as transient units that outlive Settings", () => {
    const helper = "/h/.local/bin/cybexos-backup";
    const now = helpers.nowCommand(helper, 1760000000000);
    assert.deepEqual(now.slice(0, 5), ["systemd-run", "--user", "--quiet", "--collect",
        "--unit=cybexos-backup-now-1760000000000"]);
    assert.deepEqual(now.slice(-3), [helper, "now", "--notify"]);
    const restore = helpers.restoreCommand(helper, "a".repeat(64), "Documents/Taxes", 7);
    assert.deepEqual(restore.slice(-7), [helper, "restore", "a".repeat(64), "--path", "Documents/Taxes",
        "--open", "--notify"]);
    assert.deepEqual(helpers.restoreCommand(helper, "latest", "", 7).slice(-5),
        [helper, "restore", "latest", "--open", "--notify"], "an empty path restores everything");
    for (const bad of ["../etc", "Documents/../..", "*", "a\\b"])
        assert.deepEqual(helpers.restoreCommand(helper, "latest", bad, 7), [], bad);
    assert.deepEqual(helpers.restoreCommand(helper, "latest; reboot", "", 7), []);
    assert.ok(!now.concat(restore).some(arg => /sudo|pkexec/.test(arg)));
});

test("helper failures are shown in its own words", () => {
    assert.equal(helpers.errorText(1, JSON.stringify({ ok: false, error: "T7 is not connected." }), ""),
        "T7 is not connected.");
    assert.equal(helpers.errorText(1, "", "warning\ncybexos-backup: The keyring is locked.\n"),
        "The keyring is locked.");
    assert.equal(helpers.errorText(-1, "", ""), "The backup helper is not installed.");
    assert.equal(helpers.formatBytes(1234567), "1.2 MB");
    assert.deepEqual(helpers.parseSnapshots(JSON.stringify({ snapshots: [
        { id: "ab".repeat(32), time: "2026-10-13T10:05:00Z", host: "box", bytes: 10 },
        { id: "latest" }, { id: "not hex" }] })).map(entry => entry.id), ["ab".repeat(32)]);
});

test("the next run reads in the future tense", () => {
    const page = read("Settings/BackupPage.qml");
    assert.match(page, /days <= 0 \? "today after " \+ time\s*: days === 1 \? "tomorrow after " \+ time/);
    assert.match(page, /page\.nowMs, page\.formatDue\)/);
    const localTime = require(path.join(shellDir, "Settings/LocalTime.js"));
    const now = new Date(2026, 9, 13, 12, 0).getTime();
    assert.equal(-localTime.daysBetween(new Date(2026, 9, 14, 7, 0).getTime(), now), 1);
    // -0 on the same day, which the page's `days <= 0` reads as today.
    assert.ok(-localTime.daysBetween(new Date(2026, 9, 13, 23, 0).getTime(), now) <= 0);
});

test("Backup & recovery is a System page that search reaches", () => {
    const settings = read("Common/Settings.qml");
    const view = read("Settings/SettingsView.qml");
    assert.match(settings, /\{ id: "backup", group: "System", label: "Backup & recovery", glyph: "archive",/);
    assert.ok(settings.indexOf('id: "backup"') < settings.indexOf('id: "about"'),
        "the page sits before About in the System group");
    assert.match(settings, /backup: \[\],/, "nothing on the page is a shell.json value");
    assert.match(view, /case "backup": return backupPage;/);
    assert.match(view, /Component \{ id: backupPage; BackupPage \{\} \}/);
    assert.match(read("Settings/qmldir"), /^BackupPage BackupPage\.qml$/m);
    assert.match(read("Common/qmldir"), /^singleton Backup Backup\.qml$/m);
    const rows = load("SettingsSearchData.js").ROWS.filter(row => row.page === "backup");
    assert.deepEqual(rows.map(row => row.label), ["Back up personal files", "Automatic backups",
        "Restore files", "Recovery key", "Recovery points", "Factory reset"]);
    assert.ok(rows.every(row => row.key === "" && row.pageLabel === "Backup & recovery"));
    const search = load("SettingsSearchData.js").search;
    for (const query of ["backup", "restic", "restore", "external drive", "rollback"])
        assert.ok(search(query).some(row => row.page === "backup"), query);
});

test("the page is a backups group then the recovery points, with setup inline", () => {
    const page = read("Settings/BackupPage.qml");
    const backupsAt = page.indexOf('title: "Backups"');
    const recoveryAt = page.indexOf("RecoveryGroup {");
    assert.ok(backupsAt > 0 && recoveryAt > backupsAt, "backups first, recovery points below");
    for (const step of ["Step 1 of 3", "Step 2 of 3", "Step 3 of 3"])
        assert.ok(page.includes(step), step);
    for (const label of ['label: "Last backup"', 'label: "Destination"', 'label: "Automatic backups"',
            'label: "Restore files"'])
        assert.ok(page.includes(label), label);
    for (const action of ['text: "Set up…"', 'text: "Back up now"', 'text: "Change…"',
            'text: page.restoreOpen ? "Close" : "Restore…"'])
        assert.ok(page.includes(action), action);
    assert.doesNotMatch(page, /Window \{|PanelWindow|FloatingWindow/, "setup stays inside the page");
    assert.doesNotMatch(page, /ResponsiveActionRow/);
    assert.match(page, /FolderDialog \{[\s\S]{0,120}title: "Choose a backup folder"/);
    // The key is shown once and copied as sensitive data on stdin.
    const service = read("Common/Backup.qml");
    assert.ok(service.includes("IFS= read -r key && printf '%s' \\\"$key\\\" | wl-copy --sensitive"),
        "the key reaches wl-copy through a pipe, marked sensitive");
    assert.match(service, /copyRequest\.inputText = pendingKey \+ "\\n"/);
    assert.doesNotMatch(service, /clipboardText|execDetached\(\["wl-copy"/,
        "the recovery key never reaches clipboard history or argv");
    assert.doesNotMatch(service, /FileView|writeAdapter|setText\(/, "the shell never stores the key");
    assert.match(service, /running: root\.watched/, "status is polled only while the page is shown");
});

test("About keeps shell health and the settings file, not recovery points", () => {
    const about = read("Settings/AboutPage.qml");
    assert.doesNotMatch(about, /RecoveryGroup|Recovery points/);
    assert.match(read("Common/Settings.qml"), /description: "Shell health and the settings file"/);
});
