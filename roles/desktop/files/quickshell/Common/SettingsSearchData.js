// The settings search index (turn-3 settings design): every row the nav
// search can jump to, described once. `page` must be a Settings.validPages
// id, `key` a Settings key when the target is a keyed row — the jump
// highlights that row through Settings.highlightKey — or "" when the entry
// only navigates to its page.
//
// Keep this file free of Qt APIs so settings-search.test.cjs can hold it
// against SettingsHelpers' schema under Node.

var ROWS = [
    // Appearance
    { page: "appearance", pageLabel: "Appearance", group: "Theme", label: "Mode", key: "themeMode", terms: "dark light theme" },
    { page: "appearance", pageLabel: "Appearance", group: "Theme", label: "Glass effect", key: "glassEnabled", terms: "blur translucent transparent" },
    { page: "appearance", pageLabel: "Appearance", group: "Theme", label: "High contrast", key: "highContrast", terms: "accessibility opaque borders" },
    { page: "appearance", pageLabel: "Appearance", group: "Colors", label: "Accent source", key: "paletteMode", terms: "wallpaper palette fixed color" },
    { page: "appearance", pageLabel: "Appearance", group: "Colors", label: "Accent hue", key: "accent", terms: "color swatch preset" },
    { page: "appearance", pageLabel: "Appearance", group: "Colors", label: "Bar background", key: "barColorMode", terms: "menubar color custom" },
    { page: "appearance", pageLabel: "Appearance", group: "Typography", label: "Interface font", key: "font", terms: "typeface figtree mono" },
    { page: "appearance", pageLabel: "Appearance", group: "Accessibility", label: "Reduce motion", key: "reducedMotion", terms: "animation accessibility" },
    { page: "appearance", pageLabel: "Appearance", group: "Accessibility", label: "Text size", key: "textScale", terms: "scale large accessibility" },
    { page: "appearance", pageLabel: "Appearance", group: "Accessibility", label: "Control spacing", key: "interfaceDensity", terms: "density compact comfortable touch" },

    // Wallpaper
    { page: "wallpaper", pageLabel: "Wallpaper", group: "Image", label: "Wallpaper", key: "wall", terms: "desktop image background picture" },
    { page: "wallpaper", pageLabel: "Wallpaper", group: "Image", label: "Folder", key: "wallDir", terms: "directory pictures" },
    { page: "wallpaper", pageLabel: "Wallpaper", group: "Rotation", label: "Shuffle", key: "shuffle", terms: "rotate slideshow interval" },

    // Bar
    { page: "bar", pageLabel: "Bar", group: "Placement", label: "Position", key: "position", terms: "top bottom edge" },
    { page: "bar", pageLabel: "Bar", group: "Shape", label: "Style", key: "barStyle", terms: "hug floating attached edge" },
    { page: "bar", pageLabel: "Bar", group: "Shape", label: "Height", key: "barHeight", terms: "size thickness" },
    { page: "bar", pageLabel: "Bar", group: "Shape", label: "Edge gap", key: "gap", terms: "margin floating" },
    { page: "bar", pageLabel: "Bar", group: "Shape", label: "Corner radius", key: "barRadius", terms: "rounding floating" },
    { page: "bar", pageLabel: "Bar", group: "Behavior", label: "Auto-hide", key: "autoHide", terms: "hide idle reveal" },
    { page: "bar", pageLabel: "Bar", group: "Behavior", label: "Reserve space", key: "exclusive", terms: "exclusive zone tiled windows" },

    // Widgets
    { page: "appearance", pageLabel: "Appearance", group: "Shell sizing and surfaces", label: "Shell font size", key: "shellFontSize", terms: "typography omarchy base" },
    { page: "appearance", pageLabel: "Appearance", group: "Shell sizing and surfaces", label: "Shell UI scale", key: "shellScale", terms: "zoom size accessibility" },
    { page: "appearance", pageLabel: "Appearance", group: "Shell sizing and surfaces", label: "Panel border", key: "surfaceBorderMode", terms: "accent subtle custom" },
    { page: "appearance", pageLabel: "Appearance", group: "Shell sizing and surfaces", label: "Panel border color", key: "surfaceBorderColor", terms: "color" },
    { page: "appearance", pageLabel: "Appearance", group: "Shell sizing and surfaces", label: "Panel border width", key: "surfaceBorderWidth", terms: "outline" },
    { page: "appearance", pageLabel: "Appearance", group: "Shell sizing and surfaces", label: "Panel opacity", key: "surfaceBorderOpacity", terms: "border transparency" },
    { page: "appearance", pageLabel: "Appearance", group: "Shell sizing and surfaces", label: "Panel corners", key: "surfaceCornerRadius", terms: "radius rounding" },
    { page: "appearance", pageLabel: "Appearance", group: "Plugin appearance", label: "Plugin UI scale", key: "pluginScale", terms: "size font zoom omarchy" },
    { page: "appearance", pageLabel: "Appearance", group: "Plugin appearance", label: "Plugin border", key: "pluginBorderMode", terms: "accent subtle custom omarchy" },
    { page: "appearance", pageLabel: "Appearance", group: "Plugin appearance", label: "Plugin border color", key: "pluginBorderColor", terms: "color omarchy" },
    { page: "appearance", pageLabel: "Appearance", group: "Plugin appearance", label: "Plugin border width", key: "pluginBorderWidth", terms: "outline omarchy" },
    { page: "appearance", pageLabel: "Appearance", group: "Plugin appearance", label: "Plugin border opacity", key: "pluginBorderOpacity", terms: "transparency omarchy" },
    { page: "appearance", pageLabel: "Appearance", group: "Plugin appearance", label: "Plugin corners", key: "pluginRadius", terms: "radius rounding omarchy" },
    { page: "plugins", pageLabel: "Plugins", group: "Packages", label: "Manage plugins", key: "", terms: "install git add update clone remove enable disable omarchy" },
    { page: "modules", pageLabel: "Widgets", group: "Lanes", label: "Arrange widgets", key: "", terms: "drag order left center right lane module notification group grouping status pill separate" },
    { page: "modules", pageLabel: "Widgets", group: "Catalog", label: "Show or hide widgets", key: "", terms: "enable disable toggle module clock weather notes battery tray workspaces media" },
    { page: "modules", pageLabel: "Widgets", group: "Indicators", label: "Clock-side actions", key: "", terms: "indicator dictate recording ocr scan text clipboard reminder night light do not disturb dnd stay awake idle inhibit order startup duration" },
    { page: "modules", pageLabel: "Widgets", group: "Notes", label: "AI note titles", key: "", terms: "codex claude model provider effort reasoning generate regenerate privacy" },

    // Drawer
    { page: "drawer", pageLabel: "Drawer", group: "Tabs", label: "Tab order", key: "", terms: "reorder overview sound network bluetooth power notifications usage" },
    { page: "drawer", pageLabel: "Drawer", group: "Overview", label: "Overview contents", key: "", terms: "now playing sliders tiles updates cpu ram temperature system stats" },
    { page: "drawer", pageLabel: "Drawer", group: "Behavior", label: "Open on hover", key: "drawerHover", terms: "hover switch glyph menu" },
    { page: "drawer", pageLabel: "Drawer", group: "Behavior", label: "Width", key: "drawerWidth", terms: "size wide" },

    // Notifications
    { page: "notifications", pageLabel: "Notifications", group: "Behavior", label: "Do Not Disturb", key: "notifDnd", terms: "dnd silence mute focus" },
    { page: "notifications", pageLabel: "Notifications", group: "Behavior", label: "Quiet hours", key: "notifQuiet", terms: "night schedule silence" },
    { page: "notifications", pageLabel: "Notifications", group: "Behavior", label: "Duration", key: "notifDuration", terms: "toast timeout seconds" },
    { page: "notifications", pageLabel: "Notifications", group: "Behavior", label: "Position", key: "notifPosition", terms: "toast corner top bottom" },
    { page: "notifications", pageLabel: "Notifications", group: "Style", label: "Density", key: "notifDensity", terms: "compact roomy toast" },
    { page: "notifications", pageLabel: "Notifications", group: "Style", label: "App icons", key: "notifIcons", terms: "sender icon toast" },
    { page: "notifications", pageLabel: "Notifications", group: "Style", label: "Timeout progress", key: "notifProgress", terms: "countdown bar toast" },
    { page: "notifications", pageLabel: "Notifications", group: "Style", label: "Body preview", key: "notifBodyLines", terms: "lines text toast" },

    // System
    { page: "system", pageLabel: "System", group: "General", label: "Clock", key: "clock24", terms: "24 12 hour time format" },
    { page: "system", pageLabel: "System", group: "General", label: "Temperature", key: "unit", terms: "celsius fahrenheit weather unit" },
    { page: "system", pageLabel: "System", group: "General", label: "Scroll speed", key: "scrollFactor", terms: "touchpad mouse wheel" },
    { page: "system", pageLabel: "System", group: "Night light", label: "Warmth", key: "warmth", terms: "kelvin tint blue light" },
    { page: "system", pageLabel: "System", group: "Stay awake", label: "Duration", key: "", terms: "idle inhibit caffeine sleep" },
    { page: "system", pageLabel: "System", group: "OSD", label: "Placement", key: "osd", terms: "volume brightness popup overlay" },
    { page: "system", pageLabel: "System", group: "T3 usage", label: "Poll every", key: "pollMax", terms: "model usage refresh interval" },
    { page: "system", pageLabel: "System", group: "Shell health", label: "Status", key: "", terms: "service deployment journal pid" },
    { page: "system", pageLabel: "System", group: "Config", label: "Settings file", key: "", terms: "json open reset all shell-settings" }
];

// Case-insensitive substring match over the words a user would type. Results
// keep index order — the pages' own order — with label hits ranked above
// hits that only matched hidden search terms.
function search(query) {
    var q = (query || "").trim().toLowerCase();
    if (q === "")
        return [];
    var labelHits = [];
    var termHits = [];
    ROWS.forEach(function(row) {
        var direct = (row.label + " " + row.group + " " + row.pageLabel)
            .toLowerCase().indexOf(q) !== -1;
        if (direct)
            labelHits.push(row);
        else if (row.terms.toLowerCase().indexOf(q) !== -1)
            termHits.push(row);
    });
    return labelHits.concat(termHits);
}

var exported = {
    ROWS: ROWS,
    search: search
};

if (typeof module !== "undefined" && module.exports)
    module.exports = exported;
