pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import "../Common"
import "../Common/Format.js" as Format
import "../Common/SecurityHelpers.js" as SecurityHelpers

// Security: fingerprints and security keys as alternatives to the password
// for sudo and system prompts (docs/hardware-security.md). Signing in
// after a restart always asks for the password, which unlocks the keyring.
//
// Nothing here is privileged by itself. fprintd asks for authorization (the
// shell's Polkit dialog) before it adds or removes a fingerprint, and the
// authentication policy is declared in personal NixOS modules and reviewed
// through the staged update lifecycle.
// A key registration is a public key in ~/.config/Yubico/u2f_keys.
//
// Every request runs off the UI thread: the shared settings backend for
// reads and changes, and one streaming process for an enrolment's progress.
SettingsPage {
    id: page
    readonly property SystemSettingsBackend service: SystemSettings.security
    readonly property var snapshot: service.snapshot
    readonly property var reader: snapshot.reader || ({ state: "" })
    readonly property bool readerReady: reader.state === "ready"
    readonly property var fingers: snapshot.fingers || []
    readonly property var freeFingers: snapshot.freeFingers || []
    readonly property var keys: snapshot.keys || ({ state: "", entries: [], error: "" })
    readonly property var keyEntries: keys.entries || []
    readonly property bool keysReady: keys.state === "ready"
    readonly property bool addingKey: service.busy && service.request.action === "add-key"
    // A failed key request reports under Security keys, anything else under
    // Fingerprint, so a message appears beside the thing it is about.
    property string lastAction: ""
    readonly property bool keyError: service.error !== ""
        && (lastAction === "add-key" || lastAction === "remove-key")
    property string removingFinger: ""
    property string removingKey: ""

    // The add-fingerprint flow: "" (closed), "choose", "scanning",
    // "completed" or "failed". The enrolment process owns the reader's claim
    // while it runs and releases it however it ends.
    property string enrolState: ""
    property string enrolFinger: ""
    property string enrolScanType: "press"
    property int enrolStage: 0
    property int enrolStages: 0
    property string enrolMessage: ""

    Claim {
        active: page.visible && Settings.panelOpen
        onClaimed: page.service.acquire()
        onReleased: {
            page.removingFinger = "";
            page.removingKey = "";
            page.closeEnrolment();
            page.service.release();
        }
    }

    function act(request) {
        if (service.run(request))
            lastAction = request.action;
    }

    function chooseFinger() {
        removingFinger = "";
        enrolFinger = freeFingers.length > 0 ? freeFingers[0] : "";
        enrolStage = 0;
        enrolStages = 0;
        enrolMessage = "";
        enrolState = enrolFinger !== "" ? "choose" : "";
    }

    function startEnrolment() {
        if (enroller.running || SecurityHelpers.FINGER_ORDER.indexOf(enrolFinger) === -1)
            return;
        enrolStage = 0;
        enrolStages = reader.stages || 0;
        enrolScanType = reader.scanType === "swipe" ? "swipe" : "press";
        enrolMessage = "Approve the system prompt if one appears.";
        enrolState = "scanning";
        enroller.command = ["python3", "-B", Quickshell.shellDir + "/scripts/system_settings_security.py",
            "enroll", enrolFinger];
        enroller.running = true;
    }

    // Cancelling asks the helper to stop; it releases the reader and exits.
    function closeEnrolment() {
        if (enroller.running)
            enroller.signal(15);
        enrolState = "";
        enrolMessage = "";
    }

    function handleEnrolEvent(line) {
        const event = SecurityHelpers.parseEnrolEvent(line);
        if (!event || enrolState !== "scanning")
            return;
        if (event.event === "started") {
            enrolStages = event.stages;
            enrolScanType = event.scanType;
            enrolMessage = SecurityHelpers.enrolInstruction(event.scanType);
        } else if (event.event === "progress") {
            enrolStage = event.stage;
            enrolStages = event.stages || enrolStages;
            enrolMessage = SecurityHelpers.enrolStatus(event.result, enrolScanType);
        } else if (event.event === "completed") {
            enrolStage = enrolStages;
            enrolMessage = "Fingerprint added.";
            enrolState = "completed";
            service.refresh();
        } else if (event.event === "failed") {
            enrolMessage = SecurityHelpers.enrolFailure(event.result, event.message);
            enrolState = "failed";
        }
    }

    Process {
        id: enroller
        stdout: SplitParser { onRead: data => page.handleEnrolEvent(data) }
        stderr: StdioCollector {}
        onExited: {
            // A helper that ended without saying why is a failure, not a hang.
            if (page.enrolState === "scanning") {
                page.enrolMessage = SecurityHelpers.enrolFailure("", "");
                page.enrolState = "failed";
            }
            page.service.refresh();
        }
    }

    Column {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Theme.settingsGroupSpacing

        SettingsGroup {
            width: parent.width
            title: I18n.tr("Fingerprint")

            Item {
                width: parent.width
                height: fingerNote.height + Theme.settingsContentSpacing

                SettingsHint {
                    id: fingerNote
                    width: parent.width
                    maximumLines: 4
                    text: I18n.tr("Use a fingerprint for the lock screen, sudo and system prompts. After a restart, signing in still asks for your password.")
                }
            }
            SettingsHint {
                width: parent.width
                text: page.service.error !== "" && !page.keyError ? ""
                    : !page.service.loaded ? "Looking for a fingerprint reader…"
                    : SecurityHelpers.readerLine(page.reader.state)
            }
            ValueRow {
                width: parent.width
                visible: page.service.error !== "" && !page.keyError
                label: I18n.tr("Status")
                hint: page.service.error
                hintTone: "error"

                SettingsAction {
                    text: I18n.tr("Refresh")
                    glyph: "refresh"
                    enabled: !page.service.busy && !page.service.loading
                    onTriggered: {
                        page.lastAction = "";
                        page.service.error = "";
                        page.service.refresh();
                    }
                }
            }

            ValueRow {
                width: parent.width
                visible: page.readerReady
                label: I18n.tr("Reader")
                value: page.reader.name || "Fingerprint reader"
            }

            Repeater {
                model: ScriptModel { values: page.readerReady ? page.fingers : [] }

                delegate: RowCluster {
                    id: finger
                    required property string modelData
                    readonly property string label: SecurityHelpers.fingerLabel(modelData)
                    readonly property bool confirming: page.removingFinger === modelData
                    width: parent.width

                    ValueRow {
                        width: parent.width
                        label: finger.label

                        SettingsAction {
                            visible: !finger.confirming
                            text: I18n.tr("Remove…")
                            glyph: "delete"
                            danger: true
                            enabled: !page.service.busy && page.enrolState !== "scanning"
                            Accessible.name: "Remove the " + finger.label.toLowerCase() + " fingerprint"
                            onTriggered: page.removingFinger = finger.modelData
                        }
                    }
                    ValueRow {
                        width: parent.width
                        divider: false
                        visible: finger.confirming
                        label: I18n.tr("Remove this fingerprint?")
                        hint: I18n.tr("It no longer unlocks the screen or approves prompts.")
                        hintTone: "warning"

                        SettingsAction {
                            text: I18n.tr("Remove fingerprint")
                            danger: true
                            enabled: !page.service.busy
                            onTriggered: {
                                page.act({ action: "delete-finger", finger: finger.modelData,
                                    confirmed: true });
                                page.removingFinger = "";
                            }
                        }
                        SettingsAction {
                            text: I18n.tr("Cancel")
                            onTriggered: page.removingFinger = ""
                        }
                    }
                }
            }

            ValueRow {
                width: parent.width
                visible: page.readerReady && page.enrolState === ""
                label: page.fingers.length === 0 ? I18n.tr("No fingerprints added") : I18n.tr("Add another fingerprint")
                hint: page.freeFingers.length === 0 ? "Every finger is already enrolled." : ""

                SettingsAction {
                    text: I18n.tr("Add fingerprint")
                    glyph: "add"
                    primary: page.fingers.length === 0
                    enabled: page.freeFingers.length > 0 && !page.service.busy
                    onTriggered: page.chooseFinger()
                }
            }

            // The guided enrolment: choose the finger, then scan it until
            // the reader has enough. Its progress comes from fprintd's
            // EnrollStatus signal through the streaming helper.
            SelectRow {
                width: parent.width
                visible: page.readerReady && page.enrolState !== ""
                label: I18n.tr("Finger")
                model: SecurityHelpers.fingerOptions(page.enrolState === "choose"
                    ? page.freeFingers : [page.enrolFinger])
                current: page.enrolFinger
                disabledReason: page.enrolState === "choose" ? "" : "Scanning"
                onPicked: value => page.enrolFinger = value
            }
            ValueRow {
                width: parent.width
                divider: false
                visible: page.readerReady && page.enrolState !== ""
                label: page.enrolState === "choose" ? "Scan it several times"
                    : page.enrolState === "completed" ? "Fingerprint added"
                    : page.enrolState === "failed" ? "Not added"
                    : "Scanning"
                value: page.enrolState === "scanning"
                    ? SecurityHelpers.stageLabel(page.enrolStage, page.enrolStages) : ""
                hint: page.enrolState === "choose"
                    ? SecurityHelpers.enrolInstruction(page.reader.scanType) : page.enrolMessage
                hintTone: page.enrolState === "failed" ? "error"
                    : page.enrolState === "scanning" ? "active" : "info"
                Accessible.role: Accessible.ProgressBar

                SettingsAction {
                    visible: page.enrolState === "choose"
                    text: I18n.tr("Start")
                    primary: true
                    enabled: page.enrolFinger !== "" && !enroller.running
                    onTriggered: page.startEnrolment()
                }
                SettingsAction {
                    visible: page.enrolState === "failed"
                    text: I18n.tr("Try again")
                    enabled: !enroller.running
                    onTriggered: page.chooseFinger()
                }
                SettingsAction {
                    text: page.enrolState === "completed" || page.enrolState === "failed" ? "Done" : "Cancel"
                    onTriggered: page.closeEnrolment()
                }
            }
            Item {
                width: parent.width
                height: 6
                visible: page.readerReady && page.enrolState === "scanning" && page.enrolStages > 0

                Rectangle {
                    x: Theme.settingsMarkInset
                    width: Math.max(0, parent.width - x)
                    height: 3
                    radius: 1.5
                    color: Theme.hairlineSoft

                    Rectangle {
                        width: parent.width * Format.clamp01(page.enrolStages > 0
                            ? page.enrolStage / page.enrolStages : 0)
                        height: parent.height
                        radius: parent.radius
                        color: Theme.accent

                        Behavior on width {
                            NumberAnimation {
                                duration: Theme.chipFadeDuration
                                easing.type: Easing.OutCubic
                            }
                        }
                    }
                }
            }

            ValueRow {
                width: parent.width
                visible: page.readerReady && page.fingers.length > 0
                label: I18n.tr("Use fingerprint to unlock and authorise")
                value: page.snapshot.fingerprintAuth === true ? I18n.tr("Enabled") : I18n.tr("Disabled")
                hint: I18n.tr("Managed in /etc/nixos/local")
            }
            SettingsHint {
                width: parent.width
                visible: page.readerReady && page.fingers.length > 0
                maximumLines: 6
                text: I18n.tr("Set cybexos.authentication.fingerprint in a personal NixOS module, then preview with cybex update stage local and apply the reviewed change. Enrol and remove fingerprints here.")
            }
        }

        SettingsGroup {
            width: parent.width
            title: I18n.tr("Security keys")

            Item {
                width: parent.width
                height: keyNote.height + Theme.settingsContentSpacing

                SettingsHint {
                    id: keyNote
                    width: parent.width
                    maximumLines: 4
                    text: I18n.tr("Touch a registered FIDO2 or U2F key for the lock screen, sudo and system prompts. Your password keeps working.")
                }
            }
            SettingsHint {
                width: parent.width
                text: page.keyError ? page.service.error
                    : !page.service.loaded || page.service.error !== "" ? ""
                    : page.keys.error || SecurityHelpers.keyLine(page.keys.state)
                tone: page.keyError || page.keys.error ? "error" : "info"
            }

            Repeater {
                model: ScriptModel { values: page.keysReady ? page.keyEntries.map(entry => entry.id) : [] }

                delegate: RowCluster {
                    id: key
                    required property string modelData
                    readonly property var info: page.keyEntries.find(entry => entry.id === modelData)
                        || ({ id: "", label: "" })
                    readonly property bool confirming: page.removingKey === info.id
                    width: parent.width

                    ValueRow {
                        width: parent.width
                        label: key.info.label

                        SettingsAction {
                            visible: !key.confirming
                            text: I18n.tr("Remove…")
                            glyph: "delete"
                            danger: true
                            enabled: !page.service.busy
                            Accessible.name: "Remove " + key.info.label
                            onTriggered: page.removingKey = key.info.id
                        }
                    }
                    ValueRow {
                        width: parent.width
                        divider: false
                        visible: key.confirming
                        label: I18n.tr("Remove this key?")
                        hint: I18n.tr("It no longer unlocks the screen or approves prompts on this computer.")
                        hintTone: "warning"

                        SettingsAction {
                            text: I18n.tr("Remove key")
                            danger: true
                            enabled: !page.service.busy
                            onTriggered: {
                                page.act({ action: "remove-key", id: key.info.id, confirmed: true });
                                page.removingKey = "";
                            }
                        }
                        SettingsAction {
                            text: I18n.tr("Cancel")
                            onTriggered: page.removingKey = ""
                        }
                    }
                }
            }

            ValueRow {
                width: parent.width
                visible: page.keysReady
                label: page.addingKey ? "Touch your security key now"
                    : page.keyEntries.length === 0 ? "No security keys added" : "Add another security key"
                hint: page.addingKey ? "Insert the key if it is not plugged in, then touch it when it flashes." : ""
                hintTone: page.addingKey ? "active" : "info"

                SettingsAction {
                    text: page.addingKey ? I18n.tr("Waiting…") : I18n.tr("Add security key")
                    glyph: page.addingKey ? "" : "add"
                    primary: page.keyEntries.length === 0
                    enabled: !page.service.busy
                    onTriggered: page.act({ action: "add-key" })
                }
            }
        }
    }
}
