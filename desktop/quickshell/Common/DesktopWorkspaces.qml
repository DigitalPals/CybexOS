pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import "WorkspaceHelpers.js" as WorkspaceHelpers
import "WindowCommands.js" as WindowCommands

// One read-only snapshot watcher for the whole shell. The compositor's
// user-owned preferences are authoritative; construction never writes them.
Singleton {
    id: root

    property var snapshot: null
    property var pendingCommands: []
    property string commandError: ""
    readonly property bool ready: snapshot !== null
    readonly property string mode: ready ? snapshot.mode : "shared"
    readonly property string defaultLayout: ready ? snapshot.defaultLayout : "dwindle"
    readonly property bool defaultLayoutManaged: !ready || snapshot.defaultLayoutManaged
    readonly property string nativeDefaultLayout: ready ? snapshot.nativeDefaultLayout : "dwindle"
    readonly property bool titlebarsEnabled: !ready || snapshot.titlebarsEnabled
    readonly property bool scrollingAvailable: ready && snapshot.capabilities.scrolling
    readonly property bool titlebarsAvailable: ready && snapshot.capabilities.titlebars
    readonly property string error: commandError || (ready ? snapshot.error : "")
    readonly property string snapshotPath: Quickshell.env("XDG_RUNTIME_DIR")
        ? Quickshell.env("XDG_RUNTIME_DIR") + "/nerdos/workspaces.json" : ""

    function monitor(name) { return WorkspaceHelpers.monitor(snapshot, name); }
    function workspace(id) { return WorkspaceHelpers.workspace(snapshot, id); }
    function minimizedWindow(address) { return WorkspaceHelpers.minimizedWindow(snapshot, address); }
    function isMinimized(address) { return minimizedWindow(address) !== null; }
    function isLive(address) {
        const key = WindowCommands.bareAddress(address);
        return key !== "" && Hyprland.toplevels.values.some(win =>
            WindowCommands.bareAddress(win.address) === key);
    }

    // IPC can precede the snapshot, or a workspace can be renamed while the
    // overview is open. Native metadata wins over cached numbered rows.
    function targetWorkspace(target) {
        const id = target && typeof target === "object" ? target.id : target;
        const live = Hyprland.workspaces.values.find(workspace => workspace.id === id)
            || Hyprland.toplevels.values.map(win => win.workspace).find(workspace => workspace && workspace.id === id);
        return live ? { id: live.id, kind: WindowCommands.workspaceKind({ id: live.id, name: live.name }),
            workspaceName: live.name || String(live.id) } : target;
    }
    function canSetLayout(target) {
        return ready && WindowCommands.regularWorkspaceId(targetWorkspace(target)) !== "";
    }
    function canMinimize(address) {
        const key = WindowCommands.bareAddress(address);
        const win = key !== "" ? Hyprland.toplevels.values.find(win =>
            WindowCommands.bareAddress(win.address) === key) : null;
        return ready && !!win && canSetLayout(win.workspace);
    }

    function dispatch(command, address) {
        if (command === "" || (address && !isLive(address)))
            return false;
        if (command.indexOf('require("workspaces").') === 0) {
            if (pendingCommands.length >= 64)
                return false;
            pendingCommands = pendingCommands.concat([{ expression: command, address: address || "" }]);
            runNext();
        } else {
            Hyprland.dispatch(command);
        }
        return true;
    }

    function runNext() {
        if (commandProc.running || pendingCommands.length === 0)
            return;
        const next = pendingCommands[0];
        pendingCommands = pendingCommands.slice(1);
        if (next.address !== "" && !isLive(next.address)) {
            Qt.callLater(root.runNext);
            return;
        }
        // Module functions execute an operation and return nil, rather than
        // a Hyprland dispatcher. They must use eval, with expression as one
        // argv element; neither a shell nor an interpolated command line.
        commandProc.command = ["hyprctl", "eval", next.expression];
        commandProc.running = true;
    }

    function focusCommand(target) {
        target = targetWorkspace(target);
        return ready && WindowCommands.regularWorkspaceId(target) !== ""
            ? WindowCommands.desktopFocus(target) : WindowCommands.focusWorkspace(target);
    }
    function activateCommand(address) {
        const key = WindowCommands.bareAddress(address);
        const win = Hyprland.toplevels.values.find(win => WindowCommands.bareAddress(win.address) === key);
        return !isLive(address) ? "" : ready && (!win.workspace
                || WindowCommands.workspaceKind(targetWorkspace(win.workspace)) !== "named")
            ? WindowCommands.desktopActivate(address) : WindowCommands.focusWindow(address);
    }
    function moveCommand(address, target) {
        target = targetWorkspace(target);
        return !isLive(address) ? "" : ready && WindowCommands.regularWorkspaceId(target) !== ""
            ? WindowCommands.desktopMove(address, target) : WindowCommands.moveWindow(address, target);
    }
    function activate(address) { return dispatch(activateCommand(address), address); }
    function focus(target) { return dispatch(focusCommand(target)); }
    function move(address, target) { return dispatch(moveCommand(address, target), address); }
    function minimize(address) {
        return canMinimize(address) && dispatch(WindowCommands.desktopMinimize(address), address);
    }
    function newWorkspace(name) {
        return ready && dispatch(WindowCommands.desktopNew(name));
    }
    function newWorkspaceAndMove(address, name) {
        return ready && isLive(address) && dispatch(WindowCommands.desktopNewAndMove(address, name), address);
    }
    function next(direction, name) {
        return ready && dispatch(WindowCommands.desktopNext(direction, name));
    }
    function setLayout(id, layout) {
        return canSetLayout(id) && Settings.loaded && (layout !== "scrolling" || scrollingAvailable)
            && dispatch(WindowCommands.desktopLayout(targetWorkspace(id), layout));
    }
    function cycleLayout(id) {
        return canSetLayout(id) && Settings.loaded && dispatch(WindowCommands.desktopCycleLayout(targetWorkspace(id)));
    }
    function setMode(mode) {
        return ready && Settings.loaded && dispatch(WindowCommands.desktopMode(mode));
    }
    function setDefaultLayout(layout) {
        return ready && Settings.loaded && (layout !== "scrolling" || scrollingAvailable)
            && dispatch(WindowCommands.desktopDefaultLayout(layout));
    }
    function setTitlebarsEnabled(enabled) {
        return ready && Settings.loaded && dispatch(WindowCommands.desktopTitlebars(enabled));
    }
    function layoutLabel(layout, nativeLayout) {
        return layout === "floating" ? I18n.tr("Floating")
            : layout === "scrolling" ? I18n.tr("Scrolling")
            : layout === "dwindle" ? I18n.tr("Tiled")
            : I18n.format("Custom (%1)", [nativeLayout || layout]);
    }
    function layoutGlyph(layout) {
        return WorkspaceHelpers.layoutIcon(layout);
    }

    FileView {
        id: store
        path: root.snapshotPath
        printErrors: false
        watchChanges: true
        onFileChanged: reload()
        onLoaded: root.snapshot = WorkspaceHelpers.parseSnapshot(text())
        onLoadFailed: root.snapshot = null
    }
    Process {
        id: commandProc
        property int lastExit: -1
        property int lastStatus: -1
        property string errorText: ""
        property string outputText: ""
        stdout: StdioCollector { onStreamFinished: commandProc.outputText = text.slice(0, 2048) }
        stderr: StdioCollector { onStreamFinished: commandProc.errorText += text.slice(0, 512) }
        onExited: (exitCode, exitStatus) => {
            lastExit = exitCode;
            lastStatus = exitStatus;
        }
        // A missing executable emits no exited signal. The falling edge
        // still releases the queue and exposes a failure in Settings.
        onRunningChanged: {
            if (running) {
                lastExit = -1;
                lastStatus = -1;
                errorText = "";
                outputText = "";
            } else {
                const detail = (outputText.trim() === "ok" ? "" : outputText.trim()) + " " + errorText.trim();
                root.commandError = WorkspaceHelpers.commandSucceeded(lastExit, lastStatus, outputText) ? ""
                    : I18n.tr("Workspace command failed") + (detail.trim() !== ""
                        ? ": " + detail.trim().slice(0, 512) : "");
                store.reload();
                Qt.callLater(root.runNext);
            }
        }
    }
    Timer {
        interval: 5000
        running: commandProc.running
        onTriggered: commandProc.running = false
    }
    // A missing-at-start runtime directory must recover on the first module
    // event, including after a compositor reload. No timer or subprocess poll.
    Connections {
        target: Hyprland
        function onRawEvent(event) {
            if (event.name === "configreloaded" || event.name === "workspacev2"
                    || event.name === "monitoradded" || event.name === "monitorremoved")
                store.reload();
        }
    }
}
