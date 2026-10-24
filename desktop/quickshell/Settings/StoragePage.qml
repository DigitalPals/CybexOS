pragma ComponentBehavior: Bound
import QtQuick
import "../Common"

SettingsPage {
    id: page
    property var draft: ({automatic:true, keepConfirmed:5, keepDays:30})
    readonly property var status: Maintenance.snapshot
    readonly property var configuredPolicy: status.desiredPolicy || status.policy
    property var policyBaseline: ({automatic:true, keepConfirmed:5, keepDays:30})
    function same(a, b) { return a.automatic === b.automatic && a.keepConfirmed === b.keepConfirmed && a.keepDays === b.keepDays; }
    readonly property bool dirty: !same(draft, policyBaseline)
    readonly property bool conflict: dirty && !same(policyBaseline, configuredPolicy)
    function discard() { policyBaseline = Object.assign({}, configuredPolicy); draft = Object.assign({}, policyBaseline); }
    function edit(values) { draft = Object.assign({}, draft, values); }
    Binding { target: Maintenance; property: "watched"; value: page.visible && Settings.panelOpen }
    Connections {
        target: Maintenance
        function onSnapshotChanged() { if (!page.dirty || page.same(page.draft, page.configuredPolicy)) page.discard(); }
    }
    Component.onCompleted: { discard(); Maintenance.refresh(); }
    Column {
        width: parent.width; spacing: Theme.settingsGroupSpacing
        SettingsGroup {
            width: parent.width; title: I18n.tr("Storage")
            ValueRow { width: parent.width; label: I18n.tr("Available space"); value: Maintenance.bytes(page.status.space.available) + " / " + Maintenance.bytes(page.status.space.total); valueColor: page.status.space.low ? Theme.amber : Theme.textMid }
            SettingsHint { width: parent.width; visible: page.status.space.low === true; text: I18n.tr("Storage is running low. Review cleanup before building another deployment."); tone: "warning" }
            SettingsHint { width: parent.width; text: I18n.tr("Cleanup removes obsolete system references and unreachable Nix store contents. Documents, downloads, application data and saved personal configuration stay yours.") }
            ValueRow {
                width: parent.width; label: I18n.tr("System cleanup")
                value: Maintenance.busy ? I18n.tr("Working…") : page.status.state || ""
                SettingsAction { text: I18n.tr("Review cleanup…"); enabled: !Maintenance.busy; onTriggered: Maintenance.preview() }
                SettingsAction { text: I18n.tr("Resume cleanup"); visible: page.status.recoveryPending === true; enabled: !Maintenance.busy; onTriggered: Maintenance.request(["resume"]) }
            }
            SettingsHint { width: parent.width; visible: Maintenance.error !== ""; text: Maintenance.error; tone: "error" }
            ValueRow {
                width: parent.width; visible: Maintenance.ready; label: I18n.tr("Recovery points to retire")
                value: String((page.status.candidates || []).length)
                hint: I18n.tr("Estimated system contents: ") + Maintenance.bytes(page.status.estimatedBytes) + I18n.tr(". Shared paths stay while another profile or recovery point needs them.")
                SettingsAction { text: I18n.tr("Clean reviewed items"); enabled: Maintenance.ready; danger: true; onTriggered: Maintenance.clean() }
            }
            ValueRow { width: parent.width; visible: page.status.reclaimedBytes !== undefined; label: I18n.tr("Last cleanup removed"); value: Maintenance.bytes(page.status.reclaimedBytes); hint: I18n.tr("Uncompressed store contents; filesystem space can differ.") }
        }
        SettingsGroup {
            width: parent.width; title: I18n.tr("Retention")
            SwitchRow {
                width: parent.width; label: I18n.tr("Automatic weekly cleanup"); property string searchAnchor: "storage-automatic"
                checked: page.draft.automatic
                description: I18n.tr("Runs after a confirmed boot and skips active updates or unresolved recovery. Changes are staged for review.")
                onToggled: value => page.edit({automatic:value})
            }
            SelectRow {
                width: parent.width; label: I18n.tr("Confirmed deployments to keep")
                model: [5, 10, 20, 50, 100].map(v => ({value:v, label:String(v)})); current: page.draft.keepConfirmed
                onPicked: value => page.edit({keepConfirmed:value})
            }
            SelectRow {
                width: parent.width; label: I18n.tr("Days of recovery history")
                model: [30, 60, 90, 180, 365].map(v => ({value:v, label:String(v)})); current: page.draft.keepDays
                onPicked: value => page.edit({keepDays:value})
            }
            ValueRow {
                width: parent.width; label: I18n.tr("Cleanup preferences")
                SettingsAction { text: I18n.tr("Discard"); enabled: page.dirty; onTriggered: page.discard() }
                SettingsAction { text: I18n.tr("Preview changes"); enabled: (page.dirty || page.status.configurationChanged === true) && !page.status.configurationError && !page.conflict && !Maintenance.busy && !Updates.runActive && !Updates.rebootRecommended; onTriggered: Maintenance.changePolicy(page.draft, page.policyBaseline) }
            }
        }
        SettingsHint { width: parent.width; visible: page.conflict; tone: "warning"; text: I18n.tr("Cleanup preferences changed elsewhere. Discard your draft and review the current preferences.") }
        SettingsHint { width: parent.width; visible: !!page.status.configurationError; tone: "error"; text: page.status.configurationError || "" }
        DeploymentReview { width: parent.width; kind: "maintenance" }
        SettingsGroup {
            width: parent.width; title: I18n.tr("Recovery points")
            SettingsHint { width: parent.width; text: I18n.tr("The running system, its fallback and pending recovery are always protected. Pin another confirmed recovery point to keep it indefinitely.") }
            Repeater {
                model: page.status.deployments || []
                delegate: ValueRow {
                    id: recoveryRow
                    required property var modelData
                    width: parent.width; label: modelData.id.slice(0, 10)
                    value: modelData.retired ? I18n.tr("Retired") : modelData.eligible ? I18n.tr("Eligible for cleanup") : I18n.tr("Protected")
                    hint: (modelData.reasons || []).join(" · ")
                    SettingsAction {
                        visible: recoveryRow.modelData.confirmed && !recoveryRow.modelData.retired
                        text: recoveryRow.modelData.pinned ? I18n.tr("Unpin") : I18n.tr("Pin")
                        enabled: !Maintenance.busy
                        onTriggered: Maintenance.pin(recoveryRow.modelData.id, !recoveryRow.modelData.pinned)
                    }
                }
            }
        }
    }
}
