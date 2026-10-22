const test = require("node:test");
const { untranslated } = require("./shell.cjs");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { shellDir, load } = require("./shell.cjs");

// VPN profiles and the Wi-Fi hotspot: the pure helpers behind the drawer's
// VPN switch and the Network page's VPN and Hotspot groups, and the shape of
// those surfaces — a switch only for people who have a VPN, secrets that
// never enter QML outside the hotspot's join card, removal that asks first.

const H = load("NetworkHelpers.js");

function read(relative) {
    return untranslated(fs.readFileSync(path.join(shellDir, relative), "utf8"));
}

const OFFICE = { uuid: "u-office", name: "Office", type: "vpn", label: "OpenVPN", state: "", timestamp: 100 };
const HOME = { uuid: "u-home", name: "home", type: "wireguard", label: "WireGuard", state: "", timestamp: 300 };
const LAB = { uuid: "u-lab", name: "Lab", type: "vpn", label: "", state: "", timestamp: 0 };

test("the drawer offers the VPN in use, else the most recently used one", () => {
    assert.equal(H.preferredVpn([]), null);
    assert.equal(H.preferredVpn(undefined), null);
    assert.equal(H.preferredVpn([{ name: "no uuid" }]), null);
    assert.equal(H.preferredVpn([OFFICE, HOME, LAB]).uuid, "u-home", "most recently used");
    assert.equal(H.preferredVpn([OFFICE, HOME, { ...LAB, state: "activating" }]).uuid, "u-lab");
    assert.equal(H.preferredVpn([{ ...OFFICE, state: "activated" }, { ...LAB, state: "activating" }]).uuid,
        "u-office", "a connected VPN outranks one still connecting");
    assert.equal(H.preferredVpn([{ ...OFFICE, timestamp: 0 }, LAB]).uuid, "u-lab", "never used: by name");
});

test("VPN rows name their state, a running request first", () => {
    assert.equal(H.vpnStateText(OFFICE, ""), "Off");
    assert.equal(H.vpnStateText({ state: "activated" }, ""), "Connected");
    assert.equal(H.vpnStateText({ state: "activating" }, ""), "Connecting…");
    assert.equal(H.vpnStateText({ state: "deactivating" }, ""), "Disconnecting…");
    assert.equal(H.vpnStateText({ state: "activated" }, "disconnect"), "Disconnecting…");
    assert.equal(H.vpnStateText(OFFICE, "connect"), "Connecting…");
    assert.equal(H.isVpnActive({ state: "activating" }), true);
    assert.equal(H.isVpnActive(OFFICE), false);
    assert.equal(H.isVpnActive(null), false);
    assert.equal(H.vpnLabel(OFFICE), "OpenVPN");
    assert.equal(H.vpnLabel(LAB), "VPN");
    assert.equal(H.vpnLabel({ type: "wireguard" }), "WireGuard");
});

test("the hotspot group explains what it cannot do and what starting it costs", () => {
    assert.deepEqual(H.hotspotView({ available: false }),
        { visible: false, disabledReason: "", description: "", warning: "" });
    assert.equal(H.hotspotView(null).visible, false);
    assert.equal(H.hotspotView({ available: true, supported: false }).disabledReason,
        "This Wi-Fi adapter cannot host a hotspot");
    assert.equal(H.hotspotView({ available: true, supported: true, radioOff: true }).disabledReason,
        "Turn on Wi-Fi to use the hotspot");
    const off = H.hotspotView({ available: true, supported: true, dropsWifi: true, wifiConnection: "Home" });
    assert.equal(off.disabledReason, "");
    assert.equal(off.description, "Share this computer's connection over Wi-Fi");
    assert.match(off.warning, /^This adapter cannot join Wi-Fi and host a hotspot at once, so Home disconnects/);
    const on = H.hotspotView({ available: true, supported: true, state: "activated", ssid: "Studio",
        dropsWifi: true, wifiConnection: "Home" });
    assert.equal(on.description, "Devices can join Studio to share this computer's connection");
    assert.equal(on.warning, "", "nothing left to warn about once it is on");
    assert.equal(H.hotspotView({ available: true, supported: true, state: "activating" }).description, "Starting…");
});

test("hotspot names are checked as Wi-Fi network names", () => {
    assert.equal(H.ssidProblem("Studio guests"), "");
    assert.equal(H.ssidProblem("x".repeat(32)), "");
    assert.match(H.ssidProblem("x".repeat(33)), /at most 32 bytes/);
    assert.equal(H.ssidProblem("é".repeat(16)), "", "two bytes each");
    assert.match(H.ssidProblem("é".repeat(17)), /at most 32 bytes/);
    assert.match(H.ssidProblem("😀".repeat(9)), /at most 32 bytes/, "four bytes each");
    assert.notEqual(H.ssidProblem("line\nbreak"), "");
});

