// Pure layout, filtering and keyboard rules for the window overview
// (OverviewView.qml, Super+Tab). The view reads Hyprland's objects into plain
// records and asks this module where everything goes, so the grid arithmetic,
// the window placement inside a workspace and the arrow-key rules are tested
// under Node without a compositor. Keep this file free of Qt APIs.

function finite(value, fallback) {
    var number = Number(value);
    return isFinite(number) ? number : fallback;
}

// Hyprland numbers special workspaces (the scratchpad and any other
// `special:` name) from -99 up to -2 and names them "special" or
// "special:<name>"; -1 is its invalid id. Special workspaces are overlays
// toggled over a real one rather than places, so the overview leaves them
// out. Named regular workspaces (ids from -1337 down) stay in.
function isSpecialWorkspace(workspace) {
    if (!workspace)
        return true;
    var id = finite(workspace.id, 0);
    var name = String(workspace.name === undefined || workspace.name === null ? "" : workspace.name);
    return /^special(?::|$)/.test(name) || id === 0 || (id < 0 && id >= -99);
}

// Positive ids first in number order, then named workspaces in the order
// Hyprland created them (their ids count down from -1337).
function compareWorkspaces(a, b) {
    if (a.id > 0 && b.id > 0)
        return a.id - b.id;
    if (a.id > 0 || b.id > 0)
        return a.id > 0 ? -1 : 1;
    return b.id - a.id;
}

// The lowest positive id nothing uses. A gap is filled first, which keeps
// the window reachable with Super+number.
function newWorkspaceId(ids) {
    var taken = {};
    (Array.isArray(ids) ? ids : []).forEach(function(id) { taken[id] = true; });
    var candidate = 1;
    while (taken[candidate])
        candidate++;
    return candidate;
}

// The overview's workspaces: every occupied workspace plus the ones shown on
// a monitor right now (an empty current workspace is still where you are),
// and one empty "new workspace" slot last.
//
//   workspaces: [{ id, name, monitor, active }]
//   windows:    [{ address, workspaceId }]  (special workspaces already out)
function workspaceEntries(workspaces, windows, options) {
    var counts = {};
    var windowWorkspaces = {};
    (Array.isArray(windows) ? windows : []).forEach(function(window) {
        if (window && window.workspaceId !== undefined) {
            counts[window.workspaceId] = (counts[window.workspaceId] || 0) + 1;
            if (!windowWorkspaces[window.workspaceId] || window.workspaceKind === "named")
                windowWorkspaces[window.workspaceId] = { id: window.workspaceId,
                    name: window.workspaceName, kind: window.workspaceKind, workspaceName: window.workspaceName };
        }
    });
    var seen = {};
    var entries = [];
    (Array.isArray(workspaces) ? workspaces : []).forEach(function(workspace) {
        if (isSpecialWorkspace(workspace))
            return;
        var id = finite(workspace.id, 0);
        if (windowWorkspaces[id] && windowWorkspaces[id].kind === "named")
            workspace = Object.assign({}, workspace, windowWorkspaces[id]);
        var count = counts[id] || 0;
        if (seen[id] || (count === 0 && !workspace.active))
            return;
        seen[id] = true;
        entries.push({
            id: id,
            name: String(workspace.name || id),
            workspaceName: String(workspace.workspaceName !== undefined ? workspace.workspaceName : workspace.name || id),
            kind: workspace.kind || (workspace.name && workspace.name !== String(id) ? "named" : id > 0 ? "numbered" : "named"),
            monitor: String(workspace.monitor || ""),
            windows: count,
            isNew: false
        });
    });
    // Hyprland reports a window's move before its workspace list catches up;
    // a window must never vanish because its workspace is momentarily unknown.
    Object.keys(counts).forEach(function(key) {
        var id = Number(key);
        if (seen[id] || isSpecialWorkspace({ id: id, name: "" }))
            return;
        seen[id] = true;
        var native = windowWorkspaces[id];
        var name = String(native.name || id);
        entries.push({ id: id, name: name, workspaceName: name,
            kind: native.kind || (name !== String(id) || id < 0 ? "named" : "numbered"),
            monitor: "", windows: counts[key], isNew: false });
    });
    entries.sort(compareWorkspaces);
    entries.push({
        // With the module present only it may allocate IDs. The fallback
        // keeps the existing shared behavior when no snapshot is available.
        id: options && options.authoritative ? 0
            : newWorkspaceId(entries.map(function(entry) { return entry.id; })),
        name: "",
        monitor: "",
        windows: 0,
        isNew: true
    });
    return entries;
}

