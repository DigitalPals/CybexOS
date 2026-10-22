// Pure transformations for the Network panel.  Keep operating-system reads in
// scripts/network-tool.py: these functions are shared by QML and the Node
// fixture suite, and deliberately accept plain objects only.

var PHYSICAL_TYPES = {
    "ethernet": "ethernet",
    "802-3-ethernet": "ethernet",
    "wired": "ethernet",
    "wifi": "wifi",
    "wireless": "wifi",
    "802-11-wireless": "wifi"
};

var DNS_PROVIDERS = {
    Cloudflare: [
        "1.1.1.1", "1.0.0.1",
        "2606:4700:4700::1111", "2606:4700:4700::1001"
    ],
    Google: [
        "8.8.8.8", "8.8.4.4",
        "2001:4860:4860::8888", "2001:4860:4860::8844"
    ]
};

function text(value) {
    return value === undefined || value === null ? "" : String(value);
}

function interfaceName(device) {
    return text(device && (device.interface || device.iface
        || device.device || device.name));
}

function physicalType(device) {
    var type = text(device && (device.type || device.connectionType)).toLowerCase();
    return PHYSICAL_TYPES[type] || "";
}

function isConnected(device) {
    if (!device)
        return false;
    if (device.connected === true)
        return true;
    var state = text(device.state || device.status).toLowerCase();
    return state === "connected" || state === "activated"
        || state.indexOf("100 ") === 0;
}

function routeInterface(route) {
    return text(route && (route.interface || route.iface || route.dev));
}

function isDefaultRoute(route) {
    if (!route)
        return false;
    var destination = text(route.dst || route.destination);
    return destination === "" || destination === "default"
        || destination === "0.0.0.0/0" || destination === "::/0";
}

function metric(route) {
    var value = Number(route && route.metric);
    return Number.isFinite(value) ? value : Number.MAX_SAFE_INTEGER;
}

// Prefer the physical device carrying the cheapest default route.  Tunnel,
// VPN, bridge and container routes never enter the candidates because only a
// device with a physical NetworkManager type can match.  The deterministic
// fallback is wired, then wireless, then interface name.
function selectPrimaryInterface(devices, routes) {
    var physical = (Array.isArray(devices) ? devices : []).filter(function (device) {
        return physicalType(device) !== "" && isConnected(device)
            && interfaceName(device) !== "";
    });
    if (physical.length === 0)
        return null;

    var byInterface = {};
    physical.forEach(function (device) {
        byInterface[interfaceName(device)] = device;
    });
    var candidates = [];
    (Array.isArray(routes) ? routes : []).forEach(function (route) {
        if (!isDefaultRoute(route))
            return;
        var device = byInterface[routeInterface(route)];
        if (device)
            candidates.push({ device: device, metric: metric(route) });
    });

    function compare(a, b) {
        var metricDelta = a.metric - b.metric;
        if (metricDelta !== 0)
            return metricDelta;
        var typeDelta = (physicalType(a.device) === "ethernet" ? 0 : 1)
            - (physicalType(b.device) === "ethernet" ? 0 : 1);
        return typeDelta || interfaceName(a.device).localeCompare(interfaceName(b.device));
    }
    if (candidates.length > 0) {
        candidates.sort(compare);
        return candidates[0].device;
    }

    physical.sort(function (a, b) {
        var typeDelta = (physicalType(a) === "ethernet" ? 0 : 1)
            - (physicalType(b) === "ethernet" ? 0 : 1);
        return typeDelta || interfaceName(a).localeCompare(interfaceName(b));
    });
    return physical[0];
}

function numericCounter(value) {
    if (value === null || value === undefined || value === "")
        return null;
    var number = Number(value);
    return Number.isFinite(number) && number >= 0 ? number : null;
}

