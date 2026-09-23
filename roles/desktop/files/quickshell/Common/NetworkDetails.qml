pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "NetworkHelpers.js" as NetworkHelpers
import "ProcHelpers.js" as ProcHelpers

// Ref-counted, view-lifetime network diagnostics and mutations.  The bar's
// lightweight EthernetState remains independent; this richer 1.5 second poll
// exists only while the Network panel is actually acquired.
Singleton {
    id: root

    readonly property string helper: Quickshell.shellDir + "/scripts/network-tool.py"
    readonly property int pingHistoryWindow: 24
    readonly property int pingAverageWindow: 5
    readonly property int pollIntervalMs: 1500
    readonly property string pollCadenceText:
        "Updated live every " + (pollIntervalMs / 1000).toFixed(1) + " seconds"

    property int watchers: 0
    readonly property bool acquired: watchers > 0
    property bool known: false
    property string error: ""
    property var snapshot: ({ devices: [], routes: [], profiles: [], wifi: { networks: [] } })
    property var savedProfiles: []

    readonly property var devices: Array.isArray(snapshot.devices) ? snapshot.devices : []
    readonly property var routes: Array.isArray(snapshot.routes) ? snapshot.routes : []
    readonly property var physicalDevices: devices.filter(device =>
        NetworkHelpers.physicalType(device) !== "")
    readonly property var ethernetDevices: physicalDevices.filter(device =>
        NetworkHelpers.physicalType(device) === "ethernet")
    readonly property var primary: NetworkHelpers.selectPrimaryInterface(devices, routes)
    readonly property string primaryInterface: primary
        ? NetworkHelpers.interfaceName(primary) : ""
    readonly property string primaryType: primary
        ? NetworkHelpers.physicalType(primary) : ""
    readonly property var activeWifi: physicalDevices.find(device =>
        NetworkHelpers.physicalType(device) === "wifi" && device.connected) ?? null
    readonly property string activeWifiInterface: activeWifi
        ? NetworkHelpers.interfaceName(activeWifi) : ""
    readonly property var activeWifiProfile: {
        if (!activeWifi)
            return null;
        return savedProfiles.find(profile => profile.uuid === activeWifi.uuid) ?? null;
    }

    readonly property var helperNetworks: snapshot.wifi
        && Array.isArray(snapshot.wifi.networks) ? snapshot.wifi.networks : []
    // `acquired` is checked first so a released controller holds no binding
    // on the radio's network list: each access point's signal change would
    // otherwise rebuild and regroup the scan with no Network view open.
    readonly property var fallbackNetworks: {
        if (!root.acquired || !WifiState.device || !WifiState.enabled)
            return [];
        return WifiState.device.networks.values.map(network => ({
            ssid: network.name,
            signal: Math.round(network.signalStrength),
            security: network.security,
            connected: network.connected,
            known: network.known,
            profileUuid: "",
            frequency: null
        }));
    }
    readonly property var scanNetworks: helperNetworks.length > 0
        ? helperNetworks : fallbackNetworks
    readonly property var groupedNetworks: NetworkHelpers.groupWifiNetworks(
        scanNetworks, savedProfiles.length > 0 ? savedProfiles : snapshot.profiles)
    readonly property var knownNetworks: groupedNetworks.known
    readonly property var otherNetworks: groupedNetworks.other
    readonly property var activeWifiNetwork: groupedNetworks.all.find(network =>
        network.connected) ?? null

    property var previousCounters: null
    property real downloadRate: 0
    property real uploadRate: 0
    property var routerPingHistory: []
    property var internetPingHistory: []
    readonly property var routerPing: NetworkHelpers.pingStats(
        routerPingHistory, pingAverageWindow)
    readonly property var internetPing: NetworkHelpers.pingStats(
        internetPingHistory, pingAverageWindow)

    property string dnsProvider: "Automatic"
    property var dnsServers: []
    property bool dnsMixed: false
    property bool dnsBusy: false
    property string dnsError: ""
    property string dnsNotice: ""
    property bool dnsRefreshAgain: false
    property var pendingDnsRequest: ({ provider: "status" })

    property string bandUuid: ""
    property string bandSelected: "auto"
    property bool bandBusy: false
    property string bandError: ""
    property bool bandRefreshAgain: false
    property var pendingBandRequest: ({ band: "status" })
    readonly property var activeBandState: NetworkHelpers.bandState(
        { selectedBand: bandSelected }, scanNetworks,
        activeWifi ? activeWifi.ssid : "",
        activeWifi ? activeWifi.frequency : null)
    readonly property var bandAvailable: activeBandState.available
    readonly property string bandCurrent: activeBandState.current

    property string actionKind: ""
    property string actionKey: ""
    property var wifiErrors: ({})
    property var pendingWifiRequest: ({})
    readonly property bool wifiBusy: actionKind !== ""

    signal wifiActionFinished(string key, bool success, string reason)
    signal dnsActionFinished(bool success, string reason)
    signal bandActionFinished(bool success, string reason)

    property var scannerDevice: null

    function acquire() {
        watchers++;
        if (watchers !== 1)
            return;
        syncScanner();
        resetSamples();
        refresh();
        refreshDns();
    }

    function release() {
        watchers = Math.max(0, watchers - 1);
        if (watchers !== 0)
            return;
        detailsPoll.stop();
        snapshotAgain = false;
        syncScanner();
        resetSamples();
    }

    function syncScanner() {
        const next = acquired ? WifiState.device : null;
        if (scannerDevice && scannerDevice !== next)
            scannerDevice.scannerEnabled = false;
        scannerDevice = next;
        if (scannerDevice)
            scannerDevice.scannerEnabled = acquired;
    }

    function resetSamples() {
        previousCounters = null;
        downloadRate = 0;
        uploadRate = 0;
        routerPingHistory = [];
        internetPingHistory = [];
    }

    property bool snapshotAgain: false

    function refresh() {
        if (!acquired)
            return;
        if (snapshotProc.running) {
            snapshotAgain = true;
            return;
        }
        snapshotProc.running = true;
    }

    function parseResult(body, fallback) {
        try {
            const value = JSON.parse(body);
            if (value && typeof value === "object")
                return value;
        } catch (exception) {
            console.warn(fallback + " returned invalid JSON:", exception);
        }
        return { success: false, error: fallback + " returned output this shell could not read" };
    }

    function applySnapshot(exitCode, body) {
        const result = parseResult(body, "network-tool snapshot");
        if (exitCode !== 0 || !result.success) {
            known = true;
            error = result.error || "Network details are unavailable";
            return;
        }
        const oldInterface = primaryInterface;
        snapshot = result;
        known = true;
        error = "";

        const nextPrimary = NetworkHelpers.selectPrimaryInterface(result.devices, result.routes);
        const nextInterface = nextPrimary ? NetworkHelpers.interfaceName(nextPrimary) : "";
        if (oldInterface !== nextInterface) {
            resetSamples();
        }
        if (nextPrimary) {
            const rate = NetworkHelpers.calculateRates(previousCounters,
                nextPrimary, result.timestamp);
            previousCounters = rate.next;
            downloadRate = rate.download;
            uploadRate = rate.upload;
            routerPingHistory = NetworkHelpers.updatePingHistory(routerPingHistory,
                result.diagnostics ? result.diagnostics.routerPingMs : null,
                pingHistoryWindow);
            internetPingHistory = NetworkHelpers.updatePingHistory(internetPingHistory,
                result.diagnostics ? result.diagnostics.internetPingMs : null,
                pingHistoryWindow);
        }

        const wifi = result.devices.find(device =>
            NetworkHelpers.physicalType(device) === "wifi" && device.connected) ?? null;
        const nextUuid = wifi ? wifi.uuid : "";
        if (nextUuid !== bandUuid) {
            bandUuid = nextUuid;
            bandSelected = "auto";
            if (nextUuid !== "")
                refreshBand();
        }
    }

    function setWifiError(key, message) {
        const next = Object.assign({}, wifiErrors);
        if (message)
            next[key] = message;
        else
            delete next[key];
        wifiErrors = next;
    }

    function wifiError(key) {
        return wifiErrors[key] || "";
    }

    function runWifiAction(request) {
        if (wifiProc.running)
            return false;
        const key = request.ssid || request.uuid || request.interface || "wifi";
        setWifiError(key, "");
        actionKey = key;
        actionKind = request.action || "connect";
        pendingWifiRequest = request;
        wifiProc.running = true;
        return true;
    }

    function refreshDns() {
        if (!acquired)
            return;
        if (dnsProc.running) {
            dnsRefreshAgain = true;
            return;
        }
        dnsBusy = true;
        dnsError = "";
        pendingDnsRequest = { provider: "status" };
        dnsProc.running = true;
    }

    function setDns(provider, servers) {
        if (dnsProc.running)
            return false;
        dnsBusy = true;
        dnsError = "";
        dnsNotice = "";
        pendingDnsRequest = { provider: provider, servers: servers || [] };
        dnsProc.running = true;
        return true;
    }

    function frequencyForBand(band) {
        if (!activeWifi)
            return null;
        const candidates = scanNetworks.filter(network => network.ssid === activeWifi.ssid
            && NetworkHelpers.bandForFrequency(network.frequency) === band);
        candidates.sort((a, b) => Number(b.signal) - Number(a.signal));
        return candidates.length > 0 ? candidates[0].frequency : null;
    }

    function refreshBand() {
        if (!acquired || bandUuid === "")
            return;
        if (bandProc.running) {
            bandRefreshAgain = true;
            return;
        }
        bandBusy = true;
        pendingBandRequest = { uuid: bandUuid, band: "status" };
        bandProc.running = true;
    }

    function setBand(band) {
        if (bandProc.running || !activeWifi || activeWifi.uuid === "")
            return false;
        bandBusy = true;
        bandError = "";
        pendingBandRequest = {
            uuid: activeWifi.uuid,
            interface: activeWifiInterface,
            band: band,
            frequency: band === "6" ? frequencyForBand("6") : null
        };
        bandProc.running = true;
        return true;
    }

    Timer {
        id: detailsPoll
        interval: root.pollIntervalMs
        repeat: true
        running: root.acquired
        onTriggered: root.refresh()
    }

    Connections {
        target: WifiState

        function onDeviceChanged() {
            root.syncScanner();
        }
    }

    Process {
        id: snapshotProc
        property string body: ""
        property bool exitSeen: false
        property int lastExit: 0

        command: ["python3", root.helper, "snapshot"]
        stdout: StdioCollector { onStreamFinished: snapshotProc.body = text }
        stderr: StdioCollector {}
        onExited: (exitCode, exitStatus) => {
            snapshotProc.exitSeen = true;
            snapshotProc.lastExit = exitCode;
        }
        onRunningChanged: {
            if (running) {
                body = "";
                exitSeen = false;
                lastExit = 0;
                return;
            }
            root.applySnapshot(exitSeen ? lastExit : ProcHelpers.NOT_STARTED, body);
            if (root.snapshotAgain && root.acquired) {
                root.snapshotAgain = false;
                Qt.callLater(root.refresh);
            }
        }
    }

    Process {
        id: wifiProc
        property string body: ""
        property bool exitSeen: false
        property int lastExit: 0

        command: ["python3", root.helper, "wifi"]
        stdinEnabled: true
        stdout: StdioCollector { onStreamFinished: wifiProc.body = text }
        stderr: StdioCollector {}
        onStarted: write(JSON.stringify(root.pendingWifiRequest) + "\n")
        onExited: (exitCode, exitStatus) => {
            wifiProc.exitSeen = true;
            wifiProc.lastExit = exitCode;
        }
        onRunningChanged: {
            if (running) {
                body = "";
                exitSeen = false;
                lastExit = 0;
                return;
            }
            const key = root.actionKey;
            const result = root.parseResult(body, "network-tool wifi");
            const success = exitSeen && lastExit === 0 && result.success;
            const reason = success ? "" : (result.error || "The Wi-Fi action failed");
            root.setWifiError(key, reason);
            root.actionKind = "";
            root.actionKey = "";
            root.pendingWifiRequest = {};
            root.wifiActionFinished(key, success, reason);
            if (root.acquired) {
                root.refresh();
                root.refreshDns();
            }
        }
    }

    Process {
        id: dnsProc
        property string body: ""
        property bool exitSeen: false
        property int lastExit: 0

        command: ["python3", root.helper, "dns"]
        stdinEnabled: true
        stdout: StdioCollector { onStreamFinished: dnsProc.body = text }
        stderr: StdioCollector {}
        onStarted: write(JSON.stringify(root.pendingDnsRequest) + "\n")
        onExited: (exitCode, exitStatus) => {
            dnsProc.exitSeen = true;
            dnsProc.lastExit = exitCode;
        }
        onRunningChanged: {
            if (running) {
                body = "";
                exitSeen = false;
                lastExit = 0;
                return;
            }
            const requestWasStatus = root.pendingDnsRequest.provider === "status";
            const result = root.parseResult(body, "network-tool dns");
            const success = exitSeen && lastExit === 0 && result.success;
            root.dnsBusy = false;
            if (success) {
                root.dnsProvider = result.provider || "Automatic";
                root.dnsServers = Array.isArray(result.servers) ? result.servers : [];
                root.dnsMixed = Boolean(result.mixed);
                root.dnsError = "";
                if (Array.isArray(result.profiles))
                    root.savedProfiles = result.profiles;
                if (!requestWasStatus) {
                    root.dnsNotice = result.reconnectRequired
                        ? "Saved. Reconnect " + result.reconnectDevices.join(", ") + " to apply it."
                        : "DNS updated on saved physical profiles.";
                }
            } else {
                root.dnsError = result.error || "The DNS update failed";
            }
            root.dnsActionFinished(success, root.dnsError);
            root.pendingDnsRequest = { provider: "status" };
            if (root.dnsRefreshAgain && root.acquired) {
                root.dnsRefreshAgain = false;
                Qt.callLater(root.refreshDns);
            } else if (success && !requestWasStatus && root.acquired) {
                Qt.callLater(root.refreshDns);
            }
        }
    }

    Process {
        id: bandProc
        property string body: ""
        property bool exitSeen: false
        property int lastExit: 0

        command: ["python3", root.helper, "band"]
        stdinEnabled: true
        stdout: StdioCollector { onStreamFinished: bandProc.body = text }
        stderr: StdioCollector {}
        onStarted: write(JSON.stringify(root.pendingBandRequest) + "\n")
        onExited: (exitCode, exitStatus) => {
            bandProc.exitSeen = true;
            bandProc.lastExit = exitCode;
        }
        onRunningChanged: {
            if (running) {
                body = "";
                exitSeen = false;
                lastExit = 0;
                return;
            }
            const result = root.parseResult(body, "network-tool band");
            const success = exitSeen && lastExit === 0 && result.success;
            root.bandBusy = false;
            if (success) {
                root.bandSelected = result.selected || "auto";
                root.bandError = "";
            } else {
                root.bandError = result.error || "The band change failed";
            }
            root.bandActionFinished(success, root.bandError);
            root.pendingBandRequest = { band: "status" };
            if (root.bandRefreshAgain && root.acquired) {
                root.bandRefreshAgain = false;
                Qt.callLater(root.refreshBand);
            } else if (root.acquired) {
                root.refresh();
            }
        }
    }

    Component.onDestruction: {
        if (scannerDevice)
            scannerDevice.scannerEnabled = false;
    }
}
