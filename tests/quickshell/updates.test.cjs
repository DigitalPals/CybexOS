const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { shellDir, load } = require("./shell.cjs");

const H = load("UpdatesHelpers.js");

function read(relative) {
    return fs.readFileSync(path.join(shellDir, relative), "utf8");
}

test("dnf output keeps real package rows and their raw multiarch count", () => {
    const output = [
        "Updating and loading repositories:",
        "Repositories loaded.",
        "SDL3.i686                 3.2.22-1.fc44 updates",
        "SDL3.x86_64               3.2.22-1.fc44 updates",
        "python3-foo+bar.noarch     1.4-2.fc44    updates",
        "  a continuation that is not a package"
    ].join("\n");

    assert.deepEqual(H.dnfNames(output), ["SDL3", "SDL3", "python3-foo+bar"]);
    assert.deepEqual(H.dnfNames(""), []);
});

test("Flatpak output drops blank rows without changing application names", () => {
    assert.deepEqual(H.flatpakNames("Firefox\n  Spotify  \n\n"),
        ["Firefox", "Spotify"]);
    assert.deepEqual(H.flatpakNames(undefined), []);
});

test("only a post-baseline zero-to-positive transition of an answering source notifies", () => {
    const dnf = count => ({ baseline: true, count });
    assert.equal(H.shouldNotify(0, 3, [dnf(3)], true), true);
    assert.equal(H.shouldNotify(0, 3, [{ baseline: false, count: 3 }], true), false,
        "a source's first answer establishes its baseline silently");
    assert.equal(H.shouldNotify(0, 3, [dnf(3), { baseline: false, count: 0 }], true), true,
        "a source answering for the first time does not silence one that has");
    assert.equal(H.shouldNotify(0, 5, [dnf(0), { baseline: false, count: 5 }], true), false,
        "only a known source's count is news");
    assert.equal(H.shouldNotify(2, 3, [dnf(3)], true), false,
        "a count that merely grows is not a new update event");
    assert.equal(H.shouldNotify(0, 3, [dnf(3)], false), false);
    assert.equal(H.shouldNotify(0, 3, [], true), false,
        "nothing that answered, nothing to announce");
});

test("a retry repeats only the sources that failed", () => {
    assert.deepEqual(H.allParts(), { dnf: true, flatpak: true, firmware: true, project: true });
    assert.deepEqual(H.failedParts({ dnf: "", flatpak: "Flathub unreachable", firmware: "", project: "" }),
        { dnf: false, flatpak: true, firmware: false, project: false });
    assert.deepEqual(H.failedParts(null), { dnf: false, flatpak: false, firmware: false, project: false });
    assert.equal(H.pendingSummary(3, 0, 1, false, ""), "dnf 3 · firmware 1");
    assert.equal(H.pendingSummary(0, 2, 0, true, "1.4"), "flatpak 2 · CybexOS 1.4");
});

test("table sections map to feed verbs and reject prose", () => {
    assert.equal(H.dnfSection("Upgrading:"), "up");
    assert.equal(H.dnfSection("Installing dependencies:"), "add");
    assert.equal(H.dnfSection("Removing unused dependencies:"), "del");
    assert.equal(H.dnfSection("Transaction Summary:"), null);
    assert.equal(H.dnfSection(" firefox   x86_64 0:154.0-3.fc44 updates 287.1 MiB"),
        null);
    assert.equal(H.dnfSection(""), null);
});

test("table rows carry the full untruncated name and version", () => {
    // Verbatim lines from a real fc44 transaction table.
    assert.deepEqual(H.dnfTableRow(
        " gnome-shell-extension-launch-new-instance             noarch 0:50.3-1.fc44      updates                            1.4 KiB"),
        { name: "gnome-shell-extension-launch-new-instance", arch: "noarch",
            evr: "0:50.3-1.fc44", version: "50.3-1.fc44" });
    assert.deepEqual(H.dnfTableRow(
        " vim-minimal                                           x86_64 2:9.2.967-1.fc44   updates                            1.8 MiB").version,
        "9.2.967-1.fc44", "the epoch is for matching, not for reading");
    assert.equal(H.dnfTableRow(
        "   replacing firefox                                   x86_64 0:153.0.3-1.fc44   updates                          282.0 MiB"),
        null, "outgoing versions are continuations, not packages");
    assert.equal(H.dnfTableRow("Transaction Summary:"), null);
    assert.equal(H.dnfTableRow(""), null);
});

