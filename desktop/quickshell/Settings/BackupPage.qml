pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import "../Common"
import "../Common/BackupHelpers.js" as BackupHelpers
import "LocalTime.js" as LocalTime

// Backup & recovery: encrypted copies of the home folder first, then the
// system's own recovery points. Backups are personal files on another
// drive or computer; recovery points are the installed system on this one.
//
// Until backups are set up the group is one row and one button. Setting up
// is three short steps on this page rather than a window of its own: where
// the backups go, the recovery key, then the first backup, which runs while
// the page shows its progress. Afterwards the group reads as status (the
// last backup and when the next one runs), the destination, the automatic
// switch and restore. Restoring never replaces anything: files go into a
// new folder under ~/Restored, which then opens in Files.
//
// Everything that matters lives in the nerdos-backup helper (Common/
// Backup.qml); this page holds only what the person is typing.
SettingsPage {
    id: page

    // Choosing a destination, from "Set up…" or "Change…".
    property bool choosing: false
    property string kind: "local"
    property string folder: ""
    property string host: ""
    property string remoteFolder: BackupHelpers.DEFAULT_REMOTE_PATH
    property string recoveryText: ""
    property bool restoreOpen: false
    property string restoreId: ""
    property string restorePath: ""

    readonly property var status: Backup.status
    readonly property bool keyStep: Backup.pendingKey !== ""
    readonly property bool chooseStep: choosing && !keyStep
    readonly property bool statusShown: Backup.configured && !chooseStep && !keyStep
    readonly property real nowMs: clock.date.getTime()
    readonly property bool canContinue: Backup.needsRecoveryKey ? recoveryText.trim() !== ""
        : kind === "local" ? folder !== ""
        : BackupHelpers.validHost(host) && BackupHelpers.validRemotePath(remoteFolder)
    readonly property color dotColor: {
        switch (BackupHelpers.tone(status)) {
        case "ok": return Theme.connected;
        case "running": return Theme.accentText;
        case "warning": return Theme.amber;
        case "error": return Theme.red;
        default: return "transparent";
        }
    }

    // The next run, which is never more than a day away: "tomorrow after 07:00".
    // The timer checks hourly, so the time is the earliest it starts.
    function formatDue(ms) {
        const days = -LocalTime.daysBetween(ms, page.nowMs);
        const time = LocalTime.clock(new Date(ms), Settings.clock24);
        return days <= 0 ? "today after " + time
            : days === 1 ? "tomorrow after " + time
            : LocalTime.label(ms, page.nowMs, Settings.clock24);
    }

    function startChoosing() {
        Backup.cancelSetup();
        recoveryText = "";
        choosing = true;
    }

    function cancelChoosing() {
        Backup.cancelSetup();
        choosing = false;
    }

    function continueSetup() {
        if (!canContinue || Backup.busy)
            return;
        if (Backup.needsRecoveryKey)
            Backup.connect(recoveryText);
        else if (kind === "local")
            Backup.setup("local", folder, "");
        else
            Backup.setup("sftp", host.trim(), BackupHelpers.remotePath(remoteFolder));
    }

    function toggleRestore() {
        restoreOpen = !restoreOpen;
        if (restoreOpen)
            Backup.loadSnapshots();
    }

    function snapshotChoices() {
        return Backup.snapshots.map(snapshot => ({
            value: snapshot.id,
            label: LocalTime.fromText(snapshot.time, page.nowMs, Settings.clock24, snapshot.time)
                + " · " + BackupHelpers.formatBytes(snapshot.bytes)
        }));
    }

    // Poll the helper only while this page is on screen.
    Binding {
        target: Backup
        property: "watched"
        value: page.visible && Settings.panelOpen
    }

    Connections {
        target: Backup
        function onSetupFinished(ok: bool) {
            if (ok) {
                page.choosing = false;
                page.recoveryText = "";
            }
        }
        function onSnapshotsChanged() {
            if (Backup.snapshots.length > 0
                    && !Backup.snapshots.some(snapshot => snapshot.id === page.restoreId))
                page.restoreId = Backup.snapshots[0].id;
        }
    }

    // Relative times ("Today at", "Tomorrow at") roll over at midnight; a
    // minute tick while the page is visible also keeps "within the hour" true.
    SystemClock {
        id: clock
        precision: SystemClock.Minutes
        enabled: page.visible
    }

    FolderDialog {
        id: folderDialog
        title: I18n.tr("Choose a backup folder")
        onFolderChosen: path => page.folder = path
    }

    Column {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Theme.settingsGroupSpacing

        SettingsGroup {
            id: backups
            width: parent.width
            title: I18n.tr("Backups")

            SettingsHint {
                width: parent.width
                visible: page.status.coverage !== ""
                text: I18n.tr("Includes readable home files, Steam saves and rootless container volumes. Caches, downloaded games, container images and mounted filesystems are excluded.")
            }
            SettingsHint {
                width: parent.width
                visible: page.status.consistency !== ""
                text: I18n.tr("Export databases to a readable home folder before backup. Stop databases when backing up their files directly; private container volumes still need a readable export.")
            }

            // ---- Not set up --------------------------------------------
            ValueRow {
                width: parent.width
                visible: !Backup.status.valid
                label: I18n.tr("Personal files")
                value: Backup.statusError !== "" ? "Unavailable" : "Checking…"
                hint: Backup.statusError
                hintTone: "error"
            }
            ValueRow {
                width: parent.width
                visible: Backup.status.valid && !Backup.configured && !page.chooseStep && !page.keyStep
                label: I18n.tr("Personal files")
                value: "Not backed up"
                hint: I18n.tr("Encrypted copies of your home folder on an external drive or another computer.")

                SettingsAction {
                    text: I18n.tr("Set up…")
                    glyph: "archive"
                    primary: true
                    onTriggered: page.startChoosing()
                }
            }

            // ---- Step 1: where the backups go ----------------------------
            SettingsHint {
                width: parent.width
                visible: page.chooseStep
                tone: "active"
                text: I18n.tr("Step 1 of 3 · Choose where backups go. They are encrypted, so only you can read them.")
            }
            PickerRow {
                width: parent.width
                visible: page.chooseStep && !Backup.needsRecoveryKey
                label: I18n.tr("Back up to")
                model: [
                    { value: "local", label: I18n.tr("Drive or folder") },
                    { value: "sftp", label: I18n.tr("SSH server") }
                ]
                current: page.kind
                onPicked: value => page.kind = value
            }
            ValueRow {
                width: parent.width
                visible: page.chooseStep && !Backup.needsRecoveryKey && page.kind === "local"
                label: I18n.tr("Folder")
                value: page.folder === "" ? "None chosen" : page.folder
                valueMono: page.folder !== ""
                hint: I18n.tr("An external drive is best. Backups go into a nerdos-backup folder inside it.")

                SettingsAction {
                    text: I18n.tr("Choose…")
                    glyph: "folder_open"
                    Accessible.name: I18n.tr("Choose a backup folder")
                    onTriggered: folderDialog.openAt(Backup.status.mediaRoot)
                }
            }
            DraftFieldRow {
                width: parent.width
                visible: page.chooseStep && !Backup.needsRecoveryKey && page.kind === "sftp"
                label: I18n.tr("SSH host")
                value: page.host
                placeholder: I18n.tr("alias or user@host")
                invalid: page.host.trim() !== "" && !BackupHelpers.validHost(page.host)
                hint: invalid ? "Enter an SSH alias or user@hostname; set ports in ~/.ssh/config."
                    : "Uses your SSH keys and ~/.ssh/config. Connect once with ssh in a terminal "
                        + "so this computer trusts the server."
                onEdited: text => page.host = text
            }
            DraftFieldRow {
                width: parent.width
                visible: page.chooseStep && !Backup.needsRecoveryKey && page.kind === "sftp"
                label: I18n.tr("Folder on the server")
                value: page.remoteFolder
                placeholder: BackupHelpers.DEFAULT_REMOTE_PATH
                invalid: !BackupHelpers.validRemotePath(page.remoteFolder)
                hint: invalid ? "Enter a plain path, such as backups/laptop." : ""
                onEdited: text => page.remoteFolder = text
            }
            DraftFieldRow {
                width: parent.width
                visible: page.chooseStep && Backup.needsRecoveryKey
                label: I18n.tr("Recovery key")
                value: page.recoveryText
                placeholder: I18n.tr("XXXXX-XXXXX-XXXXX-XXXXX-XXXXX-XXXXX")
                hint: I18n.tr("This destination already holds NerdOS backups. Enter their recovery key to keep using them from this computer.")
                onEdited: text => page.recoveryText = text
            }
            ValueRow {
                width: parent.width
                visible: page.chooseStep

                SettingsAction {
                    text: I18n.tr("Cancel")
                    enabled: !Backup.busy
                    onTriggered: page.cancelChoosing()
                }
                SettingsAction {
                    text: Backup.busy ? "Preparing…" : Backup.needsRecoveryKey ? "Connect" : "Continue"
                    primary: true
                    enabled: page.canContinue && !Backup.busy
                    onTriggered: page.continueSetup()
                }
            }

            // ---- Step 2: the recovery key --------------------------------
            SettingsHint {
                width: parent.width
                visible: page.keyStep
                tone: "active"
                text: Backup.firstRun ? I18n.tr("Step 2 of 3 · Save your recovery key.") : I18n.tr("Save your new recovery key.")
            }
            TextEdit {
                id: keyText
                visible: page.keyStep
                x: Theme.settingsMarkInset
                width: parent.width - x
                text: Backup.pendingKey
                readOnly: true
                selectByMouse: true
                wrapMode: TextEdit.WrapAnywhere
                font.family: Theme.fontMono
                font.pixelSize: Theme.typography.title
                font.letterSpacing: 1
                color: Theme.textHi
                selectionColor: Theme.accent
                selectedTextColor: Theme.textOnAccent
                Accessible.role: Accessible.StaticText
                Accessible.name: "Recovery key " + Backup.pendingKey
            }
            SettingsHint {
                width: parent.width
                visible: page.keyStep
                tone: "warning"
                maximumLines: 5
                text: I18n.tr("Keep it somewhere safe, such as a password manager or on paper. It opens your backups on any computer. If this computer's keyring and this key are both lost, the backups cannot be opened. It is not shown again.")
            }
            ValueRow {
                width: parent.width
                visible: page.keyStep

                SettingsAction {
                    text: Backup.copied ? I18n.tr("Copied") : I18n.tr("Copy")
                    glyph: Backup.copied ? "check" : "content_copy"
                    Accessible.name: I18n.tr("Copy the recovery key")
                    onTriggered: Backup.copyKey()
                }
                SettingsAction {
                    text: Backup.firstRun ? I18n.tr("I saved it, back up now") : I18n.tr("I saved it")
                    primary: true
                    enabled: !Backup.busy
                    onTriggered: Backup.confirmKey()
                }
            }

            SettingsHint {
                width: parent.width
                visible: (page.chooseStep || page.keyStep) && Backup.error !== ""
                tone: "error"
                text: Backup.error
            }

            // ---- Set up: status, destination, schedule, restore ----------
            SettingsHint {
                width: parent.width
                visible: page.statusShown && Backup.running && Backup.status.lastSuccess === ""
                tone: "active"
                text: I18n.tr("Step 3 of 3 · The first backup copies everything, so it takes a while.")
            }
            ValueRow {
                width: parent.width
                visible: page.statusShown
                label: I18n.tr("Last backup")
                dotColor: page.dotColor
                value: Backup.running ? BackupHelpers.progressLabel(Backup.status.progress)
                    : LocalTime.fromText(Backup.status.lastSuccess, page.nowMs, Settings.clock24, "Never")
                valueColor: Theme.textHi
                hint: Backup.error !== "" ? Backup.error
                    : BackupHelpers.statusHint(Backup.status, LocalTime.parse(Backup.status.nextDue),
                        page.nowMs, page.formatDue)
                hintTone: Backup.error !== "" ? "error" : BackupHelpers.hintTone(Backup.status)

                SettingsAction {
                    text: I18n.tr("Back up now")
                    glyph: "upload"
                    enabled: !Backup.running && !Backup.starting
                    onTriggered: Backup.backupNow()
                }
            }
            ValueRow {
                width: parent.width
                visible: page.statusShown
                label: I18n.tr("Destination")
                value: Backup.status.destination.display
                hint: Backup.status.reachable === false ? Backup.status.unreachableReason : ""
                hintTone: "warning"

                SettingsAction {
                    text: I18n.tr("Change…")
                    enabled: !Backup.running
                    Accessible.name: I18n.tr("Change the backup destination")
                    onTriggered: page.startChoosing()
                }
            }
            SwitchRow {
                width: parent.width
                visible: page.statusShown
                label: I18n.tr("Automatic backups")
                checked: Backup.status.automatic
                enabled: !Backup.busy
                description: I18n.tr("Daily while the destination is available, but not on battery below 30% or on a metered network. A reminder follows a week without one.")
                onToggled: value => Backup.setAutomatic(value)
            }
            ValueRow {
                width: parent.width
                visible: page.statusShown && !Backup.status.recoveryKeyConfirmed
                label: I18n.tr("Recovery key")
                value: "Not saved"
                valueColor: Theme.amber
                hint: I18n.tr("Without it the backups cannot be opened on another computer. A new key replaces the one from setup.")
                hintTone: "warning"

                SettingsAction {
                    text: I18n.tr("New key…")
                    glyph: "key"
                    enabled: !Backup.busy
                    onTriggered: Backup.newKey()
                }
            }
            ValueRow {
                width: parent.width
                visible: page.statusShown
                label: I18n.tr("Restore files")
                hint: page.restoreOpen ? ""
                    : "Files come back in a new folder in Restored; nothing in your home folder is replaced."

                SettingsAction {
                    text: page.restoreOpen ? I18n.tr("Close") : I18n.tr("Restore…")
                    glyph: page.restoreOpen ? "" : "history"
                    Accessible.name: page.restoreOpen ? I18n.tr("Close restore") : I18n.tr("Restore files from a backup")
                    onTriggered: page.toggleRestore()
                }
            }
            SelectRow {
                width: parent.width
                visible: page.statusShown && page.restoreOpen && Backup.snapshots.length > 0
                label: I18n.tr("Backup from")
                model: page.snapshotChoices()
                current: page.restoreId
                onPicked: value => page.restoreId = value
            }
            DraftFieldRow {
                width: parent.width
                visible: page.statusShown && page.restoreOpen && Backup.snapshots.length > 0
                label: I18n.tr("File or folder")
                mono: false
                value: page.restorePath
                placeholder: I18n.tr("Everything, or a path such as Documents/Taxes")
                invalid: !BackupHelpers.validRestorePath(page.restorePath)
                hint: invalid ? "Enter a plain path inside your home folder." : ""
                onEdited: text => page.restorePath = text
            }
            ValueRow {
                width: parent.width
                visible: page.statusShown && page.restoreOpen
                hint: Backup.action === "snapshots" ? "Reading the backups…"
                    : Backup.snapshotsError !== "" ? Backup.snapshotsError
                    : Backup.snapshotsLoaded && Backup.snapshots.length === 0 ? "There are no backups to restore yet."
                    : Backup.status.lastRestore && Backup.status.lastRestore.ok
                        ? "The last restore went to " + Backup.status.lastRestore.target + "."
                    : Backup.status.lastRestore ? Backup.status.lastRestore.error : ""
                hintTone: Backup.snapshotsError !== ""
                    || (Backup.status.lastRestore && !Backup.status.lastRestore.ok) ? "error" : "info"

                SettingsAction {
                    visible: Backup.snapshots.length > 0
                    text: I18n.tr("Restore")
                    glyph: "history"
                    primary: true
                    enabled: page.restoreId !== "" && BackupHelpers.validRestorePath(page.restorePath)
                        && !Backup.running && !Backup.starting
                    Accessible.name: I18n.tr("Restore into a new folder in Restored")
                    onTriggered: Backup.restore(page.restoreId, page.restorePath.trim())
                }
            }
        }

        RecoveryGroup {
            width: parent.width
        }
    }
}
