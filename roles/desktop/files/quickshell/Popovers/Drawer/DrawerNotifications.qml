pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import "../../Common"

// The drawer's Notifications tab: the recent hour's cards, an EARLIER block
// for the rest, and the On / Focus switch. Cards reuse the shared NotifCard
// anatomy the toasts and the old centre drew.
Column {
    id: root

    property double nowMs: Date.now()
    readonly property var entries: Notifs.entries.slice(0, 12)
    // Entries are newest first, so the recent hour is a prefix. The clock
    // tick only moves this int; the lists below re-slice when it actually
    // changes, not every 30 s, and the ScriptModels keep each surviving
    // card (its expansion and focus) across a re-slice.
    readonly property int recentCount: {
        const index = entries.findIndex(entry =>
            root.nowMs - entry.arrived >= 3600 * 1000);
        return index === -1 ? entries.length : index;
    }
    readonly property var recent: entries.slice(0, recentCount)
    readonly property var earlier: entries.slice(recentCount)

    readonly property var cardStyle: ({
        face: Theme.fontMenu,
        header: Theme.typography.notification,
        body: Theme.typography.notification,
        bodyColor: Theme.textLow,
        bodyLines: 2,
        bodyLeading: 1.25,
        stampFace: Theme.fontNumeric,
        stampSize: Theme.fontCaption,
        stampCentred: false,
        trailingHeight: 20,
        close: Theme.fontHeading,
        closeColor: Theme.textDim,
        pill: Theme.fontCaption,
        stackedHeader: false
    })

    width: parent ? parent.width : 0
    spacing: Theme.scaled(14)

    Timer {
        interval: 30000
        running: root.visible
        repeat: true
        triggeredOnStart: true
        onTriggered: root.nowMs = Date.now()
    }

    // ---- header ----------------------------------------------------------
    Item {
        width: parent.width
        height: 28

        Row {
            anchors.left: parent.left
            anchors.leftMargin: 4
            anchors.verticalCenter: parent.verticalCenter
            spacing: 8

            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: root.recent.length > 0
                    ? root.recent.length + " new"
                    : Notifs.count === 0 ? "All clear" : "Quiet hour"
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.title
                font.weight: Theme.weightSemibold
                color: Theme.textHi
            }

            Text {
                anchors.verticalCenter: parent.verticalCenter
                visible: root.earlier.length > 0
                text: root.earlier.length + " earlier"
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.secondary
                color: Theme.textFaint
            }
        }

        Rectangle {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: modeRow.implicitWidth + 4
            height: 26
            radius: 7
            color: Theme.chip

            Row {
                id: modeRow
                anchors.centerIn: parent
                spacing: 2

                Repeater {
                    model: [
                        { label: "On", glyph: "", dnd: false },
                        { label: "Focus", glyph: "do_not_disturb_on", dnd: true }
                    ]

                    delegate: Rectangle {
                        id: modeChoice

                        required property var modelData
                        readonly property bool on: Notifs.dnd === modelData.dnd

                        width: modeContent.implicitWidth + 18
                        height: 22
                        radius: 5
                        color: on ? Theme.chipHover : "transparent"

                        Row {
                            id: modeContent
                            anchors.centerIn: parent
                            spacing: 4

                            Sym {
                                visible: modeChoice.modelData.glyph !== ""
                                anchors.verticalCenter: parent.verticalCenter
                                name: modeChoice.modelData.glyph !== ""
                                    ? modeChoice.modelData.glyph : "circle"
                                size: 12
                                color: modeChoice.on ? Theme.textHi : Theme.textFaint
                            }

                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: modeChoice.modelData.label
                                font.family: Theme.fontMenu
                                font.pixelSize: Theme.typography.control
                                font.weight: Theme.weightSemibold
                                color: modeChoice.on ? Theme.textHi : Theme.textFaint
                            }
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: Notifs.setDnd(modeChoice.modelData.dnd)
                        }

                        Accessible.role: Accessible.RadioButton
                        Accessible.checked: modeChoice.on
                        Accessible.name: modeChoice.modelData.label
                    }
                }
            }
        }
    }

    // ---- cards -----------------------------------------------------------
    Column {
        width: parent.width
        spacing: 4

        Repeater {
            model: ScriptModel {
                values: root.recent
            }

            delegate: NotifCard {
                id: recentCard

                required property var modelData

                entry: modelData
                style: root.cardStyle
                nowMs: root.nowMs
                allowTextExpansion: true
                keyboardEnabled: true
                width: parent.width
                radius: 10
                color: recentCard.urgent ? Theme.redBgSoft
                    : recentCard.hovered ? Theme.chipHover : Theme.chip
                onActivated: Notifs.invokeDefault(recentCard.entry)
                onCloseRequested: Notifs.dismiss(recentCard.entry)
            }
        }

        Item {
            visible: root.recent.length === 0
            width: parent.width
            height: 64

            Column {
                anchors.centerIn: parent
                spacing: 6

                Sym {
                    anchors.horizontalCenter: parent.horizontalCenter
                    name: "notifications_off"
                    size: 20
                    color: Theme.textFaint
                }

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "Nothing new"
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.primary
                    color: Theme.textFaint
                }
            }
        }

        Item {
            visible: root.earlier.length > 0
            width: parent.width
            height: 26

            Text {
                anchors.left: parent.left
                anchors.leftMargin: 4
                anchors.bottom: parent.bottom
                anchors.bottomMargin: 4
                text: "EARLIER"
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.section
                font.weight: Theme.weightSemibold
                font.letterSpacing: 0.6
                color: Theme.textFaint
            }
        }

        Repeater {
            model: ScriptModel {
                values: root.earlier
            }

            delegate: NotifCard {
                id: earlierCard

                required property var modelData

                entry: modelData
                style: root.cardStyle
                nowMs: root.nowMs
                allowTextExpansion: true
                keyboardEnabled: true
                width: parent.width
                radius: 10
                opacity: 0.75
                padV: 8
                color: earlierCard.hovered ? Theme.chipHover : "transparent"
                onActivated: Notifs.invokeDefault(earlierCard.entry)
                onCloseRequested: Notifs.dismiss(earlierCard.entry)
            }
        }
    }

    DrawerFooter {
        info: Notifs.count === 0 ? ""
            : Notifs.count === 1 ? "1 notification kept"
            : Notifs.count + " notifications kept"
        actionText: Notifs.count > 0 ? "Clear all" : ""
        onActionClicked: Notifs.clearAll()
    }
}
