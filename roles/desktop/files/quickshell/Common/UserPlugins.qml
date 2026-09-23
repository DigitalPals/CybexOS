pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "ProcHelpers.js" as ProcHelpers

// Separate from Settings: older shell schemas must never rewrite plugin data.
Singleton {
    id: root

    property var plugins: []
    property var widgets: []
    property var barConfig: ({})
    property string error: ""
    property string lastResult: ""
    property var pendingWrites: []
    readonly property bool busy: writer.running || pendingWrites.length > 0
    property string operationResult: ""
    property bool refreshPending: false
    signal widgetMembershipFinished(string key, bool enabled, bool success, string message)
    // Registry across outputs for Omarchy broadcast and popup ownership.
    property var widgetHosts: []
    property var activePopout: null
    property var clickTargets: []
    readonly property var enabled: plugins.filter(plugin => plugin.enabled)
    readonly property var enabledWidgets: widgets.filter(plugin => plugin.enabled)
    readonly property string helper: Quickshell.shellDir + "/scripts/user-plugins.py"
    // Resolved as scripts/user-plugins.py roots() does.
    readonly property string registryPath: (Quickshell.env("CYBEXOS_USER_CONFIG_ROOT")
        || (Quickshell.env("XDG_CONFIG_HOME") || Quickshell.env("HOME") + "/.config") + "/cybexos")
        + "/plugins.json"

    function registerHost(host) {
        widgetHosts = widgetHosts.concat([host]);
    }

    function unregisterHost(host) {
        if (activePopout === host.widget)
            releasePopout(activePopout);
        widgetHosts = widgetHosts.filter(item => item !== host);
    }

    function requestPopout(owner) {
        if (activePopout && activePopout !== owner && typeof activePopout.close === "function")
            activePopout.close();
        Popouts.close();
        activePopout = owner;
    }

    function releasePopout(owner) {
        if (activePopout === owner)
            activePopout = null;
    }

    Connections {
        target: Popouts
        function onChanged() {
            if (Popouts.open && root.activePopout) {
                if (typeof root.activePopout.close === "function")
                    root.activePopout.close();
                root.activePopout = null;
            }
        }
    }

    function refresh() {
        if (!scanner.running)
            scanner.running = true;
        else
            refreshPending = true;
    }

    function moveWidget(key, section, index) {
        enqueue(["python3", helper, "move-widget", key, section, String(index)]);
    }

    function configureWidget(descriptor, changes) {
        enqueue(["python3", helper, "configure-widget", descriptor.key, JSON.stringify(changes)]);
    }

    function mergeSettings(id, settings, instanceName) {
        const command = ["python3", helper, "merge", id, JSON.stringify(settings)];
        if (instanceName) command.push("--instance", instanceName);
        enqueue(command);
    }

    function setSetting(id, key, value) {
        enqueue(["python3", helper, "set", id, key, value]);
    }

    function enqueue(command) {
        pendingWrites = pendingWrites.concat([command]);
        nextWrite();
    }

    function nextWrite() {
        if (writer.running || pendingWrites.length === 0)
            return;
        error = "";
        operationResult = "";
        writer.command = pendingWrites[0];
        pendingWrites = pendingWrites.slice(1);
        writer.running = true;
    }

    Process {
        id: scanner
        property bool timedOut: false
        command: ["python3", root.helper, "list", "--live"]
        stdout: StdioCollector {
            onStreamFinished: {
                if (text === root.lastResult)
                    return;
                try {
                    const result = JSON.parse(text);
                    if (result.error || !Array.isArray(result.plugins)) {
                        // A malformed or half-written registry is shown, never
                        // repaired with defaults — and never applied: an empty
                        // list would unload every running plugin until the
                        // next good scan. Keep the last good state.
                        root.error = result.error || "Could not read user widgets";
                        return;
                    }
                    root.error = "";
                    root.barConfig = result.bar || {};
                    root.widgets = result.widgets || [];
                    root.plugins = result.plugins;
                    root.lastResult = text;
                } catch (exception) {
                    root.error = "Could not read user widgets";
                }
            }
        }
        property bool exitSeen: false
        property int lastExit: 0
        onExited: (code, status) => {
            scanner.exitSeen = true;
            scanner.lastExit = code;
        }
        // Settles on the falling edge of `running`, the only signal there is
        // when python3 cannot start, so a queued refresh is never stranded.
        onRunningChanged: {
            if (running) {
                timedOut = false;
                exitSeen = false;
                lastExit = 0;
                scanWatchdog.restart();
                return;
            }
            scanWatchdog.stop();
            if (!exitSeen || lastExit !== 0)
                root.error = timedOut ? "Plugin discovery timed out" : "Could not inspect user widgets";
            if (root.refreshPending) {
                root.refreshPending = false;
                Qt.callLater(root.refresh);
            }
        }
    }

    Process {
        id: writer
        property bool exitSeen: false
        property int lastExit: 0
        stdout: StdioCollector {
            onStreamFinished: root.operationResult = text.trim()
        }
        stderr: StdioCollector {
            onStreamFinished: {
                if (text.trim())
                    root.error = text.trim();
            }
        }
        onExited: (code, status) => {
            writer.exitSeen = true;
            writer.lastExit = code;
        }
        // The queue advances on the falling edge of `running`: a writer that
        // never started sends no exited(), and must not leave `busy` stuck
        // with the rest of the queue behind it.
        onRunningChanged: {
            if (running) {
                exitSeen = false;
                lastExit = 0;
                return;
            }
            const code = exitSeen ? lastExit : ProcHelpers.NOT_STARTED;
            if (code === ProcHelpers.NOT_STARTED && root.error === "")
                root.error = ProcHelpers.commandError("user-plugins.py", code, "");
            if (command[2] === "configure-widget") {
                const changes = JSON.parse(command[4]);
                if (typeof changes.enabled === "boolean")
                    root.widgetMembershipFinished(command[3], changes.enabled, code === 0,
                        code === 0 ? "" : root.error || "Could not save widget changes");
            }
            root.refresh();
            Qt.callLater(root.nextWrite);
        }
    }

    // A scan waits on the registry lock and reads package trees; neither may
    // wedge discovery for the rest of the session.
    Timer {
        id: scanWatchdog
        interval: 20000
        onTriggered: {
            if (!scanner.running)
                return;
            scanner.timedOut = true;
            root.error = "Plugin discovery timed out";
            scanner.running = false;
        }
    }

    // Registry edits are seen at once; package trees are polled. The helper
    // only stats unchanged packages, but a scan is still a process, so poll
    // briskly only while the settings window can show the result.
    FileView {
        path: root.registryPath
        watchChanges: true
        printErrors: false
        onFileChanged: registryChanged.restart()
    }

    Timer {
        id: registryChanged
        interval: 150
        onTriggered: root.refresh()
    }

    Connections {
        target: Settings
        function onPanelOpenChanged() {
            if (Settings.panelOpen)
                root.refresh();
        }
    }

    Timer {
        interval: Settings.panelOpen ? 2000 : 30000
        repeat: true
        running: true
        triggeredOnStart: true
        onTriggered: root.refresh()
    }
}