test("bracketed progress lines advance the counter; verbs carry dnf's clipped token", () => {
    assert.deepEqual(H.parseDnfRunLine(
        "[11/58] Upgrading less-0:704-4.fc44.x86 100% |  29.5 MiB/s | 483.2 KiB |  00m00s"),
        { cur: 11, total: 58, verb: "up", token: "less-0:704-4.fc44.x86" });
    assert.deepEqual(H.parseDnfRunLine(
        "[53/58] Removing tmux-0:3.7b-2.fc44.x86 100% | 636.0   B/s |  14.0   B |  00m00s"),
        { cur: 53, total: 58, verb: "del", token: "tmux-0:3.7b-2.fc44.x86" });
    assert.deepEqual(H.parseDnfRunLine(
        "[10/28] less-0:704-4.fc44.x86_64        100% |   2.2 MiB/s | 227.8 KiB |  00m00s"),
        { cur: 10, total: 28, verb: "", token: "" },
        "download lines are progress only");
    assert.equal(H.parseDnfRunLine(
        "[ 1/58] Verify package files            100% |  51.0   B/s |  28.0   B |  00m01s").verb,
        "", "aux steps keep the counter without naming a package");
    assert.equal(H.parseDnfRunLine("Running transaction"), null);
    assert.equal(H.parseDnfRunLine(""), null);
});

test("clipped tokens find their table row, and only theirs", () => {
    assert.ok(H.rowMatchesToken("less", "0:704-4.fc44", "less-0:704-4.fc"),
        "a token cut inside the evr still matches");
    assert.ok(H.rowMatchesToken("less", "0:704-4.fc44", "less-0:704-4.fc44.x86"),
        "a token extending into the arch still matches");
    assert.ok(!H.rowMatchesToken("less-color", "0:704-4.fc44", "less-0:704-4.fc44.x86"),
        "a longer-named sibling must not claim the token");
    assert.ok(!H.rowMatchesToken("less", "0:704-4.fc44", "less-color-0:704-4.fc"),
        "nor the reverse");
    assert.ok(!H.rowMatchesToken("tmux", "0:3.7c-1.fc44", "tmux-0:3.7b-2.fc44.x86"),
        "cleanup of the outgoing version matches no incoming row");
    assert.ok(!H.rowMatchesToken("less", "0:704-4.fc44", ""));
});

test("flatpak lines separate the plan from the work and name apps sensibly", () => {
    assert.deepEqual(H.parseFlatpakRunLine(" 1.\torg.signal.Signal"),
        { kind: "planned", n: 1 });
    assert.deepEqual(H.parseFlatpakRunLine("Updating app/org.signal.Signal/x86_64/stable"),
        { kind: "op", verb: "up", runtime: false, name: "Signal" });
    assert.deepEqual(H.parseFlatpakRunLine("Installing runtime/org.freedesktop.Platform/x86_64/24.08"),
        { kind: "op", verb: "add", runtime: true, name: "Platform" });
    assert.equal(H.parseFlatpakRunLine("Updating app/com.spotify.Client/x86_64/stable").name,
        "Spotify", "a generic tail segment yields to the vendor segment");
    assert.equal(H.parseFlatpakRunLine("Looking for updates…"), null);
});

test("the chip percentage stays honest across both streams", () => {
    assert.equal(H.runPercent(0, 0, 0, 0), -1,
        "no denominator yet means indeterminate, not 0%");
    assert.equal(H.runPercent(76, 120, 0, 0), 63);
    assert.equal(H.runPercent(60, 120, 1, 2), 50);
    assert.equal(H.runPercent(500, 120, 9, 2), 100,
        "overshoot clamps rather than exceeding 100");
});

