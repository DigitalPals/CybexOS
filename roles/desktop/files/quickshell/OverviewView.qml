pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import Quickshell.Widgets
import "Common"
import "Common/LauncherProviders.js" as LauncherHelpers
import "Common/OverviewHelpers.js" as OverviewHelpers
import "Common/WindowCommands.js" as WindowCommands

// The overview's content, constructed only while OverviewWindow is mapped.
// Workspaces are a grid of tiles, each holding its windows as live captures
// placed where they sit on the monitor (OverviewHelpers.windowRects).
//
//   click / Enter        focus the window, switching workspace
//   arrows, Tab          move the selection
//   typing               filter by title or class (the launcher's ranking)
//   drag a thumbnail     move the window to another workspace
//   Esc                  clear the filter, then close (Super+Tab closes too)
//
// Tiles and thumbnails are keyed by workspace id and window address, so a
// title change or a focus event updates bindings instead of recreating a
// capture, and a window that closes while the overview is up just leaves.
FocusScope {
    id: root

    required property ShellScreen output

    focus: true

    // ---- live state ------------------------------------------------------
    readonly property var toplevels: Hyprland.toplevels.values
    readonly property var toplevelByAddress: {
        const map = {};
        for (const toplevel of toplevels)
            map[toplevel.address] = toplevel;
        return map;
    }
    // Plain records for the helpers. A window on a special workspace (the
    // scratchpad) or one hidden behind its group's active tab is left out.
    readonly property var windows: toplevels.map(toplevel => root.record(toplevel))
        .filter(entry => entry !== null)
    readonly property var workspaceRecords: Hyprland.workspaces.values.map(workspace => ({
        id: workspace.id,
        name: workspace.name,
        monitor: workspace.monitor ? workspace.monitor.name : "",
        active: workspace.active
    }))
    readonly property var entries: OverviewHelpers.workspaceEntries(workspaceRecords, windows)
    // Tiles are recreated only when the set of workspaces changes.
    readonly property string tilesKey: JSON.stringify(entries.map(entry => ({
        id: entry.id, name: entry.name, monitor: entry.monitor, isNew: entry.isNew
    })))
    readonly property var tiles: JSON.parse(tilesKey)
    readonly property int focusedWorkspaceId: Hyprland.focusedWorkspace
        ? Hyprland.focusedWorkspace.id : -1

    readonly property real outputAspect: output.width / Math.max(1, output.height)
    readonly property var layout: OverviewHelpers.gridLayout(tiles.length,
        grid.width, grid.height, outputAspect, {
            spacing: Theme.scaled(28),
            labelHeight: Theme.scaled(32),
            maxTileWidth: output.width * 0.42
        })
    // Each tile's letterboxed box and window rects, and every thumbnail's
    // placement in grid coordinates for keyboard navigation.
    readonly property var geometry: {
        const perTile = [];
        const placements = [];
        const cells = layout.cells;
        for (let index = 0; index < tiles.length; index++) {
            const tile = tiles[index];
            const cell = cells[index];
            if (!cell) {
                perTile.push(null);
                continue;
            }
            const monitor = monitorGeometry(tile.isNew ? "" : tile.monitor);
            const box = OverviewHelpers.fitAspect(cell.width, cell.tileHeight,
                monitor.width / Math.max(1, monitor.height));
            const inTile = tile.isNew ? []
                : windows.filter(entry => entry.workspaceId === tile.id);
            const rects = OverviewHelpers.windowRects(inTile, monitor, box.width, box.height,
                { minSize: Theme.scaled(14) });
            perTile.push({
                box: box,
                rects: rects,
                key: JSON.stringify(inTile.map(entry => entry.address).sort())
            });
            for (const entry of inTile)
                placements.push({ address: entry.address, cellIndex: index, cell: cell,
                    offsetX: box.x, offsetY: box.y, rect: rects[entry.address] });
        }
        return { perTile: perTile, placements: placements };
    }

    property string query: ""
    readonly property var scores: OverviewHelpers.filterScores(windows, query,
        LauncherHelpers.windowScore)
    readonly property var items: OverviewHelpers.selectionItems(geometry.placements, scores)
    readonly property bool anyMatch: items.some(item => item.enabled)
    property string selected: ""
    // Read once as the overview opens: an exclusive overlay can take the
    // compositor's notion of the focused window with it.
    property string initialActive: ""

    // ---- drag to another workspace --------------------------------------
    property string dragAddress: ""
    property point dragPoint: Qt.point(0, 0)
    readonly property int dropIndex: dragAddress === "" ? -1
        : OverviewHelpers.cellAt(layout.cells, dragPoint.x - grid.x, dragPoint.y - grid.y)

    function record(toplevel) {
        const workspace = toplevel.workspace;
        if (!workspace || OverviewHelpers.isSpecialWorkspace({ id: workspace.id, name: workspace.name }))
            return null;
        const ipc = toplevel.lastIpcObject || {};
        if (ipc.mapped === false || ipc.hidden === true)
            return null;
        const wayland = toplevel.wayland;
        return {
            address: toplevel.address,
            workspaceId: workspace.id,
            title: toplevel.title || "",
            appClass: (wayland && wayland.appId) || ipc.class || ipc.initialClass || "",
            at: ipc.at,
            size: ipc.size,
            floating: ipc.floating === true,
            // 1 is maximized, which keeps its tiled geometry; 2 and 3 cover
            // the monitor.
            fullscreen: ipc.fullscreen === true || Number(ipc.fullscreen) >= 2,
            focusHistoryID: ipc.focusHistoryID,
            activated: toplevel.activated
        };
    }

    function monitorGeometry(name) {
        const screen = (name !== "" ? Screens.byName(name) : null) ?? root.output;
        return { x: screen.x, y: screen.y, width: screen.width, height: screen.height };
    }

    function iconFor(appClass) {
        if (appClass === "")
            return "";
        const entry = DesktopEntries.heuristicLookup(appClass);
        return Quickshell.iconPath(entry && entry.icon ? entry.icon : appClass,
            "application-x-executable");
    }

    function windowFor(address) {
        return windows.find(entry => entry.address === address) ?? null;
    }

    function settleSelection() {
        selected = OverviewHelpers.reselect(items, selected, scores, initialActive, query);
    }

    function move(direction) {
        const index = OverviewHelpers.indexOfAddress(items, selected);
        const next = direction === "next" || direction === "previous"
            ? OverviewHelpers.step(items, index, direction === "next" ? 1 : -1)
            : OverviewHelpers.navigate(items, index, direction);
        if (next >= 0)
            selected = items[next].address;
    }

    // Hyprland falls back to the active window when a selector does not
    // resolve, so every dispatch first checks the window is still here.
    function activateWindow(address) {
        const command = root.toplevelByAddress[address] ? WindowCommands.focusWindow(address) : "";
        if (command === "")
            return;
        Overview.close();
        Hyprland.dispatch(command);
    }

    function activateWorkspace(tile) {
        const command = WindowCommands.focusWorkspace(tile);
        if (command === "")
            return;
        Overview.close();
        Hyprland.dispatch(command);
    }

    function beginDrag(address, point) {
        dragAddress = address;
        dragPoint = point;
    }

    function finishDrag() {
        const address = dragAddress;
        const tile = dropIndex >= 0 ? tiles[dropIndex] : null;
        const source = windowFor(address);
        dragAddress = "";
        if (!tile || !source || !root.toplevelByAddress[address]
                || (!tile.isNew && tile.id === source.workspaceId))
            return;
        const command = WindowCommands.moveWindow(address, tile);
        if (command !== "")
            Hyprland.dispatch(command);
    }

    onItemsChanged: settleSelection()
    onQueryChanged: settleSelection()
    Component.onCompleted: {
        initialActive = Hyprland.activeToplevel ? Hyprland.activeToplevel.address : "";
        settleSelection();
        filterInput.forceActiveFocus();
    }

    // A dragged window that closes mid-drag cancels the drag.
    onToplevelByAddressChanged: {
        if (dragAddress !== "" && !toplevelByAddress[dragAddress])
            dragAddress = "";
    }

    // Window geometry arrives only with a toplevel refresh (see Overview.qml).
    // While the overview is up, re-read it after anything that re-tiles.
    readonly property var refreshEvents: ["openwindow", "closewindow", "movewindowv2",
        "changefloatingmode", "fullscreen", "moveworkspacev2"]

    Connections {
        target: Hyprland

        function onRawEvent(event) {
            if (root.refreshEvents.indexOf(event.name) !== -1)
                refreshTimer.restart();
        }
    }

    Timer {
        id: refreshTimer
        interval: 80
        onTriggered: Hyprland.refreshToplevels()
    }

    // ---- backdrop: the wallpaper, dimmed --------------------------------
    Rectangle {
        anchors.fill: parent
        color: Theme.panelSurface
    }

    Image {
        id: backdrop
        anchors.fill: parent
        source: Wallpaper.current !== "" ? Wallpaper.url(Wallpaper.current) : ""
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: true
        // The wallpaper layer decodes the same file at this size, so both
        // share one cached image.
        sourceSize.width: Math.ceil(root.output.width * root.output.devicePixelRatio)
        sourceSize.height: Math.ceil(root.output.height * root.output.devicePixelRatio)
    }

    Rectangle {
        anchors.fill: parent
        color: Theme.scrim
    }

    // A click on the backdrop, outside every tile, closes the overview.
    MouseArea {
        anchors.fill: parent
        cursorShape: Qt.ArrowCursor
        onClicked: Overview.close()
    }

    // ---- filter ----------------------------------------------------------
    Rectangle {
        id: filterField

        anchors.horizontalCenter: parent.horizontalCenter
        y: Theme.scaled(36)
        width: Math.min(Theme.scaled(420), root.width - Theme.scaled(48))
        height: Theme.scaled(40)
        radius: height / 2
        color: Theme.chip
        border.width: 1
        border.color: Theme.stroke

        // A click on the field keeps the overview open and the caret in it.
        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.IBeamCursor
            onClicked: filterInput.forceActiveFocus()
        }

        Sym {
            id: searchGlyph
            anchors.left: parent.left
            anchors.leftMargin: Theme.scaled(14)
            anchors.verticalCenter: parent.verticalCenter
            name: "search"
            size: Theme.iconMedium
            color: Theme.textMid
        }

        TextInput {
            id: filterInput

            anchors.left: searchGlyph.right
            anchors.leftMargin: Theme.controlSpacing
            anchors.right: parent.right
            anchors.rightMargin: Theme.scaled(14)
            anchors.verticalCenter: parent.verticalCenter
            focus: true
            clip: true
            font.family: Theme.fontMenu
            font.pixelSize: Theme.typography.control
            color: Theme.textHi
            selectionColor: Theme.accentAlpha(0.35)
            Accessible.role: Accessible.EditableText
            Accessible.name: I18n.tr("Filter windows")
            onTextChanged: root.query = text

            Keys.onPressed: event => {
                switch (event.key) {
                case Qt.Key_Escape:
                    if (filterInput.text !== "")
                        filterInput.text = "";
                    else
                        Overview.close();
                    break;
                case Qt.Key_Return:
                case Qt.Key_Enter:
                    root.activateWindow(root.selected);
                    break;
                case Qt.Key_Left:
                    root.move("left");
                    break;
                case Qt.Key_Right:
                    root.move("right");
                    break;
                case Qt.Key_Up:
                    root.move("up");
                    break;
                case Qt.Key_Down:
                    root.move("down");
                    break;
                case Qt.Key_Tab:
                    root.move("next");
                    break;
                case Qt.Key_Backtab:
                    root.move("previous");
                    break;
                default:
                    return;
                }
                event.accepted = true;
            }

            Text {
                anchors.fill: parent
                verticalAlignment: Text.AlignVCenter
                visible: filterInput.text === ""
                text: I18n.tr("Type to filter windows")
                elide: Text.ElideRight
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.control
                color: Theme.textFaint
            }
        }
    }

    Text {
        id: status
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: filterField.bottom
        anchors.topMargin: Theme.controlSpacing
        text: root.windows.length === 0 ? "No open windows"
            : !root.anyMatch ? "No windows match “" + root.query.trim() + "”"
            : "Enter to switch · drag to move · Esc to close"
        font.family: Theme.fontMenu
        font.pixelSize: Theme.typography.secondary
        color: Theme.textMid
    }

    // ---- workspace grid --------------------------------------------------
    Item {
        id: grid

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: status.bottom
        anchors.bottom: parent.bottom
        anchors.leftMargin: Theme.scaled(48)
        anchors.rightMargin: Theme.scaled(48)
        anchors.topMargin: Theme.scaled(24)
        anchors.bottomMargin: Theme.scaled(48)
        scale: Overview.open ? 1 : 0.97

        Behavior on scale {
            NumberAnimation {
                duration: Theme.panelMotionDuration
                easing.type: Easing.BezierSpline
                easing.bezierCurve: Theme.springCurve
            }
        }

        Repeater {
            model: root.tiles

            delegate: Item {
                id: tile

                required property var modelData
                required property int index
                readonly property var cell: root.layout.cells[index] ?? null
                readonly property var placement: root.geometry.perTile[index] ?? null
                readonly property bool current: !modelData.isNew
                    && modelData.id === root.focusedWorkspaceId
                readonly property bool dropTarget: root.dropIndex === index
                // A tile's thumbnails are keyed by address alone. The string
                // notifies only when the set really changes; `placement` is a
                // fresh object on every geometry pass and would rebuild every
                // capture each time.
                readonly property string addressesKey: placement ? placement.key : "[]"
                readonly property var addresses: JSON.parse(addressesKey)

                visible: cell !== null && placement !== null
                x: cell ? cell.x : 0
                y: cell ? cell.y : 0
                width: cell ? cell.width : 0
                height: cell ? cell.height : 0

                Row {
                    id: label
                    x: tile.placement ? tile.placement.box.x : 0
                    height: tile.cell ? tile.cell.tileY : 0
                    spacing: Theme.iconTextSpacing

                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: !tile.modelData.isNew
                        width: Math.max(height, number.implicitWidth + Theme.scaled(12))
                        height: Theme.chipInnerHeight
                        radius: Theme.chipRadius
                        // The current workspace wears the accent pill, as on the bar.
                        color: tile.current ? Theme.accent : Theme.chip

                        Text {
                            id: number
                            anchors.centerIn: parent
                            text: tile.modelData.id > 0 ? String(tile.modelData.id) : tile.modelData.name
                            font.family: Theme.fontMenu
                            font.pixelSize: Theme.typography.secondary
                            font.weight: Theme.weightSemibold
                            font.features: Theme.tabularNumberFeatures
                            color: tile.current ? Theme.accentFg : Theme.textHi
                        }
                    }

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: tile.modelData.isNew ? "New workspace"
                            : tile.current ? "Current"
                            : tile.modelData.monitor !== "" && Quickshell.screens.length > 1
                            ? tile.modelData.monitor : ""
                        font.family: Theme.fontMenu
                        font.pixelSize: Theme.typography.secondary
                        color: Theme.textMid
                    }
                }

                Item {
                    id: surface

                    readonly property real radius: Theme.scaled(10)

                    x: tile.placement ? tile.placement.box.x : 0
                    y: (tile.cell ? tile.cell.tileY : 0) + (tile.placement ? tile.placement.box.y : 0)
                    width: tile.placement ? tile.placement.box.width : 0
                    height: tile.placement ? tile.placement.box.height : 0

                    // The workspace's own wallpaper. Only this static layer is
                    // clipped to the rounded corner: a clipping rectangle
                    // re-renders its content offscreen on every change, which
                    // around live captures would be every frame.
                    ClippingRectangle {
                        anchors.fill: parent
                        visible: !tile.modelData.isNew
                        radius: surface.radius
                        color: Theme.chip

                        Image {
                            anchors.fill: parent
                            source: backdrop.source
                            sourceSize: backdrop.sourceSize
                            fillMode: Image.PreserveAspectCrop
                            asynchronous: true
                            cache: true
                            mipmap: true
                        }
                    }

                    // An empty part of a tile switches to that workspace.
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.activateWorkspace(tile.modelData)
                    }

                    Sym {
                        anchors.centerIn: parent
                        visible: tile.modelData.isNew
                        name: "add"
                        size: Theme.iconLarge
                        color: Theme.textMid
                    }

                    Item {
                        anchors.fill: parent
                        clip: true

                        Repeater {
                            model: tile.addresses

                            delegate: Item {
                                id: thumb

                                required property string modelData
                                readonly property string address: modelData
                                readonly property var toplevel: root.toplevelByAddress[address] ?? null
                                readonly property var info: root.windowFor(address)
                                readonly property var rect: tile.placement
                                    ? tile.placement.rects[address] ?? null : null
                                readonly property bool matches: Object.prototype.hasOwnProperty.call(
                                    root.scores, address)
                                readonly property bool chosen: root.selected === address
                                readonly property bool dragged: root.dragAddress === address

                                visible: rect !== null
                                x: rect ? rect.x : 0
                                y: rect ? rect.y : 0
                                z: rect ? rect.z : 0
                                width: rect ? rect.width : 0
                                height: rect ? rect.height : 0
                                opacity: dragged ? 0.35 : matches ? 1 : 0.3

                                Accessible.role: Accessible.Button
                                Accessible.name: (info ? info.title || info.appClass : "Window")
                                    + ", workspace " + tile.modelData.name
                                Accessible.onPressAction: root.activateWindow(thumb.address)

                                Rectangle {
                                    anchors.fill: parent
                                    color: Theme.chip
                                    visible: !capture.hasContent

                                    IconImage {
                                        anchors.centerIn: parent
                                        implicitSize: Math.min(Theme.scaled(40), parent.width * 0.5,
                                            parent.height * 0.5)
                                        source: root.iconFor(thumb.info ? thumb.info.appClass : "")
                                    }
                                }

                                // Live only while the overview is open; the
                                // closing fade shows the last frame.
                                ScreencopyView {
                                    id: capture
                                    anchors.fill: parent
                                    captureSource: thumb.toplevel ? thumb.toplevel.wayland : null
                                    live: Overview.open
                                    paintCursor: false
                                }

                                Rectangle {
                                    anchors.fill: parent
                                    color: "transparent"
                                    border.width: thumb.chosen ? 2 : 1
                                    border.color: thumb.chosen ? Theme.accentText : Theme.stroke
                                }

                                // The selected window names itself.
                                Rectangle {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    anchors.bottom: parent.bottom
                                    anchors.bottomMargin: Theme.scaled(6)
                                    visible: thumb.chosen && thumb.info !== null
                                        && thumb.height > Theme.scaled(48)
                                    width: Math.min(parent.width - Theme.scaled(12),
                                        titleText.implicitWidth + Theme.scaled(16))
                                    height: titleText.implicitHeight + Theme.scaled(8)
                                    radius: Theme.chipRadius
                                    color: Theme.surfaceMenu

                                    Text {
                                        id: titleText
                                        anchors.centerIn: parent
                                        width: parent.width - Theme.scaled(16)
                                        horizontalAlignment: Text.AlignHCenter
                                        elide: Text.ElideRight
                                        text: thumb.info ? (thumb.info.title || thumb.info.appClass) : ""
                                        font.family: Theme.fontMenu
                                        font.pixelSize: Theme.typography.secondary
                                        color: Theme.textHi
                                    }
                                }

                                MouseArea {
                                    id: thumbMouse

                                    property point pressAt: Qt.point(0, 0)
                                    // Set once a press turns into a drag, so the
                                    // click that ends it does not also focus.
                                    property bool dragging: false

                                    anchors.fill: parent
                                    hoverEnabled: true
                                    preventStealing: true
                                    cursorShape: thumb.dragged ? Qt.ClosedHandCursor : Qt.PointingHandCursor
                                    onEntered: {
                                        if (thumb.matches && root.dragAddress === "")
                                            root.selected = thumb.address;
                                    }
                                    onPressed: mouse => {
                                        pressAt = Qt.point(mouse.x, mouse.y);
                                        dragging = false;
                                    }
                                    onPositionChanged: mouse => {
                                        if (!pressed)
                                            return;
                                        const point = mapToItem(root, mouse.x, mouse.y);
                                        if (!dragging && Math.hypot(mouse.x - pressAt.x,
                                                mouse.y - pressAt.y) > Theme.scaled(8)) {
                                            dragging = true;
                                            root.beginDrag(thumb.address, point);
                                        } else if (dragging) {
                                            root.dragPoint = point;
                                        }
                                    }
                                    onReleased: {
                                        if (dragging)
                                            root.finishDrag();
                                    }
                                    onCanceled: {
                                        if (dragging)
                                            root.dragAddress = "";
                                        dragging = false;
                                    }
                                    onClicked: {
                                        if (!dragging)
                                            root.activateWindow(thumb.address);
                                    }
                                }
                            }
                        }
                    }
                }

                // Hover and drop feedback around the whole tile.
                Rectangle {
                    x: surface.x - 3
                    y: surface.y - 3
                    width: surface.width + 6
                    height: surface.height + 6
                    radius: surface.radius + 3
                    color: "transparent"
                    border.width: tile.dropTarget ? 2 : 1
                    border.color: tile.dropTarget ? Theme.accentText
                        : tile.modelData.isNew ? Theme.stroke : "transparent"
                }

                Accessible.role: Accessible.Button
                Accessible.name: tile.modelData.isNew ? "New workspace"
                    : "Workspace " + tile.modelData.name + (tile.current ? ", current" : "")
                Accessible.onPressAction: root.activateWorkspace(tile.modelData)
            }
        }
    }

    // The window being dragged, at the pointer: its icon and name.
    Rectangle {
        id: ghost

        readonly property var info: root.windowFor(root.dragAddress)

        visible: root.dragAddress !== "" && info !== null
        x: root.dragPoint.x - width / 2
        y: root.dragPoint.y - height / 2
        z: 10
        width: Math.min(Theme.scaled(260), ghostRow.implicitWidth + Theme.scaled(20))
        height: Theme.scaled(40)
        radius: Theme.chipRadius
        color: Theme.surfaceMenu
        border.width: 1
        border.color: Theme.stroke

        Row {
            id: ghostRow
            anchors.verticalCenter: parent.verticalCenter
            x: Theme.scaled(10)
            spacing: Theme.iconTextSpacing

            IconImage {
                anchors.verticalCenter: parent.verticalCenter
                implicitSize: Theme.scaled(22)
                source: ghost.info ? root.iconFor(ghost.info.appClass) : ""
            }

            Text {
                anchors.verticalCenter: parent.verticalCenter
                width: Math.min(implicitWidth, Theme.scaled(200))
                elide: Text.ElideRight
                text: ghost.info ? (ghost.info.title || ghost.info.appClass) : ""
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.secondary
                color: Theme.textHi
            }
        }
    }
}
