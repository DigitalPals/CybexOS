import QtQuick
import "../Common"

// [label 90][pills][caption fill, right][undo 18] (design v2 format rows).
SettingsRow {
    id: root

    property alias model: pills.model
    property alias current: pills.current
    property alias mono: pills.mono
    property string caption: ""
    property bool captionMono: true
    readonly property real captionWidth: caption === "" ? 0
        : Math.min(180, captionText.implicitWidth)
    signal picked(var value)

    // A narrow segmented control may wrap to two or more lines. Let the row
    // grow with the Flow instead of painting the next row over those pills.
    narrowHeight: Theme.scaled(29) + Math.max(Theme.settingsControlHeight,
        pills.implicitHeight) + Theme.scaled(5)
    narrowLabelInset: 130

    PillRow {
        id: pills
        x: root.narrow ? 0 : root.labelWidth
        y: root.narrow ? Theme.scaled(29) : (parent.height - height) / 2
        width: root.narrow ? parent.width
            : Math.max(100, parent.width - x - root.undoWidth
                - root.captionWidth - (root.captionWidth > 0 ? 10 : 0))
        current: root.stored
        onPicked: value => {
            root.commit(value);
            root.picked(value);
        }
    }

    Text {
        id: captionText
        y: root.narrow ? 0 : (parent.height - height) / 2
        x: root.narrow
            ? Math.max(root.labelTextWidth,
                parent.width - implicitWidth - root.undoWidth - 6)
            : root.contentRight - root.captionWidth
        width: root.narrow ? Math.max(0, root.contentRight - x - 4) : root.captionWidth
        horizontalAlignment: Text.AlignRight
        text: root.caption
        font.family: root.captionMono ? Theme.fontMono : Theme.fontMenu
        font.pixelSize: Theme.typography.control
        color: Theme.textFaint
        elide: Text.ElideLeft
    }
}
