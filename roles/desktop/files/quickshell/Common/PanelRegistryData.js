// Every popout panel the shell can open, described once.
//
// Four hand-maintained key spaces used to disagree: Popouts' island map, the
// popout host's source map, the `registerPanel()` calls scattered through the
// bar modules, and the module ids in SettingsHelpers. Adding a panel meant
// remembering all four, and the Tailscale popout closing on any settings
// change was exactly what happens when you don't — it is in the first three
// but owned by no module, so the bar's "did my module go away" sweep closed
// it. panel-registry.test.cjs now fails when the maps drift apart.
//
// Keep this file free of Qt APIs so the test can run under Node.
//
// Fields:
//   name       the popout name, as passed to Popouts.openPanel() and
//              `cybexos-runtime ipc popouts toggle <name>` (the shell runs
//              by path, so a bare `qs ipc call` finds no config)
//   island     which bar section it hangs under when no caller says otherwise
//   source     the view, relative to the shell root (the popout host makes it
//              absolute against Quickshell.shellDir)
//   moduleId   the bar module that owns it, or "" for panels no module can
//              open. An owner-less panel must be left alone by the bar's
//              module sweep — that is the Tailscale bug above.
//
// Flags, all defaulting false/empty, each replacing a hardcoded name check:
//   centerAnchored       ignores its opener's anchor and stays centred on the
//                        bar, re-centring when the bar's geometry changes
//   fillsBody            its view owns the whole popout body rather than
//                        being laid out inside the standard padding
//   attached             the surface sits flush against the bar with no gap,
//                        retaining shared rounded corners (the edge drawer,
//                        the Day sheet)
//   edge                 "right" pins the surface to the screen edge instead
//                        of centring it on its trigger (the edge drawer)
//   tab                  which Control Dashboard tab this name presents. Every
//                        name that routes into Popovers/Drawer/DrawerPopover.qml
//                        names one, which is also how the drawer knows what to
//                        show

var DRAWER_SOURCE = "Popovers/Drawer/DrawerPopover.qml";
var DAY_SHEET_SOURCE = "Popovers/DaySheetPopover.qml";

var PANELS = [
    // The Control Dashboard. One surface, six tabs; each established status
    // popout name stays a valid IPC target and presents its tab of the drawer.
    // The Fedora button is fixed bar furniture rather than a configurable
    // module. It still registers the panel's live anchor, but `control` stays
    // ownerless so module enablement and movement never close it.
    { name: "control", island: "right", moduleId: "", source: DRAWER_SOURCE, attached: true, edge: "right", tab: "overview" },
    { name: "audio", island: "right", moduleId: "vol", source: DRAWER_SOURCE, attached: true, edge: "right", tab: "sound" },
    { name: "wifi", island: "right", moduleId: "wifi", source: DRAWER_SOURCE, attached: true, edge: "right", tab: "network" },
    { name: "bluetooth", island: "right", moduleId: "bt", source: DRAWER_SOURCE, attached: true, edge: "right", tab: "bluetooth" },
    { name: "tailscale", island: "right", moduleId: "", source: DRAWER_SOURCE, attached: true, edge: "right", tab: "network" },
    { name: "battery", island: "right", moduleId: "batt", source: DRAWER_SOURCE, attached: true, edge: "right", tab: "power" },
    { name: "notifications", island: "right", moduleId: "notifications", source: DRAWER_SOURCE, attached: true, edge: "right", tab: "notifications" },
    { name: "usage", island: "right", moduleId: "usage", source: DRAWER_SOURCE, attached: true, edge: "right", tab: "usage" },

    // Updates keeps its purpose-built state machine and transaction transcript
    // in a dedicated drawer. It uses the redesign's attached right-edge
    // geometry, but is deliberately not a Control Dashboard tab.
    { name: "updates", island: "right", moduleId: "updates", source: "Popovers/UpdatesPopover.qml", attached: true, edge: "right" },

    // The Day sheet: one view shared by the clock and the weather pill.
    // centerAnchored so it opens in the same centred spot no matter which of
    // the two triggers it — hovering between them must not move the surface.
    { name: "calendar", island: "center", moduleId: "clock", source: DAY_SHEET_SOURCE, attached: true, centerAnchored: true },
    { name: "weather", island: "center", moduleId: "weather", source: DAY_SHEET_SOURCE, attached: true, centerAnchored: true },

    { name: "notes", island: "center", moduleId: "notes", source: "Popovers/NotesPopover.qml" },

    { name: "reminders", island: "center", moduleId: "indicators", source: "Popovers/ReminderPopover.qml" },
    { name: "media", island: "left", moduleId: "media", source: "Popovers/MediaPopover.qml" },
    { name: "t3code", island: "right", moduleId: "t3", source: "Popovers/T3CodePopover.qml", attached: true },
    { name: "hermes", island: "right", moduleId: "hermes", source: "Popovers/HermesPopover.qml" },
    { name: "github", island: "right", moduleId: "gh", source: "Popovers/GitHubPopover.qml" },
    { name: "overflow", island: "right", moduleId: "", source: "Popovers/OverflowPopover.qml" },

    // Compatibility route for bar actions and `popouts open settings` IPC.
    // Popouts forwards it to the independent window before mapping a popout.
    {
        name: "settings",
        island: "center",
        moduleId: "",
        source: "Settings/SettingsView.qml"
    }
];

