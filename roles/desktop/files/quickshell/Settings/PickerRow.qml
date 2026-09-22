import QtQuick
import "../Common"

// [label][pills][caption, right][undo]. The caption is a short live readout
// of the choice — the time it formats, the next poll — never a description;
// explanatory copy goes on the row's hint line.
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
    narrowHeight: Theme.settingsStackOffset + Math.max(Theme.settingsControlHeight,
        pills.implicitHeight) + (caption === "" ? Theme.settingsRowSpacing
            : Theme.settingsContentSpacing + captionText.implicitHeight)
    wideHeight: Math.max(Theme.panelRowHeight, pills.implicitHeight)
    narrowLabelInset: root.undoWidth

    PillRow {
        id: pills
        x: root.narrow ? root.markInset : root.labelWidth
        y: root.narrow ? Theme.settingsStackOffset : (root.lineHeight - height) / 2
        opacity: root.controlOpacity
        width: root.narrow ? Math.max(0, root.contentRight - x)
            : Math.max(0, parent.width - x - root.undoWidth
                - root.captionWidth - (root.captionWidth > 0 ? 10 : 0))
        current: root.stored
        onPicked: value => {
            root.commit(value);
            root.picked(value);
        }
    }

    Text {
        id: captionText
        visible: root.caption !== ""
        y: root.narrow ? Theme.settingsStackOffset
            + Math.max(Theme.settingsControlHeight, pills.implicitHeight)
            + Theme.settingsContentSpacing : (root.lineHeight - height) / 2
        x: root.narrow ? root.markInset : root.contentRight - root.captionWidth
        width: root.narrow ? Math.max(0, root.contentRight - x) : root.captionWidth
        horizontalAlignment: root.narrow ? Text.AlignLeft : Text.AlignRight
        wrapMode: root.narrow ? Text.Wrap : Text.NoWrap
        maximumLineCount: root.narrow ? 2 : 1
        text: root.caption
        font.family: root.captionMono ? Theme.fontMono : Theme.fontMenu
        font.pixelSize: Theme.typography.control
        color: Theme.textFaint
        elide: root.narrow ? Text.ElideRight : Text.ElideLeft
    }
}
