// The editor models configured widgets, including those hidden by runtime rules.
// Plugin blocks match Bar.qml: before built-ins on left/right, after in center.
function catalog(mods, plugins, metadata) {
    var result = [];
    ["left", "center", "right"].forEach(function(section) {
        (mods[section] || []).forEach(function(entry, index) {
            var meta = metadata[entry.id] || { name: entry.id };
            result.push({ key: entry.id, id: entry.id, name: meta.name,
                description: meta.description || "", glyph: meta.glyph || "widgets",
                origin: "Built-in", plugin: false, section: section, index: index,
                enabled: entry.on, detail: meta.detail === true });
        });
    });
    (plugins || []).forEach(function(widget) {
        result.push({ key: "plugin:" + widget.key, id: widget.id,
            pluginKey: widget.key, name: widget.name + (widget.instanceName ? " · " + widget.instanceName : ""),
            description: (widget.manifest || {}).description || "A widget provided by " + widget.name,
            glyph: "extension", origin: widget.name + " plugin", plugin: true,
            section: widget.section || "right", enabled: widget.enabled, descriptor: widget });
    });
    return result;
}

function sectionEntries(entries, section) {
    var enabled = entries.filter(function(entry) { return entry.enabled && entry.section === section; });
    var builtins = enabled.filter(function(entry) { return !entry.plugin; });
    var plugins = enabled.filter(function(entry) { return entry.plugin; });
    return section === "center" ? builtins.concat(plugins) : plugins.concat(builtins);
}

function search(entries, query, filter) {
    var words = query.toLowerCase().trim().split(/\s+/).filter(Boolean);
    return entries.filter(function(entry) {
        if (filter === "available" && entry.enabled) return false;
        if (filter === "plugins" && !entry.plugin) return false;
        var haystack = [entry.name, entry.description, entry.origin].join(" ").toLowerCase();
        return words.every(function(word) { return haystack.indexOf(word) !== -1; });
    });
}

// Read a wrapped grid in row-major order. Outside/header/empty targets still
// resolve to valid insertion gaps, including the short final row.
function gridGap(count, columns, width, height, spacing, x, y) {
    if (count <= 0 || y < 0) return 0;
    var row = Math.max(0, Math.floor(y / (height + spacing)));
    var col = Math.max(0, Math.min(columns, Math.floor((x + width / 2 + spacing) / (width + spacing))));
    return Math.min(count, row * columns + col);
}

// Translate a visible insertion gap to the persisted list, preserving disabled
// entries and preventing a preview from promising unsupported interleaving.
function dropPlan(entries, mods, moving, section, gap) {
    var visible = sectionEntries(entries, section);
    var peers = visible.filter(function(entry) { return entry.plugin === moving.plugin; });
    var before = visible.slice(0, gap).filter(function(entry) { return entry.plugin === moving.plugin; }).length;
    var anchor = peers[before];
    var index = moving.plugin ? before : anchor ? anchor.index : mods[section].length;
    var offset = section === "center" ? (moving.plugin ? visible.length - peers.length : 0)
        : (moving.plugin ? 0 : visible.length - peers.length);
    return { section: section, index: index, gap: offset + before };
}

function status(entry, state) {
    if (!entry.enabled) return "Available to add · settings are kept";
    if (entry.plugin) return entry.descriptor.error || "On your bar · visibility controlled by plugin";
    switch (entry.id) {
    case "media": return state.media ? "Ready · media loaded" : "Hidden · no media loaded";
    case "weather": return !state.weather ? "Hidden · waiting for weather"
        : state.weatherLocation === false ? "On your bar · needs a location"
        : "Ready · weather loaded";
    case "bt": return state.bluetooth ? "Ready · device connected" : "Hidden · no connected device";
    case "batt": return state.battery ? "Ready · battery detected" : "Hidden · no battery detected";
    case "updates": return state.updates ? "Ready · update activity" : "Hidden · no pending updates";
    case "tray": return state.tray ? "Ready · tray items present" : "Hidden · system tray empty";
    case "indicators": return "Visibility follows your indicator preferences";
    default: return "On your bar";
    }
}

function visibility(id) {
    return ({ media: "When media is loaded", weather: "When weather is available",
        bt: "When a device is connected", batt: "When a battery is detected",
        updates: "When updates need attention", tray: "When tray items are present" })[id] || "Always available";
}

var exported = { catalog: catalog, sectionEntries: sectionEntries, search: search, gridGap: gridGap,
    dropPlan: dropPlan, status: status, visibility: visibility };
if (typeof module !== "undefined" && module.exports) module.exports = exported;
