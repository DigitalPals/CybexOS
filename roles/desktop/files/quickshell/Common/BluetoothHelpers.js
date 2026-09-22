// Pure presentation helpers: discovery should offer recognizable device names,
// while a missing name must never hide a paired or connected device.
function deviceLabel(device) {
    if (!device) return "";
    return String(device.deviceName || "").trim() || String(device.name || "").trim();
}

function hasHumanName(device) {
    var label = deviceLabel(device);
    return label !== ""
        && !/^(?:[0-9a-f]{2}[:-]){5}[0-9a-f]{2}$/i.test(label)
        && !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(label)
        && !/^[0-9a-f]{32}$/i.test(label)
        && !/^0x[0-9a-f]{4,32}$/i.test(label);
}

function groupDevices(devices) {
    var groups = { connected: [], paired: [], nearby: [] };
    for (var i = 0; i < devices.length; i++) {
        var device = devices[i];
        if (!device) continue;
        if (device.connected) groups.connected.push(device);
        else if (device.paired) groups.paired.push(device);
        else if (hasHumanName(device)) groups.nearby.push(device);
    }
    Object.keys(groups).forEach(function(key) {
        groups[key].sort(function(a, b) {
            return deviceLabel(a).localeCompare(deviceLabel(b));
        });
    });
    return groups;
}

if (typeof module !== "undefined") {
    module.exports = { deviceLabel: deviceLabel, hasHumanName: hasHumanName,
        groupDevices: groupDevices };
}
