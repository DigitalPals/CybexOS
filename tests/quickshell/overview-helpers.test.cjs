const test = require("node:test");
const assert = require("node:assert/strict");
const { load } = require("./shell.cjs");

const H = load("OverviewHelpers.js");
const { windowScore } = load("LauncherProviders.js");

// ---- workspaces ---------------------------------------------------------

test("special workspaces stay out; named regular workspaces stay in", () => {
    assert.equal(H.isSpecialWorkspace({ id: -98, name: "special:scratchpad" }), true);
    assert.equal(H.isSpecialWorkspace({ id: -99, name: "special" }), true);
    assert.equal(H.isSpecialWorkspace({ id: -50, name: "" }), true, "the special id range alone");
    assert.equal(H.isSpecialWorkspace({ id: -1, name: "" }), true, "Hyprland's invalid id");
    assert.equal(H.isSpecialWorkspace({ id: 0, name: "" }), true);
    assert.equal(H.isSpecialWorkspace(null), true);
    assert.equal(H.isSpecialWorkspace({ id: 3, name: "3" }), false);
    assert.equal(H.isSpecialWorkspace({ id: -1337, name: "music" }), false);
});

test("the grid shows occupied and visible workspaces, then one new slot", () => {
    const workspaces = [
        { id: 3, name: "3", monitor: "DP-1", active: false },
        { id: 1, name: "1", monitor: "eDP-1", active: true },
        { id: 2, name: "2", monitor: "eDP-1", active: false },
        { id: 5, name: "5", monitor: "DP-1", active: true },
        { id: -98, name: "special:scratchpad", monitor: "eDP-1", active: false },
        { id: -1337, name: "music", monitor: "eDP-1", active: false }
    ];
    const windows = [
        { address: "a", workspaceId: 1 },
        { address: "b", workspaceId: 3 },
        { address: "c", workspaceId: 3 },
        { address: "d", workspaceId: -1337 }
    ];
    const entries = H.workspaceEntries(workspaces, windows);
    assert.deepEqual(entries.map(entry => entry.id), [1, 3, 5, -1337, 2],
        "empty hidden 2 is skipped, empty current 5 stays, named after numbered, new last");
    assert.deepEqual(entries.map(entry => entry.isNew), [false, false, false, false, true]);
    assert.equal(entries[1].windows, 2);
    assert.equal(entries[2].windows, 0);
    assert.equal(entries[0].monitor, "eDP-1");
    assert.equal(entries.at(-1).id, 2, "the new slot fills the lowest free id");
});

test("a window whose workspace Hyprland has not listed yet still shows", () => {
    const entries = H.workspaceEntries([{ id: 1, name: "1", monitor: "a", active: true }],
        [{ address: "x", workspaceId: 7 }]);
    assert.deepEqual(entries.map(entry => entry.id), [1, 7, 2]);
});

test("the new workspace takes the lowest free positive id", () => {
    assert.equal(H.newWorkspaceId([]), 1);
    assert.equal(H.newWorkspaceId([1, 2, 3]), 4);
    assert.equal(H.newWorkspaceId([1, 3, 4]), 2);
    assert.equal(H.newWorkspaceId([-1337, 2]), 1);
});

// ---- grid ---------------------------------------------------------------

function inside(layout, width, height) {
    for (const cell of layout.cells) {
        assert.ok(cell.x >= 0 && cell.y >= 0, JSON.stringify(cell));
        assert.ok(cell.x + cell.width <= width + 1, `${cell.x}+${cell.width} > ${width}`);
        assert.ok(cell.y + cell.height <= height + 1, `${cell.y}+${cell.height} > ${height}`);
    }
}

