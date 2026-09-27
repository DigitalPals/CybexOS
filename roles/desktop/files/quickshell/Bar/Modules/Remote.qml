import QtQuick
import ".."
import "../../Common"
import "../../Common/RemoteServerHelpers.js" as Helpers

// The chosen reading beside a server mark. The mark carries a badge only when
// something needs attention — amber while readings are old, red once the
// connection is lost — and the reading turns amber or red past its warning
// threshold, so a healthy server is just a number.
BarModule {
    id: root

    readonly property string connection: RemoteServer.connection
    readonly property bool troubled: connection === "stale" || connection === "offline"
    readonly property string level: Helpers.metricLevel(RemoteServer.sample, RemoteServer.options)

    moduleId: "remote"
    detailSaving: RemoteServer.options.showLabel ? serverName.width + chip.spacing : 0

    BarChip {
        id: chip
        host: root.host
        panelName: "remote"
        isle: root.isle
        anchorItem: root.groupAnchor ?? chip
        spacing: 6
        tooltip: [RemoteServer.label + " · " + RemoteServer.status,
            RemoteServer.sample ? "CPU " + Helpers.percent(RemoteServer.sample.cpu)
                + " · Memory " + Helpers.percent(Helpers.memoryPercent(RemoteServer.sample))
                + " · Up " + Helpers.uptime(RemoteServer.sample.uptime) : "",
            root.troubled && RemoteServer.sample ? "Last reading " + RemoteServer.age : "",
            RemoteServer.error].filter(line => line !== "").join("\n")

        Item {
            anchors.verticalCenter: parent.verticalCenter
            width: Theme.barIconSize
            height: Theme.barIconSize

            Sym {
                anchors.fill: parent
                name: "dns"
                size: Theme.barIconSize
                color: chip.fg
            }

            // Ringed in the bar surface so it reads as sitting on the mark,
            // as the notification bell's unread mark does.
            Rectangle {
                visible: root.troubled
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.rightMargin: -3
                anchors.topMargin: -3
                width: 8
                height: 8
                radius: 4
                color: Theme.barSurface

                Rectangle {
                    anchors.centerIn: parent
                    width: 5
                    height: 5
                    radius: 3
                    color: root.connection === "offline" ? Theme.barRedText : Theme.barAmber
                }
            }
        }
        Text {
            id: serverName
            anchors.verticalCenter: parent.verticalCenter
            visible: RemoteServer.options.showLabel && !root.compact
            text: RemoteServer.label
            width: Math.min(implicitWidth, 140)
            elide: Text.ElideRight
            textFormat: Text.PlainText
            font.family: Theme.fontMenu
            font.pixelSize: Theme.typography.bar
            font.weight: Theme.weightMedium
            color: Theme.barTextLow
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: RemoteServer.host ? RemoteServer.barValue : "Set up"
            font.family: Theme.fontNumeric
            font.pixelSize: Theme.typography.bar
            font.weight: Theme.weightSemibold
            font.features: Theme.tabularNumberFeatures
            color: !RemoteServer.host ? Theme.barTextLow
                : root.troubled || !RemoteServer.sample ? Theme.barTextFaint
                : root.level === "critical" ? Theme.barRedText
                : root.level === "warn" ? Theme.barAmber : Theme.barTextHi

            Behavior on color {
                ColorAnimation { duration: Theme.chipFadeDuration }
            }
        }
    }
}
