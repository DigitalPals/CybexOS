// "What will change" before an update, the last transaction's recovery point,
// background downloads and the updates IPC target. The parsers run against
// verbatim fixtures of the commands the panel reads (dnf5 check-update,
// advisory info and changelog; flatpak remote-ls and list; rpm -qa).
const test = require("node:test");
const { untranslated } = require("./shell.cjs");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const { shellDir, load } = require("./shell.cjs");

const H = load("UpdatesHelpers.js");

function read(relative) {
    return untranslated(fs.readFileSync(path.join(shellDir, relative), "utf8"));
}

function functionSource(source, name) {
    const match = source.match(new RegExp("^    function " + name + "\\([^]*?^    }", "m"));
    assert.ok(match, `function ${name} not found`);
    return match[0];
}

// `dnf --quiet check-update` on an ISO installation with the desktop channel.
const CHECK_UPDATE = [
    "Upgrades",
    "ca-certificates.noarch             2026.2.90_v9.0.317-1.fc44 updates",
    "curl.x86_64                        8.18.0-13.fc44            updates",
    "SDL3.i686                          3.2.22-1.fc44             updates",
    "SDL3.x86_64                        3.2.22-1.fc44             updates",
    "openssl-libs.x86_64                1:3.5.9-1.fc44            updates",
    "cybexos-desktop.x86_64             1:1.2.0~beta.1-1.20261013120000.gabcdef123456.fc44 cybexos-desktop",
    "  a continuation that is not a package"
].join("\n");

// `rpm -qa --qf '%{NAME}.%{ARCH}\t%{EVR}\n'` (abridged).
const RPM_QA = [
    "ca-certificates.noarch\t2026.2.80_v9.0.304-1.fc44",
    "curl.x86_64\t8.18.0-8.fc44",
    "SDL3.i686\t3.2.20-1.fc44",
    "SDL3.x86_64\t3.2.20-1.fc44",
    "openssl-libs.x86_64\t1:3.5.8-2.fc44",
    "cybexos-desktop.x86_64\t1:1.1.0-1.20260920100000.g0123456789ab.fc44",
    "bash.x86_64\t5.3.9-3.fc44"
].join("\n") + "\n";

// `dnf --quiet advisory info --updates --json` (two of its objects trimmed).
const ADVISORY_INFO = JSON.stringify([
    { Name: "FEDORA-2026-5f9e5ace98", Title: "rust-rpm-sequoia-1.10.3-1.fc44",
        Severity: "None", Type: "enhancement", Status: "stable",
        Description: "Update to version 1.10.3.", collections: { packages: [] } },
    { Name: "FEDORA-2026-91d799048a", Title: "curl-8.18.0-13.fc44",
        Severity: "Moderate", Type: "security", Status: "stable",
        Description: "Fix Negotiate ambient user conn reuse (CVE-2026-19931)" },
    { Name: "FEDORA-2026-0b1fd1bcf5", Title: "libcap-ng-0.9.6-1.fc44",
        Severity: "None", Type: "bugfix" },
    { Name: "FEDORA-2026-77aa00bb11", Title: "openssl-3.5.9-1.fc44",
        Severity: "Important", Type: "security" },
    { Name: "FEDORA-2026-2a33732e22", Title: "dnf5-5.4.6.0-1.fc44",
        Severity: "None", Type: "unspecified" }
]);

// `LC_ALL=C dnf --quiet --repo=cybexos-desktop changelog --upgrades cybexos-desktop`,
// plus a Fedora entry in dnf5's own (timed) header format.
const CHANGELOG = [
    "Listing only new changelogs since installed version of the package",
    "Changelogs for cybexos-desktop-1:1.2.0~beta.1-1.20261013120000.gabcdef123456.fc44.x86_64",
    "* Tue Oct 13 2026 CybexOS <noreply@localhost> - 1.2.0~beta.1-1.20261013120000.gabcdef123456",
    "- CybexOS desktop 1.2.0~beta.1 (abcdef123456)",
    "- Release notes: https://github.com/DigitalPals/CybexOS/releases/tag/v1.2.0-beta.1",
    "",
    "* Thu Oct 08 12:00:00 2026 Jan Macku <jamacku@redhat.com> - 8.18.0-13",
    "- Fix Negotiate ambient user conn reuse (CVE-2026-19931)",
    "",
    "* Wed Sep 09 12:00:00 2026 Steve Grubb <sgrubb@redhat.com> 0.9.6-1",
    "- New upstream bugfix release",
    ""
].join("\n");

