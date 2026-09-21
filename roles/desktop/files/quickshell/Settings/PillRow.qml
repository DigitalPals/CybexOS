pragma ComponentBehavior: Bound
import QtQuick
import "../Common"

// Wrapping segmented control with roving keyboard selection.
//
// Selection is the menubar's own held-chip grammar rather than an accent
// tint: the taken option lights the same surface a bar chip lights when its
// popout is open, and the value jump from low copy to high copy is what says
// which one is chosen. Full accent stays on the small state marks.
Flow {
    id: root

    property var model: []
    property var current
    property bool mono: false
    property int pillHeight: Theme.chipInnerHeight
    property int padH: 11
    signal picked(var value)
    readonly property bool anySelected: model.some(item => item.value === current)

    spacing: Theme.panelRowSpacing
    Repeater {
        id: pillRepeater
        model: root.model

        delegate: Rectangle {
            id: pill

            required property var modelData
            required property int index
            readonly property bool selected: modelData.value === root.current

            width: Math.min(root.width, pillText.implicitWidth + root.padH * 2)
            height: root.pillHeight
            radius: Theme.chipRadius
            color: pill.selected ? Theme.chipHover : "transparent"
            border.width: activeFocus ? 1 : 0
            border.color: Theme.accentText
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
                    root.picked(root.model[next].value);
                    pillRepeater.itemAt(next).forceActiveFocus();
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
                font.weight: Theme.weightMedium
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
