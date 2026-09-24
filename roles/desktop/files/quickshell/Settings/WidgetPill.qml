import QtQuick
import QtQuick.Controls as Controls
import "../Common"

// One widget in the Bar page's editor (2026-09 redesign).
//
// A widget on the bar is a filled chip in its section's lane. The whole chip
// is the way into its options — the thirteen per-pill gears are gone — it
// drags to reorder or to move between sections, and its ⋯ button holds the
// same Move and Remove actions as the context menu, so right-click is no
// longer the only way to reach them.
//
// A widget that is not on the bar is an outlined chip in the Add widgets
// tray. Its body adds it to the section it last lived in, dragging it into a
// lane adds it at the drop marker, and ⋯ offers the other sections and its
// options.
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

    readonly property bool placed: entry.enabled === true
    readonly property string sectionTitle: entry.section.charAt(0).toUpperCase() + entry.section.slice(1)
    // Shown on the bar right now? A widget whose runtime rule hides it (no
    // battery, nothing playing) stays in its lane, quieter.
    readonly property bool hiddenNow: placed && status.indexOf("Hidden") === 0
    readonly property real bodyInset: Theme.controlSpacing
    // The width the chip wants on one line; the tray lays chips out at it.
    readonly property real naturalWidth: bodyInset + widgetIcon.width + Theme.iconTextSpacing
        + nameText.implicitWidth + (root.placed ? 0 : Theme.iconTextSpacing + addGlyph.width)
        + Theme.iconTextSpacing + moreAction.width + moreAction.anchors.rightMargin

    function primary() {
        if (placed)
            activated();
        else if (actionsEnabled)
            addRequested();
    }

    function openMenu(anchor) {
        menu.popup(anchor, 0, anchor.height);
    }

    height: Theme.settingsControlHeight
    radius: Theme.chipRadius
    color: placed ? Theme.chip : "transparent"
    border.width: activeFocus ? 1 : placed && !Settings.highContrast ? 0 : 1
    border.color: activeFocus ? Theme.accentText : Theme.hairline
    opacity: dragInProgress ? 0.4 : 1
    activeFocusOnTab: true
    Accessible.role: Accessible.Button
    Accessible.name: placed ? root.entry.name : "Add " + root.entry.name
    Accessible.description: status + (placed
        ? ". Opens its options. Alt+arrow keys reorder it; the Menu key moves or removes it."
        : ". Adds it to the " + sectionTitle + " section, or drag it into place; the Menu key offers another section.")
    Accessible.onPressAction: root.primary()

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
            root.openMenu(root);
            event.accepted = true;
        } else if (placed && actionsEnabled && (event.modifiers & Qt.AltModifier)
                && [Qt.Key_Left, Qt.Key_Up, Qt.Key_Right, Qt.Key_Down].includes(event.key)) {
            root.keyboardMove(event.key === Qt.Key_Left || event.key === Qt.Key_Up ? -1 : 1);
            event.accepted = true;
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
            stateLayer.pulseCenter();
            root.primary();
            event.accepted = true;
        }
    }

    StateLayer {
        id: stateLayer
        anchors.fill: parent
        radius: parent.radius
        hovered: mouse.containsMouse
        pressed: mouse.pressed && !mouse.dragging
        focused: root.activeFocus
        tint: Theme.textHi
        pressPoint: Qt.point(mouse.mouseX, mouse.mouseY)
    }

    Sym {
        id: widgetIcon
        x: root.bodyInset
        anchors.verticalCenter: parent.verticalCenter
        name: root.entry.glyph || "extension"
        size: Theme.iconSmall
        color: root.hiddenNow ? Theme.textDim : Theme.textMid
    }
    Text {
        id: nameText
        anchors.left: widgetIcon.right
        anchors.leftMargin: Theme.iconTextSpacing
        anchors.verticalCenter: parent.verticalCenter
        width: Math.max(0, Math.min(implicitWidth, moreAction.x - Theme.iconTextSpacing - x
            - (root.placed ? 0 : addGlyph.width + Theme.iconTextSpacing)))
        text: root.entry.name
        font.family: Theme.fontMenu
        font.pixelSize: Theme.typography.control
        font.weight: Theme.weightMedium
        color: root.hiddenNow ? Theme.textLow : Theme.textHi
        elide: Text.ElideRight
    }
    Sym {
        id: addGlyph
        visible: !root.placed
        anchors.left: nameText.right
        anchors.leftMargin: Theme.iconTextSpacing
        anchors.verticalCenter: parent.verticalCenter
        name: "add"
        size: Theme.iconSmall
        color: Theme.accentText
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        anchors.rightMargin: moreAction.width + moreAction.anchors.rightMargin
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        hoverEnabled: true
        preventStealing: true
        // A tray chip's first answer is a click, so it keeps the pointing
        // hand until a drag actually starts.
        cursorShape: dragging ? Qt.ClosedHandCursor
            : root.draggable && root.placed ? Qt.OpenHandCursor : Qt.PointingHandCursor
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
            else if (!canceled && event.button === Qt.LeftButton) root.primary();
        }
        onCanceled: { dragging = false; canceled = true; root.dragCanceled(); }
    }

    SettingsTooltip {
        visible: !root.dragInProgress && mouse.containsMouse
        text: root.placed ? root.entry.name + "\n" + root.status
            : "Add to " + root.sectionTitle + ", or drag into a section\n" + root.entry.description
    }

    // The visible route to Move and Remove, for the pointer and for a
    // keyboard that does not know the chip also answers to Menu and
    // Shift+F10 with the same menu.
    SettingsAction {
        id: moreAction
        anchors.right: parent.right
        anchors.rightMargin: Theme.scaled(2)
        anchors.verticalCenter: parent.verticalCenter
        width: parent.height - Theme.scaled(4)
        height: width
        text: (root.placed ? "Move or remove " : "Choose a section for ") + root.entry.name
        tooltip: root.placed ? "Move or remove" : "Choose a section"
        glyph: "more_horiz"
        compact: true
        enabled: !root.dragInProgress
        onTriggered: root.openMenu(moreAction)
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
        Controls.MenuItem {
            text: "Widget settings…"
            visible: root.placed
            height: visible ? implicitHeight : 0
            onTriggered: root.activated()
        }
        Controls.MenuSeparator {
            visible: root.placed
            height: visible ? implicitHeight : 0
        }
        Controls.MenuItem {
            text: "Move earlier"
            visible: root.placed
            height: visible ? implicitHeight : 0
            enabled: root.actionsEnabled && root.canMoveEarlier
            onTriggered: root.keyboardMove(-1)
        }
        Controls.MenuItem {
            text: "Move later"
            visible: root.placed
            height: visible ? implicitHeight : 0
            enabled: root.actionsEnabled && root.canMoveLater
            onTriggered: root.keyboardMove(1)
        }
        Controls.MenuItem {
            text: root.placed ? "Move to Left" : "Add to Left"
            visible: !root.placed || root.entry.section !== "left"
            height: visible ? implicitHeight : 0
            enabled: root.actionsEnabled
            onTriggered: root.moveRequested("left")
        }
        Controls.MenuItem {
            text: root.placed ? "Move to Center" : "Add to Center"
            visible: !root.placed || root.entry.section !== "center"
            height: visible ? implicitHeight : 0
            enabled: root.actionsEnabled
            onTriggered: root.moveRequested("center")
        }
        Controls.MenuItem {
            text: root.placed ? "Move to Right" : "Add to Right"
            visible: !root.placed || root.entry.section !== "right"
            height: visible ? implicitHeight : 0
            enabled: root.actionsEnabled
            onTriggered: root.moveRequested("right")
        }
        Controls.MenuSeparator {}
        Controls.MenuItem {
            text: "Remove from bar"
            visible: root.placed
            height: visible ? implicitHeight : 0
            enabled: root.actionsEnabled
            onTriggered: root.removeRequested()
        }
        Controls.MenuItem {
            text: "Widget settings…"
            visible: !root.placed
            height: visible ? implicitHeight : 0
            onTriggered: root.activated()
        }
    }
}
