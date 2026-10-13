pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Services.UPower
import "StatusHelpers.js" as StatusHelpers

// The one reading of the battery. UPower's display device is the aggregate
// the desktop is meant to show; the charge semantics come from
// StatusHelpers so bar and popover cannot drift apart again (WP1.3 fixed
// that drift in the pure logic — this is where the reactive half lands).
Singleton {
    id: root

    readonly property var device: UPower.displayDevice

    // A desktop with no battery still has a display device, so presence is
    // not enough to decide whether to draw the module.
    readonly property bool isLaptop: device !== null && device.isLaptopBattery

    readonly property real percent: StatusHelpers.batteryPercent(device)

    // Power source and charge state are independent at a firmware charge limit.
    readonly property string state: StatusHelpers.chargeState(device)
    readonly property bool pluggedIn: StatusHelpers.isPluggedIn(device, UPower.onBattery)
    readonly property bool charging: state === "charging"
    readonly property bool full: state === "full"
    readonly property string statusText: StatusHelpers.batteryStatus(
        state, pluggedIn, BatteryHealth.known && BatteryHealth.enabled)
}
