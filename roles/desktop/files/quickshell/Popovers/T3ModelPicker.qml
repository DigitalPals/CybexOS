pragma ComponentBehavior: Bound
import QtQuick
import "../Common"

// The composer's model control: a provider rail beside one list.
//
// Mirrors the reference client's picker. Pick a provider on the left and its
// models fill the right; retired models fold into a "Legacy models" section
// you open when you want them, so the list you normally read is only the
// three or four models anyone actually picks. Typing abandons the rail —
// search ranks every ready provider at once, because a search you have to
// scope first is not a search.
//
// The row order, the search ranking, the legacy split and the digit
// shortcuts are all arithmetic over the config snapshot and live in
// T3CodeHelpers.js; everything here is presentation.
Item {
    id: root

    property string threadId: ""
    property bool newThread: false
    // "<instanceId>::<slug>" — the composer's joined provider/model value.
    property string value: ""
    property string label: ""
    property string brand: ""
    property bool expanded: false
    property bool openUpward: true
    property real maxWidth: 1000
    property Item popupBoundsItem: null
    signal selected(string instanceId, string model)

    // Float the panel at the page boundary rather than leaving it underneath
    // the tiny bar trigger. Besides escaping a scrolling viewport's clip, this
    // keeps every row in the page's pointer-delivery tree: painting a child
    // outside the trigger made it visible but not mouse-addressable.
    readonly property Item popupHostItem: popupBoundsItem ? popupBoundsItem : root
    property point popupHostOrigin: Qt.point(0, 0)

    readonly property var rail: T3Code.providerRail()
    property string railId: ""
    property string query: ""
    property bool legacyExpanded: false
    property int highlighted: 0

    readonly property bool favoritesAvailable: T3Code.favoriteModels.length > 0
    readonly property var rows: newThread
        ? T3Code.newPickerRows(railId, query, legacyExpanded)
        : T3Code.threadPickerRows(threadId, railId, query, legacyExpanded)
    readonly property bool searching: query.trim() !== ""

    implicitWidth: trigger.implicitWidth
    implicitHeight: trigger.implicitHeight
    readonly property real naturalWidth: trigger.naturalWidth
    z: expanded ? 100 : 0

    property point popupBoundsOrigin: Qt.point(0, 0)
    readonly property real popupBoundsLeft: popupBoundsItem
        ? popupBoundsOrigin.x : 0
    readonly property real popupBoundsTop: popupBoundsItem
        ? popupBoundsOrigin.y : -100000
    readonly property real popupBoundsRight: popupBoundsItem
        ? popupBoundsOrigin.x + popupBoundsItem.width : 100000
    readonly property real popupBoundsBottom: popupBoundsItem
        ? popupBoundsOrigin.y + popupBoundsItem.height : 100000
    readonly property int panelWidth: Math.min(336,
        Math.max(1, Math.floor(popupBoundsRight - popupBoundsLeft)))
    readonly property int railWidth: 40
    readonly property int rowHeight: 42

    // Sized to what it holds, capped so a long list scrolls rather than
    // covering the transcript. The rail sets the floor: a panel shorter than
    // its own provider column would clip the last provider.
    readonly property int naturalPanelHeight: {
        const list = 55 + Math.max(1, rows.length) * (rowHeight + 2) - 2;
        const rail = 8 + (T3Code.favoriteModels.length > 0
            ? railWidth - 8 + 4 + 1 + 4 : 0)
            + root.rail.length * (railWidth - 4) - 4;
        return Math.max(searching ? 0 : rail, Math.min(300, list));
    }
    readonly property int panelHeight: Math.min(naturalPanelHeight,
        Math.max(rowHeight + 12,
            Math.floor(popupBoundsBottom - popupBoundsTop)))
    readonly property int popupHeight: panelHeight
    readonly property Item popupItem: panel

    function currentInstanceId() {
        const at = value.indexOf(T3Code.selectionSeparator);
        return at < 0 ? "" : value.slice(0, at);
    }

    function updatePopupGeometry() {
        popupHostOrigin = popupHostItem === root ? Qt.point(0, 0)
            : popupHostItem.mapFromItem(root, 0, 0);
        popupBoundsOrigin = popupBoundsItem
            ? root.mapFromItem(popupBoundsItem, 0, 0) : Qt.point(0, 0);
    }

    // The rail starts wherever the user already is: on their shortlist if
    // they have one, otherwise on the provider serving this thread.
    function defaultRailId() {
        const instanceId = currentInstanceId();
        if (T3Code.favoriteModels.length > 0)
            return "favorites";
        if (instanceId !== "")
            return instanceId;
        return rail.length > 0 ? rail[0].instanceId : "";
    }

    function open() {
        railId = defaultRailId();
        query = "";
        legacyExpanded = false;
        highlighted = 0;
        updatePopupGeometry();
        expanded = true;
        Qt.callLater(updatePopupGeometry);
        searchInput.forceActiveFocus();
    }

    function close() {
        expanded = false;
        query = "";
    }

    function toggle() {
        if (expanded)
            close();
        else
            open();
    }

    function chooseRail(id) {
        railId = id;
        query = "";
        highlighted = 0;
        searchInput.forceActiveFocus();
    }

    function activate(row) {
        if (!row)
            return;
        if (row.kind === "legacy") {
            legacyExpanded = !legacyExpanded;
            return;
        }
        if (row.disabledReason !== "")
            return;
        root.selected(row.instanceId, row.slug);
        close();
    }

    function activateShortcut(digit) {
        for (let at = 0; at < rows.length; at++) {
            if (rows[at].shortcut === digit) {
                activate(rows[at]);
                return true;
            }
        }
        return false;
    }

    function moveHighlight(delta) {
        if (rows.length === 0)
            return;
        highlighted = (highlighted + delta + rows.length) % rows.length;
    }

    function containsPickerPoint(item, x, y) {
        if (!item)
            return false;
        const buttonPoint = root.mapFromItem(item, x, y);
        const panelPoint = panel.mapFromItem(item, x, y);
        const inButton = buttonPoint.x >= 0 && buttonPoint.x <= root.width
            && buttonPoint.y >= 0 && buttonPoint.y <= root.height;
        const inPanel = panel.visible && panelPoint.x >= 0
            && panelPoint.x <= panel.width && panelPoint.y >= 0
            && panelPoint.y <= panel.height;
        return inButton || inPanel;
    }

    onEnabledChanged: {
        if (!enabled)
            close();
    }

    onVisibleChanged: {
        if (!visible)
            close();
    }

    onRowsChanged: {
        if (highlighted >= rows.length)
            highlighted = Math.max(0, rows.length - 1);
    }

    // Unstarring the last model takes the rail entry away with it. Standing on
    // a rail that no longer exists leaves an empty panel and no obvious way
    // out, so fall through to the provider the composer is already using.
    onFavoritesAvailableChanged: {
        if (!favoritesAvailable && railId === "favorites")
            railId = currentInstanceId() !== "" ? currentInstanceId()
                : (rail.length > 0 ? rail[0].instanceId : "");
    }

    TapHandler {
        enabled: root.expanded && root.enabled && root.visible
        margin: root.Window.window
            ? Math.max(root.Window.window.width, root.Window.window.height) : 0
        onTapped: eventPoint => {
            if (!root.containsPickerPoint(root,
                    eventPoint.position.x, eventPoint.position.y))
                root.close();
        }
    }

    T3BarControl {
        id: trigger
        anchors.fill: parent
        text: root.label
        accessibleDescription: "Provider and model"
        maxWidth: root.maxWidth
        brand: root.brand
        tint: T3Theme.textPrimary
        active: root.expanded
        enabled: root.enabled
        onTriggered: root.toggle()
    }

    Rectangle {
        id: panel

        parent: root.popupHostItem
        z: 1000
        visible: root.expanded && root.enabled
        readonly property real preferredY: root.openUpward
            ? -height - 6 : root.height + 6
        x: root.popupHostOrigin.x + Math.max(root.popupBoundsLeft,
            Math.min(0, root.popupBoundsRight - width))
        y: root.popupHostOrigin.y + Math.max(root.popupBoundsTop,
            Math.min(preferredY, root.popupBoundsBottom - height))
        width: root.panelWidth
        height: root.panelHeight
        radius: T3Theme.panelRadius
        color: T3Theme.overlay
        border.width: 1
        border.color: T3Theme.borderStrong
        clip: true

        // ---- provider rail ------------------------------------------------

        Rectangle {
            id: providerRail
            visible: !root.searching && root.rail.length > 0
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: visible ? root.railWidth : 0
            color: T3Theme.hover

            // Slides between rail entries rather than cutting, so the eye
            // follows the selection instead of re-finding it.
            Rectangle {
                id: railIndicator
                visible: railColumn.selectedY >= 0
                anchors.right: parent.right
                y: railColumn.selectedY
                width: 3
                height: 20
                radius: 1.5
                color: T3Theme.accent

                Behavior on y {
                    NumberAnimation {
                        duration: T3Theme.normalDuration
                        easing.type: Easing.OutCubic
                    }
                }
            }

            Column {
                id: railColumn
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: 4
                spacing: 4

                readonly property int itemSize: root.railWidth - 8
                readonly property real selectedY: {
                    if (root.railId === "favorites")
                        return favoritesRail.visible ? 4 + (itemSize - 20) / 2 : -1;
                    for (let at = 0; at < root.rail.length; at++) {
                        if (root.rail[at].instanceId === root.railId)
                            return 4 + (favoritesRail.visible ? itemSize + 4 + 9 : 0)
                                + at * (itemSize + 4) + (itemSize - 20) / 2;
                    }
                    return -1;
                }

                Rectangle {
                    id: favoritesRail
                    visible: T3Code.favoriteModels.length > 0
                    width: railColumn.itemSize
                    height: railColumn.itemSize
                    radius: T3Theme.controlRadius
                    color: favoritesMouse.containsMouse ? T3Theme.hoverStrong : "transparent"
                    Accessible.role: Accessible.Button
                    Accessible.name: "Favourites"

                    Sym {
                        anchors.centerIn: parent
                        name: "star"
                        fill: 1
                        size: Theme.iconMedium
                        symWeight: 500
                        color: root.railId === "favorites"
                            ? T3Theme.textPrimary : T3Theme.textFaint
                    }

                    MouseArea {
                        id: favoritesMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.chooseRail("favorites")
                    }
                }

                Rectangle {
                    visible: favoritesRail.visible
                    width: railColumn.itemSize
                    height: 1
                    color: T3Theme.border
                }

                Repeater {
                    model: root.rail

                    delegate: Rectangle {
                        id: railEntry
                        required property var modelData

                        width: railColumn.itemSize
                        height: railColumn.itemSize
                        radius: T3Theme.controlRadius
                        color: railMouse.containsMouse && railEntry.modelData.ready
                            ? T3Theme.hoverStrong : "transparent"
                        opacity: railEntry.modelData.ready ? 1 : 0.4
                        Accessible.role: Accessible.Button
                        Accessible.name: railEntry.modelData.tooltip

                        BrandIcon {
                            visible: railEntry.modelData.icon !== ""
                            anchors.centerIn: parent
                            width: 19
                            height: 19
                            name: railEntry.modelData.icon
                        }

                        // A driver this shell has no brand mark for still
                        // needs to be pickable, so it wears its initial.
                        Rectangle {
                            visible: railEntry.modelData.icon === ""
                            anchors.centerIn: parent
                            width: 19
                            height: 19
                            radius: 5
                            color: T3Theme.borderStrong

                            Text {
                                anchors.centerIn: parent
                                text: String(railEntry.modelData.displayName ?? "?")
                                    .slice(0, 1).toUpperCase()
                                font.family: T3Theme.fontUi
                                font.pixelSize: Theme.typography.metadata
                                font.weight: Theme.weightSemibold
                                color: T3Theme.textSecondary
                            }
                        }

                        MouseArea {
                            id: railMouse
                            anchors.fill: parent
                            enabled: railEntry.modelData.ready
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.chooseRail(railEntry.modelData.instanceId)
                        }
                    }
                }
            }
        }

        // ---- search + list ------------------------------------------------

        Item {
            anchors.left: providerRail.right
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.bottom: parent.bottom

            Rectangle {
                visible: providerRail.visible
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                width: 1
                color: T3Theme.border
            }

            Item {
                id: searchRow
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.leftMargin: 10
                anchors.rightMargin: 10
                anchors.topMargin: 8
                height: 28

                Sym {
                    id: searchGlyph
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    name: "search"
                    size: Theme.iconSmall
                    symWeight: 450
                    color: T3Theme.textFaint
                }

                TextInput {
                    id: searchInput
                    anchors.left: searchGlyph.right
                    anchors.leftMargin: 7
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.query
                    onTextChanged: {
                        root.query = text;
                        root.highlighted = 0;
                    }
                    selectByMouse: true
                    font.family: T3Theme.fontUi
                    font.pixelSize: Theme.typography.control
                    color: T3Theme.textPrimary
                    selectionColor: T3Theme.accentSoft
                    selectedTextColor: T3Theme.textPrimary
                    Accessible.role: Accessible.EditableText
                    Accessible.name: "Search models"

                    Keys.onPressed: event => {
                        if (event.key === Qt.Key_Escape) {
                            root.close();
                            event.accepted = true;
                        } else if (event.key === Qt.Key_Down) {
                            root.moveHighlight(1);
                            event.accepted = true;
                        } else if (event.key === Qt.Key_Up) {
                            root.moveHighlight(-1);
                            event.accepted = true;
                        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                            root.activate(root.rows[root.highlighted]);
                            event.accepted = true;
                        } else if ((event.modifiers & Qt.ControlModifier)
                                && event.key >= Qt.Key_1 && event.key <= Qt.Key_9) {
                            // Ctrl+digit is the reference's jump shortcut, and
                            // it stays free while the search field has the
                            // keyboard, which a bare digit does not.
                            event.accepted = root.activateShortcut(
                                String(event.key - Qt.Key_0));
                        }
                    }

                    Text {
                        visible: searchInput.text === ""
                        text: "Search models…"
                        font.family: T3Theme.fontUi
                        font.pixelSize: Theme.typography.control
                        color: T3Theme.textFaint
                    }
                }
            }

            Rectangle {
                id: searchUnderline
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: searchRow.bottom
                anchors.leftMargin: 10
                anchors.rightMargin: 10
                anchors.topMargin: 6
                height: 1
                color: searchInput.activeFocus ? T3Theme.accent : T3Theme.border

                Behavior on color {
                    ColorAnimation { duration: T3Theme.fastDuration }
                }
            }

            Text {
                visible: root.rows.length === 0
                anchors.centerIn: parent
                text: root.searching ? "No models found" : "No models available"
                font.family: T3Theme.fontUi
                font.pixelSize: Theme.typography.secondary
                color: T3Theme.textFaint
            }

            Flickable {
                id: listFlick
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: searchUnderline.bottom
                anchors.bottom: parent.bottom
                anchors.topMargin: 4
                anchors.leftMargin: 6
                anchors.rightMargin: 4
                anchors.bottomMargin: 4
                contentWidth: width
                contentHeight: listColumn.implicitHeight
                boundsBehavior: Flickable.StopAtBounds
                interactive: contentHeight > height
                clip: true

                Column {
                    id: listColumn
                    width: parent.width
                    spacing: 2

                    Repeater {
                        model: root.rows

                        delegate: Rectangle {
                            id: pickerRow
                            required property var modelData
                            required property int index

                            readonly property bool isLegacyHeader: modelData.kind === "legacy"
                            readonly property bool chosen: !isLegacyHeader
                                && T3Code.selectionId(modelData.instanceId, modelData.slug)
                                    === root.value
                            readonly property bool blocked: !isLegacyHeader
                                && modelData.disabledReason !== ""

                            width: parent ? parent.width : 0
                            height: root.rowHeight
                            radius: T3Theme.controlRadius
                            color: chosen ? T3Theme.accentSoft
                                : rowMouse.containsMouse || root.highlighted === index
                                    ? T3Theme.hoverStrong : "transparent"
                            opacity: blocked ? 0.42 : 1
                            Accessible.role: Accessible.ListItem
                            Accessible.name: pickerRow.isLegacyHeader
                                ? "Legacy models, " + pickerRow.modelData.count + " models"
                                : pickerRow.modelData.label + ", "
                                    + pickerRow.modelData.providerLabel
                                    + (pickerRow.blocked
                                        ? ", " + pickerRow.modelData.disabledReason : "")

                            // ---- legacy section header --------------------

                            Text {
                                visible: pickerRow.isLegacyHeader
                                anchors.left: parent.left
                                anchors.leftMargin: 9
                                anchors.top: parent.top
                                anchors.topMargin: 6
                                text: "Legacy models"
                                font.family: T3Theme.fontUi
                                font.pixelSize: Theme.typography.secondary
                                font.weight: Theme.weightMedium
                                color: T3Theme.textPrimary
                            }

                            Text {
                                visible: pickerRow.isLegacyHeader
                                anchors.left: parent.left
                                anchors.leftMargin: 9
                                anchors.bottom: parent.bottom
                                anchors.bottomMargin: 6
                                text: pickerRow.modelData.count + " models"
                                font.family: T3Theme.fontUi
                                font.pixelSize: Theme.typography.secondary
                                color: T3Theme.textFaint
                            }

                            Sym {
                                visible: pickerRow.isLegacyHeader
                                anchors.right: parent.right
                                anchors.rightMargin: 9
                                anchors.verticalCenter: parent.verticalCenter
                                name: "chevron_right"
                                size: Theme.iconMedium
                                symWeight: 450
                                color: T3Theme.textFaint
                                rotation: root.legacyExpanded ? 90 : 0

                                Behavior on rotation {
                                    NumberAnimation {
                                        duration: T3Theme.fastDuration
                                        easing.type: Easing.OutCubic
                                    }
                                }
                            }

                            // ---- model row --------------------------------

                            Text {
                                id: rowName
                                visible: !pickerRow.isLegacyHeader
                                anchors.left: parent.left
                                anchors.leftMargin: 9
                                anchors.right: rowShortcut.left
                                anchors.rightMargin: 6
                                anchors.top: parent.top
                                anchors.topMargin: 6
                                text: pickerRow.modelData.label ?? ""
                                elide: Text.ElideRight
                                font.family: T3Theme.fontUi
                                font.pixelSize: Theme.typography.secondary
                                font.weight: Theme.weightMedium
                                color: pickerRow.chosen ? T3Theme.textPrimary
                                    : T3Theme.textSecondary
                            }

                            BrandIcon {
                                id: rowMark
                                visible: !pickerRow.isLegacyHeader
                                    && String(pickerRow.modelData.icon ?? "") !== ""
                                anchors.left: parent.left
                                anchors.leftMargin: 9
                                anchors.bottom: parent.bottom
                                anchors.bottomMargin: 7
                                width: 12
                                height: 12
                                name: String(pickerRow.modelData.icon ?? "")
                            }

                            Text {
                                visible: !pickerRow.isLegacyHeader
                                anchors.left: rowMark.visible ? rowMark.right : parent.left
                                anchors.leftMargin: rowMark.visible ? 6 : 9
                                anchors.right: rowShortcut.left
                                anchors.rightMargin: 6
                                anchors.bottom: parent.bottom
                                anchors.bottomMargin: 6
                                text: pickerRow.blocked ? pickerRow.modelData.disabledReason
                                    : (pickerRow.modelData.providerLabel ?? "")
                                elide: Text.ElideRight
                                font.family: T3Theme.fontUi
                                font.pixelSize: Theme.typography.secondary
                                color: pickerRow.blocked ? T3Theme.amber : T3Theme.textFaint
                            }

                            Rectangle {
                                id: rowShortcut
                                visible: !pickerRow.isLegacyHeader
                                    && String(pickerRow.modelData.shortcut ?? "") !== ""
                                anchors.right: favoriteButton.left
                                anchors.rightMargin: 4
                                anchors.verticalCenter: parent.verticalCenter
                                width: visible ? shortcutText.implicitWidth + 10 : 0
                                height: 16
                                radius: 4
                                color: T3Theme.hover
                                border.width: 1
                                border.color: T3Theme.border

                                Text {
                                    id: shortcutText
                                    anchors.centerIn: parent
                                    text: "Ctrl+" + (pickerRow.modelData.shortcut ?? "")
                                    font.family: T3Theme.fontUi
                                    font.pixelSize: Theme.typography.metadata
                                    font.features: T3Theme.tabularNumberFeatures
                                    color: T3Theme.textFaint
                                }
                            }

                            MouseArea {
                                id: rowMouse
                                anchors.fill: parent
                                enabled: !pickerRow.blocked
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onEntered: root.highlighted = pickerRow.index
                                onClicked: root.activate(pickerRow.modelData)
                            }

                            // Declared last on purpose: it overlaps the row's
                            // own click target, and the sibling drawn last is
                            // the one that receives the press.
                            IconButton {
                                id: favoriteButton
                                visible: !pickerRow.isLegacyHeader
                                anchors.right: parent.right
                                anchors.rightMargin: 4
                                anchors.verticalCenter: parent.verticalCenter
                                controlSize: 24
                                symbol: "star"
                                symbolFill: pickerRow.modelData.favorite === true ? 1 : 0
                                tint: pickerRow.modelData.favorite === true
                                    ? T3Theme.amber : T3Theme.textFaint
                                // A column of stars down an untouched list is
                                // louder than the model names. Present, but
                                // quiet until the row is under the cursor or
                                // the star already means something.
                                opacity: pickerRow.modelData.favorite === true
                                    || rowMouse.containsMouse || favoriteButton.activeFocus
                                    ? 1 : 0.35
                                accessibleName: pickerRow.modelData.favorite === true
                                    ? "Remove from favourites" : "Add to favourites"
                                onTriggered: T3Code.toggleFavoriteModel(
                                    pickerRow.modelData.instanceId, pickerRow.modelData.slug)

                                Behavior on opacity {
                                    NumberAnimation { duration: T3Theme.fastDuration }
                                }
                            }
                        }
                    }
                }
            }

            ScrollChrome {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: searchUnderline.bottom
                anchors.bottom: parent.bottom
                anchors.topMargin: 4
                anchors.leftMargin: 6
                anchors.rightMargin: 4
                anchors.bottomMargin: 4
                target: listFlick
                fadeSize: 16
                edgeColor: T3Theme.overlay
                thumbColor: T3Theme.accent
            }
        }
    }
}