test("check-update rows keep version and repository; the desktop RPM is CybexOS", () => {
    const rows = H.dnfPackages(CHECK_UPDATE);
    assert.equal(rows.length, 6, "the continuation line is not a package");
    assert.deepEqual(rows[4], { name: "openssl-libs", arch: "x86_64",
        version: "1:3.5.9-1.fc44", repo: "updates" });
    assert.deepEqual(H.dnfNames(CHECK_UPDATE), rows.map(row => row.name),
        "the count and the rows describe the same answer");

    const desktop = H.desktopPackages(rows);
    assert.deepEqual(desktop.map(row => row.name), ["cybexos-desktop"]);
    assert.equal(H.desktopVersion(desktop[0].version), "1.2.0-beta.1",
        "the RPM's ~ prerelease reads as the release's own version");
    assert.equal(H.desktopVersion("1:1.2.0-1.20261013.gabc.fc44"), "1.2.0");
    assert.equal(H.isDesktopPackage({ name: "cybexos-desktop", repo: "@commandline" }), true);
    assert.equal(H.isDesktopPackage({ name: "curl", repo: "updates" }), false);
});

test("each package reads installed → incoming, once per multiarch pair", () => {
    const installed = H.rpmVersions(RPM_QA);
    assert.equal(installed["openssl-libs.x86_64"], "1:3.5.8-2.fc44");
    assert.equal(installed["bash.x86_64"], "5.3.9-3.fc44");
    assert.deepEqual(H.rpmVersions("garbage line\n\n"), {});

    const rows = H.dnfPackages(CHECK_UPDATE).filter(row => !H.isDesktopPackage(row));
    assert.deepEqual(H.packageChanges(rows, installed), [
        { name: "ca-certificates", from: "2026.2.80_v9.0.304-1.fc44",
            to: "2026.2.90_v9.0.317-1.fc44" },
        { name: "curl", from: "8.18.0-8.fc44", to: "8.18.0-13.fc44" },
        { name: "SDL3", from: "3.2.20-1.fc44", to: "3.2.22-1.fc44" },
        { name: "openssl-libs", from: "3.5.8-2.fc44", to: "3.5.9-1.fc44" }
    ]);
    // Before the installed side is read, only the incoming version shows.
    assert.deepEqual(H.packageChanges(rows.slice(0, 1), {}),
        [{ name: "ca-certificates", from: "", to: "2026.2.90_v9.0.317-1.fc44" }]);
    assert.equal(H.displayVersion("2:9.2.967-1.fc44"), "9.2.967-1.fc44");
});

test("Flatpak rows carry name, id and the incoming version", () => {
    // `flatpak remote-ls --updates --app --columns=name,application,version`
    const remote = "Signal\torg.signal.Signal\t7.75.0\n\tcom.spotify.Client\t1.2.60\n"
        + "Firefox\torg.mozilla.firefox\t\n\n";
    const apps = H.flatpakApps(remote);
    assert.deepEqual(apps, [
        { name: "Signal", id: "org.signal.Signal", version: "7.75.0" },
        { name: "Spotify", id: "com.spotify.Client", version: "1.2.60" },
        { name: "Firefox", id: "org.mozilla.firefox", version: "" }
    ], "an app without a display name still counts, under its id's name");
    assert.deepEqual(H.flatpakNames(remote), ["Signal", "Spotify", "Firefox"]);
    // The single-column output of older shells still parses.
    assert.deepEqual(H.flatpakNames("Firefox\n  Spotify  \n\n"), ["Firefox", "Spotify"]);

    // `flatpak list --app --columns=application,version`
    const installed = H.flatpakVersions("org.signal.Signal\t7.74.1\norg.mozilla.firefox\t143.0\n");
    assert.deepEqual(H.appChanges(apps, installed), [
        { name: "Signal", from: "7.74.1", to: "7.75.0" },
        { name: "Spotify", from: "", to: "1.2.60" },
        { name: "Firefox", from: "143.0", to: "" }
    ]);
});

