// Pure helpers behind Common/I18n.qml, shared with the Node tests.
//
// Catalogs are keyed by the English source text. Any string can then be
// translated where it is shown, wherever it was composed (a QML literal, a
// JS helper's label, a settings search entry), and a string without an entry
// stays English instead of turning into a key name.

// Languages with a catalog. English is the source language and needs none.
var LANGUAGES = ["en", "nl"];

// The language a POSIX locale value names: "nl_NL.UTF-8" and "nl" are Dutch,
// "C" and "POSIX" carry none. `values` is the precedence order the C library
// uses (LC_ALL, then LC_MESSAGES, then LANG); the first one that names a
// language decides, and an unsupported language falls back to English rather
// than to the next variable, as gettext does.
function languageFor(values) {
    var list = Array.isArray(values) ? values : [values];
    for (var i = 0; i < list.length; i++) {
        var value = String(list[i] || "").trim();
        if (value === "" || value === "C" || value === "POSIX"
                || value.indexOf("C.") === 0)
            continue;
        var language = value.split(/[_.@-]/)[0].toLowerCase();
        return LANGUAGES.indexOf(language) === -1 ? "en" : language;
    }
    return "en";
}

function translate(catalog, text) {
    var key = text === undefined || text === null ? "" : String(text);
    if (key === "" || !catalog)
        return key;
    var value = catalog[key];
    return typeof value === "string" && value !== "" ? value : key;
}

// Positional arguments: "%1 of %2" with ["3", "5"]. Substitution happens
// after translation, so a translator may reorder the placeholders.
function format(catalog, text, args) {
    var values = Array.isArray(args) ? args : [];
    return translate(catalog, text).replace(/%([1-9])/g, function(match, digit) {
        var index = Number(digit) - 1;
        return index < values.length ? String(values[index]) : match;
    });
}

var exported = {
    LANGUAGES: LANGUAGES,
    languageFor: languageFor,
    translate: translate,
    format: format
};

if (typeof module !== "undefined" && module.exports)
    module.exports = exported;
