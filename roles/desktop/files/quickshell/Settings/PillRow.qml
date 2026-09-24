pragma ComponentBehavior: Bound
import QtQuick
import "../Common"

// Wrapping segmented control with roving keyboard selection.
//
// In settings the options sit on one shared track, so a set of choices reads
// as a single control rather than as loose words beside a label (2026-09
// redesign); the taken option is raised out of the track. Popovers that only
// want the loose pills pass `segmented: false`. Either way the accent stays
// off the selection: it belongs to the small state marks.
Item {
    id: root

    property var model: []
    property var current
    property bool mono: false
    property bool segmented: true
    property int pillHeight: Theme.chipInnerHeight
    property int padH: 11
    property int spacing: segmented ? Theme.scaled(2) : Theme.panelRowSpacing
    signal picked(var value)
    readonly property bool anySelected: model.some(item => item.value === current)
    // The track's inset around the options.
    readonly property int inset: segmented ? Theme.scaled(2) : 0
    // The width the options want on one line, track included — what a row
    // uses to right-align the control without stretching it.
    readonly property real naturalWidth: {
        let total = 0;
        for (const item of model)
            total += Math.ceil(metrics.advanceWidth(item.label)) + 1 + padH * 2;
        return total + Math.max(0, model.length - 1) * spacing + inset * 2;
    }

    implicitWidth: naturalWidth
    implicitHeight: flow.implicitHeight + inset * 2

    FontMetrics {
        id: metrics
        font.family: root.mono ? Theme.fontMono : Theme.fontMenu
        font.pixelSize: Theme.typography.control
        font.weight: Theme.weightSemibold
    }

    Rectangle {
        anchors.fill: parent
        visible: root.segmented
        radius: Theme.chipRadius + root.inset
        color: Theme.chip
        border.width: 1
        border.color: Theme.hairlineSoft
    }

    Flow {
        id: flow
        x: root.inset
        y: root.inset
        width: Math.max(0, root.width - root.inset * 2)
        spacing: root.spacing

        Repeater {
            id: pillRepeater
            model: root.model

            delegate: Rectangle {
                id: pill

                required property var modelData
                required property int index
                readonly property bool selected: modelData.value === root.current

                width: Math.min(flow.width, pillText.implicitWidth + root.padH * 2)
                height: root.pillHeight
                radius: Theme.chipRadius
                color: !pill.selected ? "transparent"
                    : root.segmented ? Theme.segmentSelected : Theme.chipHover
                border.width: activeFocus ? 1 : pill.selected && root.segmented ? 1 : 0
                border.color: activeFocus ? Theme.accentText : Theme.hairline
                activeFocusOnTab: pill.selected || (!root.anySelected && index === 0)
                Accessible.role: Accessible.RadioButton
                Accessible.name: pill.modelData.label
                Accessible.checked: pill.selected
                Accessible.onPressAction: {
                    pillState.pulseCenter();
                    root.picked(pill.modelData.value);
                }

                Keys.onPressed: event => {
                    let next = -1;
                    if (event.key === Qt.Key_Left || event.key === Qt.Key_Up)
                        next = Math.max(0, index - 1);
                    else if (event.key === Qt.Key_Right || event.key === Qt.Key_Down)
                        next = Math.min(root.model.length - 1, index + 1);
                    else if (event.key === Qt.Key_Home)
                        next = 0;
                    else if (event.key === Qt.Key_End)
                        next = root.model.length - 1;
                    else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                            || event.key === Qt.Key_Space) {
                        pillState.pulseCenter();
                        root.picked(modelData.value); event.accepted = true; return;
                    }
                    if (next >= 0) {
                        // Focus moves before the value does. activeFocusOnTab
                        // follows the selection, and Qt refuses to clear it on
                        // the item that still holds focus — which left the old
                        // pill behind as a second, stale tab stop.
                        pillRepeater.itemAt(next).forceActiveFocus();
                        root.picked(root.model[next].value);
                        event.accepted = true;
                    }
                }

                StateLayer {
                    id: pillState
                    anchors.fill: parent
                    radius: parent.radius
                    hovered: pillMouse.containsMouse
                    pressed: pillMouse.pressed
                    focused: pill.activeFocus
                    tint: pill.selected ? Theme.accent : Theme.textHi
                    pressPoint: Qt.point(pillMouse.mouseX, pillMouse.mouseY)
                }

                Text {
                    id: pillText
                    anchors.centerIn: parent
                    width: Math.max(0, parent.width - root.padH * 2)
                    horizontalAlignment: Text.AlignHCenter
                    elide: Text.ElideRight
                    text: pill.modelData.label
                    font.family: root.mono ? Theme.fontMono : Theme.fontMenu
                    font.pixelSize: Theme.typography.control
                    font.weight: pill.selected && root.segmented ? Theme.weightSemibold : Theme.weightMedium
                    color: pill.selected ? Theme.textHi : Theme.textLow
                }

                MouseArea {
                    id: pillMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        pill.forceActiveFocus();
                        root.picked(pill.modelData.value);
                    }
                }
            }
        }
    }
}
