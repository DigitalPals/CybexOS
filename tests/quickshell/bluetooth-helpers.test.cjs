const test = require("node:test");
const assert = require("node:assert/strict");
const { load } = require("./shell.cjs");
const H = load("BluetoothHelpers.js");

test("discovery excludes empty names and address/UUID/hex identifiers", () => {
    for (const name of ["", "  ", "AA:BB:CC:DD:EE:FF", "aa-bb-cc-dd-ee-ff",
        "  0000180F-0000-1000-8000-00805F9B34FB  ",
        "123456789abcdef0123456789abcdef0", "0x180F", "0XDEADBEEF"]) {
        assert.equal(H.hasHumanName({ deviceName: name }), false, name);
    }
    for (const name of ["Headphones", "MX Master 3", "E1GE01465", "AM450X NERA"])
        assert.equal(H.hasHumanName({ deviceName: name }), true, name);
    assert.equal(H.hasHumanName(null), false);
});

test("display, filtering and sorting share trimmed names with an alias fallback", () => {
    const devices = [{ deviceName: "", name: "  Zebra  " },
        { deviceName: " Alpha ", name: "Other" }, { deviceName: " ", name: "Beta" }];
    assert.deepEqual(H.groupDevices(devices).nearby.map(H.deviceLabel), ["Alpha", "Beta", "Zebra"]);
    assert.equal(devices[0].name, "  Zebra  ", "grouping must not mutate device data");
    assert.equal(H.deviceLabel(null), "");
});

test("unnamed paired and connected devices remain available, without duplicates", () => {
    const paired = { deviceName: "", paired: true };
    const connected = { deviceName: "AA:BB:CC:DD:EE:FF", paired: true, connected: true };
    const nearby = { deviceName: "Keyboard" };
    assert.deepEqual(H.groupDevices([null, { deviceName: "" }, paired, connected, nearby]), {
        connected: [connected], paired: [paired], nearby: [nearby]
    });
    nearby.deviceName = "";
    assert.deepEqual(H.groupDevices([nearby]).nearby, []);
    nearby.deviceName = "Keyboard";
    assert.deepEqual(H.groupDevices([nearby]).nearby, [nearby]);
});
