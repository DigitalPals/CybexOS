pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Networking
import "StatusHelpers.js" as StatusHelpers

// The Wi-Fi device and its active network. `Networking.devices` lists wired
// and wireless alike and only the wireless ones carry a `networks` list, so
// that is what identifies the radio — the same find() the bar, the control
// centre and the Wi-Fi popover each wrote separately.
//
// Named WifiState, not Network: Quickshell.Networking already exports a
// `Network` type, and a consumer importing both would resolve the name by
// import order. Same reason as BluetoothState.
Singleton {
    id: root

    readonly property var device: Networking.devices.values.find(d => d.networks !== undefined) ?? null
    readonly property var active: device ? (device.networks.values.find(n => n.connected) ?? null) : null
    readonly property bool connected: active !== null
    readonly property string name: active ? active.name : ""

    // Whole percent, -1 when there is no reading — an unknown strength is
    // not the same as a genuine 0%.
    readonly property int signal: StatusHelpers.signalPercent(active ? active.signalStrength : null)

    // Whether the radio itself is on, which is independent of whether it
    // has associated with anything.
    readonly property bool enabled: Networking.wifiEnabled

    // The other networks in range, strongest first and deduplicated by name:
    // one SSID on several APs is one row to the user. There is deliberately no
    // old seven-row cap; the Network view scrolls and groups the full scan.
    // Empty while the radio is off so a stale scan cannot outlive it, and
    // while no view has the scanner on: every access point's signal change
    // would otherwise re-sort this list with nothing on screen to read it.
    readonly property var others: {
        if (!scanning || !enabled)
            return [];
        const seen = new Set();
        return device.networks.values
            .filter(n => !n.connected && n.name && n.name !== "")
            .sort((a, b) => b.signalStrength - a.signalStrength)
            .filter(n => {
                if (seen.has(n.name))
                    return false;
                seen.add(n.name);
                return true;
            });
    }

    readonly property bool scanning: device !== null && device.scannerEnabled

    function setEnabled(value) {
        Networking.wifiEnabled = value;
    }

    // The scanner is a live radio cost, so it stays opt-in: only the Wi-Fi
    // popover turns it on, and only while it is open.
    function setScanning(value) {
        if (device)
            device.scannerEnabled = value;
    }
}
