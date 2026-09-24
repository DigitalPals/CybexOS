const test = require("node:test");
const assert = require("node:assert/strict");
const { load } = require("./shell.cjs");

const H = load("ProcHelpers.js");

// ---- error text ----------------------------------------------------------

test("stderr speaks for a command whenever it said anything", () => {
    assert.equal(
        H.commandError("usage-fetch.py", 2, "/usr/bin/python3: can't open file 'x': [Errno 2] No such file or directory\n"),
        "/usr/bin/python3: can't open file 'x': [Errno 2] No such file or directory");
    // A traceback ends with the line that matters.
    assert.equal(
        H.commandError("usage-fetch.py", 1, "Traceback (most recent call last):\n  File \"x\", line 1\nValueError: bad\n"),
        "ValueError: bad");
});

test("a silent failure falls back to the exit code, and NOT_STARTED to the binary", () => {
    assert.equal(H.commandError("ip", 1, ""), "ip exited with status 1");
    assert.equal(H.commandError("ip", 1, "   \n \n"), "ip exited with status 1");
    assert.equal(H.commandError("python3", H.NOT_STARTED, ""), "python3 could not be started");
    // A command that never started still cannot have said anything, but if it
    // somehow did, that is the better message.
    assert.equal(H.commandError("python3", H.NOT_STARTED, "boom\n"), "boom");
});

test("curl exit codes are translated because -sf leaves nothing else to go on", () => {
    assert.equal(H.commandError("curl", 6, "", H.CURL_EXIT), "could not resolve the host");
    assert.equal(H.commandError("curl", 7, "", H.CURL_EXIT), "could not connect to the host");
    assert.equal(H.commandError("curl", 22, "", H.CURL_EXIT), "the server rejected the request");
    assert.equal(H.commandError("curl", 28, "", H.CURL_EXIT), "the request timed out");
    // Unmapped codes still say something specific enough to look up.
    assert.equal(H.commandError("curl", 99, "", H.CURL_EXIT), "curl exited with status 99");
});

test("a runaway error line is clipped rather than handed to a popover whole", () => {
    const long = "x".repeat(400);
    const clipped = H.lastLine(long);
    assert.equal(clipped.length, 160);
    assert.ok(clipped.endsWith("…"));
    assert.equal(H.lastLine("short"), "short");
    assert.equal(H.lastLine(""), "");
    assert.equal(H.lastLine(undefined), "");
    assert.equal(H.lastLine(null), "");
});

// ---- ip -j -4 addr show --------------------------------------------------

// Verbatim `ip -j -4 addr show wlp0s20f3` output from the machine this shell
// runs on; the jq pipeline it replaces read `.[0].addr_info[0].local`.
const IP_JSON = JSON.stringify([{
    ifindex: 2,
    ifname: "wlp0s20f3",
    flags: ["BROADCAST", "MULTICAST", "UP", "LOWER_UP"],
    mtu: 1500,
    operstate: "UP",
    addr_info: [{
        family: "inet",
        local: "192.0.2.216",
        prefixlen: 23,
        broadcast: "192.0.2.255",
        scope: "global",
        dynamic: true,
        label: "wlp0s20f3"
    }]
}]);

test("the connected device's IPv4 address reads exactly as the jq pipeline did", () => {
    assert.equal(H.firstIpv4(IP_JSON), "192.0.2.216");
    assert.equal(H.firstIpv4(IP_JSON + "\n"), "192.0.2.216");
});

test("a device with no address yet, and unusable output, both read as no address", () => {
    assert.equal(H.firstIpv4(JSON.stringify([{ ifname: "wlp0s20f3", addr_info: [] }])), "");
    assert.equal(H.firstIpv4(JSON.stringify([{ ifname: "wlp0s20f3" }])), "");
    assert.equal(H.firstIpv4("[]"), "");
    // `ip` writes its complaint to stderr and nothing at all to stdout.
    assert.equal(H.firstIpv4(""), "");
    assert.equal(H.firstIpv4("Device \"nosuchdev0\" does not exist."), "");
    assert.equal(H.firstIpv4(undefined), "");
    assert.equal(H.firstIpv4("{}"), "");
});

