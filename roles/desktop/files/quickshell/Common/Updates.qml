pragma Singleton
import QtQuick
import QtQml.Models
import Quickshell
import Quickshell.Io
import "ProcHelpers.js" as ProcHelpers
import "UpdatesHelpers.js" as UpdatesHelpers

// Pending updates: dnf packages, Flatpak refs, firmware and CybexOS releases.
// Everything installs inside the shell: packages and firmware are phases of
// one durable run, and fwupd's device requests arrive as events the panel
// shows in place of a terminal prompt.
//
// Polling is inherent here — there is nothing to subscribe to — so this is one
// timer, at the interval the module's settings choose, plus a manual refresh
// from the panel. Background checks do not install updates.
//
// The dnf side is deliberately `--cacheonly`: a refreshing check-update can
// stop to ask whether to import a repository's signing key, and a shell poller
// has no terminal to answer with — it simply hangs. Reading the cache that
// dnf-makecache.timer already keeps warm is both the honest and the cheap
// answer, and it is what the panel's footnote says it is doing.
//
// The privileged run belongs to a transient service and publishes an
// atomic status record plus append-only logs. This singleton is a client: it
// can be destroyed by a config hot reload and attach to the same run again.
Singleton {
    id: root

    property int dnfCount: 0
    // The two facts about pending system packages worth a line of their own:
    // a new kernel (it means a restart) and security fixes.
    property string dnfKernel: ""
    property int dnfSecurityCount: 0
    property bool dnfSecuritySevere: false
    readonly property string systemDetail: UpdatesHelpers.systemDetail(
        dnfKernel, dnfSecurityCount, dnfSecuritySevere)
    // [{ id, name, from, to, needsReboot, requireAc }] per device.
    property var firmwareDevices: []
    property var nextFirmwareDevices: []
    readonly property int firmwareCount: firmwareDevices.length
    property string firmwareError: ""
    property bool firmwareDone: true
    // fwupd refuses some flashes on battery. Rather than let the run fail
    // there, the firmware waits for power and the rest of the update goes on.
    readonly property bool firmwareNeedsPower: Battery.isLaptop
        && !Battery.pluggedIn
        && firmwareDevices.some(device => device.requireAc)
    readonly property bool firmwareInRun: firmwareCount > 0 && !firmwareNeedsPower
    property int flatpakCount: 0
    // The release check needs no GitHub login. A channel with nothing
    // published yet is a neutral answer (projectStatus), not a check failure.
    readonly property bool projectUpdatesEnabled: true
    property bool projectAvailable: false
    property string projectVersion: ""
    // Why an available release cannot be applied here yet (gh missing or too
    // old to verify it); the release still counts as pending.
    property string projectApplyNote: ""
    // "no-release" while the channel has no published release, else "".
    property string projectStatus: ""
    readonly property string projectNote: UpdatesHelpers.projectStatusLabel(projectStatus)
    property var dnfNames: []
    property var flatpakNames: []
    property bool ran: false
    // Which sources have answered at least once this session. A source's
    // first answer is its baseline and stays silent, even if an earlier
    // attempt could not run; see UpdatesHelpers.shouldNotify.
    property var baselines: ({})
    property double lastChecked: 0
    property string error: ""

    property bool dnfDone: true
    property bool flatpakDone: true
    property bool projectDone: true
    readonly property bool busy: !dnfDone || !flatpakDone || !projectDone || !firmwareDone

    // Results stay private until all checks finish. Publishing each stream
    // as it closes makes total briefly describe a half-completed check and can
    // fire a notification for a state that never existed.
    property var nextDnfNames: []
    property string nextDnfKernel: ""
    property var nextDnfSecurity: ({ count: 0, severe: false })
    property var nextFlatpakNames: []
    property bool nextProjectAvailable: false
    property string nextProjectVersion: ""
    property string nextProjectApplyNote: ""
    property string nextProjectStatus: ""
    property string dnfError: ""
    property string flatpakError: ""
    property string projectError: ""
    property bool checkingFlatpak: false
    // The sources the running check covers (UpdatesHelpers.allParts or
    // failedParts); the others keep their last answer.
    property var checkParts: UpdatesHelpers.allParts()
    property bool checkAgain: false
    property bool checkAgainForced: false
    // dnf answers from repository metadata that dnf5-makecache.timer
    // refreshes every few hours and an installed set that rarely changes,
    // yet each read costs most of a CPU-second and 200 MB. While the
    // signature of both (UpdatesHelpers.dnfSignature) matches the last
    // successful read's, that answer stands. A manual refresh and the
    // recount after a run force a real read.
    property string dnfCacheSignature: ""
    property var dnfCacheNames: []
    property string dnfCacheKernel: ""
    property var dnfCacheSecurity: ({ count: 0, severe: false })
    property double dnfCacheAt: 0
    property bool dnfForced: false
    property bool initialized: false
    property int checkFailureCount: 0
    // 0 = no post-run recount owed; 1 = the recount right after a run;
    // 2 = its single delayed retry. See postRunRetryNeeded.
    property int postRunCheck: 0
    property string lastLoggedCheckError: ""

    readonly property string packageError: [dnfError, flatpakError]
        .filter(value => value !== "").join(" · ");
    readonly property bool packagesOnly: projectError !== "";

    readonly property int total: dnfCount + flatpakCount + firmwareCount + (projectAvailable ? 1 : 0)
    readonly property bool flatpakEnabled: Settings.modOpts.updates.flatpak
    readonly property int pollMs: Math.max(10, Settings.modOpts.updates.pollMins) * 60000

    // Background checks serve the menubar widget and the notification; with
    // both off nothing reads a count until a view opens, and opening one
    // checks then (see the Popouts connection below). Settings.mods is
    // replaced wholesale on every edit, so this follows the widget list.
    readonly property bool pollEnabled: {
        if (Settings.modOpts.updates.notify)
            return true;
        const mods = Settings.mods;
        for (const col of ["left", "center", "right"]) {
            const hit = mods[col].find(m => m.id === "updates");
            if (hit)
                return hit.on;
        }
        return false;
    }

    // Once the count has been non-zero and then falls to zero, the panel says
    // so rather than pretending nothing was ever pending.
    property bool wasPending: false

    // Which sources could not be checked, in one sentence ("" when all
    // answered). The reasons themselves are in `error`.
    readonly property string checkError: UpdatesHelpers.checkErrorLabel({
        dnf: dnfError, flatpak: flatpakError, firmware: firmwareError,
        project: projectError })

    // The one-line answer the bar tooltip and the overview card give.
    readonly property string summary: {
        if (busy)
            return "Checking for updates…";
        if (total > 0)
            return total + (total === 1 ? " update" : " updates") + " available";
        if (checkError !== "")
            return checkError;
        return "Up to date";
    }

    // The session remembers whether the panel's details were open, so the
    // transcript is where it was left when the panel comes back.
    property bool detailsOpen: false

    function checkedLabel() {
        if (lastChecked === 0)
            return "Not checked yet";
        const mins = Math.floor((Date.now() - lastChecked) / 60000);
        if (mins < 1)
            return "Checked just now";
        if (mins < 60)
            return "Checked " + mins + " min ago";
        const hours = Math.floor(mins / 60);
        return "Checked " + hours + (hours === 1 ? " hour ago" : " hours ago");
    }

    // A first few names for a row's subtitle ("Signal, Firefox and 2 more").
    //
    // Deduplicated, because a multiarch package appears once per architecture
    // and "SDL3, SDL3" reads as a bug. The row's count stays raw: it has to
    // agree with what `dnf upgrade` is about to list.
    function namesLabel(list, count) {
        const unique = uniqueNames(list);
        if (unique.length === 0)
            return count > 0 ? count + " pending" : "";
        const shown = unique.slice(0, 3);
        const rest = unique.length - shown.length;
        return shown.join(", ") + (rest > 0 ? " and " + rest + " more" : "");
    }

    function uniqueNames(list) {
        const unique = [];
        for (const name of list || []) {
            if (unique.indexOf(name) === -1)
                unique.push(name);
        }
        return unique;
    }

    // The panel's refresh, and the recount after a run: every source, and
    // a fresh set of retries if something still fails.
    function check() {
        checkFailureCount = 0;
        startCheck(UpdatesHelpers.allParts(), true);
    }

    function startCheck(parts, forced) {
        // A poll firing mid-transaction would read the cache while dnf is
        // rewriting the installed set; whatever it said would be wrong by the
        // time it landed. finishRun schedules the recount instead.
        if (runActive)
            return;
        if (busy) {
            checkAgain = true;
            checkAgainForced = checkAgainForced || forced === true;
            return;
        }
        checkAgain = false;
        checkAgainForced = false;
        checkParts = parts;
        if (parts.dnf) {
            dnfError = "";
            nextDnfNames = [];
            nextDnfKernel = "";
            nextDnfSecurity = ({ count: 0, severe: false });
            dnfDone = false;
            dnfForced = forced === true;
        }
        if (parts.flatpak) {
            flatpakError = "";
            nextFlatpakNames = [];
            checkingFlatpak = flatpakEnabled;
            flatpakDone = !checkingFlatpak;
        }
        if (parts.project) {
            projectError = "";
            nextProjectAvailable = false;
            nextProjectVersion = "";
            nextProjectApplyNote = "";
            nextProjectStatus = "";
            projectDone = !projectUpdatesEnabled;
        }
        if (parts.firmware) {
            firmwareError = "";
            nextFirmwareDevices = [];
            firmwareDone = false;
        }
        error = [dnfError, flatpakError, projectError, firmwareError]
            .filter(value => value !== "").join(" · ");
        // Nothing left to ask (only a disabled source was due): settle now.
        if (!busy) {
            finishCheck();
            return;
        }
        if (parts.dnf)
            dnfSignatureProc.running = true;
        if (parts.flatpak && checkingFlatpak)
            flatpakProc.running = true;
        if (parts.project && projectUpdatesEnabled)
            projectProc.running = true;
        if (parts.firmware)
            firmwareProc.running = true;
    }

    // Automatic work waits for NetworkManager's global connected state.
    // Manual refresh remains an explicit attempt, even on a network whose
    // connectivity check is conservative or unavailable. Only the online
    // edge restarts the retry budget: a scheduled poll must not, or a source
    // that always fails would be retried four more times after every poll.
    function automaticCheck(resetRetries, failedOnly) {
        if (!NetworkStatus.online)
            return;
        if (resetRetries)
            checkFailureCount = 0;
        startCheck(failedOnly ? UpdatesHelpers.failedParts({ dnf: dnfError,
            flatpak: flatpakError, firmware: firmwareError, project: projectError })
            : UpdatesHelpers.allParts(), false);
    }

    // The signature is in: reuse the last answer, or ask dnf for real.
    function readDnf(signature) {
        if (!dnfForced && UpdatesHelpers.dnfAnswerReusable(signature,
                dnfCacheSignature, dnfCacheAt, Date.now())) {
            nextDnfNames = dnfCacheNames;
            nextDnfKernel = dnfCacheKernel;
            nextDnfSecurity = dnfCacheSecurity;
            dnfDone = true;
            finishCheck();
            return;
        }
        dnfProc.signature = signature;
        dnfProc.running = true;
    }

    function logCheckError(reason) {
        if (reason === lastLoggedCheckError)
            return;
        console.warn("update check:", reason);
        lastLoggedCheckError = reason;
    }

    function finishDnf(exitCode, body, errText, signature) {
        if (exitCode === 0 || exitCode === 100) {
            nextDnfNames = UpdatesHelpers.dnfNames(body);
            nextDnfKernel = UpdatesHelpers.dnfKernelVersion(body);
            dnfCacheSignature = signature || "";
            dnfCacheNames = nextDnfNames;
            dnfCacheKernel = nextDnfKernel;
            dnfCacheSecurity = ({ count: 0, severe: false });
            dnfCacheAt = Date.now();
            // Security advisories only matter for packages that are pending,
            // and cost a second dnf read; skip it when nothing is.
            if (nextDnfNames.length > 0) {
                dnfSecurityProc.running = true;
                return;
            }
        } else {
            dnfCacheSignature = "";
            dnfError = ProcHelpers.commandError("dnf check-update", exitCode, errText,
                ({ 124: "dnf check-update timed out" }));
            logCheckError(dnfError);
        }
        dnfDone = true;
        finishCheck();
    }

    // The advisory list is a detail of the dnf answer, not a source of its
    // own: when it cannot be read the row just says less.
    function finishDnfSecurity(exitCode, body) {
        if (exitCode === 0) {
            try {
                nextDnfSecurity = UpdatesHelpers.securityAdvisories(body);
            } catch (exception) {
                nextDnfSecurity = ({ count: 0, severe: false });
            }
        } else {
            console.warn("update check: dnf advisory list exited with status", exitCode);
        }
        dnfCacheSecurity = nextDnfSecurity;
        dnfDone = true;
        finishCheck();
    }

    function finishFlatpak(exitCode, body, errText) {
        if (exitCode === 0) {
            nextFlatpakNames = UpdatesHelpers.flatpakNames(body);
        } else {
            flatpakError = ProcHelpers.commandError("flatpak update check", exitCode, errText,
                ({ 124: "Flatpak update check timed out" }));
            logCheckError(flatpakError);
        }
        flatpakDone = true;
        finishCheck();
    }

    function finishFirmware(exitCode, body, errText) {
        if (exitCode === 2) {
            nextFirmwareDevices = [];
        } else if (exitCode === 0) {
            try {
                nextFirmwareDevices = UpdatesHelpers.firmwareDevices(body);
            } catch (exception) {
                firmwareError = "Firmware update check returned invalid data";
            }
        } else {
            firmwareError = ProcHelpers.commandError("Firmware update check",
                exitCode, errText, ({ 124: "Firmware update check timed out" }));
        }
        if (firmwareError !== "")
            logCheckError(firmwareError);
        firmwareDone = true;
        finishCheck();
    }

    function finishProject(exitCode, body, errText) {
        if (exitCode === 0) {
            try {
                const data = JSON.parse(body);
                nextProjectAvailable = data.available === true;
                nextProjectVersion = typeof data.availableVersion === "string"
                    ? data.availableVersion : "";
                nextProjectApplyNote = UpdatesHelpers.projectErrorOf(data);
                nextProjectStatus = UpdatesHelpers.projectStatusOf(data);
            } catch (exception) {
                projectError = "CybexOS update check returned invalid data";
            }
        } else {
            projectError = ProcHelpers.commandError("CybexOS update check",
                exitCode, errText, ({ 124: "CybexOS update check timed out" }));
            projectError = UpdatesHelpers.projectCheckError(projectError);
            logCheckError(projectError);
        }
        projectDone = true;
        finishCheck();
    }

    function finishCheck() {
        if (!dnfDone || !flatpakDone)
            return;
        if (!projectDone || !firmwareDone)
            return;

        const parts = checkParts;
        const previousTotal = total;
        const errors = [dnfError, flatpakError, projectError, firmwareError].filter(value => value !== "");
        const complete = errors.length === 0;
        // What answered this check, and whether it had answered before.
        const answered = [];
        const known = Object.assign({}, baselines);

        if (parts.dnf && dnfError === "") {
            dnfNames = nextDnfNames;
            dnfCount = nextDnfNames.length;
            dnfKernel = nextDnfKernel;
            dnfSecurityCount = nextDnfSecurity.count;
            dnfSecuritySevere = nextDnfSecurity.severe;
            answered.push({ baseline: !!known.dnf, count: dnfCount });
            known.dnf = true;
        }
        if (parts.flatpak && (!checkingFlatpak || flatpakError === "")) {
            flatpakNames = checkingFlatpak ? nextFlatpakNames : [];
            flatpakCount = flatpakNames.length;
            if (checkingFlatpak) {
                answered.push({ baseline: !!known.flatpak, count: flatpakCount });
                known.flatpak = true;
            }
        }
        if (parts.project && projectError === "") {
            projectAvailable = nextProjectAvailable;
            projectVersion = nextProjectVersion;
            projectApplyNote = nextProjectAvailable ? nextProjectApplyNote : "";
            projectStatus = nextProjectStatus;
            if (projectUpdatesEnabled) {
                answered.push({ baseline: !!known.project, count: projectAvailable ? 1 : 0 });
                known.project = true;
            }
        }
        if (parts.firmware && firmwareError === "") {
            firmwareDevices = nextFirmwareDevices;
            answered.push({ baseline: !!known.firmware, count: firmwareCount });
            known.firmware = true;
        }
        const nextTotal = dnfCount + flatpakCount + firmwareCount + (projectAvailable ? 1 : 0);

        error = errors.join(" · ");
        lastChecked = Date.now();
        ran = true;
        if (nextTotal > 0)
            wasPending = true;

        if (UpdatesHelpers.shouldNotify(previousTotal, nextTotal, answered,
                Settings.modOpts.updates.notify)) {
            Quickshell.execDetached(["notify-send", "--app-name=Updates",
                nextTotal + (nextTotal === 1 ? " update ready" : " updates ready"),
                UpdatesHelpers.pendingSummary(dnfCount, flatpakCount, firmwareCount,
                    projectAvailable, projectVersion)]);
        }
        baselines = known;
        if (complete) {
            checkFailureCount = 0;
            lastLoggedCheckError = "";
        } else {
            checkFailureCount++;
        }

        if (postRunCheck === 1 && UpdatesHelpers.postRunRetryNeeded(complete,
                runState, dnfCount, flatpakCount, runIncludedFlatpak)) {
            postRunCheck = 2;
            recheck.restart();
        } else {
            postRunCheck = 0;
        }

        if (checkAgain)
            Qt.callLater(root.startCheck, UpdatesHelpers.allParts(), checkAgainForced);
    }

    // ---- the native run ---------------------------------------------------
    // idle | running | done | failed. `done` clears once the user has opened
    // and closed the finished panel (or after a quiet timeout); `failed`
    // stays until dismissed or retried, so an unattended failure cannot
    // vanish. The feed is a ListModel so the transcript appends in place —
    // reassigning a var array would reset the view and lose scrollback.
    property string runState: "idle"
    readonly property bool runActive: runState === "running"
    property double runStartedAt: 0
    property double runFinishedAt: 0
    property int runElapsed: 0
    property int runDuration: 0
    property string runStamp: ""
    // resolving -> downloading -> installing, keyed off dnf's own milestones.
    property string dnfPhase: "resolving"
    // The table section currently streaming in; "" outside the table.
    property string tableVerb: ""
    // Feed index of the row the transaction most recently completed.
    property int lastDoneIndex: -1
    property int dnfCur: 0
    property int dnfTotal: 0
    property int fpCur: 0
    property int fpTotal: 0
    property bool runDnfDone: true
    property bool runFpDone: true
    property bool runFwDone: true
    property int runDnfRc: 0
    property int runFpRc: 0
    property int runFwRc: 0
    // The firmware phase, from the worker's event stream: devices finished
    // of those planned, the one being written and fwupd's word for what it
    // is doing, and anything fwupd asks the person to do.
    property int fwCur: 0
    property int fwTotal: 0
    property int fwPercent: 0
    property string fwStatus: ""
    // The current device's share done, across fwupd's restarting stages.
    // Devices order their stages differently (a restart before or after
    // verification), so it only ever moves forward within one device.
    property real fwFraction: 0
    property string fwActiveName: ""
    property string fwRequest: ""
    property var fwNotes: []
    property int fwInstalled: 0
    property int fwFailed: 0
    property string fwFailMessage: ""
    property bool fwNeedsReboot: false
    // Feed rows of planned devices, by fwupd device id.
    property var fwRows: ({})
    // What the run was started with, for its rows and its progress weights;
    // null when this client attached to a run it did not start.
    property var runPlan: null
    property string runPlanStamp: ""
    property int upCount: 0
    property int addCount: 0
    property int delCount: 0
    property int appCount: 0
    property var topNames: []
    property string kernelPending: ""
    property string failHeadline: ""
    property var failTail: []
    property var rawTail: []
    property string fpWarning: ""
    // The failure in one sentence (UpdatesHelpers.friendlyFailure); dnf's
    // own words are failHeadline and failTail.
    property string failMessage: ""
    property bool runCancelled: false
    // Fedora's needs-restarting result is authoritative. The kernel parsed
    // from dnf's transcript is optional explanatory detail only.
    property string bootId: ""
    property string rebootRecommendation: "unavailable"
    readonly property bool rebootRecommended:
        rebootRecommendation === "recommended"
    // The finished panel has been opened; closing it then retires `done`.
    property bool runSeen: false
    readonly property string runBackend:
        Quickshell.env("HOME") + "/.local/bin/cybexos-update-run"
    readonly property string updateClient:
        Quickshell.shellDir + "/scripts/update-client"
    property bool runIncludedFlatpak: true
    property bool runIncludedFirmware: false
    property int dnfLogOffset: 0
    property int flatpakLogOffset: 0
    property int firmwareLogOffset: 0
    property int wantedDnfBytes: 0
    property int wantedFlatpakBytes: 0
    property int wantedFirmwareBytes: 0
    property string dnfLogCarry: ""
    property string flatpakLogCarry: ""
    property string firmwareLogCarry: ""
    property string backendTerminalState: ""
    property string backendMessage: ""
    property string backendPhase: ""
    property string recoveryPointId: ""
    property double backendFinishedAt: 0
    // Why this run's CybexOS release step was skipped while its package
    // update went ahead. Only the start record carries it, so a shell
    // reload mid-run forgets it; the run log keeps it.
    property string runProjectSkipped: ""
    // The worker finishes its current step before it honours a cancel.
    property bool cancelRequested: false
    property bool runDeferredCancel: false
    readonly property bool cancelPending: cancelRequested || cancelProc.running
        || cancelSettle.running
    readonly property bool cancelAllowed: runActive && runStamp !== ""
        && UpdatesHelpers.cancelAllowed(backendPhase, runDeferredCancel)
    // A release apply stopped after Ansible began (see mixedStateAdvice).
    property bool mixedState: false
    // Status requests are deliberately subordinate to a local start. A retry
    // must not accept the old run's final status after the start client has
    // already returned the new durable run.
    property int statusGeneration: 0
    property bool startPending: false
    property string startPreviousStamp: ""
    property int startPollCount: 0

    // Streams restart their counters (dnf downloads, then installs), so the
    // published percentage only ever moves forward within one run.
    readonly property int runProgressNow: UpdatesHelpers.runProgress({
        dnfPhase: dnfPhase, dnfCur: dnfCur, dnfTotal: dnfTotal,
        dnfDone: runDnfDone, dnfPlanned: runPlan ? runPlan.dnf : 0,
        fpIncluded: runIncludedFlatpak, fpCur: fpCur, fpTotal: fpTotal,
        fpDone: runFpDone, fpPlanned: runPlan ? runPlan.flatpak : 0,
        fwIncluded: runIncludedFirmware, fwCur: fwCur, fwTotal: fwTotal,
        fwFraction: fwFraction, fwDone: runFwDone,
        fwPlanned: runPlan ? runPlan.firmware : 0
    })
    property int runPercent: -1
    onRunProgressNowChanged: {
        if (runActive && runProgressNow > runPercent)
            runPercent = runProgressNow;
    }
    readonly property int runPkgCount: upCount + addCount + delCount
    readonly property string runPhaseLabel: UpdatesHelpers.runPhaseLabel({
        cancelPending: cancelPending, phase: backendPhase, dnfPhase: dnfPhase,
        dnfDone: runDnfDone, fpIncluded: runIncludedFlatpak, fpDone: runFpDone,
        fwStatus: fwStatus, fwName: fwActiveName
    })

    ListModel {
        id: feedModel
    }
    // Feed rows still waiting for their progress line, by package name
    // (UpdatesHelpers.takePendingRow). Plain JS state: nothing binds to it.
    property var pendingRows: ({})
    readonly property ListModel feed: feedModel

    function settleStartRequest() {
        if (!startPending)
            return;
        // Invalidate any status read launched while the old current record
        // was still visible. Its response must not replace the new run (or a
        // precise start failure) after this boundary has settled.
        statusGeneration++;
        startPending = false;
    }

    function resetRun(runId, startedAt, includedFlatpak, includedFirmware) {
        feedModel.clear();
        pendingRows = ({});
        dnfCur = 0;
        dnfTotal = 0;
        fpCur = 0;
        fpTotal = 0;
        upCount = 0;
        addCount = 0;
        delCount = 0;
        appCount = 0;
        topNames = [];
        kernelPending = "";
        failHeadline = "";
        failTail = [];
        rawTail = [];
        fpWarning = "";
        failMessage = "";
        runCancelled = false;
        runSeen = false;
        runDnfRc = 0;
        runFpRc = 0;
        runFwRc = 0;
        fwCur = 0;
        fwTotal = 0;
        fwPercent = 0;
        fwFraction = 0;
        fwStatus = "";
        fwActiveName = "";
        fwRequest = "";
        fwNotes = [];
        fwInstalled = 0;
        fwFailed = 0;
        fwFailMessage = "";
        fwNeedsReboot = false;
        fwRows = ({});
        runPercent = -1;
        runStamp = runId || "";
        runStartedAt = startedAt > 0 ? startedAt : Date.now();
        runElapsed = 0;
        dnfPhase = "resolving";
        tableVerb = "";
        lastDoneIndex = -1;
        runDnfDone = false;
        runIncludedFlatpak = includedFlatpak;
        runFpDone = !includedFlatpak;
        runIncludedFirmware = includedFirmware === true;
        runFwDone = !runIncludedFirmware;
        dnfLogOffset = 0;
        flatpakLogOffset = 0;
        firmwareLogOffset = 0;
        wantedDnfBytes = 0;
        wantedFlatpakBytes = 0;
        wantedFirmwareBytes = 0;
        dnfLogCarry = "";
        flatpakLogCarry = "";
        firmwareLogCarry = "";
        backendTerminalState = "";
        backendMessage = "";
        backendPhase = "";
        recoveryPointId = "";
        backendFinishedAt = 0;
        runProjectSkipped = "";
        cancelRequested = false;
        runDeferredCancel = false;
        cancelSettle.stop();
        mixedState = false;
        runState = "running";
        doneClear.stop();
    }

    function run(packagesOnly = false) {
        if (runActive || runStartProc.running)
            return;
        // This process only stages and starts the durable worker. systemd
        // requests authorization from the desktop Polkit agent when needed,
        // so the update and its progress stay on this Quickshell surface.
        const command = ["bash", updateClient, "start"];
        if (packagesOnly || !projectUpdatesEnabled)
            command.push("--system-only");
        if (!flatpakEnabled)
            command.push("--no-flatpak");
        // Firmware is part of the same run whenever some is pending and it
        // can be written now; the worker installs it after the packages.
        const withFirmware = firmwareInRun;
        if (withFirmware)
            command.push("--firmware");
        statusGeneration++;
        startPreviousStamp = runStamp;
        startPollCount = 0;
        startPending = true;
        resetRun("", Date.now(), flatpakEnabled, withFirmware);
        runPlan = ({ dnf: dnfCount, flatpak: flatpakEnabled ? flatpakCount : 0,
            firmware: withFirmware ? firmwareCount : 0 });
        runPlanStamp = "pending";
        runStartProc.command = command;
        runStartProc.running = true;
    }

    function dnfLine(line) {
        const text = String(line).replace(/\r/g, "");
        if (text.trim() !== "")
            rawTail = rawTail.concat([text]).slice(-10);

        // The resolved table is the one place dnf prints every package's
        // full name and version, so its rows build the feed; the bracketed
        // progress lines below are column-clipped by dnf and only advance
        // the counter and tick rows off.
        const section = UpdatesHelpers.dnfSection(text);
        if (section !== null) {
            tableVerb = section;
            return;
        }
        if (tableVerb !== "") {
            const row = UpdatesHelpers.dnfTableRow(text);
            if (row !== null) {
                feedModel.append({ tag: "dnf", verb: tableVerb, name: row.name,
                    ver: row.version, evr: row.evr, done: false, failed: false });
                UpdatesHelpers.addPendingRow(pendingRows, row.name, row.evr,
                    feedModel.count - 1);
                if (tableVerb === "up")
                    upCount++;
                else if (tableVerb === "del")
                    delCount++;
                else
                    addCount++;
                if (kernelPending === "")
                    kernelPending = UpdatesHelpers.kernelHint(row.name,
                        tableVerb, row.version);
                if (tableVerb !== "del" && topNames.length < 3
                        && topNames.indexOf(row.name) === -1)
                    topNames = topNames.concat([row.name]);
                return;
            }
            // Any other column-0 line ("Transaction Summary:") closes the
            // section; the "   replacing …" continuations sit deeper and do
            // not, so an interleaved outgoing version cannot end the table.
            if (/^\S/.test(text))
                tableVerb = "";
        }

        if (text === "Running transaction") {
            dnfPhase = "installing";
            dnfCur = 0;
            dnfTotal = 0;
            return;
        }

        const step = UpdatesHelpers.parseDnfRunLine(text);
        if (step === null)
            return;
        if (dnfPhase === "resolving")
            dnfPhase = "downloading";
        dnfCur = step.cur;
        dnfTotal = step.total;
        if (step.token === "")
            return;
        // Cleanup of a replaced version carries the outgoing evr and matches
        // nothing here — progress moves, the feed stays truthful.
        const i = UpdatesHelpers.takePendingRow(pendingRows, step.token);
        if (i !== -1) {
            feedModel.setProperty(i, "done", true);
            lastDoneIndex = i;
        }
    }

    function fpLine(line) {
        const parsed = UpdatesHelpers.parseFlatpakRunLine(String(line));
        if (parsed === null)
            return;
        if (parsed.kind === "planned") {
            fpTotal = Math.max(fpTotal, parsed.n);
            return;
        }
        feedModel.append({ tag: "fpk", verb: parsed.verb, name: parsed.name,
            ver: "", evr: "", done: true, failed: false });
        lastDoneIndex = feedModel.count - 1;
        if (!parsed.runtime) {
            fpCur = Math.min(fpCur + 1, Math.max(fpTotal, fpCur + 1));
            appCount++;
        }
    }

    // One event from the worker's firmware phase (UpdatesHelpers
    // .parseFirmwareEvent). The planned devices join the transaction feed
    // up front, like dnf's table, and light up as each one finishes.
    function fwLine(line) {
        const event = UpdatesHelpers.parseFirmwareEvent(line);
        if (event === null)
            return;
        const id = typeof event.id === "string" ? event.id : "";
        const message = typeof event.message === "string" ? event.message.trim() : "";
        switch (event.event) {
        case "plan": {
            const devices = Array.isArray(event.devices) ? event.devices : [];
            const rows = {};
            for (const device of devices) {
                if (!device || typeof device.id !== "string")
                    continue;
                feedModel.append({ tag: "fw", verb: "up",
                    name: UpdatesHelpers.firmwareDisplayName(device.name),
                    ver: device.from && device.to ? device.from + " → " + device.to
                        : String(device.to || ""),
                    evr: "", done: false, failed: false });
                rows[device.id] = feedModel.count - 1;
            }
            fwRows = rows;
            fwTotal = Math.max(fwTotal, Object.keys(rows).length);
            break;
        }
        case "device": {
            fwPercent = 0;
            fwFraction = 0;
            fwStatus = "";
            fwRequest = "";
            const row = fwRows[id];
            fwActiveName = row !== undefined ? feedModel.get(row).name : "firmware";
            if (typeof event.count === "number")
                fwTotal = Math.max(fwTotal, event.count);
            break;
        }
        case "progress":
            fwStatus = typeof event.status === "string" ? event.status : "";
            fwPercent = Math.max(0, Math.min(100, Number(event.percent) || 0));
            fwFraction = Math.max(fwFraction,
                UpdatesHelpers.firmwareDeviceFraction(fwStatus, fwPercent));
            if (fwStatus !== "waiting-for-user")
                fwRequest = "";
            break;
        case "request":
            // An immediate request waits on the person (replug, press a
            // button); a post request is advice for after the update.
            if (event.kind === "immediate")
                fwRequest = message;
            else if (message !== "" && fwNotes.indexOf(message) === -1)
                fwNotes = fwNotes.concat([message]);
            break;
        case "installed":
        case "skipped":
        case "failed": {
            const row = fwRows[id];
            if (row !== undefined) {
                feedModel.setProperty(row, "done", true);
                feedModel.setProperty(row, "failed", event.event === "failed");
                lastDoneIndex = row;
            }
            if (id !== "")
                fwCur++;
            fwPercent = 0;
            fwFraction = 0;
            fwRequest = "";
            if (event.event === "installed") {
                fwInstalled++;
                if (event.needsReboot === true)
                    fwNeedsReboot = true;
                if (message !== "" && fwNotes.indexOf(message) === -1)
                    fwNotes = fwNotes.concat([message]);
            } else if (event.event === "failed") {
                fwFailed++;
                if (fwFailMessage === "")
                    fwFailMessage = message !== "" ? message
                        : "The firmware update didn’t finish.";
            }
            break;
        }
        default:
            break;
        }
    }

    function consumeBackendLog(kind, body, targetOffset) {
        let text = (kind === "dnf" ? dnfLogCarry
            : kind === "flatpak" ? flatpakLogCarry : firmwareLogCarry)
            + String(body || "");
        const complete = text.endsWith("\n");
        const lines = text.split("\n");
        const carry = complete ? "" : lines.pop();
        if (complete)
            lines.pop();
        for (const line of lines) {
            if (kind === "dnf")
                dnfLine(line);
            else if (kind === "flatpak")
                fpLine(line);
            else
                fwLine(line);
        }
        if (kind === "dnf") {
            dnfLogCarry = carry;
            dnfLogOffset = targetOffset;
        } else if (kind === "flatpak") {
            flatpakLogCarry = carry;
            flatpakLogOffset = targetOffset;
        } else {
            firmwareLogCarry = carry;
            firmwareLogOffset = targetOffset;
        }
        drainBackendLogs();
        maybeFinishBackendRun();
    }

    function drainBackendLogs() {
        if (runStamp === "")
            return;
        if (!dnfLogReadProc.running && wantedDnfBytes > dnfLogOffset) {
            dnfLogReadProc.targetRunStamp = runStamp;
            dnfLogReadProc.sourceOffset = dnfLogOffset;
            dnfLogReadProc.targetOffset = wantedDnfBytes;
            dnfLogReadProc.command = [runBackend, "read-log",
                dnfLogReadProc.targetRunStamp, "dnf",
                String(dnfLogReadProc.sourceOffset),
                String(dnfLogReadProc.targetOffset
                    - dnfLogReadProc.sourceOffset)];
            dnfLogReadProc.running = true;
        }
        if (!flatpakLogReadProc.running
                && wantedFlatpakBytes > flatpakLogOffset) {
            flatpakLogReadProc.targetRunStamp = runStamp;
            flatpakLogReadProc.sourceOffset = flatpakLogOffset;
            flatpakLogReadProc.targetOffset = wantedFlatpakBytes;
            flatpakLogReadProc.command = [runBackend, "read-log",
                flatpakLogReadProc.targetRunStamp, "flatpak",
                String(flatpakLogReadProc.sourceOffset),
                String(flatpakLogReadProc.targetOffset
                    - flatpakLogReadProc.sourceOffset)];
            flatpakLogReadProc.running = true;
        }
        if (!firmwareLogReadProc.running
                && wantedFirmwareBytes > firmwareLogOffset) {
            firmwareLogReadProc.targetRunStamp = runStamp;
            firmwareLogReadProc.sourceOffset = firmwareLogOffset;
            firmwareLogReadProc.targetOffset = wantedFirmwareBytes;
            firmwareLogReadProc.command = [runBackend, "read-log",
                firmwareLogReadProc.targetRunStamp, "firmware-events",
                String(firmwareLogReadProc.sourceOffset),
                String(firmwareLogReadProc.targetOffset
                    - firmwareLogReadProc.sourceOffset)];
            firmwareLogReadProc.running = true;
        }
    }

    function applyBackendStatus(data) {
        if (!data)
            return;
        bootId = typeof data.bootId === "string" ? data.bootId : "";
        rebootRecommendation = UpdatesHelpers.normalizedRebootRecommendation(
            data.rebootRecommendation);
        if (typeof data.id !== "string" || data.id === ""
                || data.state === "idle" || data.state === "dismissed")
            return;
        const started = Number(data.startedAt || 0) * 1000;
        const includedFlatpak = data.flatpak !== false;
        const includedFirmware = data.firmware === true;
        if (runStamp !== data.id) {
            resetRun(data.id, started, includedFlatpak, includedFirmware);
            // The plan belongs to the run this client started; a run it
            // merely found (the CLI's, or one from before a reload) has none.
            if (runPlanStamp === "pending")
                runPlanStamp = data.id;
            else if (runPlanStamp !== data.id)
                runPlan = null;
        } else {
            runStartedAt = started > 0 ? started : runStartedAt;
            runIncludedFlatpak = includedFlatpak;
            runIncludedFirmware = includedFirmware;
        }
        backendPhase = typeof data.phase === "string" ? data.phase : "";
        recoveryPointId = typeof data.snapshotId === "string" ? data.snapshotId : "";
        cancelRequested = data.cancelRequested === true;
        runDeferredCancel = data.deferredCancel === true;
        mixedState = data.mixedState === true;

        wantedDnfBytes = Math.max(wantedDnfBytes, Number(data.dnfBytes || 0));
        wantedFlatpakBytes = Math.max(wantedFlatpakBytes,
            Number(data.flatpakBytes || 0));
        wantedFirmwareBytes = Math.max(wantedFirmwareBytes,
            Number(data.firmwareEventBytes || 0));
        runDnfDone = data.dnfDone === true;
        runFpDone = !includedFlatpak || data.flatpakDone === true;
        runFwDone = !includedFirmware || data.firmwareDone === true;
        runDnfRc = Number(data.dnfRc || 0);
        runFpRc = Number(data.flatpakRc || 0);
        runFwRc = Number(data.firmwareRc || 0);
        backendMessage = typeof data.message === "string" ? data.message : "";
        drainBackendLogs();

        if (data.state === "queued" || data.state === "running") {
            runState = "running";
            return;
        }
        if (["done", "failed", "cancelled"].indexOf(data.state) === -1)
            return;
        backendTerminalState = data.state;
        backendFinishedAt = Number(data.finishedAt || 0) * 1000;
        runDnfDone = true;
        runFpDone = true;
        runFwDone = true;
        if (data.state !== "done")
            runDnfRc = Number(data.exitCode || runDnfRc
                || ProcHelpers.NOT_STARTED);
        maybeFinishBackendRun();
    }

    function maybeFinishBackendRun() {
        if (backendTerminalState === "" || dnfLogReadProc.running
                || flatpakLogReadProc.running || firmwareLogReadProc.running
                || dnfLogOffset < wantedDnfBytes
                || flatpakLogOffset < wantedFlatpakBytes
                || firmwareLogOffset < wantedFirmwareBytes)
            return;
        if (dnfLogCarry !== "") {
            dnfLine(dnfLogCarry);
            dnfLogCarry = "";
        }
        if (flatpakLogCarry !== "") {
            fpLine(flatpakLogCarry);
            flatpakLogCarry = "";
        }
        if (firmwareLogCarry !== "") {
            fwLine(firmwareLogCarry);
            firmwareLogCarry = "";
        }
        finishRun();
    }

    function finishRun() {
        if (!runDnfDone || !runFpDone || !runFwDone || !runActive)
            return;
        runFinishedAt = backendFinishedAt > 0 ? backendFinishedAt : Date.now();
        runDuration = Math.round((runFinishedAt - runStartedAt) / 1000);
        if (runDnfRc !== 0) {
            failTail = rawTail;
            failHeadline = UpdatesHelpers.failureHeadline(rawTail);
            if (failHeadline === "")
                failHeadline = backendMessage !== "" ? backendMessage
                    : runDnfRc === 126 || runDnfRc === 127
                    ? "Authorization dismissed"
                    : runDnfRc === ProcHelpers.NOT_STARTED
                    ? "dnf could not be started"
                    : "dnf exited with status " + runDnfRc;
            runCancelled = backendTerminalState === "cancelled";
            failMessage = runCancelled ? "Nothing more was changed after the step that was running."
                : UpdatesHelpers.friendlyFailure(rawTail, backendMessage,
                    runDnfRc, backendPhase, ProcHelpers.NOT_STARTED);
            runState = "failed";
        } else {
            // A Flathub hiccup or a device that refused its firmware should
            // not turn a completed system upgrade into a failure banner;
            // their rows say what happened instead.
            if (runIncludedFlatpak && runFpRc !== 0)
                fpWarning = "Couldn’t update apps";
            if (runIncludedFirmware && runFwRc !== 0 && fwFailMessage === "")
                fwFailMessage = "The firmware update didn’t finish.";
            runState = "done";
            doneClear.restart();
        }
        // The counts the panel shows must agree with what is now installed:
        // one recount now, and finishCheck allows a single delayed retry
        // only when that recount failed or still looks inconsistent.
        recheck.stop();
        postRunCheck = 1;
        Qt.callLater(root.check);
    }

    function dismissRun() {
        if (runStamp !== "")
            Quickshell.execDetached([runBackend, "dismiss", runStamp]);
        statusGeneration++;
        startPending = false;
        runState = "idle";
        runSeen = false;
        doneClear.stop();
    }

    function cancelRun() {
        if (!cancelAllowed || cancelPending)
            return;
        cancelProc.command = [runBackend, "cancel", runStamp];
        cancelProc.running = true;
    }

    // Raw transcript, in the pager everyone already has. The log file is the
    // one place the full unparsed output survives, so the escape hatch opens
    // it rather than re-rendering it. run.log interleaves every step.
    function openLog(file = "run.log") {
        Quickshell.execDetached(["kitty", "--title", "Update log", "bash",
            "-c", "exec less -R \"${XDG_STATE_HOME:-$HOME/.local/state}/"
            + "cybexos/update/logs/" + runStamp + "/" + file + "\""]);
    }

    Timer {
        interval: 1000
        running: root.runActive
        repeat: true
        onTriggered: root.runElapsed =
            Math.round((Date.now() - root.runStartedAt) / 1000)
    }

    // An unvisited ✓ should not sit in the bar all afternoon: after a quiet
    // quarter hour the result retires itself and the auto rule tucks the
    // module away. The full log keeps the story.
    Timer {
        id: doneClear
        interval: 15 * 60000
        onTriggered: {
            if (root.runState === "done")
                root.dismissRun();
        }
    }

    // Opening the finished panel is the acknowledgement; the close after it
    // retires the result. A failure never self-acknowledges — dismiss and
    // retry are explicit actions in the panel.
    Connections {
        target: Popouts

        function onChanged() {
            // A view that shows the count brings a stale one up to date: the
            // only way it refreshes while background checks are off.
            if (Popouts.open && (Popouts.currentName === "updates"
                    || Popouts.currentName === "control"
                        && Settings.drawerOverview.updates === true))
                root.staleCheck();
            if (Popouts.open && Popouts.currentName === "updates") {
                if (root.runState === "done")
                    root.runSeen = true;
            } else if (!Popouts.open && root.runSeen
                    && root.runState === "done") {
                root.dismissRun();
            }
        }
    }

    // The updater owns the privileged transaction in a transient service.
    // This tracked process is only its short-lived start client: a shell hot
    // reload cannot discard the worker, its lock, or its logs once launched.
    Process {
        id: runStartProc
        property string body: ""
        property string errText: ""
        property bool exitSeen: false
        property int lastExit: 0

        stdout: StdioCollector {
            onStreamFinished: runStartProc.body = text
        }
        stderr: StdioCollector {
            onStreamFinished: runStartProc.errText = text.trim()
        }
        onExited: (exitCode, exitStatus) => {
            runStartProc.exitSeen = true;
            runStartProc.lastExit = exitCode;
        }
        onRunningChanged: {
            if (running) {
                body = "";
                errText = "";
                exitSeen = false;
                lastExit = 0;
                return;
            }
            if (!exitSeen && body === "" && errText === ""
                    && !root.startPending)
                return;
            root.settleStartRequest();
            try {
                const started = JSON.parse(body);
                if (typeof started.id !== "string" || started.id === "")
                    throw new Error("missing durable run id");
                root.applyBackendStatus(started);
                root.runProjectSkipped = UpdatesHelpers.projectErrorOf(started);
            } catch (error) {
                root.runDnfDone = true;
                root.runFpDone = true;
                root.runDnfRc = exitSeen && lastExit !== 0
                    ? lastExit : ProcHelpers.NOT_STARTED;
                root.backendMessage = errText !== "" ? errText
                    : "The update service could not be started";
                root.backendTerminalState = "failed";
                root.maybeFinishBackendRun();
            }
        }
    }

    Process {
        id: runStatusProc
        property int requestGeneration: 0
        property string body: ""
        property string errText: ""
        property bool exitSeen: false
        property int lastExit: 0

        stdout: StdioCollector {
            onStreamFinished: runStatusProc.body = text
        }
        stderr: StdioCollector {
            onStreamFinished: runStatusProc.errText = text.trim()
        }
        onExited: (exitCode, exitStatus) => {
            runStatusProc.exitSeen = true;
            runStatusProc.lastExit = exitCode;
        }
        onRunningChanged: {
            if (running) {
                body = "";
                errText = "";
                exitSeen = false;
                lastExit = 0;
                return;
            }
            if (!exitSeen && body === "" && errText === "")
                return;
            if (root.startPending && exitSeen && lastExit === 0) {
                try {
                    const pending = JSON.parse(body);
                    if (typeof pending.id === "string" && pending.id !== ""
                            && pending.id !== root.startPreviousStamp
                            && pending.state !== "idle"
                            && pending.state !== "dismissed") {
                        root.settleStartRequest();
                        root.applyBackendStatus(pending);
                        return;
                    }
                } catch (error) {
                    // The next poll retries malformed or partial status.
                }
            }
            if (UpdatesHelpers.acceptsStatusResponse(root.statusGeneration,
                    requestGeneration, root.startPending, exitSeen, lastExit)) {
                try {
                    root.applyBackendStatus(JSON.parse(body));
                    return;
                } catch (error) {
                    console.warn("update status: invalid backend response", error);
                }
            }
            if (root.runActive && errText !== "")
                console.warn("update status:", errText);
        }
    }

    Process {
        id: dnfLogReadProc
        property string targetRunStamp: ""
        property int sourceOffset: 0
        property int targetOffset: 0
        property string body: ""
        property bool exitSeen: false
        property int lastExit: -1
        stdout: StdioCollector {
            onStreamFinished: dnfLogReadProc.body = text
        }
        onExited: (exitCode, exitStatus) => {
            dnfLogReadProc.exitSeen = true;
            dnfLogReadProc.lastExit = exitCode;
        }
        onRunningChanged: {
            if (running) {
                body = "";
                exitSeen = false;
                lastExit = -1;
            } else if (UpdatesHelpers.acceptsLogRead(root.runStamp,
                    root.dnfLogOffset, targetRunStamp, sourceOffset,
                    targetOffset, exitSeen, lastExit)) {
                root.consumeBackendLog("dnf", body, targetOffset);
            } else if (exitSeen && (targetRunStamp !== root.runStamp
                    || sourceOffset !== root.dnfLogOffset)) {
                // The process slot is free again; immediately service the
                // current run rather than waiting for its next status poll.
                root.drainBackendLogs();
            } else if (exitSeen && lastExit !== 0) {
                console.warn("dnf update log read exited with status", lastExit);
            }
        }
    }

    Process {
        id: flatpakLogReadProc
        property string targetRunStamp: ""
        property int sourceOffset: 0
        property int targetOffset: 0
        property string body: ""
        property bool exitSeen: false
        property int lastExit: -1
        stdout: StdioCollector {
            onStreamFinished: flatpakLogReadProc.body = text
        }
        onExited: (exitCode, exitStatus) => {
            flatpakLogReadProc.exitSeen = true;
            flatpakLogReadProc.lastExit = exitCode;
        }
        onRunningChanged: {
            if (running) {
                body = "";
                exitSeen = false;
                lastExit = -1;
            } else if (UpdatesHelpers.acceptsLogRead(root.runStamp,
                    root.flatpakLogOffset, targetRunStamp, sourceOffset,
                    targetOffset, exitSeen, lastExit)) {
                root.consumeBackendLog("flatpak", body, targetOffset);
            } else if (exitSeen && (targetRunStamp !== root.runStamp
                    || sourceOffset !== root.flatpakLogOffset)) {
                root.drainBackendLogs();
            } else if (exitSeen && lastExit !== 0) {
                console.warn("flatpak update log read exited with status", lastExit);
            }
        }
    }

    Process {
        id: firmwareLogReadProc
        property string targetRunStamp: ""
        property int sourceOffset: 0
        property int targetOffset: 0
        property string body: ""
        property bool exitSeen: false
        property int lastExit: -1
        stdout: StdioCollector {
            onStreamFinished: firmwareLogReadProc.body = text
        }
        onExited: (exitCode, exitStatus) => {
            firmwareLogReadProc.exitSeen = true;
            firmwareLogReadProc.lastExit = exitCode;
        }
        onRunningChanged: {
            if (running) {
                body = "";
                exitSeen = false;
                lastExit = -1;
            } else if (UpdatesHelpers.acceptsLogRead(root.runStamp,
                    root.firmwareLogOffset, targetRunStamp, sourceOffset,
                    targetOffset, exitSeen, lastExit)) {
                root.consumeBackendLog("firmware", body, targetOffset);
            } else if (exitSeen && (targetRunStamp !== root.runStamp
                    || sourceOffset !== root.firmwareLogOffset)) {
                root.drainBackendLogs();
            } else if (exitSeen && lastExit !== 0) {
                console.warn("firmware update log read exited with status", lastExit);
            }
        }
    }

    // The falling edge, so a cancel client that never started still asks
    // for the run's state.
    Process {
        id: cancelProc
        onRunningChanged: {
            if (running)
                return;
            cancelSettle.restart();
            root.refreshRunStatus();
        }
    }

    // A status read already in flight predates the cancel. Hold the pending
    // state until a later poll can report the worker's answer, so Cancel
    // does not flash back on in between.
    Timer {
        id: cancelSettle
        interval: 2000
    }

    function refreshRunStatus() {
        if (runStatusProc.running)
            return;
        runStatusProc.requestGeneration = statusGeneration;
        runStatusProc.command = [runBackend, "status", "--json"];
        runStatusProc.running = true;
    }

    Timer {
        id: statusPoll
        interval: 1000
        running: root.runActive
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            if (root.startPending && ++root.startPollCount > 300) {
                root.settleStartRequest();
                root.runDnfDone = true;
                root.runFpDone = true;
                root.runDnfRc = ProcHelpers.NOT_STARTED;
                root.backendMessage = "The update request did not publish a new run";
                root.backendTerminalState = "failed";
                root.maybeFinishBackendRun();
                return;
            }
            root.refreshRunStatus();
        }
    }

    Timer {
        id: recheck
        interval: 60000
        onTriggered: root.check()
    }

    // A transient endpoint failure after NetworkManager came online should
    // not survive until the ordinary (30 minute by default) poll. Four
    // bounded retries cover startup DNS/repository lag without hammering a
    // permanently broken remote, and each repeats only what failed.
    Timer {
        interval: Math.min(120000, 15000 * Math.pow(2,
            Math.max(0, root.checkFailureCount - 1)))
        running: root.error !== "" && root.checkFailureCount <= 4
            && NetworkStatus.online && !root.busy && !root.runActive
            && !Activity.idle
        onTriggered: root.automaticCheck(false, true)
    }

    // Nothing to notify about or to count in an idle or locked session; the
    // first input afterwards checks at once if the last result is stale.
    Timer {
        interval: root.pollMs
        running: NetworkStatus.online && root.pollEnabled && !Activity.idle
        repeat: true
        onTriggered: root.automaticCheck(false, false)
    }

    function staleCheck() {
        if (!busy && !UpdatesHelpers.checkIsFresh(lastChecked, Date.now(), pollMs))
            automaticCheck(false, false);
    }

    Connections {
        target: Activity

        function onResumed() {
            if (root.pollEnabled && !startupCheck.running)
                root.staleCheck();
        }
    }

    onPollEnabledChanged: {
        if (pollEnabled && initialized && !startupCheck.running)
            staleCheck();
    }

    // One cheap process for the signature: each repository's repomd.xml
    // (depth 3 under the libdnf5 cache), the repo files and the rpm
    // database, as "path size mtime" lines.
    Process {
        id: dnfSignatureProc
        property string body: ""
        property bool exitSeen: false
        property int lastExit: 0

        command: ["timeout", "10s", "find", "/var/cache/libdnf5",
            "/usr/lib/sysimage/rpm", "/etc/yum.repos.d", "-maxdepth", "3",
            "(", "-name", "repomd.xml", "-o", "-name", "rpmdb.sqlite",
            "-o", "-name", "rpmdb.sqlite-wal", "-o", "-name", "*.repo", ")",
            "-printf", "%p %s %T@\\n"]

        stdout: StdioCollector {
            onStreamFinished: dnfSignatureProc.body = text
        }

        onExited: (exitCode, exitStatus) => {
            dnfSignatureProc.exitSeen = true;
            dnfSignatureProc.lastExit = exitCode;
        }
        onRunningChanged: {
            if (running) {
                body = "";
                exitSeen = false;
                lastExit = 0;
            } else {
                // No signature just means a real read.
                root.readDnf(exitSeen && lastExit === 0
                    ? UpdatesHelpers.dnfSignature(body) : "");
            }
        }
    }

    // dnf check-update lists one package per line as "name.arch  version  repo"
    // under a plain-text section heading. Exit 100 is the "there are updates"
    // status, exit 0 means none, anything else is a real failure.
    Process {
        id: dnfProc
        property string body: ""
        property string errText: ""
        property bool exitSeen: false
        property int lastExit: 0
        // The signature taken before this read started.
        property string signature: ""

        command: ["timeout", "45s", "dnf", "--quiet",
            "--cacheonly", "check-update"]
        // Untranslated output, without an `env` process per check.
        // QML object literals convert to QVariantHash at runtime; the shipped
        // Quickshell type description reports them as QVariantMap to qmllint.
        // qmllint disable incompatible-type
        environment: ({ LC_ALL: "C" })
        // qmllint enable incompatible-type

        stdout: StdioCollector {
            onStreamFinished: dnfProc.body = text
        }

        stderr: StdioCollector {
            onStreamFinished: dnfProc.errText = text
        }

        onExited: (exitCode, exitStatus) => {
            dnfProc.exitSeen = true;
            dnfProc.lastExit = exitCode;
        }
        onRunningChanged: {
            if (running) {
                body = "";
                errText = "";
                exitSeen = false;
                lastExit = 0;
            } else {
                root.finishDnf(exitSeen ? lastExit : ProcHelpers.NOT_STARTED, body, errText,
                    signature);
            }
        }
    }

    // The security advisories among the pending packages, from the same
    // cache check-update just read.
    Process {
        id: dnfSecurityProc
        property string body: ""
        property bool exitSeen: false
        property int lastExit: 0

        command: ["timeout", "45s", "dnf", "--quiet", "--cacheonly",
            "advisory", "list", "--security", "--updates", "--json"]
        // qmllint disable incompatible-type
        environment: ({ LC_ALL: "C" })
        // qmllint enable incompatible-type

        stdout: StdioCollector {
            onStreamFinished: dnfSecurityProc.body = text
        }

        onExited: (exitCode, exitStatus) => {
            dnfSecurityProc.exitSeen = true;
            dnfSecurityProc.lastExit = exitCode;
        }
        onRunningChanged: {
            if (running) {
                body = "";
                exitSeen = false;
                lastExit = 0;
            } else {
                root.finishDnfSecurity(exitSeen ? lastExit : ProcHelpers.NOT_STARTED,
                    body);
            }
        }
    }

    Process {
        id: flatpakProc
        property string body: ""
        property string errText: ""
        property bool exitSeen: false
        property int lastExit: 0

        command: ["timeout", "45s", "flatpak", "remote-ls",
            "--updates", "--app", "--columns=name"]
        // qmllint disable incompatible-type
        environment: ({ LC_ALL: "C" })
        // qmllint enable incompatible-type

        stdout: StdioCollector {
            onStreamFinished: flatpakProc.body = text
        }

        stderr: StdioCollector {
            onStreamFinished: flatpakProc.errText = text
        }

        onExited: (exitCode, exitStatus) => {
            flatpakProc.exitSeen = true;
            flatpakProc.lastExit = exitCode;
        }
        onRunningChanged: {
            if (running) {
                body = "";
                errText = "";
                exitSeen = false;
                lastExit = 0;
            } else {
                root.finishFlatpak(exitSeen ? lastExit : ProcHelpers.NOT_STARTED,
                    body, errText);
            }
        }
    }

    Process {
        id: firmwareProc
        property string body: ""
        property string errText: ""
        property bool exitSeen: false
        property int lastExit: 0

        command: ["timeout", "45s", "fwupdmgr",
            "get-updates", "--json"]
        // qmllint disable incompatible-type
        environment: ({ LC_ALL: "C" })
        // qmllint enable incompatible-type

        stdout: StdioCollector {
            onStreamFinished: firmwareProc.body = text
        }

        stderr: StdioCollector {
            onStreamFinished: firmwareProc.errText = text
        }

        onExited: (exitCode, exitStatus) => {
            firmwareProc.exitSeen = true;
            firmwareProc.lastExit = exitCode;
        }
        onRunningChanged: {
            if (running) {
                body = "";
                errText = "";
                exitSeen = false;
                lastExit = 0;
            } else {
                root.finishFirmware(exitSeen ? lastExit : ProcHelpers.NOT_STARTED,
                    body, errText);
            }
        }
    }

    Process {
        id: projectProc

        property string body: ""
        property string errText: ""
        property bool exitSeen: false
        property int lastExit: 0

        command: ["timeout", "45s", "bash", root.updateClient, "check"]

        stdout: StdioCollector {
            onStreamFinished: projectProc.body = text
        }

        stderr: StdioCollector {
            onStreamFinished: projectProc.errText = text
        }

        onExited: (exitCode, exitStatus) => {
            projectProc.exitSeen = true;
            projectProc.lastExit = exitCode;
        }
        onRunningChanged: {
            if (running) {
                body = "";
                errText = "";
                exitSeen = false;
                lastExit = 0;
            } else {
                root.finishProject(exitSeen ? lastExit : ProcHelpers.NOT_STARTED,
                    body, errText);
            }
        }
    }

    Connections {
        target: NetworkStatus

        function onOnlineChanged() {
            // The session's first online edge belongs to startupCheck, and
            // one that lands while idle to the resume check. A flapping link
            // must not repeat a complete check that is only minutes old; a
            // failed one is still retried at once.
            if (startupCheck.running || !root.pollEnabled || Activity.idle)
                return;
            if (NetworkStatus.online && (root.error !== ""
                    || !UpdatesHelpers.checkIsFresh(root.lastChecked,
                        Date.now(), 600000)))
                root.automaticCheck(true, false);
        }
    }

    // The first check (dnf, a Flathub round trip, fwupd) is not needed for
    // the first frame; keep it out of the session-start burst. A run already
    // in progress is still picked up immediately by refreshRunStatus.
    Timer {
        id: startupCheck
        interval: 20000
        // A view opened meanwhile may already have checked.
        onTriggered: {
            if (root.pollEnabled && !root.ran && !root.busy)
                root.automaticCheck(true, false);
        }
    }

    Component.onCompleted: {
        initialized = true;
        startupCheck.start();
        refreshRunStatus();
    }
    onFlatpakEnabledChanged: {
        if (initialized && !startupCheck.running)
            automaticCheck(true, false);
    }
}
