pragma ComponentBehavior: Bound
import QtQuick
import "../Common"
import "../Settings" as SettingsUi
Column {
    id: root
    spacing: Theme.scaled(18)
    // INTEGRATION: stream B replaces these rows with ShortcutKeyboardMap
    // and routes this action to the new shortcuts Settings page.
    readonly property var groups: [
        {title: I18n.tr("Your everyday essentials"), rows: [
            {id: "shell.launcher", label: I18n.tr("Launcher")}, {id: "shell.settings", label: I18n.tr("Settings")},
            {id: "shell.shortcuts", label: I18n.tr("Keyboard shortcuts")}]},
        {title: I18n.tr("Apps and windows"), rows: [
            {id: "apps.terminal", label: I18n.tr("Terminal")}, {id: "apps.browser", label: I18n.tr("Browser")},
            {id: "apps.files", label: I18n.tr("Files")}, {id: "windows.overview", label: I18n.tr("Overview")},
            {id: "windows.close", label: I18n.tr("Close window")} ]}
    ]
    Repeater {
        model: root.groups
        delegate: Column {
            id: group
            required property var modelData
            width: root.width; spacing: Theme.controlSpacing
            GuideText { text: group.modelData.title; font.weight: Theme.weightSemibold }
            Repeater {
                model: group.modelData.rows
                delegate: Rectangle {
                    id: row
                    required property var modelData
                    width: group.width; height: Theme.scaled(44); radius: Theme.chipRadius; color: Theme.cardFill
                    GuideText { anchors.left: parent.left; anchors.leftMargin: Theme.scaled(16); anchors.verticalCenter: parent.verticalCenter; text: row.modelData.label }
                    Keycaps { anchors.right: parent.right; anchors.rightMargin: Theme.scaled(12); anchors.verticalCenter: parent.verticalCenter; combos: Welcome.keysFor(row.modelData.id) }
                    GuideText { anchors.right: parent.right; anchors.rightMargin: Theme.scaled(12); anchors.verticalCenter: parent.verticalCenter; visible: Welcome.keysFor(row.modelData.id).length === 0; text: I18n.tr("Not bound"); tone: "muted" }
                }
            }
        }
    }
    SettingsUi.SettingsAction {
        text: I18n.tr("Customize shortcuts…"); glyph: "keyboard"
        onTriggered: Settings.showPanel(Settings.validPages.includes("shortcuts") ? "shortcuts" : "keyboard")
    }
}
