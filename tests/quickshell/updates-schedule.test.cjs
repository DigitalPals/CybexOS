// The update check's scheduling, run against the coordinator's own function
// bodies from Common/Updates.qml: which sources a check starts, when the
// retry budget resets, and which transitions notify. The QML properties are
// plain values here and the processes record their starts, so a scenario
// reads as the sequence of polls and results it describes.
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const { shellDir, load } = require("./shell.cjs");

const H = load("UpdatesHelpers.js");
const P = load("ProcHelpers.js");
const source = fs.readFileSync(path.join(shellDir, "Common/Updates.qml"), "utf8");

function functionSource(name) {
    const match = source.match(new RegExp("^    function " + name + "\\([^]*?^    }", "m"));
    assert.ok(match, `function ${name} not found`);
    return match[0];
}

const FUNCTIONS = ["check", "startCheck", "automaticCheck", "readDnf", "logCheckError",
    "finishDnf", "finishFlatpak", "finishFirmware", "finishProject", "finishCheck"];

// `find -printf '%p %s %T@\n'` output for the dnf signature.
function signature(repomdMtime, rpmdbSize) {
    return [
        `/var/cache/libdnf5/updates-3cc0/repodata/repomd.xml 7055 ${repomdMtime}.0`,
        `/usr/lib/sysimage/rpm/rpmdb.sqlite ${rpmdbSize} 1789998453.4`,
        "/etc/yum.repos.d/fedora.repo 1100 1789000000.0"
    ].join("\n") + "\n";
}

function coordinator() {
    const started = [];
    const notes = [];
    const later = [];
    const proc = name => ({
        signature: "",
        get running() { return false; },
        set running(value) { if (value) started.push(name); }
    });
    const ctx = {
        UpdatesHelpers: H,
        ProcHelpers: P,
        NetworkStatus: { online: true },
        Settings: { modOpts: { updates: { notify: true, flatpak: true, pollMins: 30 } } },
        Quickshell: { execDetached: argv => notes.push(argv) },
        Qt: { callLater: (fn, ...args) => later.push(() => fn(...args)) },
        console: { warn() {} },
        dnfProc: proc("dnf"),
        dnfSignatureProc: proc("signature"),
        flatpakProc: proc("flatpak"),
        firmwareProc: proc("firmware"),
        projectProc: proc("project"),
        recheck: { restart() {}, stop() {} },

        dnfCount: 0, dnfNames: [], nextDnfNames: [], dnfError: "", dnfDone: true,
        flatpakCount: 0, flatpakNames: [], nextFlatpakNames: [], flatpakError: "",
        flatpakDone: true, checkingFlatpak: false, flatpakEnabled: true,
        firmwareCount: 0, firmwareNames: [], nextFirmwareNames: [], firmwareError: "",
        firmwareDone: true, firmwareInstalling: false,
        projectUpdatesEnabled: false, projectAvailable: false, projectVersion: "",
        nextProjectAvailable: false, nextProjectVersion: "", projectError: "", projectDone: true,
        ran: false, baselines: {}, lastChecked: 0, error: "", wasPending: false,
        checkParts: H.allParts(), checkAgain: false, checkAgainForced: false,
        checkFailureCount: 0, dnfCacheSignature: "", dnfCacheNames: [], dnfCacheAt: 0,
        dnfForced: false,
        postRunCheck: 0, lastLoggedCheckError: "", runState: "idle", runActive: false,
        runIncludedFlatpak: true
    };
    Object.defineProperty(ctx, "busy", {
        get() { return !ctx.dnfDone || !ctx.flatpakDone || !ctx.projectDone || !ctx.firmwareDone; }
    });
    Object.defineProperty(ctx, "total", {
        get() {
            return ctx.dnfCount + ctx.flatpakCount + ctx.firmwareCount
                + (ctx.projectAvailable ? 1 : 0);
        }
    });
    ctx.root = ctx;
    vm.createContext(ctx);
    for (const name of FUNCTIONS)
        vm.runInContext(functionSource(name), ctx);

    // One round: answer each source as it starts. The signature comes
    // first and decides whether dnf itself runs; its default is a listing
    // that never changes.
    function answer(results) {
        const round = [];
        while (started.length > 0) {
            const name = started.shift();
            round.push(name);
            if (name === "signature") {
                ctx.readDnf(H.dnfSignature(results.signature || signature(1, 100)));
                continue;
            }
            const [code, body, err] = results[name];
            if (name === "dnf")
                ctx.finishDnf(code, body, err || "", ctx.dnfProc.signature);
            else if (name === "flatpak")
                ctx.finishFlatpak(code, body, err || "");
            else if (name === "firmware")
                ctx.finishFirmware(code, body, err || "");
            else
                ctx.finishProject(code, body, err || "");
        }
        return round;
    }
    return { ctx, started, notes, later, answer };
}

const DNF_NONE = [0, ""];
const dnfPending = n => [100, Array.from({ length: n },
    (_, i) => `pkg${i}.x86_64  1-1.fc44  updates`).join("\n")];
const FLATHUB_DOWN = [1, "", "error: Unable to load summary from remote flathub"];
const FIRMWARE_NONE = [2, ""];

