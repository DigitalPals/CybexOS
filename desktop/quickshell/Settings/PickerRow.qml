import QtQuick
import "../Common"

// [label][caption][segmented control][undo]. The control ends on the page's
// right-hand edge at its natural width and only wraps, back to the label
// column, when the choices do not fit on one line. The caption is a short
// live readout of the choice — the time it formats, the next poll — never a
// description; explanatory copy goes on the row's hint line.
SettingsRow {
    id: root

    property alias model: pills.model
    property alias current: pills.current
    property alias mono: pills.mono
    property string caption: ""
    property bool captionMono: true
    readonly property real captionWidth: caption === "" ? 0
        : Math.min(Theme.scaled(180), captionText.implicitWidth)
    readonly property real captionGap: captionWidth > 0 ? Theme.controlSpacing : 0
    // Room the choices may take on the control line: everything right of the
    // label column, less the caption.
    readonly property real wideRoom: Math.max(0, root.contentRight - root.labelWidth
        - root.captionWidth - root.captionGap)
    readonly property bool fits: pills.naturalWidth <= wideRoom
    signal picked(var value)

    // A narrow segmented control may wrap to two or more lines. Let the row
    // grow with the track instead of painting the next row over those pills.
    narrowHeight: Theme.settingsStackOffset + Math.max(Theme.settingsControlHeight,
        pills.implicitHeight) + (caption === "" ? Theme.settingsRowSpacing
            : Theme.settingsContentSpacing + captionText.implicitHeight)
    wideHeight: Math.max(Theme.panelRowHeight, pills.implicitHeight) + rowPad * 2
    narrowLabelInset: root.undoWidth
    controlLeft: root.narrow ? root.labelWidth
        : Math.min(pills.x, captionText.visible ? captionText.x : pills.x)

    PillRow {
        id: pills
        width: root.narrow ? Math.max(0, root.contentRight - root.markInset)
            : Math.min(naturalWidth, root.wideRoom)
        x: root.narrow ? root.markInset : root.contentRight - width
        y: root.narrow ? Theme.settingsStackOffset : (root.lineHeight - height) / 2
        opacity: root.controlOpacity
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
        x: root.narrow ? root.markInset : pills.x - root.captionGap - width
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
