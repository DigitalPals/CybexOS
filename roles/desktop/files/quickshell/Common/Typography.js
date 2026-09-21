// Shared native/plugin typography. Logical pixels; output scale belongs to Qt.
// Reference: Omarchy 961ec7f39fd0d70c7d2944c5b80585a86713693d,
// shell/Commons/Style.qml. Usage rationale: docs/shell-typography.md.
var SCALE = {
    caption: ["caption", 0.833], bodySmall: ["body-small", 0.917],
    body: ["body", 1], subtitle: ["subtitle", 1.083],
    title: ["title", 1.167], heading: ["heading", 1.333],
    display: ["display", 2], displayLarge: ["display-large", 2.333],
    iconSmall: ["icon-small", 0.917], icon: ["icon", 1.167],
    iconLarge: ["icon-large", 1.5],
    // Omarchy clock Panel.qml uses a 52px date hero outside its core scale.
    clock: ["clock", 52 / 12]
};

// Choose a usage, not a smaller size to make a row fit. Grow/wrap the row.
var ROLES = {
    bar: "body", control: "body", navigation: "body", primary: "body",
    secondary: "bodySmall", section: "caption", metadata: "caption",
    tooltip: "bodySmall", notification: "title", osd: "title"
};

function pixels(base, multiplier) {
    return Math.max(1, Math.round(base * multiplier));
}

function resolve(base, overrides) {
    base = Number(base);
    if (!isFinite(base) || base <= 0) base = 12;
    overrides = overrides || {};
    var sizes = {};
    Object.keys(SCALE).forEach(function(name) {
        var spec = SCALE[name];
        var requested = Number(overrides[spec[0]]);
        var fallback = name === "iconSmall" ? sizes.bodySmall
            : name === "icon" ? sizes.title : pixels(base, spec[1]);
        sizes[name] = isFinite(requested) && requested > 0
            ? Math.max(1, Math.round(requested)) : fallback;
    });
    Object.keys(ROLES).forEach(function(role) { sizes[role] = sizes[ROLES[role]]; });
    return sizes;
}

if (typeof module !== "undefined" && module.exports)
    module.exports = { SCALE: SCALE, ROLES: ROLES, pixels: pixels, resolve: resolve };
