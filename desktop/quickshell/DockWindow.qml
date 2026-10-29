pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import Quickshell.Widgets
import "Common"
import "Common/BarGeometry.js" as BarGeometry
import "Common/DockHelpers.js" as DockHelpers
import "Common/WindowCommands.js" as WindowCommands
import Qt.labs.folderlistmodel

// The dock (automatic on Floating; Settings → Workspaces & dock → Dock for all layouts): pinned and
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
//
// The Mac-like desktop style (Settings → Appearance) draws it as a Mac dock:
// icons grow under the pointer and bounce while an app starts, running apps
// carry a small dot, and after a divider come the minimized windows, as
// thumbnails, and the Trash.
PanelWindow {
    id: root

    required property var modelData

    readonly property bool mac: Theme.macStyle
    readonly property int iconSize: mac ? itemSize - Theme.scaled(4) : Theme.scaled(36)
    readonly property int itemSize: Theme.scaled(48)
    readonly property int padding: mac ? Theme.scaled(5) : Theme.scaled(6)
    readonly property int dockHeight: itemSize + padding * 2
    readonly property int gap: Theme.scaled(8)
    readonly property int headroom: Theme.scaled(160)
    readonly property bool barShown: !OmarchyPlugins.replacementActive
    readonly property var place: DockHelpers.placement({
        barPosition: barShown ? Settings.position : "top",
        barDepth: Theme.barTopMargin + Theme.barHeight,
        barZone: BarGeometry.exclusiveZone({
            style: Settings.effectiveBarStyle,
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
    // The Mac-like dock's tail: a divider, each minimized window, the Trash.
    readonly property var minimizedKeys: mac && DesktopWorkspaces.ready
        ? DesktopWorkspaces.snapshot.minimized
            .filter(row => DesktopWorkspaces.isLive(row.address))
            .map(row => "min:" + row.address)
        : []
    readonly property var dockKeys: mac
        ? keys.concat(keys.length > 0 ? ["|"] : [], minimizedKeys, ["trash"]) : keys

    // ---- magnification ------------------------------------------------
    // Each item's size follows its distance from the pointer, measured
    // against where the items rest rather than where they are drawn, so the
    // growth they cause cannot feed back into what grows.
    readonly property int separatorWidth: Theme.scaled(9)
    readonly property int itemSpacing: mac ? Theme.scaled(4) : Theme.scaled(2)
    readonly property real magnifyMax: mac && !Theme.reducedMotion ? 1.6 : 1
    readonly property real magnifyRange: itemSize * 2.6
    readonly property var restLayout: {
        const widths = dockKeys.map(key => key === "|" ? separatorWidth : itemSize);
        const total = widths.reduce((sum, width) => sum + width, 0)
            + itemSpacing * Math.max(0, widths.length - 1);
        let x = -total / 2;
        const centres = widths.map(width => {
            const centre = x + width / 2;
            x += width + itemSpacing;
            return centre;
        });
        return { centres: centres, total: total };
    }
    readonly property real pointerX: magnifyMax > 1 && dockHover.hovered && menuKey === ""
        ? dockHover.point.position.x - width / 2 : NaN
    // Where the pointer is over the dock, in window coordinates. The hover
    // layer above the items takes the pointer's hover events, so items learn
    // that they are pointed at from here, as the menubar's widgets do from
    // its own layer; their MouseAreas never see a hover.
    readonly property point pointerAt: dockHover.hovered ? dockHover.point.position : Qt.point(-1, -1)

    function magnification(index) {
        if (isNaN(pointerX) || index >= restLayout.centres.length)
            return 1;
        const distance = Math.abs(pointerX - restLayout.centres[index]);
        if (distance >= magnifyRange)
            return 1;
        return 1 + (magnifyMax - 1) * (Math.cos(Math.PI * distance / magnifyRange) + 1) / 2;
    }

    // The Trash: full or empty, opened in the file manager.
    readonly property string trashFolder: "file://" + (Quickshell.env("XDG_DATA_HOME")
        || Quickshell.env("HOME") + "/.local/share") + "/Trash/files"
    FolderListModel {
        id: trashFiles
        folder: root.mac ? root.trashFolder : ""
        showHidden: true
        showDotAndDotDot: false
    }

    function openTrash() {
        Quickshell.execDetached(["gio", "open", "trash:///"]);
    }

    // Where a window being minimized lands (Minimizer.qml): the start of the
    // Trash, where its thumbnail appears, in this output's coordinates.
    property Item trashTile: null

    function publishTarget() {
        if (!mac || !trashTile || !screen)
            return;
        const at = trashTile.mapToItem(null, 0, 0);
        Minimizer.setTarget(screen.name, Qt.rect((screen.width - width) / 2 + at.x,
            screen.height - height + at.y, itemSize, itemSize));
    }

    Timer {
        id: targetTimer
        interval: 300
        onTriggered: root.publishTarget()
    }

    onDockKeysChanged: targetTimer.restart()
    onWidthChanged: targetTimer.restart()

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
    visible: dockKeys.length > 0
    anchors.bottom: true
    exclusionMode: ExclusionMode.Normal
    exclusiveZone: place.exclusiveZone
    // Room either side of the pill for a name or menu over an end item. The
    // Mac-like dock holds its widest magnified extent, so pointing at it never
    // resizes the surface.
    implicitWidth: (mac ? restLayout.total + padding * 2 + itemSize * (magnifyMax - 1) * 3
        : card.width) + Theme.scaled(240)
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

        Region {
            item: magnifyRegion
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

            // The room magnified icons grow into, part of the input region
            // only while the pointer is on the dock.
            Item {
                id: magnifyRegion
                y: -height
                width: card.width
                height: root.mac && !isNaN(root.pointerX)
                    ? Math.ceil(root.itemSize * (root.magnifyMax - 1)) : 0
            }

            Rectangle {
                id: card

                width: items.width + root.padding * 2
                height: parent.height
                radius: root.mac ? Theme.scaled(18) : Theme.panelRadius
                color: Theme.panelSurface
                border.width: Math.max(1, Theme.surfaceBorderWidth)
                border.color: Theme.surfaceBorderWidth > 0 ? Theme.surfaceBorderColor : Theme.stroke

                Row {
                    id: items

                    x: root.padding
                    // Items rest on the pill's floor so a magnified one grows
                    // upward out of it.
                    y: card.height - root.padding - height
                    spacing: root.itemSpacing

                    Repeater {
                        model: root.dockKeys

                        delegate: Item {
                            id: item

                            required property string modelData
                            required property int index
                            readonly property bool separator: modelData === "|"
                            readonly property bool trash: modelData === "trash"
                            readonly property string minimizedAddress: modelData.indexOf("min:") === 0
                                ? modelData.slice(4) : ""
                            readonly property var window: minimizedAddress === "" ? null
                                : Hyprland.toplevels.values.find(toplevel =>
                                    WindowCommands.bareAddress(toplevel.address) === minimizedAddress) ?? null
                            readonly property var windowApp: window
                                ? Dock.apps.find(app => app.windows.indexOf(window.address) !== -1) ?? null : null
                            readonly property var app: separator || trash || minimizedAddress !== "" ? null
                                : Dock.appByKey[modelData] ?? null
                            readonly property bool focusedApp: app !== null
                                && app.windows.indexOf(Dock.activeAddress) !== -1
                            readonly property bool minimizedApp: app !== null && app.windows.length > 0
                                && app.windows.every(address => DesktopWorkspaces.isMinimized(address))
                            readonly property string title: app ? Dock.titleFor(app)
                                : window ? (window.title !== "" ? window.title
                                    : windowApp ? Dock.titleFor(windowApp) : "")
                                : trash ? I18n.tr("Trash") : ""
                            readonly property real zoom: separator ? 1 : root.magnification(index)
                            readonly property bool pointed: {
                                const at = root.pointerAt;
                                if (separator || at.x < 0)
                                    return false;
                                // Magnification moves the items under a still
                                // pointer; follow where this one is drawn.
                                void x;
                                void width;
                                void items.x;
                                const local = tile.mapFromItem(null, at.x, at.y);
                                return local.x >= 0 && local.y >= 0
                                    && local.x <= tile.width && local.y <= tile.height;
                            }
                            readonly property real tileSize: root.itemSize * zoom
                            // A launch bounces until the app is running.
                            property real bounce: 0
                            readonly property bool running: app !== null && app.running

                            function startBounce() {
                                if (root.mac && !Theme.reducedMotion)
                                    bounceAnimation.restart();
                            }

                            onRunningChanged: {
                                if (running)
                                    bounceAnimation.stop();
                            }

                            width: separator ? root.separatorWidth : tileSize
                            height: root.itemSize * root.magnifyMax

                            Behavior on width {
                                enabled: isNaN(root.pointerX)
                                NumberAnimation {
                                    duration: Theme.chipFadeDuration
                                    easing.type: Easing.OutCubic
                                }
                            }

                            SequentialAnimation {
                                id: bounceAnimation
                                loops: 3
                                alwaysRunToEnd: true
                                NumberAnimation {
                                    target: item
                                    property: "bounce"
                                    to: -root.itemSize * 0.4
                                    duration: Theme.expandDuration
                                    easing.type: Easing.OutQuad
                                }
                                NumberAnimation {
                                    target: item
                                    property: "bounce"
                                    to: 0
                                    duration: Theme.expandDuration
                                    easing.type: Easing.InQuad
                                }
                            }

                            Accessible.role: separator ? Accessible.Separator : Accessible.Button
                            Accessible.name: separator ? "" : item.title
                                + (item.minimizedApp || item.minimizedAddress !== ""
                                    ? ", " + I18n.tr("Minimized") : "")
                                + (item.focusedApp ? ", focused" : app && app.running ? ", running" : "")
                            Accessible.onPressAction: item.activate(Qt.LeftButton)

                            function activate(button) {
                                if (separator)
                                    return;
                                if (trash) {
                                    root.openTrash();
                                } else if (minimizedAddress !== "") {
                                    DesktopWorkspaces.activate(minimizedAddress);
                                } else if (button === Qt.MiddleButton) {
                                    item.startBounce();
                                    Dock.launch(modelData);
                                } else {
                                    if (app && !app.running)
                                        item.startBounce();
                                    Dock.activate(modelData);
                                }
                            }

                            Rectangle {
                                visible: item.separator
                                anchors.horizontalCenter: parent.horizontalCenter
                                anchors.bottom: parent.bottom
                                anchors.bottomMargin: root.itemSize * 0.2
                                width: 1
                                height: root.itemSize * 0.6
                                color: Theme.stroke
                            }

                            Component.onCompleted: {
                                if (trash) {
                                    root.trashTile = tile;
                                    targetTimer.restart();
                                }
                            }
                            Component.onDestruction: {
                                if (root.trashTile === tile)
                                    root.trashTile = null;
                            }

                            Item {
                                id: tile
                                visible: !item.separator
                                anchors.horizontalCenter: parent.horizontalCenter
                                anchors.bottom: parent.bottom
                                width: item.tileSize
                                height: item.tileSize

                                transform: Translate {
                                    y: item.bounce
                                }

                                StateLayer {
                                    visible: !root.mac
                                    anchors.fill: parent
                                    radius: Theme.chipRadius
                                    hovered: item.pointed
                                    pressed: itemMouse.pressed
                                    pressPoint: Qt.point(itemMouse.mouseX, itemMouse.mouseY)
                                }

                                IconImage {
                                    visible: !item.trash && (item.minimizedAddress === "" || !capture.hasContent)
                                    anchors.centerIn: parent
                                    anchors.verticalCenterOffset: root.mac ? 0 : -Theme.scaled(2)
                                    implicitSize: root.iconSize * item.zoom
                                    asynchronous: true
                                    source: item.app ? Dock.iconFor(item.app)
                                        : item.windowApp ? Dock.iconFor(item.windowApp) : ""
                                }

                                // The Trash is drawn here rather than taken from the
                                // icon theme: Adwaita keeps only a symbolic one. A
                                // glassy bin, with paper in it while it holds files.
                                Item {
                                    id: trashArt
                                    visible: item.trash
                                    anchors.centerIn: parent
                                    width: parent.width * 0.6
                                    height: parent.height * 0.78

                                    Repeater {
                                        model: trashFiles.count > 0 ? 3 : 0
                                        delegate: Rectangle {
                                            required property int index
                                            x: trashArt.width * (0.18 + index * 0.2)
                                            y: trashArt.height * 0.02
                                            width: trashArt.width * 0.32
                                            height: trashArt.height * 0.22
                                            rotation: -14 + index * 14
                                            radius: 2
                                            color: "#f8f8fa"
                                            border.width: 1
                                            border.color: Qt.rgba(0, 0, 0, 0.12)
                                        }
                                    }

                                    Rectangle {
                                        id: trashBody
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        y: trashLid.y + trashLid.height * 0.6
                                        width: parent.width * 0.86
                                        height: parent.height - y
                                        radius: width * 0.14
                                        border.width: 1
                                        border.color: Qt.rgba(1, 1, 1, 0.85)
                                        gradient: Gradient {
                                            GradientStop { position: 0; color: Qt.rgba(0.96, 0.97, 0.98, 0.88) }
                                            GradientStop { position: 1; color: Qt.rgba(0.74, 0.77, 0.83, 0.82) }
                                        }

                                        Repeater {
                                            model: 3
                                            delegate: Rectangle {
                                                required property int index
                                                x: trashBody.width * (0.3 + index * 0.2) - width / 2
                                                y: trashBody.height * 0.12
                                                width: Math.max(1, trashBody.width * 0.05)
                                                height: trashBody.height * 0.74
                                                radius: width / 2
                                                color: Qt.rgba(0.45, 0.49, 0.57, 0.45)
                                            }
                                        }
                                    }

                                    Rectangle {
                                        id: trashLid
                                        y: parent.height * 0.18
                                        width: parent.width
                                        height: Math.max(3, parent.height * 0.1)
                                        radius: height / 2
                                        color: "#eef1f5"
                                        border.width: 1
                                        border.color: Qt.rgba(0, 0, 0, 0.12)
                                    }
                                }

                                // A minimized window shows its last frame, with its
                                // app's icon in the corner as a Mac dock does.
                                ScreencopyView {
                                    id: capture
                                    visible: item.minimizedAddress !== "" && hasContent
                                    anchors.centerIn: parent
                                    width: parent.width * 0.9
                                    height: sourceSize.width > 0
                                        ? Math.min(parent.height * 0.9, width * sourceSize.height / sourceSize.width)
                                        : parent.height * 0.7
                                    captureSource: item.window ? item.window.wayland : null
                                    live: false
                                    paintCursor: false
                                }

                                IconImage {
                                    visible: item.minimizedAddress !== "" && capture.hasContent
                                    anchors.right: parent.right
                                    anchors.bottom: parent.bottom
                                    implicitSize: parent.width * 0.42
                                    asynchronous: true
                                    source: item.windowApp ? Dock.iconFor(item.windowApp) : ""
                                }

                                // Running apps carry a dot; in the Cybex style the
                                // focused one a wider accent mark.
                                Rectangle {
                                    visible: item.app !== null && item.app.running
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    y: root.mac ? parent.height + Theme.scaled(1)
                                        : parent.height - height - Theme.scaled(1)
                                    width: root.mac ? Theme.scaled(4)
                                        : item.focusedApp ? Theme.scaled(14) : Theme.scaled(5)
                                    height: Theme.scaled(4)
                                    radius: height / 2
                                    color: item.focusedApp && !root.mac ? Theme.accent : Theme.textMid
                                    opacity: item.minimizedApp ? 0.5 : 1

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
                                            if (item.app !== null)
                                                root.openMenu(item.modelData,
                                                    item.mapToItem(null, item.width / 2, 0).x);
                                            return;
                                        }
                                        root.closeMenu();
                                        item.activate(mouse.button);
                                    }
                                }

                                // The app's name above it while pointed at.
                                Rectangle {
                                    visible: item.pointed && root.menuKey === "" && item.title !== ""
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

                            // Pointed at, from the hover layer (see pointerAt).
                            readonly property bool pointed: {
                                const at = root.pointerAt;
                                if (at.x < 0)
                                    return false;
                                void menu.y;
                                const local = action.mapFromItem(null, at.x, at.y);
                                return local.x >= 0 && local.y >= 0
                                    && local.x <= action.width && local.y <= action.height;
                            }

                            StateLayer {
                                anchors.fill: parent
                                radius: parent.radius
                                hovered: action.pointed
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