// Bar modules that own no panel of their own. `ws` has no detail view and
// `tray` opens each item's own menu. Listed so the test can insist the module
// id and panel spaces account for each other completely rather than silently
// tolerating a typo'd moduleId.
var PANEL_LESS_MODULES = ["ws", "tray"];

var SETTINGS = "settings";
var NOTES = "notes";

function byName(name) {
    for (var i = 0; i < PANELS.length; i++) {
        if (PANELS[i].name === name)
            return PANELS[i];
    }
    return null;
}

function names() {
    return PANELS.map(function (p) { return p.name; });
}

function island(name) {
    var panel = byName(name);
    return panel ? panel.island : "right";
}

function moduleFor(name) {
    var panel = byName(name);
    return panel ? panel.moduleId : "";
}

function panelForModule(moduleId) {
    for (var i = 0; i < PANELS.length; i++) {
        if (PANELS[i].moduleId === moduleId && moduleId !== "")
            return PANELS[i].name;
    }
    return "";
}

// True when no bar module can own this panel, so the bar's sweep for
// "the module behind the open popout went away" must skip it.
function ownerless(name) {
    return moduleFor(name) === "";
}

function centerAnchored(name) {
    var panel = byName(name);
    return !!(panel && panel.centerAnchored);
}

function attached(name) {
    var panel = byName(name);
    return !!(panel && panel.attached);
}

function edge(name) {
    var panel = byName(name);
    return panel && panel.edge ? panel.edge : "";
}

function drawerTab(name) {
    var panel = byName(name);
    return panel && panel.tab ? panel.tab : "";
}

// The drawer's own tab strip navigates by reopening the panel name that
// presents the wanted tab, so the popout host, the bar's held states and IPC
// all stay in one name space. First declaration wins, which keeps the strip
// on the canonical names (control/audio/wifi/battery/notifications/usage).
function nameForTab(tab) {
    for (var i = 0; i < PANELS.length; i++) {
        if (PANELS[i].tab === tab)
            return PANELS[i].name;
    }
    return "";
}

function fillsBody(name) {
    var panel = byName(name);
    return !!(panel && panel.fillsBody);
}

// { name: island } and { name: source }, for the QML properties that want a
// plain map to index rather than a call per lookup.
function islandMap() {
    var out = {};
    PANELS.forEach(function (p) { out[p.name] = p.island; });
    return out;
}

function sourceMap(prefix) {
    var base = prefix === undefined ? "" : prefix;
    var out = {};
    PANELS.forEach(function (p) { out[p.name] = base + p.source; });
    return out;
}

var exported = {
    PANELS: PANELS,
    PANEL_LESS_MODULES: PANEL_LESS_MODULES,
    SETTINGS: SETTINGS,
    NOTES: NOTES,
    byName: byName,
    names: names,
    island: island,
    moduleFor: moduleFor,
    panelForModule: panelForModule,
    ownerless: ownerless,
    centerAnchored: centerAnchored,
    attached: attached,
    edge: edge,
    drawerTab: drawerTab,
    nameForTab: nameForTab,
    fillsBody: fillsBody,
    islandMap: islandMap,
    sourceMap: sourceMap
};

if (typeof module !== "undefined" && module.exports)
    module.exports = exported;
