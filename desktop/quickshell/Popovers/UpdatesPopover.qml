pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls as Controls
import "../Common"
import "../Common/UpdatesHelpers.js" as Helpers

Surface {
    id: root
    property var service: Updates
    property bool systemDetails: false

    implicitWidth: Theme.drawerWidth
    spacing: Theme.panelSectionSpacing

    function primary() {
        if (service.actions.apply) service.apply();
        else if (service.actions.confirm) service.confirm();
        else if (service.deployment.state === "awaiting-boot" && !service.runActive) Session.reboot();
        else if (service.deployment.state === "recovery-failed" && service.actions.rollback) service.rollback();
        else if (service.actions.prepare) service.prepare();
    }

    Component.onCompleted: service.opened()
    onVisibleChanged: { if (visible) service.opened(); }

    Row {
        id: header
        width: parent.width
        spacing: 12
        Text {
            width: parent.width - recheck.width - parent.spacing
            anchors.verticalCenter: parent.verticalCenter
            text: I18n.tr("System updates")
            color: Theme.textHi
            font.family: Theme.fontMenu
            font.pixelSize: Theme.typography.heading
            font.weight: Theme.weightSemibold
        }
        ActionButton {
            id: recheck
            objectName: "updateCheck"
            label: I18n.tr("Check")
            enabled: !root.service.busy && !root.service.runActive
            onTriggered: { root.service.refreshStatus(); root.service.check(); }
        }
    }

    Text {
        width: parent.width
        objectName: "updateSummary"
        text: root.service.summary
        color: Theme.textHi
        font.family: Theme.fontMenu
        font.pixelSize: Theme.typography.primary
        wrapMode: Text.Wrap
        textFormat: Text.PlainText
    }

    Flickable {
        id: reviewFlick
        width: parent.width
        height: Math.min(details.implicitHeight, root.availableHeight > 0
            ? Math.max(80, root.availableHeight - header.height - primaryAction.height
                - root.padding * 2 - Theme.scaled(160))
            : Theme.scaled(430))
        contentWidth: width
        contentHeight: details.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        Controls.ScrollBar.vertical: Controls.ScrollBar {}

        Column {
            id: details
            width: reviewFlick.width
            spacing: Theme.panelSectionSpacing

            Rectangle {
                width: parent.width
                height: visible ? errorText.implicitHeight + 20 : 0
                visible: root.service.error !== ""
                radius: Theme.chipRadius
                color: Theme.redBg
                Text {
                    id: errorText
                    objectName: "updateError"
                    x: 10; y: 10
                    width: parent.width - 20
                    text: root.service.error
                    color: Theme.redText
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.secondary
                    wrapMode: Text.Wrap
                    textFormat: Text.PlainText
                    Accessible.role: Accessible.AlertMessage
                    Accessible.name: text
                }
            }

            Column {
                width: parent.width
                spacing: 8
                visible: !root.service.ready && !root.service.runActive && !root.service.rebootRecommended
                Repeater {
                    model: ["upstream", "cybexos"]
                    delegate: Column {
                        id: sourceRow
                        required property string modelData
                        readonly property var source: root.service.sources[modelData]
                        readonly property string name: modelData === "upstream" ? I18n.tr("NixOS packages") : I18n.tr("Cybex OS")
                        width: details.width
                        spacing: 4
                        Row {
                            width: parent.width
                            spacing: 8
                            Controls.CheckBox {
                                objectName: sourceRow.modelData === "upstream" ? "updateSelectUpstream" : "updateSelectCybexOS"
                                visible: sourceRow.source.state === "available"
                                text: sourceRow.name
                                palette.text: Theme.textHi
                                checked: root.service.selectedSources.includes(sourceRow.modelData)
                                enabled: !root.service.runActive
                                Accessible.name: I18n.tr("Include") + " " + sourceRow.name
                                onToggled: root.service.selectSource(sourceRow.modelData, checked)
                            }
                            Text {
                                visible: sourceRow.source.state !== "available"
                                text: sourceRow.name
                                color: Theme.textHi
                                font.family: Theme.fontMenu
                                font.pixelSize: Theme.typography.primary
                            }
                        }
                        Text {
                            width: parent.width
                            text: sourceRow.source.state === "available"
                                ? sourceRow.modelData === "cybexos"
                                    ? (sourceRow.source.installed || "") + " → " + (sourceRow.source.available || "")
                                    : I18n.tr("Prepare the update to review the exact package changes.")
                                : sourceRow.source.state === "current" ? I18n.tr("Up to date")
                                : sourceRow.source.state === "unknown" ? I18n.tr("Not checked")
                                : I18n.tr("Could not check for updates")
                            color: Theme.textDim
                            font.family: Theme.fontMenu
                            font.pixelSize: Theme.typography.secondary
                            wrapMode: Text.Wrap
                            textFormat: Text.PlainText
                        }
                    }
                }
            }

            Text {
                width: parent.width
                visible: root.service.projectNotes !== ""
                text: root.service.projectNotes
                color: Theme.textMid
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.secondary
                wrapMode: Text.Wrap
                textFormat: Text.PlainText
            }

            Column {
                width: parent.width
                spacing: 10
                visible: root.service.ready
                Text {
                    width: parent.width
                    text: I18n.tr("Review before installing") + "\n" + root.service.scopeLabel
                    color: Theme.textHi
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.primary
                    wrapMode: Text.Wrap
                    textFormat: Text.PlainText
                }
                Text {
                    width: parent.width
                    visible: (root.service.deployment.packageChanges || []).length === 0
                    text: I18n.tr("No directly installed package changed. Review the system and dependency changes below.")
                    color: Theme.textDim
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.secondary
                    wrapMode: Text.Wrap
                }
                Repeater {
                    model: root.service.ready ? root.service.deployment.packageChanges || [] : []
                    delegate: Rectangle {
                        id: packageRow
                        required property var modelData
                        objectName: "updatePackageChange"
                        width: details.width
                        height: packageCopy.implicitHeight + 20
                        radius: Theme.chipRadius
                        color: Theme.cardFill
                        Column {
                            id: packageCopy
                            x: 10; y: 10
                            width: parent.width - 20
                            spacing: 4
                            Text {
                                width: parent.width
                                text: packageRow.modelData.name
                                color: Theme.textHi
                                font.family: Theme.fontMenu
                                font.pixelSize: Theme.typography.primary
                                font.weight: Theme.weightMedium
                                wrapMode: Text.Wrap
                                textFormat: Text.PlainText
                            }
                            Text {
                                width: parent.width
                                text: Helpers.packageChange(packageRow.modelData)
                                color: Theme.textMid
                                font.family: Theme.fontMenu
                                font.pixelSize: Theme.typography.secondary
                                wrapMode: Text.Wrap
                                textFormat: Text.PlainText
                            }
                        }
                    }
                }
                Text {
                    width: parent.width
                    visible: root.systemDetails
                    text: root.service.deployment.changes || I18n.tr("No package closure changes")
                    color: Theme.textMid
                    font.family: Theme.fontMono
                    font.pixelSize: Theme.typography.metadata
                    wrapMode: Text.WrapAnywhere
                    textFormat: Text.PlainText
                }
            }

            Text {
                width: parent.width
                visible: root.service.deployment.recovery !== undefined
                    && root.service.deployment.recovery !== "" && root.service.deployment.state !== "done"
                text: root.service.deployment.recovery || ""
                color: Theme.textDim
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.secondary
                wrapMode: Text.Wrap
                textFormat: Text.PlainText
            }

            ActionButton {
                objectName: "updateDiscard"
                visible: root.service.actions.discard
                label: I18n.tr("Discard preview")
                onTriggered: root.service.discard()
            }
            ActionButton {
                label: root.systemDetails ? I18n.tr("Hide system details") : I18n.tr("Show system details")
                onTriggered: root.systemDetails = !root.systemDetails
            }
            Flow {
                visible: root.systemDetails
                width: parent.width
                spacing: 8
                ActionButton {
                    visible: !!root.service.deployment.transaction
                    label: I18n.tr("Build log")
                    onTriggered: root.service.openLog()
                }
                ActionButton {
                    visible: root.service.actions.rollback && root.service.deployment.state !== "recovery-failed"
                    label: I18n.tr("Restore previous generation")
                    onTriggered: root.service.rollback()
                }
                ActionButton {
                    label: I18n.tr("Recovery history")
                    onTriggered: root.service.openRecoveryPoints()
                }
            }
        }
    }

    Controls.BusyIndicator {
        anchors.horizontalCenter: parent.horizontalCenter
        visible: root.service.runActive
        running: visible
        height: visible ? Theme.scaled(30) : 0
        width: Theme.scaled(30)
    }

    ActionButton {
        id: primaryAction
        objectName: "updatePrimary"
        width: parent.width
        height: Theme.scaled(42)
        visible: root.service.hasUpdates || root.service.ready || root.service.runActive
            || root.service.rebootRecommended || root.service.deployment.state === "recovery-failed"
        enabled: root.service.actions.apply || root.service.actions.prepare || root.service.actions.confirm
            || (root.service.deployment.state === "awaiting-boot" && !root.service.runActive)
            || (root.service.deployment.state === "recovery-failed" && root.service.actions.rollback)
        label: root.service.runActive ? I18n.tr("Working…")
            : root.service.ready ? (root.service.deployment.changeKind === "update" ? I18n.tr("Update") : I18n.tr("Apply change"))
            : root.service.deployment.state === "awaiting-login" ? I18n.tr("Confirm this boot")
            : root.service.deployment.state === "awaiting-boot" ? I18n.tr("Restart to finish")
            : root.service.deployment.state === "recovery-failed" ? I18n.tr("Restore previous generation")
            : I18n.tr("Prepare update")
        fill: Theme.accent
        tint: Theme.accentFg
        onTriggered: root.primary()
    }

    Text {
        width: parent.width
        text: root.service.checkedLabel + " · " + I18n.tr("Flatpak apps have separate updates.")
        color: Theme.textFaint
        font.family: Theme.fontMenu
        font.pixelSize: Theme.typography.metadata
        wrapMode: Text.Wrap
    }
}