test("advisories count by kind, security first and most severe first", () => {
    const summary = H.advisorySummary(ADVISORY_INFO);
    assert.deepEqual([summary.security, summary.bugfix, summary.enhancement, summary.other],
        [2, 1, 1, 1]);
    assert.equal(summary.count, 2, "count keeps meaning security advisories");
    assert.equal(summary.severe, true, "an Important security fix is severe");
    assert.deepEqual(summary.advisories.map(a => a.title), [
        "openssl-3.5.9-1.fc44", "curl-8.18.0-13.fc44", "libcap-ng-0.9.6-1.fc44",
        "rust-rpm-sequoia-1.10.3-1.fc44", "dnf5-5.4.6.0-1.fc44"
    ]);
    assert.equal(H.advisoryLabel(summary),
        "2 security fixes · 1 bug fix · 1 enhancement · 1 other update");
    assert.equal(H.advisoryKind(summary.advisories[0]), "Important security");
    assert.equal(H.advisoryKind({ type: "security", severity: "None" }), "Security");
    assert.equal(H.advisoryKind(summary.advisories[2]), "Bug fix");
    assert.equal(H.advisoryLabel(H.emptyAdvisories()), "");

    // `advisory list --json` repeats an advisory per package and has no title.
    const list = H.advisorySummary(JSON.stringify([
        { name: "FEDORA-2026-1", type: "security", severity: "Moderate", nevra: "kernel-7.2.7" },
        { name: "FEDORA-2026-1", type: "security", severity: "Moderate", nevra: "kernel-core-7.2.7" },
        { name: "FEDORA-2026-2", type: "bugfix", severity: "None", nevra: "less-704" }
    ]));
    assert.deepEqual([list.security, list.bugfix, list.count, list.severe], [1, 1, 1, false]);
    assert.equal(list.advisories[0].title, "");
    assert.throws(() => H.advisorySummary("{}"));
    assert.throws(() => H.advisorySummary("not json"));
});

test("the desktop changelog and release notes become a few plain lines", () => {
    const entries = H.parseChangelog(CHANGELOG, 5, 8);
    assert.deepEqual(entries[0], {
        version: "1.2.0~beta.1-1.20261013120000.gabcdef123456", date: "13 Oct 2026",
        lines: ["CybexOS desktop 1.2.0~beta.1 (abcdef123456)",
            "Release notes: https://github.com/DigitalPals/CybexOS/releases/tag/v1.2.0-beta.1"]
    });
    assert.deepEqual(entries[1], { version: "8.18.0-13", date: "8 Oct 2026",
        lines: ["Fix Negotiate ambient user conn reuse (CVE-2026-19931)"] });
    assert.equal(entries[2].version, "0.9.6-1", "a header without the dash still names its version");
    assert.equal(H.parseChangelog(CHANGELOG, 1, 1).length, 1);
    assert.deepEqual(H.parseChangelog(CHANGELOG, 1, 1)[0].lines.length, 1);
    assert.deepEqual(H.parseChangelog("", 5, 8), []);

    // A GitHub release body, as `gh release create --generate-notes` writes it.
    const notes = [
        "## What's Changed",
        "* Keep mDNS open so network printers are found by @john in https://github.com/DigitalPals/CybexOS/pull/15",
        "* Align the [browser desktop](https://example.invalid/x) with **native** CybexOS by @john in https://github.com/DigitalPals/CybexOS/pull/16",
        "",
        "<!-- generated -->",
        "**Full Changelog**: https://github.com/DigitalPals/CybexOS/compare/v0.1.0...v0.2.0"
    ].join("\r\n");
    assert.deepEqual(H.releaseNotesLines(notes, 12), [
        "What's Changed",
        "• Keep mDNS open so network printers are found",
        "• Align the browser desktop with native CybexOS"
    ]);
    assert.equal(H.releaseNotesLines(notes, 2).length, 2);
    assert.equal(H.releaseNotesLines("x".repeat(500), 1)[0].length, 200);
    assert.equal(H.projectNotesOf({ releaseNotes: notes }), notes);
    assert.equal(H.projectNotesOf({ releaseNotes: 7 }), "");
    assert.equal(H.projectNotesOf(null), "");
});

