import QtQuick
import ".."
import "../../Common"
import "../../Common/RemoteServerHelpers.js" as Helpers

BarModule {
    id: root
    moduleId: "remote"
    detailSaving: RemoteServer.options.showLabel ? serverName.width + chip.spacing : 0

    BarChip {
        id: chip
        host: root.host
        panelName: "remote"
        isle: root.isle
        anchorItem: root.groupAnchor ?? chip
        spacing: 6
        tooltip: RemoteServer.label + " · " + RemoteServer.status
            + "\n" + (Helpers.METRICS.find(m => m.value === RemoteServer.options.metric)?.label || "CPU")
            + ": " + RemoteServer.barValue
            + (RemoteServer.sample ? "\nCPU " + Helpers.percent(RemoteServer.sample.cpu)
                + " · RAM " + Helpers.percent(Helpers.memoryPercent(RemoteServer.sample))
                + " · Updated " + RemoteServer.age : "")
            + (RemoteServer.error ? "\n" + RemoteServer.error : "")

        Sym {
            anchors.verticalCenter: parent.verticalCenter
            name: "dns"
            size: Theme.barIconSize
            color: RemoteServer.error ? Theme.barAmber : chip.fg
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
            color: RemoteServer.stale ? Theme.barTextFaint : Theme.barTextHi
        }
        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: 4; height: 4; radius: 2
            color: RemoteServer.error || RemoteServer.stale ? Theme.barAmber
                : RemoteServer.sample ? Theme.barAccent : Theme.barTextFaint
        }
    }
}
