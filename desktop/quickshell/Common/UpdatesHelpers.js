// Shared update capabilities and presentation; no Qt APIs, so behavior is testable.
function active(state) {
    return ["discovering", "building", "validating", "activating", "recovering"].includes(state);
}

function pending(request) {
    return ["queued", "running", "unknown"].includes((request || {}).state);
}

function validSources(value) {
    const states = ["available", "current", "unpublished", "unavailable", "unreachable", "unknown"];
    return value && typeof value === "object" && ["upstream", "cybexos"].every(name =>
        value[name] && states.includes(value[name].state)
        && (value[name].state !== "available" || (typeof value[name].available === "string"
            && value[name].available.trim() !== "")));
}

function validDeployment(value) {
    const states = ["idle", "unavailable", "discovering", "building", "validating", "ready", "stale",
        "activating", "awaiting-boot", "awaiting-login", "done", "recovering", "failed",
        "interrupted", "rolled-back", "recovery-failed"];
    return value && states.includes(value.state) && (value.state !== "ready"
        || (/^[a-f0-9]{32}$/.test(value.transaction || "")
            && /^[a-f0-9]{64}$/.test(value.reviewToken || "")
            && Array.isArray(value.packageChanges) && typeof value.changes === "string"));
}

function scope(sources, selected) {
    const upstream = selected.includes("upstream") && sources.upstream.state === "available";
    const vendor = selected.includes("cybexos") && sources.cybexos.state === "available";
    return upstream && vendor ? "both" : upstream ? "upstream" : vendor ? "cybexos" : "";
}

function scopeLabel(value) {
    return value === "both" ? "NixOS packages and Cybex OS"
        : value === "upstream" ? "NixOS packages" : value === "cybexos" ? "Cybex OS"
        : "Your system configuration";
}

function capabilities(deployment, busy, available, selectedScope) {
    const state = deployment.state || "idle";
    const blocked = busy || active(state) || !available;
    const waiting = ["awaiting-boot", "awaiting-login", "recovery-failed"].includes(state);
    return {
        prepare: !blocked && !waiting && state !== "ready" && selectedScope !== "",
        apply: !blocked && state === "ready" && !!deployment.transaction && !!deployment.reviewToken,
        confirm: !blocked && state === "awaiting-login",
        rollback: !blocked && waiting && !!deployment.transaction,
        // A finished failure is dismissed the same way; files and logs stay.
        discard: !blocked && ["ready", "stale", "failed", "interrupted", "rolled-back"].includes(state)
            && !!deployment.transaction
    };
}

function overviewVisible(hasUpdates, deployment, error) {
    return hasUpdates || active(deployment.state) || pending(deployment.request)
        || ["ready", "stale", "awaiting-boot", "awaiting-login", "recovery-failed", "failed", "interrupted"].includes(deployment.state)
        || error !== "";
}

function indicator(hasUpdates, state) {
    return hasUpdates && !["activating", "awaiting-boot", "awaiting-login", "recovering", "recovery-failed"].includes(state);
}

// ---- Software Update app ---------------------------------------------------

// Components people recognise, keyed as /etc/cybexos/components.json names
// them. Labels are English catalog keys; views translate them.
var COMPONENTS = {
    cybexos: { label: "Cybex OS", detail: "Desktop, settings and system tools", glyph: "layout-dashboard" },
    nixos: { label: "NixOS", detail: "The base system, its services and libraries", glyph: "package-export" },
    kernel: { label: "Linux kernel", detail: "Core of the system and hardware support", glyph: "cpu" },
    graphics: { label: "Graphics drivers", detail: "Mesa drivers for Intel and AMD graphics", glyph: "device-desktop" },
    nvidia: { label: "NVIDIA driver", detail: "Driver for NVIDIA graphics", glyph: "device-desktop" },
    firmware: { label: "Device firmware files", detail: "Wi-Fi, Bluetooth and graphics firmware loaded by Linux", glyph: "devices" },
    hyprland: { label: "Window manager", detail: "Hyprland draws and arranges your windows", glyph: "layout-grid" }
};

function component(id) {
    return COMPONENTS[id] || { label: String(id || ""), detail: "", glyph: "package-export" };
}

