import QtQuick
import ".."
import "../../Common"

// Combined Network status, kept under the persisted `wifi` module id. Wired
// wins the glyph while active; without it, the familiar Wi-Fi states remain.
BarModule {
    id: root

    moduleId: "wifi"

    // ModuleSlot only constructs this object for the enabled module on the
    // live bar. Its object lifetime is therefore the exact polling claim.
    Component.onCompleted: {
        EthernetState.acquire();
        Tailscale.acquire();
    }
    Component.onDestruction: {
        EthernetState.release();
        Tailscale.release();
    }

    readonly property string statusText: {
        const parts = [];
        for (const device of EthernetState.connectedDevices)
            parts.push("Ethernet " + (device.connection || device.device));
        if (WifiState.enabled && WifiState.connected)
            parts.push("Wi-Fi " + WifiState.name);
        else if (WifiState.enabled)
            parts.push("Wi-Fi off-network");
        else
            parts.push("Wi-Fi off");
        if (Tailscale.connected) {
            const identity = Tailscale.net || Tailscale.host;
            let detail = "Tailscale" + (identity !== "" ? " " + identity : "");
            if (Tailscale.ip !== "")
                detail += " (" + Tailscale.ip + ")";
            if (Tailscale.exitNode)
                detail += " · exit node";
            parts.push(detail);
        }
        return parts.join(" · ");
    }

    BarChip {
        id: chip

        host: root.host
        panelName: "wifi"
        isle: root.isle
        anchorItem: root.groupAnchor ?? chip
        tooltip: root.statusText
        tooltipAlign: 1

        Sym {
            anchors.verticalCenter: parent.verticalCenter
            name: EthernetState.connected ? "lan"
                : !WifiState.enabled ? "wifi_off"
                : !WifiState.connected ? "wifi_find"
                : WifiState.signal >= 66 ? "wifi"
                : WifiState.signal >= 33 ? "network_wifi_2_bar"
                : "network_wifi_1_bar"
            size: Theme.barIconSize
            color: chip.fg
            opacity: EthernetState.connected || WifiState.connected ? 1 : 0.35

            Behavior on opacity {
                NumberAnimation { duration: Theme.chipFadeDuration }
            }
        }
    }
}
