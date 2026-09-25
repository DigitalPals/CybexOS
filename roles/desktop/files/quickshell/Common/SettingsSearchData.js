// The settings search index (turn-3 settings design): every row the nav
// search can jump to, described once. `page` must be a Settings.pages
// id, `key` a Settings key when the target is a keyed row — the jump
// highlights that row through Settings.highlightKey — or "" when the entry
// only navigates to its page. An optional `widget` names a widget whose
// settings dialog holds the row; the jump opens it.
//
// Keep this file free of Qt APIs so settings-search.test.cjs can hold it
// against SettingsHelpers' schema under Node.

var ROWS = [
    // Appearance
    { page: "network", pageLabel: "Network", group: "Connections", label: "Network connections", key: "", terms: "wifi ethernet saved profile adapter vpn advanced editor" },
    { page: "network", pageLabel: "Network", group: "Connection", label: "Autoconnect and metered", key: "", terms: "automatic join metered data limit background" },
    { page: "network", pageLabel: "Network", group: "IPv4 and IPv6", label: "IP addresses and DNS", key: "", terms: "ipv4 ipv6 dns gateway address manual automatic static dhcp" },
    { page: "sound", pageLabel: "Sound", group: "Output", label: "Output device and volume", key: "", terms: "audio speaker headphones volume mute balance port network airplay" },
    { page: "sound", pageLabel: "Sound", group: "Input", label: "Input device and volume", key: "", terms: "audio microphone mic level mute" },
    { page: "sound", pageLabel: "Sound", group: "Hardware profiles", label: "Hardware profiles", key: "", terms: "audio card profile pro audio hifi" },
    { page: "sound", pageLabel: "Sound", group: "Applications", label: "Application audio", key: "", terms: "audio routing per-app volume mute mixer pavucontrol" },
    // Displays (Settings -> Displays): monitor rules saved outside shell.json.
    { page: "displays", pageLabel: "Displays", group: "Arrangement", label: "Display arrangement", key: "", terms: "monitor screen layout position multiple external dock" },
    { page: "displays", pageLabel: "Displays", group: "Selected display", label: "Resolution and refresh rate", key: "", terms: "monitor mode hz hertz 4k 120 144 60" },
    { page: "displays", pageLabel: "Displays", group: "Selected display", label: "Display scale", key: "", terms: "monitor hidpi fractional zoom size 125 150 200" },
    { page: "displays", pageLabel: "Displays", group: "Selected display", label: "Rotation", key: "", terms: "monitor transform portrait landscape orientation flip flipped" },
    { page: "displays", pageLabel: "Displays", group: "Selected display", label: "Mirror and turn off displays", key: "", terms: "monitor duplicate projector disable enable lid clamshell" },
    { page: "displays", pageLabel: "Displays", group: "Selected display", label: "Adaptive sync", key: "", terms: "monitor vrr freesync gsync variable refresh" },
    { page: "accounts", pageLabel: "Online accounts", group: "Online accounts", label: "Add account", key: "", terms: "google calendar login sign in reconnect remove credentials" },
    { page: "accounts", pageLabel: "Online accounts", group: "Online accounts", label: "Use calendars", key: "", terms: "calendar events account sync" },
    { page: "appearance", pageLabel: "Appearance", group: "Theme", label: "Mode", key: "themeMode", terms: "dark light theme" },
    { page: "appearance", pageLabel: "Appearance", group: "Theme", label: "Glass effect", key: "glassEnabled", terms: "blur translucent transparent" },
    { page: "appearance", pageLabel: "Appearance", group: "Text & size", label: "Interface font", key: "font", terms: "typeface figtree mono typography" },
    { page: "appearance", pageLabel: "Appearance", group: "Text & size", label: "Base font size", key: "shellFontSize", terms: "typography font size pixels advanced" },
    { page: "appearance", pageLabel: "Appearance", group: "Text & size", label: "Text size", key: "textScale", terms: "scale large accessibility readability" },
    { page: "appearance", pageLabel: "Appearance", group: "Text & size", label: "Interface scale", key: "shellScale", terms: "ui zoom size accessibility" },
    { page: "appearance", pageLabel: "Appearance", group: "Text & size", label: "Density", key: "interfaceDensity", terms: "control spacing compact comfortable touch row height" },
    { page: "appearance", pageLabel: "Appearance", group: "Colors", label: "Accent source", key: "paletteMode", terms: "wallpaper palette fixed color" },
    { page: "appearance", pageLabel: "Appearance", group: "Colors", label: "Accent color", key: "accent", terms: "hue swatch preset sky lavender sage sand coral" },
    { page: "appearance", pageLabel: "Appearance", group: "Panels", label: "Panel border", key: "surfaceBorderMode", terms: "accent subtle custom outline" },
    { page: "appearance", pageLabel: "Appearance", group: "Panels", label: "Panel border color", key: "surfaceBorderColor", terms: "color hex" },
    { page: "appearance", pageLabel: "Appearance", group: "Panels", label: "Panel border width", key: "surfaceBorderWidth", terms: "outline" },
    { page: "appearance", pageLabel: "Appearance", group: "Panels", label: "Panel border opacity", key: "surfaceBorderOpacity", terms: "border transparency" },
    { page: "appearance", pageLabel: "Appearance", group: "Panels", label: "Panel corners", key: "surfaceCornerRadius", terms: "radius rounding" },
    { page: "appearance", pageLabel: "Appearance", group: "Omarchy plugins", label: "Match shell style", key: "", terms: "plugin appearance omarchy inherit" },
    { page: "appearance", pageLabel: "Appearance", group: "Omarchy plugins", label: "Plugin interface scale", key: "pluginScale", terms: "ui size font zoom omarchy" },
    { page: "appearance", pageLabel: "Appearance", group: "Omarchy plugins", label: "Plugin border", key: "pluginBorderMode", terms: "accent subtle custom omarchy" },
    { page: "appearance", pageLabel: "Appearance", group: "Omarchy plugins", label: "Plugin border color", key: "pluginBorderColor", terms: "color hex omarchy" },
    { page: "appearance", pageLabel: "Appearance", group: "Omarchy plugins", label: "Plugin border width", key: "pluginBorderWidth", terms: "outline omarchy" },
    { page: "appearance", pageLabel: "Appearance", group: "Omarchy plugins", label: "Plugin border opacity", key: "pluginBorderOpacity", terms: "transparency omarchy" },
    { page: "appearance", pageLabel: "Appearance", group: "Omarchy plugins", label: "Plugin corners", key: "pluginRadius", terms: "radius rounding omarchy" },
    { page: "appearance", pageLabel: "Appearance", group: "Accessibility", label: "High contrast", key: "highContrast", terms: "accessibility opaque borders solid" },
    { page: "appearance", pageLabel: "Appearance", group: "Accessibility", label: "Reduce motion", key: "reducedMotion", terms: "animation accessibility" },

    // Wallpaper
    { page: "wallpaper", pageLabel: "Wallpaper", group: "Library", label: "Wallpaper", key: "wall", terms: "desktop image background picture online wallhaven download" },
    { page: "wallpaper", pageLabel: "Wallpaper", group: "Folder", label: "Folder", key: "wallDir", terms: "directory pictures" },
    { page: "wallpaper", pageLabel: "Wallpaper", group: "Rotation", label: "Rotate", key: "shuffle", terms: "shuffle slideshow interval" },

    // Bar
    { page: "bar", pageLabel: "Bar", group: "Layout", label: "Position", key: "position", terms: "top bottom edge placement" },
    { page: "bar", pageLabel: "Bar", group: "Layout", label: "Style", key: "barStyle", terms: "hug floating attached edge shape" },
    { page: "bar", pageLabel: "Bar", group: "Layout", label: "Height", key: "barHeight", terms: "size thickness compact classic default roomy custom preset" },
    { page: "bar", pageLabel: "Bar", group: "Layout", label: "Edge gap", key: "gap", terms: "margin floating style only" },
    { page: "bar", pageLabel: "Bar", group: "Layout", label: "Corner radius", key: "barRadius", terms: "rounding floating style only" },
    { page: "bar", pageLabel: "Bar", group: "Background", label: "Bar background", key: "barColorMode", terms: "menubar color custom black white graphite slate macos hue" },
    { page: "bar", pageLabel: "Bar", group: "Behavior", label: "Auto-hide", key: "autoHide", terms: "hide idle reveal" },
    { page: "bar", pageLabel: "Bar", group: "Behavior", label: "Reserve space", key: "exclusive", terms: "exclusive zone tiled windows" },

    // Bar widgets and their options
    { page: "plugins", pageLabel: "Omarchy plugins", group: "Add a plugin", label: "Browse plugins", key: "", terms: "plugins.omarchy.org directory marketplace community find discover website" },
    { page: "plugins", pageLabel: "Omarchy plugins", group: "Add a plugin", label: "Source", key: "", terms: "install git url local path add omarchy plugin add command paste trust" },
    { page: "plugins", pageLabel: "Omarchy plugins", group: "Installed", label: "Installed plugins", key: "", terms: "enable disable update preview clone remove omarchy manage" },
    { page: "bar", pageLabel: "Bar", group: "Widgets", label: "Arrange widgets", key: "", terms: "drag order left center right lane module preview move remove menu notification group grouping status pill separate" },
    { page: "bar", pageLabel: "Bar", group: "Widgets", label: "Add widgets", key: "", terms: "tray plugin enable disable remove toggle module clock weather notes battery workspaces media" },
    { page: "bar", pageLabel: "Bar", group: "Indicators", label: "Clock-side actions", key: "", terms: "indicator dictate recording ocr scan text clipboard reminder night light do not disturb dnd stay awake idle inhibit order startup duration" },
    { page: "bar", pageLabel: "Bar", group: "Notes", label: "AI note titles", key: "", terms: "codex claude model provider effort reasoning generate regenerate privacy" },
    { page: "bar", pageLabel: "Bar", group: "Weather", label: "Weather location", key: "", widget: "weather", terms: "clock city place search country region coordinates latitude longitude forecast" },
    { page: "bar", pageLabel: "Bar", group: "Model Usage", label: "Model Usage", key: "", widget: "modelusage", terms: "ai claude codex kimi quota limits reset percentage providers cliproxy proxy accounts credentials cost tokens t3 refresh warning critical" },

    { page: "bar", pageLabel: "Bar", group: "Control Center", label: "Control Center widget", key: "", widget: "control", terms: "fedora button move drag reorder show hide drawer" },

    // Control Center (also searchable by its former Drawer name)
    { page: "bar", pageLabel: "Bar", widget: "control", group: "Tabs", label: "Tab order", key: "", terms: "drawer reorder overview sound network bluetooth power notifications usage" },
    { page: "bar", pageLabel: "Bar", widget: "control", group: "Overview", label: "Overview contents", key: "", terms: "drawer now playing sliders tiles updates cpu ram temperature system stats" },
    { page: "bar", pageLabel: "Bar", widget: "control", group: "Behavior", label: "Open on hover", key: "drawerHover", terms: "drawer hover switch glyph menu" },
    { page: "bar", pageLabel: "Bar", widget: "control", group: "Behavior", label: "Width", key: "drawerWidth", terms: "drawer size wide" },

    // Notifications
    { page: "notifications", pageLabel: "Notifications", group: "Behavior", label: "Do Not Disturb", key: "notifDnd", terms: "dnd silence mute focus" },
    { page: "notifications", pageLabel: "Notifications", group: "Behavior", label: "Quiet hours", key: "notifQuiet", terms: "night schedule silence" },
    { page: "notifications", pageLabel: "Notifications", group: "Behavior", label: "Duration", key: "notifDuration", terms: "toast timeout seconds" },
    { page: "notifications", pageLabel: "Notifications", group: "Behavior", label: "Position", key: "notifPosition", terms: "toast corner top bottom" },
    { page: "notifications", pageLabel: "Notifications", group: "Style", label: "Density", key: "notifDensity", terms: "compact roomy toast" },
    { page: "notifications", pageLabel: "Notifications", group: "Style", label: "App icons", key: "notifIcons", terms: "sender icon toast" },
    { page: "notifications", pageLabel: "Notifications", group: "Style", label: "Timeout progress", key: "notifProgress", terms: "countdown bar toast" },
    { page: "notifications", pageLabel: "Notifications", group: "Style", label: "Body preview", key: "notifBodyLines", terms: "lines text toast" },

    // Formats, touchpad, night light and power (the old System page)
    { page: "region", pageLabel: "Region & formats", group: "Formats", label: "Clock", key: "clock24", terms: "24 12 hour time format" },
    { page: "region", pageLabel: "Region & formats", group: "Formats", label: "Temperature", key: "unit", terms: "celsius fahrenheit weather unit" },
    { page: "touchpad", pageLabel: "Touchpad", group: "Touchpad", label: "Scroll speed", key: "scrollFactor", terms: "touchpad mouse wheel input" },
    { page: "displays", pageLabel: "Displays", group: "Night light", label: "Night light", key: "nightLight", terms: "blue light hyprsunset" },
    { page: "displays", pageLabel: "Displays", group: "Night light", label: "Warmth", key: "warmth", terms: "kelvin tint blue light" },
    { page: "power", pageLabel: "Power", group: "Idle", label: "Lock screen", key: "idleLockMins", terms: "timeline idle timeout auto lock hypridle power" },
    { page: "power", pageLabel: "Power", group: "Idle", label: "Screen off", key: "idleScreenOffMins", terms: "timeline idle timeout display dpms blank monitor power" },
    { page: "power", pageLabel: "Power", group: "Idle", label: "Suspend", key: "idleSuspendMins", terms: "timeline idle timeout sleep suspend power" },
    { page: "power", pageLabel: "Power", group: "Idle", label: "Only on battery", key: "idleSuspendBatteryOnly", terms: "idle suspend sleep battery plugged in ac power" },
    { page: "power", pageLabel: "Power", group: "Stay awake", label: "Duration", key: "", terms: "idle inhibit caffeine sleep" },
    { page: "power", pageLabel: "Power", group: "Stay awake", label: "Bar indicator", key: "", terms: "stay awake indicator sign-in widget options" },
    { page: "notifications", pageLabel: "Notifications", group: "On-screen display", label: "Placement", key: "osd", terms: "osd volume brightness popup overlay" },
    { page: "about", pageLabel: "About", group: "Recovery points", label: "Recovery points", key: "", terms: "snapshot restore rollback undo update btrfs boot menu grub recovery" },

    // About
    { page: "about", pageLabel: "About", group: "Shell health", label: "Status", key: "", terms: "service deployment journal pid" },
    { page: "about", pageLabel: "About", group: "Shell health", label: "Last deploy check", key: "", terms: "deploy check refresh health" },
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
