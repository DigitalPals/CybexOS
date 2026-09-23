import QtQuick
import QtQuick.Controls as Controls
import "../Common"

Rectangle {
    id: root
    required property var entry
    property string status: ""
    property bool draggable: true
    property bool dragInProgress: false
    property bool actionsEnabled: true
    property bool canMoveEarlier: false
    property bool canMoveLater: false
    signal activated()
    signal removeRequested()
    signal addRequested()
    signal moveRequested(string section)
    signal keyboardMove(int delta)
    signal dragStarted()
    signal dragMoved(real x, real y)
    signal dragFinished()
    signal dragCanceled()

    height: Theme.settingsControlHeight
    radius: height / 2
    color: Theme.background
    border.width: activeFocus || settingsAction.activeFocus || Settings.highContrast ? 2 : 0
    border.color: Theme.accentText
    opacity: dragInProgress ? 0.4 : 1
    activeFocusOnTab: true
    Accessible.role: Accessible.Button
    Accessible.name: entry.name
    Accessible.description: status + (entry.enabled
        ? ". Alt+arrow keys to reorder. Menu key for move and remove actions."
        : ". Menu key to add to the bar or open settings.")
    Accessible.onPressAction: root.activated()
    Controls.ToolTip.visible: !dragInProgress && (mouse.containsMouse || activeFocus)
    Controls.ToolTip.text: entry.name + "\n" + status

    onDragInProgressChanged: {
        if (!dragInProgress && mouse.dragging) {
            mouse.dragging = false;
            mouse.canceled = true;
        }
    }
    Keys.onPressed: event => {
        if (event.key === Qt.Key_Escape && dragInProgress) {
            root.dragCanceled();
            event.accepted = true;
        } else if (event.key === Qt.Key_Menu || (event.key === Qt.Key_F10 && (event.modifiers & Qt.ShiftModifier))) {
            menu.popup();
            event.accepted = true;
        } else if (actionsEnabled && (event.modifiers & Qt.AltModifier)
                && [Qt.Key_Left, Qt.Key_Up, Qt.Key_Right, Qt.Key_Down].includes(event.key)) {
            root.keyboardMove(event.key === Qt.Key_Left || event.key === Qt.Key_Up ? -1 : 1);
            event.accepted = true;
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
            root.activated();
            event.accepted = true;
        }
    }
    Sym {
        id: widgetIcon
        anchors.left: parent.left
        anchors.leftMargin: 8
        anchors.verticalCenter: parent.verticalCenter
        name: root.entry.glyph || "extension"
        size: Theme.iconSmall
        color: Theme.textMid
    }
    Text {
        anchors.left: widgetIcon.right
        anchors.leftMargin: 6
        anchors.right: settingsAction.left
        anchors.rightMargin: 4
        anchors.verticalCenter: parent.verticalCenter
        text: root.entry.name
        font.family: Theme.fontMenu
        font.pixelSize: Theme.typography.control
        font.weight: Theme.weightMedium
        color: Theme.textHi
        elide: Text.ElideRight
    }
    MouseArea {
        id: mouse
        anchors.fill: parent
        anchors.rightMargin: settingsAction.width + 6
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        hoverEnabled: true
        preventStealing: true
        cursorShape: !root.draggable ? Qt.PointingHandCursor : dragging ? Qt.ClosedHandCursor : Qt.OpenHandCursor
        property point startPoint
        property bool dragging: false
        property bool canceled: false
        onPressed: event => {
            root.forceActiveFocus();
            startPoint = Qt.point(event.x, event.y);
            dragging = false;
            canceled = false;
            if (event.button === Qt.RightButton) menu.popup();
        }
        onPositionChanged: event => {
            if (!(pressedButtons & Qt.LeftButton) || canceled || !root.draggable) return;
            if (!dragging && Math.hypot(event.x - startPoint.x, event.y - startPoint.y) > 8) {
                dragging = true;
                root.dragStarted();
            }
            if (dragging) root.dragMoved(event.x, event.y);
        }
        onReleased: event => {
            const finished = dragging;
            dragging = false;
            if (finished) root.dragFinished();
            else if (!canceled && event.button === Qt.LeftButton) root.forceActiveFocus();
        }
        onCanceled: { dragging = false; canceled = true; root.dragCanceled(); }
    }
    SettingsAction {
        id: settingsAction
        anchors.right: parent.right
        anchors.rightMargin: 6
        anchors.verticalCenter: parent.verticalCenter
        text: "Settings for " + root.entry.name
        glyph: "settings"
        compact: true
        enabled: !root.dragInProgress
        onTriggered: root.activated()
    }
    Controls.Menu {
        id: menu
        popupType: Controls.Popup.Item
        focus: true
        font.family: Theme.fontMenu
        font.pixelSize: Theme.typography.control
        palette.window: Theme.popBg
        palette.base: Theme.popBg
        palette.text: Theme.textHi
        palette.windowText: Theme.textHi
        palette.buttonText: Theme.textHi
        palette.highlight: Theme.chipHover
        palette.highlightedText: Theme.textHi
        Controls.MenuItem { text: "Widget settings…"; onTriggered: root.activated() }
        Controls.MenuSeparator {}
        Controls.MenuItem {
            text: "Move earlier"
            visible: root.entry.enabled
            height: visible ? implicitHeight : 0
            enabled: root.actionsEnabled && root.canMoveEarlier
            onTriggered: root.keyboardMove(-1)
        }
        Controls.MenuItem {
            text: "Move later"
            visible: root.entry.enabled
            height: visible ? implicitHeight : 0
            enabled: root.actionsEnabled && root.canMoveLater
            onTriggered: root.keyboardMove(1)
        }
        Controls.MenuItem {
            text: root.entry.enabled ? "Move to Left" : "Add to Left"
            visible: !root.entry.enabled || root.entry.section !== "left"
            height: visible ? implicitHeight : 0
            enabled: root.actionsEnabled
            onTriggered: root.moveRequested("left")
        }
        Controls.MenuItem {
            text: root.entry.enabled ? "Move to Center" : "Add to Center"
            visible: !root.entry.enabled || root.entry.section !== "center"
            height: visible ? implicitHeight : 0
            enabled: root.actionsEnabled
            onTriggered: root.moveRequested("center")
        }
        Controls.MenuItem {
            text: root.entry.enabled ? "Move to Right" : "Add to Right"
            visible: !root.entry.enabled || root.entry.section !== "right"
            height: visible ? implicitHeight : 0
            enabled: root.actionsEnabled
            onTriggered: root.moveRequested("right")
        }
        Controls.MenuSeparator {}
        Controls.MenuItem {
            text: root.entry.enabled ? "Remove from bar" : "Add to bar"
            enabled: root.actionsEnabled
            onTriggered: {
                if (root.entry.enabled) root.removeRequested();
                else root.addRequested();
            }
        }
    }
}
