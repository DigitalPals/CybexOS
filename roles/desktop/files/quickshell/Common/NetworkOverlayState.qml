pragma Singleton
import QtQuick
import Quickshell
import "NetworkHelpers.js" as NetworkHelpers

// Shell-wide modal route shared by the Network popover and its one overlay
// window. QR, speed-test and Tailscale pages are mutually exclusive.
Singleton {
    id: root

    property bool open: false
    property string page: ""
    property var screen: null
    property string interfaceName: ""
    property var qrInfo: ({})
    property var speedDevices: []

    function openTailscale() {
        close();
        Popouts.close();
        Launcher.close();
        root.screen = Screens.focused;
        root.page = "tailscale";
        root.open = true;
    }

    function openQr(screen, interfaceName) {
        Popouts.close();
        Launcher.close();
        root.screen = screen ?? Screens.focused;
        root.interfaceName = interfaceName || "";
        root.speedDevices = [];
        const wifi = NetworkDetails.activeWifi;
        const profile = NetworkDetails.activeWifiProfile;
        const profileSecurity = profile && profile.security
            ? profile.security + (profile.certificateEnterprise ? " TLS" : "") : "";
        const profileInfo = NetworkHelpers.classifySecurity(profileSecurity);
        root.qrInfo = wifi ? {
            ssid: wifi.ssid || wifi.connection || "",
            uuid: wifi.uuid || "",
            security: profileInfo.kind === "enterprise-certificate"
                ? profileSecurity : (wifi.security || profileSecurity),
            hidden: profile ? Boolean(profile.hidden) : false
        } : {};
        root.page = "qr";
        root.open = true;
    }

    function openSpeedTest(screen, interfaceName) {
        Popouts.close();
        Launcher.close();
        root.screen = screen ?? Screens.focused;
        const connected = NetworkDetails.physicalDevices.filter(device =>
            device && device.connected && NetworkHelpers.interfaceName(device) !== "")
            .sort((left, right) => {
                const leftType = NetworkHelpers.physicalType(left);
                const rightType = NetworkHelpers.physicalType(right);
                if (leftType !== rightType)
                    return leftType === "ethernet" ? -1 : 1;
                return NetworkHelpers.interfaceName(left)
                    .localeCompare(NetworkHelpers.interfaceName(right));
            });
        const typeCounts = connected.reduce((counts, device) => {
            const type = NetworkHelpers.physicalType(device);
            counts[type] = (counts[type] || 0) + 1;
            return counts;
        }, {});
        root.speedDevices = connected.map(device => {
            const type = NetworkHelpers.physicalType(device);
            const name = NetworkHelpers.interfaceName(device);
            const baseLabel = type === "ethernet" ? "Ethernet" : "Wi-Fi";
            const details = [name];
            if (type === "wifi") {
                if (device.ssid)
                    details.push(device.ssid);
                if (Number(device.signal) >= 0)
                    details.push(Math.round(Number(device.signal)) + "% signal");
            } else {
                if (device.connection)
                    details.push(device.connection);
                if (device.speed)
                    details.push(device.speed);
            }
            return {
                interfaceName: name,
                type: type,
                label: typeCounts[type] > 1 ? baseLabel + " · " + name : baseLabel,
                detail: details.join(" · ")
            };
        });
        const requested = interfaceName || "";
        if (root.speedDevices.length === 0 && requested !== "")
            root.speedDevices = [{ interfaceName: requested, type: "",
                label: requested, detail: requested }];
        const preferred = root.speedDevices.find(device =>
            device.interfaceName === requested);
        root.interfaceName = preferred ? preferred.interfaceName
            : root.speedDevices.length > 0 ? root.speedDevices[0].interfaceName : "";
        root.page = "speed";
        root.qrInfo = {};
        root.open = true;
    }

    function selectSpeedInterface(interfaceName) {
        if (root.speedDevices.some(device => device.interfaceName === interfaceName))
            root.interfaceName = interfaceName;
    }

    function close() {
        root.open = false;
        root.page = "";
        root.interfaceName = "";
        root.qrInfo = {};
        root.speedDevices = [];
        root.screen = null;
    }
}