test("the grid picks the column count with the largest tiles and stays in bounds", () => {
    const options = { spacing: 20, labelHeight: 30, maxTileWidth: 10000 };
    for (const count of [1, 2, 3, 4, 5, 7, 10, 16]) {
        for (const [width, height] of [[1600, 800], [800, 1200], [3000, 600]]) {
            const layout = H.gridLayout(count, width, height, 16 / 9, options);
            assert.equal(layout.cells.length, count);
            assert.equal(layout.rows, Math.ceil(count / layout.columns));
            inside(layout, width, height);
            // No other column count would have given bigger tiles.
            for (let columns = 1; columns <= count; columns++) {
                const rows = Math.ceil(count / columns);
                const tile = Math.min((width - 20 * (columns - 1)) / columns,
                    ((height - 20 * (rows - 1)) / rows - 30) * 16 / 9);
                assert.ok(layout.tileWidth >= Math.floor(tile) - 1,
                    `${count} in ${width}x${height}: ${columns} columns would fit ${tile}`);
            }
        }
    }
});

test("capped tiles prefer one row, and the last row is centred", () => {
    const capped = H.gridLayout(3, 2400, 1200, 16 / 9,
        { spacing: 20, labelHeight: 30, maxTileWidth: 400 });
    assert.equal(capped.rows, 1, "equal tiles: fewest rows");
    assert.equal(capped.tileWidth, 400);
    const width = 3 * 400 + 2 * 20;
    assert.equal(capped.cells[0].x, Math.round((2400 - width) / 2));

    const layout = H.gridLayout(5, 1000, 700, 16 / 9, { spacing: 20, labelHeight: 30 });
    assert.deepEqual([layout.columns, layout.rows], [2, 3]);
    const lastRow = layout.cells.filter(cell => cell.y === layout.cells.at(-1).y);
    assert.equal(lastRow.length, 1);
    assert.ok(Math.abs(lastRow[0].x - (1000 - layout.tileWidth) / 2) <= 1, "partial row sits centred");
    assert.equal(layout.cells[0].tileY, 30);
    assert.equal(layout.cells[0].height, 30 + layout.tileHeight);
});

test("an empty or degenerate grid is empty rather than NaN", () => {
    assert.deepEqual(H.gridLayout(0, 100, 100, 1, {}).cells, []);
    assert.deepEqual(H.gridLayout(3, 0, 100, 1, {}).cells, []);
    const layout = H.gridLayout(2, 500, 300, NaN, {});
    assert.equal(layout.cells.length, 2, "a bad aspect falls back to 16:9");
    assert.ok(layout.cells.every(cell => Number.isFinite(cell.x) && Number.isFinite(cell.y)));
});

test("a monitor of another shape is letterboxed inside its cell", () => {
    assert.deepEqual(H.fitAspect(400, 225, 16 / 9), { x: 0, y: 0, width: 400, height: 225 });
    const portrait = H.fitAspect(400, 225, 9 / 16);
    assert.equal(portrait.height, 225);
    assert.equal(portrait.width, Math.round(225 * 9 / 16));
    assert.equal(portrait.x, Math.round((400 - portrait.width) / 2));
    const wide = H.fitAspect(400, 225, 32 / 9);
    assert.equal(wide.width, 400);
    assert.equal(wide.y, Math.round((225 - 112.5) / 2));
});

// ---- windows inside a tile ----------------------------------------------

const monitor = { x: 1920, y: 0, width: 1920, height: 1080 };

test("windows scale from their layout geometry relative to their monitor", () => {
    const rects = H.windowRects([
        { address: "left", at: [1920 + 10, 50], size: [940, 1020], focusHistoryID: 1 },
        { address: "right", at: [1920 + 970, 50], size: [940, 1020], focusHistoryID: 0 }
    ], monitor, 384, 216);
    assert.deepEqual(rects.left, { x: 2, y: 10, width: 188, height: 204, z: 1 });
    assert.deepEqual(rects.right, { x: 194, y: 10, width: 188, height: 204, z: 2 },
        "the more recently focused tiled window sits above");
});

