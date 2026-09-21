pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Services.Notifications
import "../Common"
import "../Common/Format.js" as Format

// Notification center built from the same anatomy as the popup card: source
// icon, app · summary header, timestamp, wrapped body, whole-card default
// activation, contextual actions, and hover-to-dismiss. Repeated sources are
// collapsed under one card and expand into a source-headed list.
Surface {
    id: root

    implicitWidth: availableWidth > 0
        ? Math.min(Theme.popWideWidth, availableWidth) : Theme.popWideWidth
    spacing: 10
    focus: visible

    property Item initialCard: null
    property string announcement: ""
    property bool announcementReady: false

    Keys.onEscapePressed: Popouts.close()

    function focusInitial() {
        if (!visible)
            return;
        Qt.callLater(() => {
            const target = root.initialCard && root.initialCard.visible
                    && root.initialCard.activeFocusOnTab
                ? root.initialCard : clearAll.enabled ? clearAll : dndToggle;
            if (target)
                target.forceActiveFocus();
        });
    }

    function moveFocus(item, forward) {
        const next = item.nextItemInFocusChain(forward);
        if (next)
            next.forceActiveFocus();
    }

    onVisibleChanged: focusInitial()

    Connections {
        target: Notifs

        function onCountChanged() {
            if (!root.announcementReady)
                return;
            root.announcement = Notifs.count === 0 ? "No notifications"
                : Notifs.count + (Notifs.count === 1
                    ? " notification" : " notifications");
        }
    }

    SystemClock {
        id: relativeClock
        precision: SystemClock.Seconds
    }

    property var expandedApps: ({})

    function toggleApp(app) {
        const next = Object.assign({}, expandedApps);
        next[app] = !next[app];
        expandedApps = next;
    }

    function clearGroup(group) {
        for (const entry of group.items)
            Notifs.dismiss(entry);
    }

    readonly property var groups: {
        const seen = {};
        const list = [];
        for (const entry of Notifs.entries.slice(0, 18)) {
            const key = entry.displayAppName || "Other";
            let group = seen[key];
            if (!group) {
                group = { app: key, items: [] };
                seen[key] = group;
                list.push(group);
            }
            group.items.push(entry);
        }
        return list;
    }

    readonly property real nowMs: relativeClock.date.getTime()
    readonly property var recentGroups: groups.filter(group =>
        nowMs - group.items[0].arrived < Format.MS_HOUR)
    readonly property var earlierGroups: groups.filter(group =>
        nowMs - group.items[0].arrived >= Format.MS_HOUR)

    // ---- card wiring ----------------------------------------------------

    // Centre type: this is menubar chrome, so it follows the menu font and
    // the popover scale. Common/NotifCard.qml draws the anatomy; everything
    // that differs between a toast and a centre row arrives through here.
    readonly property var cardStyle: ({
        face: Theme.fontMenu,
        header: Theme.typography.notification,
        body: Theme.typography.notification,
        bodyColor: Theme.textLow,
        bodyLines: 2,
        bodyLeading: 1.25,
        stampFace: Theme.fontMenu,
        stampSize: Theme.fontCaption,
        stampCentred: false,
        trailingHeight: 20,
        close: Theme.fontHeading,
        closeColor: Theme.textDim,
        pill: Theme.fontCaption,
        stackedHeader: false
    })

    // A nested card is a row inside an expanded source group: no fill, no
    // border, tighter padding, and a hairline separating it from the row
    // above. Its source is already named by the group header, so it drops
    // the app name and the icon with it.
    component CentreCard: NotifCard {
        id: centre

        property bool nested: false

        style: root.cardStyle
        nowMs: root.nowMs
        allowTextExpansion: true
        keyboardEnabled: true
        showIcon: centre.showApp
        padH: centre.nested ? 10 : 12
        padV: centre.nested ? 8 : 12
        radius: centre.nested ? Theme.rowRadius : 11
        color: centre.urgent ? Theme.redBgSoft
            : centre.hovered ? Theme.hoverFill
            : centre.nested ? "transparent" : Theme.cardFill
        border.width: centre.nested ? 0 : 1
        border.color: centre.urgent ? Theme.redBorder : Theme.hairlineSoft

        Component.onCompleted: {
            if (!centre.nested && root.initialCard === null) {
                root.initialCard = centre;
                root.focusInitial();
            }
        }
        Component.onDestruction: {
            if (root.initialCard === centre)
                root.initialCard = null;
        }

        Rectangle {
            visible: centre.nested
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.leftMargin: 10
            anchors.right: parent.right
            anchors.rightMargin: 10
            height: 1
            color: Theme.hairlineSoft
        }
    }

    component GroupBlock: Column {
        id: block
        required property var group
        property bool dim: false
        readonly property bool expanded: root.expandedApps[group.app] === true
        readonly property var newest: group.items[0]
        readonly property bool hasUrgent: group.items.some(item =>
            item.urgency === NotificationUrgency.Critical)

        width: parent.width
        opacity: dim ? 0.7 : 1

        CentreCard {
            visible: !block.expanded
            width: parent.width
            entry: block.newest
            groupCount: block.group.items.length
            groupUrgent: block.hasUrgent
            onActivated: {
                if (block.group.items.length > 1)
                    root.toggleApp(block.group.app);
                else
                    Notifs.invokeDefault(block.newest);
            }
            onCloseRequested: root.clearGroup(block.group)
        }

        Rectangle {
            visible: block.expanded
            width: parent.width
            height: expandedColumn.implicitHeight + 2
            radius: Theme.chipRadius
            color: Theme.chip
            border.width: block.hasUrgent ? 1 : 0
            border.color: Theme.redBorder
            clip: true

            Column {
                id: expandedColumn
                x: 1
                y: 1
                width: parent.width - 2

                Item {
                    id: groupHeader
                    width: parent.width
                    height: 44
                    activeFocusOnTab: true
                    Accessible.role: Accessible.Button
                    Accessible.name: "Collapse notifications from " + block.group.app
                    Accessible.description: block.group.items.length + " notifications"
                    Accessible.onPressAction: root.toggleApp(block.group.app)

                    Keys.onPressed: event => {
                        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                                || event.key === Qt.Key_Space) {
                            root.toggleApp(block.group.app);
                            event.accepted = true;
                        } else if (event.key === Qt.Key_Right || event.key === Qt.Key_Down) {
                            root.moveFocus(groupHeader, true);
                            event.accepted = true;
                        } else if (event.key === Qt.Key_Left || event.key === Qt.Key_Up) {
                            root.moveFocus(groupHeader, false);
                            event.accepted = true;
                        }
                    }

                    Rectangle {
                        anchors.fill: parent
                        radius: Theme.chipRadius
                        color: "transparent"
                        border.width: groupHeader.activeFocus ? 1 : 0
                        border.color: Theme.accent
                    }

                    HoverHandler {
                        id: groupHeaderHover
                    }

                    MouseArea {
                        anchors.fill: parent
                        anchors.rightMargin: 34
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            groupHeader.forceActiveFocus();
                            root.toggleApp(block.group.app);
                        }
                    }

                    NotifIcon {
                        anchors.left: parent.left
                        anchors.leftMargin: 10
                        anchors.verticalCenter: parent.verticalCenter
                        width: 24
                        height: 24
                        iconSize: 24
                        entry: block.newest
                        urgent: block.hasUrgent
                    }

                    Text {
                        anchors.left: parent.left
                        anchors.leftMargin: 44
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width - 110
                        text: block.group.app
                        font.family: Theme.fontMenu
                        font.pixelSize: Theme.typography.primary
                        font.weight: Theme.weightSemibold
                        color: Theme.textHi
                        elide: Text.ElideRight
                    }

                    Rectangle {
                        anchors.right: parent.right
                        anchors.rightMargin: 42
                        anchors.verticalCenter: parent.verticalCenter
                        width: expandedCount.implicitWidth + 12
                        height: Theme.chipInnerHeight
                        radius: Theme.chipRadius
                        color: "transparent"

                        Text {
                            id: expandedCount
                            anchors.centerIn: parent
                            text: block.group.items.length
                            font.family: Theme.fontMenu
                            font.pixelSize: Theme.typography.metadata
                            font.weight: Theme.weightMedium
                            font.features: Theme.tabularNumberFeatures
                            color: Theme.textMid
                        }
                    }

                    Sym {
                        id: groupCloseButton
                        anchors.right: parent.right
                        anchors.rightMargin: 13
                        anchors.verticalCenter: parent.verticalCenter
                        name: groupHeaderHover.hovered || activeFocus ? "close" : "expand_less"
                        size: groupHeaderHover.hovered || activeFocus
                            ? Theme.iconMedium : Theme.iconSmall
                        color: groupCloseMouse.containsMouse || activeFocus
                            ? Theme.textHi : Theme.textDim
                        activeFocusOnTab: true
                        Accessible.role: Accessible.Button
                        Accessible.name: "Dismiss all notifications from " + block.group.app
                        Accessible.onPressAction: root.clearGroup(block.group)

                        Keys.onPressed: event => {
                            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                                    || event.key === Qt.Key_Space
                                    || event.key === Qt.Key_Delete) {
                                root.clearGroup(block.group);
                                event.accepted = true;
                            } else if (event.key === Qt.Key_Right || event.key === Qt.Key_Down) {
                                root.moveFocus(groupCloseButton, true);
                                event.accepted = true;
                            } else if (event.key === Qt.Key_Left || event.key === Qt.Key_Up) {
                                root.moveFocus(groupCloseButton, false);
                                event.accepted = true;
                            }
                        }

                        MouseArea {
                            id: groupCloseMouse
                            anchors.fill: parent
                            anchors.margins: -6
                            enabled: groupHeaderHover.hovered || groupCloseButton.activeFocus
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                groupCloseButton.forceActiveFocus();
                                root.clearGroup(block.group);
                            }
                        }
                    }
                }

                Repeater {
                    model: block.group.items

                    delegate: CentreCard {
                        required property var modelData
                        width: expandedColumn.width
                        entry: modelData
                        nested: true
                        showApp: false
                        onActivated: Notifs.invokeDefault(entry)
                        onCloseRequested: Notifs.dismiss(entry)
                    }
                }
            }
        }
    }

    // ---- header ---------------------------------------------------------

    Item {
        width: parent.width
        height: Theme.sectionHeaderHeight + 8

        // The section mark every panel draws, with the count as its detail and
        // the clear action at the end of the rule.
        Row {
            id: headerRow
            x: 2
            anchors.verticalCenter: parent.verticalCenter
            spacing: 7

            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "NOTIFICATIONS"
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.metadata
                font.weight: Theme.weightSemibold
                font.letterSpacing: 1
                color: Theme.textFaint
            }

            Rectangle {
                visible: Notifs.count > 0
                anchors.verticalCenter: parent.verticalCenter
                width: countText.implicitWidth + 12
                height: Theme.chipInnerHeight
                radius: Theme.chipRadius
                color: "transparent"

                Text {
                    id: countText
                    anchors.centerIn: parent
                    text: Notifs.count
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.metadata
                    font.weight: Theme.weightMedium
                    font.features: Theme.tabularNumberFeatures
                    color: Theme.textMid
                }
            }
        }

        LinkText {
            id: clearAll
            anchors.right: parent.right
            anchors.rightMargin: 2
            anchors.verticalCenter: parent.verticalCenter
            text: "Clear all"
            enabled: Notifs.count > 0
            opacity: enabled ? 1 : 0.45
            onClicked: Notifs.clearAll()
        }

        Rectangle {
            anchors.left: headerRow.right
            anchors.leftMargin: 10
            anchors.right: clearAll.left
            anchors.rightMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            height: 1
            color: Theme.hairlineSoft
        }
    }

    StatusPlaceholder {
        shown: Notifs.count === 0
        width: parent.width
        glyph: "notifications"
        title: "No notifications"
    }

    // ---- grouped history ------------------------------------------------

    Column {
        width: parent.width
        spacing: 8

        Repeater {
            model: root.recentGroups

            delegate: GroupBlock {
                required property var modelData
                group: modelData
            }
        }

        Item {
            visible: root.earlierGroups.length > 0
            width: parent.width
            height: Theme.controlHeight

            Text {
                id: earlierLabel
                x: 10
                anchors.verticalCenter: parent.verticalCenter
                text: "EARLIER"
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.section
                font.weight: Theme.weightSemibold
                font.letterSpacing: 1.2
                color: Theme.textFaint
            }

            Rectangle {
                anchors.left: earlierLabel.right
                anchors.leftMargin: 8
                anchors.right: parent.right
                anchors.rightMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                height: 1
                color: Theme.hairlineSoft
            }
        }

        Repeater {
            model: root.earlierGroups

            delegate: GroupBlock {
                required property var modelData
                group: modelData
                dim: true
            }
        }
    }

    HDivider {}

    // ---- footer ---------------------------------------------------------

    Item {
        width: parent.width
        height: Theme.controlHeight

        Text {
            x: 10
            anchors.verticalCenter: parent.verticalCenter
            text: "Do Not Disturb"
            font.family: Theme.fontMenu
            font.pixelSize: Theme.typography.control
            color: Theme.textDim
        }

        Toggle {
            id: dndToggle
            anchors.right: parent.right
            anchors.rightMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            checked: Notifs.dnd
            accessibleName: "Do Not Disturb"
            onToggled: value => Notifs.setDnd(value)
        }
    }

    Item {
        width: 1
        height: 1
        opacity: 0
        Accessible.role: Accessible.AlertMessage
        Accessible.name: root.announcement
    }

    Component.onCompleted: {
        announcementReady = true;
        focusInitial();
    }
}
