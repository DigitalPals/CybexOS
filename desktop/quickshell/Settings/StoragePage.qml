pragma ComponentBehavior: Bound
import QtQuick
import "../Common"

// Two tabs of Backup & storage (2026-10 redesign). "storage" is Disk space:
// free space and the reviewed system cleanup. "recovery" is Recovery points:
// how long they are kept, which exist, and the boot menu's generations.
// They used to sit on the Storage page and again under Backup; each now has
// one home. The retention draft lives in RetentionDraft, so it survives a
// tab switch and joins the header's Changes review.
SettingsPage {
    id: page
    property string section: "storage"
    readonly property var status: Maintenance.snapshot
    readonly property var draft: RetentionDraft.draft
    readonly property bool dirty: RetentionDraft.dirty
    Binding { target: Maintenance; property: "watched"; value: page.visible && Settings.panelOpen }
    Component.onCompleted: Maintenance.refresh()

    Column {
        width: parent.width; spacing: Theme.settingsGroupSpacing
        SettingsGroup {
            width: parent.width; title: I18n.tr("Disk space")
            visible: page.section === "storage"
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
            width: parent.width; title: I18n.tr("Recovery points")
            visible: page.section === "recovery"
            property string searchAnchor: "recoveryPoints"
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
        SettingsGroup {
            width: parent.width; title: I18n.tr("Retention")
            visible: page.section === "recovery"
            changeTag: "restart"
            SwitchRow {
                width: parent.width; label: I18n.tr("Automatic weekly cleanup"); property string searchAnchor: "storage-automatic"
                checked: page.draft.automatic
                description: I18n.tr("Runs after a confirmed boot and skips active updates or unresolved recovery.")
                onToggled: value => RetentionDraft.edit({automatic:value})
            }
            SelectRow {
                width: parent.width; label: I18n.tr("Confirmed deployments to keep")
                model: [5, 10, 20, 50, 100].map(v => ({value:v, label:String(v)})); current: page.draft.keepConfirmed
                onPicked: value => RetentionDraft.edit({keepConfirmed:value})
            }
            SelectRow {
                width: parent.width; label: I18n.tr("Days of recovery history")
                model: [30, 60, 90, 180, 365].map(v => ({value:v, label:String(v)})); current: page.draft.keepDays
                onPicked: value => RetentionDraft.edit({keepDays:value})
            }
            ValueRow {
                width: parent.width; label: I18n.tr("Cleanup preferences")
                hint: RetentionDraft.dirty && SettingsChanges.systemBusy && !Maintenance.busy
                    ? I18n.tr("Prepare these after the current system change is finished.") : ""
                SettingsAction { text: I18n.tr("Discard"); enabled: RetentionDraft.dirty; onTriggered: RetentionDraft.discard() }
                SettingsAction { text: I18n.tr("Prepare change"); primary: true; enabled: RetentionDraft.canPrepare; onTriggered: RetentionDraft.prepare() }
            }
        }
        SettingsHint { width: parent.width; visible: page.section === "recovery" && RetentionDraft.conflict; tone: "warning"; text: I18n.tr("Cleanup preferences changed elsewhere. Discard your draft and review the current preferences.") }
        SettingsHint { width: parent.width; visible: page.section === "recovery" && !!page.status.configurationError; tone: "error"; text: page.status.configurationError || "" }
        DeploymentReview { width: parent.width; kind: "maintenance"; visible: page.section === "recovery" && Updates.deployment.changeKind === "maintenance" }
        RecoveryGroup { visible: page.section === "recovery" }
    }
}