// The workspace grid. Each cell is a label line above a tile with the
// monitor's aspect ratio. The column count is the one that gives the largest
// tiles; when the cap makes several equal, the fewest rows win, so a handful
// of workspaces reads as one row. Rows are centred, the last one included.
function gridLayout(count, width, height, aspect, options) {
    var o = options || {};
    var spacing = Math.max(0, finite(o.spacing, 24));
    var label = Math.max(0, finite(o.labelHeight, 24));
    var maxTile = Math.max(1, finite(o.maxTileWidth, Infinity));
    var n = Math.max(0, Math.floor(finite(count, 0)));
    var ratio = finite(aspect, 0) > 0 ? Number(aspect) : 16 / 9;
    var empty = { columns: 0, rows: 0, tileWidth: 0, tileHeight: 0, labelHeight: label, cells: [] };
    if (n === 0 || !(width > 0) || !(height > 0))
        return empty;

    var best = null;
    for (var columns = 1; columns <= n; columns++) {
        var rows = Math.ceil(n / columns);
        var byWidth = (width - spacing * (columns - 1)) / columns;
        var byHeight = ((height - spacing * (rows - 1)) / rows - label) * ratio;
        var tile = Math.min(byWidth, byHeight, maxTile);
        if (!(tile > 0))
            continue;
        if (best === null || tile > best.tile + 0.01
                || (Math.abs(tile - best.tile) <= 0.01 && rows < best.rows))
            best = { columns: columns, rows: rows, tile: tile };
    }
    if (best === null)
        return empty;

    var tileWidth = Math.max(1, Math.floor(best.tile));
    var tileHeight = Math.max(1, Math.floor(tileWidth / ratio));
    var cellHeight = label + tileHeight;
    var totalHeight = best.rows * cellHeight + (best.rows - 1) * spacing;
    var top = Math.max(0, (height - totalHeight) / 2);
    var cells = [];
    for (var index = 0; index < n; index++) {
        var row = Math.floor(index / best.columns);
        var column = index % best.columns;
        var inRow = row === best.rows - 1 ? n - row * best.columns : best.columns;
        var rowWidth = inRow * tileWidth + (inRow - 1) * spacing;
        var left = (width - rowWidth) / 2;
        cells.push({
            x: Math.round(left + column * (tileWidth + spacing)),
            y: Math.round(top + row * (cellHeight + spacing)),
            width: tileWidth,
            height: cellHeight,
            tileY: label,
            tileHeight: tileHeight
        });
    }
    return {
        columns: best.columns,
        rows: best.rows,
        tileWidth: tileWidth,
        tileHeight: tileHeight,
        labelHeight: label,
        cells: cells
    };
}

// A box of `aspect` centred in width × height: a workspace on a monitor of
// another shape than the overview's own sits letterboxed in its cell.
function fitAspect(width, height, aspect) {
    var w = Math.max(0, finite(width, 0));
    var h = Math.max(0, finite(height, 0));
    var ratio = finite(aspect, 0) > 0 ? Number(aspect) : (h > 0 ? w / h : 1);
    var fitWidth = Math.min(w, h * ratio);
    var fitHeight = ratio > 0 ? fitWidth / ratio : h;
    return {
        x: Math.round((w - fitWidth) / 2),
        y: Math.round((h - fitHeight) / 2),
        width: Math.round(fitWidth),
        height: Math.round(fitHeight)
    };
}

function pair(value) {
    return Array.isArray(value) && value.length >= 2
        && isFinite(Number(value[0])) && isFinite(Number(value[1]))
        ? [Number(value[0]), Number(value[1])] : null;
}

