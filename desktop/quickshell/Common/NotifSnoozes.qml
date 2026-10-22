pragma ComponentBehavior: Bound
import QtQuick

Column {
    id: root
    spacing: Theme.controlSpacing
    visible: Notifs.snoozes.length > 0

    Text {
        width: parent.width
        text: I18n.tr("Source snoozes")
        font.family: Theme.fontMenu
        font.pixelSize: Theme.typography.metadata
        color: Theme.textDim
    }
    Repeater {
        model: Notifs.snoozes
        delegate: Row {
            id: snoozeRow
            required property var modelData
            width: root.width
            spacing: Theme.controlSpacing
            Text {
                width: Math.max(0, snoozeRow.width - resume.width - snoozeRow.spacing)
                anchors.verticalCenter: parent.verticalCenter
                text: snoozeRow.modelData.label + " · " + Qt.formatTime(new Date(snoozeRow.modelData.until), "hh:mm")
                textFormat: Text.PlainText
                elide: Text.ElideRight
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.secondary
                color: Theme.textMid
            }
            NotifButton {
                id: resume
                text: I18n.tr("Unsnooze")
                Accessible.description: snoozeRow.modelData.label
                onTriggered: Notifs.unsnooze(snoozeRow.modelData.key)
            }
        }
    }
    NotifButton {
        text: I18n.tr("Unsnooze all")
        onTriggered: Notifs.unsnoozeAll()
    }
}
