pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// A client of the durable NixOS lifecycle. Closing/reloading the shell never
// owns or interrupts the systemd worker. Every apply names the reviewed build.
Singleton {
    id: root
    property var sources: ({upstream:{}, cybexos:{}})
    property var deployment: ({state:"idle"})
    readonly property bool busy: checker.running
    readonly property bool runActive: ["discovering", "building", "validating", "activating", "recovering"].includes(deployment.state)
    readonly property string runState: runActive ? "running" : deployment.state === "done" ? "done"
        : ["failed", "interrupted", "rolled-back", "recovery-failed"].includes(deployment.state) ? "failed" : "idle"
    readonly property string error: [sources.upstream.error || "", sources.cybexos.error || "", deployment.error || ""].filter(x => x).join("\n")
    readonly property string packageError: sources.upstream.error || ""
    readonly property int upstreamCount: sources.upstream.state === "available" ? 1 : 0
    readonly property bool projectAvailable: sources.cybexos.state === "available"
    readonly property string projectVersion: sources.cybexos.available || ""
    readonly property string installedVersion: sources.cybexos.installed || deployment.installedVersion || ""
    readonly property string projectNotes: deployment.notes || sources.cybexos.notes || ""
    readonly property int total: upstreamCount + (projectAvailable ? 1 : 0)
    readonly property string summary: busy ? "Checking update sources…" : runActive ? runPhaseLabel
        : total > 0 ? "Updates available" : error ? "Some update sources could not be checked" : "No updates reported"
    readonly property string checkedLabel: checkedAt ? Qt.formatTime(checkedAt, "HH:mm") : "Not checked"
    property var checkedAt: null
    readonly property int runPercent: -1
    readonly property int runElapsed: deployment.phaseElapsedSeconds || 0
    readonly property bool runCancelled: false
    readonly property string runPhaseLabel: deployment.phase || ""
    readonly property string failMessage: deployment.error || deployment.phase || ""
    readonly property bool rebootRecommended: ["awaiting-boot", "awaiting-login"].includes(deployment.state)
    readonly property string rebootRecommendation: rebootRecommended ? "Reboot when ready, then sign in to confirm health" : ""
    readonly property bool kernelPending: rebootRecommended
    readonly property bool ready: deployment.state === "ready"
    property bool detailsOpen: false

    function parse(text) { try { return JSON.parse(text); } catch (_) { return null; } }
    function check() { if (!checker.running) checker.running = true; }
    function request(args) { if (!requester.running) { requester.command = ["cybex", "update"].concat(args); requester.running = true; } }
    function stage(scope) { request(["stage", scope]); }
    function run() { stage("both"); }
    function apply() { if (ready) request(["apply", deployment.transaction, deployment.reviewToken]); }
    function rollback() { request(["rollback"]); }
    function confirm() { request(["confirm"]); }
    function dismissRun() { check(); }
    function openLog() { if (deployment.transaction) Quickshell.execDetached(["kitty", "--hold", "cybex", "update", "log", deployment.transaction]); }
    function openRecoveryPoints() { Quickshell.execDetached(["kitty", "--hold", "cybex", "update", "history"]); }
    function openFirmware() { Quickshell.execDetached(["kitty", "--hold", "cybexos-firmware-update", "interactive"]); }

    Process {
        id: checker
        command: ["cybex", "update", "check"]
        stdout: StdioCollector { onStreamFinished: { const result = root.parse(text); if (result) { root.sources = result; root.checkedAt = new Date(); } } }
        stderr: StdioCollector { onStreamFinished: { if (text.trim()) console.warn("Update check: " + text.trim()); } }
    }
    Process {
        id: requester
        stdout: StdioCollector { onStreamFinished: { poll.running = true; } }
        stderr: StdioCollector { onStreamFinished: { if (text.trim()) root.deployment = Object.assign({}, root.deployment, {error:text.trim()}); } }
    }
    Process {
        id: poll
        command: ["cybex", "update", "status"]
        stdout: StdioCollector { onStreamFinished: { const result = root.parse(text); if (result) root.deployment = result; } }
    }
    Timer { interval: 2000; repeat: true; running: true; triggeredOnStart: true; onTriggered: { if (!poll.running) poll.running = true; } }
    Timer { interval: Math.max(10, Number((Settings.modOpts.updates || {}).pollMins) || 60) * 60000; repeat: true; running: true; triggeredOnStart: true; onTriggered: root.check() }
}
