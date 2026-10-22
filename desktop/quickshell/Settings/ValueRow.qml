import QtQuick
import "../Common"

// [label][value][actions][reset column]: a row that reports something or
// offers an action rather than holding a setting — a service's status, the
// time of the last check, a file to open, an account to remove. Its value
// and actions end on the page's right-hand edge like every other control,
// so a page that mixes settings and reports keeps one control column
// (2026-09 redesign). ResponsiveActionRow ended its actions at the row's
// outer edge instead, a reset column further right than the controls above.
//
// Nothing here is a setting: the row is never dirty and has nothing to
// reset. A status dot (`dotColor`) can precede the value. `labelMono` sets a
// row named by a path in the mono face and elides it in the middle, so both
// ends of the path stay readable.
//
// On a narrow row a value moves under the label with the actions beside
// it; actions alone stay on the label's line, as a switch does.
SettingsRow {
    id: root

    default property alias actions: actionRow.data
    property string value: ""
    property bool valueMono: false
    property color valueColor: Theme.textMid
    property color dotColor: "transparent"
    property bool labelMono: false

    readonly property bool hasValue: value !== ""
    readonly property real actionsWidth: actionRow.implicitWidth
    readonly property real actionsGap: actionsWidth > 0 && hasValue ? Theme.controlSpacing : 0
    readonly property bool stacked: narrow && hasValue
    // The control line: the row's own line when wide, the line under the
    // label when a narrow row stacks its value.
    readonly property real controlTop: stacked ? Theme.settingsStackOffset : 0
    readonly property real controlHeight: stacked ? Theme.settingsControlHeight : lineHeight
    readonly property real actionsLeft: contentRight - actionsWidth

    dirty: false
    resetKeys: []
    // The mono copy below stands in for the row's own label.
    labelColor: labelMono ? "transparent" : Theme.textMid
    narrowHeight: stacked ? Theme.settingsStackOffset + Theme.settingsControlHeight
        : Math.max(Theme.settingsControlHeight, labelTextHeight)
    narrowLabelY: stacked ? 0
        : Math.max(0, Math.round((Theme.settingsControlHeight - labelTextHeight) / 2))
    narrowLabelInset: stacked ? undoWidth : actionsWidth + undoWidth + Theme.controlSpacing
    controlLeft: hasValue ? valueLine.x : actionsWidth > 0 ? actionsLeft : contentRight

    Text {
        visible: root.labelMono
        x: root.markInset
        y: root.narrow ? root.narrowLabelY : (root.lineHeight - height) / 2
        width: root.narrow ? Math.max(0, root.width - root.narrowLabelInset - root.markInset)
            : Math.max(0, root.controlLeft - root.markInset - Theme.controlSpacing)
        text: root.label
        font.family: Theme.fontMono
        font.pixelSize: Theme.typography.control
        color: Theme.textMid
        elide: Text.ElideMiddle
        verticalAlignment: Text.AlignVCenter
        Accessible.ignored: true
    }

    Row {
        id: valueLine
        visible: root.hasValue
        readonly property real room: Math.max(0, root.actionsLeft - root.actionsGap
            - (root.stacked ? root.markInset : root.labelWidth))
        x: root.stacked ? root.markInset : root.actionsLeft - root.actionsGap - width
        y: root.controlTop + (root.controlHeight - height) / 2
        spacing: Theme.iconTextSpacing
        opacity: root.controlOpacity

        Rectangle {
            id: dot
            visible: root.dotColor.a > 0
            anchors.verticalCenter: parent.verticalCenter
            width: 7
            height: 7
            radius: 4
            color: root.dotColor
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            width: Math.min(implicitWidth, Math.max(0, valueLine.room
                - (dot.visible ? dot.width + valueLine.spacing : 0)))
            text: root.value
            font.family: root.valueMono ? Theme.fontMono : Theme.fontMenu
            font.pixelSize: root.valueMono ? Theme.typography.secondary : Theme.typography.control
            color: root.valueColor
            elide: Text.ElideRight
        }
    }

    Row {
        id: actionRow
        x: root.actionsLeft
        y: root.controlTop + (root.controlHeight - height) / 2
        spacing: Theme.iconTextSpacing
        opacity: root.controlOpacity
    }
}
