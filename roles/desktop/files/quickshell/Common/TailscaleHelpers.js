// tailscale up --json emits several pretty-printed objects, not JSON lines.
// Keep only one bounded object in memory; never log its authentication URL.
function outputLine(buffer, line) {
    var next = buffer === "" ? String(line).trim() : buffer + "\n" + line;
    if (next[0] !== "{")
        return { buffer: "", event: null };
    if (next.length > 65536)
        return { buffer: "", event: { Error: "Tailscale returned an oversized response." } };
    try {
        return { buffer: "", event: JSON.parse(next) };
    } catch (_) {
        return { buffer: next, event: null };
    }
}

function authUrl(value) {
    // Allow HTTPS control servers, including Headscale, but no credentials,
    // whitespace, shell/file schemes, or backslashes interpreted as slashes.
    return typeof value === "string" && value.length <= 4096
        && !/[\s\\\x00-\x1f\x7f]/.test(value)
        && /^https:\/\/[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?(?::[0-9]{1,5})?\/[^\s\\\x00-\x1f\x7f]*$/i.test(value)
        ? value : "";
}

function needsPermission(message) {
    return /Access denied:|permission denied|must be run as root|requires root/i.test(message);
}

function waitingTimeout(message) {
    return /timeout waiting for Tailscale service to enter a Running state/i.test(message);
}

function errorMessage(code, message, privileged) {
    if (privileged && (code === 126 || code === 127))
        return "Authorization was cancelled or denied. Try again to connect.";
    if (/failed to connect to local tailscaled|tailscaled.*not running|connection refused/i.test(message))
        return "The Tailscale service is unavailable. Start it and try again.";
    if (code === 124 || waitingTimeout(message))
        return "Tailscale did not connect in time. Check your internet connection and try again.";
    if (code === 127 || code === -1)
        return "Tailscale or a required system command is not installed.";
    // Error output can include an authentication link. Show useful diagnostics
    // in the UI without retaining the link in errors or notifications.
    var detail = String(message || "").replace(/https?:\/\/\S+/gi, "[link]")
        .replace(/[\x00-\x1f\x7f]+/g, " ").trim().slice(0, 360);
    return detail || "Tailscale could not complete the request. Try again.";
}

function command(up, privileged, login) {
    // The timeout runs at the same privilege level as tailscale, so even a
    // shell restart cannot leave a root-owned login command waiting forever.
    var args = ["/usr/bin/timeout", "--kill-after=2s", "20s", "/usr/bin/tailscale"];
    // A bare up is Tailscale's special reconnect path: adding even --json
    // makes it reject existing non-default preferences. Only new sign-ins
    // use JSON; a reconnect that discovers expired credentials also emits
    // its HTTPS login URL on stderr, which the caller handles separately.
    args = args.concat(!up ? ["down"] : login === false ? ["up"]
        : ["up", "--json", "--timeout=15s"]);
    return privileged ? ["/usr/bin/pkexec"].concat(args) : args;
}

if (typeof module !== "undefined")
    module.exports = { outputLine: outputLine, authUrl: authUrl,
        needsPermission: needsPermission, waitingTimeout: waitingTimeout,
        errorMessage: errorMessage, command: command };
