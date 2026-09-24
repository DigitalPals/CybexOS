// The settings search index (turn-3 settings design): every row the nav
// search can jump to, described once. `page` must be a Settings.validPages
// id, `key` a Settings key when the target is a keyed row — the jump
// highlights that row through Settings.highlightKey — or "" when the entry
// only navigates to its page. An optional `widget` names a widget whose
// settings dialog holds the row; the jump opens it.
//
// Keep this file free of Qt APIs so settings-search.test.cjs can hold it
// against SettingsHelpers' schema under Node.

var ROWS = [
    // Appearance
    { page: "network", pageLabel: "Network", group: "Connections", label: "Network connections", key: "", terms: "wifi ethernet ipv4 ipv6 dns gateway addresses manual automatic metered" },
    { page: "sound", pageLabel: "Sound", group: "Devices", label: "Sound devices and applications", key: "", terms: "audio microphone volume profiles ports balance routing mute" },
    { page: "accounts", pageLabel: "Online accounts", group: "Accounts", label: "Online accounts", key: "", terms: "google calendar login reconnect remove credentials" },
    { page: "appearance", pageLabel: "Appearance", group: "Theme", label: "Mode", key: "themeMode", terms: "dark light theme" },
    { page: "appearance", pageLabel: "Appearance", group: "Theme", label: "Glass effect", key: "glassEnabled", terms: "blur translucent transparent" },
    { page: "appearance", pageLabel: "Appearance", group: "Text & size", label: "Interface font", key: "font", terms: "typeface figtree mono typography" },
    { page: "appearance", pageLabel: "Appearance", group: "Text & size", label: "Base font", key: "shellFontSize", terms: "typography font size pixels" },
    { page: "appearance", pageLabel: "Appearance", group: "Text & size", label: "Text size", key: "textScale", terms: "scale large accessibility readability" },
    { page: "appearance", pageLabel: "Appearance", group: "Text & size", label: "UI scale", key: "shellScale", terms: "zoom size accessibility" },
    { page: "appearance", pageLabel: "Appearance", group: "Text & size", label: "Control spacing", key: "interfaceDensity", terms: "density compact comfortable touch" },
    { page: "appearance", pageLabel: "Appearance", group: "Colors", label: "Accent source", key: "paletteMode", terms: "wallpaper palette fixed color" },
    { page: "appearance", pageLabel: "Appearance", group: "Colors", label: "Accent hue", key: "accent", terms: "color swatch preset sky lavender sage sand coral" },
    { page: "appearance", pageLabel: "Appearance", group: "Colors", label: "Bar background", key: "barColorMode", terms: "menubar color custom" },
    { page: "appearance", pageLabel: "Appearance", group: "Panels", label: "Panel border", key: "surfaceBorderMode", terms: "accent subtle custom outline" },
    { page: "appearance", pageLabel: "Appearance", group: "Panels", label: "Panel border color", key: "surfaceBorderColor", terms: "color hex" },
    { page: "appearance", pageLabel: "Appearance", group: "Panels", label: "Panel border width", key: "surfaceBorderWidth", terms: "outline" },
    { page: "appearance", pageLabel: "Appearance", group: "Panels", label: "Panel border opacity", key: "surfaceBorderOpacity", terms: "border transparency" },
    { page: "appearance", pageLabel: "Appearance", group: "Panels", label: "Panel corners", key: "surfaceCornerRadius", terms: "radius rounding" },
    { page: "appearance", pageLabel: "Appearance", group: "Plugins", label: "Match shell style", key: "", terms: "plugin appearance omarchy inherit" },
    { page: "appearance", pageLabel: "Appearance", group: "Plugins", label: "Plugin UI scale", key: "pluginScale", terms: "size font zoom omarchy" },
    { page: "appearance", pageLabel: "Appearance", group: "Plugins", label: "Plugin border", key: "pluginBorderMode", terms: "accent subtle custom omarchy" },
    { page: "appearance", pageLabel: "Appearance", group: "Plugins", label: "Plugin border color", key: "pluginBorderColor", terms: "color hex omarchy" },
    { page: "appearance", pageLabel: "Appearance", group: "Plugins", label: "Plugin border width", key: "pluginBorderWidth", terms: "outline omarchy" },
    { page: "appearance", pageLabel: "Appearance", group: "Plugins", label: "Plugin border opacity", key: "pluginBorderOpacity", terms: "transparency omarchy" },
    { page: "appearance", pageLabel: "Appearance", group: "Plugins", label: "Plugin corners", key: "pluginRadius", terms: "radius rounding omarchy" },
    { page: "appearance", pageLabel: "Appearance", group: "Accessibility", label: "High contrast", key: "highContrast", terms: "accessibility opaque borders solid" },
    { page: "appearance", pageLabel: "Appearance", group: "Accessibility", label: "Reduce motion", key: "reducedMotion", terms: "animation accessibility" },

    // Wallpaper
    { page: "wallpaper", pageLabel: "Wallpaper", group: "Image", label: "Wallpaper", key: "wall", terms: "desktop image background picture" },
    { page: "wallpaper", pageLabel: "Wallpaper", group: "Image", label: "Folder", key: "wallDir", terms: "directory pictures" },
    { page: "wallpaper", pageLabel: "Wallpaper", group: "Rotation", label: "Shuffle", key: "shuffle", terms: "rotate slideshow interval" },

    // Bar
    { page: "bar", pageLabel: "Bar", group: "Layout", label: "Position", key: "position", terms: "top bottom edge placement" },
    { page: "bar", pageLabel: "Bar", group: "Layout", label: "Style", key: "barStyle", terms: "hug floating attached edge shape" },
    { page: "bar", pageLabel: "Bar", group: "Layout", label: "Height", key: "barHeight", terms: "size thickness compact classic roomy preset" },
    { page: "bar", pageLabel: "Bar", group: "Layout", label: "Edge gap", key: "gap", terms: "margin floating" },
    { page: "bar", pageLabel: "Bar", group: "Layout", label: "Corner radius", key: "barRadius", terms: "rounding floating" },
    { page: "bar", pageLabel: "Bar", group: "Behavior", label: "Auto-hide", key: "autoHide", terms: "hide idle reveal" },
    { page: "bar", pageLabel: "Bar", group: "Behavior", label: "Reserve space", key: "exclusive", terms: "exclusive zone tiled windows" },

    // Widgets
    { page: "plugins", pageLabel: "Plugins", group: "Packages", label: "Manage plugins", key: "", terms: "install git add update clone remove enable disable omarchy" },
    { page: "modules", pageLabel: "Widgets", group: "Lanes", label: "Arrange widgets", key: "", terms: "drag order left center right lane module notification group grouping status pill separate" },
    { page: "modules", pageLabel: "Widgets", group: "Catalog", label: "Show or hide widgets", key: "", terms: "enable disable toggle module clock weather notes battery tray workspaces media" },
    { page: "modules", pageLabel: "Widgets", group: "Indicators", label: "Clock-side actions", key: "", terms: "indicator dictate recording ocr scan text clipboard reminder night light do not disturb dnd stay awake idle inhibit order startup duration" },
    { page: "modules", pageLabel: "Widgets", group: "Notes", label: "AI note titles", key: "", terms: "codex claude model provider effort reasoning generate regenerate privacy" },
    { page: "modules", pageLabel: "Widgets", group: "Weather", label: "Weather location", key: "", widget: "weather", terms: "clock city place search country region coordinates latitude longitude forecast" },
    { page: "modules", pageLabel: "Widgets", group: "Usage", label: "Usage refresh interval", key: "pollMax", widget: "usage", terms: "t3 model usage poll refresh interval" },

    { page: "modules", pageLabel: "Widgets", group: "Model usage", label: "Model usage", key: "", widget: "usage", terms: "providers accounts quota credentials api key direct cliproxy sub2api" },

    { page: "modules", pageLabel: "Widgets", group: "Control Center", label: "Control Center widget", key: "", widget: "control", terms: "fedora button move drag reorder show hide drawer" },

    // Control Center (also searchable by its former Drawer name)
    { page: "modules", pageLabel: "Widgets", widget: "control", group: "Tabs", label: "Tab order", key: "", terms: "drawer reorder overview sound network bluetooth power notifications usage" },
    { page: "modules", pageLabel: "Widgets", widget: "control", group: "Overview", label: "Overview contents", key: "", terms: "drawer now playing sliders tiles updates cpu ram temperature system stats" },
    { page: "modules", pageLabel: "Widgets", widget: "control", group: "Behavior", label: "Open on hover", key: "drawerHover", terms: "drawer hover switch glyph menu" },
    { page: "modules", pageLabel: "Widgets", widget: "control", group: "Behavior", label: "Width", key: "drawerWidth", terms: "drawer size wide" },

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
    { page: "system", pageLabel: "System", group: "Formats", label: "Clock", key: "clock24", terms: "24 12 hour time format" },
    { page: "system", pageLabel: "System", group: "Formats", label: "Temperature", key: "unit", terms: "celsius fahrenheit weather unit" },
    { page: "system", pageLabel: "System", group: "Touchpad", label: "Scroll speed", key: "scrollFactor", terms: "touchpad mouse wheel input" },
    { page: "system", pageLabel: "System", group: "Night light", label: "Night light", key: "nightLight", terms: "blue light hyprsunset" },
    { page: "system", pageLabel: "System", group: "Night light", label: "Warmth", key: "warmth", terms: "kelvin tint blue light" },
    { page: "system", pageLabel: "System", group: "Idle", label: "Lock screen", key: "idleLockMins", terms: "idle timeout auto lock hypridle power" },
    { page: "system", pageLabel: "System", group: "Idle", label: "Screen off", key: "idleScreenOffMins", terms: "idle timeout display dpms blank monitor power" },
    { page: "system", pageLabel: "System", group: "Idle", label: "Suspend", key: "idleSuspendMins", terms: "idle timeout sleep suspend power" },
    { page: "system", pageLabel: "System", group: "Idle", label: "Only on battery", key: "idleSuspendBatteryOnly", terms: "idle suspend sleep battery plugged in ac power" },
    { page: "system", pageLabel: "System", group: "Stay awake", label: "Duration", key: "", terms: "idle inhibit caffeine sleep" },
    { page: "system", pageLabel: "System", group: "On-screen display", label: "Placement", key: "osd", terms: "osd volume brightness popup overlay" },
    { page: "system", pageLabel: "System", group: "Recovery points", label: "Recovery points", key: "", terms: "snapshot restore rollback undo update btrfs boot menu grub recovery" },

    // About
    { page: "about", pageLabel: "About", group: "Shell health", label: "Status", key: "", terms: "service deployment journal pid" },
    { page: "about", pageLabel: "About", group: "Settings file", label: "Settings file", key: "", terms: "json open config shell-settings" },
    { page: "about", pageLabel: "About", group: "Reset", label: "Reset all settings", key: "", terms: "defaults factory restore" }
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