test("rects are clamped into the tile and kept clickable", () => {
    const rects = H.windowRects([
        { address: "offscreen", at: [1920 - 400, -100], size: [600, 300] },
        { address: "sliver", at: [1920 + 100, 100], size: [4, 4] },
        { address: "huge", at: [1000, -500], size: [9000, 9000] }
    ], monitor, 384, 216, { minSize: 12 });
    for (const rect of Object.values(rects)) {
        assert.ok(rect.x >= 0 && rect.y >= 0);
        assert.ok(rect.x + rect.width <= 384 && rect.y + rect.height <= 216, JSON.stringify(rect));
        assert.ok(rect.width >= 12 && rect.height >= 12);
    }
    assert.deepEqual([rects.huge.x, rects.huge.y, rects.huge.width, rects.huge.height], [0, 0, 384, 216]);
});

test("stacking follows the screen: tiled, then floating, then fullscreen", () => {
    const rects = H.windowRects([
        { address: "fullscreen", at: [0, 0], size: [10, 10], fullscreen: true, focusHistoryID: 5 },
        { address: "floating", at: [2000, 100], size: [300, 200], floating: true, focusHistoryID: 9 },
        { address: "tiledRecent", at: [1930, 10], size: [900, 900], focusHistoryID: 0 },
        { address: "tiledOld", at: [2900, 10], size: [900, 900], focusHistoryID: 3 }
    ], monitor, 384, 216);
    const order = Object.entries(rects).sort((a, b) => a[1].z - b[1].z).map(([key]) => key);
    assert.deepEqual(order, ["tiledOld", "tiledRecent", "floating", "fullscreen"]);
    assert.deepEqual(rects.fullscreen, { x: 0, y: 0, width: 384, height: 216, z: 4 },
        "fullscreen covers the tile whatever its stale geometry says");
});

test("windows without geometry yet share the tile in a grid on top", () => {
    const rects = H.windowRects([
        { address: "known", at: [1920, 0], size: [1920, 1080] },
        { address: "new1" },
        { address: "new2", at: "junk", size: [0, 0] },
        { address: "new3", size: [100, 100] }
    ], monitor, 400, 200);
    for (const key of ["new1", "new2", "new3"]) {
        assert.ok(rects[key], key);
        assert.ok(rects[key].z > rects.known.z, `${key} draws above placed windows`);
    }
    assert.notDeepEqual([rects.new1.x, rects.new1.y], [rects.new2.x, rects.new2.y]);
});

test("a point resolves to the cell under it, label included", () => {
    const layout = H.gridLayout(3, 1200, 400, 16 / 9, { spacing: 20, labelHeight: 30 });
    const cell = layout.cells[1];
    assert.equal(H.cellAt(layout.cells, cell.x + 5, cell.y + 5), 1, "on the label line");
    assert.equal(H.cellAt(layout.cells, cell.x + cell.width - 1, cell.y + cell.height - 1), 1);
    assert.equal(H.cellAt(layout.cells, cell.x - 10, cell.y + 40), -1, "in the gap");
    assert.equal(H.cellAt(layout.cells, -5, -5), -1);
});

// ---- filtering and selection --------------------------------------------

const windows = [
    { address: "w1", title: "Inbox — Mozilla Firefox", appClass: "firefox", activated: false },
    { address: "w2", title: "~/src", appClass: "kitty", activated: true },
    { address: "w3", title: "Files", appClass: "org.gnome.Nautilus", activated: false }
];

test("filtering ranks windows exactly as the launcher's window provider does", () => {
    assert.deepEqual(Object.keys(H.filterScores(windows, "", windowScore)), ["w1", "w2", "w3"]);
    const scores = H.filterScores(windows, "fire", windowScore);
    assert.deepEqual(Object.keys(scores), ["w1"]);
    assert.equal(scores.w1, windowScore(windows[0].title, "firefox", "fire", false));
    assert.deepEqual(Object.keys(H.filterScores(windows, "nautilus", windowScore)), ["w3"]);
    assert.deepEqual(H.filterScores(windows, "zzz", windowScore), {});
});

