pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls as Controls
import "../Common"
import "../Common/SettingsSearchData.js" as SearchData
import "../Popovers"

// Settings workspace with a sidebar that collapses as its window narrows.
PopoutPanel {
    id: root

    // Defaults for an unhosted instance; the host assigns both.
    availableWidth: 900
    availableHeight: 680
    readonly property bool compactNav: availableWidth < Theme.scaled(860, Theme.typeScale)
    readonly property int headerHeight: Theme.scaled(44)
    readonly property int gutter: Theme.panelPadding
    readonly property int navWidth: Theme.scaled(compactNav ? 56 : 200, Theme.typeScale)
    readonly property int preferredWidth: Theme.scaled(900, Theme.contentScale)
    readonly property int preferredHeight: Theme.scaled(664)
    property bool moduleDragActive: false
    property bool moduleSubPageActive: false
    signal moveRequested()
    signal cancelModuleDrag()
    signal closeModuleSubPage()
    readonly property int pageIndex: Math.max(0,
        navItems.findIndex(item => item.id === Settings.page))
    readonly property bool dragActive: Settings.page === "modules"
        && moduleDragActive
    readonly property string persistenceStatus: Settings.loadError
        ? (Settings.loadErrorText !== "" ? Settings.loadErrorText
            : "Could not read the settings file.") + " Retry is available."
        : Settings.saveError ? "Could not save settings. Retry is available."
        : Settings.savePending ? "Saving changes…"
        : Settings.font === "mono" ? "Saved · live" : "Saved · applies live"

    // ---- search (turn-3 design: "/" jumps to any row) --------------------
    property string searchQuery: ""
    property int searchSelection: 0
    readonly property bool searchActive: searchQuery.trim() !== ""
    readonly property var searchResults: searchActive
        ? SearchData.search(searchQuery) : []

    function focusSearch() {
        searchField.forceActiveFocus();
        searchField.selectAll();
    }

    function clearSearch() {
        searchQuery = "";
        searchSelection = 0;
        const item = navDelegate(Settings.page);
        if (item)
            item.forceActiveFocus();
    }

    function jumpToResult(row) {
        if (!row)
            return;
        searchQuery = "";
        searchSelection = 0;
        Settings.page = row.page;
        Settings.highlightKey = "";
        Settings.highlightKey = row.key;
        Settings.announcement = row.pageLabel + " page, " + row.label + " row.";
        if (row.key !== "")
            highlightClearTimer.restart();
    }

    Timer {
        id: highlightClearTimer
        interval: 2600
        onTriggered: Settings.highlightKey = ""
    }

    implicitWidth: Theme.fitWidth(preferredWidth, availableWidth > 0 ? availableWidth : preferredWidth)
    implicitHeight: Math.max(1, Math.min(preferredHeight, availableHeight > 0 ? availableHeight : preferredHeight))
    focus: true

    // "/" from anywhere in the workspace focuses the nav search. A focused
    // TextInput consumes its own keys, so typing "/" into a field never
    // reaches this handler.
    Keys.onPressed: event => {
        if (event.key === Qt.Key_Slash
                || (event.key === Qt.Key_F && event.modifiers & Qt.ControlModifier)) {
            focusSearch();
            event.accepted = true;
        }
    }
    // A dialog sits on the shell's deepest surface rather than on a lighter
    // card stacked over it, so the sections inside can be separated by
    // hairlines the way the bar separates its widgets.
    surfaceColor: Theme.panelSurface

    readonly property var navItems: [
        { id: "appearance", group: "SHELL", label: "Appearance", glyph: "palette",
            title: "Appearance", description: "Theme, colors, and typography" },
        { id: "wallpaper", group: "SHELL", label: "Wallpaper", glyph: "image",
            title: "Wallpaper", description: "Desktop image and automatic rotation" },
        { id: "bar", group: "SHELL", label: "Bar", glyph: "space_dashboard",
            title: "Bar", description: "Placement, shape, and behavior" },
        { id: "modules", group: "SHELL", label: "Widgets", glyph: "widgets",
            title: "Widgets", description: "Choose and arrange the bar’s contents" },
        { id: "plugins", group: "SHELL", label: "Plugins", glyph: "extension",
            title: "Plugins", description: "Install and manage trusted desktop plugins" },
        { id: "drawer", group: "SHELL", label: "Drawer", glyph: "right_panel_open",
            title: "Drawer", description: "Tabs, overview contents, and how it opens" },
        { id: "notifications", group: "SYSTEM", label: "Notifications", glyph: "notifications",
            title: "Notifications", description: "Toasts, quiet hours, and the notification center" },
        { id: "system", group: "SYSTEM", label: "System", glyph: "settings",
            title: "System", description: "Formats, night light, OSD, and storage" }
    ]

    function navDelegate(id) {
        for (const repeater of [shellRepeater, systemRepeater]) {
            for (let i = 0; i < repeater.count; i++) {
                const item = repeater.itemAt(i);
                if (item && item.modelData.id === id)
                    return item;
            }
        }
        return null;
    }

    function selectVisible(position) {
        if (navItems.length === 0)
            return;
        const clamped = Math.max(0, Math.min(navItems.length - 1, position));
        Settings.page = navItems[clamped].id;
        const item = navDelegate(navItems[clamped].id);
        if (item)
            item.forceActiveFocus();
    }

    function selectOffset(delta) {
        const current = navItems.findIndex(item => item.id === Settings.page);
        selectVisible(current === -1 ? 0 : current + delta);
    }

    function cancelDrag() {
        cancelModuleDrag();
    }

    // Called by the window host. An active search consumes the first Escape, a
    // module drag the next, an open inline widget panel the one after that;
    // otherwise the host closes the panel.
    function handleEscape(): bool {
        if (searchActive || searchField.activeFocus) {
            clearSearch();
            return true;
        }
        if (dragActive) {
            cancelDrag();
            return true;
        }
        if (Settings.page === "modules" && moduleSubPageActive) {
            closeModuleSubPage();
            return true;
        }
        return false;
    }

    component NavItem: Rectangle {
        id: navItem
        required property var modelData
        required property int index
        readonly property bool current: Settings.page === modelData.id

        width: navColumn.width
        height: Theme.panelRowHeight + 2
        radius: Theme.chipRadius
        // The current page lights the same surface a bar chip lights when its
        // popout is open. A 176px slab of accent would be the loudest thing
        // in the workspace; the accent survives on the icon, where it is a
        // mark rather than a field.
        color: current ? Theme.chip : "transparent"
        border.width: activeFocus ? 1 : 0
        border.color: Theme.accent
        activeFocusOnTab: navItem.current
        Accessible.role: Accessible.PageTab
        Accessible.name: navItem.modelData.label
        Accessible.selected: navItem.current
        Accessible.onPressAction: {
            navState.pulseCenter();
            Settings.page = navItem.modelData.id;
        }
        Controls.ToolTip.visible: root.compactNav && navMouse.containsMouse
        Controls.ToolTip.text: navItem.modelData.label

        Keys.onPressed: event => {
            if (event.key === Qt.Key_Up || event.key === Qt.Key_Left) {
                root.selectOffset(-1); event.accepted = true;
            } else if (event.key === Qt.Key_Down || event.key === Qt.Key_Right) {
                root.selectOffset(1); event.accepted = true;
            } else if (event.key === Qt.Key_Home) {
                root.selectVisible(0); event.accepted = true;
            } else if (event.key === Qt.Key_End) {
                root.selectVisible(root.navItems.length - 1); event.accepted = true;
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                    || event.key === Qt.Key_Space) {
                navState.pulseCenter();
                Settings.page = modelData.id; event.accepted = true;
            }
        }

        StateLayer {
            id: navState
            anchors.fill: parent
            radius: parent.radius
            hovered: navMouse.containsMouse
            pressed: navMouse.pressed
            focused: navItem.activeFocus
            tint: navItem.current ? Theme.accent : Theme.textHi
            pressPoint: Qt.point(navMouse.mouseX, navMouse.mouseY)
        }

        Sym {
            id: navIcon
            anchors.left: parent.left
            anchors.leftMargin: root.compactNav ? 0 : 8
            anchors.verticalCenter: parent.verticalCenter
            width: root.compactNav ? parent.width : 20
            horizontalAlignment: Text.AlignHCenter
            name: navItem.modelData.glyph
            size: Theme.iconMedium
            color: navItem.current ? Theme.accent : Theme.icon
        }

        Text {
            visible: !root.compactNav
            anchors.left: navIcon.right
            anchors.leftMargin: 9
            anchors.verticalCenter: parent.verticalCenter
            text: navItem.modelData.label
            font.family: Theme.fontMenu
            font.pixelSize: Theme.typography.navigation
            font.weight: navItem.current ? Theme.weightSemibold : Theme.weightMedium
            color: navItem.current ? Theme.textHi : Theme.textLow
            width: parent.width - x - 10
            elide: Text.ElideRight
        }

        // The page's modified mark: the same 6px accent dot its changed rows
        // wear, so a page holding non-default values is findable from the nav.
        Rectangle {
            visible: !root.compactNav && Settings.revision >= 0
                && Settings.sectionDirty(navItem.modelData.id)
            anchors.right: parent.right
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            width: 6
            height: 6
            radius: 3
            color: Theme.accent
        }

        MouseArea {
            id: navMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
                Settings.page = navItem.modelData.id;
                navItem.forceActiveFocus();
            }
        }
    }

    component GroupLabel: Item {
        property alias text: labelText.text
        property int topPad: 6
        width: navColumn.width
        height: visible ? Theme.sectionHeaderHeight + topPad : 0

        Text {
            id: labelText
            anchors.left: parent.left
            anchors.leftMargin: 8
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 2
            font.family: Theme.fontMenu
            font.pixelSize: Theme.typography.section
            font.weight: Theme.weightSemibold
            font.letterSpacing: 1
            color: Theme.textFaint
        }
    }

    Item {
        id: header
        width: parent.width
        height: root.headerHeight

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.SizeAllCursor
            onPressed: root.moveRequested()
        }

        // One line, the way the clock reads: the subject, then what it is
        // about as a quieter qualifier after a middot. Two stacked lines made
        // the header the tallest thing on the page and said no more than this.
        Row {
            id: headerCopy
            anchors.left: parent.left
            anchors.leftMargin: root.gutter
            anchors.right: headerActions.left
            anchors.rightMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            spacing: 8

            Text {
                id: headerTitle
                anchors.verticalCenter: parent.verticalCenter
                text: root.searchActive ? "Search" : root.navItems[root.pageIndex].title
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.title
                font.weight: Theme.weightSemibold
                color: Theme.textHi
            }

            Text {
                anchors.verticalCenter: parent.verticalCenter
                visible: !root.compactNav
                text: "·"
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.secondary
                color: Theme.dotDim
            }

            Text {
                anchors.verticalCenter: parent.verticalCenter
                visible: !root.compactNav
                text: root.searchActive
                    ? root.searchResults.length + " result"
                        + (root.searchResults.length === 1 ? "" : "s")
                        + " for “" + root.searchQuery.trim() + "”"
                    : root.navItems[root.pageIndex].description.toLowerCase()
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.secondary
                color: Theme.textFaint
                width: Math.max(0, parent.width - headerTitle.width - parent.spacing * 2 - 8)
                elide: Text.ElideRight
            }
        }

        Row {
            id: headerActions
            anchors.right: parent.right
            anchors.rightMargin: root.gutter
            anchors.verticalCenter: parent.verticalCenter
            spacing: 4

            SettingsAction {
                visible: !root.searchActive && Settings.revision >= 0
                    && Settings.sectionDirty(Settings.page)
                text: "Reset page"
                glyph: "undo"
                onTriggered: Settings.resetSection(Settings.page)
            }

            SettingsAction {
                compact: true
                text: "Close"
                glyph: "close"
                onTriggered: Settings.closePanel()
            }
        }
    }

    Rectangle {
        y: root.headerHeight
        width: parent.width
        height: 1
        color: Theme.hairlineSoft
    }

    Item {
        id: body
        y: root.headerHeight + 1
        width: parent.width
        height: parent.height - root.headerHeight - 1

        Column {
            id: navColumn
            x: root.gutter / 2
            y: root.gutter
            width: root.navWidth - root.gutter
            spacing: 3

            // The search field ("/" focuses it): a row that filters every
            // page's rows and jumps to the picked one. In the icon rail it
            // compresses to its glyph; focusing it still takes typed text.
            Rectangle {
                id: searchBox
                width: parent.width
                height: Theme.settingsControlHeight
                radius: Theme.chipRadius
                color: searchField.activeFocus || root.searchActive
                    ? Theme.chipHover : Theme.chip
                border.width: searchField.activeFocus ? 1 : 0
                border.color: Theme.accent

                Sym {
                    id: searchGlyph
                    anchors.left: parent.left
                    anchors.leftMargin: root.compactNav ? 0 : 9
                    width: root.compactNav ? parent.width : implicitWidth
                    horizontalAlignment: Text.AlignHCenter
                    anchors.verticalCenter: parent.verticalCenter
                    name: "search"
                    size: Theme.iconSmall
                    color: searchField.activeFocus ? Theme.textMid : Theme.textFaint
                }

                TextInput {
                    id: searchField
                    visible: !root.compactNav || activeFocus
                    anchors.left: searchGlyph.right
                    anchors.leftMargin: root.compactNav ? 0 : 7
                    anchors.right: searchHint.visible ? searchHint.left : parent.right
                    anchors.rightMargin: 6
                    anchors.verticalCenter: parent.verticalCenter
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.control
                    color: Theme.textHi
                    selectionColor: Theme.accentAlpha(0.4)
                    selectedTextColor: Theme.textHi
                    clip: true
                    activeFocusOnTab: true
                    Accessible.role: Accessible.EditableText
                    Accessible.name: "Search settings"
                    onTextChanged: {
                        root.searchQuery = text;
                        root.searchSelection = 0;
                    }
                    Keys.onPressed: event => {
                        if (event.key === Qt.Key_Down) {
                            root.searchSelection = Math.min(
                                root.searchResults.length - 1, root.searchSelection + 1);
                            event.accepted = true;
                        } else if (event.key === Qt.Key_Up) {
                            root.searchSelection = Math.max(0, root.searchSelection - 1);
                            event.accepted = true;
                        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                            const row = root.searchResults[root.searchSelection];
                            if (row) {
                                searchField.text = "";
                                root.jumpToResult(row);
                            }
                            event.accepted = true;
                        }
                    }

                    Text {
                        visible: parent.text === "" && !parent.activeFocus
                        anchors.fill: parent
                        verticalAlignment: Text.AlignVCenter
                        text: "Search"
                        font.family: Theme.fontMenu
                        font.pixelSize: Theme.typography.control
                        color: Theme.textFaint
                    }
                }

                Rectangle {
                    id: searchHint
                    visible: !root.compactNav && !searchField.activeFocus
                        && !root.searchActive
                    anchors.right: parent.right
                    anchors.rightMargin: 6
                    anchors.verticalCenter: parent.verticalCenter
                    width: hintText.implicitWidth + 10
                    height: 16
                    radius: 4
                    color: "transparent"
                    border.width: 1
                    border.color: Theme.hairline

                    Text {
                        id: hintText
                        anchors.centerIn: parent
                        text: "/"
                        font.family: Theme.fontMono
                        font.pixelSize: Theme.typography.metadata
                        font.weight: Theme.weightSemibold
                        color: Theme.textFaint
                    }
                }

                Sym {
                    visible: root.searchActive && !root.compactNav
                    anchors.right: parent.right
                    anchors.rightMargin: 7
                    anchors.verticalCenter: parent.verticalCenter
                    name: "close"
                    size: Theme.iconSmall
                    color: clearMouse.containsMouse ? Theme.textHi : Theme.textFaint

                    MouseArea {
                        id: clearMouse
                        anchors.fill: parent
                        anchors.margins: -4
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            searchField.text = "";
                            root.clearSearch();
                        }
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    visible: !searchField.activeFocus
                    cursorShape: Qt.IBeamCursor
                    onClicked: root.focusSearch()
                }
            }

            Item { width: 1; height: 6 }

            // Whole-nav dimming while a search runs: the list stays visible
            // as a map, but the results own the workspace.
            GroupLabel {
                text: "SHELL"
                topPad: 0
                visible: !root.compactNav
                opacity: root.searchActive ? 0.45 : 1
            }

            Repeater {
                id: shellRepeater
                model: root.navItems.filter(item => item.group === "SHELL")
                delegate: NavItem { opacity: root.searchActive ? 0.45 : 1 }
            }

            GroupLabel {
                text: "SYSTEM"
                visible: !root.compactNav
                opacity: root.searchActive ? 0.45 : 1
            }

            Repeater {
                id: systemRepeater
                model: root.navItems.filter(item => item.group === "SYSTEM")
                delegate: NavItem { opacity: root.searchActive ? 0.45 : 1 }
            }

        }

        // Save state lives in the rail footer (design 1c).
        Column {
            id: railFooter
            anchors.left: parent.left
            anchors.leftMargin: root.gutter / 2
            anchors.bottom: parent.bottom
            anchors.bottomMargin: root.gutter - 2
            width: root.navWidth - root.gutter
            spacing: 5

            SettingsAction {
                visible: Settings.undoAvailable
                compact: root.compactNav
                text: "Undo"
                glyph: "undo"
                Accessible.name: "Undo " + Settings.resetLabel + " reset"
                onTriggered: Settings.undoReset()
            }

            SettingsAction {
                visible: Settings.persistenceError && !Settings.undoAvailable
                compact: root.compactNav
                text: "Retry"
                glyph: "refresh"
                Accessible.name: Settings.loadError
                    ? "Retry loading settings" : "Retry saving settings"
                onTriggered: Settings.retrySave()
            }

            Row {
                spacing: 7
                leftPadding: root.compactNav ? 0 : 8
                width: parent.width
                Accessible.role: Settings.persistenceError
                    ? Accessible.AlertMessage : Accessible.StaticText
                Accessible.name: root.persistenceStatus

                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: 6; height: 6; radius: 3
                    color: Settings.undoAvailable ? Theme.accent
                        : Settings.persistenceError ? Theme.red
                        : Settings.savePending ? Theme.amber : Theme.connected
                }

                Text {
                    visible: !root.compactNav
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - 6 - 7 - parent.leftPadding
                    text: Settings.undoAvailable ? Settings.resetLabel + " reset"
                        : Settings.loadError ? "Could not read settings"
                        : Settings.saveError ? "Could not save settings"
                        : Settings.savePending ? "Saving changes…"
                        : Settings.font === "mono" ? "Saved · live" : "Saved · applies live"
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.secondary
                    color: Settings.persistenceError ? Theme.redText : Theme.textFaint
                    elide: Text.ElideRight
                    Accessible.role: Settings.persistenceError
                        ? Accessible.AlertMessage : Accessible.StaticText
                    Accessible.name: root.persistenceStatus
                }
            }
        }

        Rectangle {
            x: root.navWidth
            width: 1
            height: parent.height
            color: Theme.hairlineSoft
        }

        Loader {
            id: pageLoader
            // Incubated off the frame that opens the panel: the pages are the
            // bulk of this view and building one inline stalls the popout's
            // open animation. The loader is explicitly sized, so a page that
            // is one frame late changes nothing but its own content area, and
            // every reader below already tolerates a null item.
            asynchronous: true
            x: root.navWidth + root.gutter
            y: root.gutter
            width: parent.width - root.navWidth - root.gutter * 2
            height: parent.height - root.gutter * 2
            focus: true
            sourceComponent: {
                if (root.searchActive)
                    return searchResultsPage;
                switch (Settings.page) {
                case "wallpaper": return wallpaperPage;
                case "bar": return barPage;
                case "modules": return modulesPage;
                case "plugins": return pluginsPage;
                case "drawer": return drawerPage;
                case "notifications": return notificationsPage;
                case "system": return systemPage;
                default: return appearancePage;
                }
            }
        }

        Component {
            id: searchResultsPage

            Item {
                Column {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    spacing: 2

                    Repeater {
                        model: root.searchResults

                        delegate: Rectangle {
                            id: resultRow

                            required property var modelData
                            required property int index
                            readonly property bool selected:
                                index === root.searchSelection
                            // Booleans read as words, everything else as its
                            // stored value; container keys stay silent.
                            readonly property string valueLabel: {
                                void Settings.revision;
                                if (modelData.key === "")
                                    return "";
                                const value = Settings[modelData.key];
                                if (typeof value === "boolean")
                                    return value ? "on" : "off";
                                if (typeof value === "object")
                                    return "";
                                return String(value);
                            }

                            width: parent.width
                            height: Theme.scaled(40)
                            radius: Theme.rowRadius
                            color: selected ? Theme.chip
                                : resultMouse.containsMouse ? Theme.hoverFill
                                : "transparent"
                            Accessible.role: Accessible.ListItem
                            Accessible.name: modelData.pageLabel + ", "
                                + modelData.group + ", " + modelData.label
                            Accessible.selected: selected

                            Text {
                                id: crumb
                                anchors.left: parent.left
                                anchors.leftMargin: 10
                                anchors.verticalCenter: parent.verticalCenter
                                width: 180
                                text: resultRow.modelData.pageLabel
                                    + "  ›  " + resultRow.modelData.group
                                font.family: Theme.fontMenu
                                font.pixelSize: Theme.typography.metadata
                                color: Theme.textFaint
                                elide: Text.ElideRight
                            }

                            Text {
                                anchors.left: crumb.right
                                anchors.leftMargin: 12
                                anchors.right: valueText.left
                                anchors.rightMargin: 10
                                anchors.verticalCenter: parent.verticalCenter
                                text: resultRow.modelData.label
                                font.family: Theme.fontMenu
                                font.pixelSize: Theme.typography.primary
                                font.weight: Theme.weightMedium
                                color: resultRow.selected ? Theme.textHi : Theme.textMid
                                elide: Text.ElideRight
                            }

                            Text {
                                id: valueText
                                anchors.right: parent.right
                                anchors.rightMargin: 10
                                anchors.verticalCenter: parent.verticalCenter
                                text: resultRow.valueLabel
                                font.family: Theme.fontMono
                                font.pixelSize: Theme.typography.control
                                color: Theme.textFaint
                            }

                            MouseArea {
                                id: resultMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    searchField.text = "";
                                    root.jumpToResult(resultRow.modelData);
                                }
                            }
                        }
                    }

                    Text {
                        visible: root.searchResults.length === 0
                        width: parent.width
                        topPadding: 8
                        leftPadding: 10
                        text: "Nothing matches “" + root.searchQuery.trim()
                            + "”. Try a setting's name, its group, or a page."
                        font.family: Theme.fontMenu
                        font.pixelSize: Theme.typography.primary
                        color: Theme.textDim
                        wrapMode: Text.Wrap
                    }
                }

                Row {
                    anchors.left: parent.left
                    anchors.leftMargin: 10
                    anchors.bottom: parent.bottom
                    spacing: 14

                    Repeater {
                        model: [
                            { keys: "↑↓", verb: "move" },
                            { keys: "⏎", verb: "open row" },
                            { keys: "Esc", verb: "back to page" }
                        ]

                        delegate: Row {
                            required property var modelData
                            spacing: 5

                            Text {
                                text: parent.modelData.keys
                                font.family: Theme.fontMono
                                font.pixelSize: Theme.typography.metadata
                                color: Theme.textDim
                            }
                            Text {
                                text: parent.modelData.verb
                                font.family: Theme.fontMenu
                                font.pixelSize: Theme.typography.secondary
                                color: Theme.textFaint
                            }
                        }
                    }
                }
            }
        }

        Component { id: appearancePage; AppearancePage {} }
        Component { id: wallpaperPage; WallpaperPage {} }
        Component { id: barPage; BarLayoutPage {} }
        Component {
            id: modulesPage
            ModulesPage {
                id: modulesContent
                onDragActiveChanged: root.moduleDragActive = modulesContent.dragActive
                onSubPageActiveChanged: root.moduleSubPageActive = modulesContent.subPageActive
                Component.onCompleted: {
                    root.moduleDragActive = modulesContent.dragActive;
                    root.moduleSubPageActive = modulesContent.subPageActive;
                }
                Component.onDestruction: {
                    root.moduleDragActive = false;
                    root.moduleSubPageActive = false;
                }
                Connections {
                    target: root
                    function onCancelModuleDrag() { modulesContent.cancelDrag(); }
                    function onCloseModuleSubPage() { modulesContent.closeSubPage(); }
                }
            }
        }
        Component { id: notificationsPage; NotificationsPage {} }
        Component { id: pluginsPage; PluginsPage {} }
        Component { id: drawerPage; DrawerPage {} }
        Component { id: systemPage; SystemPage {} }
    }

    Item {
        width: 1
        height: 1
        opacity: 0
        Accessible.role: Accessible.AlertMessage
        Accessible.name: Settings.announcement
    }
}
