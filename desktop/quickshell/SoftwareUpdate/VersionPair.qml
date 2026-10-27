import QtQuick
import "../Common"
import "../Common/UpdatesHelpers.js" as Helpers

// Old → new, in the instrument face. Additions and removals say so instead
// of showing an empty side. Dates (firmware, NixOS builds) read as dates.
Row {
    id: root

    property string component: ""
    property var before: null
    property var after: null
    property string kind: "updated"
    property bool compact: false

    function display(value) {
        const parts = Helpers.versionParts(root.component, value);
        if (parts.date === "")
            return parts.text;
        const [year, month, day] = parts.date.split("-").map(Number);
        const date = new Date(year, month - 1, day).toLocaleDateString(Qt.locale(), "d MMM yyyy");
        return parts.text !== "" ? parts.text + " · " + date : date;
    }

    readonly property bool added: kind === "added" || (before === null || before === undefined) && after
    readonly property bool removed: kind === "removed" || (after === null || after === undefined) && before

    spacing: Theme.scaled(7)
    layoutDirection: Qt.LeftToRight

    Text {
        anchors.verticalCenter: parent.verticalCenter
        visible: !root.added && !root.removed
        text: root.display(root.before)
        color: Theme.textFaint
        font.family: Theme.fontNumeric
        font.pixelSize: root.compact ? Theme.typography.metadata : Theme.typography.secondary
        textFormat: Text.PlainText
    }
    Sym {
        anchors.verticalCenter: parent.verticalCenter
        visible: !root.added && !root.removed
        name: "arrow-right"
        size: root.compact ? Theme.iconSmall : Theme.iconMedium
        color: Theme.accentText
    }
    Rectangle {
        anchors.verticalCenter: parent.verticalCenter
        width: value.implicitWidth + Theme.scaled(12)
        height: value.implicitHeight + Theme.scaled(4)
        radius: Theme.chipRadius - 1
        color: root.added ? Theme.okBg : root.removed ? Theme.redBgSoft : Theme.chip
        Text {
            id: value
            anchors.centerIn: parent
            text: root.added ? I18n.tr("New") : root.removed ? I18n.tr("Removed") : root.display(root.after)
            color: root.added ? Theme.ok : root.removed ? Theme.redText : Theme.textHi
            font.family: root.added || root.removed ? Theme.fontMenu : Theme.fontNumeric
            font.weight: root.added || root.removed ? Theme.weightSemibold : Theme.weightMedium
            font.pixelSize: root.compact ? Theme.typography.metadata : Theme.typography.secondary
            textFormat: Text.PlainText
        }
    }
}
