pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls as Controls
import Quickshell
import Quickshell.Hyprland
import "Common"
import "Settings" as SettingsUi

FloatingWindow {
    id: window
    title: "Cybex OS Software" // i18n: untranslated (compositor identity)
    visible: Software.open
    color: Theme.panelSurface
    implicitWidth: 960
    implicitHeight: 720
    minimumSize: Qt.size(560, 420)
    onClosed: Software.close()
    onVisibleChanged: { if (visible) { screen = Screens.focused; minimized = false; } }
    Connections {
        target: Software
        function onPresent() {
            window.minimized = false;
            Hyprland.dispatch('hl.dsp.focus({ window = "title:^Cybex OS Software$" })');
        }
    }
    Column {
        focus: true
        Keys.onEscapePressed: Software.close()
        anchors.fill: parent; anchors.margins: Theme.panelPadding
        spacing: Theme.controlSpacing
        Row {
            width: parent.width; spacing: Theme.controlSpacing
            Text { text: I18n.tr("Software"); color: Theme.textHi; font.family: Theme.fontMenu; font.pixelSize: Theme.typography.title; anchors.verticalCenter: parent.verticalCenter }
            SettingsUi.SettingsAction { text: I18n.tr("Browse"); primary: !Software.installedTab; onTriggered: Software.installedTab = false }
            SettingsUi.SettingsAction { text: I18n.tr("Installed"); primary: Software.installedTab; onTriggered: Software.installedTab = true }
            SettingsUi.SettingsAction { text: I18n.tr("Refresh"); enabled: !Software.busy; onTriggered: Software.refresh() }
        }
        Controls.TextField {
            id: search
            width: parent.width
            placeholderText: I18n.tr("Search native applications and packages")
            text: Software.query; onTextEdited: Software.query = text
            color: Theme.textHi; placeholderTextColor: Theme.textDim
            font.family: Theme.fontMenu; font.pixelSize: Theme.typography.control
            background: Rectangle { color: Theme.cardFill; radius: Theme.chipRadius; border.color: Theme.stroke; border.width: 1 }
            Accessible.name: I18n.tr("Search software")
        }
        Text {
            width: parent.width
            text: Software.error || (Software.busy ? I18n.tr("Loading the machine’s locked package catalogue…")
                : Software.installedTab ? I18n.tr("Packages declared elsewhere keep their existing configuration owners.")
                : String(Software.total) + I18n.tr(" matching packages · showing up to 200"))
            color: Software.error ? Theme.redText : Theme.textDim
            font.family: Theme.fontMenu; font.pixelSize: Theme.typography.secondary; wrapMode: Text.Wrap
            textFormat: Text.PlainText
        }
        ListView {
            id: list
            width: parent.width
            height: Math.max(100, window.height - y - footer.height - Theme.panelPadding * 2 - Theme.controlSpacing)
            clip: true
            model: Software.installedTab ? (Software.inventory.packages || []).filter(p =>
                Software.query === "" || (p.name + " " + p.description).toLowerCase().includes(Software.query.toLowerCase())) : Software.results
            spacing: Theme.controlSpacing
            Controls.ScrollBar.vertical: Controls.ScrollBar {}
            delegate: Rectangle {
                id: row
                required property var modelData
                readonly property string attribute: modelData.attribute || (modelData.attributes || [])[0] || ""
                width: ListView.view ? ListView.view.width : 0
                height: Math.max(76, copy.implicitHeight + 20)
                color: Theme.cardFill; radius: Theme.chipRadius
                Column {
                    id: copy
                    anchors.left: parent.left; anchors.leftMargin: 12; anchors.right: action.left; anchors.rightMargin: 12
                    anchors.verticalCenter: parent.verticalCenter; spacing: 3
                    Text { width: parent.width; text: row.modelData.name + "  " + (row.modelData.version || ""); textFormat: Text.PlainText; color: Theme.textHi; font.family: Theme.fontMenu; font.pixelSize: Theme.typography.primary; elide: Text.ElideRight }
                    Text { width: parent.width; text: row.modelData.description || ""; textFormat: Text.PlainText; color: Theme.textDim; font.family: Theme.fontMenu; font.pixelSize: Theme.typography.secondary; wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight }
                    Text { width: parent.width; visible: Software.installedTab; text: row.modelData.managedElsewhere ? I18n.tr("Managed by existing configuration") : row.attribute; textFormat: Text.PlainText; color: Theme.textFaint; font.family: Theme.fontMono; font.pixelSize: Theme.typography.secondary; elide: Text.ElideRight }
                }
                SettingsUi.SettingsAction {
                    id: action
                    anchors.right: parent.right; anchors.rightMargin: 12; anchors.verticalCenter: parent.verticalCenter
                    visible: row.attribute !== ""
                    text: Software.draft.includes(row.attribute) ? (Software.installedTab ? I18n.tr("Remove selection") : I18n.tr("Selected")) : I18n.tr("Add")
                    enabled: !Updates.runActive && !Updates.rebootRecommended
                    onTriggered: Software.toggle(row.attribute)
                }
            }
        }
        Column {
            id: footer
            width: parent.width; spacing: Theme.controlSpacing
            Flow {
                width: parent.width; spacing: Theme.controlSpacing
                SettingsUi.SettingsAction { text: I18n.tr("Discard selections"); enabled: (Software.dirty || Software.conflict) && !Software.busy; onTriggered: Software.discard() }
                SettingsUi.SettingsAction { text: I18n.tr("Build preview"); primary: true; enabled: Software.canStage; onTriggered: Software.stage() }
                SettingsUi.SettingsAction { text: I18n.tr("Review deployment…"); visible: Software.ownDeployment; onTriggered: { Settings.showPanel("applications", Screens.focused ? Screens.focused.name : ""); } }
                SettingsUi.SettingsAction { text: I18n.tr("Close"); onTriggered: Software.close() }
            }
            Text { width: parent.width; visible: Software.ownDeployment; text: Updates.runPhaseLabel; color: Theme.textMid; font.family: Theme.fontMenu; font.pixelSize: Theme.typography.secondary; wrapMode: Text.Wrap; textFormat: Text.PlainText }
        }
    }
}
