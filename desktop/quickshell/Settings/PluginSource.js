// The source the Omarchy plugins page installs from, out of whatever was
// pasted into its Source field. plugins.omarchy.org hands out a shell
// command ("omarchy plugin add https://github.com/acme/weather.git
// --enable"), so the field accepts that as well as a bare Git URL or local
// path: a leading prompt and the "omarchy|cybex plugin add|install" words go,
// flags go, quotes around the source go. New plugins still start switched
// off here; --enable is dropped rather than honoured. Returns "" when
// nothing usable is left. Pure — no Qt APIs — so it runs under Node in tests.

var COMMAND = /^(?:[$#>]\s*)?(?:omarchy|cybex)\s+plugins?\s+(?:add|install)(?:\s+|$)/i;

function unquote(token) {
    var match = /^(["'])(.*)\1$/.exec(token);
    return match ? match[2] : token;
}

function parse(text) {
    var rest = String(text === undefined || text === null ? "" : text).trim();
    // A command copied from a web page can carry a trailing comment or a
    // second line; only the first line is the command.
    rest = rest.split(/\r?\n/)[0].trim();
    var command = COMMAND.test(rest);
    rest = rest.replace(COMMAND, "");
    if (!command)
        return unquote(rest);
    var tokens = rest.split(/\s+/).filter(function (token) {
        return token !== "" && token.charAt(0) !== "-";
    });
    return tokens.length > 0 ? unquote(tokens[0]) : "";
}

var exported = {
    parse: parse
};

if (typeof module !== "undefined" && module.exports)
    module.exports = exported;