test("a permanently failing source retries only itself, and polls do not refill the budget", () => {
    const { ctx, answer } = coordinator();
    ctx.automaticCheck(true, false);
    assert.deepEqual(answer({ dnf: DNF_NONE, flatpak: FLATHUB_DOWN, firmware: FIRMWARE_NONE }),
        ["signature", "flatpak", "firmware", "dnf"]);
    assert.equal(ctx.checkFailureCount, 1);
    assert.notEqual(ctx.error, "");

    // The retry timer asks for the failed parts only.
    ctx.automaticCheck(false, true);
    assert.deepEqual(answer({ flatpak: FLATHUB_DOWN }), ["flatpak"],
        "dnf and fwupd answered; a Flathub outage must not rerun them");
    assert.equal(ctx.checkFailureCount, 2);

    // The regular poll runs everything but keeps counting failures, so the
    // four-retry budget is spent once per online edge, not once per poll.
    ctx.automaticCheck(false, false);
    answer({ dnf: DNF_NONE, flatpak: FLATHUB_DOWN, firmware: FIRMWARE_NONE });
    assert.equal(ctx.checkFailureCount, 3);

    // The online edge and a manual refresh do reset it.
    ctx.automaticCheck(true, false);
    assert.equal(ctx.checkFailureCount, 0);
    answer({ dnf: DNF_NONE, flatpak: FLATHUB_DOWN, firmware: FIRMWARE_NONE });
    ctx.check();
    assert.equal(ctx.checkFailureCount, 0);
    answer({ dnf: DNF_NONE, flatpak: [0, "Firefox\n"], firmware: FIRMWARE_NONE });
    assert.equal(ctx.checkFailureCount, 0, "an all-success check clears the count");
    assert.equal(ctx.error, "");
});

test("a failed-only retry keeps the answers it did not repeat", () => {
    const { ctx, answer } = coordinator();
    ctx.automaticCheck(true, false);
    answer({ dnf: dnfPending(2), flatpak: FLATHUB_DOWN, firmware: FIRMWARE_NONE });
    assert.equal(ctx.dnfCount, 2);
    ctx.automaticCheck(false, true);
    answer({ flatpak: [0, "Firefox\nSpotify\n"] });
    assert.equal(ctx.dnfCount, 2, "dnf's last answer stands");
    assert.equal(ctx.flatpakCount, 2);
    assert.equal(ctx.total, 4);
    assert.equal(ctx.error, "");
});

test("dnf keeps notifying while Flathub never answers", () => {
    const { ctx, notes, answer } = coordinator();
    ctx.automaticCheck(true, false);
    answer({ dnf: DNF_NONE, flatpak: FLATHUB_DOWN, firmware: FIRMWARE_NONE });
    assert.equal(notes.length, 0);
    ctx.automaticCheck(false, false);
    answer({ signature: signature(2, 100), dnf: dnfPending(3), flatpak: FLATHUB_DOWN,
        firmware: FIRMWARE_NONE });
    assert.equal(notes.length, 1, "a known dnf going from zero to three is news");
    assert.equal(notes[0][2], "3 updates ready");
    assert.equal(notes[0][3], "dnf 3", "the body lists what is pending, not the Flathub error");
});

test("each source's first answer is silent, even after a failed first attempt", () => {
    const { ctx, notes, answer } = coordinator();
    ctx.automaticCheck(true, false);
    answer({ dnf: [1, "", "Cache-only enabled but no cache"], flatpak: FLATHUB_DOWN,
        firmware: FIRMWARE_NONE });
    ctx.automaticCheck(false, false);
    answer({ dnf: dnfPending(4), flatpak: FLATHUB_DOWN, firmware: FIRMWARE_NONE });
    assert.equal(notes.length, 0, "updates pending before login are not news");
    assert.equal(ctx.dnfCount, 4);
});

test("only the online edge, startup and settings changes refill the retry budget", () => {
    assert.match(source, /checkFailureCount <= 4[\s\S]{0,200}?onTriggered: root\.automaticCheck\(false, true\)/,
        "the retry timer repeats only what failed");
    assert.match(source, /interval: root\.pollMs[\s\S]{0,200}?onTriggered: root\.automaticCheck\(false, false\)/,
        "the regular poll must not reset the failure count");
    assert.match(source, /function onOnlineChanged\(\)[\s\S]{0,600}?root\.automaticCheck\(true, false\)/);
    assert.match(functionSource("check"), /checkFailureCount = 0;/,
        "a manual refresh earns a fresh set of retries");
    assert.doesNotMatch(source, /hasBaseline/, "the baseline is tracked per source");
});

