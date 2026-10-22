// Pure helpers for the terse multiline output produced by:
//
//   nmcli -t -m multiline -f \
//     GENERAL.DEVICE,GENERAL.TYPE,GENERAL.CONNECTION,GENERAL.STATE,IP4.ADDRESS \
//     device show
//
// Keeping parsing out of the singleton makes the important distinction
// testable: [] is a successful read with no Ethernet devices, while null is
// output that cannot safely replace the last snapshot.

var DEVICE_STATE = {
    Unknown: 0,
    Unmanaged: 10,
    Unavailable: 20,
    Disconnected: 30,
    Prepare: 40,
    Config: 50,
    NeedAuth: 60,
    IpConfig: 70,
    IpCheck: 80,
    Secondaries: 90,
    Activated: 100,
    Deactivating: 110,
    Failed: 120
};

function stateStatus(code) {
    switch (code) {
    case DEVICE_STATE.Unmanaged: return "Unmanaged";
    case DEVICE_STATE.Unavailable: return "Unavailable";
    case DEVICE_STATE.Disconnected: return "Disconnected";
    case DEVICE_STATE.Prepare: return "Connecting";
    case DEVICE_STATE.Config: return "Configuring";
    case DEVICE_STATE.NeedAuth: return "Authentication required";
    case DEVICE_STATE.IpConfig: return "Obtaining address";
    case DEVICE_STATE.IpCheck: return "Checking connection";
    case DEVICE_STATE.Secondaries: return "Finishing connection";
    case DEVICE_STATE.Activated: return "Connected";
    case DEVICE_STATE.Deactivating: return "Disconnecting";
    case DEVICE_STATE.Failed: return "Failed";
    default: return "Unknown";
    }
}

// Terse nmcli escapes the field separator and backslash as \: and \\.
// Treat a dangling escape as malformed rather than silently changing a
// profile or interface name.
function unescapeValue(value) {
    var out = "";
    var escaped = false;
    for (var i = 0; i < value.length; i++) {
        var ch = value[i];
        if (escaped) {
            out += ch;
            escaped = false;
        } else if (ch === "\\") {
            escaped = true;
        } else {
            out += ch;
        }
    }
    return escaped ? null : out;
}

function fieldLine(line) {
    var escaped = false;
    for (var i = 0; i < line.length; i++) {
        var ch = line[i];
        if (escaped) {
            escaped = false;
        } else if (ch === "\\") {
            escaped = true;
        } else if (ch === ":") {
            var key = unescapeValue(line.slice(0, i));
            var value = unescapeValue(line.slice(i + 1));
            return key === null || value === null || key === ""
                ? null : { key: key, value: value };
        }
    }
    return null;
}

function firstIpv4(values) {
    for (var i = 0; i < values.length; i++) {
        var value = values[i].trim();
        if (value === "")
            continue;
        var address = value.split("/")[0];
        if (/^(?:\d{1,3}\.){3}\d{1,3}$/.test(address))
            return address;
    }
    return "";
}

function parseState(value) {
    var match = value.match(/^(\d+)(?:\s+\(.*\))?$/);
    if (!match)
        return null;
    var code = Number(match[1]);
    return Number.isInteger(code) ? code : null;
}

function parseDevices(text) {
    if (typeof text !== "string")
        return null;
    if (text.trim() === "")
        return [];

    var records = [];
    var current = null;

    function finishCurrent() {
        if (current !== null) {
            records.push(current);
            current = null;
        }
    }

    var lines = text.replace(/\r\n/g, "\n").split("\n");
    for (var i = 0; i < lines.length; i++) {
        var line = lines[i];
        if (line === "") {
            finishCurrent();
            continue;
        }
        var field = fieldLine(line);
        if (field === null)
            return null;
        if (field.key === "GENERAL.DEVICE") {
            finishCurrent();
            current = { device: field.value, type: null, connection: null,
                stateCode: null, addresses: [] };
            continue;
        }
        if (current === null)
            return null;
        if (field.key === "GENERAL.TYPE")
            current.type = field.value;
        else if (field.key === "GENERAL.CONNECTION")
            current.connection = field.value;
        else if (field.key === "GENERAL.STATE")
            current.stateCode = parseState(field.value);
        else if (/^IP4\.ADDRESS\[\d+\]$/.test(field.key))
            current.addresses.push(field.value);
        else
            return null;
    }
    finishCurrent();

    var devices = [];
    for (var j = 0; j < records.length; j++) {
        var record = records[j];
        if (record.device === "" || record.type === null
                || record.connection === null || record.stateCode === null)
            return null;
        // NetworkManager reports bridges, tunnels, loopback and Wi-Fi P2P as
        // their own types. Only the actual Ethernet type belongs in this view.
        if (record.type !== "ethernet")
            continue;
        var connected = record.stateCode === DEVICE_STATE.Activated;
        devices.push({
            device: record.device,
            connection: record.connection === "--" ? "" : record.connection,
            stateCode: record.stateCode,
            status: stateStatus(record.stateCode),
            connected: connected,
            ipv4: firstIpv4(record.addresses)
        });
    }

    devices.sort(function (a, b) {
        return (Number(b.connected) - Number(a.connected))
            || a.device.localeCompare(b.device);
    });
    return devices;
}

var exported = {
    DEVICE_STATE: DEVICE_STATE,
    stateStatus: stateStatus,
    parseDevices: parseDevices
};

if (typeof module !== "undefined" && module.exports)
    module.exports = exported;
