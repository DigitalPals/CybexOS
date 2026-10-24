pragma ComponentBehavior: Bound
import QtQuick
import "../Common"

SettingsPage {
    id: page
    Component.onCompleted: DefaultApplications.refresh()
    Column {
        width: parent.width
        spacing: Theme.settingsGroupSpacing
        SettingsGroup {
            width: parent.width
            title: I18n.tr("Default applications")
            SettingsHint { width: parent.width; text: I18n.tr("Applies immediately to your account. Your own shortcuts and explicit editor overrides keep their choices.") }
            Repeater {
                model: [{id:"browser", label:"Web browser"}, {id:"terminal", label:"Terminal"},
                    {id:"editor", label:"Text editor"}, {id:"pdf", label:"PDF viewer"},
                    {id:"image", label:"Image viewer"}, {id:"video", label:"Video player"}]
                delegate: SelectRow {
                    required property var modelData
                    readonly property var role: DefaultApplications.roles[modelData.id] || ({})
                    width: parent.width
                    label: I18n.tr(modelData.label)
                    property string searchAnchor: "applications-" + modelData.id
                    model: role.choices || []
                    current: role.selected || ""
                    enabled: !DefaultApplications.busy && model.length > 0
                    hint: role.unavailable ? I18n.tr("Your saved application is unavailable. An available fallback is used until you choose another.") : ""
                    onPicked: value => DefaultApplications.select(modelData.id, value)
                }
            }
            SettingsHint { width: parent.width; visible: DefaultApplications.error !== ""; text: DefaultApplications.error; tone: "error" }
            ValueRow {
                width: parent.width; label: I18n.tr("Available applications")
                SettingsAction { text: I18n.tr("Refresh"); enabled: !DefaultApplications.busy; onTriggered: DefaultApplications.refresh() }
            }
        }
        SettingsGroup {
            width: parent.width; title: I18n.tr("Software")
            ValueRow {
                width: parent.width; label: I18n.tr("Install and remove applications")
                SettingsAction { text: I18n.tr("Open Software…"); glyph: "apps"; onTriggered: Software.show() }
            }
        }
        DeploymentReview { width: parent.width; kind: "software" }
    }
}
