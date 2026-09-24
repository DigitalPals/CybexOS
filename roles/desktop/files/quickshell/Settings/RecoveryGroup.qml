pragma ComponentBehavior: Bound
import QtQuick
import "../Common"
import "../Common/RecoveryHelpers.js" as RecoveryHelpers

// Recovery points on the About page: taken before every update, bootable
// from GRUB, restorable here. The recovery-boot notification scrolls to it
// (settingKey "recoveryPoints").
SettingsGroup {
    id: recoveryGroup
    readonly property string settingKey: "recoveryPoints"
    property string confirmId: ""
    width: parent.width
    title: "Recovery points"
    rowSpacing: Theme.settingsContentSpacing

    SettingsHint {
        width: parent.width
        visible: Recovery.recoveryBoot
        tone: "warning"
        text: "You are running the recovery point from " + RecoveryHelpers.pointTime(Recovery.recoveryBootId)
            + ". Changes made now are temporary and disappear when you restart."
    }
    ResponsiveActionRow {
        width: parent.width
        visible: Recovery.recoveryBoot && !Recovery.restartPending
        description: recoveryGroup.confirmId === Recovery.recoveryBootId
            ? "Replaces the installed system at the next restart. Your home folder is not changed."
            : "Keep this recovery point as the installed system"
        SettingsAction {
            text: recoveryGroup.confirmId === Recovery.recoveryBootId
                ? "Confirm restore" : "Restore this recovery point"
            glyph: "history"
            danger: recoveryGroup.confirmId === Recovery.recoveryBootId
            enabled: !Recovery.busy
            onTriggered: {
                if (recoveryGroup.confirmId === Recovery.recoveryBootId)
                    Recovery.restore(Recovery.recoveryBootId);
                else
                    recoveryGroup.confirmId = Recovery.recoveryBootId;
            }
        }
        SettingsAction {
            visible: recoveryGroup.confirmId === Recovery.recoveryBootId
            text: "Cancel"
            glyph: "close"
            onTriggered: recoveryGroup.confirmId = ""
        }
    }
    SettingsHint {
        width: parent.width
        visible: Recovery.restartPending
        tone: "active"
        text: "A restored recovery point starts at the next restart."
    }
    SettingsHint {
        width: parent.width
        visible: Recovery.loaded && !Recovery.supported && !Recovery.recoveryBoot
        tone: "info"
        text: "Recovery points need the standard Btrfs layout"
            + (Recovery.unsupportedReason !== "" ? " (" + Recovery.unsupportedReason + ")." : ".")
    }
    SettingsHint {
        width: parent.width
        visible: Recovery.supported && Recovery.points.length === 0
        text: "None yet. One is taken automatically before each update."
    }

    Repeater {
        model: Recovery.points
        delegate: Item {
            id: pointRow
            required property var modelData
            readonly property bool confirming: recoveryGroup.confirmId === modelData.id
            readonly property bool running: modelData.id === Recovery.recoveryBootId
            width: recoveryGroup.width
            implicitHeight: pointColumn.implicitHeight
            height: implicitHeight

            Column {
                id: pointColumn
                width: parent.width
                spacing: Theme.settingsContentSpacing / 2

                Text {
                    width: parent.width
                    leftPadding: Theme.settingsMarkInset
                    text: RecoveryHelpers.pointTime(pointRow.modelData.id) + " · "
                        + RecoveryHelpers.pointLabel(pointRow.modelData)
                        + (pointRow.running ? " · running now" : "")
                    color: Theme.textHi
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.control
                    elide: Text.ElideRight
                }
                ResponsiveActionRow {
                    width: parent.width
                    description: pointRow.confirming
                        ? "Replaces the installed system at the next restart. Your home folder is not changed."
                        : RecoveryHelpers.pointStatus(pointRow.modelData)
                    SettingsAction {
                        visible: !pointRow.running && !Recovery.restartPending
                        text: pointRow.confirming ? "Confirm restore" : "Restore…"
                        glyph: "history"
                        danger: pointRow.confirming
                        enabled: !Recovery.busy
                        Accessible.name: "Restore recovery point from " + RecoveryHelpers.pointTime(pointRow.modelData.id)
                        onTriggered: {
                            if (pointRow.confirming)
                                Recovery.restore(pointRow.modelData.id);
                            else
                                recoveryGroup.confirmId = pointRow.modelData.id;
                        }
                    }
                    SettingsAction {
                        visible: pointRow.confirming
                        text: "Cancel"
                        glyph: "close"
                        onTriggered: recoveryGroup.confirmId = ""
                    }
                }
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
        text: "The five newest are kept; your home folder is never rolled back. To try one "
            + "without changing anything, restart and hold Shift (or press Esc) until the boot "
            + "menu appears, then open CybexOS recovery points."
    }
}