// Where each window sits inside a workspace tile of width × height, scaled
// from its layout geometry (`at`/`size` from `hyprctl clients`, global
// logical coordinates) relative to its monitor. Rects are clamped into the
// tile and kept at least `minSize` so a sliver stays clickable.
//
// Stacking follows the screen: tiled windows under floating ones, a
// fullscreen window over everything, and within each the more recently
// focused (lower focusHistoryID) on top. Windows Hyprland has not reported
// geometry for yet — opened since the last refresh — share the tile in a
// small grid above the rest, so a window is never invisible.
//
// Returns { address: { x, y, width, height, z } }.
function windowRects(windows, monitor, width, height, options) {
    var tileWidth = Math.max(1, finite(width, 1));
    var tileHeight = Math.max(1, finite(height, 1));
    var minSize = Math.max(1, finite(options && options.minSize, 12));
    var mx = finite(monitor && monitor.x, 0);
    var my = finite(monitor && monitor.y, 0);
    var mw = Math.max(1, finite(monitor && monitor.width, tileWidth));
    var mh = Math.max(1, finite(monitor && monitor.height, tileHeight));
    var sx = tileWidth / mw;
    var sy = tileHeight / mh;

    function clampSpan(start, length, limit) {
        var from = Math.max(0, Math.min(limit, start));
        var to = Math.max(0, Math.min(limit, start + length));
        var span = Math.min(limit, Math.max(minSize, to - from));
        if (from + span > limit)
            from = Math.max(0, limit - span);
        return { from: from, span: span };
    }

    var placed = [];
    var unplaced = [];
    (Array.isArray(windows) ? windows : []).forEach(function(window) {
        if (!window || !window.address)
            return;
        var at = pair(window.at);
        var size = pair(window.size);
        var layer = window.fullscreen ? 2 : window.floating ? 1 : 0;
        var focus = finite(window.focusHistoryID, 1000000);
        if (window.fullscreen) {
            placed.push({ address: window.address, layer: layer, focus: focus,
                x: 0, y: 0, width: tileWidth, height: tileHeight });
            return;
        }
        if (at === null || size === null || size[0] <= 0 || size[1] <= 0) {
            unplaced.push(window);
            return;
        }
        var horizontal = clampSpan((at[0] - mx) * sx, size[0] * sx, tileWidth);
        var vertical = clampSpan((at[1] - my) * sy, size[1] * sy, tileHeight);
        placed.push({ address: window.address, layer: layer, focus: focus,
            x: horizontal.from, y: vertical.from,
            width: horizontal.span, height: vertical.span });
    });

    placed.sort(function(a, b) {
        return a.layer - b.layer || b.focus - a.focus;
    });
    var out = {};
    var z = 1;
    placed.forEach(function(rect) {
        out[rect.address] = {
            x: Math.round(rect.x), y: Math.round(rect.y),
            width: Math.round(rect.width), height: Math.round(rect.height), z: z++
        };
    });

    if (unplaced.length > 0) {
        var columns = Math.ceil(Math.sqrt(unplaced.length));
        var rows = Math.ceil(unplaced.length / columns);
        var cellWidth = tileWidth / columns;
        var cellHeight = tileHeight / rows;
        var inset = 0.08;
        unplaced.forEach(function(window, index) {
            var column = index % columns;
            var row = Math.floor(index / columns);
            out[window.address] = {
                x: Math.round(column * cellWidth + cellWidth * inset),
                y: Math.round(row * cellHeight + cellHeight * inset),
                width: Math.round(Math.max(minSize, cellWidth * (1 - 2 * inset))),
                height: Math.round(Math.max(minSize, cellHeight * (1 - 2 * inset))),
                z: z++
            };
        });
    }
    return out;
}

// The cell under a point in grid coordinates, label line included so a drop
// on a workspace's name lands too. -1 when the point is between cells.
function cellAt(cells, x, y) {
    var list = Array.isArray(cells) ? cells : [];
    for (var index = 0; index < list.length; index++) {
        var cell = list[index];
        if (x >= cell.x && x < cell.x + cell.width && y >= cell.y && y < cell.y + cell.height)
            return index;
    }
    return -1;
}

// Filter scores by address for the typed query. `scoreFn(title, class,
// query, active)` is LauncherProviders.windowScore, passed in so the overview
// and the launcher's `$` windows provider rank alike. A negative score is a
// miss; with an empty query every window matches.
function filterScores(windows, query, scoreFn) {
    var out = {};
    var q = String(query || "").trim();
    (Array.isArray(windows) ? windows : []).forEach(function(window) {
        if (!window || !window.address)
            return;
        var score = q === "" ? 1 : scoreFn(window.title, window.appClass, q, !!window.activated);
        if (score >= 0)
            out[window.address] = score;
    });
    return out;
}

function firstEnabled(items) {
    for (var index = 0; index < items.length; index++)
        if (items[index].enabled)
            return index;
    return -1;
}