// Returns both the displayed rates and the sample that should be retained.
// A counter reset, interface handoff, missing counter, or non-forward clock is
// a baseline sample rather than an enormous manufactured transfer spike.
function calculateRates(previous, current, timestampMs) {
    var iface = interfaceName(current);
    var rx = numericCounter(current && (current.rxBytes !== undefined
        ? current.rxBytes : current.rx_bytes));
    var tx = numericCounter(current && (current.txBytes !== undefined
        ? current.txBytes : current.tx_bytes));
    var now = Number(timestampMs);
    if (!Number.isFinite(now))
        now = Date.now();
    var next = { interface: iface, rxBytes: rx, txBytes: tx, timestamp: now };
    var validPrevious = previous && previous.interface === iface && iface !== ""
        && numericCounter(previous.rxBytes) !== null
        && numericCounter(previous.txBytes) !== null
        && Number.isFinite(Number(previous.timestamp));
    var elapsed = validPrevious ? (now - Number(previous.timestamp)) / 1000 : 0;
    var reset = !validPrevious || rx === null || tx === null || elapsed <= 0
        || rx < Number(previous.rxBytes) || tx < Number(previous.txBytes);
    return {
        download: reset ? 0 : (rx - Number(previous.rxBytes)) / elapsed,
        upload: reset ? 0 : (tx - Number(previous.txBytes)) / elapsed,
        reset: reset,
        next: next
    };
}

function updatePingHistory(history, sample, limit) {
    var next = Array.isArray(history) ? history.slice() : [];
    var value = Number(sample);
    next.push(sample !== null && sample !== undefined
        && Number.isFinite(value) && value >= 0 ? value : null);
    var maximum = Math.max(1, Number(limit) || 24);
    if (next.length > maximum)
        next.splice(0, next.length - maximum);
    return next;
}

function pingStats(history, averageWindow) {
    var samples = Array.isArray(history) ? history : [];
    if (samples.length === 0)
        return { latency: -1, loss: 0, samples: 0 };
    var good = samples.filter(function (sample) {
        return sample !== null && sample !== undefined
            && Number.isFinite(Number(sample)) && Number(sample) >= 0;
    });
    var window = good.slice(-Math.max(1, Number(averageWindow) || 5));
    var total = window.reduce(function (sum, sample) { return sum + Number(sample); }, 0);
    return {
        latency: window.length > 0 ? total / window.length : -1,
        loss: Math.round((samples.length - good.length) * 100 / samples.length),
        samples: samples.length
    };
}

function formatNumber(value, digits) {
    var number = Number(value);
    if (!Number.isFinite(number))
        return "--";
    return number.toFixed(digits).replace(/(\.\d*?[1-9])0+$/, "$1").replace(/\.0+$/, "");
}

function formatBytes(value) {
    if (value === null || value === undefined || value === "")
        return "--";
    var number = Number(value);
    if (!Number.isFinite(number) || number < 0)
        return "--";
    var units = ["B", "KB", "MB", "GB", "TB", "PB"];
    var unit = 0;
    while (number >= 1024 && unit < units.length - 1) {
        number /= 1024;
        unit++;
    }
    var digits = unit === 0 || number >= 100 ? 0 : number >= 10 ? 1 : 2;
    return formatNumber(number, digits) + " " + units[unit];
}

function formatRate(value) {
    var formatted = formatBytes(value);
    return formatted === "--" ? formatted : formatted + "/s";
}

function formatLatency(value) {
    if (value === null || value === undefined || value === "")
        return "--";
    var number = Number(value);
    return Number.isFinite(number) && number >= 0
        ? formatNumber(number, number < 10 ? 1 : 0) + " ms" : "--";
}

function bandForFrequency(frequency) {
    var value = Number(frequency);
    if (!Number.isFinite(value))
        return "";
    if (value >= 2400 && value < 2500)
        return "2.4";
    if (value >= 4900 && value < 5925)
        return "5";
    if (value >= 5925 && value <= 7125)
        return "6";
    return "";
}

