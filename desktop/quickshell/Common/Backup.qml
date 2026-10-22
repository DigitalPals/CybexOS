pragma Singleton
import QtQuick
import Quickshell
import "BackupHelpers.js" as BackupHelpers

// Personal-file backups for Settings → Backup & recovery. The user helper
// nerdos-backup owns everything that matters: the configuration, the
// keyring password, every restic run, the state file and the notifications.
// This reads its `status --json` while the page is on screen and starts
// the few actions the page offers. Backups and restores run as transient
// user units, so the shell can restart or close Settings mid-run.
//
// The recovery key from setup lives only here, in memory, until the person
// says it is saved. Nothing in the shell writes it anywhere; copying offers
// it to the clipboard as sensitive, which clipboard history leaves out.
Singleton {
    id: root

    readonly property string helper: BackupHelpers.helperPath(Quickshell.env("HOME"))
    property var status: BackupHelpers.emptyStatus()
    // Why `status --json` could not be read, such as a missing helper.
    property string statusError: ""
    readonly property bool configured: status.configured
    readonly property bool running: status.running
    // The Backup & recovery page is on screen; status is polled only then.
    property bool watched: false
    // A short helper command is in flight: setup, a key, a switch, a list.
    readonly property bool busy: actionRequest.running
    property string action: ""
    property string error: ""
    property string pendingKey: ""
    // The chosen destination already holds backups; their key connects it.
    property bool needsRecoveryKey: false
    property var pendingDestination: null
    // A first backup follows the key step.
    property bool firstRun: false
    property var snapshots: []
    property bool snapshotsLoaded: false
    property string snapshotsError: ""
    // Set while a run was just started and the helper has not yet taken
    // its lock, so the page polls quickly and does not flash "idle".
    property bool starting: false
    property bool copied: false

    signal setupFinished(bool ok)

    function refresh() {
        if (!statusRequest.running)
            statusRequest.running = true;
    }

    function run(name, command, input) {
        if (actionRequest.running || command.length === 0)
            return false;
        action = name;
        error = "";
        actionRequest.stdinEnabled = input !== undefined;
        actionRequest.inputText = input !== undefined ? input + "\n" : "";
        actionRequest.timeoutMs = name === "snapshots" || name === "setup" || name === "connect"
            || name === "key" ? 180000 : 30000;
        actionRequest.command = command;
        actionRequest.running = true;
        return true;
    }

    function setup(kind, target, path) {
        const command = BackupHelpers.setupCommand(helper, kind, target, path, false);
        if (command.length === 0) {
            error = kind === "sftp" ? "Enter an SSH alias or user@hostname and a plain folder path."
                : "Choose a folder for the backups.";
            return;
        }
        needsRecoveryKey = false;
        pendingDestination = { kind: kind, target: target, path: path };
        run("setup", command);
    }

    function connect(recoveryKey) {
        const target = pendingDestination;
        if (!target || String(recoveryKey || "").trim() === "")
            return;
        run("connect", BackupHelpers.setupCommand(helper, target.kind, target.target, target.path, true),
            String(recoveryKey).trim());
    }

    function cancelSetup() {
        needsRecoveryKey = false;
        pendingDestination = null;
        error = "";
    }

    function confirmKey() {
        run("confirm", [helper, "confirm-key"]);
    }

    function newKey() {
        run("key", [helper, "recovery-key", "--json"]);
    }

    function copyKey() {
        if (pendingKey === "" || copyRequest.running)
            return;
        copied = false;
        copyRequest.inputText = pendingKey + "\n";
        copyRequest.running = true;
    }

    function setAutomatic(on) {
        run("automatic", [helper, "automatic", on ? "on" : "off"]);
    }

    function loadSnapshots() {
        snapshotsError = "";
        run("snapshots", [helper, "snapshots", "--json"]);
    }

    function startUnit(name, command) {
        if (command.length === 0 || unitRequest.running)
            return;
        error = "";
        unitRequest.operation = name;
        unitRequest.command = command;
        unitRequest.running = true;
        starting = true;
        startingTimeout.restart();
    }

    function backupNow() {
        startUnit("now", BackupHelpers.nowCommand(helper, Date.now()));
    }

    function restore(snapshotId, path) {
        startUnit("restore", BackupHelpers.restoreCommand(helper, snapshotId, path, Date.now()));
    }

    function parse(body) {
        try {
            return JSON.parse(body);
        } catch (e) {
            return null;
        }
    }

    function finishAction(code, body, failure) {
        const name = action;
        action = "";
        const data = parse(body);
        if (name === "snapshots") {
            snapshotsLoaded = code === 0;
            snapshots = code === 0 ? BackupHelpers.parseSnapshots(body) : [];
            snapshotsError = code === 0 ? "" : BackupHelpers.errorText(code, body, failure);
            return;
        }
        if (code !== 0) {
            if ((name === "setup" || name === "connect") && data && data.existing === true) {
                needsRecoveryKey = true;
                error = "";
            } else {
                error = BackupHelpers.errorText(code, body, failure);
            }
            refresh();
            return;
        }
        if (name === "setup" || name === "connect") {
            needsRecoveryKey = false;
            pendingDestination = null;
            const key = data && typeof data.recoveryKey === "string" ? data.recoveryKey : "";
            pendingKey = key;
            copied = false;
            firstRun = key !== "";
            setupFinished(true);
            // Connected backups need no key step; their first run starts now.
            if (key === "")
                backupNow();
        } else if (name === "key") {
            pendingKey = data && typeof data.recoveryKey === "string" ? data.recoveryKey : "";
            copied = false;
        } else if (name === "confirm") {
            pendingKey = "";
            copied = false;
            if (firstRun) {
                firstRun = false;
                backupNow();
            }
        }
        refresh();
    }

    CommandRequest {
        id: statusRequest
        command: [root.helper, "status", "--json"]
        timeoutMs: 10000
        onCompleted: (code, body, failure) => {
            root.statusError = code === 0 ? "" : BackupHelpers.errorText(code, body, failure);
            if (code !== 0)
                return;
            const next = BackupHelpers.parseStatus(body);
            if (next.running)
                root.starting = false;
            root.status = next;
        }
    }

    CommandRequest {
        id: actionRequest
        onCompleted: (code, body, failure) => root.finishAction(code, body, failure)
    }

    CommandRequest {
        id: unitRequest
        property string operation: ""
        timeoutMs: 20000
        onCompleted: (code, body, failure) => {
            if (code !== 0) {
                root.starting = false;
                root.error = BackupHelpers.errorText(code, body, failure);
            }
            Qt.callLater(root.refresh);
        }
    }

    // The key travels on stdin, never argv, where other accounts could read
    // it; --sensitive marks the offer as a secret, so clipboard-history-store
    // skips it. The request keeps stdin open, so the shell reads one line
    // and hands wl-copy a pipe that ends.
    CommandRequest {
        id: copyRequest
        command: ["sh", "-c", "IFS= read -r key && printf '%s' \"$key\" | wl-copy --sensitive >/dev/null 2>&1"]
        stdinEnabled: true
        timeoutMs: 5000
        onCompleted: code => {
            root.copied = code === 0;
            if (code !== 0)
                root.error = "Could not copy the key. Select it and copy it instead.";
        }
    }

    Timer {
        id: startingTimeout
        interval: 10000
        onTriggered: root.starting = false
    }

    // Quick while something runs, slow otherwise, and not at all while the
    // page is closed: the timer and the helper keep their own state.
    Timer {
        interval: root.running || root.starting ? 1000 : 15000
        running: root.watched
        repeat: true
        triggeredOnStart: true
        onTriggered: root.refresh()
    }
}
