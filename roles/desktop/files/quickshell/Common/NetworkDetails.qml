pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "NetworkDetailsHelpers.js" as NetworkDetailsHelpers
import "NetworkHelpers.js" as NetworkHelpers
import "ProcHelpers.js" as ProcHelpers

// Ref-counted, view-lifetime network diagnostics and mutations.  The bar's
// lightweight EthernetState remains independent; everything here runs only
// while the Network panel is actually acquired.
//
// The live figures cost no process per sample: throughput reads the kernel's
// byte counters every 1.5 seconds through FileView, and latency comes from
// two long-lived `ping -O` processes that report once per probe. The
// device/route/profile/scan snapshot (network-tool.py, six processes) runs
// on NetworkManager events from NetworkStatus's monitor, after an action,
// and on a slow safety poll for what no event announces (scan results,
// signal and bitrate drift).
Singleton {
    id: root

    readonly property string helper: Quickshell.shellDir + "/scripts/network-tool.py"
    readonly property int pingHistoryWindow: 24
    readonly property int pingAverageWindow: 5
    readonly property int pollIntervalMs: 1500
    readonly property int snapshotIntervalMs: 10000
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
    readonly property var snapshotPrimary:
        NetworkHelpers.selectPrimaryInterface(devices, routes)
    // Views read the primary device's rxBytes/txBytes as running totals, so
    // they carry the live counters rather than the last snapshot's.
    readonly property var primary: NetworkDetailsHelpers.withCounters(
        snapshotPrimary, primaryInterface, liveCounters)
    readonly property string primaryInterface: snapshotPrimary
        ? NetworkHelpers.interfaceName(snapshotPrimary) : ""
    readonly property string primaryType: snapshotPrimary
        ? NetworkHelpers.physicalType(snapshotPrimary) : ""
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
    // An access point appearing or leaving the radio's scan refreshes the
    // snapshot's list at scan speed; signal drift waits for the slow poll.
    // Only names are read, so a strength change does not re-evaluate this.
    // The first key after acquire() needs nothing: acquire() refreshes.
    readonly property string scanKey: {
        if (!root.acquired || !WifiState.device || !WifiState.enabled)
            return "";
        return WifiState.device.networks.values.map(network => network.name)
            .sort().join("\n");
    }
    property string lastScanKey: ""
    onScanKeyChanged: {
        const previous = lastScanKey;
        lastScanKey = scanKey;
        if (acquired && previous !== "" && scanKey !== "")
            snapshotDebounce.restart();
    }
    readonly property var groupedNetworks: NetworkHelpers.groupWifiNetworks(
        scanNetworks, savedProfiles.length > 0 ? savedProfiles : snapshot.profiles)
    readonly property var knownNetworks: groupedNetworks.known
    readonly property var otherNetworks: groupedNetworks.other
    readonly property var activeWifiNetwork: groupedNetworks.all.find(network =>
        network.connected) ?? null

    property var previousCounters: null
    property var liveCounters: null
    property real downloadRate: 0
    property real uploadRate: 0
    // Counters and pings follow the snapshot's primary device, and only
    // while a view holds the controller.
    readonly property string counterInterface: acquired ? primaryInterface : ""
    readonly property string routerPingTarget: acquired && snapshotPrimary
        ? NetworkDetailsHelpers.pingTarget(snapshotPrimary.gateway) : ""
    readonly property string internetPingTarget: acquired && snapshotPrimary
        ? "1.1.1.1" : ""
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
        sampleCounters();
        refresh();
        refreshDns();
    }

    function release() {
        watchers = Math.max(0, watchers - 1);
        if (watchers !== 0)
            return;
        detailsPoll.stop();
        snapshotPoll.stop();
        snapshotDebounce.stop();
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
        liveCounters = null;
        downloadRate = 0;
        uploadRate = 0;
        routerPingHistory = [];
        internetPingHistory = [];
    }

    // One throughput sample from sysfs. The rate is taken between this
    // tick's reads and the previous tick's, so it never depends on FileView
    // signalling a reload whose text did not change.
    function sampleCounters() {
        const iface = counterInterface;
        if (iface === "") {
            liveCounters = null;
            return;
        }
        rxCounterView.reload();
        txCounterView.reload();
        const sample = NetworkDetailsHelpers.counterSample(iface,
            rxCounterView.text(), txCounterView.text(), Date.now());
        const rate = NetworkHelpers.calculateRates(previousCounters, sample,
            sample.timestamp);
        previousCounters = rate.next;
        downloadRate = rate.download;
        uploadRate = rate.upload;
        liveCounters = sample;
    }

    // A (re)started pinger begins a new icmp_seq run; "" stops it. Setting
    // running false then true restarts it once the old ping has exited.
    function restartPinger(pinger, target) {
        pinger.lastSeq = -1;
        pinger.lastSampleAt = Date.now();
        pinger.running = false;
        const command = NetworkDetailsHelpers.pingCommand(target, pollIntervalMs);
        if (!command)
            return;
        pinger.command = command;
        pinger.running = true;
    }

    function pingLine(pinger, router, line) {
        const sample = NetworkDetailsHelpers.pingSample(pinger.lastSeq, line);
        if (!sample)
            return;
        pinger.lastSeq = sample.seq;
        pinger.lastSampleAt = Date.now();
        recordPing(router, sample.ms);
    }

    // `ping -O` reports every probe it sends, but one that cannot send at
    // all (no route) only prints errors. Each interval of silence beyond one
    // counts as a lost probe, so a stale latency cannot outlive the path it
    // measured. A long gap (a suspend) adds at most one window of losses.
    function checkPinger(pinger, router) {
        if (!pinger.running)
            return;
        const missed = NetworkDetailsHelpers.missedProbes(pinger.lastSampleAt,
            Date.now(), pollIntervalMs);
        if (missed === 0)
            return;
        pinger.lastSampleAt += missed * pollIntervalMs;
        for (let i = 0; i < Math.min(missed, pingHistoryWindow); i++)
            recordPing(router, null);
    }

    function recordPing(router, ms) {
        if (router)
            routerPingHistory = NetworkHelpers.updatePingHistory(routerPingHistory,
                ms, pingHistoryWindow);
        else
            internetPingHistory = NetworkHelpers.updatePingHistory(internetPingHistory,
                ms, pingHistoryWindow);
    }

    // A pinger that ended on its own (no route yet, the network went away)
    // is retried at the sample cadence, and each interval without it counts
    // as a lost probe, as the one-shot pings used to.
    function retryPingers() {
        if (!acquired)
            return;
        if (routerPingTarget !== "" && !routerPinger.running) {
            recordPing(true, null);
            restartPinger(routerPinger, routerPingTarget);
        }
        if (internetPingTarget !== "" && !internetPinger.running) {
            recordPing(false, null);
            restartPinger(internetPinger, internetPingTarget);
        }
    }

    onRouterPingTargetChanged: restartPinger(routerPinger, routerPingTarget)
    onInternetPingTargetChanged: restartPinger(internetPinger, internetPingTarget)

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

        // A new primary device starts its rates and ping history afresh, from
        // a baseline read straight away rather than at the next tick.
        const nextPrimary = NetworkHelpers.selectPrimaryInterface(result.devices, result.routes);
        const nextInterface = nextPrimary ? NetworkHelpers.interfaceName(nextPrimary) : "";
        if (oldInterface !== nextInterface) {
            resetSamples();
            sampleCounters();
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
        onTriggered: {
            root.sampleCounters();
            root.checkPinger(routerPinger, true);
            root.checkPinger(internetPinger, false);
        }
    }

    Timer {
        id: snapshotPoll
        interval: root.snapshotIntervalMs
        repeat: true
        running: root.acquired
        onTriggered: root.refresh()
    }

    // `nmcli monitor` prints a burst of lines per change; take one snapshot.
    Timer {
        id: snapshotDebounce
        interval: 250
        onTriggered: root.refresh()
    }

    Timer {
        id: pingRetry
        interval: root.pollIntervalMs
        repeat: true
        running: root.acquired
            && ((root.routerPingTarget !== "" && !routerPinger.running)
                || (root.internetPingTarget !== "" && !internetPinger.running))
        onTriggered: root.retryPingers()
    }

    Connections {
        target: WifiState

        function onDeviceChanged() {
            root.syncScanner();
        }
    }

    Connections {
        target: NetworkStatus

        function onMonitorEvent(line) {
            if (root.acquired)
                snapshotDebounce.restart();
        }

        // Events are lost while the stream is down or reattaching, so each
        // edge takes a fresh snapshot.
        function onMonitorRunningChanged() {
            if (root.acquired)
                snapshotDebounce.restart();
        }
    }

    FileView {
        id: rxCounterView
        path: NetworkDetailsHelpers.counterPath(root.counterInterface, "rx_bytes")
        printErrors: false
        blockAllReads: true
    }

    FileView {
        id: txCounterView
        path: NetworkDetailsHelpers.counterPath(root.counterInterface, "tx_bytes")
        printErrors: false
        blockAllReads: true
    }

    // Stopping or ending on their own needs no handler: pingRetry watches
    // their falling edge. stderr is split and dropped rather than collected,
    // since a long-lived ping may repeat "Network is unreachable" for hours.
    Process {
        id: routerPinger
        property int lastSeq: -1
        property real lastSampleAt: 0

        stdout: SplitParser { onRead: line => root.pingLine(routerPinger, true, line) }
        stderr: SplitParser {}
    }

    Process {
        id: internetPinger
        property int lastSeq: -1
        property real lastSampleAt: 0

        stdout: SplitParser { onRead: line => root.pingLine(internetPinger, false, line) }
        stderr: SplitParser {}
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
