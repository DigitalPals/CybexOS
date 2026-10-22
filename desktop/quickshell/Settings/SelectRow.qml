import QtQuick
import "../Common"

// [label][dropdown][undo]. For a choice with more options than fit on one
// line as a segmented control — display scale, idle delays, fonts — or with
// long option names. The dropdown ends on the page's right-hand edge like
// every other control.
SettingsRow {
    id: root

    property alias model: select.model
    property var current: root.stored
    property alias fontFor: select.fontFor
    property alias maximumWidth: select.maximumWidth
    signal picked(var value)

    narrowHeight: Theme.settingsStackOffset + Theme.settingsControlHeight
    narrowLabelInset: root.undoWidth
    controlLeft: select.x

    SettingsSelect {
        id: select
        width: root.narrow ? Math.max(0, root.contentRight - root.markInset)
            : Math.min(naturalWidth, Math.max(0, root.contentRight - root.labelWidth))
        x: root.narrow ? root.markInset : root.contentRight - width
        y: root.narrow ? Theme.settingsStackOffset : (root.lineHeight - height) / 2
        opacity: root.controlOpacity
        current: root.current
        accessibleName: root.label
        onPicked: value => {
            root.commit(value);
            root.picked(value);
        }
    }
}
