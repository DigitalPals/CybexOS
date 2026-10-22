function rebootLabel(recommendation, kernelPending) { return recommendation || (kernelPending ? "Reboot when ready" : ""); }
function pendingSummary(upstream, apps, firmware, project, version) {
    const parts = [];
    if (upstream) parts.push("Upstream NixOS packages");
    if (project) parts.push("NerdOS " + version);
    return parts.join(" · ") || "Check update sources";
}
