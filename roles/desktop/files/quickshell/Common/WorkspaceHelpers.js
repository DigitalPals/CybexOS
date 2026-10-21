// Snapshot presentation only. Physical identity, ID allocation, layouts and
// hidden-window ownership belong to workspaces.lua; never infer ID blocks here.
function regularId(value) {
    return typeof value === "number" && Number.isInteger(value)
        && value > 0 && value < 2147483647;
}

function addressKey(value) {
    var text = String(value || "").replace(/^0x/i, "");
    return /^[0-9a-fA-F]{1,16}$/.test(text) ? text.toLowerCase() : "";
}

function layout(value) {
    return ["dwindle", "scrolling", "floating"].indexOf(value) !== -1 ? value
        : value ? "unmanaged" : "dwindle";
}

function nativeLayout(value, fallback) {
    return String(value || fallback || "").slice(0, 256);
}

function layoutIcon(value) {
    return value === "floating" ? "window" : value === "scrolling" ? "chevron_right"
        : value === "dwindle" ? "view_quilt" : "settings";
}

// hyprctl eval may exit zero for a Lua error. Hyprland's acknowledgement is
// exactly "ok"; receiving arbitrary output is not evidence an edit applied.
function commandSucceeded(exitCode, exitStatus, stdout) {
    return exitCode === 0 && exitStatus === 0 && String(stdout || "").trim() === "ok";
}

function parseSnapshot(text) {
    if (typeof text !== "string" || text.length > 1048576)
        return null;
    try {
        var value = JSON.parse(text);
        if (!value || value.v !== 1 || ["shared", "per-monitor"].indexOf(value.mode) === -1
                || !Array.isArray(value.monitors) || value.monitors.length > 32
                || !Array.isArray(value.workspaces) || value.workspaces.length > 2048
                || !Array.isArray(value.minimized) || value.minimized.length > 4096)
            return null;
        var ids = {};
        var workspaces = value.workspaces.map(function(row) {
            if (!row || !regularId(row.id) || ids[row.id]
                    || typeof row.monitor !== "string" || row.monitor.length > 256)
                throw new Error("invalid workspace");
            ids[row.id] = true;
            return {
                id: row.id,
                kind: "numbered", workspaceName: String(row.id),
                localNumber: row.localNumber === 0 || regularId(row.localNumber) ? row.localNumber : row.id,
                monitor: row.monitor,
                label: String(row.label || row.localNumber || row.id).slice(0, 256),
                layout: layout(row.layout),
                layoutManaged: row.layoutManaged !== false,
                nativeLayout: nativeLayout(row.nativeLayout, row.layout),
                guest: row.guest === true,
                ownerIdentity: String(row.ownerIdentity || "").slice(0, 512)
            };
        });
        var names = {};
        var monitors = value.monitors.map(function(row) {
            if (!row || typeof row.name !== "string" || !row.name || row.name.length > 256
                    || names[row.name] || !Array.isArray(row.workspaces)
                    || row.workspaces.some(function(id) { return !regularId(id) || !ids[id]; }))
                throw new Error("invalid monitor");
            names[row.name] = true;
            return {
                name: row.name, identity: String(row.identity || "").slice(0, 512),
                label: String(row.label || row.name).slice(0, 256),
                activeWorkspace: regularId(row.activeWorkspace) ? row.activeWorkspace : -1,
                workspaces: row.workspaces.slice()
            };
        });
        var minimized = value.minimized.map(function(row) {
            var address = row && addressKey(row.address);
            if (!address || !regularId(row.workspace))
                throw new Error("invalid minimized window");
            return { address: address, workspace: row.workspace,
                monitor: String(row.monitor || "").slice(0, 256) };
        });
        return {
            v: 1, mode: value.mode, defaultLayout: layout(value.defaultLayout),
            defaultLayoutManaged: value.defaultLayoutManaged !== false,
            nativeDefaultLayout: nativeLayout(value.nativeDefaultLayout, value.defaultLayout),
            titlebarsEnabled: value.titlebarsEnabled !== false,
            monitors: monitors, workspaces: workspaces, minimized: minimized,
            capabilities: { scrolling: !!(value.capabilities && value.capabilities.scrolling === true),
                titlebars: !!(value.capabilities && value.capabilities.titlebars === true) },
            error: typeof value.error === "string" ? value.error.slice(0, 2048) : ""
        };
    } catch (error) {
        return null;
    }
}

