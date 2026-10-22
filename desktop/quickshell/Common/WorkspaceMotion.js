// Workspace geometry and direction selection without Hyprland or Qt state.

var CELL_WIDTH = 22;
var LEADING_MS = 120;
var TRAILING_MS = 300;

// The numbered workspaces among Hyprland's list, ascending. Special
// workspaces such as the scratchpad (special:scratchpad) carry negative ids,
// as do named ones; neither is a numbered slot in the strip.
// Hyprland.workspaces.values is a QML list, array-like but not an Array.
function regularIds(workspaces) {
    var ids = [];
    var count = workspaces && typeof workspaces.length === "number" ? workspaces.length : 0;
    for (var i = 0; i < count; i++) {
        var workspace = workspaces[i];
        var id = workspace ? workspace.id : undefined;
        var name = workspace && typeof workspace.name === "string" ? workspace.name : "";
        if (Number.isInteger(id) && id > 0 && name.indexOf("special:") !== 0)
            ids.push(id);
    }
    return ids.sort(function(a, b) { return a - b; });
}

function visibleIds(slotCount, existingIds, focusedId, hideEmpty) {
    var existing = {};
    (Array.isArray(existingIds) ? existingIds : []).forEach(function(id) {
        if (Number.isInteger(id) && id > 0)
            existing[id] = true;
    });
    var count = Math.max(0, Math.floor(Number(slotCount) || 0));
    var out = [];
    for (var id = 1; id <= count; id++) {
        if (!hideEmpty || existing[id] || id === focusedId)
            out.push(id);
    }
    return out;
}

function indicatorBounds(ids, focusedId) {
    var index = Array.isArray(ids) ? ids.indexOf(focusedId) : -1;
    if (index < 0)
        return null;
    // The classic current-workspace chip is wider than its fixed pointer cell.
    // The pager's 5px side padding absorbs the two-pixel overhang at either end.
    return { left: index * CELL_WIDTH - 2, right: index * CELL_WIDTH + 24 };
}

function edgeDurations(previousId, nextId, animate) {
    if (!animate || !Number.isFinite(previousId) || !Number.isFinite(nextId)
            || previousId <= 0 || nextId <= 0 || previousId === nextId)
        return { left: 0, right: 0, direction: 0 };
    if (nextId > previousId)
        return { left: TRAILING_MS, right: LEADING_MS, direction: 1 };
    return { left: LEADING_MS, right: TRAILING_MS, direction: -1 };
}

var exported = {
    CELL_WIDTH: CELL_WIDTH,
    LEADING_MS: LEADING_MS,
    TRAILING_MS: TRAILING_MS,
    regularIds: regularIds,
    visibleIds: visibleIds,
    indicatorBounds: indicatorBounds,
    edgeDurations: edgeDurations
};

if (typeof module !== "undefined" && module.exports)
    module.exports = exported;
