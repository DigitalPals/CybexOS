const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { shellDir } = require("./shell.cjs");

function read(relative) {
    return fs.readFileSync(path.join(shellDir, relative), "utf8");
}

function objectBlock(source, start) {
    let depth = 0;
    const opening = source.indexOf("{", start);
    for (let index = opening; index < source.length; index++) {
        if (source[index] === "{")
            depth++;
        else if (source[index] === "}" && --depth === 0)
            return source.slice(start, index + 1);
    }
    assert.fail("unterminated QML object block");
}

test("the Internet row always opens Network details and never toggles Wi-Fi", () => {
    const source = read("Popovers/ControlCenterPopover.qml");
    const title = source.indexOf('title: "Internet"');
    assert.ok(title >= 0);
    const start = source.lastIndexOf("RadioRow {", title);
    const row = objectBlock(source, start);

    assert.match(row, /onActivated:\s*Popouts\.openPanel\("wifi", "right"\)/);
    assert.doesNotMatch(row, /WifiState\.setEnabled/);
    for (const label of ["Ethernet + Wi-Fi", "Ethernet", "No connection", "Offline"])
        assert.match(row, new RegExp(label.replace(/[+]/g, "\\+")));
    assert.match(row, /on:\s*EthernetState\.connected \|\| WifiState\.connected/);

    // One activation, not three. Left-click, right-click and the chevron's own
    // hit area all used to call openPanel() with the same arguments — three
    // targets for one outcome, and a chevron that looked like it did something
    // the row did not.
    const radioRow = objectBlock(source, source.indexOf("component RadioRow:"));
    assert.match(radioRow,
        /onClicked:\s*\{[\s\S]*?radio\.forceActiveFocus\(\);[\s\S]*?radio\.activated\(\);[\s\S]*?\}/,
        "pointer activation must leave keyboard focus on the action it invoked");
    assert.doesNotMatch(radioRow, /RightButton/,
        "a radio row has one outcome, so it must not split the mouse buttons");
    assert.equal(radioRow.match(/MouseArea\s*\{/g).length, 1,
        "the whole row is the hit target — no separate chevron MouseArea");
});

test("the Bluetooth row always opens details and never toggles the radio", () => {
    const source = read("Popovers/ControlCenterPopover.qml");
    const title = source.indexOf('title: "Bluetooth"');
    assert.ok(title >= 0);
    const start = source.lastIndexOf("RadioRow {", title);
    const row = objectBlock(source, start);

    assert.match(row,
        /onActivated:\s*Popouts\.openPanel\("bluetooth", "right"\)/);
    assert.doesNotMatch(row, /BluetoothState\.toggle/);
});

test("the stable wifi popout is a scrollable Ethernet and Wi-Fi Network view", () => {
    const source = read("Popovers/WifiPopover.qml");
    assert.match(source, /text:\s*"Network"/);
    assert.match(source, /text:\s*"TAILSCALE"/);
    assert.match(source, /text:\s*"ETHERNET"/);
    assert.match(source, /model:\s*EthernetState\.devices/);
    assert.match(source, /model:\s*WifiState\.others/);
    assert.match(source, /Flickable\s*\{/);
    assert.match(source, /ScrollChrome\s*\{/);
    assert.match(source, /checked:\s*WifiState\.enabled/);
    assert.match(source, /onToggled:\s*value => root\.setWifiEnabled\(value\)/);
    assert.match(source,
        /function setWifiEnabled\(value\)[\s\S]{0,100}WifiState\.setEnabled\(value\)/);
    assert.match(source, /text:\s*"Network settings"/);
    assert.match(source, /gnome-control-center network/);
    assert.doesNotMatch(source, /gnome-control-center wifi/);
});

test("Ethernet loading, absence and read failures are separate UI states", () => {
    const source = read("Popovers/WifiPopover.qml");
    assert.match(source, /!EthernetState\.known/);
    assert.match(source, /Checking Ethernet…/);
    assert.match(source, /EthernetState\.error !== ""/);
    assert.match(source, /Ethernet status unavailable/);
    assert.match(source, /EthernetState\.devices\.length === 0/);
    assert.match(source, /No Ethernet ports/);
});

test("the combined menubar indicator gives wired transport priority", () => {
    const module = read("Bar/Modules/Wifi.qml");
    assert.match(module, /moduleId:\s*"wifi"/);
    assert.match(module, /panelName:\s*"wifi"/);
    assert.match(module, /EthernetState\.connected \? "lan"/);
    assert.match(module, /EthernetState\.connected \|\| WifiState\.connected/);
    assert.match(module, /for \(const device of EthernetState\.connectedDevices\)/);
    assert.match(module, /"Ethernet " \+ \(device\.connection \|\| device\.device\)/);
    assert.match(module, /"Wi-Fi " \+ WifiState\.name/);
    assert.match(module, /if \(Tailscale\.connected\)/);
    assert.match(module, /Tailscale\.net \|\| Tailscale\.host/);
    assert.match(module, /Tailscale\.exitNode/);
    assert.doesNotMatch(module, /BrandIcon\s*\{/,
        "Tailscale belongs in the tooltip and panel, not beside the transport glyph");
});

test("Tailscale is an overlay with a persistent drill-in, not the physical route", () => {
    const singleton = read("Common/Tailscale.qml");
    const panel = read("Popovers/WifiPopover.qml");

    assert.match(singleton,
        /readonly property bool connected:\s*running && ip !== "" && statusError === ""/);
    assert.match(panel, /component TailscaleSummary:\s*Rectangle/);
    assert.match(panel, /TailscaleSummary\s*\{\}/);
    assert.match(panel, /Stopped · open details to connect/);
    assert.match(panel, /exit node active/);
    assert.match(panel, /Popouts\.openPanel\("tailscale", "right"\)/);

    // Tailscale augments the view; the hero and diagnostics remain bound to
    // NetworkDetails' selected Ethernet/Wi-Fi interface.
    assert.match(panel, /readonly property var primary:\s*NetworkDetails\.primary/);
    assert.match(panel, /NetworkDetails\.primaryInterface/);
    assert.doesNotMatch(panel, /primary:\s*Tailscale/);
});

test("Tailscale polling follows Network consumers and refreshes new views", () => {
    const singleton = read("Common/Tailscale.qml");
    const module = read("Bar/Modules/Wifi.qml");
    const panel = read("Popovers/WifiPopover.qml");

    assert.match(singleton,
        /function acquire\(\)[\s\S]{0,120}watchers\+\+;[\s\S]{0,80}if \(!statusProc\.running\)\s*refresh\(\)/);
    // The menubar's permanent claim polls slowly; an open view polls fast.
    assert.match(singleton, /readonly property int livePollMs:\s*30000/);
    assert.match(singleton, /readonly property int idlePollMs:\s*120000/);
    assert.match(singleton,
        /interval:\s*root\.missing \? root\.missingPollMs\s*: root\.liveWatchers > 0 \? root\.livePollMs : root\.idlePollMs/);
    // Nothing polls an idle or locked session; the first input refreshes.
    assert.match(singleton, /running:\s*root\.watchers > 0 && !Activity\.idle/);
    assert.match(singleton,
        /target: Activity[\s\S]{0,80}function onResumed\(\)[\s\S]{0,120}root\.refresh\(\)/);
    // A missing binary is probed hourly, not forked every poll.
    assert.match(singleton, /readonly property int missingPollMs:\s*3600000/);
    assert.match(singleton, /missing = exitCode === ProcHelpers\.NOT_STARTED;/);
    assert.match(singleton,
        /function acquireLive\(\)\s*\{\s*liveWatchers\+\+;\s*acquire\(\);/);
    assert.match(singleton,
        /function releaseLive\(\)\s*\{[\s\S]{0,80}liveWatchers - 1\);\s*release\(\);/);
    const drawer = read("Popovers/Drawer/DrawerNetwork.qml");
    assert.match(drawer, /onClaimed:[\s\S]{0,200}Tailscale\.acquireLive\(\)/);
    assert.match(drawer, /onReleased:[\s\S]{0,200}Tailscale\.releaseLive\(\)/);
    for (const source of [module, panel]) {
        assert.match(source, /Tailscale\.acquire\(\)/);
        assert.match(source, /Tailscale\.release\(\)/);
    }
});

test("the Tailscale switch issues exactly one requested state change", () => {
    const singleton = read("Common/Tailscale.qml");
    const panel = read("Popovers/TailscalePopover.qml");
    const checked = panel.indexOf("checked: Tailscale.running");
    assert.ok(checked >= 0);
    const start = panel.lastIndexOf("Toggle {", checked);
    const toggle = objectBlock(panel, start);

    assert.match(toggle, /onToggled:\s*value => Tailscale\.setRunning\(value\)/);
    assert.doesNotMatch(toggle, /execDetached/);
    assert.match(singleton,
        /function setRunning\(value\)[\s\S]{0,140}Quickshell\.execDetached\(\["tailscale", value \? "up" : "down"\]\)/);
});

test("wired monitoring is ref-counted by each visible Network consumer", () => {
    const singleton = read("Common/EthernetState.qml");
    const module = read("Bar/Modules/Wifi.qml");
    const popover = read("Popovers/WifiPopover.qml");
    const control = read("Popovers/ControlCenterPopover.qml");

    assert.match(singleton, /function acquire\(\)/);
    assert.match(singleton, /function release\(\)/);
    // One NetworkManager event stream for the shell: wired changes arrive
    // through NetworkStatus's `nmcli monitor`, and the poll is only a
    // safety net while that stream is down.
    assert.doesNotMatch(singleton, /"nmcli", "device", "monitor"/);
    assert.match(singleton,
        /target: NetworkStatus[\s\S]*?function onMonitorEvent\(line\)[\s\S]*?monitorDebounce\.restart\(\)/);
    assert.match(singleton, /function onMonitorRunningChanged\(\)/);
    assert.match(singleton,
        /id: poll[\s\S]{0,80}running: root\.watchers > 0 && !NetworkStatus\.monitorRunning/);
    assert.match(singleton, /property bool known:/);
    assert.match(singleton, /property string error:/);
    assert.match(singleton, /readonly property var connectedDevices:/);
    for (const source of [module, popover, control]) {
        assert.match(source, /EthernetState\.acquire\(\)/);
        assert.match(source, /EthernetState\.release\(\)/);
    }
});

test("the visible widget label is Network while stable identifiers stay wifi", () => {
    const registry = read("Common/PanelRegistryData.js");
    const catalog = require(path.join(shellDir, "Common", "WidgetCatalog.js"));
    assert.equal(catalog.widgetName("wifi"), "Network");
    assert.match(registry, /name: "wifi"[\s\S]*tab: "network"/);
});