function monitor(snapshot, name) {
    return snapshot ? snapshot.monitors.find(function(row) { return row.name === name; }) || null : null;
}

function workspace(snapshot, id) {
    return snapshot ? snapshot.workspaces.find(function(row) { return row.id === id; }) || null : null;
}

function minimizedWindow(snapshot, address) {
    var key = addressKey(address);
    return snapshot && key ? snapshot.minimized.find(function(row) { return row.address === key; }) || null : null;
}

function occupied(workspace) {
    var windows = workspace && workspace.toplevels ? workspace.toplevels.values : null;
    return numbered(workspace)
        && (!windows || windows.length > 0);
}

function numbered(workspace) {
    if (!workspace || !regularId(workspace.id) || workspace.kind === "named" || workspace.kind === "special")
        return false;
    var name = String(workspace.workspaceName !== undefined ? workspace.workspaceName : workspace.name || "");
    return !/^special(?::|$)/.test(name) && (workspace.kind === "numbered" || name === "" || name === String(workspace.id));
}

// Use only the compositor's rows for Per-monitor mode, including guest IDs.
// The shared fallback intentionally retains the pre-existing numbered strip.
function barEntries(snapshot, name, live, minSlots, hideEmpty, activeId) {
    var values = Array.prototype.slice.call(live || []);
    var liveIds = values.filter(occupied).map(function(row) { return row.id; });
    if (snapshot)
        snapshot.minimized.forEach(function(row) {
            if (liveIds.indexOf(row.workspace) === -1)
                liveIds.push(row.workspace);
        });
    var target = monitor(snapshot, name);
    if (snapshot && snapshot.mode === "per-monitor" && target) {
        return target.workspaces.map(function(id) { return workspace(snapshot, id); })
            .filter(function(row) {
                var native = row && values.find(function(value) { return value.id === row.id; });
                return row && (!native || numbered(native)) && (row.id === activeId || liveIds.indexOf(row.id) !== -1
                    || (!hideEmpty && (!row.guest && row.localNumber <= Math.max(1, minSlots))));
            });
    }
    var ids = values.filter(numbered).map(function(row) { return row.id; });
    var nativeActive = values.find(function(row) { return row.id === activeId; });
    var regularActive = regularId(activeId) && (!nativeActive || numbered(nativeActive)) ? activeId : 0;
    var count = Math.min(10000, Math.max(Number(minSlots) || 1, regularActive,
        ids.length ? Math.max.apply(null, ids) : 0));
    var rows = [];
    for (var id = 1; id <= count; id++) {
        var native = values.find(function(row) { return row.id === id; });
        if (native && !numbered(native))
            continue;
        if (!hideEmpty || liveIds.indexOf(id) !== -1 || id === activeId)
            rows.push(workspace(snapshot, id) || { id: id, localNumber: id,
                kind: "numbered", workspaceName: String(id),
                label: String(id), monitor: name, layout: "dwindle", guest: false });
    }
    ids.concat(regularActive > 0 ? [regularActive] : []).forEach(function(id) {
        if (id > count && !rows.some(function(row) { return row.id === id; }))
            rows.push(workspace(snapshot, id) || { id: id, localNumber: id,
                kind: "numbered", workspaceName: String(id),
                label: String(id), monitor: name, layout: "dwindle", guest: false });
    });
    return rows;
}

function decorateOverview(entries, snapshot, targetMonitor) {
    if (!snapshot)
        return entries;
    return entries.map(function(entry) {
        if (entry.isNew)
            return Object.assign({}, entry, { id: 0, monitor: targetMonitor });
        var row = numbered(entry) ? workspace(snapshot, entry.id) : null;
        return row ? Object.assign({}, entry, { name: row.label, label: row.label,
            localNumber: row.localNumber, monitor: row.monitor, layout: row.layout,
            nativeLayout: row.nativeLayout, layoutManaged: row.layoutManaged, guest: row.guest }) : entry;
    });
}

var exported = { regularId: regularId, addressKey: addressKey, layout: layout, layoutIcon: layoutIcon,
    numbered: numbered,
    commandSucceeded: commandSucceeded,
    parseSnapshot: parseSnapshot, monitor: monitor, workspace: workspace,
    minimizedWindow: minimizedWindow, barEntries: barEntries, decorateOverview: decorateOverview };
if (typeof module !== "undefined" && module.exports)
    module.exports = exported;
