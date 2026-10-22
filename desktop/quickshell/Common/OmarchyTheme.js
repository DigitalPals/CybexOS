// Pure translation of Cybex preferences into Omarchy's flat shell tokens.
function values(settings, palette, metrics, session) {
    var inherited = settings.pluginBorderMode === "inherit";
    var border = inherited ? palette.surfaceBorder : settings.pluginBorderMode === "custom" ? settings.pluginBorderColor
        : settings.pluginBorderMode === "subtle" ? palette.outline : palette.accent;
    var out = {
        "font.base-size": String(Math.max(1, Math.round(metrics.fontBase * settings.pluginScale / 100))),
        "spacing.scale": String(metrics.density),
        "spacing.scale-with-font": "true",
        "hyprland.active-border": border,
        "hyprland.active-border-foreground": border
    };
    ["bar", "popups", "tooltip", "menu", "launcher", "notifications"].forEach(function(surface) {
        out[surface + ".background"] = surface === "bar" ? palette.bar : palette.background;
        out[surface + ".text"] = palette.foreground;
        out[surface + ".border"] = border;
        out[surface + ".border-width"] = String(inherited ? palette.surfaceBorderWidth : settings.pluginBorderWidth);
        out[surface + ".border-alpha"] = String(inherited ? palette.surfaceBorderAlpha : settings.pluginBorderOpacity / 100);
    });
    // Session imports override defaults; persistent user tokens always win.
    [session || {}, settings.pluginThemeOverrides || {}].forEach(function(layer) {
        Object.keys(layer).forEach(function(key) { out[key] = String(layer[key]); });
    });
    return out;
}

if (typeof module !== "undefined" && module.exports)
    module.exports = { values: values };