function securityText(value) {
    // Quickshell 0.2.1 WifiSecurityType enum order.  Strings remain the
    // canonical test/helper interface, but accepting the enum keeps QML from
    // depending on private numeric constants at every delegate.
    var enumNames = ["WPA3-EAP", "SAE", "WPA2-EAP", "WPA2-PSK",
        "WPA-EAP", "WPA-PSK", "WEP", "WEP-DYNAMIC", "LEAP", "OWE",
        "OPEN", "UNKNOWN"];
    if (typeof value === "number" && value >= 0 && value < enumNames.length)
        return enumNames[value];
    return text(value).trim().toUpperCase();
}

function classifySecurity(value) {
    var raw = securityText(value);
    if (raw === "" || raw === "--" || raw === "NONE" || raw === "OPEN")
        return { kind: "open", label: "Open", password: false,
            identity: false, supported: true, shareable: true, qrType: "nopass" };
    if (raw.indexOf("OWE") !== -1)
        return { kind: "owe", label: "Enhanced Open", password: false,
            identity: false, supported: true, shareable: true, qrType: "nopass" };
    if (raw.indexOf("WEP") !== -1)
        return { kind: "wep", label: "WEP", password: true,
            identity: false, supported: true, shareable: true, qrType: "WEP" };
    if (raw.indexOf("EAP") !== -1 || raw.indexOf("802.1X") !== -1
            || raw.indexOf("ENTERPRISE") !== -1 || raw.indexOf("LEAP") !== -1) {
        var certificate = raw.indexOf("TLS") !== -1
            && raw.indexOf("PEAP") === -1 && raw.indexOf("MSCHAP") === -1;
        return { kind: certificate ? "enterprise-certificate" : "enterprise-peap",
            label: certificate ? "Enterprise certificate" : "Enterprise",
            password: !certificate, identity: !certificate, supported: !certificate,
            shareable: false, qrType: "" };
    }
    if (raw.indexOf("SAE") !== -1 || raw.indexOf("WPA3") !== -1)
        return { kind: "wpa3", label: "WPA3", password: true,
            identity: false, supported: true, shareable: true, qrType: "WPA" };
    if (raw.indexOf("WPA") !== -1 || raw.indexOf("PSK") !== -1)
        return { kind: "wpa", label: raw.indexOf("WPA2") !== -1 ? "WPA2" : "WPA",
            password: true, identity: false, supported: true,
            shareable: true, qrType: "WPA" };
    return { kind: "unsupported", label: "Unsupported security", password: false,
        identity: false, supported: false, shareable: false, qrType: "" };
}

function signalOf(network) {
    var value = Number(network && (network.signal !== undefined
        ? network.signal : network.signalStrength));
    return Number.isFinite(value) ? Math.max(0, Math.min(100, Math.round(value))) : -1;
}

function ssidOf(network) {
    return text(network && (network.ssid !== undefined ? network.ssid : network.name));
}

function networkFrequencies(network) {
    var frequencies = [];
    var values = network && (network.frequencies || network.frequency || network.freq);
    if (!Array.isArray(values))
        values = values === undefined || values === null ? [] : [values];
    values.forEach(function (frequency) {
        var number = Number(frequency);
        if (Number.isFinite(number) && frequencies.indexOf(number) === -1)
            frequencies.push(number);
    });
    return frequencies;
}

