pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import "Common"
import "Common/LauncherNavigation.js" as Navigation
import "Popovers"

// Compact eight-row tabbed command palette. LauncherProviders owns routing,
// asynchronous work and activation; this permanently warm view renders each
// normalized row on one line and scrolls longer result sets in-place.
Surface {
    id: root

    implicitWidth: Theme.fitWidth(Theme.scaled(460, Theme.contentScale), availableWidth > 0 ? availableWidth : Theme.scaled(460, Theme.contentScale))

    readonly property int maxResults: LauncherProviders.maxResults
    readonly property int tabHeight: Theme.scaled(34)
    readonly property int searchHeight: Theme.scaled(44)
    readonly property int rowHeight: Theme.scaled(42)
    readonly property int resultIconSize: Theme.scaled(28)
    readonly property int fullHeight: padding * 2 + tabHeight + searchHeight
        + maxResults * rowHeight + spacing * 2
    property int selected: 0
    readonly property string query: search.text
    readonly property bool inputActiveFocus: search.activeFocus
    readonly property var provider: LauncherProviders.activeProvider
    readonly property string mode: LauncherProviders.mode
    readonly property string term: LauncherProviders.term
    readonly property var rows: LauncherProviders.rows
    readonly property var tabs: LauncherProviders.tabProviders
    readonly property string searchPlaceholder: ({
        apps: "Search applications",
        emoji: "Search emoji by name",
        clipboard: "Search clipboard history",
        actions: "Search actions"
    })[provider.id] || "Search apps, commands and more"

    // The view is permanently warm. Reset synchronously on open and ask for
    // focus both now and on the next event-loop turn: the second request
    // covers the layer-surface mapping without clearing any text typed in the
    // meantime.
    function focusInput(): void {
        search.forceActiveFocus();
    }

    function prepareOpen(): void {
        LauncherProviders.selectedProviderId = "apps";
        search.text = "";
        selected = 0;
        focusInput();
        resultList.positionViewAtBeginning();
        Qt.callLater(() => {
            if (Launcher.open)
                root.focusInput();
        });
    }

    Component.onCompleted: {
        if (Launcher.open)
            prepareOpen();
    }

    Connections {
        target: Launcher

        function onOpenChanged() {
            if (Launcher.open)
                root.prepareOpen();
        }
    }

    onRowsChanged: {
        selected = Navigation.clampSelection(selected, rows.length);
        Qt.callLater(() => root.revealSelection());
    }
    onSelectedChanged: revealSelection()
    onQueryChanged: {
        selected = 0;
        LauncherProviders.query = query;
        Qt.callLater(() => resultList.positionViewAtBeginning());
    }

    function activate(row): void {
        LauncherProviders.activate(row);
    }

    function selectTab(providerId): void {
        LauncherProviders.selectedProviderId = providerId;
        search.text = "";
        selected = 0;
        resultList.positionViewAtBeginning();
        focusInput();
    }

    function cycleTab(offset): void {
        let current = 0;
        const selectedId = root.tabs.some(tab => tab.id === root.provider.id)
            ? root.provider.id : LauncherProviders.selectedProviderId;
        for (let i = 0; i < root.tabs.length; ++i) {
            if (root.tabs[i].id === selectedId) {
                current = i;
                break;
            }
        }
        const next = (current + offset + root.tabs.length) % root.tabs.length;
        root.selectTab(root.tabs[next].id);
    }

    function wrapSelection(offset): void {
        selected = Navigation.wrapSelection(selected, rows.length, offset);
    }

    function pageSelection(offset): void {
        selected = Navigation.pageSelection(selected, rows.length, offset);
    }

    function revealSelection(): void {
        if (rows.length === 0)
            resultList.positionViewAtBeginning();
        else
            resultList.positionViewAtIndex(selected, ListView.Contain);
    }

    // Shared by the TextInput and by LauncherWindow's one-frame focus-race
    // fallback. Enter is intentionally handled regardless of modifiers, so
    // it can launch the selected first row even if Super has not yet lifted.
    function handleCommandKey(event): bool {
        if (event.key === Qt.Key_Escape) {
            if (query !== "") {
                search.text = "";
                selected = 0;
            } else {
                Launcher.close();
            }
        } else if (event.modifiers & Qt.ControlModifier
                && (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab)) {
            cycleTab((event.key === Qt.Key_Backtab
                || event.modifiers & Qt.ShiftModifier) ? -1 : 1);
        } else if (event.key === Qt.Key_Left) {
            cycleTab(-1);
        } else if (event.key === Qt.Key_Right) {
            cycleTab(1);
        } else if (event.modifiers & Qt.AltModifier && event.key >= Qt.Key_1 && event.key <= Qt.Key_8) {
            activate(rows[event.key - Qt.Key_1]);
        } else if (event.modifiers & Qt.ShiftModifier
                && event.key === Qt.Key_Delete
                && LauncherProviders.canRemove(rows[selected])) {
            LauncherProviders.remove(rows[selected]);
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            activate(rows[selected]);
        } else if (event.key === Qt.Key_Down || event.key === Qt.Key_Tab) {
            wrapSelection(1);
        } else if (event.key === Qt.Key_Up) {
            wrapSelection(-1);
        } else if (event.key === Qt.Key_PageDown) {
            pageSelection(6);
        } else if (event.key === Qt.Key_PageUp) {
            pageSelection(-6);
        } else if (event.key === Qt.Key_Home) {
            selected = 0;
        } else if (event.key === Qt.Key_End) {
            selected = Math.max(0, rows.length - 1);
        } else {
            return false;
        }
        return true;
    }

    function handleEarlyKey(event): bool {
        if (handleCommandKey(event))
            return true;
        const commandModifiers = Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier;
        if (event.text === "" || event.modifiers & commandModifiers)
            return false;
        focusInput();
        search.insert(search.cursorPosition, event.text);
        return true;
    }

    function esc(value) {
        return (value || "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
    }

    function highlight(value) {
        if (term === "")
            return esc(value);
        const index = (value || "").toLowerCase().indexOf(term.toLowerCase());
        if (index < 0)
            return esc(value);
        return esc(value.slice(0, index))
            + `<font color="${Theme.accent}">` + esc(value.slice(index, index + term.length)) + "</font>"
            + esc(value.slice(index + term.length));
    }

    // The match highlight is the accent, and it now shows on every row: the
    // selected row lights a chip rather than an accent field, so there is
    // nothing for it to collide with.
    function titleFor(row) {
        if (!row)
            return "";
        return row.highlight === false ? esc(row.title) : highlight(row.title);
    }

    // ---- Provider tabs ---------------------------------------------------
    Rectangle {
        width: parent.width
        height: root.tabHeight
        radius: Theme.chipRadius
        color: "transparent"

        Row {
            id: tabRow
            x: 4
            y: 4
            width: parent.width - 8
            height: parent.height - 8
            spacing: 4

            Repeater {
                model: root.tabs

                delegate: Rectangle {
                    id: providerTab

                    required property var modelData
                    required property int index
                    readonly property bool active:
                        root.provider.id === modelData.id
                    readonly property string label: ({
                        apps: "Apps",
                        emoji: "Emoji",
                        clipboard: "History",
                        actions: "Actions"
                    })[modelData.id] || modelData.label

                    width: (tabRow.width - tabRow.spacing
                        * (root.tabs.length - 1)) / root.tabs.length
                    height: tabRow.height
                    radius: Theme.chipRadius
                    color: active ? Theme.chipHover
                        : providerTabMouse.containsMouse
                            ? Theme.chip : "transparent"

                    Behavior on color {
                        ColorAnimation { duration: Theme.chipFadeDuration }
                    }

                    Row {
                        anchors.centerIn: parent
                        spacing: 7

                        Sym {
                            anchors.verticalCenter: parent.verticalCenter
                            name: providerTab.modelData.glyph
                            size: Theme.iconMedium
                            color: providerTab.active
                                ? Theme.accentText : Theme.textDim
                        }

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: providerTab.label
                            font.family: Theme.fontMenu
                            font.pixelSize: Theme.typography.title
                            font.weight: Theme.weightMedium
                            color: providerTab.active
                                ? Theme.textHi : Theme.textDim
                        }
                    }

                    Accessible.role: Accessible.PageTab
                    Accessible.name: label
                    Accessible.selected: active
                    Accessible.onPressAction:
                        root.selectTab(providerTab.modelData.id)

                    MouseArea {
                        id: providerTabMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.selectTab(providerTab.modelData.id)
                    }
                }
            }
        }
    }

    // ---- Search tile -----------------------------------------------------
    Rectangle {
        width: parent.width
        height: root.searchHeight
        radius: Theme.chipRadius
        color: Theme.chip

        Behavior on color {
            ColorAnimation { duration: Theme.surfaceDuration }
        }

        Sym {
            id: searchGlyph
            x: 16
            anchors.verticalCenter: parent.verticalCenter
            name: root.provider.glyph
            size: 18
            color: Theme.textDim
        }

        TextInput {
            id: search
            anchors.verticalCenter: parent.verticalCenter
            x: 44
            width: parent.width - x - (modeChip.visible ? modeChip.width + 24 : 16)
            font.family: Theme.fontMenu
            font.pixelSize: Theme.typography.heading
            font.weight: Theme.weightRegular
            color: Theme.textHi
            clip: true
            focus: Launcher.open

            Text {
                visible: search.text === ""
                anchors.verticalCenter: parent.verticalCenter
                text: root.searchPlaceholder
                font: search.font
                color: Theme.textDim
            }

            Keys.onPressed: event => event.accepted = root.handleCommandKey(event)
        }

        // A typed utility prefix temporarily overrides the selected tab.
        // Clicking its chip removes the prefix and returns to that tab.
        Rectangle {
            id: modeChip
            visible: root.mode !== ""
            anchors.right: parent.right
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            width: modeLabel.implicitWidth + 20
            height: 22
            radius: Theme.pillRadius
            color: modeMouse.containsMouse ? Theme.hoverFillStrong : Theme.chipHover

            Text {
                id: modeLabel
                anchors.centerIn: parent
                text: root.mode !== "" ? root.provider.label : ""
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.metadata
                font.weight: Theme.weightMedium
                font.letterSpacing: 0.5
                color: Theme.textHi
            }

            MouseArea {
                id: modeMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: search.text = root.term
            }
        }
    }

    // ---- Results ---------------------------------------------------------
    Item {
        width: parent.width
        height: Math.min(Math.min(root.maxResults, root.rows.length) * root.rowHeight,
            root.availableHeight > 0 ? Math.max(0, root.availableHeight - root.padding * 2 - root.tabHeight - root.searchHeight - root.spacing * 2) : root.maxResults * root.rowHeight)
        clip: true

        ListView {
            id: resultList
            anchors.fill: parent
            model: root.rows
            interactive: contentHeight > height
            boundsBehavior: Flickable.StopAtBounds
            flickableDirection: Flickable.VerticalFlick

            delegate: Rectangle {
                id: resultRow

                required property var modelData
                required property int index
                readonly property bool isSelected: index === root.selected
                width: resultList.width
                height: root.rowHeight
                radius: Theme.rowRadius
                // The selected result lights the bar's held chip. A full-accent
                // slab across a 460px row was the loudest thing in the shell, and
                // the value jump from mid copy to white already says which row it
                // is — the same way a taken segment says it everywhere else.
                color: isSelected ? Theme.chipHover : "transparent"

                Item {
                    id: resultIcon
                    x: Theme.scaled(10)
                    anchors.verticalCenter: parent.verticalCenter
                    width: root.resultIconSize
                    height: root.resultIconSize

                    Image {
                        anchors.fill: parent
                        visible: source !== ""
                        source: resultRow.modelData.icon
                            ? Quickshell.iconPath(resultRow.modelData.icon, true) : ""
                        sourceSize: Qt.size(64, 64)
                        fillMode: Image.PreserveAspectFit
                        asynchronous: true
                    }

                    Rectangle {
                        visible: !resultRow.modelData.icon
                        anchors.fill: parent
                        radius: 9
                        color: Theme.chip

                        Sym {
                            anchors.centerIn: parent
                            visible: !resultRow.modelData.iconText
                            name: resultRow.modelData.glyph || root.provider.glyph
                            size: Theme.iconMedium
                            animateColor: false
                            color: resultRow.isSelected ? Theme.textHi : Theme.textMid
                        }

                        Text {
                            anchors.centerIn: parent
                            visible: !!resultRow.modelData.iconText
                            text: resultRow.modelData.iconText || ""
                            font.family: Theme.fontMenu
                            font.pixelSize: Theme.typography.title
                        }
                    }
                }

                Text {
                    x: resultIcon.x + resultIcon.width + Theme.scaled(10)
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.max(0, parent.width - x - Theme.scaled(12))
                    textFormat: Text.StyledText
                    text: root.titleFor(resultRow.modelData)
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.heading
                    font.weight: Theme.weightMedium
                    color: Theme.textHi
                    elide: Text.ElideRight
                }

                MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onEntered: root.selected = resultRow.index
                    onClicked: mouse => {
                        if (mouse.button === Qt.RightButton
                                && LauncherProviders.canRemove(resultRow.modelData))
                            LauncherProviders.remove(resultRow.modelData);
                        else
                            root.activate(resultRow.modelData);
                    }
                }
            }
        }

        ScrollChrome {
            anchors.fill: parent
            target: resultList
        }
    }

    // ---- Empty state -----------------------------------------------------
    Column {
        visible: root.rows.length === 0
        width: parent.width
        topPadding: 18
        bottomPadding: 12
        spacing: 6

        Sym {
            anchors.horizontalCenter: parent.horizontalCenter
            name: "search_off"
            size: Theme.iconLarge + 2
            color: Theme.textDim
        }

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            width: parent.width - 40
            horizontalAlignment: Text.AlignHCenter
            text: LauncherProviders.emptyText
            font.family: Theme.fontMenu
            font.pixelSize: Theme.typography.secondary
            font.weight: Theme.weightBold
            color: LauncherProviders.error !== "" ? Theme.redText : Theme.textDim
            elide: Text.ElideRight
        }
    }

}