test("a run record's recovery point is validated before it is shown", () => {
    assert.equal(H.recoveryPointOf({ snapshotId: "20261013T120000Z-4242" }),
        "20261013T120000Z-4242");
    for (const record of [{ snapshotId: "" }, { snapshotId: "../../etc" }, {}, null,
        { snapshotId: 20261013 }])
        assert.equal(H.recoveryPointOf(record), "");

    // A dismissed run is still the last transaction; a new run clears it.
    const updates = read("Common/Updates.qml");
    const apply = functionSource(updates, "applyBackendStatus");
    const state = { UpdatesHelpers: H, runState: "idle", recoveryPointId: "",
        bootId: "", rebootRecommendation: "" };
    vm.runInNewContext("(" + apply.replace(/^    function applyBackendStatus/, "function")
        + ")(" + JSON.stringify({ id: "20261013-120000-1-1", state: "dismissed",
            snapshotId: "20261013T120000Z-4242", bootId: "b" }) + ")", state);
    assert.equal(state.recoveryPointId, "20261013T120000Z-4242");
    assert.match(functionSource(updates, "resetRun"), /recoveryPointId = "";/);
    assert.match(updates,
        /function openRecoveryPoints\(\) \{\s*Settings\.showSetting\(Settings\.validPages\.indexOf\("backup"\) !== -1 \? "backup" : "",\s*"recoveryPoints", ""\);/,
        "the route opens the Backup page where it exists, else where recoveryPoints lives");
});

test("background downloads report ready only until something is installed", () => {
    const done = H.parseDownloadStatus(JSON.stringify({ version: 1, state: "done",
        finishedAt: 1791000000, dnfRc: 0, flatpakRc: 0 }));
    assert.deepEqual(done, { state: "done", finishedAt: 1791000000 });
    for (const text of ["", "{}", "not json", JSON.stringify({ version: 2, state: "done" }),
        JSON.stringify({ version: 1, state: "running", finishedAt: 5 })])
        assert.equal(H.parseDownloadStatus(text).state, "", text);

    const signature = H.dnfSignature([
        "/var/cache/libdnf5/updates-3cc0/repodata/repomd.xml 7055 1790999999.0",
        "/usr/lib/sysimage/rpm/rpmdb.sqlite 104857600 1790990000.25",
        "/usr/lib/sysimage/rpm/rpmdb.sqlite-wal 4096 1790995000.5"
    ].join("\n"));
    assert.equal(H.rpmdbChangedAt(signature), 1790995000.5, "the newer of db and log");
    assert.equal(H.rpmdbChangedAt(""), 0);
    assert.equal(H.downloadReady(done, 1790995000.5, 3), true);
    assert.equal(H.downloadReady(done, 1791000500, 3), false,
        "an install after the download makes it stale");
    assert.equal(H.downloadReady(done, 0, 0), false, "nothing pending, nothing ready");
    assert.equal(H.downloadReady({ state: "failed", finishedAt: 1791000000 }, 0, 3), false);

    const updates = read("Common/Updates.qml");
    assert.match(updates,
        /id: downloadView\s*path: UpdatesHelpers\.DOWNLOAD_STATUS_PATH\s*watchChanges: true/);
    assert.equal(H.DOWNLOAD_STATUS_PATH, "/var/lib/cybexos/update-download/status.json");
    assert.match(updates,
        /readonly property bool downloadReady: runState === "idle"\s*&& UpdatesHelpers\.downloadReady\(downloadStatus, rpmdbChangedAt,\s*dnfCount \+ flatpakCount\)/);
    const popover = read("Popovers/UpdatesPopover.qml");
    assert.match(popover, /if \(Updates\.downloadReady\)\s*return "Updates downloaded — ready to install";/);
});

test("the automatic download setting is the system timer, changed through Polkit", () => {
    assert.equal(H.autoDownloadState(0, "enabled\n"), "enabled");
    assert.equal(H.autoDownloadState(1, "disabled\n"), "disabled");
    assert.equal(H.autoDownloadState(4, ""), "unavailable", "no timer installed hides the row");
    assert.equal(H.autoDownloadState(1, "masked\n"), "unavailable");

    const on = H.autoDownloadCommand(true, 1790000000123);
    assert.deepEqual(on.slice(0, 6),
        ["systemd-run", "--system", "--quiet", "--collect", "--wait", "--pipe"]);
    assert.equal(on[6], "--unit=cybexos-update-download-setup-1790000000123");
    assert.deepEqual(on.slice(-5),
        ["--", "/usr/bin/systemctl", "enable", "--now", "cybexos-update-download.timer"]);
    assert.deepEqual(H.autoDownloadCommand(false, 1).slice(-4),
        ["/usr/bin/systemctl", "disable", "--now", "cybexos-update-download.timer"]);
    assert.ok(!H.autoDownloadCommand(true, 1).some(arg => /sudo|pkexec|NOPASSWD/.test(arg)),
        "no passwordless privilege: systemd asks the session's Polkit agent");
    assert.equal(H.autoDownloadError(1,
        "Failed to start transient service unit: Interactive authentication required."),
        "Authorization was cancelled, so nothing changed.");
    assert.equal(H.autoDownloadError(1, "first\nsecond reason\n"), "second reason");

    const detail = read("Settings/ModuleDetailView.qml");
    const updatesOptions = detail.slice(detail.indexOf("id: updatesOptions"),
        detail.indexOf("id: trayOptions"));
    assert.equal((updatesOptions.match(/SwitchRow \{/g) || []).length, 3,
        "one new switch beside the existing interval, Flatpak and notification rows");
    assert.match(updatesOptions, /label: "Check every"/, "the existing interval stays exposed");
    assert.match(updatesOptions,
        /visible: Updates\.autoDownloadState !== "unavailable"\s*label: "Download updates automatically"/);
    assert.match(updatesOptions, /checked: Updates\.autoDownloadState === "enabled"/);
    assert.match(updatesOptions, /onToggled: value => Updates\.setAutoDownload\(value\)/);
    assert.match(updatesOptions, /Component\.onCompleted: Updates\.refreshAutoDownload\(\)/);
    const search = load("SettingsSearchData.js").ROWS;
    assert.ok(search.some(row => row.widget === "updates"
        && row.label === "Download updates automatically" && /metered/.test(row.terms)));
    const defaults = load("SettingsHelpers.js").defaults();
    assert.deepEqual(Object.keys(defaults.modOpts.updates).sort(), ["flatpak", "notify", "pollMins"],
        "systemd keeps the choice; there is no shell.json key to disagree with it");
});

test("the preview is read once per check, only while its details are open", () => {
    const updates = read("Common/Updates.qml");
    assert.match(updates,
        /readonly property bool previewWanted: detailsOpen && runState === "idle" && total > 0\s*&& Popouts\.open && Popouts\.currentName === "updates"/);
    assert.match(updates, /onPreviewWantedChanged: loadPreview\(\)/);
    const started = [];
    const proc = name => ({ set running(value) { if (value) started.push(name); } });
    const ctx = { previewWanted: true, busy: false, previewFor: -1, lastChecked: 1000,
        systemCount: 3, flatpakCount: 1, desktopCount: 1, installedRpms: null,
        installedApps: null, desktopChangelog: null,
        rpmQuery: proc("rpm"), appQuery: proc("flatpak"), changelogQuery: proc("changelog") };
    vm.createContext(ctx);
    vm.runInContext(functionSource(updates, "loadPreview"), ctx);
    ctx.loadPreview();
    assert.deepEqual(started, ["rpm", "flatpak", "changelog"]);
    ctx.loadPreview();
    assert.equal(started.length, 3, "the same check is not read twice");
    ctx.lastChecked = 2000;
    ctx.systemCount = 0;
    ctx.flatpakCount = 0;
    ctx.desktopCount = 0;
    ctx.loadPreview();
    assert.equal(started.length, 3, "nothing pending reads nothing");
    assert.equal(JSON.stringify([ctx.installedRpms, ctx.installedApps, ctx.desktopChangelog]),
        "[{},{},[]]", "and clears what an earlier check read");
    ctx.lastChecked = 3000;
    ctx.previewWanted = false;
    ctx.systemCount = 2;
    ctx.loadPreview();
    assert.equal(started.length, 3, "closed details read nothing");

    // Unprivileged, bounded reads; the changelog loads only the desktop channel.
    assert.match(updates, /id: rpmQuery\s*command: \["rpm", "-qa", "--qf", "%\{NAME\}\.%\{ARCH\}\\\\t%\{EVR\}\\\\n"\]\s*timeoutMs: 20000/);
    assert.match(updates, /id: appQuery\s*command: \["flatpak", "list", "--app", "--columns=application,version"\]\s*timeoutMs: 20000/);
    assert.match(updates,
        /id: changelogQuery[\s\S]{0,200}command: \["timeout", "45s", "dnf", "--quiet", "--assumeyes",\s*"--repo=" \+ UpdatesHelpers\.DESKTOP_REPO, "changelog", "--upgrades",\s*"cybexos-desktop"\]/);
    assert.match(updates, /"advisory", "info", "--updates", "--json"\]/,
        "one advisory read serves the security note and the details");
    assert.match(updates, /"--updates", "--app", "--columns=name,application,version"\]/);
    const preview = updates.slice(updates.indexOf("// ---- what will change"),
        updates.indexOf("// ---- the native run"));
    assert.doesNotMatch(preview, /"sudo"|"pkexec"|"-n", "true"/, "the preview never needs root");
});