test("only an incoming kernel earns the reboot hint", () => {
    assert.equal(H.kernelHint("kernel-core", "add", "7.1.9-200.fc44"), "7.1.9");
    assert.equal(H.kernelHint("kernel", "up", "7.1.9-200.fc44"), "7.1.9");
    assert.equal(H.kernelHint("kernel-core", "del", "7.1.4-100.fc44"), "",
        "removing the old kernel is not news");
    assert.equal(H.kernelHint("kernel-headers", "up", "7.1.9-200.fc44"), "");
});

test("authoritative reboot states are normalized and presented explicitly", () => {
    for (const state of ["pending", "checking", "recommended", "not-needed",
        "unavailable"])
        assert.equal(H.normalizedRebootRecommendation(state), state);
    assert.equal(H.normalizedRebootRecommendation(undefined), "unavailable");
    assert.equal(H.normalizedRebootRecommendation("legacy-guess"), "unavailable",
        "an older status must never become a false recommendation");

    assert.equal(H.rebootLabel("recommended", "7.1.9"),
        "Reboot recommended · Kernel 7.1.9 installed");
    assert.equal(H.rebootLabel("recommended", ""), "Reboot recommended");
    assert.equal(H.rebootLabel("not-needed", "7.1.9"),
        "No reboot recommended", "the kernel parser is detail, not authority");
    assert.equal(H.rebootLabel("unavailable", ""),
        "Couldn’t determine whether a reboot is recommended");
});

test("the completed widget gates reboot action and retains only positive advice", () => {
    const updates = read("Common/Updates.qml");
    const bar = read("Bar/Modules/Updates.qml");
    const barHost = read("Bar/Bar.qml");
    const popover = read("Popovers/UpdatesPopover.qml");

    assert.match(updates, /property string bootId:\s*""/);
    assert.match(updates, /property string recoveryPointId:\s*""/);
    assert.match(updates,
        /recoveryPointId = typeof data\.snapshotId === "string" \? data\.snapshotId : ""/);
    assert.match(popover,
        /label:\s*"Recovery point"[\s\S]{0,300}?Updates\.recoveryPointId/);
    assert.match(updates,
        /property string rebootRecommendation:\s*"unavailable"/);
    assert.match(updates,
        /normalizedRebootRecommendation\(\s*data\.rebootRecommendation\)/);
    assert.match(popover,
        /visible:\s*root\.mode === "done"[\s\S]{0,100}root\.mode === "idle" && recommended/,
        "only a positive survives the completed transcript");
    assert.match(popover, /visible:\s*rebootOutcome\.recommended/,
        "the Restart action is controlled by Fedora's result");
    assert.match(popover, /onTriggered:\s*Session\.reboot\(\)/);
    assert.doesNotMatch(popover,
        /visible:\s*root\.mode === "done" && Updates\.kernelPending !== ""/,
        "a parsed kernel must not gate the outcome or action");

    assert.match(barHost,
        /Updates\.runState !== "idle" \|\| Updates\.rebootRecommended/);
    assert.match(bar,
        /stateGlyph:[\s\S]{0,100}rebootRecommended[\s\S]{0,100}"restart_alt"/);
    assert.match(bar,
        /idleColor:\s*chip\.rebootRecommended \? Theme\.barAmber/);
    assert.match(bar,
        /tooltip:[\s\S]{0,300}chip\.rebootRecommended[\s\S]{0,150}rebootLabel/);
});

test("the failure banner leads with the last line that names a problem", () => {
    assert.equal(H.failureHeadline([
        "Running transaction check…",
        "GPG signature check failed: mesa-dri-drivers-25.3.2-1.fc44",
        "Transaction aborted."
    ]), "GPG signature check failed: mesa-dri-drivers-25.3.2-1.fc44");
    assert.equal(H.failureHeadline(["all quiet"]), "");
    assert.equal(H.failureHeadline([]), "");
    assert.equal(H.failureHeadline(["Error: " + "x".repeat(200)]).length, 96,
        "one runaway line cannot take over the banner");
});

test("log stamps match the update script's shelf naming", () => {
    assert.equal(H.logStamp(new Date(2026, 7, 21, 14, 32, 5)), "20260821-143205");
    assert.equal(H.logStamp(new Date(2026, 0, 1, 0, 0, 0)), "20260101-000000");
});

