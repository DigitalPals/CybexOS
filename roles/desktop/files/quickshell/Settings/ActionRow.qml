import QtQuick
import "../Common"

// [label][actions][undo gutter]: a row whose control is one or more buttons
// that hand off to something else — the mixer, the Wi-Fi list, the advanced
// connection editor. The buttons end on the control edge like any other
// control. Without a label the row is bare: the buttons start on the label
// lane instead, the way a group's closing actions read.
//
// Nothing here is a stored setting, so the row never wears the modified
// mark and has nothing to reset.
SettingsRow {
    id: root

    default property alias actions: buttons.data
    readonly property bool bare: label === ""

    dirty: false
    resetKeys: []
    narrowHeight: (bare ? 0 : Theme.settingsStackOffset) + Math.max(Theme.settingsControlHeight,
        buttons.height)
    wideHeight: Math.max(Theme.panelRowHeight, buttons.height) + rowPad * 2
    narrowLabelInset: root.undoWidth
    controlLeft: buttons.x

    Row {
        id: buttons
        x: root.bare || root.narrow ? root.markInset - Theme.scaled(8) : root.contentRight - width
        y: root.narrow && !root.bare ? Theme.settingsStackOffset : (root.lineHeight - height) / 2
        spacing: Theme.controlSpacing
        opacity: root.controlOpacity
    }
}
