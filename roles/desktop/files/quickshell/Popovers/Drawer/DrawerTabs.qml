pragma ComponentBehavior: Bound
import QtQuick
import "../../Common"
import "../../Common/PanelRegistryData.js" as PanelRegistry

// The drawer's tab strip. The current tab carries its icon and label on a
// lit segment with the design's 12px side padding; the others compress to
// icons sharing the remaining width, so the strip holds one row at every
// drawer width. Selecting a tab reopens the popout under that tab's
// canonical panel name — same name space as the bar glyphs and IPC — which
// keeps the surface exactly where it is.
Rectangle {
    id: root

    property string current: "overview"

    readonly property var tabMeta: ({
        overview: { glyph: "dashboard", label: "Overview" },
        sound: { glyph: "volume_down", label: "Sound" },
        network: { glyph: "wifi", label: "Network" },
        power: { glyph: "battery_5_bar", label: "Power", rotate: true },
        notifications: { glyph: "notifications", label: "Notifications" },
        usage: { glyph: "insights", label: "Usage" }
    })

    // Order and visibility come from the Drawer settings page. A tab the user
    // switched off stays reachable through its bar glyph and IPC name; while
    // it is presented it joins the strip so the current tab is never unnamed.
    readonly property var tabs: Settings.drawerTabs
        .filter(entry => (entry.on || entry.id === current)
            && tabMeta[entry.id] !== undefined)
        .map(entry => ({
            tab: entry.id,
            glyph: tabMeta[entry.id].glyph,
            label: tabMeta[entry.id].label,
            rotate: tabMeta[entry.id].rotate === true
        }))

    height: 42
    radius: 10
    color: Theme.chip

    Row {
        anchors.fill: parent
        anchors.margins: 3
        spacing: 2

        Repeater {
            model: root.tabs

            delegate: Rectangle {
                id: segment

                required property var modelData
                readonly property bool on: modelData.tab === root.current
                // Icon lane, its gap to the label, and the design's 12px of
                // air either side of the pair.
                readonly property real litWidth: 12 + 17 + 7
                    + labelMetrics.width + 12
                // The lit segment takes its natural width; the rest split
                // what is left evenly.
                readonly property real restWidth: {
                    let lit = 0;
                    for (const t of root.tabs) {
                        if (t.tab === root.current)
                            lit = 12 + 17 + 7 + litMetrics.width + 12;
                    }
                    return (parent.width - lit - 2 * (root.tabs.length - 1))
                        / (root.tabs.length - 1);
                }

                TextMetrics {
                    id: labelMetrics
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.navigation
                    font.weight: Theme.weightSemibold
                    text: segment.modelData.label
                }

                TextMetrics {
                    id: litMetrics
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.navigation
                    font.weight: Theme.weightSemibold
                    text: {
                        for (const t of root.tabs) {
                            if (t.tab === root.current)
                                return t.label;
                        }
                        return "";
                    }
                }

                width: on ? litWidth : Math.max(28, restWidth)
                height: parent.height
                radius: 8
                color: on ? Theme.chipHover : "transparent"

                Behavior on width {
                    NumberAnimation {
                        duration: Theme.expandDuration
                        easing.type: Easing.BezierSpline
                        easing.bezierCurve: Theme.springCurve
                    }
                }

                Behavior on color {
                    ColorAnimation { duration: Theme.chipFadeDuration }
                }

                Row {
                    anchors.centerIn: parent
                    spacing: 7

                    Item {
                        anchors.verticalCenter: parent.verticalCenter
                        width: 17
                        height: 17

                        Sym {
                            anchors.centerIn: parent
                            name: segment.modelData.glyph
                            size: 17
                            fill: segment.on ? 1 : 0
                            rotation: segment.modelData.rotate === true ? 90 : 0
                            color: segment.on ? Theme.textHi : Theme.textFaint
                        }
                    }

                    Text {
                        visible: segment.on
                        anchors.verticalCenter: parent.verticalCenter
                        text: segment.modelData.label
                        font.family: Theme.fontMenu
                        font.pixelSize: Theme.typography.navigation
                        font.weight: Theme.weightSemibold
                        color: Theme.textHi
                    }
                }

                // Unread mark on the resting Notifications tab, in the same
                // place the bar's bell wears its dot.
                Rectangle {
                    visible: segment.modelData.tab === "notifications"
                        && !segment.on && Notifs.count > 0
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.rightMargin: 8
                    anchors.topMargin: 7
                    width: 6
                    height: 6
                    radius: 3
                    color: Theme.accent
                }

                StateLayer {
                    anchors.fill: parent
                    radius: parent.radius
                    hovered: segmentMouse.containsMouse && !segment.on
                    pressed: segmentMouse.pressed
                    tint: Theme.textHi
                    pressPoint: Qt.point(segmentMouse.mouseX, segmentMouse.mouseY)
                }

                MouseArea {
                    id: segmentMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        if (segment.on)
                            return;
                        const name = PanelRegistry.nameForTab(segment.modelData.tab);
                        if (name !== "")
                            Popouts.openPanel(name, "right");
                    }
                }

                Accessible.role: Accessible.PageTab
                Accessible.name: segment.modelData.label
            }
        }
    }
}
