import QtQuick
import "../Common"

// [label 90][description fill][switch][undo 18] (design v2 behavior rows).
SettingsRow {
    id: root

    property string description: ""
    property bool checked: root.stored === true
    signal toggled(bool value)

    narrowHeight: Math.max(Theme.scaled(48), Theme.scaled(24) + descriptionText.implicitHeight + Theme.scaled(3))
    narrowLabelY: 2
    narrowLabelInset: 82

    Text {
        id: descriptionText
        x: root.narrow ? 0 : root.labelWidth
        y: root.narrow ? Theme.scaled(24) : (parent.height - height) / 2
        width: root.narrow ? parent.width - 4 : control.x - x - 10
        text: root.description
        font.family: Theme.fontMenu
        font.pixelSize: Theme.typography.control
        color: Theme.textDim
        elide: root.narrow ? Text.ElideNone : Text.ElideRight
        wrapMode: root.narrow ? Text.Wrap : Text.NoWrap
        maximumLineCount: root.narrow ? 2 : 1
    }

    Toggle {
        id: control
        x: root.contentRight - width - 2
        y: root.narrow ? 0 : (parent.height - height) / 2
        metrics: Theme.switchRow
        checked: root.checked
        accessibleName: root.label
        onToggled: value => {
            root.commit(value);
            root.toggled(value);
        }
    }
}