test("only inet entries count as the address", () => {
    const mixed = JSON.stringify([{
        ifname: "wlp0s20f3",
        addr_info: [
            { family: "inet6", local: "fe80::1" },
            { family: "inet", local: "192.0.2.216" }
        ]
    }]);
    assert.equal(H.firstIpv4(mixed), "192.0.2.216");
});

// ---- tailscale status --json ---------------------------------------------

const TS_JSON = JSON.stringify({
    Version: "1.102.1",
    BackendState: "Running",
    Self: { HostName: "xps", TailscaleIPs: ["100.93.129.14"] },
    Peer: {
        "nodekey:aaa": {
            DNSName: "zeta.tail1234.ts.net.",
            HostName: "zeta",
            Online: false,
            TailscaleIPs: ["100.1.1.3"],
            OS: "linux"
        },
        "nodekey:bbb": {
            DNSName: "beast.tail1234.ts.net.",
            HostName: "beast",
            Online: true,
            TailscaleIPs: ["100.1.1.1", "fd7a::1"],
            OS: "linux",
            ExitNodeOption: true
        },
        "nodekey:ccc": {
            HostName: "phone",
            Online: true,
            TailscaleIPs: ["100.1.1.2"],
            OS: "iOS",
            ExitNode: true
        }
    }
});

test("peers come back online-first then alphabetical, named by their short name", () => {
    const peers = H.tailscalePeers(TS_JSON);
    assert.deepEqual(peers.map(p => p.name), ["beast", "phone", "zeta"]);
    assert.deepEqual(peers[0], {
        name: "beast",
        online: true,
        ip: "100.1.1.1",
        os: "linux",
        exitOption: true,
        exit: false
    });
    assert.equal(peers[1].exit, true);
    assert.equal(peers[2].online, false);
});

test("a peer missing every field still renders as a row", () => {
    const peers = H.tailscalePeers(JSON.stringify({ Peer: { "nodekey:x": {} } }));
    assert.deepEqual(peers, [{ name: "?", online: false, ip: "", os: "", exitOption: false, exit: false }]);
});

test("this machine's own status comes out of the same body as the peer list", () => {
    assert.deepEqual(H.tailscaleSelf(TS_JSON), {
        running: true,
        backendState: "Running",
        host: "xps",
        net: "",
        ip: "100.93.129.14",
        exitNode: false
    });
});

test("self status reads MagicDNSSuffix and the exit-node flag", () => {
    const self = H.tailscaleSelf(JSON.stringify({
        BackendState: "Running",
        MagicDNSSuffix: "tail1234.ts.net",
        Self: { HostName: "xps", TailscaleIPs: ["100.0.0.1"] },
        ExitNodeStatus: { Online: true }
    }));
    assert.equal(self.net, "tail1234.ts.net");
    assert.equal(self.exitNode, true);
});

test("a stopped backend is readable status, not unreadable output", () => {
    // The distinction the old bare `catch` collapsed: `tailscale down` must
    // not look like a dead tailscaled.
    const stopped = H.tailscaleSelf(JSON.stringify({ BackendState: "Stopped", Self: {} }));
    assert.equal(stopped.running, false);
    assert.equal(stopped.host, "");
    assert.equal(H.tailscaleSelf("failed to connect to local tailscaled"), null);
    assert.equal(H.tailscaleSelf(""), null);
    assert.equal(H.tailscaleSelf("[]"), null);
    assert.equal(H.tailscaleSelf(JSON.stringify({ Self: [] })), null);
    assert.equal(H.tailscaleSelf(undefined), null);
});

test("an empty tailnet is an empty list; unreadable output is null, never a list", () => {
    // The whole point: "0 of 0 devices online" must only ever mean this.
    assert.deepEqual(H.tailscalePeers(JSON.stringify({ BackendState: "Running" })), []);
    assert.deepEqual(H.tailscalePeers(JSON.stringify({ Peer: {} })), []);
    assert.equal(H.tailscalePeers(""), null);
    assert.equal(H.tailscalePeers("failed to connect to local tailscaled"), null);
    assert.equal(H.tailscalePeers("[]"), null);
    assert.equal(H.tailscalePeers(JSON.stringify({ Peer: [] })), null);
    assert.equal(H.tailscalePeers(undefined), null);
});