function groupWifiNetworks(networks, profiles) {
    var profileList = Array.isArray(profiles) ? profiles : [];
    var bySsid = {};
    profileList.forEach(function (profile) {
        var type = physicalType(profile);
        var ssid = text(profile.ssid || profile.name);
        // The hotspot's own profile is not a network this computer joins.
        if (type === "wifi" && ssid !== "" && !bySsid[ssid] && !sharedProfile(profile))
            bySsid[ssid] = profile;
    });
    var grouped = {};
    (Array.isArray(networks) ? networks : []).forEach(function (network) {
        var ssid = ssidOf(network);
        if (ssid === "")
            return;
        var signal = signalOf(network);
        var current = grouped[ssid];
        if (!current) {
            current = {
                ssid: ssid,
                signal: signal,
                security: network.security,
                known: Boolean(network.known),
                connected: Boolean(network.connected),
                hidden: Boolean(network.hidden),
                profileUuid: text(network.profileUuid || network.uuid),
                profileName: text(network.profileName || network.connection),
                frequencies: [],
                bssids: []
            };
            grouped[ssid] = current;
        }
        current.known = current.known || Boolean(network.known);
        current.connected = current.connected || Boolean(network.connected);
        if (signal > current.signal) {
            current.signal = signal;
            current.security = network.security;
        }
        if (text(network.profileUuid || network.uuid) !== "")
            current.profileUuid = text(network.profileUuid || network.uuid);
        if (text(network.profileName || network.connection) !== "")
            current.profileName = text(network.profileName || network.connection);
        networkFrequencies(network).forEach(function (frequency) {
            if (current.frequencies.indexOf(frequency) === -1)
                current.frequencies.push(frequency);
        });
        var bssid = text(network.bssid);
        if (bssid !== "" && current.bssids.indexOf(bssid) === -1)
            current.bssids.push(bssid);
    });
    Object.keys(grouped).forEach(function (ssid) {
        var network = grouped[ssid];
        var profile = bySsid[ssid];
        if (profile) {
            network.known = true;
            network.profileUuid = network.profileUuid || text(profile.uuid);
            network.profileName = network.profileName || text(profile.name);
            if (profile.security) {
                var eapDetail = Array.isArray(profile.eap) ? profile.eap.join(" ") : "";
                if (profile.certificateEnterprise)
                    eapDetail += " TLS";
                network.profileSecurity = profile.security + (eapDetail ? " " + eapDetail : "");
            }
        }
        network.frequencies.sort(function (a, b) { return a - b; });
        network.bands = network.frequencies.map(bandForFrequency)
            .filter(function (band, index, all) {
                return band !== "" && all.indexOf(band) === index;
            });
        var profileInfo = classifySecurity(network.profileSecurity);
        network.securityInfo = profileInfo.kind === "enterprise-certificate"
            ? profileInfo : classifySecurity(network.security || network.profileSecurity);
    });
    var all = Object.keys(grouped).map(function (ssid) { return grouped[ssid]; });
    all.sort(function (a, b) {
        return Number(b.connected) - Number(a.connected)
            || b.signal - a.signal || a.ssid.localeCompare(b.ssid);
    });
    return {
        all: all,
        known: all.filter(function (network) { return network.known; }),
        other: all.filter(function (network) { return !network.known; })
    };
}

// The identity of a network list as a string: its first `limit` SSIDs in
// order. A view bound to a fresh array per snapshot rebuilds every row (and
// whatever the user is typing in one) on each poll; a string property only
// notifies when this key really changes.
function networkListKey(networks, limit) {
    var list = Array.isArray(networks) ? networks : [];
    var count = limit === undefined
        ? list.length : Math.max(0, Math.floor(Number(limit)) || 0);
    return JSON.stringify(list.slice(0, count).map(ssidOf));
}

// The SSIDs a networkListKey names; malformed keys name none.
function networkListIds(key) {
    try {
        var ids = JSON.parse(key);
        return Array.isArray(ids) ? ids.filter(function (id) {
            return typeof id === "string";
        }) : [];
    } catch (error) {
        return [];
    }
}

// The live entry for one row. A row can briefly outlive its network between
// the list and its key updating, so a missing SSID reads as a bare,
// disconnected, signal-less entry rather than undefined.
function networkBySsid(networks, ssid) {
    var list = Array.isArray(networks) ? networks : [];
    for (var i = 0; i < list.length; i++) {
        if (list[i] && ssidOf(list[i]) === ssid)
            return list[i];
    }
    return {
        ssid: text(ssid), signal: -1, security: "", connected: false,
        known: false, profileUuid: "", missing: true
    };
}

