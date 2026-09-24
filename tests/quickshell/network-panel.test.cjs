const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { shellDir, load } = require("./shell.cjs");

function read(relative) {
    return fs.readFileSync(path.join(shellDir, relative), "utf8");
}

test("the wide Network panel has a physical-transport hero and live diagnostic grid", () => {
    const panel = read("Popovers/WifiPopover.qml");
    assert.match(panel, /implicitWidth:\s*Math\.min\(600/);
    assert.match(panel, /readonly property var primary:\s*NetworkDetails\.primary/);
    for (const label of ["Ping", "Packet loss", "Receive", "Send", "Downloaded",
        "Uploaded", "IPv4 address", "Gateway"])
        assert.match(panel, new RegExp(`label: "${label}"`));
    assert.match(panel, /NetworkHelpers\.formatRate\(NetworkDetails\.downloadRate\)/);
    assert.match(panel, /NetworkHelpers\.formatBytes\(root\.primary\.rxBytes\)/);
});

test("network details poll only while acquired and serialize snapshots", () => {
    const controller = read("Common/NetworkDetails.qml");
    assert.match(controller, /function acquire\(\)/);
    assert.match(controller, /function release\(\)/);
    assert.match(controller, /readonly property int pollIntervalMs:\s*1500/);
    assert.match(controller, /interval:\s*root\.pollIntervalMs/);
    assert.match(controller, /pollCadenceText:/,
        "the visible cadence label must come from the actual polling interval");
    assert.match(controller, /running:\s*root\.acquired/);
    assert.match(controller, /if \(snapshotProc\.running\)[\s\S]*snapshotAgain = true/);
    assert.match(controller, /scannerDevice\.scannerEnabled = false/);
    assert.match(controller, /NetworkHelpers\.calculateRates/);
    assert.match(controller, /NetworkHelpers\.updatePingHistory/);
});

test("the live network figures start no process per sample", () => {
    const controller = read("Common/NetworkDetails.qml");
    // Throughput: the 1.5 s tick reads sysfs counters through FileView.
    assert.match(controller,
        /id: detailsPoll\s*interval: root\.pollIntervalMs\s*repeat: true\s*running: root\.acquired\s*onTriggered: \{\s*root\.sampleCounters\(\);\s*root\.checkPinger\(routerPinger, true\);\s*root\.checkPinger\(internetPinger, false\);/);
    for (const counter of ["rx_bytes", "tx_bytes"])
        assert.match(controller, new RegExp(
            `FileView \\{[^}]*counterPath\\(root\\.counterInterface, "${counter}"\\)[^}]*blockAllReads: true`));
    assert.match(controller, /readonly property string counterInterface: acquired \? primaryInterface : ""/);
    // Latency: two long-lived pingers, stopped when released.
    assert.match(controller, /readonly property string routerPingTarget: acquired && snapshotPrimary/);
    assert.match(controller, /readonly property string internetPingTarget: acquired && snapshotPrimary/);
    assert.match(controller, /onRouterPingTargetChanged: restartPinger\(routerPinger, routerPingTarget\)/);
    assert.match(controller, /onInternetPingTargetChanged: restartPinger\(internetPinger, internetPingTarget\)/);
    assert.match(controller, /id: pingRetry[\s\S]{0,80}running: root\.acquired\s*&&/);
    // The snapshot follows NetworkManager's single monitor plus a slow poll.
    assert.match(controller,
        /id: snapshotPoll\s*interval: root\.snapshotIntervalMs\s*repeat: true\s*running: root\.acquired\s*onTriggered: root\.refresh\(\)/);
    assert.match(controller, /readonly property int snapshotIntervalMs:\s*10000/);
    assert.match(controller,
        /target: NetworkStatus\s*function onMonitorEvent\(line\) \{\s*if \(root\.acquired\)\s*snapshotDebounce\.restart\(\);/);
    assert.match(controller, /function onMonitorRunningChanged\(\) \{\s*if \(root\.acquired\)/);
    assert.doesNotMatch(controller, /result\.diagnostics/,
        "ping results no longer come from the snapshot helper");
    const release = controller.slice(controller.indexOf("function release()"),
        controller.indexOf("function syncScanner()"));
    for (const timer of ["detailsPoll", "snapshotPoll", "snapshotDebounce"])
        assert.match(release, new RegExp(`${timer}\\.stop\\(\\)`));
});

test("sysfs counter samples feed the existing rate math and the primary device", () => {
    const D = load("NetworkDetailsHelpers.js");
    const N = load("NetworkHelpers.js");
    assert.equal(D.counterPath("wlan0", "rx_bytes"), "/sys/class/net/wlan0/statistics/rx_bytes");
    assert.equal(D.counterPath("enp0s31f6", "tx_bytes"), "/sys/class/net/enp0s31f6/statistics/tx_bytes");
    for (const bad of ["", "..", "../../etc", "wlan0/../x", "a b"])
        assert.equal(D.counterPath(bad, "rx_bytes"), "", bad);
    assert.equal(D.counterPath("wlan0", "rx_errors"), "");

    const first = D.counterSample("wlan0", "1000\n", "500\n", 1000);
    assert.deepEqual(first, { interface: "wlan0", rxBytes: 1000, txBytes: 500, timestamp: 1000 });
    const second = D.counterSample("wlan0", "4000\n", "1500\n", 2500);
    const rate = N.calculateRates(N.calculateRates(null, first, 1000).next, second, 2500);
    assert.equal(rate.download, 2000);
    assert.equal(rate.upload, 1000 / 1.5);
    assert.deepEqual(D.counterSample("wlan0", "", "junk", 3000),
        { interface: "wlan0", rxBytes: null, txBytes: null, timestamp: 3000 });

    const device = { interface: "wlan0", ipv4: "192.168.1.20", rxBytes: 10, txBytes: 20 };
    const merged = D.withCounters(device, "wlan0", second);
    assert.deepEqual(merged, { interface: "wlan0", ipv4: "192.168.1.20", rxBytes: 4000, txBytes: 1500 });
    assert.equal(device.rxBytes, 10, "the snapshot object is not mutated");
    assert.equal(D.withCounters(device, "eth0", second), device);
    assert.equal(D.withCounters(device, "wlan0", null), device);
    assert.equal(D.withCounters(null, "wlan0", second), null);
});

test("long-lived ping output becomes one latency or loss sample per probe", () => {
    const D = load("NetworkDetailsHelpers.js");
    assert.equal(D.parsePingLine("PING 1.1.1.1 (1.1.1.1) 56(84) bytes of data."), null);
    assert.deepEqual(D.parsePingLine("64 bytes from 1.1.1.1: icmp_seq=3 ttl=57 time=14.2 ms"),
        { seq: 3, ms: 14.2 });
    assert.deepEqual(D.parsePingLine("64 bytes from 10.0.0.1: icmp_seq=4 ttl=64 time<1 ms"),
        { seq: 4, ms: 1 });
    assert.deepEqual(D.parsePingLine("no answer yet for icmp_seq=5"), { seq: 5, ms: null });
    assert.equal(D.parsePingLine("ping: sendmsg: Network is unreachable"), null);

    // A reply that arrives after its probe was counted lost, and a DUP!,
    // add nothing; the sequence wraps at 16 bits.
    assert.deepEqual(D.pingSample(-1, "no answer yet for icmp_seq=1"), { seq: 1, ms: null });
    assert.equal(D.pingSample(1, "64 bytes from 1.1.1.1: icmp_seq=1 ttl=57 time=1600 ms"), null);
    assert.equal(D.pingSample(2, "64 bytes from 1.1.1.1: icmp_seq=2 ttl=57 time=9 ms (DUP!)"), null);
    assert.deepEqual(D.pingSample(65535, "64 bytes from 1.1.1.1: icmp_seq=0 ttl=57 time=9 ms"),
        { seq: 0, ms: 9 });

    // A pinger that cannot send prints no per-probe line at all.
    assert.equal(D.missedProbes(0, 1500, 1500), 0);
    assert.equal(D.missedProbes(0, 2999, 1500), 0);
    assert.equal(D.missedProbes(0, 3000, 1500), 1);
    assert.equal(D.missedProbes(0, 7600, 1500), 4);
    assert.equal(D.missedProbes(0, 5000, 0), 0);

    assert.deepEqual(D.pingCommand("192.168.1.1", 1500),
        ["env", "LC_ALL=C", "ping", "-n", "-O", "-i", "1.5", "--", "192.168.1.1"]);
    assert.deepEqual(D.pingCommand("fe80::1", 1500).slice(-2), ["--", "fe80::1"]);
    for (const bad of ["", "-f", "example.com", "1.1.1.1 -c 1", "fe80::1%wlan0", null]) {
        assert.equal(D.pingCommand(bad, 1500), null, bad);
        assert.equal(D.pingTarget(bad), "", bad);
    }
    assert.equal(D.pingTarget("192.168.1.1"), "192.168.1.1");
});

test("the pinger command and parser agree with the installed ping",
    { skip: spawnSync("ping", ["-V"]).status !== 0 && "ping is not installed" }, () => {
    const D = load("NetworkDetailsHelpers.js");
    const argv = D.pingCommand("127.0.0.1", 200);
    const run = spawnSync("timeout", ["0.7", ...argv], { encoding: "utf8" });
    if (!/icmp_seq=/.test(run.stdout))
        return; // No ICMP socket permission here (e.g. a restricted container).
    let lastSeq = -1;
    const samples = [];
    for (const line of run.stdout.split("\n")) {
        const sample = D.pingSample(lastSeq, line);
        if (sample) {
            lastSeq = sample.seq;
            samples.push(sample);
        }
    }
    assert.ok(samples.length >= 2, run.stdout);
    assert.ok(samples.every(sample => sample.ms !== null && sample.ms >= 0), run.stdout);
});

test("DNS controls remain profile-backed and Wi-Fi band options stay out of the view", () => {
    const panel = read("Popovers/WifiPopover.qml");
    const controller = read("Common/NetworkDetails.qml");
    assert.match(panel, /model:\s*\["Automatic", "Cloudflare", "Google", "Custom"\]/);
    assert.match(panel, /NetworkHelpers\.validateDnsServers/);
    assert.match(panel, /NetworkDetails\.dnsMixed/);
    assert.match(panel, /NetworkDetails\.dnsNotice/);
    assert.doesNotMatch(panel, /WI-FI BAND/);
    assert.doesNotMatch(panel, /NetworkDetails\.bandAvailable/);
    assert.doesNotMatch(panel, /NetworkDetails\.setBand/);
    assert.match(controller, /command:\s*\["python3", root\.helper, "dns"\]/);
});

test("Wi-Fi defaults to a connected-network picker and expands all actionable rows", () => {
    const panel = read("Popovers/WifiPopover.qml");
    assert.match(panel, /property bool wifiNetworksOpen:\s*false/);
    assert.match(panel, /component WifiNetworkPicker:\s*Rectangle/);
    assert.match(panel, /id:\s*wifiPicker[\s\S]{0,300}currentLabel:\s*root\.connectedWifiName/);
    assert.match(panel, /expanded:\s*root\.wifiNetworksOpen/);
    assert.match(panel, /id:\s*wifiNetworkList[\s\S]{0,80}visible:\s*root\.wifiNetworksOpen/);
    assert.match(panel, /function collapseWifiNetworks\(\)[\s\S]{0,100}clearCredentials\(\)/);
    assert.match(panel, /text:\s*"KNOWN NETWORKS"/);
    assert.match(panel, /text:\s*"OTHER NETWORKS"/);
    assert.match(panel, /model:\s*root\.wifiNetworksOpen && WifiState\.enabled\s*\? NetworkDetails\.knownNetworks/);
    assert.match(panel, /model:\s*root\.wifiNetworksOpen && WifiState\.enabled\s*\? NetworkDetails\.otherNetworks/);
    assert.match(panel, /action:\s*"disconnect"/);
    assert.match(panel, /action:\s*"forget"/);
    assert.match(panel, /credentialIdentity/);
    assert.match(panel, /echoMode:\s*TextInput\.Password/);
    assert.match(panel, /Certificates\? Network Settings/);
    assert.match(panel, /function clearCredentials\(\)/);
    assert.match(panel, /if \(runConnectRequest\(request\)\)\s*clearCredentials\(\)/);
    assert.match(panel, /NetworkDetails\.wifiError\(network\.ssid\)/);
});

test("every managed Ethernet port retains loading, absent, failure and compact states", () => {
    const panel = read("Popovers/WifiPopover.qml");
    assert.match(panel, /text:\s*"ETHERNET"/);
    assert.match(panel, /model:\s*EthernetState\.devices/);
    assert.match(panel, /Checking Ethernet…/);
    assert.match(panel, /Ethernet status unavailable/);
    assert.match(panel, /No Ethernet ports/);
    assert.match(panel, /ethernetRow\.modelData\.device \+ " · "/);
});

test("one disposable network overlay is registered at shell scope", () => {
    const shell = read("shell.qml");
    const overlay = read("NetworkOverlayWindow.qml");
    const state = read("Common/NetworkOverlayState.qml");
    assert.equal((shell.match(/NetworkOverlayWindow\s*\{/g) || []).length, 1);
    assert.match(state, /function openQr\(screen, interfaceName\)/);
    assert.match(state, /function openSpeedTest\(screen, interfaceName\)/);
    assert.match(state, /property var speedDevices:\s*\[\]/);
    assert.match(state, /NetworkDetails\.physicalDevices\.filter/);
    assert.match(state, /function selectSpeedInterface\(interfaceName\)/);
    assert.match(state, /function close\(\)/);
    assert.match(state, /Popouts\.close\(\)/);
    assert.match(state, /Launcher\.close\(\)/);
    assert.match(overlay, /active:\s*NetworkOverlayState\.open/);
    assert.match(overlay, /sourceComponent:\s*NetworkOverlayState\.page === "qr" \? qrPage\s*:\s*NetworkOverlayState\.page === "tailscale" \? tailscalePage : speedPage/);
    assert.match(overlay, /Keys\.onEscapePressed:\s*NetworkOverlayState\.close\(\)/);
    assert.match(overlay, /onClicked:\s*NetworkOverlayState\.close\(\)/);
});

test("QR generation is immediate and sustained speed tests support device switching", () => {
    const overlay = read("NetworkOverlayWindow.qml");
    assert.match(overlay, /stdinEnabled:\s*true/);
    assert.match(overlay, /Component\.onCompleted:[\s\S]{0,400}startQr\(\)/);
    assert.match(overlay, /pendingQrRequest = \{[\s\S]{0,100}uuid: info\.uuid/);
    assert.doesNotMatch(overlay, /Reveal password & QR/);
    assert.doesNotMatch(overlay, /id:\s*passwordProc/);
    assert.match(overlay, /Component\.onDestruction:[\s\S]{0,200}matrix = \[\]/);
    assert.match(overlay, /text:\s*"TEST DEVICE"/);
    assert.match(overlay, /function chooseInterface\(interfaceName\)/);
    assert.match(overlay, /NetworkOverlayState\.selectSpeedInterface\(selectedInterface\)/);
    assert.match(overlay, /command:\s*\["python3", root\.speedHelper, "--interface"/);
    assert.match(overlay, /speedProc\.signal\(15\)/);
    assert.match(overlay,
        /label:\s*speedProc\.running\s*\?\s*"Cancel"\s*:\s*"Run Again"/);
    assert.match(overlay, /component SpeedDial:/);

    const speedHelper = read("scripts/network-speedtest.py");
    assert.match(speedHelper, /api\.fast\.com\/netflix\/speedtest\/v2/);
    assert.match(speedHelper, /NETWORK_SPEEDTEST_PARALLEL", 8/);
    assert.match(speedHelper, /NETWORK_SPEEDTEST_PHASE_SECONDS", 5\.0/);
    assert.match(speedHelper, /rx_bytes/);
    assert.match(speedHelper, /tx_bytes/);
    assert.match(speedHelper, /"--interface", interface/);
});

test("new runtime commands are explicit desktop dependencies", () => {
    const tasks = fs.readFileSync(path.resolve(shellDir, "../../tasks/main.yml"), "utf8");
    for (const dependency of ["NetworkManager", "python3", "curl", "iw", "qrencode", "iproute", "iputils", "dnf5-plugins"])
        assert.match(tasks, new RegExp(`- ${dependency}(?:\\s|$)`));
});
