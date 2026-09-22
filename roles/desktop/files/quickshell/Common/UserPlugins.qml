pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

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
    // Registry across outputs for Omarchy broadcast and popup ownership.
    property var widgetHosts: []
    property var activePopout: null
    property var clickTargets: []
    readonly property var enabled: plugins.filter(plugin => plugin.enabled)
    readonly property var enabledWidgets: widgets.filter(plugin => plugin.enabled)
    readonly property string helper: Quickshell.shellDir + "/scripts/user-plugins.py"

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
    }

    function moveWidget(key, section, index) {
        enqueue(["python3", helper, "move-widget", key, section, String(index)]);
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
        command: ["python3", root.helper, "list", "--live"]
        stdout: StdioCollector {
            onStreamFinished: {
                if (text === root.lastResult)
                    return;
                try {
                    const result = JSON.parse(text);
                    root.error = result.error;
                    // A malformed registry is shown, never repaired with defaults.
                    root.barConfig = result.bar || {};
                    root.widgets = result.widgets || [];
                    root.plugins = result.plugins;
                    root.lastResult = text;
                } catch (exception) {
                    root.error = "Could not read user widgets";
                }
            }
        }
        onExited: (code, status) => {
            if (code !== 0)
                root.error = "Could not inspect user widgets";
        }
    }

    Process {
        id: writer
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
            root.refresh();
            Qt.callLater(root.nextWrite);
        }
    }

    Timer {
        interval: 2000
        repeat: true
        running: true
        triggeredOnStart: true
        onTriggered: root.refresh()
    }
}
