pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "RemoteServerHelpers.js" as Helpers

Singleton {
    id: root
    readonly property var options: Settings.modOpts.remote
    readonly property string host: options.host
    readonly property string label: options.label || host || "Remote Server"
    readonly property bool widgetOn: ["left", "center", "right"].some(
        column => Settings.mods[column].some(entry => entry.id === "remote" && entry.on))
    property int watchers: 0
    readonly property bool wanted: host !== "" && (widgetOn || watchers > 0)
    readonly property int cadence: watchers > 0 ? 2 : options.pollSecs
    property var sample: null
    property var history: []
    property string error: ""
    property double updatedAt: 0
    property double now: Date.now()
    property double heartbeat: 0
    property int failures: 0
    readonly property bool busy: worker.running && updatedAt === 0
    readonly property bool stale: sample !== null && (error !== "" || !worker.running
        || now - updatedAt > Math.max(15000, cadence * 3000))
    readonly property string age: updatedAt > 0
        ? Math.max(0, Math.floor((now - updatedAt) / 1000)) + "s ago" : "No readings yet"
    readonly property string status: !host ? "Set up SSH" : error ? "Disconnected"
        : stale ? "Stale" : sample ? "Connected" : "Connecting…"
    readonly property string barValue: Helpers.metric(sample, options)
    readonly property var selectedNetwork: Helpers.network(sample, options.interface)

    function acquire() { watchers++; }
    function release() { watchers = Math.max(0, watchers - 1); }
    function configure() {
        Settings.openWidgetSettings("remote");
        Settings.showPanel("bar", Popouts.hostScreenName);
    }
    function start() {
        if (!wanted || worker.running) return;
        retry.stop();
        worker.issuedHost = host;
        worker.command = ["python3", "-B", Quickshell.shellDir + "/scripts/remote-server.py", host];
        worker.running = true;
    }
    function refresh() {
        if (worker.running) worker.write(JSON.stringify({ interval: cadence, refresh: true }) + "\n");
        else { failures = 0; start(); }
    }
    function receive(line) {
        if (!wanted || worker.issuedHost !== host) return;
        try {
            if (line.length > 262144) throw new Error("Telemetry response too large");
            const value = JSON.parse(line);
            if (!Helpers.validSample(value)) throw new Error("Invalid telemetry response");
            now = Date.now();
            history = Helpers.historyAppend(history, value, now);
            sample = value;
            updatedAt = now;
            heartbeat = now;
            error = "";
            failures = 0;
        } catch (e) {
            error = "Could not read server statistics. Check that the server supports Python 3.9+ and Linux /proc.";
            worker.running = false;
        }
    }
    onHostChanged: {
        sample = null; history = []; updatedAt = 0; error = ""; failures = 0;
        retry.stop();
        if (worker.running) worker.running = false;
        else Qt.callLater(start);
    }
    onWantedChanged: {
        if (wanted) Qt.callLater(start);
        else { retry.stop(); worker.running = false; }
    }
    onCadenceChanged: {
        if (worker.running) worker.write(JSON.stringify({ interval: cadence }) + "\n");
    }
    Component.onCompleted: Qt.callLater(start)

    IpcHandler {
        target: "remoteServer"
        function status(): string {
            return JSON.stringify({ host: root.host, label: root.label, status: root.status,
                updatedAt: root.updatedAt, stale: root.stale, error: root.error,
                cadence: root.cadence, watchers: root.watchers, running: worker.running,
                metric: root.options.metric, value: root.barValue, sample: root.sample });
        }
        function refresh(): void { root.refresh(); }
        function configure(): void { root.configure(); }
    }

    Timer {
        id: retry
        onTriggered: root.start()
    }
    Timer {
        interval: 1000
        running: root.wanted
        repeat: true
        onTriggered: {
            root.now = Date.now();
            if (worker.running && root.now - root.heartbeat > Math.max(20000, root.cadence * 3000)) {
                root.error = "Server stopped responding; reconnecting…";
                worker.running = false;
            }
        }
    }
    Process {
        id: worker
        property string issuedHost: ""
        property string diagnostic: ""
        stdinEnabled: true
        stdout: SplitParser { onRead: data => root.receive(data) }
        stderr: SplitParser {
            onRead: data => { if (data.trim()) worker.diagnostic = data.trim().slice(0, 240); }
        }
        onStarted: write(JSON.stringify({ interval: root.cadence }) + "\n")
        onRunningChanged: {
            if (running) {
                diagnostic = "";
                root.heartbeat = Date.now();
            } else if (root.wanted) {
                if (issuedHost !== root.host) {
                    retry.interval = 1;
                } else {
                    if (!root.error) root.error = diagnostic || "SSH connection ended. Check the host, trusted host key and SSH key access.";
                    root.failures++;
                    retry.interval = Math.min(60000, 5000 * Math.pow(2, Math.min(root.failures - 1, 4)));
                }
                retry.restart();
            }
        }
    }
}
