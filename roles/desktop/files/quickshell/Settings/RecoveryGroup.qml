pragma ComponentBehavior: Bound
import QtQuick
import "../Common"
import "../Common/RecoveryHelpers.js" as RecoveryHelpers
import "LocalTime.js" as LocalTime

// Recovery points on the Backup & recovery page: taken before every update, bootable
// from GRUB, restorable here. The recovery-boot notification scrolls to it
// (searchAnchor "recoveryPoints").
//
// Each point is a row named by when it was taken, in local time; the boot
// menu lists points in UTC, so a bootable point also gives that stamp.
// Restore always takes a second press: the row turns into its own warning
// with Confirm restore and Cancel.
SettingsGroup {
    id: recoveryGroup
    readonly property string searchAnchor: "recoveryPoints"
    property string confirmId: ""
    // The page's clock, so "Today" turns into "Yesterday" at midnight.
    property real nowMs: Date.now()
    readonly property string restoreWarning:
        "Replaces the installed system at the next restart. Your home folder is not changed."
    width: parent.width
    title: I18n.tr("Recovery points")

    function whenTaken(id) {
        return LocalTime.fromText(String(id).slice(0, 16), recoveryGroup.nowMs,
            Settings.clock24, RecoveryHelpers.pointTime(id));
    }

    SettingsHint {
        width: parent.width
        visible: Recovery.recoveryBoot
        tone: "warning"
        text: "You are running the recovery point from " + RecoveryHelpers.pointTime(Recovery.recoveryBootId)
            + ". Changes made now are temporary and disappear when you restart."
    }
    ValueRow {
        id: keepRow
        readonly property bool confirming: recoveryGroup.confirmId === Recovery.recoveryBootId
        width: parent.width
        visible: Recovery.recoveryBoot && !Recovery.restartPending
        label: I18n.tr("Keep this system")
        hint: confirming ? recoveryGroup.restoreWarning
            : "Restores this recovery point as the installed system"
        hintTone: confirming ? "warning" : "info"

        SettingsAction {
            text: keepRow.confirming ? I18n.tr("Confirm restore") : I18n.tr("Restore…")
            glyph: "history"
            danger: keepRow.confirming
            enabled: !Recovery.busy
            Accessible.name: keepRow.confirming ? "Confirm restore of the running recovery point"
                : "Restore the running recovery point"
            onTriggered: {
                if (keepRow.confirming)
                    Recovery.restore(Recovery.recoveryBootId);
                else
                    recoveryGroup.confirmId = Recovery.recoveryBootId;
            }
        }
        SettingsAction {
            visible: keepRow.confirming
            text: I18n.tr("Cancel")
            onTriggered: recoveryGroup.confirmId = ""
        }
    }
    SettingsHint {
        width: parent.width
        visible: Recovery.restartPending
        tone: "active"
        text: I18n.tr("A restored recovery point starts at the next restart.")
    }
    ValueRow {
        width: parent.width
        visible: Recovery.loaded && !Recovery.supported && !Recovery.recoveryBoot
        label: I18n.tr("Recovery points")
        value: "Unavailable"
        hint: Recovery.unsupportedReason !== ""
            ? I18n.format("They need the standard Btrfs layout (%1).", [Recovery.unsupportedReason])
            : I18n.tr("They need the standard Btrfs layout.")
    }
    ValueRow {
        width: parent.width
        visible: Recovery.supported && Recovery.points.length === 0
        label: I18n.tr("Recovery points")
        value: "None yet"
        hint: I18n.tr("One is taken automatically before each update.")
    }

    Repeater {
        model: Recovery.points

        delegate: ValueRow {
            id: pointRow
            required property var modelData
            readonly property bool confirming: recoveryGroup.confirmId === modelData.id
            readonly property bool running: modelData.id === Recovery.recoveryBootId
            width: recoveryGroup.width
            label: recoveryGroup.whenTaken(modelData.id)
            hint: confirming ? recoveryGroup.restoreWarning
                : [RecoveryHelpers.pointLabel(modelData), RecoveryHelpers.pointStatus(modelData),
                    modelData.bootable ? RecoveryHelpers.pointTime(modelData.id) : "",
                    running ? "running now" : ""].filter(part => part !== "").join(" · ")
            hintTone: confirming ? "warning" : "info"

            SettingsAction {
                visible: !pointRow.running && !Recovery.restartPending
                text: pointRow.confirming ? I18n.tr("Confirm restore") : I18n.tr("Restore…")
                glyph: "history"
                danger: pointRow.confirming
                enabled: !Recovery.busy
                Accessible.name: (pointRow.confirming ? "Confirm restore of" : "Restore")
                    + " recovery point from " + RecoveryHelpers.pointTime(pointRow.modelData.id)
                onTriggered: {
                    if (pointRow.confirming)
                        Recovery.restore(pointRow.modelData.id);
                    else
                        recoveryGroup.confirmId = pointRow.modelData.id;
                }
            }
            SettingsAction {
                visible: pointRow.confirming
                text: I18n.tr("Cancel")
                onTriggered: recoveryGroup.confirmId = ""
            }
        }
    }

    SettingsHint {
        width: parent.width
        visible: Recovery.busy || Recovery.error !== "" || Recovery.result !== ""
        tone: Recovery.error !== "" ? "error" : "active"
        text: Recovery.busy ? "Restoring…" : Recovery.error !== "" ? Recovery.error : Recovery.result
    }
    SettingsHint {
        width: parent.width
        visible: Recovery.supported
        maximumLines: 4
        text: I18n.tr("The five newest are kept; your home folder is never rolled back. To try one without changing anything, restart and hold Shift (or press Esc) until the boot menu appears, then open CybexOS recovery points.")
    }
    FactoryResetRow {
        width: parent.width
    }
}
