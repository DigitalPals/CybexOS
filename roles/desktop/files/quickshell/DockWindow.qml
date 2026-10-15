pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import Quickshell.Widgets
import "Common"
import "Common/BarGeometry.js" as BarGeometry
import "Common/DockHelpers.js" as DockHelpers

// The optional dock (Settings → Bar → Dock, off by default): pinned and
// running apps in a bottom-centred pill, one per output like the bar, so it
// is under the pointer whichever screen that is on and hotplug creates or
// removes just that output's copy. The items and every action live in the
// Dock singleton; this window only draws them.
//
//   click        launch, focus the app's last window, or cycle its windows
//   middle-click a new window
//   right-click  New window · Pin/Unpin · Close
//
// The surface is a little larger than the pill: the headroom above it and the
// margin either side hold an item's name and its menu. That margin is transparent and outside the
// input mask, so it never blocks a click, and nothing is painted there that
// the compositor's blur would smear (see looknfeel.lua.j2).
PanelWindow {
    id: root

    required property var modelData

    readonly property int iconSize: Theme.scaled(36)
    readonly property int itemSize: Theme.scaled(48)
    readonly property int padding: Theme.scaled(6)
    readonly property int dockHeight: itemSize + padding * 2
    readonly property int gap: Theme.scaled(8)
    readonly property int headroom: Theme.scaled(160)
    readonly property bool barShown: !OmarchyPlugins.replacementActive
    readonly property var place: DockHelpers.placement({
        barPosition: barShown ? Settings.position : "top",
        barDepth: Theme.barTopMargin + Theme.barHeight,
        barZone: BarGeometry.exclusiveZone({
            style: Settings.barStyle,
            gap: Settings.gap,
            height: Theme.barHeight,
            autoHide: Settings.autoHide,
            exclusive: Settings.exclusive
        }),
        dockHeight: dockHeight,
        gap: gap,
        autoHide: Settings.dockAutoHide
    })
    readonly property var keys: JSON.parse(Dock.appsKey)

    // The item whose menu is open ("" for none) and its centre in window x.
    property string menuKey: ""
    property real menuX: 0
    readonly property var menuActions: menuKey !== "" ? Dock.menuActions(menuKey) : []

    function openMenu(key, centreX) {
        menuX = centreX;
        menuKey = key;
        Qt.callLater(() => {
            if (root.menuKey !== "")
                menuColumn.forceActiveFocus();
        });
    }

    function closeMenu() {
        menuKey = "";
    }

    screen: modelData.screen
    visible: keys.length > 0
    anchors.bottom: true
    exclusionMode: ExclusionMode.Normal
    exclusiveZone: place.exclusiveZone
    // Room either side of the pill for a name or menu over an end item.
    implicitWidth: card.width + Theme.scaled(240)
    implicitHeight: headroom + dockHeight + place.offset
    color: "transparent"

    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.namespace: "qs-dock"
    // The menu is modal while open, as a menu is: arrows, Enter and Esc
    // reach it, and the focus grab closes it on any click elsewhere.
    WlrLayershell.keyboardFocus: menuKey !== "" ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    // A click anywhere outside the dock closes its menu.
    HyprlandFocusGrab {
        active: root.menuKey !== ""
        windows: [root]
        onCleared: root.closeMenu()
    }

    // An app that goes away under its open menu closes the menu.
    onKeysChanged: {
        if (menuKey !== "" && keys.indexOf(menuKey) === -1)
            closeMenu();
    }

    // ---- auto-hide ----------------------------------------------------
    // As the bar does it: the window stays mapped, the pill slides below the
    // edge and the input mask shrinks to a thin strip where it was.
    property bool revealed: true
    readonly property bool hidden: Settings.dockAutoHide && !revealed && menuKey === ""
    property real hideShift: hidden ? dockHeight + place.offset - place.stepOver + 4 : 0

    Behavior on hideShift {
        NumberAnimation {
            duration: Theme.expandDuration
            easing.type: Easing.BezierSpline
            easing.bezierCurve: Theme.springCurve
        }
    }

    Timer {
        id: hideTimer
        interval: 1200
        onTriggered: {
            if (Settings.dockAutoHide && !dockHover.hovered && root.menuKey === "")
                root.revealed = false;
        }
    }

    Connections {
        target: Settings

        function onDockAutoHideChanged() {
            if (Settings.dockAutoHide) {
                hideTimer.restart();
            } else {
                hideTimer.stop();
                root.revealed = true;
            }
        }
    }

    onMenuKeyChanged: {
        if (menuKey === "" && Settings.dockAutoHide && !dockHover.hovered)
            hideTimer.restart();
    }

    // A saved auto-hide emits no change while the window is constructed.
    Component.onCompleted: {
        if (Settings.dockAutoHide)
            hideTimer.restart();
    }

    // The pill, plus the open menu. Hidden, only the reveal strip.
    mask: Region {
        item: root.hidden ? revealStrip : dockArea

        Region {
            item: menu
        }
    }

    Item {
        id: revealStrip
        anchors.horizontalCenter: parent.horizontalCenter
        y: root.height - root.place.stepOver - height
        width: parent.width
        height: Math.max(Theme.scaled(6), root.place.offset - root.place.stepOver + 2)
    }

    // Tracks the pointer over whatever the input mask admits.
    Item {
        anchors.fill: parent
        z: 100

        HoverHandler {
            id: dockHover
            blocking: false

            onHoveredChanged: {
                if (hovered) {
                    hideTimer.stop();
                    root.revealed = true;
                } else if (Settings.dockAutoHide) {
                    hideTimer.restart();
                }
            }
        }
    }

    // Everything above a bar the dock steps over. A hiding pill slides down
    // out of this, never across the bar.
    Item {
        id: dockClip
        width: parent.width
        height: Math.max(0, root.height - root.place.stepOver)
        clip: true

        Item {
            id: dockArea

            anchors.horizontalCenter: parent.horizontalCenter
            y: dockClip.height - (root.place.offset - root.place.stepOver) - root.dockHeight
                + root.hideShift
            width: card.width
            height: root.dockHeight

            Rectangle {
                id: card

                width: items.width + root.padding * 2
                height: parent.height
                radius: Theme.panelRadius
                color: Theme.panelSurface
                border.width: Math.max(1, Theme.surfaceBorderWidth)
                border.color: Theme.surfaceBorderWidth > 0 ? Theme.surfaceBorderColor : Theme.stroke

                Row {
                    id: items

                    x: root.padding
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.scaled(2)

                    Repeater {
                        model: root.keys

                        delegate: Item {
                            id: item

                            required property string modelData
                            readonly property bool separator: modelData === "|"
                            readonly property var app: separator ? null : Dock.appByKey[modelData] ?? null
                            readonly property bool focusedApp: app !== null
                                && app.windows.indexOf(Dock.activeAddress) !== -1
                            readonly property string title: app ? Dock.titleFor(app) : ""

                            width: separator ? Theme.scaled(9) : root.itemSize
                            height: root.itemSize

                            Accessible.role: separator ? Accessible.Separator : Accessible.Button
                            Accessible.name: separator ? "" : item.title
                                + (item.focusedApp ? ", focused" : app && app.running ? ", running" : "")
                            Accessible.onPressAction: {
                                if (!item.separator)
                                    Dock.activate(item.modelData);
                            }

                            Rectangle {
                                visible: item.separator
                                anchors.centerIn: parent
                                width: 1
                                height: root.itemSize * 0.6
                                color: Theme.stroke
                            }

                            StateLayer {
                                visible: !item.separator
                                anchors.fill: parent
                                radius: Theme.chipRadius
                                hovered: itemMouse.containsMouse
                                pressed: itemMouse.pressed
                                pressPoint: Qt.point(itemMouse.mouseX, itemMouse.mouseY)
                            }

                            IconImage {
                                visible: !item.separator
                                anchors.centerIn: parent
                                anchors.verticalCenterOffset: -Theme.scaled(2)
                                implicitSize: root.iconSize
                                asynchronous: true
                                source: item.app ? Dock.iconFor(item.app) : ""
                            }

                            // Running apps carry a dot; the focused one a wider,
                            // accent mark — the dock's live status mark.
                            Rectangle {
                                visible: item.app !== null && item.app.running
                                anchors.horizontalCenter: parent.horizontalCenter
                                anchors.bottom: parent.bottom
                                anchors.bottomMargin: Theme.scaled(1)
                                width: item.focusedApp ? Theme.scaled(14) : Theme.scaled(5)
                                height: Theme.scaled(4)
                                radius: height / 2
                                color: item.focusedApp ? Theme.accent : Theme.textMid

                                Behavior on width {
                                    NumberAnimation {
                                        duration: Theme.chipFadeDuration
                                        easing.type: Easing.OutCubic
                                    }
                                }
                            }

                            MouseArea {
                                id: itemMouse
                                anchors.fill: parent
                                enabled: !item.separator
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
                                onClicked: mouse => {
                                    if (mouse.button === Qt.RightButton) {
                                        root.openMenu(item.modelData,
                                            item.mapToItem(null, item.width / 2, 0).x);
                                        return;
                                    }
                                    root.closeMenu();
                                    if (mouse.button === Qt.MiddleButton)
                                        Dock.launch(item.modelData);
                                    else
                                        Dock.activate(item.modelData);
                                }
                            }

                            // The app's name above it while pointed at.
                            Rectangle {
                                visible: itemMouse.containsMouse && root.menuKey === "" && item.title !== ""
                                anchors.horizontalCenter: parent.horizontalCenter
                                y: -height - Theme.scaled(10) - root.padding
                                width: Math.min(nameText.implicitWidth + Theme.scaled(16), Theme.scaled(220))
                                height: nameText.implicitHeight + Theme.scaled(8)
                                radius: Theme.chipRadius
                                color: Theme.surfaceMenu
                                border.width: 1
                                border.color: Theme.stroke

                                Text {
                                    id: nameText
                                    anchors.centerIn: parent
                                    width: Math.min(implicitWidth, Theme.scaled(204))
                                    elide: Text.ElideRight
                                    text: item.title
                                    font.family: Theme.fontMenu
                                    font.pixelSize: Theme.typography.secondary
                                    color: Theme.textHi
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // ---- the item menu ------------------------------------------------
    Item {
        id: menu

        readonly property bool shown: root.menuKey !== "" && root.menuActions.length > 0

        visible: shown
        // Zero-sized while closed, so the mask region it feeds adds nothing.
        width: shown ? menuCard.width : 0
        height: shown ? menuCard.height : 0
        x: Math.max(0, Math.min(root.width - width, root.menuX - width / 2))
        y: dockArea.y - height - Theme.scaled(6)

        Rectangle {
            id: menuCard

            width: Theme.scaled(200)
            height: menuColumn.implicitHeight + Theme.scaled(8)
            radius: Theme.panelRadius
            color: Theme.surfaceMenu
            border.width: 1
            border.color: Theme.stroke

            FocusScope {
                id: menuColumn

                x: Theme.scaled(4)
                y: Theme.scaled(4)
                width: parent.width - Theme.scaled(8)
                implicitHeight: menuRows.implicitHeight
                height: implicitHeight

                Keys.onEscapePressed: root.closeMenu()

                Column {
                    id: menuRows
                    width: parent.width

                    Repeater {
                        model: root.menuActions

                        delegate: Rectangle {
                            id: action

                            required property var modelData
                            required property int index

                            width: menuRows.width
                            height: Theme.listRowHeight
                            radius: Theme.chipRadius
                            color: "transparent"
                            focus: index === 0
                            activeFocusOnTab: true
                            border.width: activeFocus ? 1 : 0
                            border.color: Theme.accentText
                            Accessible.role: Accessible.MenuItem
                            Accessible.name: modelData.label
                            Accessible.onPressAction: action.trigger()

                            function trigger() {
                                const key = root.menuKey;
                                root.closeMenu();
                                Dock.runAction(key, action.modelData.id);
                            }

                            Keys.onPressed: event => {
                                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                                        || event.key === Qt.Key_Space) {
                                    action.trigger();
                                    event.accepted = true;
                                } else if (event.key === Qt.Key_Down || event.key === Qt.Key_Up) {
                                    const next = action.nextItemInFocusChain(event.key === Qt.Key_Down);
                                    if (next)
                                        next.forceActiveFocus();
                                    event.accepted = true;
                                }
                            }

                            StateLayer {
                                anchors.fill: parent
                                radius: parent.radius
                                hovered: actionMouse.containsMouse
                                pressed: actionMouse.pressed
                                pressPoint: Qt.point(actionMouse.mouseX, actionMouse.mouseY)
                            }

                            Sym {
                                id: actionGlyph
                                anchors.left: parent.left
                                anchors.leftMargin: Theme.scaled(10)
                                anchors.verticalCenter: parent.verticalCenter
                                name: action.modelData.glyph
                                size: Theme.iconMedium
                                color: Theme.textMid
                            }

                            Text {
                                anchors.left: actionGlyph.right
                                anchors.leftMargin: Theme.scaled(10)
                                anchors.right: parent.right
                                anchors.rightMargin: Theme.scaled(10)
                                anchors.verticalCenter: parent.verticalCenter
                                elide: Text.ElideRight
                                text: action.modelData.label
                                font.family: Theme.fontMenu
                                font.pixelSize: Theme.typography.control
                                color: Theme.textHi
                            }

                            MouseArea {
                                id: actionMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: action.trigger()
                            }
                        }
                    }
                }
            }
        }
    }
}
