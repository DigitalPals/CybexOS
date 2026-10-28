pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "UpdatesHelpers.js" as Helpers

// Discovery, request outcomes and the reviewed deployment have separate lifetimes.
// Only the systemd worker owns an update; closing this client never interrupts it.
// The Software Update app (SoftwareUpdateWindow) is its one review surface.
Singleton {
    id: root

    property bool appOpen: false
    signal present()
    // The app's window belongs to this shell, and activating or restoring a
    // generation restarts the shell when NixOS restarts its changed user
    // unit. A marker keyed to the compositor session reopens the app in the
    // replacement shell, so an update's progress and result stay in view.
    // Closing the app clears it; a new login never reopens the app.
    readonly property string reopenPath: Startup.runtimeDir !== ""
        ? Startup.runtimeDir + "/cybexos-software-update-open" : ""
    property bool reopenLoaded: false

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
    property string requestAction: ""
    // Background preparation is requested once per discovered target, and a
    // trial boot is confirmed once per shell session; the units decide.
    property string preparedTarget: ""
    property bool confirmRequested: false
    // Heavy background work waits until the session has settled, unless
    // the person explicitly checks for updates.
    property bool preparationAllowed: false
    property string lastState: ""
    // The running system's own component versions, for the up-to-date page.
    property var installedComponents: ({})

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
    readonly property var automatic: deployment.automatic || ({prepare: false, confirm: false})
    readonly property bool choosingAutomatic: chooser.busy
    // This request's refusal, or the latest worker request's durable failure.
    readonly property string requestFailure: requestError
        || ((deployment.request || {}).state === "failed" ? deployment.request.error || "" : "")
    readonly property string page: Helpers.page({statusLoaded: statusLoaded, statusError: statusError,
        sourcesLoaded: sourcesLoaded, hasUpdates: hasUpdates, error: error, state: deployment.state,
        request: deployment.request, requestAction: requestAction, automatic: automatic})
    readonly property string problem: Helpers.problem({statusLoaded: statusLoaded, state: deployment.state})
    readonly property var review: Helpers.summary(deployment)
    readonly property bool upstreamOnlyAvailable: deployment.state === "failed" && deployment.scope === "both"
        && sourcesLoaded && sources.upstream.state === "available"
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
        if (appOpen) present();
        else appOpen = true;
        componentsFile.reload();
        opened();
    }
    function close() { appOpen = false; }
    onAppOpenChanged: rememberOpen()
    function rememberOpen() {
        if (reopenLoaded) reopenFile.setText(appOpen ? Startup.sessionKey + "\n" : "");
    }
    function restoreOpen(text) {
        if (reopenLoaded) return;
        reopenLoaded = true;
        if (text.trim() === Startup.sessionKey && !appOpen) show();
        else rememberOpen();
    }
    function opened() {
        refreshStatus();
        if (!checkedAt || Date.now() - checkedAt.getTime() > 60000) check();
    }
    function check(explicit) {
        if (explicit === true) preparationAllowed = true;
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
        if (runActive || !["upstream", "cybexos"].includes(name)) return;
        selectedSources = selected ? [...new Set(selectedSources.concat([name]))] : selectedSources.filter(value => value !== name);
    }
    function request(args) {
        if (runActive || !statusLoaded || statusError !== "") {
            requestError = "Another operation is pending, or its status is unavailable. Review the current status before retrying.";
            return;
        }
        requestError = "";
        requestAction = args[0];
        requester.run(["cybex", "update"].concat(args));
    }
    function prepare() { if (actions.prepare) request(["stage", selectedScope]); }
    // A prepared update with different sources is replaced by a new preview.
    function restage() {
        if (!runActive && selectedScope !== "" && ["ready", "stale"].includes(deployment.state)
                && selectedScope !== deployment.scope) request(["stage", selectedScope]);
    }
    // After a failed combined preview: keep the installed Cybex OS.
    function prepareUpstream() { if (upstreamOnlyAvailable && !runActive) request(["stage", "upstream"]); }
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
    function openFirmware() {
        Quickshell.execDetached(["cybexos-apps", "terminal", "--hold", "--", "cybexos-firmware-update", "interactive"]);
    }
    // A machine policy, so changing it asks for administrator authorization.
    function setAutomatic(name, enabled) {
        if (chooser.busy || !["prepare", "confirm"].includes(name)) return;
        requestError = "";
        chooser.run(["cybex", "update", "automatic", name, enabled ? "on" : "off"]);
    }
    // The units validate state as root and take no input; a polkit rule lets
    // the signed-in administrator start them without a prompt.
    function startUnit(unit) {
        Quickshell.execDetached(["systemctl", "--no-ask-password", "start", "--no-block", unit]);
    }
    function maybePrepare() {
        if (!preparationAllowed || !statusLoaded || !sourcesLoaded
                || !Helpers.autoPrepare(hasUpdates, automatic, deployment.state, runActive)) return;
        const target = Helpers.targetKey(sources, installedIdentity);
        if (target === preparedTarget) return;
        preparedTarget = target;
        startUnit("cybexos-update-auto.service");
    }
    function finished(previous, value) {
        if (!["awaiting-login", "activating"].includes(previous) || value.state !== "done") return;
        Quickshell.execDetached(["notify-send", "--app-name=Software Update", "--icon=cybexos",
            value.changeKind === "update" ? I18n.tr("Update complete") : I18n.tr("System change complete"),
            I18n.tr("Everything passed its checks after the restart.")]);
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
            root.maybePrepare();
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
            root.deployment = Object.assign({}, root.deployment,
                {request: {id: value.requestId, state: "queued", action: root.requestAction}});
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
            root.finished(root.lastState, value);
            root.lastState = value.state;
            root.deployment = value;
            root.statusLoaded = true;
            root.statusError = "";
            root.maybePrepare();
            if (value.installedIdentity && value.installedIdentity !== root.installedIdentity) {
                root.installedIdentity = value.installedIdentity;
                root.sourcesLoaded = false;
                root.check();
            }
        }
        onFailed: message => { root.statusError = message; }
    }
    FileView {
        id: componentsFile
        path: "/etc/cybexos/components.json"
        printErrors: false
        onLoaded: {
            try {
                const value = JSON.parse(text());
                root.installedComponents = value && value.schema === 1 && value.components ? value.components : {};
            } catch (error) {
                root.installedComponents = {};
            }
        }
        onLoadFailed: root.installedComponents = {}
    }
    // Silent: the activation health check rejects a shell whose journal
    // shows file errors, and a missing marker is the normal case.
    FileView {
        id: reopenFile
        path: root.reopenPath
        printErrors: false
        atomicWrites: true
        blockWrites: true
        onLoaded: root.restoreOpen(text())
        onLoadFailed: root.restoreOpen("")
    }
    JsonCommand {
        id: chooser
        onCompleted: () => root.refreshStatus()
        onFailed: message => { root.requestError = message; root.refreshStatus(); }
    }
    Timer {
        interval: 600000
        running: true
        onTriggered: {
            root.preparationAllowed = true;
            root.maybePrepare();
        }
    }
    // Health checks inspect the running shell, so give it time to settle.
    Timer {
        interval: 20000
        running: root.deployment.state === "awaiting-login" && root.automatic.confirm === true
            && !root.confirmRequested && !Helpers.pending(root.deployment.request)
        onTriggered: {
            root.confirmRequested = true;
            root.startUnit("cybexos-update-confirm.service");
        }
    }
    Timer { interval: 2000; repeat: true; running: true; triggeredOnStart: true; onTriggered: root.refreshStatus() }
    Timer {
        interval: Math.max(10, Number((Settings.modOpts.updates || {}).pollMins) || 60) * 60000
        repeat: true; running: true; triggeredOnStart: true; onTriggered: root.check()
    }
}
