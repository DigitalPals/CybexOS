pragma Singleton
pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io

// Read-only operational state for Settings/System. Nothing here restarts the
// shell: refresh is safe to invoke from UI visibility and retry controls.
Singleton {
    id: root

    readonly property string stateHome: Quickshell.env("XDG_STATE_HOME")
        || (Quickshell.env("HOME") + "/.local/state")
    readonly property string helper: Quickshell.shellDir + "/scripts/shell-health.py"

    property string deploymentStatus: "unknown"
    property string deploymentDetail: "No deployment health record yet"
    property string deploymentId: ""
    property string deploymentCheckedAt: ""
    property bool serviceActive: false
    property int servicePid: 0
    property int serviceUptimeSecs: 0
    property var recentWarnings: []
    property bool busy: false
    property string refreshError: ""

    // Naming a connection singleton constructs it. An integration whose bar
    // module is off is reported as off — it contributes no issue — and the
    // short-circuit keeps this page from being what brings it to life.
    readonly property bool t3On: moduleOn("t3")
    readonly property bool hermesOn: moduleOn("hermes")

    readonly property var integrationIssues: {
        const issues = [];
        if (root.t3On && T3Connection.state === "offline"
                && T3Connection.connectionError !== "")
            issues.push("T3: " + T3Connection.connectionError);
        if (root.hermesOn && HermesConnection.state === "offline"
                && HermesConnection.connectionError !== "")
            issues.push("Hermes: " + HermesConnection.connectionError);
        if (GitHub.inboxError !== "")
            issues.push("GitHub: " + GitHub.inboxError);
        return issues;
    }
    readonly property int issueCount: integrationIssues.length + recentWarnings.length
    readonly property bool healthy: serviceActive
        && deploymentStatus !== "failed" && deploymentStatus !== "rolled-back"
    readonly property string statusLabel: !serviceActive ? "Service unavailable"
        : deploymentStatus === "failed" ? "Deployment failed"
        : deploymentStatus === "rolled-back" ? "Rolled back"
        : issueCount > 0 ? issueCount + (issueCount === 1 ? " issue" : " issues")
        : "Healthy"

    function moduleOn(id) {
        const mods = Settings.mods;
        return ["left", "center", "right"].some(col =>
            mods[col].some(m => m.id === id && m.on));
    }

    function refresh() {
        if (probe.running)
            return;
        busy = true;
        refreshError = "";
        deploymentFile.reload();
        probe.running = true;
    }

    function uptimeLabel() {
        let seconds = Math.max(0, serviceUptimeSecs);
        const days = Math.floor(seconds / 86400);
        const hours = Math.floor((seconds % 86400) / 3600);
        const minutes = Math.floor((seconds % 3600) / 60);
        if (days > 0)
            return days + "d " + hours + "h";
        if (hours > 0)
            return hours + "h " + minutes + "m";
        return Math.max(1, minutes) + "m";
    }

    function finishProbe() {
        busy = false;
        if (!probe.exitSeen || probe.lastExit !== 0) {
            serviceActive = false;
            refreshError = "Could not inspect Quickshell";
            return;
        }
        try {
            const data = JSON.parse(probe.body);
            const service = data.service || ({});
            serviceActive = service.active === true;
            servicePid = Number(service.pid) || 0;
            serviceUptimeSecs = Number(service.uptimeSecs) || 0;
            recentWarnings = Array.isArray(data.warnings) ? data.warnings : [];
        } catch (e) {
            serviceActive = false;
            refreshError = "Unreadable shell health response";
        }
    }

    FileView {
        id: deploymentFile
        path: root.stateHome + "/cybexos/quickshell-health.json"
        printErrors: false
        watchChanges: true
        onFileChanged: reload()
        // JsonAdapter ids are absent from the FileView static type data, as in
        // the other persisted Common models. The runtime owns this child.
        // qmllint disable unqualified
        onLoaded: {
            root.deploymentStatus = deploymentData.status || "unknown";
            root.deploymentDetail = deploymentData.detail || "No deployment detail";
            root.deploymentId = deploymentData.deploymentId || "";
            root.deploymentCheckedAt = deploymentData.checkedAt || "";
        }
        // qmllint enable unqualified
        onLoadFailed: error => {
            if (error === FileViewError.FileNotFound) {
                root.deploymentStatus = "unknown";
                root.deploymentDetail = "No deployment health record yet";
            } else {
                root.deploymentStatus = "failed";
                root.deploymentDetail = "Could not read deployment health";
            }
        }

        JsonAdapter {
            id: deploymentData
            property string status: "unknown"
            property string detail: ""
            property string deploymentId: ""
            property string checkedAt: ""
        }
    }

    Process {
        id: probe
        property string body: ""
        property bool exitSeen: false
        property int lastExit: -1
        command: ["/usr/bin/python3", root.helper]
        stdout: StdioCollector { onStreamFinished: probe.body = text }
        stderr: StdioCollector {}
        onStarted: {
            body = "";
            exitSeen = false;
            lastExit = -1;
        }
        onExited: code => {
            exitSeen = true;
            lastExit = code;
        }
        onRunningChanged: {
            if (!running)
                Qt.callLater(root.finishProbe);
        }
    }
}
