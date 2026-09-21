pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls as Controls
import "../Common"
import "../Common/LayoutHelpers.js" as LayoutHelpers
import "../Common/SettingsHelpers.js" as SettingsHelpers
import "../Common/WidgetCatalog.js" as WidgetCatalog

// Widgets page (turn-3 settings design): the three lanes drawn as one bar
// replica you drag chips along — the same edit the bar itself accepts — and
// a two-column catalog of every widget whose settings expand inline under
// their row instead of swapping the whole page.
//
// Both drop paths commit through LayoutHelpers.moveWidget with the same
// column/index math the bar's own drag uses (barDropColumn/barDropIndex), so
// a drop means the same thing whichever surface it was made on.
SettingsPage {
    id: page

    readonly property var widgetMeta: WidgetCatalog.WIDGETS
    readonly property var catalogIds: SettingsHelpers.MODULE_IDS
    readonly property int enabledCount: {
        void Settings.revision;
        let count = 0;
        for (const col of ["left", "center", "right"])
            count += Settings.mods[col].filter(entry => entry.on).length;
        return count;
    }

    // ---- drag state -------------------------------------------------------
    property var dragMod: null     // { id, name, fromCol }
    property var dropAt: null      // { col, idx }, idx in the full list
    property point dragPos: Qt.point(0, 0)
    property string announcement: ""
    readonly property bool dragActive: dragMod !== null

    // ---- inline widget settings -------------------------------------------
    // Kept under the historical sub-page names so SettingsView's Escape
    // routing keeps working unchanged.
    property string subPage: ""
    readonly property bool subPageActive: subPage !== ""

    function openSubPage(id) {
        if (dragActive)
            return;
        subPage = subPage === id ? "" : id;
        if (subPage !== "")
            announcement = widgetMeta[id].name + " settings expanded.";
    }

    function closeSubPage() {
        const id = subPage;
        subPage = "";
        announcement = "Widget settings collapsed.";
        if (id !== "")
            Qt.callLater(() => focusCatalog(id));
    }

    function focusCatalog(id) {
        const index = catalogIds.indexOf(id);
        if (index === -1)
            return;
        const pair = catalogRepeater.itemAt(Math.floor(index / 2)) as CatalogPair;
        if (pair)
            pair.focusCell(index % 2);
    }

    function cancelDrag() {
        dragMod = null;
        dropAt = null;
    }

    function laneEntries(col) {
        return Settings.mods[col].filter(entry => entry.on);
    }

    // Pointer position in replica coordinates -> { col, idx } in the full
    // configured list, exactly as the bar's own drag resolves it.
    function updateDrop(pos) {
        if (pos.x < -20 || pos.x > laneStrip.width + 20
                || pos.y < -34 || pos.y > laneStrip.height + 34) {
            dropAt = null;
            return;
        }
        const col = LayoutHelpers.barDropColumn(pos.x, {
            leftEnd: laneLeftBox.x + laneLeftBox.width,
            centerStart: laneCenterBox.x,
            centerEnd: laneCenterBox.x + laneCenterBox.width,
            rightStart: laneRightBox.x
        });
        const lane = col === "left" ? laneLeft : col === "center" ? laneCenter : laneRight;
        const idx = LayoutHelpers.barDropIndex(Settings.mods[col],
            lane.chipCenters(), pos.x);
        if (!dropAt || dropAt.col !== col || dropAt.idx !== idx)
            dropAt = { col: col, idx: idx };
    }

    function commitDrag() {
        if (!dragMod || !dropAt) {
            cancelDrag();
            return;
        }
        const result = LayoutHelpers.moveWidget(Settings.mods, dragMod.fromCol,
            dragMod.id, dropAt.col, dropAt.idx);
        if (!result) {
            cancelDrag();
            return;
        }
        const focusId = dragMod.id;
        announcement = WidgetCatalog.widgetName(focusId)
            + " dropped in " + result.col + " position " + (result.idx + 1) + ".";
        Settings.setModuleOrder(result.mods.left, result.mods.center,
            result.mods.right);
        dragMod = null;
        dropAt = null;
        Qt.callLater(() => focusChip(focusId));
    }

    function focusChip(id) {
        for (const lane of [laneLeft, laneCenter, laneRight]) {
            const chip = lane.chipForId(id);
            if (chip) {
                chip.forceActiveFocus();
                return;
            }
        }
    }

    function keyboardToggle(chip) {
        if (!dragActive) {
            dragMod = { id: chip.entryId, name: widgetMeta[chip.entryId].name,
                fromCol: chip.colId };
            dropAt = { col: chip.colId, idx: chip.fullIndex };
            announcement = widgetMeta[chip.entryId].name
                + " picked up. Arrow keys move, Space drops, Escape cancels.";
        } else {
            commitDrag();
        }
    }

    function keyboardMove(key) {
        if (!dragActive || !dropAt)
            return false;
        const order = ["left", "center", "right"];
        let colIndex = order.indexOf(dropAt.col);
        let idx = dropAt.idx;
        if (key === Qt.Key_Left)
            idx--;
        else if (key === Qt.Key_Right)
            idx++;
        else if (key === Qt.Key_Up)
            colIndex = Math.max(0, colIndex - 1);
        else if (key === Qt.Key_Down)
            colIndex = Math.min(order.length - 1, colIndex + 1);
        else
            return false;
        const col = order[colIndex];
        idx = Math.max(0, Math.min(Settings.mods[col].length, idx));
        dropAt = { col: col, idx: idx };
        return true;
    }

    // ---- lane chip --------------------------------------------------------
    component LaneChip: Rectangle {
        id: chip

        required property var modelData
        required property int index
        required property string colId

        readonly property string entryId: modelData.id
        readonly property int fullIndex: {
            void Settings.revision;
            return Settings.mods[colId].findIndex(entry => entry.id === entryId);
        }
        readonly property bool dragged: page.dragMod !== null
            && page.dragMod.id === entryId

        height: 26
        width: chipRow.implicitWidth + 14
        radius: 7
        color: Theme.chip
        opacity: chip.dragged ? 0.35 : 1
        border.width: activeFocus ? 1 : 0
        border.color: Theme.accent
        activeFocusOnTab: colId === "left" && index === 0
        Accessible.role: Accessible.ListItem
        Accessible.name: page.widgetMeta[chip.entryId].name
        Accessible.description: page.dragActive
            ? "Drag in progress" : "Press Space to pick up"
        Accessible.selected: chip.dragged
        Accessible.onPressAction: page.keyboardToggle(chip)
        Controls.ToolTip.visible: chipDrag.containsMouse && !page.dragActive
        Controls.ToolTip.text: page.widgetMeta[chip.entryId].name

        Keys.onPressed: event => {
            if (event.key === Qt.Key_Space) {
                page.keyboardToggle(chip); event.accepted = true;
            } else if (event.key === Qt.Key_Escape && page.dragActive) {
                page.cancelDrag(); event.accepted = true;
            } else if (page.keyboardMove(event.key)) {
                event.accepted = true;
            }
        }

        Row {
            id: chipRow
            anchors.centerIn: parent
            spacing: 5

            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "⠿"
                font.family: Theme.fontMono
                font.pixelSize: Theme.typography.metadata
                color: Theme.textDim
            }

            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: page.widgetMeta[chip.entryId].short
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.bar
                font.weight: Theme.weightSemibold
                color: Theme.textMid
            }
        }

        MouseArea {
            id: chipDrag
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: page.dragActive ? Qt.ClosedHandCursor : Qt.OpenHandCursor
            preventStealing: true

            property point pressPos

            onPressed: mouse => pressPos = Qt.point(mouse.x, mouse.y)
            onPositionChanged: mouse => {
                if (!page.dragActive) {
                    if (Math.abs(mouse.x - pressPos.x)
                            + Math.abs(mouse.y - pressPos.y) < 4)
                        return;
                    page.dragMod = { id: chip.entryId,
                        name: page.widgetMeta[chip.entryId].name,
                        fromCol: chip.colId };
                    page.announcement = page.widgetMeta[chip.entryId].name
                        + " picked up.";
                }
                page.dragPos = chipDrag.mapToItem(laneStrip, mouse.x, mouse.y);
                page.updateDrop(page.dragPos);
            }
            onReleased: {
                if (page.dragActive)
                    page.commitDrag();
            }
            onCanceled: page.cancelDrag()
            onClicked: chip.forceActiveFocus()
        }
    }

    component Lane: Row {
        id: lane

        required property string colId

        spacing: 4

        function chipForId(id) {
            for (let i = 0; i < laneRepeater.count; i++) {
                const item = laneRepeater.itemAt(i) as LaneChip;
                if (item && item.entryId === id)
                    return item;
            }
            return null;
        }

        // id -> chip centre x in replica coordinates, for barDropIndex.
        function chipCenters() {
            const centers = {};
            for (let i = 0; i < laneRepeater.count; i++) {
                const item = laneRepeater.itemAt(i) as LaneChip;
                if (item)
                    centers[item.entryId] = item.mapToItem(laneStrip, 0, 0).x
                        + item.width / 2;
            }
            return centers;
        }

        // Where the insertion caret sits for a drop at `idx` (full-list),
        // in replica coordinates.
        function caretX(idx) {
            for (let i = 0; i < laneRepeater.count; i++) {
                const item = laneRepeater.itemAt(i) as LaneChip;
                if (item && item.fullIndex >= idx)
                    return item.mapToItem(laneStrip, 0, 0).x - 3;
            }
            const last = laneRepeater.itemAt(laneRepeater.count - 1);
            if (last)
                return last.mapToItem(laneStrip, 0, 0).x + last.width + 1;
            return lane.mapToItem(laneStrip, 0, 0).x;
        }

        Repeater {
            id: laneRepeater
            model: page.laneEntries(lane.colId)
            delegate: LaneChip { colId: lane.colId }
        }
    }

    // ---- catalog cell -----------------------------------------------------
    component CatalogCell: Rectangle {
        id: cell

        property string entryId: ""

        readonly property var meta: page.widgetMeta[entryId] ?? ({ name: entryId })
        readonly property var entry: {
            void Settings.revision;
            for (const col of ["left", "center", "right"]) {
                const hit = Settings.mods[col].find(m => m.id === cell.entryId);
                if (hit)
                    return hit;
            }
            return { on: false, detail: "auto" };
        }
        readonly property bool hasOptions: cell.meta.detail === true
            || Settings.defaults.modOpts[entryId] !== undefined
        readonly property bool optsDirty: {
            void Settings.revision;
            return cell.entry.detail !== "auto"
                || (Settings.defaults.modOpts[cell.entryId] !== undefined
                    && JSON.stringify(Settings.modOpts[cell.entryId])
                        !== JSON.stringify(Settings.defaults.modOpts[cell.entryId]));
        }
        readonly property bool expanded: page.subPage === entryId

        visible: entryId !== ""
        height: 32
        radius: Theme.rowRadius
        color: expanded ? Theme.chip
            : cellHover.hovered ? Theme.hoverFill : "transparent"

        HoverHandler {
            id: cellHover
        }

        Text {
            id: cellName
            anchors.left: parent.left
            anchors.leftMargin: 10
            anchors.right: cellTag.left
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            text: cell.meta.name
            font.family: Theme.fontMenu
            font.pixelSize: Theme.typography.primary
            font.weight: Theme.weightMedium
            color: cell.entry.on ? Theme.textHi : Theme.textLow
            elide: Text.ElideRight
        }

        Text {
            id: cellTag
            anchors.right: cellCog.visible ? cellCog.left : cellSwitch.left
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            width: Math.min(implicitWidth, 110)
            text: cell.meta.tag ?? ""
            font.family: Theme.fontMenu
            font.pixelSize: Theme.typography.metadata
            color: Theme.textFaint
            elide: Text.ElideRight
        }

        Rectangle {
            id: cellCog
            visible: cell.hasOptions
            anchors.right: cellSwitch.left
            anchors.rightMargin: 3
            anchors.verticalCenter: parent.verticalCenter
            width: 24
            height: 24
            radius: 6
            color: cogMouse.containsMouse || activeFocus ? Theme.hoverFill : "transparent"
            border.width: activeFocus ? 1 : 0
            border.color: Theme.accent
            activeFocusOnTab: visible
            Accessible.role: Accessible.Button
            Accessible.name: cell.meta.name + " settings"
            Accessible.onPressAction: page.openSubPage(cell.entryId)
            Controls.ToolTip.visible: cogMouse.containsMouse
            Controls.ToolTip.text: cell.expanded
                ? "Collapse widget settings" : "Widget settings"

            Sym {
                anchors.centerIn: parent
                name: "tune"
                size: Theme.iconSmall
                color: cell.optsDirty ? Theme.accent
                    : cell.expanded ? Theme.textHi : Theme.textDim
            }

            Keys.onPressed: event => {
                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                        || event.key === Qt.Key_Space) {
                    page.openSubPage(cell.entryId);
                    event.accepted = true;
                }
            }

            MouseArea {
                id: cogMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    cellCog.forceActiveFocus();
                    page.openSubPage(cell.entryId);
                }
            }
        }

        Toggle {
            id: cellSwitch
            anchors.right: parent.right
            anchors.rightMargin: 6
            anchors.verticalCenter: parent.verticalCenter
            metrics: Theme.switchCompact
            checked: cell.entry.on
            accessibleName: "Show " + cell.meta.name
            onToggled: value => Settings.setModuleEnabled(cell.entryId, value)
        }
    }

    // One catalog grid row: two cells side by side, plus the inline
    // widget-settings panel when one of its cells is expanded.
    component CatalogPair: Column {
                    id: catalogPair

                    required property int index

                    readonly property string leftId: page.catalogIds[index * 2] ?? ""
                    readonly property string rightId: page.catalogIds[index * 2 + 1] ?? ""
                    readonly property bool holdsExpansion: page.subPageActive
                        && (page.subPage === leftId || page.subPage === rightId)

                    function focusCell(side) {
                        const cell = side === 0 ? leftCell : rightCell;
                        cell.forceActiveFocus();
                    }

                    width: parent.width
                    spacing: 4

                    Row {
                        width: parent.width
                        spacing: 12

                        CatalogCell {
                            id: leftCell
                            width: (parent.width - 12) / 2
                            entryId: catalogPair.leftId
                        }

                        CatalogCell {
                            id: rightCell
                            width: (parent.width - 12) / 2
                            entryId: catalogPair.rightId
                        }
                    }

                    // The inline widget-settings panel, expanded under the
                    // grid row that owns it and spanning both columns.
                    Loader {
                        active: catalogPair.holdsExpansion
                        visible: active
                        width: parent.width

                        sourceComponent: Rectangle {
                            width: parent ? parent.width : 0
                            implicitHeight: panelColumn.implicitHeight + 20
                            radius: 10
                            color: Theme.cardFill
                            border.width: 1
                            border.color: Theme.hairlineSoft

                            Column {
                                id: panelColumn
                                x: 12
                                y: 10
                                width: parent.width - 24
                                spacing: 4

                                Item {
                                    width: parent.width
                                    height: 22

                                    Text {
                                        anchors.left: parent.left
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: (page.widgetMeta[page.subPage] ?? ({ name: page.subPage })).name.toUpperCase()
                                            + " · WIDGET SETTINGS"
                                        font.family: Theme.fontMenu
                                        font.pixelSize: Theme.typography.section
                                        font.weight: Theme.weightSemibold
                                        font.letterSpacing: 1
                                        color: Theme.textFaint
                                    }

                                    SettingsAction {
                                        anchors.right: parent.right
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: "Collapse"
                                        glyph: "collapse_all"
                                        onTriggered: page.closeSubPage()
                                    }
                                }

                                ModuleDetailView {
                                    width: parent.width
                                    height: contentHeight
                                    interactive: false
                                    inlineMode: true
                                    moduleId: page.subPage
                                    moduleName: (page.widgetMeta[page.subPage]
                                        ?? ({ name: "" })).name
                                    hasDetail: (page.widgetMeta[page.subPage]
                                        ?? ({})).detail === true
                                    onBackRequested: page.closeSubPage()
                                }
                            }
                        }
                    }
                }

    // ---- layout -----------------------------------------------------------
    Column {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: 12

        SettingsGroup {
            width: parent.width
            title: "Lanes · drag here or on the bar"
            dirty: Settings.modsModified
            onResetRequested: Settings.resetKeys(["mods"], "Widgets")

            Item {
                width: parent.width
                height: 26

                Text {
                    anchors.left: parent.left
                    anchors.leftMargin: Theme.settingsMarkInset
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Profile"
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.control
                    color: Theme.textFaint
                }

                Row {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 2

                    SettingsAction { text: "Focused"; onTriggered: Settings.applyModulePreset("focused") }
                    SettingsAction { text: "Connected"; onTriggered: Settings.applyModulePreset("connected") }
                    SettingsAction { text: "Everything"; onTriggered: Settings.applyModulePreset("everything") }
                }
            }

            Rectangle {
                id: laneStrip
                width: parent.width
                height: 40
                radius: 10
                color: Theme.cardFill

                readonly property real laneUnit: (width - 16 - 12) / 3

                // Each lane clips to its own third of the replica, so an
                // overfull lane truncates instead of colliding with the next.
                Item {
                    id: laneLeftBox
                    x: 8
                    width: laneStrip.laneUnit
                    height: parent.height
                    clip: true

                    Lane {
                        id: laneLeft
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        colId: "left"
                    }
                }

                Item {
                    id: laneCenterBox
                    x: 8 + laneStrip.laneUnit + 6
                    width: laneStrip.laneUnit
                    height: parent.height
                    clip: true

                    Lane {
                        id: laneCenter
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.verticalCenter: parent.verticalCenter
                        colId: "center"
                    }
                }

                Item {
                    id: laneRightBox
                    x: 8 + (laneStrip.laneUnit + 6) * 2
                    width: laneStrip.laneUnit
                    height: parent.height
                    clip: true

                    Lane {
                        id: laneRight
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        colId: "right"
                    }
                }

                // Insertion caret: a lit vertical mark in the drop gap, the
                // way the bar's own drag shows its target.
                Rectangle {
                    visible: page.dragActive && page.dropAt !== null
                    x: {
                        if (!page.dropAt)
                            return 0;
                        const lane = page.dropAt.col === "left" ? laneLeft
                            : page.dropAt.col === "center" ? laneCenter : laneRight;
                        // Recompute when the order changes under the caret.
                        void Settings.revision;
                        return Math.max(2, Math.min(laneStrip.width - 4,
                            lane.caretX(page.dropAt.idx)));
                    }
                    anchors.verticalCenter: parent.verticalCenter
                    width: 2
                    height: 26
                    radius: 1
                    color: Theme.accent
                    z: 10
                }

                // Floating proxy chip that follows the pointer.
                Rectangle {
                    visible: page.dragActive
                    x: page.dragPos.x + 10
                    y: page.dragPos.y - 34
                    width: proxyRow.implicitWidth + 16
                    height: 26
                    radius: 7
                    color: Theme.popBg
                    border.width: 1
                    border.color: Theme.popBorder
                    opacity: 0.92
                    z: 30

                    Row {
                        id: proxyRow
                        anchors.centerIn: parent
                        spacing: 6

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "⠿"
                            font.family: Theme.fontMono
                            font.pixelSize: Theme.typography.metadata
                            color: Theme.textDim
                        }

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: page.dragMod ? page.dragMod.name : ""
                            font.family: Theme.fontMenu
                            font.pixelSize: Theme.typography.bar
                            font.weight: Theme.weightSemibold
                            color: Theme.textHi
                        }
                    }
                }
            }

            Item {
                width: parent.width
                height: 16

                Text {
                    anchors.left: parent.left
                    anchors.leftMargin: 6
                    text: "LEFT"
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.section
                    font.letterSpacing: 0.8
                    color: Theme.textFaint
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "CENTER"
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.section
                    font.letterSpacing: 0.8
                    color: Theme.textFaint
                }
                Text {
                    anchors.right: parent.right
                    anchors.rightMargin: 6
                    text: page.dragActive && page.dropAt !== null
                        ? "RIGHT · drop to place" : "RIGHT"
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.section
                    font.letterSpacing: 0.8
                    color: page.dragActive ? Theme.textMid : Theme.textFaint
                }
            }
        }

        SettingsGroup {
            width: parent.width
            title: "All widgets"

            Text {
                width: parent.width
                leftPadding: Theme.settingsMarkInset
                bottomPadding: 4
                text: page.enabledCount + " of " + page.catalogIds.length
                    + " shown · switch off to remove from its lane"
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.secondary
                color: Theme.textDim
            }

            Repeater {
                id: catalogRepeater
                model: Math.ceil(page.catalogIds.length / 2)

                delegate: CatalogPair {}
            }
        }
    }

    // Post-preset undo: a floating chip over the page, not a reserved row
    // (turn-3 design). Settings' eight-second undo window owns its lifetime.
    Rectangle {
        parent: page
        visible: Settings.undoAvailable && Settings.resetLabel === "Widget profile"
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 10
        width: undoRow.implicitWidth + 20
        height: 32
        radius: 9
        color: Theme.popBg
        border.width: 1
        border.color: Theme.popBorder
        z: 40

        Row {
            id: undoRow
            anchors.centerIn: parent
            spacing: 10

            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "Widget profile applied"
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.secondary
                color: Theme.textMid
            }

            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: undoLabel.implicitWidth + 16
                height: 24
                radius: 6
                color: undoMouse.containsMouse ? Theme.chipHover : Theme.chip
                activeFocusOnTab: parent.parent.visible
                Accessible.role: Accessible.Button
                Accessible.name: "Undo widget profile"
                Accessible.onPressAction: Settings.undoReset()

                Keys.onPressed: event => {
                    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                            || event.key === Qt.Key_Space) {
                        Settings.undoReset(); event.accepted = true;
                    }
                }

                Text {
                    id: undoLabel
                    anchors.centerIn: parent
                    text: "Undo"
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.control
                    font.weight: Theme.weightSemibold
                    color: Theme.accent
                }

                MouseArea {
                    id: undoMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: Settings.undoReset()
                }
            }
        }
    }

    Item {
        width: 1
        height: 1
        opacity: 0
        Accessible.role: Accessible.AlertMessage
        Accessible.name: page.announcement
    }
}
