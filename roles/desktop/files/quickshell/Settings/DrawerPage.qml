pragma ComponentBehavior: Bound
import QtQuick
import "../Common"

// Drawer page (turn-3 settings design): the edge drawer's tab strip — order
// and visibility — what its Overview tab shows, and how the drawer opens.
// Tab rows reorder by drag or by the same keyboard grammar the Widgets page
// uses: Space picks up, arrows move, Space drops, Escape cancels.
SettingsPage {
    id: page

    readonly property var tabMeta: ({
        overview: { glyph: "dashboard", label: "Overview", from: "the Fedora button" },
        sound: { glyph: "volume_down", label: "Sound", from: "the volume glyph" },
        network: { glyph: "wifi", label: "Network", from: "the network glyphs" },
        bluetooth: { glyph: "bluetooth", label: "Bluetooth", from: "the Bluetooth glyph" },
        power: { glyph: "battery_5_bar", label: "Power", from: "the battery glyph" },
        notifications: { glyph: "notifications", label: "Notifications", from: "the bell" },
        usage: { glyph: "insights", label: "Model usage", from: "the usage pill" }
    })

    readonly property var overviewRows: [
        { key: "media", label: "Now playing",
            description: "Current track and controls at the top of Overview" },
        { key: "sliders", label: "Sliders",
            description: "Brightness and volume, always in reach" },
        { key: "tiles", label: "Quick toggles",
            description: "The Dark, Focus, Night and Awake tiles" },
        { key: "updates", label: "Updates",
            description: "Pending system updates with the install action" }
    ]

    // ---- tab reorder state ------------------------------------------------
    property int dragIndex: -1
    property int dropIndex: -1
    property real dragY: 0
    property string announcement: ""
    readonly property bool tabDragActive: dragIndex !== -1
    readonly property int tabPitch: 36

    function beginDrag(index) {
        dragIndex = index;
        dropIndex = index;
        announcement = page.tabMeta[Settings.drawerTabs[index].id].label
            + " picked up. Use arrow keys to move.";
    }

    function moveDrop(delta) {
        if (!tabDragActive)
            return;
        dropIndex = Math.max(0, Math.min(Settings.drawerTabs.length - 1,
            dropIndex + delta));
    }

    function cancelTabDrag() {
        dragIndex = -1;
        dropIndex = -1;
    }

    function commitTabDrag() {
        if (!tabDragActive) {
            return;
        }
        const from = dragIndex;
        const to = dropIndex;
        cancelTabDrag();
        if (from === to)
            return;
        const ids = Settings.drawerTabs.map(tab => tab.id);
        const moved = ids.splice(from, 1)[0];
        ids.splice(to, 0, moved);
        Settings.setDrawerTabOrder(ids);
        announcement = page.tabMeta[moved].label + " moved to position "
            + (to + 1) + ".";
    }

    Column {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Theme.settingsGroupSpacing

        SettingsGroup {
            width: parent.width
            title: "Tabs"

            SettingsHint {
                width: parent.width
                text: "Drag to reorder Control Center tabs; switch one off to hide it"
            }

            Item {
                width: parent.width
                height: Settings.drawerTabs.length * page.tabPitch

                Column {
                    width: parent.width
                    spacing: 2

                    Repeater {
                        id: tabRepeater
                        model: Settings.drawerTabs

                        delegate: Rectangle {
                            id: tabRow

                            required property var modelData
                            required property int index

                            readonly property var meta: page.tabMeta[modelData.id]
                            readonly property bool locked: modelData.id === "overview"
                            readonly property bool dragged: page.dragIndex === index

                            width: parent.width
                            height: page.tabPitch - 2
                            radius: Theme.rowRadius
                            color: "transparent"
                            opacity: tabRow.dragged ? 0.35 : 1
                            border.width: activeFocus ? 1 : 0
                            border.color: Theme.accentText
                            activeFocusOnTab: index === 0
                            Accessible.role: Accessible.ListItem
                            Accessible.name: tabRow.meta.label + " tab"
                            Accessible.description: page.tabDragActive
                                ? "Drag in progress" : "Press Space to pick up"
                            Accessible.selected: tabRow.dragged

                            Keys.onPressed: event => {
                                if (event.key === Qt.Key_Space) {
                                    if (page.tabDragActive)
                                        page.commitTabDrag();
                                    else
                                        page.beginDrag(index);
                                    event.accepted = true;
                                } else if (event.key === Qt.Key_Escape && page.tabDragActive) {
                                    page.cancelTabDrag(); event.accepted = true;
                                } else if (page.tabDragActive && (event.key === Qt.Key_Up
                                        || event.key === Qt.Key_Down)) {
                                    page.moveDrop(event.key === Qt.Key_Up ? -1 : 1);
                                    event.accepted = true;
                                } else if (!page.tabDragActive && (event.key === Qt.Key_Up
                                        || event.key === Qt.Key_Down)) {
                                    const next = tabRepeater.itemAt(index
                                        + (event.key === Qt.Key_Up ? -1 : 1));
                                    if (next)
                                        next.forceActiveFocus();
                                    event.accepted = true;
                                }
                            }

                            MouseArea {
                                id: tabDragArea
                                anchors.left: parent.left
                                anchors.top: parent.top
                                anchors.bottom: parent.bottom
                                width: labelText.x + labelText.width
                                cursorShape: page.tabDragActive
                                    ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                                preventStealing: true

                                property real pressY

                                onPressed: mouse => pressY = mouse.y
                                onPositionChanged: mouse => {
                                    if (!page.tabDragActive) {
                                        if (Math.abs(mouse.y - pressY) < 4)
                                            return;
                                        page.beginDrag(tabRow.index);
                                    }
                                    const local = tabDragArea.mapToItem(
                                        tabRow.parent, mouse.x, mouse.y);
                                    page.dragY = local.y;
                                    page.dropIndex = Math.max(0, Math.min(
                                        Settings.drawerTabs.length - 1,
                                        Math.floor(local.y / page.tabPitch)));
                                }
                                onReleased: {
                                    if (page.tabDragActive)
                                        page.commitTabDrag();
                                }
                                onCanceled: page.cancelTabDrag()
                                onClicked: tabRow.forceActiveFocus()
                            }

                            // The rule between rows, as SettingsRow draws it.
                            Rectangle {
                                visible: tabRow.index > 0
                                x: Theme.settingsMarkInset
                                y: -2
                                width: Math.max(0, parent.width - x)
                                height: 1
                                color: Theme.hairlineSoft
                            }

                            // The grip sits in the modified-mark gutter so the
                            // icon and name line up with row labels.
                            Sym {
                                id: handle
                                x: Math.max(0, Math.round((Theme.settingsMarkInset - width) / 2) - 1)
                                anchors.verticalCenter: parent.verticalCenter
                                name: "drag_indicator"
                                size: Theme.iconSmall
                                color: Theme.textDim
                            }

                            Sym {
                                id: tabGlyph
                                x: Theme.settingsMarkInset
                                anchors.verticalCenter: parent.verticalCenter
                                name: tabRow.meta.glyph
                                size: Theme.iconMedium
                                rotation: tabRow.meta.rotate === true ? 90 : 0
                                color: Theme.icon
                            }

                            Text {
                                id: labelText
                                anchors.left: tabGlyph.right
                                anchors.leftMargin: 10
                                anchors.verticalCenter: parent.verticalCenter
                                width: 110
                                text: tabRow.meta.label
                                font.family: Theme.fontMenu
                                font.pixelSize: Theme.typography.control
                                font.weight: Theme.weightMedium
                                color: Theme.textHi
                                elide: Text.ElideRight
                            }

                            Text {
                                anchors.left: labelText.right
                                anchors.leftMargin: 10
                                anchors.right: tabToggle.left
                                anchors.rightMargin: 10
                                anchors.verticalCenter: parent.verticalCenter
                                text: tabRow.locked
                                    ? "opens from " + tabRow.meta.from + " · always on"
                                    : "opens from " + tabRow.meta.from
                                font.family: Theme.fontMenu
                                font.pixelSize: Theme.typography.secondary
                                color: Theme.textDim
                                elide: Text.ElideRight
                            }

                            Toggle {
                                id: tabToggle
                                // Ends where every row's control ends, clear
                                // of the reset column.
                                anchors.right: parent.right
                                anchors.rightMargin: Theme.chipHeight + 2
                                anchors.verticalCenter: parent.verticalCenter
                                metrics: Theme.switchCompact
                                checked: tabRow.modelData.on
                                enabled: !tabRow.locked
                                opacity: tabRow.locked ? 0.4 : 1
                                accessibleName: "Show the " + tabRow.meta.label + " tab"
                                onToggled: value =>
                                    Settings.setDrawerTabEnabled(tabRow.modelData.id, value)
                            }
                        }
                    }
                }

                // Insertion caret in the row gap — an overlay, so rows never
                // move while a drag is in flight.
                Rectangle {
                    visible: page.tabDragActive
                    x: 2
                    width: parent.width - 4
                    height: 2
                    radius: 1
                    y: Math.max(0, page.dropIndex) * page.tabPitch - 1
                        + (page.dropIndex > page.dragIndex ? page.tabPitch - 2 : 0)
                    color: Theme.accent
                    z: 10
                }
            }
        }

        SettingsGroup {
            width: parent.width
            title: "Overview"

            Repeater {
                model: page.overviewRows

                delegate: SwitchRow {
                    required property var modelData
                    width: parent.width
                    label: modelData.label
                    description: modelData.description
                    checked: Settings.drawerOverview[modelData.key] === true
                    dirty: Settings.drawerOverview[modelData.key]
                        !== Settings.defaults.drawerOverview[modelData.key]
                    onToggled: value =>
                        Settings.setDrawerOverviewKey(modelData.key, value)
                    onResetRequested: Settings.setDrawerOverviewKey(modelData.key,
                        Settings.defaults.drawerOverview[modelData.key])
                }
            }
        }

        SettingsGroup {
            width: parent.width
            title: "Behavior"

            PickerRow {
                width: parent.width
                label: "Open on hover"
                settingKey: "drawerHover"
                hint: Settings.drawerHover === "always"
                    ? "Pointing at a bar icon opens its tab"
                    : Settings.drawerHover === "open"
                    ? "While the drawer is open, pointing at another bar icon switches to its tab"
                    : "Click a bar icon to open its tab"
                model: [
                    { value: "off", label: "Off" },
                    { value: "open", label: "While open" },
                    { value: "always", label: "Always" }
                ]
            }

            SliderRow {
                width: parent.width
                label: "Width"
                settingKey: "drawerWidth"
                min: 320; max: 480; step: 10; unit: "px"
                valueWidth: 52
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