// The one page the app shows. Worker state wins over discovery: a running,
// prepared or restarting change is shown even when sources are unknown.
function page(m) {
    const state = m.state || "idle";
    const request = m.request || {};
    if (!m.statusLoaded)
        return m.statusError ? "problem" : "checking";
    if (state === "unavailable")
        return "unavailable";
    if (["discovering", "building", "validating"].includes(state))
        return "preparing";
    if (state === "activating")
        return "installing";
    if (state === "recovering")
        return "recovering";
    if (pending(request)) {
        const action = request.action || m.requestAction || "";
        if (action === "stage") return "preparing";
        if (action === "apply") return "installing";
        if (action === "confirm") return "finishing";
        if (action === "rollback") return "recovering";
    }
    if (state === "ready")
        return "ready";
    if (state === "awaiting-boot")
        return "restart";
    if (state === "awaiting-login")
        return confirmFailed(state, request) || !(m.automatic || {}).confirm ? "confirm" : "finishing";
    if (["failed", "interrupted", "stale", "rolled-back", "recovery-failed"].includes(state))
        return "problem";
    if (m.hasUpdates)
        return "available";
    if (m.error)
        return "problem";
    return m.sourcesLoaded ? "current" : "checking";
}

function confirmFailed(state, request) {
    return state === "awaiting-login" && (request || {}).action === "confirm" && (request || {}).state === "failed";
}

// Which problem a problem page explains.
function problem(m) {
    const state = m.state || "idle";
    if (!m.statusLoaded)
        return "status";
    if (["failed", "interrupted", "stale", "rolled-back", "recovery-failed"].includes(state))
        return state;
    return "check";
}

// A version split into what people read: NixOS's release and build date,
// date-stamped firmware, and unstable snapshots. Views format the date.
function versionParts(id, value) {
    const text = String(value || "");
    let match = /^(\d{2}\.\d{2})(?:pre)?\.(\d{4})(\d{2})(\d{2})\./.exec(text);
    if (id === "nixos" && match)
        return { text: match[1], date: match[2] + "-" + match[3] + "-" + match[4] };
    match = /^(\d{4})(\d{2})(\d{2})$/.exec(text) || /(?:^|-)unstable-(\d{4})-(\d{2})-(\d{2})$/.exec(text);
    if (match && Number(match[2]) >= 1 && Number(match[2]) <= 12 && Number(match[3]) >= 1 && Number(match[3]) <= 31)
        return { text: "", date: match[1] + "-" + match[2] + "-" + match[3] };
    return { text: text, date: "" };
}

// The reviewed change as the app presents it. A summary from an older
// worker falls back to the directly installed package list.
function summary(deployment) {
    const value = (deployment || {}).highlights;
    if (value && value.schema === 1)
        return {
            components: Array.isArray(value.components) ? value.components : [],
            apps: Array.isArray(value.apps) ? value.apps : [],
            tools: Array.isArray(value.tools) ? value.tools : [],
            background: Number(value.background) || 0,
            sizeChange: Number(value.sizeChange) || 0
        };
    const rows = ((deployment || {}).packageChanges || []).filter(row => row.kind !== "rebuilt")
        .map(row => ({ name: row.name, kind: row.kind, before: row.before, after: row.after }));
    return { components: [], apps: [], tools: rows, background: 0, sizeChange: 0 };
}

// Release notes as short items: list markers and headings are dropped.
function noteItems(text, limit) {
    const max = limit || 6;
    const lines = String(text || "").split(/\r?\n/).map(line => line.trim())
        .filter(line => line !== "" && !/^#/.test(line))
        .map(line => line.replace(/^(?:[-*\u2022]|\d+\.)\s+/, ""));
    return { items: lines.slice(0, max), more: lines.length > max };
}

// Net size change in decimal units, signed; "" when it rounds to nothing.
function sizeChange(bytes) {
    const value = Number(bytes) || 0;
    const magnitude = Math.abs(value);
    if (magnitude < 500000)
        return "";
    const sign = value < 0 ? "\u2212" : "+";
    return magnitude >= 1e9 ? sign + (magnitude / 1e9).toFixed(1) + " GB" : sign + Math.round(magnitude / 1e6) + " MB";
}

// A discovered target, so background preparation is requested once for it.
function targetKey(sources, installedIdentity) {
    const pick = source => source && source.state === "available" ? source.available || "" : "";
    return JSON.stringify([installedIdentity || "", pick((sources || {}).upstream), pick((sources || {}).cybexos)]);
}

function autoPrepare(hasUpdates, automatic, state, busy) {
    return hasUpdates && !!(automatic || {}).prepare && ["idle", "done"].includes(state || "idle") && !busy;
}

if (typeof module !== "undefined") module.exports = {
    active, pending, validSources, validDeployment, scope, scopeLabel, capabilities,
    overviewVisible, indicator, COMPONENTS, component, page, confirmFailed, problem, versionParts,
    summary, noteItems, sizeChange, targetKey, autoPrepare
};
