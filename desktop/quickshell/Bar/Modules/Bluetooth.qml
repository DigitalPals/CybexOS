import QtQuick
import ".."
import "../../Common"

// Bluetooth gets its own detail target. The bar's auto-rule keeps it off
// screen unless something is actually connected.
BarModule {
    id: root

    moduleId: "bt"

    BarChip {
        id: chip

        host: root.host
        panelName: "bluetooth"
        isle: root.isle
        anchorItem: root.groupAnchor ?? chip
        tooltip: I18n.tr("Bluetooth connected")
        tooltipAlign: 1

        Sym {
            anchors.verticalCenter: parent.verticalCenter
            name: BluetoothState.enabled ? "bluetooth" : "bluetooth_disabled"
            size: Theme.barIconSize
            color: chip.fg
            opacity: BluetoothState.connected ? 1 : 0.35

            Behavior on opacity {
                NumberAnimation { duration: Theme.chipFadeDuration }
            }
        }
    }
}