// The selectable windows in reading order — workspace by workspace, then
// top-to-bottom and left-to-right inside each — with their centres in grid
// coordinates. `placements` holds { address, cell, rect } records.
function selectionItems(placements, scores) {
    var list = (Array.isArray(placements) ? placements : []).map(function(placement) {
        var cell = placement.cell;
        var rect = placement.rect;
        return {
            address: placement.address,
            cellIndex: placement.cellIndex,
            cx: cell.x + finite(placement.offsetX, 0) + rect.x + rect.width / 2,
            cy: cell.y + cell.tileY + finite(placement.offsetY, 0) + rect.y + rect.height / 2,
            enabled: !scores || Object.prototype.hasOwnProperty.call(scores, placement.address)
        };
    });
    list.sort(function(a, b) {
        return a.cellIndex - b.cellIndex || a.cy - b.cy || a.cx - b.cx;
    });
    return list;
}

// Arrow-key movement: the nearest enabled window whose centre lies in the
// pressed direction, where drifting sideways costs twice as much as going
// forward. This crosses from one workspace tile into its neighbour naturally.
// With nothing in that direction the selection stays put.
function navigate(items, index, direction) {
    var list = Array.isArray(items) ? items : [];
    if (list.length === 0)
        return -1;
    var current = list[index];
    if (!current || !current.enabled)
        return firstEnabled(list);
    var dx = direction === "left" ? -1 : direction === "right" ? 1 : 0;
    var dy = direction === "up" ? -1 : direction === "down" ? 1 : 0;
    if (dx === 0 && dy === 0)
        return index;
    var best = index;
    var bestCost = Infinity;
    list.forEach(function(item, candidate) {
        if (candidate === index || !item.enabled)
            return;
        var offsetX = item.cx - current.cx;
        var offsetY = item.cy - current.cy;
        var along = dx !== 0 ? offsetX * dx : offsetY * dy;
        if (along <= 0.5)
            return;
        var across = dx !== 0 ? Math.abs(offsetY) : Math.abs(offsetX);
        var cost = along + across * 2;
        if (cost < bestCost) {
            bestCost = cost;
            best = candidate;
        }
    });
    return best;
}

// Tab and Shift+Tab: the next or previous enabled window in reading order,
// wrapping at the ends.
function step(items, index, delta) {
    var list = Array.isArray(items) ? items : [];
    var count = list.length;
    if (count === 0)
        return -1;
    var direction = delta < 0 ? -1 : 1;
    var start = index >= 0 && index < count ? index : (direction > 0 ? -1 : count);
    for (var offset = 1; offset <= count; offset++) {
        var candidate = ((start + direction * offset) % count + count) % count;
        if (list[candidate].enabled)
            return candidate;
    }
    return -1;
}

function indexOfAddress(items, address) {
    var list = Array.isArray(items) ? items : [];
    for (var index = 0; index < list.length; index++)
        if (list[index].address === address)
            return index;
    return -1;
}

// Which window the selection rests on after the windows or the filter
// change: the same window while it is still there and matches; otherwise the
// best filter match when a query is typed, else the focused window, else the
// first match. Returns an address, or "" when nothing matches.
function reselect(items, current, scores, activeAddress, query) {
    var list = Array.isArray(items) ? items : [];
    var at = indexOfAddress(list, current);
    if (at !== -1 && list[at].enabled)
        return current;
    if (String(query || "").trim() !== "" && scores) {
        var best = -1;
        var bestScore = -Infinity;
        list.forEach(function(item, index) {
            if (item.enabled && scores[item.address] > bestScore) {
                bestScore = scores[item.address];
                best = index;
            }
        });
        if (best !== -1)
            return list[best].address;
    }
    var active = indexOfAddress(list, activeAddress);
    if (active !== -1 && list[active].enabled)
        return activeAddress;
    var first = firstEnabled(list);
    return first === -1 ? "" : list[first].address;
}

var exported = {
    isSpecialWorkspace: isSpecialWorkspace,
    compareWorkspaces: compareWorkspaces,
    newWorkspaceId: newWorkspaceId,
    workspaceEntries: workspaceEntries,
    gridLayout: gridLayout,
    fitAspect: fitAspect,
    windowRects: windowRects,
    cellAt: cellAt,
    filterScores: filterScores,
    selectionItems: selectionItems,
    navigate: navigate,
    step: step,
    indexOfAddress: indexOfAddress,
    reselect: reselect
};

if (typeof module !== "undefined" && module.exports)
    module.exports = exported;
