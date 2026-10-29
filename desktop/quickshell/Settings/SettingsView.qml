pragma ComponentBehavior: Bound
import QtQuick
import "../Common"
import "../Popovers"

// The Settings workspace (2026-10 redesign). A rail on the left — the search
// that opens the palette, then Home and three groups of six pages — and the
// page on the right under a one-line header: Back, the page and what it is
// about, the save state, the Changes chip and Close. Pages that hold more
// than one view show their tabs above the content. The rail compresses to
// its glyphs as the window narrows, and scrolls when it is shorter than its
// pages.
PopoutPanel {
    id: root

    // Defaults for an unhosted instance; the host assigns both.
    availableWidth: 960
    availableHeight: 700
    readonly property bool compactNav: availableWidth < Theme.scaled(860, Theme.typeScale)
    readonly property int headerHeight: Theme.scaled(44)
    readonly property int gutter: Theme.panelPadding
    readonly property int navWidth: Theme.scaled(compactNav ? 58 : 228, Theme.typeScale)
    readonly property int preferredWidth: Theme.scaled(960, Theme.contentScale)
    readonly property int preferredHeight: Theme.scaled(700)
    property bool moduleDragActive: false
    property bool moduleSubPageActive: false
    property string moduleSubPageTitle: ""
    signal moveRequested()
    signal cancelModuleDrag()
    signal closeModuleSubPage()
    readonly property var currentPage: Settings.pageInfo(Settings.page)
    readonly property var currentTabs: currentPage.tabs || []
    readonly property var currentTab: currentTabs.find(entry => entry.id === Settings.tab) || currentTabs[0] || null
    readonly property bool dragActive: Settings.page === "bar" && moduleDragActive
    readonly property bool canGoBack: Settings.canGoBack || (Settings.page === "bar" && moduleSubPageActive)
    readonly property bool systemServicePage: currentPage.system === true
    readonly property string persistenceStatus: Settings.loadError
        ? (Settings.loadErrorText !== "" ? Settings.loadErrorText
            : "Could not read the settings file.") + " Retry is available."
        : Settings.saveError ? "Could not save settings. Retry is available."
        : Settings.savePending ? "Saving changes…"
        : "Saved"

    // The save state speaks only when there is something to say: while a
    // change saves and briefly after, after a reset (with Undo), and on an
    // error. A standing "saved" line told nobody anything.
    property bool justSaved: false
    readonly property bool statusShown: Settings.undoAvailable
        || Settings.persistenceError || Settings.newerSchema
        || Settings.savePending || justSaved
    Connections {
        target: Settings
        function onSavePendingChanged() {
            if (Settings.savePending) {
                savedLinger.stop();
                root.justSaved = false;
            } else if (!Settings.persistenceError) {
                root.justSaved = true;
                savedLinger.restart();
            }
        }
    }
    Timer {
        id: savedLinger
        interval: 2200
        onTriggered: root.justSaved = false
    }

    // Recently changed settings are recorded while this window is open;
    // the recorder has to exist before the first change, not when Home
    // first shows them.
    readonly property int recentCount: SettingsRecent.entries.length
    readonly property int changeCount: SettingsChanges.count

    function openPalette(text) {
        changesSheet.hide();
        palette.show(text || "");
    }

    function openChanges() {
        palette.hide();
        changesSheet.show();
    }

    function goBack() {
        if (Settings.page === "bar" && moduleSubPageActive) {
            closeModuleSubPage();
            return true;
        }
        return Settings.goBack();
    }

    Connections {
        target: SettingsChanges
        function onReviewRequested() { root.openChanges(); }
    }

    // Search results and Settings.showSetting() both jump by setting the key.
    Connections {
        target: Settings
        function onHighlightKeyChanged() {
            if (Settings.highlightKey !== "")
                highlightClearTimer.restart();
        }
        function onPanelOpenChanged() {
            if (Settings.panelOpen) {
                pageRelease.stop();
            } else {
                pageRelease.restart();
                palette.hide();
                changesSheet.hide();
            }
        }
    }

    Timer {
        id: pageRelease
        interval: 15000
    }

    Timer {
        id: highlightClearTimer
        interval: 2600
        onTriggered: Settings.highlightKey = ""
    }

    implicitWidth: Theme.fitWidth(preferredWidth, availableWidth > 0 ? availableWidth : preferredWidth)
    implicitHeight: Math.max(1, Math.min(preferredHeight, availableHeight > 0 ? availableHeight : preferredHeight))
    focus: true

    // "/", Ctrl+K and Ctrl+F from anywhere in the workspace open the palette;
    // Alt+Left goes back. A focused TextInput consumes its own keys, so typing
    // "/" into a field never reaches this handler.
    Keys.onPressed: event => {
        if (event.key === Qt.Key_Slash
                || ((event.key === Qt.Key_K || event.key === Qt.Key_F)
                    && event.modifiers & Qt.ControlModifier)) {
            openPalette("");
            event.accepted = true;
        } else if (event.key === Qt.Key_Left && event.modifiers & Qt.AltModifier) {
            goBack();
            event.accepted = true;
        }
    }
    // A dialog sits on the shell's deepest surface rather than on a lighter
    // card stacked over it, so the sections inside can be separated by
    // hairlines the way the bar separates its widgets.
    surfaceColor: Theme.panelSurface

    readonly property var navItems: Settings.pages

    function navDelegate(id) {
        if (homeItem.modelData.id === id)
            return homeItem;
        for (let g = 0; g < navGroups.count; g++) {
            const group = navGroups.itemAt(g) as NavGroup;
            const item = group ? group.itemFor(id) : null;
            if (item)
                return item;
        }
        return null;
    }

    function selectVisible(position) {
        if (navItems.length === 0)
            return;
        const clamped = Math.max(0, Math.min(navItems.length - 1, position));
        // Focus first: a nav row is a tab stop only while current, and Qt
        // will not drop activeFocusOnTab from the row that still has focus.
        const item = navDelegate(navItems[clamped].id);
        if (item) {
            item.forceActiveFocus();
            navFlick.revealItem(item);
        }
        Settings.page = navItems[clamped].id;
    }

    function selectOffset(delta) {
        const current = navItems.findIndex(item => item.id === Settings.page);
        selectVisible(current === -1 ? 0 : current + delta);
    }

    function cancelDrag() {
        cancelModuleDrag();
    }

    // Called by the window host. The palette or the review sheet consumes
    // the first Escape, a module drag the next, an open inline widget panel
    // the one after that, then a page's own open form or trial; otherwise
    // the host closes the panel.
    function handleEscape(): bool {
        if (palette.open) {
            palette.hide();
            return true;
        }
        if (changesSheet.open) {
            changesSheet.hide();
            return true;
        }
        if (dragActive) {
            cancelDrag();
            return true;
        }
        if (Settings.page === "bar" && moduleSubPageActive) {
            closeModuleSubPage();
            return true;
        }
        // A pending display trial answers first: Escape reverts it.
        const displays = pageLoader.item as DisplaysPage;
        if (displays && displays.handleEscape())
            return true;
        // An open Add form or reset question on Keyboard shortcuts closes first.
        const shortcuts = pageLoader.item as ShortcutsPage;
        if (shortcuts && shortcuts.handleEscape())
            return true;
        return false;
    }

    component NavItem: Rectangle {
        id: navItem
        required property var modelData
        required property int index
        readonly property bool current: Settings.page === modelData.id
        // A page holding a draft that waits for Apply, or the region change
        // being prepared: the same dot the Changes chip wears.
        readonly property bool pending: SettingsChanges.pages.indexOf(modelData.id) !== -1
            || (modelData.id === "region" && RegionDrafts.preparing)
            || (modelData.id === "backup" && SettingsChanges.deploymentKind === "maintenance"
                && SettingsChanges.deploymentState !== "")

        width: navColumn.width
        height: Theme.panelRowHeight
        radius: Theme.chipRadius
        // The current page lights the same surface a bar chip lights when its
        // popout is open. A 200px slab of accent would be the loudest thing
        // in the workspace; the accent survives on the icon, where it is a
        // mark rather than a field.
        color: current ? Theme.chip : "transparent"
        border.width: activeFocus ? 1 : 0
        border.color: Theme.accentText
        activeFocusOnTab: navItem.current
        Accessible.role: Accessible.PageTab
        Accessible.name: navItem.modelData.label + (navItem.pending ? ", " + I18n.tr("changes not applied yet") : "")
        Accessible.selected: navItem.current
        Accessible.onPressAction: {
            navState.pulseCenter();
            Settings.page = navItem.modelData.id;
        }
        SettingsTooltip {
            visible: root.compactNav && navMouse.containsMouse
            text: navItem.modelData.label
            x: parent.width + Theme.scaled(6)
            y: (parent.height - height) / 2
        }

        Keys.onPressed: event => {
            // Alt+Left is Back, which the window handles.
            if (event.modifiers & Qt.AltModifier) {
                event.accepted = false;
            } else if (event.key === Qt.Key_Up || event.key === Qt.Key_Left) {
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
            color: navItem.current ? Theme.accentText : Theme.icon
        }

        Text {
            visible: !root.compactNav
            anchors.left: navIcon.right
            anchors.leftMargin: 9
            anchors.right: pendingDot.visible ? pendingDot.left : parent.right
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            text: navItem.modelData.label
            font.family: Theme.fontMenu
            font.pixelSize: Theme.typography.navigation
            font.weight: navItem.current ? Theme.weightSemibold : Theme.weightMedium
            color: navItem.current ? Theme.textHi : Theme.textLow
            elide: Text.ElideRight
        }

        Rectangle {
            id: pendingDot
            visible: navItem.pending
            x: root.compactNav ? parent.width - width - 7 : parent.width - width - 10
            y: root.compactNav ? 6 : (parent.height - height) / 2
            width: 7
            height: 7
            radius: 3.5
            color: Theme.accent
        }

        MouseArea {
            id: navMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
                navItem.forceActiveFocus();
                Settings.page = navItem.modelData.id;
            }
        }
    }

    component NavGroup: Column {
        id: navGroup
        required property string modelData
        required property int index
        width: navColumn.width
        spacing: 1

        function itemFor(id) {
            for (let i = 0; i < pageRepeater.count; i++) {
                const item = pageRepeater.itemAt(i) as NavItem;
                if (item && item.modelData.id === id)
                    return item;
            }
            return null;
        }

        GroupLabel {
            text: I18n.tr(navGroup.modelData).toUpperCase()
            visible: !root.compactNav
        }
        // In the icon rail a hairline stands in for the label.
        Item {
            visible: root.compactNav
            width: parent.width
            height: Theme.scaled(13)
            Rectangle {
                anchors.centerIn: parent
                width: parent.width - Theme.scaled(12)
                height: 1
                color: Theme.hairlineSoft
            }
        }

        Repeater {
            id: pageRepeater
            model: root.navItems.filter(item => item.group === navGroup.modelData)
            delegate: NavItem {}
        }
    }

    component GroupLabel: Item {
        property alias text: labelText.text
        width: navColumn.width
        height: visible ? Theme.sectionHeaderHeight + Theme.scaled(4) : 0

        Text {
            id: labelText
            anchors.left: parent.left
            anchors.leftMargin: 8
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 3
            font.family: Theme.fontMenu
            font.pixelSize: Theme.typography.section
            font.weight: Theme.weightSemibold
            font.letterSpacing: 1
            color: Theme.textFaint
        }
    }

    // ---- rail ------------------------------------------------------------
    Item {
        id: rail
        width: root.navWidth
        height: parent.height

        MouseArea {
            width: parent.width
            height: root.headerHeight
            cursorShape: Qt.SizeAllCursor
            onPressed: root.moveRequested()
        }

        // The palette's field, shown where search always was. In the icon
        // rail it compresses to its glyph.
        Rectangle {
            id: searchBox
            x: root.gutter / 2
            y: Math.round((root.headerHeight - height) / 2)
            width: root.navWidth - root.gutter
            height: Theme.settingsControlHeight
            radius: Theme.chipRadius
            color: searchMouse.containsMouse ? Theme.chipHover : Theme.chip
            border.width: activeFocus ? 1 : 0
            border.color: Theme.accentText
            activeFocusOnTab: true
            Accessible.role: Accessible.Button
            Accessible.name: I18n.tr("Search settings")
            Accessible.onPressAction: root.openPalette("")
            Keys.onPressed: event => {
                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                    root.openPalette("");
                    event.accepted = true;
                } else if (event.text.length === 1 && event.text.trim() !== ""
                        && !(event.modifiers & (Qt.ControlModifier | Qt.AltModifier))) {
                    // Typing on the focused field starts the search with it.
                    root.openPalette(event.text);
                    event.accepted = true;
                }
            }

            Sym {
                id: searchGlyph
                anchors.left: parent.left
                anchors.leftMargin: root.compactNav ? 0 : 9
                width: root.compactNav ? parent.width : implicitWidth
                horizontalAlignment: Text.AlignHCenter
                anchors.verticalCenter: parent.verticalCenter
                name: "search"
                size: Theme.iconSmall
                color: Theme.textFaint
            }
            Text {
                visible: !root.compactNav
                anchors.left: searchGlyph.right
                anchors.leftMargin: 7
                anchors.verticalCenter: parent.verticalCenter
                text: I18n.tr("Search")
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.control
                color: Theme.textFaint
            }
            Rectangle {
                visible: !root.compactNav
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
            MouseArea {
                id: searchMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.IBeamCursor
                onClicked: root.openPalette("")
            }
        }

        Flickable {
            id: navFlick
            y: root.headerHeight
            width: parent.width
            height: parent.height - y
            contentHeight: navColumn.height + root.gutter
            boundsBehavior: Flickable.StopAtBounds
            interactive: contentHeight > height
            clip: true

            function revealItem(item) {
                const top = item.mapToItem(navColumn, 0, 0).y + navColumn.y;
                if (top < contentY)
                    contentY = Math.max(0, top - root.gutter / 2);
                else if (top + item.height > contentY + height)
                    contentY = Math.min(contentHeight - height, top + item.height - height + root.gutter / 2);
            }

            Column {
                id: navColumn
                x: root.gutter / 2
                y: Theme.scaled(2)
                width: root.navWidth - root.gutter
                spacing: 1

                // Groups follow what the person is doing — personalizing the
                // desktop, a device, the system — not where a value happens
                // to be stored. Home stands above them.
                NavItem {
                    id: homeItem
                    modelData: Settings.pages[0]
                    index: 0
                }

                Repeater {
                    id: navGroups
                    model: Settings.pageGroups

                    delegate: NavGroup {}
                }
            }
        }
    }

    Rectangle {
        x: root.navWidth
        width: 1
        height: parent.height
        color: Theme.hairlineSoft
    }

    // ---- page ------------------------------------------------------------
    Item {
        id: body
        x: root.navWidth + 1
        y: root.headerHeight + 1
        width: parent.width - x
        height: parent.height - y

        // A tabbed page's views, on the content column's own edges.
        SettingsTabs {
            id: pageTabs
            readonly property int columnWidth: Math.min(Theme.scaled(640, Theme.typeScale),
                Math.max(0, pageLoader.width - 8))
            visible: root.currentTabs.length > 0
            x: pageLoader.x + Math.max(0, Math.floor((pageLoader.width - 8 - columnWidth) / 2))
            y: root.gutter - Theme.scaled(6)
            width: columnWidth
            height: visible ? implicitHeight : 0
            tabs: root.currentTabs
            current: root.currentTab ? root.currentTab.id : ""
            onPicked: id => Settings.setTab(Settings.page, id)
        }

        Loader {
            id: pageLoader
            objectName: "settingsPageLoader"
            // Incubated off the frame that opens the panel: the pages are the
            // bulk of this view and building one inline stalls the popout's
            // open animation. The loader is explicitly sized, so a page that
            // is one frame late changes nothing but its own content area, and
            // every reader below already tolerates a null item.
            asynchronous: true
            // The window outlives every close, and a page such as the
            // wallpaper grid holds thumbnails and models while it exists. Keep
            // it briefly so a quick reopen is instant, then release it;
            // Settings.page reopens the same page.
            active: Settings.panelOpen || pageRelease.running
            x: root.gutter
            y: pageTabs.visible ? pageTabs.y + pageTabs.height + Theme.scaled(18) : root.gutter
            width: parent.width - root.gutter * 2
            height: parent.height - y - root.gutter
            focus: true
            sourceComponent: {
                const tab = root.currentTab ? root.currentTab.id : "";
                switch (Settings.page) {
                case "home": return homePage;
                case "wallpaper": return wallpaperPage;
                case "bar": return barPage;
                case "workspaces": return workspacesPage;
                case "notifications": return notificationsPage;
                case "plugins": return pluginsPage;
                case "displays": return displaysPage;
                case "sound": return soundPage;
                case "network": return networkPage;
                case "touchpad": return touchpadPage;
                case "keyboard": return tab === "shortcuts" ? shortcutsPage : keyboardPage;
                case "power": return powerPage;
                case "security": return securityPage;
                case "accounts": return accountsPage;
                case "assistant": return assistantPage;
                case "applications": return applicationsPage;
                case "region": return regionPage;
                case "backup": return tab === "storage" ? storagePage : tab === "recovery" ? recoveryPage : backupPage;
                default: return appearancePage;
                }
            }
        }

        Component { id: homePage; HomePage {} }
        Component { id: appearancePage; AppearancePage {} }
        Component { id: wallpaperPage; WallpaperPage {} }
        // The Bar page is the widget editor with the bar's own layout,
        // background and behavior beneath it; the drag and the widget
        // dialog it hosts take part in the Escape chain above.
        Component {
            id: barPage
            ModulesPage {
                id: modulesContent
                onDragActiveChanged: root.moduleDragActive = modulesContent.dragActive
                onSubPageActiveChanged: root.moduleSubPageActive = modulesContent.subPageActive
                onSubPageTitleChanged: root.moduleSubPageTitle = modulesContent.subPageTitle
                Component.onCompleted: {
                    root.moduleDragActive = modulesContent.dragActive;
                    root.moduleSubPageActive = modulesContent.subPageActive;
                    root.moduleSubPageTitle = modulesContent.subPageTitle;
                }
                Component.onDestruction: {
                    root.moduleDragActive = false;
                    root.moduleSubPageActive = false;
                    root.moduleSubPageTitle = "";
                }
                Connections {
                    target: root
                    function onCancelModuleDrag() { modulesContent.cancelDrag(); }
                    function onCloseModuleSubPage() { modulesContent.closeSubPage(); }
                }
            }
        }
        Component { id: workspacesPage; WorkspacesPage {} }
        Component { id: notificationsPage; NotificationsPage {} }
        Component { id: assistantPage; AssistantPage {} }
        Component { id: pluginsPage; PluginsPage {} }
        Component { id: networkPage; NetworkPage {} }
        Component { id: soundPage; SoundPage {} }
        Component { id: displaysPage; DisplaysPage {} }
        Component { id: accountsPage; AccountsPage {} }
        Component { id: securityPage; SecurityPage {} }
        Component { id: touchpadPage; TouchpadPage {} }
        Component { id: keyboardPage; KeyboardPage {} }
        Component { id: shortcutsPage; ShortcutsPage {} }
        Component { id: powerPage; PowerPage {} }
        Component { id: applicationsPage; ApplicationsPage {} }
        Component { id: storagePage; StoragePage { section: "storage" } }
        Component { id: recoveryPage; StoragePage { section: "recovery" } }
        Component { id: regionPage; RegionPage {} }
        Component { id: backupPage; BackupPage {} }
    }

    // ---- header ----------------------------------------------------------
    // Declared after the page so the tab order runs search, rail, page, then
    // the header's actions and Close last. Resetting a page lives at the
    // page's foot (SettingsPage.pageReset), not up here beside Close, where
    // Tab then Enter used to reset the whole page.
    Item {
        id: header
        x: root.navWidth + 1
        width: parent.width - x
        height: root.headerHeight

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.SizeAllCursor
            onPressed: root.moveRequested()
        }

        SettingsAction {
            id: backAction
            x: root.gutter / 2
            anchors.verticalCenter: parent.verticalCenter
            compact: true
            glyph: "arrow_back"
            text: I18n.tr("Back")
            enabled: root.canGoBack
            Accessible.name: I18n.tr("Back to the previous page")
            onTriggered: root.goBack()
        }

        // One line, the way the clock reads: the subject, then what it is
        // about as a quieter qualifier after a middot.
        Row {
            id: headerCopy
            anchors.left: backAction.right
            anchors.leftMargin: Theme.scaled(6)
            anchors.right: headerActions.left
            anchors.rightMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            spacing: 8

            Text {
                id: headerTitle
                anchors.verticalCenter: parent.verticalCenter
                // A widget's own settings read as a breadcrumb under its page.
                text: I18n.tr(root.currentPage.label)
                    + (Settings.page === "bar" && root.moduleSubPageTitle !== "" ? "  ›  " + root.moduleSubPageTitle : "")
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
                text: root.currentTab ? root.currentTab.description : root.currentPage.description
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
            anchors.rightMargin: root.gutter / 2
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.scaled(8)

            Row {
                visible: root.statusShown
                anchors.verticalCenter: parent.verticalCenter
                spacing: 7
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
                    text: Settings.undoAvailable ? Settings.resetLabel + " reset"
                        : Settings.newerSchema ? "Newer settings file · not saving"
                        : Settings.loadError ? "Could not read settings"
                        : Settings.saveError ? "Could not save settings"
                        : Settings.savePending ? "Saving…"
                        : "Saved"
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.secondary
                    color: Settings.persistenceError ? Theme.redText : Theme.textFaint
                    elide: Text.ElideRight
                }
            }

            SettingsAction {
                visible: Settings.undoAvailable
                anchors.verticalCenter: parent.verticalCenter
                compact: root.compactNav
                text: I18n.tr("Undo")
                glyph: "undo"
                Accessible.name: "Undo " + Settings.resetLabel + " reset"
                onTriggered: Settings.undoReset()
            }

            SettingsAction {
                visible: Settings.persistenceError && !Settings.undoAvailable
                anchors.verticalCenter: parent.verticalCenter
                compact: root.compactNav
                text: I18n.tr("Retry")
                glyph: "refresh"
                Accessible.name: Settings.loadError
                    ? "Retry loading settings" : "Retry saving settings"
                onTriggered: Settings.retrySave()
            }

            ChangesChip {
                anchors.verticalCenter: parent.verticalCenter
                compact: root.compactNav
                onReviewRequested: root.openChanges()
            }

            SettingsAction {
                anchors.verticalCenter: parent.verticalCenter
                compact: true
                text: I18n.tr("Close")
                glyph: "close"
                onTriggered: Settings.closePanel()
            }
        }
    }

    Rectangle {
        x: root.navWidth + 1
        y: root.headerHeight
        width: parent.width - x
        height: 1
        color: Theme.hairlineSoft
    }

    // ---- overlays --------------------------------------------------------
    ChangesSheet {
        id: changesSheet
        objectName: "changesSheet"
        anchors.fill: parent
    }

    SettingsPalette {
        id: palette
        objectName: "settingsPalette"
        anchors.fill: parent
        onFinished: {
            const item = root.navDelegate(Settings.page);
            if (item)
                item.forceActiveFocus();
        }
    }

    Item {
        width: 1
        height: 1
        opacity: 0
        Accessible.role: Accessible.AlertMessage
        Accessible.name: Settings.announcement
    }
}