test("the panel shows what will change as plain text, CybexOS split out", () => {
    const popover = read("Popovers/UpdatesPopover.qml");
    assert.match(popover, /text: root\.previewing \? "What will change" : "Details"/);
    assert.match(popover, /readonly property bool showSystem: idle \? Updates\.systemCount > 0 : true/);
    assert.match(popover, /readonly property bool showProject: idle && Updates\.cybexosPending/);
    assert.match(popover, /count: Updates\.cybexosVersion/);
    assert.match(popover, /text: UpdatesHelpers\.advisoryLabel\(Updates\.dnfAdvisories\)/);
    assert.match(popover, /changes: root\.idle \? Updates\.packageChanges : \[\]/);
    assert.match(popover, /changes: root\.idle \? Updates\.appChanges : \[\]/);
    assert.match(popover, /heading: "CYBEXOS · " \+ Updates\.cybexosVersion/);
    assert.match(popover,
        /cybexosNotes: Updates\.projectAvailable\s*\? UpdatesHelpers\.releaseNotesLines\(Updates\.projectNotes, 12\)\s*: Updates\.desktopChangelog/);
    // Titles, changelog lines, notes and package names come from outside: no
    // Text that shows them may interpret markup.
    for (const binding of ["text: changeRow.modelData.name", "text: detailBlock.body",
        "text: UpdatesHelpers.advisoryKind(advisoryRow.modelData)"]) {
        const at = popover.indexOf(binding);
        assert.ok(at > 0, binding);
        assert.match(popover.slice(at, at + 260), /textFormat: Text\.PlainText/, binding);
    }
    const title = popover.indexOf("advisoryRow.modelData.title !== \"\"");
    assert.match(popover.slice(title, title + 260), /textFormat: Text\.PlainText/);

    const updates = read("Common/Updates.qml");
    assert.match(updates, /readonly property int systemCount: Math\.max\(0, dnfCount - desktopCount\)/);
    assert.match(updates, /readonly property bool cybexosPending: projectAvailable \|\| desktopCount > 0/);
    assert.match(updates, /readonly property int total: dnfCount \+ flatpakCount \+ firmwareCount \+ \(projectAvailable \? 1 : 0\)/,
        "the total still counts the desktop RPM once, as dnf will");
});

test("the updates IPC target checks and opens the Updates panel", () => {
    const shell = read("shell.qml");
    const start = shell.indexOf('target: "updates"');
    assert.ok(start > 0, "an updates IpcHandler");
    const handler = shell.slice(start, shell.indexOf("}\n    }", start) + 7);
    assert.match(handler, /function check\(\): void \{\s*Updates\.check\(\);\s*\}/);
    assert.match(handler,
        /function open\(\): void \{\s*Popouts\.openPanel\("updates", undefined, undefined,\s*Screens\.focused \? Screens\.focused\.name : ""\);/);
    assert.equal((shell.match(/target: "updates"/g) || []).length, 1,
        "an IpcHandler target may only be registered once");
});