function availableBands(networks, activeSsid) {
    var found = {};
    (Array.isArray(networks) ? networks : []).forEach(function (network) {
        if (ssidOf(network) !== text(activeSsid))
            return;
        networkFrequencies(network).forEach(function (frequency) {
            var band = bandForFrequency(frequency);
            if (band !== "")
                found[band] = true;
        });
    });
    return ["2.4", "5", "6"].filter(function (band) { return found[band]; });
}

function bandState(profile, networks, activeSsid, currentFrequency) {
    var selected = text(profile && (profile.selectedBand || profile.bandChoice));
    var rawBand = text(profile && profile.band).toLowerCase();
    if (selected === "") {
        if (rawBand === "bg")
            selected = "2.4";
        else if (rawBand === "a")
            selected = Number(profile && profile.channel) > 180 ? "6" : "5";
        else
            selected = "auto";
    }
    return {
        selected: selected,
        current: bandForFrequency(currentFrequency),
        available: availableBands(networks, activeSsid),
        automatic: selected === "auto"
    };
}

function isIpv4(value) {
    var parts = text(value).split(".");
    if (parts.length !== 4)
        return false;
    return parts.every(function (part) {
        return /^(0|[1-9]\d{0,2})$/.test(part) && Number(part) <= 255;
    });
}

function isIpv6(value) {
    var address = text(value).toLowerCase();
    if (address === "" || address.indexOf("%") !== -1
            || (address.match(/::/g) || []).length > 1)
        return false;
    var halves = address.split("::");
    if (halves.length > 2)
        return false;
    function words(part) {
        if (part === "")
            return [];
        var out = part.split(":");
        for (var i = 0; i < out.length; i++) {
            if (out[i].indexOf(".") !== -1) {
                if (i !== out.length - 1 || !isIpv4(out[i]))
                    return null;
                out.splice(i, 1, "0", "0");
            } else if (!/^[0-9a-f]{1,4}$/.test(out[i])) {
                return null;
            }
        }
        return out;
    }
    var left = words(halves[0]);
    var right = halves.length === 2 ? words(halves[1]) : [];
    if (left === null || right === null)
        return false;
    var count = left.length + right.length;
    return halves.length === 2 ? count < 8 : count === 8;
}

function validateDnsServers(value) {
    var values = Array.isArray(value) ? value : text(value).split(/[\s,;]+/);
    var servers = [];
    for (var i = 0; i < values.length; i++) {
        var server = text(values[i]).trim().toLowerCase();
        if (server === "")
            continue;
        if (!isIpv4(server) && !isIpv6(server))
            return { valid: false, servers: [], error: server + " is not a literal IP address" };
        if (servers.indexOf(server) === -1)
            servers.push(server);
        if (servers.length > 4)
            return { valid: false, servers: [], error: "Enter at most four DNS servers" };
    }
    if (servers.length === 0)
        return { valid: false, servers: [], error: "Enter at least one DNS server" };
    return { valid: true, servers: servers, error: "" };
}

function dnsValues(value) {
    if (Array.isArray(value))
        return value.map(function (item) { return text(item).toLowerCase(); })
            .filter(function (item) { return item !== ""; });
    return text(value).split(/[\s,;]+/).map(function (item) { return item.toLowerCase(); })
        .filter(function (item) { return item !== ""; });
}

function sameSet(a, b) {
    var left = a.slice().sort();
    var right = b.slice().sort();
    return left.length === right.length && left.every(function (value, index) {
        return value === right[index];
    });
}

function boolValue(value) {
    return value === true || text(value).toLowerCase() === "yes"
        || text(value).toLowerCase() === "true" || Number(value) === 1;
}

