pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls as Controls
import Quickshell.Services.SystemTray
import "../Common"
import "../Common/LayoutHelpers.js" as LayoutHelpers
import "../Common/WidgetCatalog.js" as WidgetCatalog
import "../Common/WidgetEditor.js" as Editor

Item {
    id: page
    readonly property var entries: Editor.catalog(Settings.mods, UserPlugins.widgets, WidgetCatalog.WIDGETS)
    readonly property var availableEntries: Editor.search(entries, "", "available")
    readonly property var selected: entries.find(entry => entry.key === subPage) || null
    property string subPage: ""
    property bool presetsOpen: false
    property string preset: "focused"
    // The catalog as the chosen preset would leave it, for the bar preview:
    // presets switch built-ins on and off and leave plugins alone.
    readonly property var presetEntries: {
        const ids = Settings.modulePresetIds(preset);
        return entries.map(entry => entry.plugin ? entry
            : Object.assign({}, entry, { enabled: ids.indexOf(entry.id) !== -1 }));
    }
    readonly property bool subPageActive: subPage !== "" || presetsOpen
    property var dragMod: null
    property var dropAt: null
    readonly property bool dragActive: dragMod !== null
    property string announcement: ""
    property string pendingFocus: ""
    property var dragRow: null
    property point dragViewportPoint: Qt.point(0, 0)

    // SettingsView incubates pages asynchronously, and a Repeater nested in
    // that incubation builds its delegates asynchronously too, in completion
    // order: Center and Right would land before Left and then get shoved down,
    // with pills popping in afterwards. Stay transparent until every section
    // and pill exists so the page appears in one piece.
    property bool built: false
    opacity: built ? 1 : 0
    function checkBuilt() {
        if (built || sections.count !== 3)
            return;
        for (let i = 0; i < sections.count; i++) {
            const group = sections.itemAt(i) as ArrangementSection;
            if (!group || !group.complete())
                return;
        }
        built = true;
    }
    // Never leave the page invisible if a delegate fails to incubate.
    Timer { interval: 500; running: !page.built; onTriggered: page.built = true }

    readonly property var runtimeState: ({ media: Media.hasTrack,
        weather: Weather.ready || Weather.offline || !Weather.locationSet,
        weatherLocation: Weather.locationSet, bluetooth: BluetoothState.connected, battery: Battery.isLaptop,
        updates: Updates.total > 0 || Updates.error !== "" || Updates.runState !== "idle" || Updates.rebootRecommended,
        tray: SystemTray.items.values.length > 0 })

    function openSubPage(id) {
        if (dragActive)
            return;
        presetsOpen = false;
        subPage = id;
        openedFromPreview = false;
        detailPage.contentY = 0;
        widgetDialog.open();
    }
    // The pinned preview is a pointer shortcut to the same dialog. Closing it
    // then leaves the page where it was, instead of scrolling up to the
    // widget's pill to hand it focus.
    property bool openedFromPreview: false
    function openFromPreview(id) {
        openSubPage(id);
        openedFromPreview = subPage === id;
    }
    // Another page asked for one widget's options (System's Stay awake links
    // to Indicators). Honour it once the catalog knows the widget.
    function takeWidgetRequest() {
        const id = Settings.widgetRequest;
        if (id === "" || !entries.some(entry => entry.key === id))
            return;
        Settings.widgetRequest = "";
        openSubPage(id);
    }
    Connections {
        target: Settings
        function onWidgetRequestChanged() { page.takeWidgetRequest(); }
    }
    Component.onCompleted: {
        Qt.callLater(page.takeWidgetRequest);
        page.checkBuilt();
    }
    function closeSubPage() {
        if (presetsOpen) presetsOpen = false;
        else widgetDialog.close();
        moreAction.forceActiveFocus();
    }
    function cancelDrag() { dragMod = null; dropAt = null; dragRow = null; }
    function sectionEntries(section) { return Editor.sectionEntries(entries, section); }
    function status(entry) { return Editor.status(entry, runtimeState); }
    property var pendingMembership: null
    property var undoRemoved: null
    property string notice: ""
    readonly property bool membershipBusy: pendingMembership !== null || UserPlugins.busy
    function setEnabled(entry, enabled, undoing, section) {
        if (!entry || membershipBusy) return;
        const destination = section || entry.section;
        const change = { key: entry.key, name: entry.name, enabled: enabled, section: destination,
            undoing: !!undoing, acknowledged: false };
        if (entry.plugin) {
            pendingMembership = change;
            membershipTimeout.restart();
            const changes = { enabled: enabled };
            if (enabled && section) changes.section = section;
            UserPlugins.configureWidget(entry.descriptor, changes);
        } else {
            if (enabled && section) {
                const result = LayoutHelpers.moveWidget(Settings.mods, entry.section, entry.id,
                    destination, Settings.mods[destination].length);
                if (result) Settings.setModuleOrder(result.mods.left, result.mods.center, result.mods.right);
            }
            Settings.setModuleEnabled(entry.id, enabled);
            finishMembership(change);
        }
    }
    function finishMembership(change) {
        pendingMembership = null;
        membershipTimeout.stop();
        if (!change.enabled) undoRemoved = { key: change.key, name: change.name };
        else undoRemoved = null;
        notice = change.name + (change.undoing ? " restored to your bar" : change.enabled ? " added to your bar" : " removed from bar");
        announcement = notice;
        noticeTimer.restart();
        membershipFocus.key = change.key;
        membershipFocus.section = change.section;
        membershipFocus.available = !change.enabled;
        membershipFocus.restart();
    }
    Timer {
        id: membershipFocus
        property string key: ""
        property string section: ""
        property bool available: false
        interval: 16
        onTriggered: {
            const trayIndex = page.trayFocusIndex;
            page.trayFocusIndex = -1;
            if (widgetDialog.visible) return;
            if (available) page.focusSection(section);
            else if (!page.focusTray(trayIndex)) page.focusEntry(key);
        }
    }
    // Adding from the tray keeps the keyboard in the tray, on the chip that
    // took the added one's place, so several widgets can be added in a row
    // without the page scrolling up to each lane; the preview shows where
    // each one landed.
    property int trayFocusIndex: -1
    function addFromTray(entry, index, section) {
        trayFocusIndex = index;
        setEnabled(entry, true, false, section);
    }
    function focusTray(index) {
        if (index < 0 || availableRows.count === 0) return false;
        const row = availableRows.itemAt(Math.min(index, availableRows.count - 1)) as WidgetPill;
        if (!row) return false;
        row.forceActiveFocus();
        return true;
    }
    function confirmMembership() {
        const change = pendingMembership;
        if (change && change.acknowledged && entries.some(entry => entry.key === change.key && entry.enabled === change.enabled && entry.section === change.section))
            finishMembership(change);
    }
    onEntriesChanged: {
        confirmMembership();
        if (undoRemoved && !entries.some(entry => entry.key === undoRemoved.key && !entry.enabled)) undoRemoved = null;
    }
    Timer {
        id: membershipTimeout
        interval: 10000
        onTriggered: {
            page.pendingMembership = null;
            page.undoRemoved = null;
            page.notice = "Could not confirm the change. Check the widget and try again.";
            noticeTimer.restart();
        }
    }
    Timer { id: noticeTimer; interval: 8000; onTriggered: { page.notice = ""; page.undoRemoved = null; } }
    function move(entry, section, gap) {
        if (!entry || membershipBusy) return;
        const plan = Editor.dropPlan(entries, Settings.mods, entry, section, gap);
        if (entry.plugin) {
            pendingFocus = entry.key;
            UserPlugins.moveWidget(entry.pluginKey, section, plan.index);
        }
        else {
            const result = LayoutHelpers.moveWidget(Settings.mods, entry.section, entry.id, section, plan.index);
            if (result) Settings.setModuleOrder(result.mods.left, result.mods.center, result.mods.right);
        }
        announcement = entry.name + " moved to " + section + ".";
        Qt.callLater(() => focusEntry(entry.key));
    }
    function focusEntry(key) {
        for (let i = 0; i < availableRows.count; i++) {
            const row = availableRows.itemAt(i) as WidgetPill;
            if (row && row.entry.key === key) row.forceActiveFocus();
        }
        for (let i = 0; i < sections.count; i++) {
            const group = sections.itemAt(i) as ArrangementSection;
            if (group) group.focusEntry(key);
        }
    }
    // After a removal, keep the keyboard in the lane the widget left; an
    // emptied lane hands focus to the layout actions above it.
    function focusSection(section) {
        for (let i = 0; i < sections.count; i++) {
            const group = sections.itemAt(i) as ArrangementSection;
            if (group && group.section === section && group.focusFirst()) return;
        }
        moreAction.forceActiveFocus();
    }
    function canMove(entry, delta) {
        if (!entry || !entry.enabled || membershipBusy) return false;
        const peers = sectionEntries(entry.section).filter(item => item.plugin === entry.plugin);
        const index = peers.findIndex(item => item.key === entry.key);
        return index + delta >= 0 && index + delta < peers.length;
    }
    function keyboardMove(entry, delta) {
        if (!canMove(entry, delta)) return;
        const list = sectionEntries(entry.section);
        const index = list.findIndex(item => item.key === entry.key);
        const peers = list.filter(item => item.plugin === entry.plugin);
        const at = peers.findIndex(item => item.key === entry.key);
        if (at + delta < 0 || at + delta >= peers.length) return;
        move(entry, entry.section, index + (delta < 0 ? -1 : 2));
    }
    function updateDrop(row, x, y) {
        if (!dragActive || !row) return;
        dragRow = row;
        const point = row.mapToItem(arrangement, x, y);
        dragViewportPoint = point;
        if (point.x < 0 || point.x > arrangement.width || point.y < 0 || point.y > arrangement.height) {
            dropAt = null;
            return;
        }
        for (let i = 0; i < sections.count; i++) {
            const group = sections.itemAt(i) as ArrangementSection;
            const local = row.mapToItem(group, x, y);
            if (local.y >= 0 && local.y <= group.height) {
                dropAt = Editor.dropPlan(entries, Settings.mods, dragMod, group.section, group.gapAt(local.x, local.y));
                return;
            }
        }
        dropAt = null;
    }
    function commitDrag() {
        const entry = dragMod;
        const target = dropAt;
        cancelDrag();
        if (entry && target) move(entry, target.section, target.gap);
    }

    Connections {
        target: UserPlugins
        function onWidgetMembershipFinished(key, enabled, success, message) {
            if (!page.pendingMembership || page.pendingMembership.key !== "plugin:" + key) return;
            if (!success) {
                page.pendingMembership = null;
                membershipTimeout.stop();
                page.undoRemoved = null;
                page.notice = message;
                noticeTimer.restart();
                return;
            }
            page.pendingMembership.acknowledged = true;
            page.confirmMembership();
        }
        function onWidgetsChanged() {
            if (page.pendingFocus !== "") {
                const key = page.pendingFocus;
                page.pendingFocus = "";
                Qt.callLater(() => page.focusEntry(key));
            }
        }
    }
    Timer {
        interval: 40
        repeat: true
        running: page.dragActive && page.dragRow !== null
        onTriggered: {
            const point = page.dragViewportPoint;
            const delta = point.y < 36 ? -12 : point.y > arrangement.height - 36 ? 12 : 0;
            if (delta) {
                arrangement.contentY = Math.max(0, Math.min(Math.max(0, arrangement.contentHeight - arrangement.height), arrangement.contentY + delta));
                const local = page.dragRow.mapFromItem(arrangement, point.x, point.y);
                page.updateDrop(page.dragRow, local.x, local.y);
            }
        }
    }

    // One section of the bar as a settings row: the section's name in the
    // label column and its widgets, in bar order, where a row's control goes.
    // No card around it (2026-09 redesign): lanes are separated by the same
    // hairline as every other row, and a drop target lights up instead.
    component ArrangementSection: Item {
        id: group
        required property string modelData
        readonly property string section: modelData
        readonly property var widgets: page.sectionEntries(section)
        readonly property string title: section.charAt(0).toUpperCase() + section.slice(1)
        readonly property bool narrow: width < Theme.settingsNarrowWidth
        readonly property int pad: narrow ? 0 : Theme.scaled(4)
        readonly property real laneX: narrow ? Theme.settingsMarkInset
            : Theme.settingsMarkInset + Theme.settingsLabelWidth
        readonly property bool dropTarget: page.dragActive && page.dropAt !== null
            && page.dropAt.section === section
        width: parent ? parent.width : 0
        height: lane.y + lane.height + pad
        Accessible.role: Accessible.Grouping
        Accessible.name: title + " section, " + widgets.length
            + (widgets.length === 1 ? " widget" : " widgets")

        function focusFirst() {
            const row = rows.itemAt(0) as WidgetPill;
            if (!row) return false;
            row.forceActiveFocus();
            return true;
        }
        function complete() {
            for (let i = 0; i < widgets.length; i++)
                if (!rows.itemAt(i)) return false;
            return true;
        }
        function focusEntry(key) {
            for (let i = 0; i < rows.count; i++) {
                const row = rows.itemAt(i) as WidgetPill;
                if (row && row.entry.key === key) row.forceActiveFocus();
            }
        }
        function gapAt(x, y) {
            const point = group.mapToItem(widgetGrid, x, y);
            return Editor.gridGap(widgets.length, widgetGrid.columns, widgetGrid.cellWidth,
                widgetGrid.cellHeight, widgetGrid.spacing, point.x, point.y);
        }
        function markerPosition(gap) {
            const at = Math.max(0, Math.min(widgets.length, gap));
            const preceding = at === widgets.length && at > 0;
            const index = preceding ? at - 1 : at;
            return Qt.point((index % widgetGrid.columns) * (widgetGrid.cellWidth + widgetGrid.spacing)
                + (preceding ? widgetGrid.cellWidth + 3 : -5),
                Math.floor(index / widgetGrid.columns) * (widgetGrid.cellHeight + widgetGrid.spacing));
        }

        // The rule between lanes, where SettingsRow draws its own.
        Rectangle {
            visible: group.y > 0
            x: Theme.settingsMarkInset
            y: -Math.ceil(Theme.settingsRowSpacing / 2) - 1
            width: Math.max(0, group.width - x)
            height: 1
            color: Theme.hairlineSoft
        }
        Rectangle {
            anchors.fill: parent
            anchors.leftMargin: -6
            anchors.rightMargin: -6
            radius: Theme.rowRadius
            color: Theme.accentAlpha(0.10)
            opacity: group.dropTarget ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: Theme.chipFadeDuration } }
        }
        Text {
            id: sectionLabel
            x: Theme.settingsMarkInset
            y: group.pad + (Theme.settingsControlHeight - height) / 2
            width: group.narrow ? group.width - x : Theme.settingsLabelWidth - Theme.controlSpacing
            text: group.title
            font.family: Theme.fontMenu
            font.pixelSize: Theme.typography.control
            color: group.dropTarget ? Theme.textHi : Theme.textMid
            elide: Text.ElideRight
        }
        Item {
            id: lane
            x: group.laneX
            y: group.narrow ? sectionLabel.y + sectionLabel.height + Theme.settingsContentSpacing : group.pad
            // Ends on the page's control edge, clear of the reset column.
            width: Math.max(0, group.width - Theme.chipHeight - x)
            height: group.widgets.length ? widgetGrid.height : emptyHint.height
            Grid {
                id: widgetGrid
                width: parent.width
                columns: Math.max(1, Math.min(3, Math.floor((width + spacing) / (Theme.scaled(150, Theme.typeScale) + spacing))))
                spacing: Theme.scaled(6)
                readonly property real cellWidth: (width - (columns - 1) * spacing) / columns
                readonly property real cellHeight: Theme.settingsControlHeight
                Repeater {
                    id: rows
                    model: group.widgets
                    onItemAdded: page.checkBuilt()
                    delegate: WidgetPill {
                        id: widgetRow
                        required property var modelData
                        entry: modelData
                        width: widgetGrid.cellWidth
                        height: widgetGrid.cellHeight
                        status: page.status(modelData)
                        draggable: !page.membershipBusy
                        dragInProgress: page.dragActive && page.dragMod.key === modelData.key
                        actionsEnabled: !page.membershipBusy && !page.dragActive
                        canMoveEarlier: page.canMove(modelData, -1)
                        canMoveLater: page.canMove(modelData, 1)
                        onActivated: page.openSubPage(modelData.key)
                        onRemoveRequested: page.setEnabled(modelData, false)
                        onMoveRequested: section => page.move(modelData, section, page.sectionEntries(section).length)
                        onKeyboardMove: delta => page.keyboardMove(modelData, delta)
                        onDragStarted: page.dragMod = modelData
                        onDragMoved: (x, y) => page.updateDrop(widgetRow, x, y)
                        onDragFinished: page.commitDrag()
                        onDragCanceled: page.cancelDrag()
                    }
                }
            }
            Caption {
                id: emptyHint
                width: parent.width
                height: visible ? Math.max(Theme.settingsControlHeight, implicitHeight) : 0
                verticalAlignment: Text.AlignVCenter
                visible: group.widgets.length === 0
                color: Theme.textFaint
                text: "Empty. Drag a widget here, or add one from the widgets below."
            }
            Rectangle {
                // Beside the Grid, not in it, so the marker never takes a cell.
                readonly property point position: group.markerPosition(page.dropAt ? page.dropAt.gap : 0)
                x: position.x
                y: position.y
                width: 3
                height: widgetGrid.cellHeight
                radius: 1
                visible: group.dropTarget
                color: Theme.accentText
            }
        }
    }

    component Caption: Text {
        font.family: Theme.fontMenu
        font.pixelSize: Theme.typography.secondary
        color: Theme.textDim
        wrapMode: Text.Wrap
    }
    component Heading: Text {
        font.family: Theme.fontMenu
        font.pixelSize: Theme.typography.primary
        font.weight: Theme.weightSemibold
        color: Theme.textHi
    }

    // Where the scrolling column sits, so the pinned header lines up with it.
    readonly property real columnX: Math.max(0,
        Math.floor((arrangement.width - arrangement.scrollGutter - arrangement.columnWidth) / 2))

    // ---- pinned header ---------------------------------------------------
    // The preview stays in view above the scrolling page, so every row below
    // it — a widget, the height, the style, the colour — can be watched
    // changing the bar. It sits outside the Flickable rather than in its
    // overlay: the page clips under it, so glass surfaces need no mask.
    Item {
        id: header
        x: page.columnX
        width: arrangement.columnWidth
        height: toolbar.y + toolbar.height

        BarPreview {
            id: preview
            // From the label edge to the control edge, like every row.
            x: Theme.settingsMarkInset
            width: Math.max(0, parent.width - x - Theme.chipHeight)
            entries: page.presetsOpen ? page.presetEntries : page.entries
            draggingKey: page.dragMod ? page.dragMod.key : ""
            interactive: !page.presetsOpen
            // Never taller than a fifth of the page: on a short window the
            // rows it previews need the room more.
            height: Math.min(implicitHeight, Math.max(Theme.scaled(64), Math.round(page.height * 0.2)))
            onWidgetActivated: key => page.openFromPreview(key)
        }

        Item {
            id: toolbar
            x: preview.x
            y: preview.height + Theme.settingsContentSpacing
            width: preview.width
            height: Math.max(moreAction.height, toolbarCaption.implicitHeight)
            Caption {
                id: toolbarCaption
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - moreAction.width - Theme.controlSpacing
                maximumLineCount: 2
                elide: Text.ElideRight
                text: page.presetsOpen
                    ? "The preview shows the " + page.presetLabel(page.preset) + " preset. Apply it below to use it."
                    : "Drag widgets to reorder them or move them between sections. Select one to change it."
            }
            SettingsAction {
                id: moreAction
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: "Widget layout actions"
                glyph: "more_horiz"
                compact: true
                enabled: !page.dragActive && !page.membershipBusy
                onTriggered: moreMenu.popup(moreAction, 0, moreAction.height)
                Controls.Menu {
                    id: moreMenu
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
                        text: "Presets…"
                        onTriggered: page.presetsOpen = true
                    }
                    Controls.MenuItem {
                        text: "Manage plugins…"
                        onTriggered: Settings.page = "plugins"
                    }
                    Controls.MenuItem {
                        text: "Restore default built-in layout"
                        onTriggered: Settings.resetKeys(["mods"], "Widgets")
                    }
                    Controls.MenuItem {
                        text: "Undo layout change"
                        enabled: Settings.undoAvailable && (Settings.resetLabel === "Widget profile" || Settings.resetLabel === "Widgets")
                        onTriggered: Settings.undoReset()
                    }
                }
            }
        }
    }

    // A rule under the header once the page has scrolled beneath it.
    Rectangle {
        x: header.x + Theme.settingsMarkInset
        y: header.y + header.height + Math.round(Theme.settingsContentSpacing / 2)
        width: Math.max(0, header.width - Theme.settingsMarkInset)
        height: 1
        color: Theme.hairlineSoft
        visible: arrangement.visible && arrangement.contentY > 0
    }

    function presetLabel(value) {
        const hit = presetChoices.find(choice => choice.value === value);
        return hit ? hit.label : value;
    }
    readonly property var presetChoices: [
        { value: "focused", label: "Focused" },
        { value: "connected", label: "Connected" },
        { value: "everything", label: "Everything" }
    ]

    SettingsPage {
        id: arrangement
        anchors.top: header.bottom
        anchors.topMargin: Theme.settingsContentSpacing
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: noticeBar.visible ? noticeBar.top : parent.bottom
        anchors.bottomMargin: 8
        visible: !page.presetsOpen
        interactive: !page.dragActive && contentHeight > height
        pageReset: true
        resetSection: "bar"
        Column {
            width: parent.width
            spacing: Theme.settingsGroupSpacing
            SettingsGroup {
                width: parent.width
                title: "Widgets"
                Repeater {
                    id: sections
                    model: ["left", "center", "right"]
                    delegate: ArrangementSection {}
                    onItemAdded: page.checkBuilt()
                }
            }
            // Everything that is not on the bar, built-in or from a plugin,
            // in one tray: one click adds it where it last lived.
            SettingsGroup {
                width: parent.width
                title: "Add widgets"
                Flow {
                    id: availableFlow
                    x: Theme.settingsMarkInset
                    width: Math.max(0, parent.width - x - Theme.chipHeight)
                    spacing: Theme.controlSpacing
                    visible: page.availableEntries.length > 0
                    Repeater {
                        id: availableRows
                        model: page.availableEntries
                        delegate: WidgetPill {
                            required property var modelData
                            required property int index
                            entry: modelData
                            width: Math.min(naturalWidth, availableFlow.width)
                            status: page.status(modelData)
                            draggable: false
                            actionsEnabled: !page.membershipBusy && !page.dragActive
                            onActivated: page.openSubPage(modelData.key)
                            onAddRequested: page.addFromTray(modelData, index)
                            onMoveRequested: section => page.addFromTray(modelData, index, section)
                        }
                    }
                }
                SettingsHint {
                    width: parent.width
                    text: page.availableEntries.length > 0
                        ? "Select a widget to add it to its section, or use ⋯ to pick another section. Widgets from plugins show up here too."
                        : "Every widget is on the bar. Widgets from plugins show up here too."
                }
                SettingsHint {
                    width: parent.width
                    text: UserPlugins.error || (UserPlugins.busy ? "Saving plugin changes…" : "")
                    tone: UserPlugins.error ? "error" : "info"
                }
            }
            BarLayoutGroups {
                width: parent.width
            }
        }
    }

    Rectangle {
        id: dragGhost
        x: Math.max(0, Math.min(page.width - width, page.dragViewportPoint.x - width / 2))
        y: arrangement.y + page.dragViewportPoint.y - height / 2
        width: Math.min(Theme.scaled(190, Theme.typeScale), page.width)
        height: Theme.settingsControlHeight
        radius: Theme.chipRadius
        visible: page.dragActive
        color: Theme.popBg
        border.width: 1
        border.color: Theme.accentText
        opacity: 0.9
        z: 10
        Row {
            anchors.fill: parent
            anchors.leftMargin: Theme.controlSpacing
            anchors.rightMargin: Theme.controlSpacing
            spacing: Theme.iconTextSpacing
            Sym {
                anchors.verticalCenter: parent.verticalCenter
                name: page.dragMod ? page.dragMod.glyph || "extension" : "extension"
                size: Theme.iconSmall
                color: Theme.textMid
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - Theme.iconSmall - parent.spacing
                text: page.dragMod ? page.dragMod.name : ""
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.control
                font.weight: Theme.weightMedium
                color: Theme.textHi
                elide: Text.ElideRight
            }
        }
    }

    Controls.Popup {
        id: widgetDialog
        parent: Controls.Overlay.overlay
        anchors.centerIn: parent
        width: Math.min(Theme.scaled(620, Theme.typeScale), parent ? parent.width - 32 : 620)
        height: Math.min(660, parent ? parent.height - 32 : 660,
            Math.max(180, detailPage.contentHeight + dialogHeader.height + padding * 2 + 16))
        padding: 20
        modal: true
        focus: true
        popupType: Controls.Popup.Item
        closePolicy: Controls.Popup.CloseOnEscape
        onClosed: {
            const key = page.subPage;
            page.subPage = "";
            if (page.openedFromPreview) moreAction.forceActiveFocus();
            else Qt.callLater(() => page.focusEntry(key));
        }
        background: Rectangle {
            color: Theme.popBg
            radius: Theme.panelRadius
            border.width: 1
            border.color: Theme.stroke
        }
        contentItem: Item {
            Row {
                id: dialogHeader
                width: parent.width
                spacing: 4
                Heading {
                    width: parent.width - closeAction.width - parent.spacing
                        - (resetWidgetAction.visible ? resetWidgetAction.width + parent.spacing : 0)
                    text: page.selected ? page.selected.name : "Widget settings"
                    wrapMode: Text.Wrap
                    anchors.verticalCenter: parent.verticalCenter
                }
                // One widget's options back to defaults. The header's Reset
                // page would take the whole bar layout with it.
                SettingsAction {
                    id: resetWidgetAction
                    visible: page.selected !== null && !page.selected.plugin
                        && Settings.revision >= 0 && Settings.moduleDirty(page.selected.id)
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Reset widget"
                    glyph: "undo"
                    Accessible.name: "Reset " + (page.selected ? page.selected.name : "widget") + " options"
                    // The action hides once the widget is clean; hand focus
                    // on first so it and its tooltip are not stranded.
                    onTriggered: {
                        closeAction.forceActiveFocus();
                        Settings.resetModule(page.selected.id, page.selected.name);
                    }
                }
                SettingsAction {
                    id: closeAction
                    text: "Close widget settings"
                    glyph: "close"
                    compact: true
                    onTriggered: widgetDialog.close()
                }
            }
            SettingsPage {
                id: detailPage
                anchors.top: dialogHeader.bottom
                anchors.topMargin: 16
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                Column {
                    width: parent.width
                    spacing: Theme.settingsGroupSpacing
                    Column {
                        width: parent.width
                        spacing: Theme.settingsContentSpacing
                        SettingsHint {
                            width: parent.width
                            text: page.selected ? page.selected.description : ""
                        }
                        // Whether it is on the bar, and whether the bar is
                        // drawing it right now, on one row.
                        SwitchRow {
                            width: parent.width
                            label: "Show on bar"
                            description: page.selected ? page.status(page.selected) : ""
                            checked: page.selected !== null && page.selected.enabled
                            enabled: page.selected !== null && !page.membershipBusy
                            onToggled: value => page.setEnabled(page.selected, value)
                        }
                    }
                    Loader {
                        id: optionsLoader
                        width: parent.width
                        active: widgetDialog.visible
                        sourceComponent: !page.selected ? null : page.selected.plugin ? pluginOptions : builtinOptions
                    }
                }
            }
        }
    }

    Component {
        id: builtinOptions
        ModuleDetailView {
            width: optionsLoader.width
            height: contentHeight
            interactive: false
            inlineMode: true
            moduleId: page.selected ? page.selected.id : "clock"
            moduleName: page.selected ? page.selected.name : ""
            hasDetail: page.selected ? page.selected.detail : false
        }
    }
    Component {
        id: pluginOptions
        PluginWidgetSettings {
            width: optionsLoader.width
            descriptor: page.selected ? page.selected.descriptor : ({})
        }
    }

    Rectangle {
        id: noticeBar
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: Math.max(40, noticeText.implicitHeight + 16)
        visible: page.notice !== ""
        color: Theme.chip
        radius: Theme.rowRadius
        Caption {
            id: noticeText
            anchors.left: parent.left
            anchors.leftMargin: 10
            anchors.right: undoAction.left
            anchors.verticalCenter: parent.verticalCenter
            text: page.notice
            color: Theme.textHi
        }
        SettingsAction {
            id: undoAction
            anchors.right: dismissAction.left
            anchors.verticalCenter: parent.verticalCenter
            text: "Undo"
            glyph: "undo"
            visible: page.undoRemoved !== null
            width: visible ? implicitWidth : 0
            // SettingsAction supplies width rather than implicitWidth.
            implicitWidth: 86
            enabled: !page.membershipBusy
            onTriggered: page.setEnabled(page.entries.find(entry => entry.key === page.undoRemoved.key), true, true)
        }
        SettingsAction {
            id: dismissAction
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: "Dismiss"
            glyph: "close"
            compact: true
            onTriggered: { page.notice = ""; page.undoRemoved = null; noticeTimer.stop(); }
        }
    }

    // Presets, previewed on the bar above before they are applied.
    SettingsPage {
        anchors.top: header.bottom
        anchors.topMargin: Theme.settingsContentSpacing
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        visible: page.presetsOpen
        Column {
            width: parent.width
            spacing: Theme.settingsGroupSpacing
            SettingsAction {
                x: Theme.settingsMarkInset - Theme.scaled(4)
                text: "Back to widgets"
                glyph: "arrow_back"
                onTriggered: page.closeSubPage()
            }
            SettingsGroup {
                width: parent.width
                title: "Presets"
                PickerRow {
                    width: parent.width
                    label: "Preset"
                    hint: "Presets change which built-in widgets are on the bar. Placement, widget options and plugins are kept."
                    model: page.presetChoices
                    current: page.preset
                    onPicked: value => page.preset = value
                }
                SettingsHint {
                    width: parent.width
                    text: "Turns on " + Settings.modulePresetIds(page.preset).map(id => WidgetCatalog.widgetName(id)).join(", ") + "."
                }
                Item {
                    width: parent.width
                    height: applyPreset.height
                    SettingsAction {
                        id: applyPreset
                        anchors.right: parent.right
                        anchors.rightMargin: Theme.chipHeight
                        text: "Apply preset"
                        glyph: "check"
                        primary: true
                        onTriggered: { Settings.applyModulePreset(page.preset); page.presetsOpen = false; }
                    }
                }
            }
        }
    }
    Item {
        width: 1; height: 1
        opacity: 0
        Accessible.role: Accessible.AlertMessage
        Accessible.name: page.announcement
    }
}
