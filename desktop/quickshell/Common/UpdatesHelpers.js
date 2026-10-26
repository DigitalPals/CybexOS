// Shared update capabilities and presentation; no Qt APIs, so behavior is testable.
function active(state) {
    return ["discovering", "building", "validating", "activating", "recovering"].includes(state);
}

function pending(request) {
    return ["queued", "running", "unknown"].includes((request || {}).state);
}

function validSources(value) {
    const states = ["available", "current", "unavailable", "unreachable", "unknown"];
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
        discard: !blocked && ["ready", "stale"].includes(state) && !!deployment.transaction
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

function packageChange(row) {
    if (row.kind === "added") return "New · " + (row.after || "version not supplied");
    if (row.kind === "removed") return (row.before || "Installed") + " · Removed";
    if (row.kind === "rebuilt") return (row.after || "Same version") + " · Rebuilt";
    return (row.before || "—") + " → " + (row.after || "—");
}

if (typeof module !== "undefined") module.exports = {
    active, pending, validSources, validDeployment, scope, scopeLabel, capabilities,
    overviewVisible, indicator, packageChange
};