// A profile that shares this computer's connection (the hotspot) serves its
// clients' DNS itself, so the DNS presets leave it alone, as the helper does.
function sharedProfile(profile) {
    return text(profile && profile.ipv4Method).toLowerCase() === "shared";
}

function standalonePhysicalProfile(profile) {
    return physicalType(profile) !== "" && text(profile.master || profile.controller) === ""
        && text(profile.slaveType || profile.portType) === ""
        && profile.standalone !== false && !sharedProfile(profile);
}

function profileDnsState(profile) {
    var servers = dnsValues(profile.ipv4Dns || profile.ipv4_dns)
        .concat(dnsValues(profile.ipv6Dns || profile.ipv6_dns));
    var ignores = boolValue(profile.ipv4IgnoreAutoDns || profile.ipv4_ignore_auto_dns)
        && boolValue(profile.ipv6IgnoreAutoDns || profile.ipv6_ignore_auto_dns);
    if (servers.length === 0 && !boolValue(profile.ipv4IgnoreAutoDns
            || profile.ipv4_ignore_auto_dns) && !boolValue(profile.ipv6IgnoreAutoDns
            || profile.ipv6_ignore_auto_dns))
        return { provider: "Automatic", servers: [] };
    if (ignores && sameSet(servers, DNS_PROVIDERS.Cloudflare))
        return { provider: "Cloudflare", servers: DNS_PROVIDERS.Cloudflare.slice() };
    if (ignores && sameSet(servers, DNS_PROVIDERS.Google))
        return { provider: "Google", servers: DNS_PROVIDERS.Google.slice() };
    return { provider: "Custom", servers: servers };
}

function dnsState(profiles) {
    var targets = (Array.isArray(profiles) ? profiles : []).filter(standalonePhysicalProfile);
    if (targets.length === 0)
        return { provider: "Automatic", label: "Automatic", servers: [], mixed: false,
            profiles: [] };
    var states = targets.map(profileDnsState);
    var signature = function (state) {
        return state.provider + ":" + state.servers.slice().sort().join(",");
    };
    var first = signature(states[0]);
    var mixed = states.some(function (state) { return signature(state) !== first; });
    return {
        provider: mixed ? "Mixed" : states[0].provider,
        label: mixed ? "Mixed" : states[0].provider,
        servers: mixed ? [] : states[0].servers.slice(),
        mixed: mixed,
        profiles: targets
    };
}

// ---- VPN and hotspot ------------------------------------------------------
// `vpns` entries come from network-tool.py: {uuid, name, type, kind, label,
// state, active, timestamp}, state being NetworkManager's activation state
// ("activated", "activating", "deactivating" or "").

function isVpnActive(vpn) {
    var state = text(vpn && vpn.state);
    return state === "activated" || state === "activating";
}

// The one VPN the drawer's compact row offers: a connected or connecting one,
// else the most recently used, else the first by name.
function preferredVpn(vpns) {
    var list = (Array.isArray(vpns) ? vpns : []).filter(function (vpn) {
        return vpn && text(vpn.uuid) !== "";
    });
    if (list.length === 0)
        return null;
    function rank(vpn) {
        var state = text(vpn.state);
        return state === "activated" ? 0 : state === "activating" ? 1 : 2;
    }
    return list.slice().sort(function (a, b) {
        return rank(a) - rank(b)
            || (Number(b.timestamp) || 0) - (Number(a.timestamp) || 0)
            || text(a.name).localeCompare(text(b.name));
    })[0];
}

// What a VPN row says about its state; `pending` names a request running for
// it ("connect" or "disconnect"), which wins over the last snapshot.
function vpnStateText(vpn, pending) {
    if (pending === "connect")
        return "Connecting…";
    if (pending === "disconnect")
        return "Disconnecting…";
    var state = text(vpn && vpn.state);
    return state === "activated" ? "Connected"
        : state === "activating" ? "Connecting…"
        : state === "deactivating" ? "Disconnecting…" : "Off";
}

