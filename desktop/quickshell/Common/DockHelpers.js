// Pure visibility, matching, grouping, pinning, click and placement rules for the dock
// (DockWindow.qml). Desktop-entry lookups and Hyprland state stay in
// Common/Dock.qml; this module only sees plain records, so the dock's
// behaviour is tested under Node. Keep it free of Qt APIs.

// A desktop entry id as the settings schema stores it. Keep in step with
// SettingsHelpers.desktopIdsIn, which normalizes the persisted list.
var DESKTOP_ID = /^[A-Za-z0-9][A-Za-z0-9._+-]{0,254}$/;
var MAX_PINS = 32;
var RECENT_LIMIT = 64;

// The shell's own windows (Settings) are part of the desktop, not
// applications to launch or pin.
var SHELL_APP_IDS = ["org.quickshell", "quickshell"];

// Pinned by default until the person pins or unpins something: the default
// browser (read from mimeapps.list), Files and the terminal — the apps the
// Super+B, Super+E and Super+Return bindings open.
var SUGGESTED_PINS = ["org.gnome.Nautilus", "kitty"];

// Use the live workspace identity with the compositor's layout snapshot.
// A stale numbered row must not enable the dock after a workspace is renamed.
function showOnWorkspace(always, live, saved) {
    return always === true || !!(live && saved && live.id === saved.id
        && live.id > 0 && String(live.name) === String(live.id)
        && saved.layout === "floating");
}

