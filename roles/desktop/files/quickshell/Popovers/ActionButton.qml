import QtQuick
import "../Common"

// The small pill button the T3 pages use for every inline action — Expand,
// Approve, Snooze, Stop, and the rest.
//
// It existed three times, once per page, as near-identical `component Action:`
// declarations that had drifted apart: 18/16/14px of side padding, a default
// tint of textLow or textMid, 0.4 or 0.45 opacity when disabled, and three
// different guards on `activeFocusOnTab`. The differences that are design
// (padding, tint) are properties; the ones that were drift are settled here.
//
// Each page keeps a local `component Action: ActionButton { … }` carrying its
// own defaults, so none of the 21 call sites had to change.
Rectangle {
    id: root

    property string label: ""
    property color tint: Theme.textLow
    property color fill: Theme.hoverFill
    property color focusColor: Theme.accent
    property string fontFamily: Theme.fontMenu
    property int buttonRadius: 6
    // Side padding either side of the label.
    property real hPadding: 18
    // False while the row this sits in is collapsed: a hidden action must not
    // be reachable by Tab. Was the one real behavioural difference between the
    // three copies, and the strictest reading is the correct one.
    property bool revealed: true

    signal triggered()

    width: labelText.implicitWidth + hPadding
    height: Theme.inlineActionHeight
    radius: buttonRadius
    color: fill
    opacity: enabled ? 1 : 0.4
    activeFocusOnTab: enabled && visible && revealed
    Accessible.role: Accessible.Button
    Accessible.name: label
    Accessible.onPressAction: {
        actionState.pulseCenter();
        root.triggered();
    }
    border.width: activeFocus ? 1 : 0
    border.color: focusColor

    Keys.onPressed: event => {
        if (!root.enabled)
            return;
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                || event.key === Qt.Key_Space) {
            actionState.pulseCenter();
            root.triggered();
            event.accepted = true;
        }
    }

    StateLayer {
        id: actionState
        anchors.fill: parent
        radius: parent.radius
        hovered: actionMouse.containsMouse && root.enabled
        pressed: actionMouse.pressed
        focused: root.activeFocus
        tint: root.tint
        pressPoint: Qt.point(actionMouse.mouseX, actionMouse.mouseY)
    }

    Text {
        id: labelText
        anchors.centerIn: parent
        text: root.label
        font.family: root.fontFamily
        font.pixelSize: Theme.typography.control
        font.weight: Theme.weightSemibold
        color: root.tint
    }

    MouseArea {
        id: actionMouse
        anchors.fill: parent
        enabled: root.enabled
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.triggered()
    }
}
