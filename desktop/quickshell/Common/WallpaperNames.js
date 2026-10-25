// Display names for wallpaper files. Files keep their names; only the label
// changes. The bundled collection ("moon-mountains.png") and its imported
// copies ("cybexos-moon-mountains.png") read as titles ("Moon Mountains").
// The user's own files keep their own casing, with separators as spaces.

function stem(fileName) {
    return String(fileName || "").split("/").pop().replace(/\.[^.]+$/, "");
}
function words(text) {
    return text.replace(/[-_]+/g, " ").replace(/\s+/g, " ").trim();
}
function titleCase(text) {
    return text.replace(/(^|\s)(\S)/g, function(match, space, first) { return space + first.toUpperCase(); });
}
function label(fileName, bundled) {
    var name = stem(fileName);
    var imported = /^cybexos-./.test(name);
    if (imported)
        name = name.slice("cybexos-".length);
    var spaced = words(name);
    return bundled || imported ? titleCase(spaced) : spaced || String(fileName || "");
}

var exported = { label: label };
if (typeof module !== "undefined" && module.exports)
    module.exports = exported;