// Chromium's URL-app desktop id is <browser>-<host>_<path>-<profile>.
// Its filename replaces slash and other illegal path characters with '_';
// scheme, port, query and fragment do not participate. Match the whole app
// name, so two apps on the same host but different paths stay separate.
function webAppName(url) {
    var parts = String(url || "").match(/^https?:\/\/([^/?#]+)(\/[^?#]*)?(?:[?#].*)?$/i);
    if (!parts || parts[1].indexOf("@") !== -1)
        return "";
    var host = parts[1].toLowerCase().replace(/:\d+$/, "");
    return (host + "_" + (parts[2] || "/")).replace(/[\\/<>:"|?*\x00-\x1f]/g, "_");
}

function webAppEntryId(appId, apps) {
    var match = String(appId || "").match(/^(?:brave|chrome|chromium|msedge)-(.+)$/);
    if (!match)
        return "";
    var matches = (Array.isArray(apps) ? apps : []).filter(function(app) {
        if (!app || !/^[a-z0-9][a-z0-9-]{0,39}$/.test(app.id))
            return false;
        var name = webAppName(app.url);
        return name !== "" && match[1].indexOf(name + "-") === 0
            && /^[A-Za-z0-9_.-]+$/.test(match[1].slice(name.length + 1));
    });
    // URLs differing only by query/port (or sanitized path) are ambiguous.
    return matches.length === 1 ? "nerdos-webapp-" + matches[0].id : "";
}

function validId(id) {
    return typeof id === "string" && DESKTOP_ID.test(id);
}

function uniqueIds(ids) {
    var seen = {};
    var out = [];
    (Array.isArray(ids) ? ids : []).forEach(function(id) {
        if (validId(id) && !seen[id] && out.length < MAX_PINS) {
            seen[id] = true;
            out.push(id);
        }
    });
    return out;
}

function isShellWindow(appId) {
    return SHELL_APP_IDS.indexOf(String(appId || "").toLowerCase()) !== -1;
}

// One dock item per application: its desktop entry when one resolves,
// otherwise its window class. A window with neither stands alone.
function appKey(entryId, appId, address) {
    if (validId(entryId))
        return "app:" + entryId;
    var cls = String(appId || "").trim().toLowerCase();
    return cls !== "" ? "class:" + cls : "window:" + String(address || "");
}

// The window of `addresses` focused most recently, by position in `recent`
// (most recent first); the first window when none has been seen focused.
function mostRecent(addresses, recent) {
    var list = Array.isArray(addresses) ? addresses : [];
    var order = Array.isArray(recent) ? recent : [];
    var best = "";
    var bestIndex = Infinity;
    list.forEach(function(address) {
        var at = order.indexOf(address);
        if (at !== -1 && at < bestIndex) {
            bestIndex = at;
            best = address;
        }
    });
    return best !== "" ? best : (list.length > 0 ? list[0] : "");
}

// The dock's items: pinned apps in pin order, running or not, then the other
// running apps in the order their first window appeared. Each item lists its
// windows in a stable order (for cycling) and the most recent one (for a
// plain click).
//
//   windows: [{ address, appId, entryId }]   (Hyprland toplevel order)
//   pins:    [entryId]
//   recent:  [address]  most recently focused first
function groupApps(windows, pins, recent) {
    var groups = {};
    var order = [];
    uniqueIds(pins).forEach(function(id) {
        var key = appKey(id, "", "");
        groups[key] = { key: key, entryId: id, appId: "", pinned: true, windows: [] };
        order.push(key);
    });
    (Array.isArray(windows) ? windows : []).forEach(function(window) {
        if (!window || !window.address || isShellWindow(window.appId))
            return;
        var key = appKey(window.entryId, window.appId, window.address);
        var group = groups[key];
        if (!group) {
            group = groups[key] = {
                key: key,
                entryId: validId(window.entryId) ? window.entryId : "",
                appId: String(window.appId || ""),
                pinned: false,
                windows: []
            };
            order.push(key);
        }
        if (group.appId === "")
            group.appId = String(window.appId || "");
        if (group.windows.indexOf(window.address) === -1)
            group.windows.push(window.address);
    });
    return order.map(function(key) {
        var group = groups[key];
        group.running = group.windows.length > 0;
        group.recent = mostRecent(group.windows, recent);
        return group;
    });
}

// What a left click on an item does:
//   not running         → launch it (when it has a desktop entry)
//   running, not active → focus its most recent window
//   one of its windows is active → the next of its windows; nothing when
//                         it only has the one
function clickAction(app, activeAddress) {
    if (!app)
        return { kind: "none" };
    var windows = Array.isArray(app.windows) ? app.windows : [];
    if (windows.length === 0)
        return validId(app.entryId) ? { kind: "launch" } : { kind: "none" };
    var at = windows.indexOf(activeAddress);
    if (at === -1)
        return { kind: "focus", address: app.recent || windows[0] };
    if (windows.length === 1)
        return { kind: "none" };
    return { kind: "focus", address: windows[(at + 1) % windows.length] };
}

function pin(pins, id) {
    var list = uniqueIds(pins);
    if (!validId(id) || list.indexOf(id) !== -1 || list.length >= MAX_PINS)
        return list;
    return list.concat([id]);
}

function unpin(pins, id) {
    return uniqueIds(pins).filter(function(pinned) { return pinned !== id; });
}

function isPinned(pins, id) {
    return validId(id) && uniqueIds(pins).indexOf(id) !== -1;
}

// Focus history, most recent first, bounded.
function touchRecent(recent, address, limit) {
    var max = Math.max(1, Number(limit) || RECENT_LIMIT);
    var list = (Array.isArray(recent) ? recent : []).filter(function(entry) {
        return entry !== address;
    });
    if (address)
        list.unshift(address);
    return list.slice(0, max);
}

// The pinned list in effect: the stored one once the person has pinned or
// unpinned anything (an explicit empty list included), the suggestions
// before that.
function effectivePins(stored, explicit, suggestions) {
    return uniqueIds(explicit ? stored : suggestions);
}

// The https handler from a mimeapps.list's [Default Applications] group,
// as a desktop entry id ("" when there is none).
function defaultBrowserId(text) {
    var section = "";
    var found = "";
    String(text || "").split("\n").some(function(raw) {
        var line = raw.trim();
        var header = line.match(/^\[(.+)\]$/);
        if (header) {
            section = header[1];
            return false;
        }
        if (section !== "Default Applications")
            return false;
        var entry = line.match(/^x-scheme-handler\/https\s*=\s*(.*)$/);
        if (!entry)
            return false;
        var first = entry[1].split(";")[0].trim().replace(/\.desktop$/, "");
        found = validId(first) ? first : "";
        return true;
    });
    return found;
}

function suggestedPins(browserId) {
    return uniqueIds([browserId].concat(SUGGESTED_PINS));
}

// Where the dock sits and what it reserves. The layer surface is anchored to
// the bottom edge with no layer-shell margin and always respects other
// surfaces' exclusive zones (ExclusionMode.Normal); `offset` is the distance
// from the surface's bottom to the dock's own bottom edge, drawn inside the
// surface, so the reserved zone never depends on how a compositor counts
// margins.
//
// A bar at the top leaves the bottom edge to the dock, which then reserves
// its height (unless it auto-hides) so tiled windows stay clear of it.
//
// With the bar at the bottom both would claim that edge, and Hyprland stacks
// two exclusive zones on one edge in surface creation order — which a
// hotplug or a bar restyle can change, putting the dock under the bar. So
// there the dock reserves nothing: a zero zone is laid out after every
// exclusive one, which puts the surface above a bar that reserves space. A
// bar that reserves none (auto-hide, or Reserve space off) is stepped over
// by the offset instead. Either way the dock never overlaps the bar.
//
// `stepOver` is the part of the offset that is the bar's slot; auto-hide's
// reveal strip sits just above it, never over the bar.
//
//   { barPosition, barDepth, barZone, dockHeight, gap, autoHide }
//   → { offset, stepOver, exclusiveZone }
function placement(options) {
    var o = options || {};
    var gap = Math.max(0, Number(o.gap) || 0);
    var height = Math.max(0, Number(o.dockHeight) || 0);
    if (o.barPosition === "bottom") {
        var skip = (Number(o.barZone) || 0) > 0 ? 0 : Math.max(0, Number(o.barDepth) || 0);
        return { offset: skip + gap, stepOver: skip, exclusiveZone: 0 };
    }
    return { offset: gap, stepOver: 0, exclusiveZone: o.autoHide ? 0 : gap + height };
}

// The dock's items in drawing order, with "|" between the pinned apps and
// the other running ones when there are both.
function displayKeys(apps) {
    var pinned = [];
    var others = [];
    (Array.isArray(apps) ? apps : []).forEach(function(app) {
        (app.pinned ? pinned : others).push(app.key);
    });
    return pinned.length > 0 && others.length > 0
        ? pinned.concat(["|"], others) : pinned.concat(others);
}

// The context menu's entries for an item, in order.
function menuActions(app, pins) {
    if (!app)
        return [];
    var out = [];
    var launchable = validId(app.entryId);
    var count = Array.isArray(app.windows) ? app.windows.length : 0;
    if (launchable)
        out.push({ id: "launch", label: "New window", glyph: "add" });
    if (launchable)
        out.push(isPinned(pins, app.entryId)
            ? { id: "unpin", label: "Unpin from dock", glyph: "pin" }
            : { id: "pin", label: "Pin to dock", glyph: "pin" });
    if (count > 0)
        out.push({ id: "close", label: count === 1 ? "Close window" : "Close " + count + " windows",
            glyph: "close" });
    return out;
}

var exported = {
    showOnWorkspace: showOnWorkspace,
    webAppName: webAppName,
    webAppEntryId: webAppEntryId,
    DESKTOP_ID: DESKTOP_ID,
    MAX_PINS: MAX_PINS,
    SHELL_APP_IDS: SHELL_APP_IDS,
    SUGGESTED_PINS: SUGGESTED_PINS,
    validId: validId,
    uniqueIds: uniqueIds,
    isShellWindow: isShellWindow,
    appKey: appKey,
    mostRecent: mostRecent,
    groupApps: groupApps,
    clickAction: clickAction,
    pin: pin,
    unpin: unpin,
    isPinned: isPinned,
    touchRecent: touchRecent,
    effectivePins: effectivePins,
    defaultBrowserId: defaultBrowserId,
    suggestedPins: suggestedPins,
    placement: placement,
    displayKeys: displayKeys,
    menuActions: menuActions
};

if (typeof module !== "undefined" && module.exports)
    module.exports = exported;
