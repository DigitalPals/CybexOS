import QtQuick
import QtQuick.Controls as Controls
import "../Common"

Rectangle {
    id: root
    property var entry: ({})
    required property string title
    property string subtitle: ""
    property string glyph: "widgets"
    property bool selected: false
    property bool draggable: false
    property bool dragInProgress: false
    onDragInProgressChanged: {
        if (!dragInProgress && dragArea.dragging) {
            dragArea.dragging = false;
            dragArea.canceled = true;
        }
    }
    property string action: ""
    property string actionGlyph: ""
    property bool actionCompact: false
    property bool actionEnabled: true
    property bool compactRow: false
    signal actionTriggered()
    signal activated()
    signal dragStarted()
    signal dragMoved(real x, real y)
    signal dragFinished()
    signal dragCanceled()
    signal keyboardMove(int delta)
    height: Math.max(compactRow ? 40 : 58, labels.implicitHeight + 12)
    radius: Theme.rowRadius
    color: selected ? Theme.chip : hover.hovered ? Theme.hoverFill : "transparent"
    border.width: activeFocus || selected ? 1 : 0
    border.color: activeFocus ? Theme.accentText : Theme.stroke
    activeFocusOnTab: enabled && visible
    Accessible.role: Accessible.Button
    Accessible.name: title
    Accessible.description: subtitle + (draggable ? ". Alt+Up or Alt+Down to reorder." : "")
    Accessible.selected: selected
    Accessible.onPressAction: root.activated()
    Keys.onPressed: event => {
        if (draggable && (event.modifiers & Qt.AltModifier)
                && (event.key === Qt.Key_Up || event.key === Qt.Key_Down)) {
            root.keyboardMove(event.key === Qt.Key_Up ? -1 : 1);
            event.accepted = true;
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
            root.activated();
            event.accepted = true;
        } else if (event.key === Qt.Key_Escape && root.dragInProgress) {
            root.dragCanceled();
            event.accepted = true;
        }
    }
    HoverHandler { id: hover }
    MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: { root.forceActiveFocus(); root.activated(); }
    }
    Sym {
        id: handle
        x: 8
        anchors.verticalCenter: parent.verticalCenter
        visible: root.draggable
        name: "drag_indicator"
        size: Theme.iconSmall
        color: Theme.textDim
    }
    MouseArea {
        id: dragArea
        visible: root.draggable
        width: 32
        height: parent.height
        preventStealing: true
        cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
        property real startY: 0
        property bool dragging: false
        property bool canceled: false
        onPressed: mouse => { startY = mouse.y; dragging = false; canceled = false; }
        onPositionChanged: mouse => {
            if (!pressed || canceled) return;
            if (!dragging && Math.abs(mouse.y - startY) > 5) {
                dragging = true;
                root.dragStarted();
            }
            if (dragging) root.dragMoved(mouse.x, mouse.y);
        }
        onReleased: {
            const finished = dragging;
            const wasCanceled = canceled;
            dragging = false;
            canceled = false;
            if (finished) root.dragFinished();
            else if (!wasCanceled) { root.forceActiveFocus(); root.activated(); }
        }
        onCanceled: { dragging = false; canceled = false; root.dragCanceled(); }
    }
    Sym {
        id: icon
        x: root.draggable ? 34 : 12
        anchors.verticalCenter: parent.verticalCenter
        name: root.glyph
        size: Theme.iconMedium
        color: root.selected ? Theme.accentText : Theme.textMid
    }
    Column {
        id: labels
        anchors.left: icon.right
        anchors.leftMargin: 10
        anchors.right: actionButton.left
        anchors.rightMargin: 12
        anchors.verticalCenter: parent.verticalCenter
        spacing: 3
        Text {
            width: parent.width
            text: root.title
            font.family: Theme.fontMenu
            font.pixelSize: Theme.typography.primary
            font.weight: Theme.weightMedium
            color: Theme.textHi
            elide: Text.ElideRight
        }
        Text {
            width: parent.width
            visible: text !== ""
            text: root.subtitle
            font.family: Theme.fontMenu
            font.pixelSize: Theme.typography.secondary
            color: Theme.textDim
            elide: Text.ElideRight
        }
    }
    SettingsAction {
        id: actionButton
        anchors.right: parent.right
        anchors.rightMargin: 6
        anchors.verticalCenter: parent.verticalCenter
        text: root.action
        Accessible.name: root.actionCompact ? root.action : root.action + " " + root.title
        glyph: root.actionGlyph
        compact: root.actionCompact
        visible: root.action !== ""
        enabled: root.actionEnabled
        onTriggered: root.actionTriggered()
    }
    Controls.ToolTip.visible: hover.hovered
    Controls.ToolTip.text: root.title + (root.subtitle ? "\n" + root.subtitle : "")
}
