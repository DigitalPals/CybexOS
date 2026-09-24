import QtQuick
import "../Common"

// One entry in a list whose rows are the control: an output device, a saved
// connection (2026-09 redesign). The icon says what kind of thing it is, the
// label which one, `detail` adds a quieter second line and `meta` a short
// status at the right ("Connected"). The chosen entry is raised out of the
// page and wears a check. A list whose choice opens settings further down
// the page sets `opens`: every row then ends in a chevron instead.
//
// The row keeps the settings column's grid: its icon starts on the label
// lane and its mark ends on the control edge, so a list reads as one more
// control between ordinary rows. Tab reaches each entry; Up and Down step to
// the neighbouring entry and Enter or Space picks it.
Item {
    id: root

    property string glyph: ""
    property string label: ""
    property string detail: ""
    property string meta: ""
    property bool checked: false
    property bool opens: false
    signal activated()

    readonly property int bleed: Theme.scaled(6)
    // The reset gutter every settings row keeps free on the right.
    readonly property real contentRight: width - Theme.chipHeight

    // Up and Down look for siblings by this name, so a list can mix entries
    // with other items without them joining the arrow-key order.
    objectName: "settingsChoiceRow"
    width: parent ? parent.width : 0
    height: Math.max(Theme.listRowHeight, copy.implicitHeight + Theme.scaled(10))
    opacity: enabled ? 1 : 0.5
    activeFocusOnTab: enabled && visible
    Accessible.role: opens ? Accessible.Button : Accessible.RadioButton
    Accessible.name: root.label
    Accessible.description: [root.detail, root.meta].filter(part => part !== "").join(", ")
    Accessible.checkable: !root.opens
    Accessible.checked: root.checked
    Accessible.onPressAction: root.pick()

    function pick() {
        if (!root.enabled)
            return;
        rowState.pulseCenter();
        root.activated();
    }

    function neighbour(step) {
        const rows = root.parent ? root.parent.children : [];
        let at = -1;
        for (let i = 0; i < rows.length; i++) {
            if (rows[i] === root)
                at = i;
        }
        for (let i = at + step; at >= 0 && i >= 0 && i < rows.length; i += step) {
            const row = rows[i];
            if (row.objectName === root.objectName && row.visible && row.enabled)
                return row;
        }
        return null;
    }

    Keys.onPressed: event => {
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                || event.key === Qt.Key_Space) {
            root.pick();
            event.accepted = true;
        } else if (event.key === Qt.Key_Up || event.key === Qt.Key_Down) {
            const next = root.neighbour(event.key === Qt.Key_Up ? -1 : 1);
            if (next)
                next.forceActiveFocus(Qt.TabFocusReason);
            event.accepted = true;
        }
    }

    Rectangle {
        id: fill
        x: Theme.settingsMarkInset - root.bleed
        width: Math.max(0, root.contentRight + root.bleed - x)
        height: parent.height
        radius: Theme.rowRadius
        color: root.checked ? Theme.chip : "transparent"
        border.width: root.activeFocus ? 1 : 0
        border.color: Theme.accentText

        Behavior on color {
            ColorAnimation { duration: Theme.chipFadeDuration }
        }

        StateLayer {
            id: rowState
            anchors.fill: parent
            radius: parent.radius
            hovered: mouse.containsMouse
            pressed: mouse.pressed
            focused: root.activeFocus
            tint: Theme.textHi
            pressPoint: Qt.point(mouse.mouseX, mouse.mouseY)
        }
    }

    Sym {
        id: icon
        visible: root.glyph !== ""
        x: Theme.settingsMarkInset
        anchors.verticalCenter: parent.verticalCenter
        name: root.glyph
        size: Theme.iconMedium
        color: root.checked ? Theme.accentText : Theme.textLow
    }

    Column {
        id: copy
        x: icon.visible ? icon.x + icon.width + Theme.controlSpacing : Theme.settingsMarkInset
        width: Math.max(0, trail.x - Theme.controlSpacing - x)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Theme.scaled(1)

        Text {
            width: parent.width
            text: root.label
            font.family: Theme.fontMenu
            font.pixelSize: Theme.typography.control
            font.weight: root.checked ? Theme.weightSemibold : Theme.weightRegular
            color: root.checked ? Theme.textHi : Theme.textMid
            elide: Text.ElideRight
        }
        Text {
            width: parent.width
            visible: text !== ""
            text: root.detail
            font.family: Theme.fontMenu
            font.pixelSize: Theme.typography.secondary
            color: Theme.textFaint
            elide: Text.ElideRight
        }
    }

    Row {
        id: trail
        x: root.contentRight - width
        anchors.verticalCenter: parent.verticalCenter
        spacing: Theme.controlSpacing

        Text {
            anchors.verticalCenter: parent.verticalCenter
            visible: text !== ""
            text: root.meta
            font.family: Theme.fontMenu
            font.pixelSize: Theme.typography.secondary
            color: root.checked ? Theme.textLow : Theme.textFaint
        }
        // The mark keeps its slot while hidden, so choosing an entry does not
        // shift its status text sideways.
        Sym {
            anchors.verticalCenter: parent.verticalCenter
            name: root.opens ? "chevron_right" : "check"
            size: Theme.iconSmall
            color: root.opens ? Theme.textFaint : Theme.accentText
            opacity: root.opens || root.checked ? 1 : 0
        }
    }

    MouseArea {
        id: mouse
        x: fill.x
        width: fill.width
        height: parent.height
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: {
            root.forceActiveFocus(Qt.MouseFocusReason);
            root.activated();
        }
    }
}
