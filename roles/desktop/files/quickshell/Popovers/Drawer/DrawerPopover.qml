pragma ComponentBehavior: Bound
import QtQuick
import "../../Common"
import "../../Common/PanelRegistryData.js" as PanelRegistry
import ".."

// The edge drawer: the one surface every status glyph opens, per the 2026-09
// redesign (Claude Design project 8cf85161, direction 2). A tab strip —
// Overview · Sound · Network · Bluetooth · Power · Notifications — sits above the
// tab body; the popout host attaches the surface flush under the bar and pins
// it to the right screen edge (PanelRegistryData `attached` + `edge`).
//
// Each established popout name (control, audio, wifi, battery, notifications,
// usage, …) presents one tab of this same component, so IPC names, the bar's
// held states and hover-crossing all keep working unchanged. The host keys
// its slots by source, so every one of those names reuses this same instance
// and a tab switch swaps content in place instead of cross-fading a clone.
Surface {
    id: root

    property string tab: "overview"
    // Deep links: the updates chip opens Overview with its updates row lit.
    property string highlight: ""

    padding: Theme.panelPadding
    spacing: Theme.scaled(14)
    implicitWidth: Theme.drawerWidth

    readonly property real bodyHeightLimit: availableHeight > 0
        ? Math.max(1, availableHeight - padding * 2
            - drawerTabs.height - spacing)
        : Math.max(1, bodyLoader.implicitHeight)

    onTabChanged: {
        bodyFlick.cancelFlick();
        bodyFlick.contentY = 0;
    }

    function bodyContains(item) {
        let cursor = item;
        while (cursor) {
            if (cursor === bodyFlick.contentItem)
                return true;
            cursor = cursor.parent;
        }
        return false;
    }

    function revealFocus(item) {
        if (!item || !bodyFlick.interactive || !bodyContains(item))
            return;
        Qt.callLater(() => {
            if (!item || !item.visible || !root.bodyContains(item))
                return;
            const point = item.mapToItem(bodyFlick.contentItem, 0, 0);
            const margin = Theme.scaled(8);
            const itemHeight = Math.max(item.height, item.implicitHeight || 0);
            let next = bodyFlick.contentY;
            if (point.y < bodyFlick.contentY + margin)
                next = point.y - margin;
            else if (point.y + itemHeight
                    > bodyFlick.contentY + bodyFlick.height - margin)
                next = point.y + itemHeight - bodyFlick.height + margin;
            bodyFlick.contentY = Math.max(0, Math.min(next,
                bodyFlick.contentHeight - bodyFlick.height));
        });
    }

    Component.onCompleted: {
        const name = Popouts.currentName;
        tab = PanelRegistry.drawerTab(name) || "overview";
        if (name === "updates")
            highlight = "updates";
    }

    // Follow the presenting name while it is a drawer name. When another
    // surface takes over (drawerTab resolves to ""), this instance is the
    // outgoing half of a cross-fade and must keep showing what it showed.
    Connections {
        target: Popouts

        function onChanged() {
            if (!Popouts.open)
                return;
            const tab = PanelRegistry.drawerTab(Popouts.currentName);
            if (tab === "")
                return;
            root.tab = tab;
            root.highlight = Popouts.currentName === "updates" ? "updates" : "";
        }
    }

    DrawerTabs {
        id: drawerTabs
        width: parent.width
        current: root.tab
    }

    Item {
        id: bodyViewport

        width: parent.width
        height: implicitHeight
        implicitHeight: Math.min(bodyLoader.implicitHeight,
            root.bodyHeightLimit)
        clip: true

        Flickable {
            id: bodyFlick

            anchors.fill: parent
            contentWidth: width
            contentHeight: bodyLoader.implicitHeight
            interactive: contentHeight > height + 1
            boundsBehavior: Flickable.StopAtBounds
            flickableDirection: Flickable.VerticalFlick
            flickDeceleration: 3000
            clip: true

            Loader {
                id: bodyLoader

                width: bodyFlick.width
                sourceComponent: root.tab === "sound" ? soundTab
                    : root.tab === "network" ? networkTab
                    : root.tab === "bluetooth" ? bluetoothTab
                    : root.tab === "power" ? powerTab
                    : root.tab === "notifications" ? notificationsTab
                    : overviewTab
            }
        }

        ScrollChrome {
            anchors.fill: parent
            target: bodyFlick
        }
    }

    Connections {
        target: root.Window.window
        enabled: target !== null
        function onActiveFocusItemChanged() {
            const item = root.Window.window
                ? root.Window.window.activeFocusItem : null;
            if (item)
                root.revealFocus(item);
        }
    }

    Component {
        id: overviewTab
        DrawerOverview {
            highlightUpdates: root.highlight === "updates"
        }
    }

    Component {
        id: soundTab
        DrawerSound {}
    }

    Component {
        id: networkTab
        DrawerNetwork {}
    }

    Component {
        id: bluetoothTab
        DrawerBluetooth {}
    }

    Component {
        id: powerTab
        DrawerPower {}
    }

    Component {
        id: notificationsTab
        DrawerNotifications {}
    }
}