function placementsFor(layout) {
    // w1 and w2 side by side on workspace 0, w3 alone on workspace 1.
    const tile = { x: 0, y: 0, width: 160, height: 90 };
    return [
        { address: "w2", cellIndex: 0, cell: layout.cells[0], rect: { ...tile, x: 160 } },
        { address: "w1", cellIndex: 0, cell: layout.cells[0], rect: tile },
        { address: "w3", cellIndex: 1, cell: layout.cells[1], rect: { ...tile, width: 320 } }
    ];
}

test("selection items run in reading order with centres in grid coordinates", () => {
    const layout = H.gridLayout(2, 800, 200, 16 / 9, { spacing: 20, labelHeight: 20, maxTileWidth: 320 });
    const items = H.selectionItems(placementsFor(layout), null);
    assert.deepEqual(items.map(item => item.address), ["w1", "w2", "w3"]);
    assert.equal(items[0].cx, layout.cells[0].x + 80);
    assert.equal(items[0].cy, layout.cells[0].y + 20 + 45);
    assert.ok(items.every(item => item.enabled));
    const filtered = H.selectionItems(placementsFor(layout), { w3: 1 });
    assert.deepEqual(filtered.map(item => item.enabled), [false, false, true]);
});

test("arrow keys move to the nearest window in that direction, across tiles", () => {
    const items = [
        { address: "a", cx: 100, cy: 100, enabled: true },
        { address: "b", cx: 300, cy: 100, enabled: true },
        { address: "c", cx: 700, cy: 110, enabled: true },
        { address: "d", cx: 120, cy: 400, enabled: true },
        { address: "e", cx: 700, cy: 400, enabled: false }
    ];
    assert.equal(H.navigate(items, 0, "right"), 1);
    assert.equal(H.navigate(items, 1, "right"), 2, "on into the next workspace");
    assert.equal(H.navigate(items, 2, "right"), 2, "nothing further: stay");
    assert.equal(H.navigate(items, 2, "left"), 1);
    assert.equal(H.navigate(items, 0, "down"), 3);
    assert.equal(H.navigate(items, 2, "down"), 3, "the disabled match is skipped");
    assert.equal(H.navigate(items, 3, "up"), 0, "the window straight above wins over a nearer diagonal");
    assert.equal(H.navigate(items, 0, "sideways"), 0);
    assert.equal(H.navigate(items, -1, "left"), 0, "no selection starts at the first match");
    assert.equal(H.navigate([], 0, "left"), -1);
});

test("Tab steps through matches in order and wraps", () => {
    const items = [
        { address: "a", enabled: true },
        { address: "b", enabled: false },
        { address: "c", enabled: true }
    ];
    assert.equal(H.step(items, 0, 1), 2);
    assert.equal(H.step(items, 2, 1), 0);
    assert.equal(H.step(items, 0, -1), 2);
    assert.equal(H.step(items, -1, 1), 0);
    assert.equal(H.step([{ address: "x", enabled: false }], 0, 1), -1);
});

test("the selection survives churn and follows the filter", () => {
    const items = [
        { address: "a", enabled: true },
        { address: "b", enabled: true },
        { address: "c", enabled: false }
    ];
    assert.equal(H.reselect(items, "b", null, "a", ""), "b", "still there: kept");
    assert.equal(H.reselect(items, "gone", null, "a", ""), "a", "closed: back to the focused window");
    assert.equal(H.reselect(items, "gone", null, "zzz", ""), "a", "else the first match");
    assert.equal(H.reselect(items, "c", null, "", ""), "a", "a filtered-out selection moves");
    assert.equal(H.reselect(items, "a", { a: 10, b: 900 }, "", "q"), "a",
        "a still-matching choice is not yanked away while typing");
    assert.equal(H.reselect(items, "", { a: 10, b: 900 }, "", "q"), "b", "else the best match");
    assert.equal(H.reselect([{ address: "x", enabled: false }], "x", {}, "x", "q"), "",
        "no match, no selection");
});