test("background checks run only for the widget or notifications, never while idle", () => {
    const body = source.match(/readonly property bool pollEnabled: \{([\s\S]*?)\n    \}/)[1];
    const enabled = (notify, on) => vm.runInNewContext("(() => {" + body + "})()", {
        Settings: {
            modOpts: { updates: { notify } },
            mods: { left: [], center: [], right: on === undefined ? [] : [{ id: "updates", on }] }
        }
    });
    assert.equal(enabled(true, false), true, "notifications need a background count");
    assert.equal(enabled(false, true), true, "so does the menubar widget");
    assert.equal(enabled(false, false), false);
    assert.equal(enabled(false, undefined), false);

    assert.match(source,
        /interval: root\.pollMs\s*running: NetworkStatus\.online && root\.pollEnabled && !Activity\.idle/);
    assert.match(source, /checkFailureCount <= 4[\s\S]{0,120}?!Activity\.idle/,
        "retries wait for the session too");
    assert.match(source,
        /target: Activity[\s\S]{0,80}function onResumed\(\)[\s\S]{0,120}root\.staleCheck\(\)/);
    assert.match(functionSource("staleCheck"),
        /UpdatesHelpers\.checkIsFresh\(lastChecked, Date\.now\(\), pollMs\)/);
    // The drawer and the Updates panel still count when background checks are off.
    assert.match(source,
        /Popouts\.currentName === "updates"\s*\|\| Popouts\.currentName === "control"\s*&& Settings\.drawerOverview\.updates === true\)\)\s*root\.staleCheck\(\)/);
    assert.match(source, /id: startupCheck[\s\S]{0,200}?if \(root\.pollEnabled && !root\.ran && !root\.busy\)/);
});

test("dnf reruns only when its metadata or the installed set moved", () => {
    const { ctx, answer } = coordinator();
    ctx.automaticCheck(true, false);
    assert.ok(answer({ dnf: dnfPending(2), flatpak: [0, ""], firmware: FIRMWARE_NONE })
        .includes("dnf"), "the first read is real");

    // The next poll: same metadata, same rpmdb.
    ctx.automaticCheck(false, false);
    assert.ok(!answer({ flatpak: [0, ""], firmware: FIRMWARE_NONE }).includes("dnf"),
        "an unchanged signature reuses the answer");
    assert.equal(ctx.dnfCount, 2);

    // makecache fetched new metadata.
    ctx.automaticCheck(false, false);
    assert.ok(answer({ signature: signature(2, 100), dnf: dnfPending(5), flatpak: [0, ""],
        firmware: FIRMWARE_NONE }).includes("dnf"));
    assert.equal(ctx.dnfCount, 5);

    // A dnf upgrade in a terminal rewrote the rpmdb.
    ctx.automaticCheck(false, false);
    assert.ok(answer({ signature: signature(2, 200), dnf: DNF_NONE, flatpak: [0, ""],
        firmware: FIRMWARE_NONE }).includes("dnf"));
    assert.equal(ctx.dnfCount, 0);

    // A manual refresh (and the recount after a run) always reads.
    ctx.check();
    assert.ok(answer({ signature: signature(2, 200), dnf: dnfPending(1), flatpak: [0, ""],
        firmware: FIRMWARE_NONE }).includes("dnf"));
    assert.equal(ctx.dnfCount, 1);
});

test("a failed dnf read or an unreadable signature is never reused", () => {
    const { ctx, answer } = coordinator();
    ctx.automaticCheck(true, false);
    answer({ dnf: [1, "", "Cache-only enabled but no cache"], flatpak: [0, ""],
        firmware: FIRMWARE_NONE });
    ctx.automaticCheck(false, false);
    assert.ok(answer({ dnf: DNF_NONE, flatpak: [0, ""], firmware: FIRMWARE_NONE })
        .includes("dnf"), "a failure leaves nothing to reuse");
    ctx.automaticCheck(false, false);
    assert.ok(answer({ signature: "/var/cache/libdnf5/x/repodata/repomd.xml 1 2.0\n",
        dnf: DNF_NONE, flatpak: [0, ""], firmware: FIRMWARE_NONE }).includes("dnf"),
        "a listing without the rpm database cannot vouch for the installed set");
});

test("the dnf signature is order-free, needs the rpmdb, and expires", () => {
    const listing = signature(1, 100);
    const reversed = listing.trim().split("\n").reverse().join("\n");
    assert.equal(H.dnfSignature(listing), H.dnfSignature(reversed));
    assert.equal(H.dnfSignature("/var/cache/libdnf5/x/repodata/repomd.xml 1 2.0"), "");
    assert.equal(H.dnfSignature(""), "");
    const sig = H.dnfSignature(listing);
    assert.equal(H.dnfAnswerReusable(sig, sig, 1000, 1000 + 60000), true);
    assert.equal(H.dnfAnswerReusable(sig, sig, 1000, 1000 + H.DNF_ANSWER_MAX_AGE_MS), false,
        "a real read still happens every few hours");
    assert.equal(H.dnfAnswerReusable("", "", 1000, 2000), false);
    assert.equal(H.dnfAnswerReusable(sig, H.dnfSignature(signature(1, 101)), 1000, 2000), false);

    assert.match(source, /id: dnfSignatureProc[\s\S]{0,400}?command: \["timeout", "10s", "find", "\/var\/cache\/libdnf5",\s*"\/usr\/lib\/sysimage\/rpm"/);
    assert.match(source, /"-name", "repomd\.xml"/);
    assert.match(source, /"-printf", "%p %s %T@\\\\n"\]/);
});
