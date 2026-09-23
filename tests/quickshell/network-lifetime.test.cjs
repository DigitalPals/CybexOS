const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { shellDir, load } = require("./shell.cjs");

const H = load("NetworkHelpers.js");

function read(relative) {
    return fs.readFileSync(path.join(shellDir, relative), "utf8");
}

test("a network list key changes with the visible SSIDs and their order only", () => {
    const first = [
        { ssid: "Home", signal: 80, connected: true },
        { ssid: "Office", signal: 40 },
        { ssid: "Cafe", signal: 30 }
    ];
    // A later snapshot: new objects, new signal values, same rows.
    const later = first.map(network => Object.assign({}, network,
        { signal: network.signal + 3 }));
    assert.equal(H.networkListKey(first, 6), H.networkListKey(later, 6));

    const reordered = [first[0], first[2], first[1]];
    assert.notEqual(H.networkListKey(first, 6), H.networkListKey(reordered, 6));
    // Beyond the limit is not part of the visible identity.
    assert.equal(H.networkListKey(first, 2),
        H.networkListKey([first[0], first[1], { ssid: "Elsewhere" }], 2));
    assert.deepEqual(H.networkListIds(H.networkListKey(first, 2)), ["Home", "Office"]);
    assert.deepEqual(H.networkListIds(H.networkListKey(first)), ["Home", "Office", "Cafe"]);
    assert.deepEqual(H.networkListIds(H.networkListKey(null, 6)), []);
    assert.deepEqual(H.networkListIds("not json"), []);
    assert.deepEqual(H.networkListIds("{\"a\":1}"), []);
});

test("a row looks its live entry up by SSID and survives a missing one", () => {
    const list = [{ ssid: "Home", signal: 80, connected: true }];
    assert.equal(H.networkBySsid(list, "Home"), list[0]);
    const missing = H.networkBySsid(list, "Gone");
    assert.equal(missing.ssid, "Gone");
    assert.equal(missing.connected, false);
    assert.equal(missing.signal, -1);
    assert.equal(missing.security, "");
    assert.equal(H.networkBySsid(undefined, "x").ssid, "x");
});

test("the drawer's network rows are keyed by SSID and keep typed credentials", () => {
    const drawer = read("Popovers/Drawer/DrawerNetwork.qml");
    assert.doesNotMatch(drawer, /groupedNetworks\.all\.slice/);
    assert.match(drawer,
        /readonly property string networkKey:\s*NetworkHelpers\.networkListKey\(networks, 6\)/);
    assert.match(drawer, /model:\s*root\.networkSsids/);
    assert.match(drawer,
        /required property string modelData\s*readonly property var network:\s*NetworkHelpers\.networkBySsid\(root\.networks, modelData\)/);
    assert.doesNotMatch(drawer, /netEntry\.modelData\./);
    assert.match(drawer, /property string credentialPassword:\s*""/);
    assert.match(drawer,
        /onTextChanged:\s*\{\s*if \(netEntry\.unfolded\)\s*root\.credentialPassword = text;/);
    assert.match(drawer,
        /Component\.onCompleted:\s*\{[\s\S]{0,240}text = root\.credentialPassword;[\s\S]{0,160}forceActiveFocus\(\);/);
    // The metrics grid is a fixed model; its values are read live.
    assert.match(drawer, /model:\s*\["Ping", "Loss", "Down", "Up"\]/);
    assert.match(drawer, /text:\s*root\.metricValue\(metricCell\.modelData\)/);
});

test("an outgoing popout slot is hidden, not only transparent, after its fade", () => {
    const host = read("Bar/PopoutHost.qml");
    assert.match(host,
        /function slotVisible\(slot, opacity\)\s*\{\s*return frontSlot === slot \|\| opacity > 0\s*\|\| \(requestedName !== "" && nameFor\(slot\) === requestedName\);/);
    const loaders = [...host.matchAll(/Loader \{\s*id: loader([AB])[\s\S]*?onLoaded: host\.slotLoaded\((\d)\)/g)];
    assert.equal(loaders.length, 2);
    for (const [block, , slot] of loaders)
        assert.match(block, new RegExp(`visible: host\\.slotVisible\\(${slot}, opacity\\)`));
});

test("presenting a panel fronts its slot before the card turns visible", () => {
    const host = read("Bar/PopoutHost.qml");
    const present = host.slice(host.indexOf("function presentSlot("),
        host.indexOf("function retargetFront("));
    const fronted = present.indexOf("frontSlot = slot;");
    const faded = present.indexOf("loaderFor(oldSlot).opacity = 0;");
    const presented = present.indexOf("presented = true;");
    assert.ok(fronted > 0 && faded > 0 && presented > 0);
    // After a close frontSlot still names the latched drawer. Raising
    // `presented` first made it visible for one turn, which started and
    // stopped every poller its current tab claims on each unrelated open.
    assert.ok(fronted < presented,
        "the latched slot must stop being front before the card becomes visible");
    assert.ok(faded < presented,
        "the outgoing slot's fade must be requested before the card becomes visible");
    // The close path mirrors it: the card hides before frontSlot moves back.
    assert.match(host,
        /host\.presented = false;[\s\S]*?host\.frontSlot = keep;/);
});

test("scan lists are not re-sorted while no Network view is using them", () => {
    const wifi = read("Common/WifiState.qml");
    assert.match(wifi, /readonly property var others:\s*\{\s*if \(!scanning \|\| !enabled\)\s*return \[\];/);
    const details = read("Common/NetworkDetails.qml");
    assert.match(details,
        /readonly property var fallbackNetworks:\s*\{\s*if \(!root\.acquired \|\| !WifiState\.device \|\| !WifiState\.enabled\)\s*return \[\];/);
});
