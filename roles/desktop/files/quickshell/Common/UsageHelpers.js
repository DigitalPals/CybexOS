// Pure model-usage presentation helpers shared by QML and Node tests.
// Managed discovery uses the fetcher's source marker. Providers with failing
// accounts retain that marker; absent-provider placeholders do not.

var CLI_PROVIDER_KEYS = ["claude", "codex", "kimi", "xai"];
var SUPPORTED_PROVIDER_KEYS = ["claude", "codex", "kimi", "gemini", "xai"];

function providerKeys(source, data) {
    var records = data && typeof data === "object" ? data : {};
    if (source !== "cliproxy" && source !== "sub2api") {
        return CLI_PROVIDER_KEYS.filter(function (key) {
            var reading = records[key];
            if (!reading || reading.source === "cliproxy" || reading.source === "sub2api")
                return false;
            // Missing credentials and setup placeholders are not sessions.
            // Keep detected logins visible through expiry or endpoint failures,
            // but do not revive a removed login from last-known usage.
            return (reading.status === "ok" || reading.status === "error")
                && reading.kind !== "nocreds" && reading.kind !== "config"
                && reading.staleKind !== "nocreds" && reading.staleKind !== "config";
        });
    }

    var keys = source === "sub2api" ? ["claude", "codex", "gemini", "xai"]
        : CLI_PROVIDER_KEYS;
    return keys.filter(function (key) {
        var reading = records[key];
        if (!reading || reading.source !== source)
            return false;
        // If a formerly managed credential disappears, resilient polling may
        // briefly return its last reading qualified with the current failure.
        // Treat that authoritative inventory miss as removal, not stale data.
        return reading.staleKind !== "nocreds";
    });
}

// The best overall account may not report Fable. Keep that account's summary
// intact, but expose Fable readings from other accounts with explicit labels.
function additionalFableWindows(reading) {
    if (!reading || reading.status !== "ok")
        return [];
    var primary = reading.windows || [];
    if (primary.some(function (window) { return /fable/i.test(window.label || ""); }))
        return [];
    var extra = [];
    (reading.accounts || []).forEach(function (account) {
        if (!account || account.status !== "ok")
            return;
        (account.windows || []).forEach(function (window) {
            if (!/fable/i.test(window.label || ""))
                return;
            var copy = Object.assign({}, window);
            copy.label = window.label + " · " + (account.label || "Account");
            extra.push(copy);
        });
    });
    return extra;
}

function selectedProvider(keys, current) {
    var available = Array.isArray(keys) ? keys : [];
    if (available.indexOf(current) !== -1 || available.length === 0)
        return current;
    return available[0];
}

var exported = {
    SUPPORTED_PROVIDER_KEYS: SUPPORTED_PROVIDER_KEYS,
    providerKeys: providerKeys,
    additionalFableWindows: additionalFableWindows,
    selectedProvider: selectedProvider
};

if (typeof module !== "undefined" && module.exports)
    module.exports = exported;