test("log readers accept bytes only for the exact run and source offset", () => {
    assert.equal(H.acceptsLogRead("new", 0, "new", 0, 42, true, 0), true);
    assert.equal(H.acceptsLogRead("new", 0, "old", 0, 42, true, 0), false,
        "a callback from the prior durable run cannot contaminate this run");
    assert.equal(H.acceptsLogRead("new", 24, "new", 0, 42, true, 0), false,
        "overlapping callbacks cannot replay bytes or jump the live offset");
    assert.equal(H.acceptsLogRead("new", 0, "new", 0, 42, false, 0), false,
        "the initial non-running signal is not a successful read");
    assert.equal(H.acceptsLogRead("new", 0, "new", 0, 42, true, 1), false,
        "a failed read must remain retryable without advancing the offset");
    assert.equal(H.acceptsLogRead("new", 42, "new", 42, 42, true, 0), false,
        "an empty interval cannot trigger log consumption");
});

test("status readers cannot cross a local start or dismiss boundary", () => {
    assert.equal(H.acceptsStatusResponse(8, 8, false, true, 0), true);
    assert.equal(H.acceptsStatusResponse(9, 8, false, true, 0), false,
        "the prior status request cannot overwrite a retry response");
    assert.equal(H.acceptsStatusResponse(8, 8, true, true, 0), false,
        "start owns run discovery until its response is handled");
    assert.equal(H.acceptsStatusResponse(8, 8, false, false, 0), false);
    assert.equal(H.acceptsStatusResponse(8, 8, false, true, 1), false);

    const updates = read("Common/Updates.qml");
    assert.match(updates,
        /statusGeneration\+\+;[\s\S]{0,100}?startPreviousStamp = runStamp;[\s\S]{0,100}?startPending = true;[\s\S]{0,100}?resetRun\(/,
        "a local start must invalidate an already-running old status request");
    assert.match(updates,
        /function settleStartRequest\(\)[\s\S]{0,280}?statusGeneration\+\+;[\s\S]{0,80}?startPending = false/,
        "settling a start must invalidate status reads launched before it");
    assert.match(updates,
        /pending\.id !== root\.startPreviousStamp[\s\S]{0,240}?root\.settleStartRequest\(\)/,
        "run discovery must ignore the prior durable status record");
    assert.match(updates, /running: root\.runActive\s*repeat: true/,
        "status polling must continue while the client publishes its new run");
});

test("the QML coordinator settles every check and backend command", () => {
    const updates = read("Common/Updates.qml");
    const popover = read("Popovers/UpdatesPopover.qml");

    assert.match(updates, /readonly property bool busy: !dnfDone \|\| !flatpakDone/);
    assert.match(updates, /function finishCheck\(\) \{\s*if \(!dnfDone \|\| !flatpakDone\)\s*return;/);
    assert.ok((updates.match(/ProcHelpers\.NOT_STARTED/g) || []).length >= 6,
        "check and backend commands need the no-exited-signal fallback, and "
        + "the failure banner names the could-not-start case");
    assert.equal((updates.match(/onRunningChanged:/g) || []).length >= 3, true,
        "each process and the recheck timer should have completion handling");
    assert.doesNotMatch(updates, /onTotalChanged:/,
        "intermediate per-process totals must not drive notifications");
    assert.match(updates, /command: \["timeout", "45s"/,
        "a background poll must have a finite upper bound");
    assert.match(popover, /Accessible\.name:[\s\S]{0,100}?Check for updates/);
    assert.match(popover, /onClicked:[\s\S]{0,100}?Updates\.check\(\)/);
});

test("the menu routes checks and runs through its deployment-aware client", () => {
    const updates = read("Common/Updates.qml");

    assert.match(updates,
        /updateClient:\s*\n?\s*Quickshell\.shellDir \+ "\/scripts\/update-client"/);
    assert.match(updates,
        /const command = \["bash", updateClient, "start"\]/);
    assert.match(updates,
        /runStartProc\.command = command;\s*runStartProc\.running = true;/,
        "the panel owns the short-lived start request and its JSON response");
    assert.doesNotMatch(updates, /"--class", "cybexos-update"/,
        "starting an update must not open an external terminal");
    assert.match(updates,
        /command: \["timeout", "45s", "bash", root\.updateClient, "check"\]/);
    assert.doesNotMatch(updates, /"cybexos", "update"/,
        "Quickshell-only deployments do not install the public CLI");
    assert.doesNotMatch(updates,
        /Quickshell\.env\("HOME"\) \+ "\/\.local\/share\/cybexos\/current\/update"/,
        "the optional release runtime must not be an unconditional process");
});

test("release errors identify GitHub rejection without hiding other causes", () => {
    assert.match(H.projectCheckError("curl: (22) The requested URL returned error: 403"),
        /CybexOS: GitHub.*HTTP 403.*rate limited/);
    assert.equal(H.projectCheckError("network offline"), "CybexOS: network offline");
});

test("a failed project check preserves a usable package summary and explicit action", () => {
    const vm = require("node:vm");
    const source = read("Common/Updates.qml");
    const summary = source.match(/readonly property string summary: \{([\s\S]*?)\n    \}/)[1];
    const state = {busy: false, packageError: "", packagesOnly: true, total: 0,
        dnfCount: 0, flatpakCount: 0, firmwareCount: 0, firmwareError: "", projectAvailable: false};
    assert.equal(vm.runInNewContext("(() => {" + summary + "})()", state),
        "Packages up to date · CybexOS check unavailable");
    state.dnfCount = state.total = 2;
    assert.equal(vm.runInNewContext("(() => {" + summary + "})()", state),
        "dnf 2 · CybexOS check unavailable");
    state.packageError = "dnf failed";
    assert.equal(vm.runInNewContext("(() => {" + summary + "})()", state),
        "Package updates unavailable");
    const panel = read("Popovers/UpdatesPopover.qml");
    assert.match(panel, /Update packages only/);
    assert.match(panel, /onClicked: Updates.run\(Updates.packagesOnly\)/);
});


test("firmware counts devices once and rejects malformed successful responses", () => {
    assert.deepEqual(H.firmwareNames(JSON.stringify({ Devices: [
        { Name: "UEFI dbx", Releases: [{Version: "2"}, {Version: "3"}] },
        { Name: "System Firmware", Releases: [{Version: "5"}] },
        { Name: "Current device", Releases: [] }
    ] })), ["UEFI dbx", "System Firmware"]);
    assert.deepEqual(H.firmwareNames('{"Devices":[]}'), []);
    assert.throws(() => H.firmwareNames('{}'));
    assert.throws(() => H.firmwareNames('not json'));
    assert.match(H.projectCheckError("curl: (22) The requested URL returned error: 404"),
        /no published release.*HTTP 404/);
});

test("firmware completion distinguishes no updates, malformed output and failures", () => {
    const vm = require("node:vm");
    const source = read("Common/Updates.qml");
    const finish = source.match(/function finishFirmware\(exitCode, body, errText\) \{([\s\S]*?)\n    \}/)[1];
    for (const [exitCode, body, failed] of [
        [2, "", false], [0, '{"Devices":[]}', false],
        [0, '{}', true], [124, "", true], [127, "", true]
    ]) {
        let settled = 0;
        const state = {exitCode, body, errText: "", firmwareError: "", firmwareDone: false,
            nextFirmwareNames: ["old"], UpdatesHelpers: H,
            ProcHelpers: load("ProcHelpers.js"), logCheckError() {},
            finishCheck() { settled++; }};
        vm.runInNewContext("(() => {" + finish + "})()", state);
        assert.equal(state.firmwareDone, true);
        assert.equal(settled, 1);
        assert.equal(state.firmwareError !== "", failed);
        assert.equal(state.nextFirmwareNames.length, failed ? 1 : 0);
    }
});

test("a skipped or blocked CybexOS release says why without stopping packages", () => {
    assert.equal(H.projectErrorOf({ id: "run", projectError: "  the GitHub CLI is not logged in  " }),
        "the GitHub CLI is not logged in");
    assert.equal(H.projectErrorOf({ id: "run" }), "");
    assert.equal(H.projectErrorOf({ projectError: 69 }), "");
    assert.equal(H.projectErrorOf(null), "");
    assert.equal(H.projectSkippedLabel("gh is missing", false),
        "System update started · CybexOS skipped: gh is missing");
    assert.equal(H.projectSkippedLabel("gh is missing", true), "CybexOS skipped: gh is missing");
    assert.equal(H.projectSkippedLabel("", false), "");

    const updates = read("Common/Updates.qml");
    const popover = read("Popovers/UpdatesPopover.qml");
    // The start record is the only place the reason travels; a status poll
    // (which never carries it) must not be what sets it, and resetRun clears it.
    assert.match(updates,
        /root\.applyBackendStatus\(started\);\s*root\.runProjectSkipped = UpdatesHelpers\.projectErrorOf\(started\);/);
    assert.match(updates, /function resetRun\([\s\S]*?runProjectSkipped = "";[\s\S]*?runState = "running";/);
    assert.match(updates, /nextProjectApplyNote = UpdatesHelpers\.projectErrorOf\(data\);/);
    assert.match(updates, /projectApplyNote = nextProjectAvailable \? nextProjectApplyNote : "";/);
    assert.match(popover, /UpdatesHelpers\.projectSkippedLabel\(Updates\.runProjectSkipped,/);
    assert.match(popover, /"To apply CybexOS " \+ Updates\.projectVersion \+ ": "\s*\+ Updates\.projectApplyNote/);
});

test("cancel waits for the current step and is offered only while one remains", () => {
    for (const phase of ["queued", "snapshot", "tests", "migration"])
        assert.equal(H.cancelAllowed(phase, true), true, phase);
    assert.equal(H.cancelAllowed("packages", true), true,
        "a deferred cancel lets dnf and flatpak finish first");
    assert.equal(H.cancelAllowed("packages", false), false,
        "a worker from before deferred cancellation refuses mid-transaction");
    assert.equal(H.cancelAllowed("packages", undefined), false);
    for (const phase of ["ansible", "activation", "reboot-check"])
        assert.equal(H.cancelAllowed(phase, true), false, `${phase} has no stopping point left`);

    const updates = read("Common/Updates.qml");
    const popover = read("Popovers/UpdatesPopover.qml");
    assert.match(updates, /cancelRequested = data\.cancelRequested === true;/);
    assert.match(updates, /runDeferredCancel = data\.deferredCancel === true;/);
    assert.match(updates,
        /readonly property bool cancelPending: cancelRequested \|\| cancelProc\.running\s*\|\| cancelSettle\.running/);
    assert.match(updates, /function cancelRun\(\) \{\s*if \(!cancelAllowed \|\| cancelPending\)\s*return;/);
    // The cancel client settles on the falling edge, like every other process.
    assert.match(updates,
        /id: cancelProc\s*onRunningChanged: \{\s*if \(running\)\s*return;\s*cancelSettle\.restart\(\);\s*root\.refreshRunStatus\(\);/);
    assert.match(popover,
        /id: cancelButton\s*visible: root\.mode === "running" && Updates\.cancelAllowed\s*enabled: !Updates\.cancelPending/);
    assert.match(popover, /Updates\.cancelPending \? "cancelling after the current step…"/);
    assert.match(read("Popovers/Drawer/DrawerOverview.qml"),
        /Updates\.cancelPending \? "Cancelling after the current step…"/);
});

test("a failed release apply that left newer files says how to recover", () => {
    assert.equal(H.mixedStateAdvice(false), "");
    assert.equal(H.mixedStateAdvice(undefined), "");
    assert.match(H.mixedStateAdvice(true), /`cybex update` again/);
    assert.match(H.mixedStateAdvice(true), /~\/\.local\/share\/cybexos\/current\/install/);

    const updates = read("Common/Updates.qml");
    assert.match(updates, /mixedState = data\.mixedState === true;/);
    assert.match(read("Popovers/UpdatesPopover.qml"),
        /visible: Updates\.mixedState[\s\S]{0,80}?text: UpdatesHelpers\.mixedStateAdvice\(Updates\.mixedState\)/);
});
