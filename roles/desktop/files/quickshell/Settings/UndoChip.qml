import QtQuick
import QtQuick.Controls as Controls
import "../Common"

// Small undo affordance beside a section header or row; the caller shows it
// only while the covered settings differ from their defaults (design v2).
Item {
    id: root

    signal clicked()

    // The settings row this chip resets. Its control is where focus goes.
    property Item row: null

    function inside(item, container) {
        for (let at = item; at; at = at.parent) {
            if (at === container)
                return true;
        }
        return false;
    }

    // Resetting clears the change this chip exists for, so the caller hides
    // it at once, which would strand keyboard focus on an invisible item.
    // Hand focus to the row's own control first. A row declares its control
    // after the base row's chip, so look both ways along the tab chain.
    function trigger() {
        if (root.activeFocus && root.row) {
            for (const forward of [true, false]) {
                let item = root.nextItemInFocusChain(forward);
                for (let i = 0; item && item !== root && i < 64; i++) {
                    if (inside(item, root.row)) {
                        item.forceActiveFocus(Qt.TabFocusReason);
                        root.clicked();
                        return;
                    }
                    item = item.nextItemInFocusChain(forward);
                }
            }
        }
        root.clicked();
    }

    width: Theme.chipHeight
    height: Theme.chipHeight
    activeFocusOnTab: visible
    Accessible.role: Accessible.Button
    Accessible.name: "Reset to default"
    Accessible.onPressAction: root.trigger()
    Controls.ToolTip.visible: mouse.containsMouse
    Controls.ToolTip.text: "Reset to default"

    Keys.onPressed: event => {
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                || event.key === Qt.Key_Space) {
            root.trigger(); event.accepted = true;
        }
    }

    Rectangle {
        anchors.fill: parent
        radius: Theme.chipRadius
        color: mouse.pressed ? Theme.hoverFillStrong
            : mouse.containsMouse || root.activeFocus ? Theme.hoverFill : "transparent"
        border.width: root.activeFocus ? 1 : 0
        border.color: Theme.accentText
    }

    Sym {
        anchors.centerIn: parent
        name: "undo"
        size: Theme.iconSmall
        symWeight: 450
        color: mouse.containsMouse ? Theme.textHi : Theme.textDim
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        // A pointer reset leaves focus where it was rather than parking it
        // on a chip that is about to disappear.
        onClicked: root.trigger()
    }
}
