// The desktop opener is a trust boundary: URLs can originate in relay/GitHub
// payloads and must never select an arbitrary local protocol handler. Keep the
// policy pure so QML and the Node authentication helper use the same check.

function safeHttpUrl(value) {
    if (typeof value !== "string")
        return "";
    var trimmed = value.trim();
    if (!/^https?:\/\//i.test(trimmed))
        return "";
    // Control characters can make logs/UI disagree with the argument passed
    // to xdg-open even though it is passed without a shell.
    if (/[\u0000-\u001f\u007f]/.test(trimmed))
        return "";
    return trimmed;
}

var exported = { safeHttpUrl: safeHttpUrl };

if (typeof module !== "undefined" && module.exports)
    module.exports = exported;
