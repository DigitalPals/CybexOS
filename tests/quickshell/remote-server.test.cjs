const test = require("node:test");
const assert = require("node:assert/strict");
const H = require("../../roles/desktop/files/quickshell/Common/RemoteServerHelpers.js");
const S = require("../../roles/desktop/files/quickshell/Common/SettingsHelpers.js");

function sample() {
    return { version: 1, boot: "a", uptime: 1200, cpu: 25, perCore: [20, 30], load: [1, 2, 3],
        meta: { hostname: "beast", os: "Linux", defaultInterface: "eth0" },
        memory: { total: 16 * 1024 ** 3, available: 12 * 1024 ** 3, used: 4 * 1024 ** 3 },
        storage: [{ mount: "/", total: 1000, free: 400, percent: 60 }],
        temperatures: [{ name: "CPU", celsius: 54 }],
        network: [{ name: "eth0", addresses: ["10.10.0.7"], rx: 1024, tx: 2048 },
            { name: "docker0", addresses: ["172.17.0.1"], rx: 999999, tx: 999999 }] };
}
test("remote widget migrates as disabled and preserves user options", () => {
    const old = S.defaults();
    old.mods.right = old.mods.right.filter(m => m.id !== "remote");
    delete old.modOpts.remote;
    const migrated = S.merge(old);
    assert.equal(migrated.mods.right.find(m => m.id === "remote").on, false);
    assert.equal(migrated.modOpts.remote.host, "");
    assert.equal(migrated.modOpts.remote.metric, "cpu");
    const normalized = S.normalizeModOpts({ remote: { host: " john@10.10.0.7 ", label: "The Beast",
        metric: "diskFree", mount: "/data", interface: "eth0", pollSecs: 999 } }).remote;
    assert.equal(normalized.host, "john@10.10.0.7");
    assert.equal(normalized.metric, "diskFree");
    assert.equal(normalized.mount, "/data");
    assert.equal(normalized.pollSecs, 60);
    assert.equal(S.normalizeModOpts({ remote: { metric: "bogus" } }).remote.metric, "cpu");
});
test("every menu metric produces the intended unit and missing readings stay unknown", () => {
    const s = sample();
    const options = { mount: "/", interface: "eth0" };
    const expected = { cpu: "25%", load: "1.00", memory: "25%", memoryUsed: "4.0 GiB",
        memoryFree: "12.0 GiB", disk: "60%", diskFree: "400 B", rx: "↓ 1.0 KiB/s",
        tx: "↑ 2.0 KiB/s", temperature: "54°C" };
    for (const { value } of H.METRICS) {
        assert.equal(H.metric(s, { ...options, metric: value }), expected[value]);
        assert.equal(H.metric(null, { ...options, metric: value }), "—");
    }
    assert.equal(H.metric(s, { metric: "disk", mount: "/missing" }), "—");
    assert.equal(H.metric({ ...s, cpu: null }, { metric: "cpu" }), "—");
    assert.equal(H.temperature({ ...s, temperatures: [] }), null);
});
test("network automatic uses the default route and explicit missing interfaces stay missing", () => {
    const s = sample();
    assert.equal(H.network(s, "").name, "eth0");
    assert.equal(H.network(s, "docker0").name, "docker0");
    assert.equal(H.network(s, "missing"), null);
    delete s.meta.defaultInterface;
    assert.equal(H.network(s, "").name, "docker0");
});
test("malformed data is rejected while unavailable first-sample counters are valid", () => {
    const s = sample();
    assert.equal(H.validSample(s), true);
    s.cpu = null; s.perCore = [null]; s.network[0].rx = null;
    assert.equal(H.validSample(s), true);
    for (const value of [null, {}, { ...s, version: 2 }, { ...s, cpu: Infinity },
        { ...s, network: [{}] }, { ...s, storage: [{}] }, { ...s, load: [] }])
        assert.equal(H.validSample(value), false);
});
test("history is bounded and reboot or long disconnection starts a new series", () => {
    const s = sample();
    let history = [];
    for (let at = 0; at <= 700000; at += 2000) history = H.historyAppend(history, s, at);
    assert.equal(history.length, 300);
    assert.ok(history.every(p => 700000 - p.at < 600000));
    assert.equal(H.historyAppend(history, { ...s, boot: "b" }, 702000).length, 1);
    assert.equal(H.historyAppend(history, s, 900000).length, 1);
    assert.equal(history[0].network[0].name, "eth0");
});
