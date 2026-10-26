pragma Singleton
import QtQuick
import Quickshell
import "UpdatesHelpers.js" as Helpers

// Discovery, request outcomes and the reviewed deployment have separate lifetimes.
// Only the systemd worker owns an update; closing this client never interrupts it.
Singleton {
    id: root

    property var sources: ({upstream: {state: "unknown"}, cybexos: {state: "unknown"}})
    property var deployment: ({state: "idle"})
    property bool sourcesLoaded: false
    property bool statusLoaded: false
    property string checkError: ""
    property string requestError: ""
    property string statusError: ""
    property var checkedAt: null
    property string installedIdentity: ""
    property var selectedSources: ["upstream", "cybexos"]
    property int requestEpoch: 0
    property int pollEpoch: 0

    readonly property bool available: statusLoaded && deployment.available !== false && sources.available !== false
    readonly property bool busy: checker.busy
    readonly property bool requestPending: requester.busy || Helpers.pending(deployment.request)
    readonly property bool runActive: Helpers.active(deployment.state) || requestPending
    readonly property string runState: runActive ? "running" : deployment.state === "done" ? "done"
        : ["failed", "interrupted", "rolled-back", "recovery-failed"].includes(deployment.state) ? "failed" : "idle"
    readonly property bool hasUpdates: sourcesLoaded && [sources.upstream, sources.cybexos].some(source => source.state === "available")
    readonly property bool showIndicator: Helpers.indicator(hasUpdates, deployment.state)
    readonly property string selectedScope: sourcesLoaded ? Helpers.scope(sources, selectedSources) : ""
    readonly property var actions: Helpers.capabilities(deployment, runActive || !statusLoaded || statusError !== "", available, selectedScope)
    readonly property bool ready: deployment.state === "ready"
    readonly property bool rebootRecommended: ["awaiting-boot", "awaiting-login"].includes(deployment.state)
    readonly property string rebootRecommendation: deployment.state === "awaiting-login"
        ? "Confirm this boot after signing in. No further restart is needed."
        : deployment.state === "awaiting-boot" ? "Restart when ready to finish this update." : ""
    readonly property string runPhaseLabel: deployment.phase || ""
    readonly property string error: [...new Set([requestError, statusError, checkError,
        (deployment.request || {}).error || "", deployment.error || "",
        sources.error || "", sources.upstream.error || "", sources.cybexos.error || ""].filter(value => value))].join("\n\n")
    readonly property string projectNotes: ready || rebootRecommended ? deployment.notes || "" : sources.cybexos.notes || ""
    readonly property string installedVersion: ready ? deployment.installedVersion || "" : sources.cybexos.installed || ""
    readonly property string projectVersion: ready ? deployment.availableVersion || "" : sources.cybexos.available || ""
    readonly property string checkedLabel: checkedAt ? "Checked " + Qt.formatTime(checkedAt, "HH:mm") : "Not checked"
    readonly property string scopeLabel: Helpers.scopeLabel(ready || runActive || rebootRecommended ? deployment.scope : selectedScope)
    readonly property bool overviewVisible: Helpers.overviewVisible(hasUpdates, deployment, error)
    readonly property string summary: deployment.available === false ? deployment.phase || "System updates are available after installation."
        : requester.busy ? "Waiting for authorization…"
        : Helpers.active(deployment.state) ? runPhaseLabel
        : Helpers.pending(deployment.request) ? "Starting the system update request…"
        : ready ? (deployment.changeKind === "update" ? "Ready to update" : "System change ready for review")
        : rebootRecommended ? rebootRecommendation
        : deployment.state === "recovery-failed" ? "Recovery needs attention"
        : deployment.state === "stale" ? "The configuration changed. Prepare again."
        : ["failed", "interrupted"].includes(deployment.state) ? "The update did not finish"
        : hasUpdates ? "System updates available"
        : busy ? "Checking for system updates…"
        : error ? "Some update sources could not be checked"
        : !sourcesLoaded ? "System updates have not been checked"
        : "Your system is up to date"

    function show() {
        Popouts.openPanel("updates", undefined, undefined, Screens.focused ? Screens.focused.name : "");
    }
    function opened() {
        refreshStatus();
        if (!checkedAt || Date.now() - checkedAt.getTime() > 60000) check();
    }
    function check() {
        if (checker.busy) return;
        checkError = "";
        checker.run(["cybex", "update", "check"]);
    }
    function refreshStatus() {
        if (poll.busy) return;
        pollEpoch = requestEpoch;
        poll.run(["cybex", "update", "status"]);
    }
    function selectSource(name, selected) {
        if (ready || runActive || !["upstream", "cybexos"].includes(name)) return;
        selectedSources = selected ? [...new Set(selectedSources.concat([name]))] : selectedSources.filter(value => value !== name);
    }
    function request(args) {
        if (runActive || !statusLoaded || statusError !== "") {
            requestError = "Another operation is pending, or its status is unavailable. Review the current status before retrying.";
            return;
        }
        requestError = "";
        requester.run(["cybex", "update"].concat(args));
    }
    function prepare() { if (actions.prepare) request(["stage", selectedScope]); }
    function apply() { if (actions.apply) request(["apply", deployment.transaction, deployment.reviewToken]); }
    function discard() { if (actions.discard) request(["discard", deployment.transaction]); }
    function rollback() { if (actions.rollback) request(["rollback", deployment.transaction]); }
    function confirm() { if (actions.confirm) request(["confirm"]); }
    function openLog() {
        if (deployment.transaction) Quickshell.execDetached(["cybexos-apps", "terminal", "--hold", "--", "cybex", "update", "log", deployment.transaction]);
    }
    function openRecoveryPoints() {
        Quickshell.execDetached(["cybexos-apps", "terminal", "--hold", "--", "cybex", "update", "history"]);
    }

    JsonCommand {
        id: checker
        onCompleted: value => {
            // Discovery may finish after activation selected a different lock.
            // Never offer updates computed against the previous installation.
            if (root.installedIdentity && value.installedIdentity
                    && value.installedIdentity !== root.installedIdentity) {
                root.sourcesLoaded = false;
                Qt.callLater(() => root.check());
                return;
            }
            if (!Helpers.validSources(value)) {
                root.checkError = "The update checker returned an invalid response. Retry checking for updates.";
                root.sourcesLoaded = false;
                root.sources = {upstream: {state: "unknown"}, cybexos: {state: "unknown"}};
                return;
            }
            root.sources = value;
            root.sourcesLoaded = true;
            root.checkError = "";
            root.checkedAt = new Date((value.checkedAt || Date.now() / 1000) * 1000);
        }
        onFailed: message => {
            root.checkError = message;
            root.sourcesLoaded = false;
            root.sources = {upstream: {state: "unknown"}, cybexos: {state: "unknown"}};
        }
    }
    JsonCommand {
        id: requester
        onCompleted: value => {
            if (value.accepted !== true || !/^[a-f0-9]{32}$/.test(value.requestId || "")) {
                root.requestError = "The update request was not accepted. Refresh its status and retry.";
                root.refreshStatus();
                return;
            }
            root.requestEpoch++;
            root.deployment = Object.assign({}, root.deployment, {request: {id: value.requestId, state: "queued"}});
            root.refreshStatus();
        }
        onFailed: message => { root.requestError = message; root.refreshStatus(); }
    }
    JsonCommand {
        id: poll
        onCompleted: value => {
            if (!Helpers.validDeployment(value)) {
                root.statusError = "The updater returned an invalid status. Retry checking its status.";
                return;
            }
            // A poll started before authorization may finish after acceptance.
            // Do not clear the new queued request using that older snapshot.
            if (root.pollEpoch !== root.requestEpoch) return;
            root.deployment = value;
            root.statusLoaded = true;
            root.statusError = "";
            if (value.installedIdentity && value.installedIdentity !== root.installedIdentity) {
                root.installedIdentity = value.installedIdentity;
                root.sourcesLoaded = false;
                root.check();
            }
        }
        onFailed: message => { root.statusError = message; }
    }
    Timer { interval: 2000; repeat: true; running: true; triggeredOnStart: true; onTriggered: root.refreshStatus() }
    Timer {
        interval: Math.max(10, Number((Settings.modOpts.updates || {}).pollMins) || 60) * 60000
        repeat: true; running: true; triggeredOnStart: true; onTriggered: root.check()
    }
}
