import QtQuick
import "../Common"

// [label][switch][undo] with the description on the row's hint line below.
// Sharing the label's line made the description compete with the label and
// elide at ordinary widths; underneath, it wraps instead.
SettingsRow {
    id: root

    property string description: ""
    property bool checked: root.stored === true
    signal toggled(bool value)

    hint: description
    // The switch keeps its own line beside the label at every width.
    narrowHeight: Theme.settingsControlHeight
    narrowLabelY: Math.max(0, Math.round((Theme.settingsControlHeight - root.labelTextHeight) / 2))
    narrowLabelInset: control.width + root.undoWidth + Theme.controlSpacing
    controlLeft: control.x

    Toggle {
        id: control
        x: root.contentRight - width - 2
        y: (root.lineHeight - height) / 2
        opacity: root.controlOpacity
        metrics: Theme.switchRow
        checked: root.checked
        accessibleName: root.label
        onToggled: value => {
            root.commit(value);
            root.toggled(value);
        }
    }
}
