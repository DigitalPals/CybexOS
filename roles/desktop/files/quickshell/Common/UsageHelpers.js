// Pure model-usage presentation helpers shared by QML and Node tests.
// Managed discovery uses the fetcher's source marker. Providers with failing
// accounts retain that marker; absent-provider placeholders do not.

var CLI_PROVIDER_KEYS = ["claude", "codex", "kimi", "xai"];
var SUPPORTED_PROVIDER_KEYS = ["claude", "codex", "kimi", "gemini", "xai"];

function providerKeys(source, data) {
    if (source !== "cliproxy" && source !== "sub2api")
        return CLI_PROVIDER_KEYS.slice();

    var records = data && typeof data === "object" ? data : {};
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

function selectedProvider(keys, current) {
    var available = Array.isArray(keys) ? keys : [];
    if (available.indexOf(current) !== -1 || available.length === 0)
        return current;
    return available[0];
}

var exported = {
    SUPPORTED_PROVIDER_KEYS: SUPPORTED_PROVIDER_KEYS,
    providerKeys: providerKeys,
    selectedProvider: selectedProvider
};

if (typeof module !== "undefined" && module.exports)
    module.exports = exported;