test("the hotspot's shared profile is neither a DNS target nor a known network", () => {
    const wired = { connectionType: "802-3-ethernet", ipv4Method: "auto", ipv4Dns: ["1.1.1.1", "1.0.0.1"],
        ipv6Dns: ["2606:4700:4700::1111", "2606:4700:4700::1001"], ipv4IgnoreAutoDns: true,
        ipv6IgnoreAutoDns: true };
    const hotspot = { connectionType: "802-11-wireless", ipv4Method: "shared", name: "NerdOS hotspot",
        ssid: "Studio", uuid: "u-hotspot" };
    assert.equal(H.sharedProfile(hotspot), true);
    assert.equal(H.dnsState([wired, hotspot]).provider, "Cloudflare", "the hotspot does not make DNS Mixed");
    const grouped = H.groupWifiNetworks([{ ssid: "Studio", signal: 60, security: "WPA2" }], [hotspot]);
    assert.equal(grouped.all[0].known, false);
});

test("the drawer's VPN switch exists only for people with a VPN profile", () => {
    const drawer = read("Popovers/Drawer/DrawerNetwork.qml");
    assert.match(drawer, /readonly property var vpn: NetworkHelpers\.preferredVpn\(NetworkDetails\.vpnProfiles\)/);
    assert.match(drawer, /id: vpnRow[\s\S]{0,700}?visible: vpn !== null/);
    assert.match(drawer,
        /onToggled: value => NetworkDetails\.runVpnAction\(\{\s*action: value \? "connect" : "disconnect", uuid: vpnRow\.uuid/);
    assert.match(drawer, /enabled: NetworkDetails\.vpnBusyUuid === ""/);
    assert.match(drawer, /text: vpnRow\.failure/, "a failed connect says why under the row");
    // Below Tailscale and above DNS, inside the existing section.
    const tailscale = drawer.indexOf("Tailscale.showSetup()");
    const vpn = drawer.indexOf("id: vpnRow");
    const dns = drawer.indexOf("id: dnsMark");
    assert.ok(tailscale > 0 && tailscale < vpn && vpn < dns);
    assert.doesNotMatch(drawer, /Repeater \{\s*model: NetworkDetails\.vpnProfiles/, "one compact row, not a list");

    const details = read("Common/NetworkDetails.qml");
    assert.match(details, /readonly property var vpnProfiles: Array\.isArray\(snapshot\.vpns\) \? snapshot\.vpns : \[\]/);
    assert.match(details, /id: vpnProc[\s\S]{0,200}?command: \["python3", root\.helper, "vpn"\]/);
    assert.match(details, /id: vpnProc[\s\S]{0,500}?onStarted: write\(JSON\.stringify\(root\.pendingVpnRequest\) \+ "\\n"\)/,
        "requests travel on stdin like every network-tool request");
    assert.match(details, /function runVpnAction\(request\) \{\s*if \(vpnProc\.running\)\s*return false;/);
});

test("the Network page lists VPNs with a switch each and removal that asks first", () => {
    const page = read("Settings/NetworkPage.qml");
    assert.match(page, /VpnGroup \{\s*width: parent\.width\s*service: page\.service\s*\}/);
    assert.match(page, /HotspotGroup \{\s*width: parent\.width\s*service: page\.service\s*\}/);
    assert.ok(page.indexOf("title: \"Connections\"") < page.indexOf("VpnGroup {")
        && page.indexOf("HotspotGroup {") < page.indexOf("IpSettings {"),
        "between the connection list and the selected connection's editor");
    assert.match(page,
        /function onCompleted\(result\) \{\s*const request = page\.service\.request;[\s\S]{0,160}?if \(request\.action === "vpn" \|\| request\.action === "hotspot"\)\s*return;/,
        "a VPN or hotspot request never discards the draft");
    assert.match(page, /hint: "Enterprise certificates, bridges and routing are in the advanced editor\."/);

    const group = read("Settings/VpnGroup.qml");
    assert.match(group, /title: "VPN"/);
    assert.match(group, /readonly property var vpns: service\.snapshot\.vpns \|\| \[\]/);
    assert.match(group, /Toggle \{[\s\S]{0,400}?onToggled: value => root\.run\(value \? "connect" : "disconnect", \{uuid: entry\.modelData\}\)/);
    assert.match(group, /onTriggered: root\.removing = entry\.modelData/);
    const confirm = group.slice(group.indexOf("visible: entry.confirming"));
    assert.match(confirm, /root\.run\("remove", \{uuid: entry\.modelData, confirmed: true\}\)/);
    assert.equal((group.match(/confirmed: true/g) ?? []).length, 1, "only the confirming press removes");
    assert.match(group, /FolderDialog \{[\s\S]{0,200}?chooseFile: true\s*nameFilters: \["\*\.ovpn", "\*\.conf"\]\s*onFileChosen: path => root\.run\("import", \{path: path\}\)/);
    assert.match(group, /text: "Advanced editor"[\s\S]{0,120}?onTriggered: SystemSettings\.openExternal\("network"\)/);
    assert.match(group, /No VPN connections yet\./);
    for (const surface of [group, read("Popovers/Drawer/DrawerNetwork.qml")]
        .map(source => source.slice(source.indexOf("vpn")))) {
        assert.doesNotMatch(surface, /vpn[^\n]*echoMode|password: /i, "the VPN plugin's own dialog asks for secrets");
    }
});

test("the hotspot group is one switch, a name and a join card", () => {
    const group = read("Settings/HotspotGroup.qml");
    assert.match(group, /visible: view\.visible/);
    assert.match(group, /title: "Hotspot"/);
    assert.match(group, /SwitchRow \{[\s\S]{0,900}?onToggled: value => \{[\s\S]{0,120}?root\.run\(value \? "start" : "stop"\)/);
    assert.match(group, /label: "Network name"/);
    assert.match(group, /text: root\.view\.warning\s*tone: "warning"/);
    assert.match(group,
        /text: "Show password and QR code"[\s\S]{0,80}?onTriggered: NetworkOverlayState\.openHotspot\(null, root\.status\.ssid, root\.status\.uuid\)/);
    assert.doesNotMatch(group, /"password"|\.password\b/, "the password stays out of the Settings page");
    assert.equal((group.match(/(SwitchRow|FieldRow|ActionRow) \{/g) ?? []).length, 3, "at most three rows");

    const state = read("Common/NetworkOverlayState.qml");
    assert.match(state, /function openHotspot\(screen, ssid, uuid\)[\s\S]{0,400}?hotspot: true[\s\S]{0,80}?root\.page = "qr";/);
    const overlay = read("NetworkOverlayWindow.qml");
    assert.match(overlay, /readonly property bool reveal: info\.hotspot === true/);
    assert.match(overlay, /hidden: Boolean\(info\.hidden\),\s*reveal: reveal/);
    assert.match(overlay, /qr\.password = qr\.reveal && typeof result\.password === "string" \? result\.password : "";/);
    assert.match(overlay, /Component\.onDestruction: \{[\s\S]{0,160}?password = "";/,
        "the password goes with the card, like the matrix");
    assert.match(overlay, /qrInfo\.hotspot \? "Join the hotspot" : "Share Wi-Fi"/);
});

test("the folder dialog can choose one file for an import", () => {
    const dialog = read("Settings/FolderDialog.qml");
    assert.match(dialog, /signal fileChosen\(string path\)/);
    assert.match(dialog, /showFiles: root\.chooseFile\s*nameFilters: root\.nameFilters/);
    assert.match(dialog, /openButton\.enabled = Qt\.binding\(\(\) => !root\.chooseFile \|\| root\.selectedIsFile\)/);
    assert.match(dialog, /if \(chooseFile\) \{\s*if \(selectedIsFile\)\s*fileChosen\(selectedPath\);\s*return;\s*\}/);
    assert.match(dialog, /onDoubleClicked: folderRow\.open\(\)/);
    // Folder mode is unchanged for the wallpaper page.
    assert.match(read("Settings/WallpaperPage.qml"), /FolderDialog \{\s*id: folderDialog\s*onFolderChosen:/);
});

test("VPN and hotspot are searchable and the groups are registered", () => {
    const search = read("Common/SettingsSearchData.js");
    assert.match(search, /page: "network", pageLabel: "Network", group: "VPN", label: "VPN connections"/);
    assert.match(search, /page: "network", pageLabel: "Network", group: "Hotspot", label: "Wi-Fi hotspot"/);
    const qmldir = read("Settings/qmldir");
    for (const type of ["VpnGroup", "HotspotGroup"])
        assert.match(qmldir, new RegExp(`^${type} ${type}\\.qml$`, "m"));
});

test("the hotspot profile never starts at boot and stays in NetworkManager's shared zone", () => {
    const helper = read("scripts/network-tool.py");
    const settings = helper.slice(helper.indexOf("HOTSPOT_SETTINGS = ("), helper.indexOf("PASSWORD_ALPHABET"));
    for (const pair of ['"connection.autoconnect", "no"', '"connection.zone", "nm-shared"',
        '"802-11-wireless.mode", "ap"', '"ipv4.method", "shared"'])
        assert.ok(settings.includes(pair), pair);
    assert.doesNotMatch(settings, /security\.psk"/, "the password goes through passwd-file, not argv");
});
