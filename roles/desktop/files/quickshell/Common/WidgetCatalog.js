// What each bar widget is called on screen.
//
// The ids stay where they were: SettingsHelpers.MODULE_IDS is the schema the
// settings file is written in terms of, and renaming those would need a
// migration for no gain the user can see. This file owns only the words, so
// `wifi` can present itself as "Network" without touching a stored key.
//
// It exists as its own file because two surfaces now name a widget: the
// settings list, and the proxy that follows the pointer when a widget is
// dragged along the bar itself. Reading both from one table is what keeps
// them from drifting apart.
//
//   name    the full label — settings rows, drag proxies, announcements
//   short   the miniature label for the settings page's bar preview
//   tag     when the widget shows itself, when that is not "always"
//   detail  whether it has detail text the bar may compact away

var WIDGETS = {
    ws: { name: "Workspaces", short: "Workspaces", glyph: "view_quilt", description: "Switch between your workspaces." },
    media: { name: "Media", short: "Media", tag: "while playing", detail: true, glyph: "music_note", description: "See the current track and control playback." },
    indicators: { name: "Indicators", short: "Indicators", tag: "clock-side", glyph: "tune", description: "Quick actions and recording indicators beside the clock." },
    clock: { name: "Clock", short: "Clock", detail: true, glyph: "schedule", description: "Time, date, and calendar." },
    weather: { name: "Weather", short: "Weather", detail: true, glyph: "cloud", description: "Local conditions and forecast." },
    notes: { name: "Notes", short: "Notes", glyph: "edit_note", description: "Capture and revisit your notes." },
    t3: { name: "T3 Code", short: "T3 Code", detail: true, glyph: "code", description: "Follow T3 Code sessions." },
    hermes: { name: "Hermes Agent", short: "Hermes Agent", detail: true, glyph: "smart_toy", description: "Follow Hermes Agent activity." },
    gh: { name: "GitHub", short: "GitHub", detail: true, glyph: "code", description: "Watch GitHub repositories and activity." },
    updates: { name: "Updates", short: "Updates", tag: "when pending", detail: true, glyph: "update", description: "Check software updates and installation progress." },
    tray: { name: "System tray", short: "System tray", tag: "when populated", glyph: "apps", description: "Access background applications." },
    notifications: { name: "Notifications", short: "Notifications", detail: true, glyph: "notifications", description: "Open notification history and unread messages." },
    vol: { name: "Volume", short: "Volume", detail: true, glyph: "volume_up", description: "Adjust volume and audio devices." },
    wifi: { name: "Network", short: "Network", glyph: "wifi", description: "Manage network connections." },
    bt: { name: "Bluetooth", short: "Bluetooth", tag: "when connected", glyph: "bluetooth", description: "Manage connected Bluetooth devices." },
    batt: { name: "Battery", short: "Battery", tag: "on laptops", detail: true, glyph: "battery_full", description: "Monitor battery charge and power status." },
    control: { name: "Control Center", short: "Control Center", glyph: "tune", description: "Open Control Center from the Fedora button. Configure its tabs, overview, and behavior." }
};

// Never null: a widget id that outlived its catalog entry still has to draw a
// settings row and a drag proxy, and the raw id reads better there than a
// blank label would.
function widget(id) {
    return WIDGETS[id] || { name: id, short: id };
}

function widgetName(id) {
    return widget(id).name;
}

var exported = {
    WIDGETS: WIDGETS,
    widget: widget,
    widgetName: widgetName
};

if (typeof module !== "undefined" && module.exports)
    module.exports = exported;