function vpnLabel(vpn) {
    var label = text(vpn && vpn.label);
    return label !== "" ? label : text(vpn && vpn.type) === "wireguard" ? "WireGuard" : "VPN";
}

// Why `name` cannot be a Wi-Fi network name, or "": an SSID is at most 32
// bytes, which is fewer characters outside ASCII.
function utf8Length(value) {
    var length = 0;
    for (var i = 0; i < value.length; i++) {
        var unit = value.charCodeAt(i);
        if (unit < 0x80)
            length += 1;
        else if (unit < 0x800)
            length += 2;
        else if (unit >= 0xd800 && unit <= 0xdbff && i + 1 < value.length) {
            length += 4;
            i++;
        } else
            length += 3;
    }
    return length;
}

function ssidProblem(name) {
    var value = text(name);
    if (/[\u0000-\u001f\u007f]/.test(value))
        return "Use letters, digits, spaces and punctuation";
    return utf8Length(value) > 32 ? "Use at most 32 bytes (about 32 letters)" : "";
}

// The Hotspot group's copy from network-tool.py's hotspot status: whether the
// switch can be used and why not, the line under it, and the warning that
// starting it drops this adapter's Wi-Fi connection. NetworkManager runs one
// connection per adapter, so an adapter cannot join a network and host one
// at the same time.
function hotspotView(status) {
    var value = status || {};
    var hosting = text(value.state) === "activated" || text(value.state) === "activating";
    var view = { visible: value.available === true, disabledReason: "", description: "", warning: "" };
    if (!view.visible)
        return view;
    if (value.supported !== true)
        view.disabledReason = "This Wi-Fi adapter cannot host a hotspot";
    else if (value.radioOff === true && !hosting)
        view.disabledReason = "Turn on Wi-Fi to use the hotspot";
    view.description = text(value.state) === "activated"
        ? "Devices can join " + text(value.ssid) + " to share this computer's connection"
        : text(value.state) === "activating" ? "Starting…"
        : "Share this computer's connection over Wi-Fi";
    if (!hosting && value.dropsWifi === true && view.disabledReason === "")
        view.warning = "This adapter cannot join Wi-Fi and host a hotspot at once, so "
            + (text(value.wifiConnection) || "the current Wi-Fi network")
            + " disconnects while the hotspot is on. Devices share your other connection, such as Ethernet.";
    return view;
}

var exported = {
    PHYSICAL_TYPES: PHYSICAL_TYPES,
    DNS_PROVIDERS: DNS_PROVIDERS,
    physicalType: physicalType,
    interfaceName: interfaceName,
    selectPrimaryInterface: selectPrimaryInterface,
    calculateRates: calculateRates,
    updatePingHistory: updatePingHistory,
    pingStats: pingStats,
    formatBytes: formatBytes,
    formatRate: formatRate,
    formatLatency: formatLatency,
    bandForFrequency: bandForFrequency,
    classifySecurity: classifySecurity,
    groupWifiNetworks: groupWifiNetworks,
    networkListKey: networkListKey,
    networkListIds: networkListIds,
    networkBySsid: networkBySsid,
    availableBands: availableBands,
    bandState: bandState,
    isIpv4: isIpv4,
    isIpv6: isIpv6,
    validateDnsServers: validateDnsServers,
    standalonePhysicalProfile: standalonePhysicalProfile,
    sharedProfile: sharedProfile,
    profileDnsState: profileDnsState,
    dnsState: dnsState,
    isVpnActive: isVpnActive,
    preferredVpn: preferredVpn,
    vpnStateText: vpnStateText,
    vpnLabel: vpnLabel,
    ssidProblem: ssidProblem,
    hotspotView: hotspotView
};

if (typeof module !== "undefined" && module.exports)
    module.exports = exported;
