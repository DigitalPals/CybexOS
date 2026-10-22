pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Bluetooth

// Default adapter and the devices worth showing. Named BluetoothState
// rather than Bluetooth so it cannot shadow the Quickshell.Bluetooth
// import inside a consumer that needs both.
Singleton {
    id: root

    readonly property var adapter: Bluetooth.defaultAdapter
    readonly property bool enabled: adapter !== null && adapter.enabled

    // Paired or connected, connected first, then by name — the ordering the
    // popover list has always used.
    readonly property var devices: {
        if (!enabled)
            return [];
        return Bluetooth.devices.values
            .filter(d => d.paired || d.connected)
            .sort((a, b) => (b.connected - a.connected) || a.deviceName.localeCompare(b.deviceName));
    }

    // Drives the bar module's auto-rule, so it must not depend on `devices`
    // above: a device can be connected while the adapter list is still
    // settling, and the chip should appear as soon as that is true.
    readonly property bool connected: adapter !== null && adapter.devices.values.some(d => d.connected)

    function setEnabled(value) {
        if (adapter)
            adapter.enabled = value;
    }

    function toggle() {
        if (adapter)
            adapter.enabled = !adapter.enabled;
    }
}
