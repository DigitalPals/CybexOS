import { describe, expect, it } from 'vitest';
import { APP_IDS, initialWindow, windowReducer } from '../lib/desktop';
import { directionalNeighbor, layoutWorkspace, tiledWindows, type Rect } from '../lib/tiling';
import type { DesktopWindow } from '../lib/types';

const viewport = { width: 1440, height: 900 };
const windows = (count: number) => APP_IDS.slice(0, count).map((id, index) => initialWindow(id, 1, index));

function overlaps(a: Rect, b: Rect) {
  return a.x < b.x + b.width && a.x + a.width > b.x && a.y < b.y + b.height && a.y + a.height > b.y;
}

describe('dwindle workspace geometry', () => {
  it.each([
    { width: 760, height: 480 }, { width: 1024, height: 768 },
    viewport, { width: 1920, height: 1080 }, { width: 2560, height: 1440 },
  ])('fits one through seven tiles without overlaps on a $width × $height desktop', size => {
    for (let count = 1; count <= APP_IDS.length; count++) {
      const rects = Object.values(layoutWorkspace(windows(count), 1, size));
      expect(rects).toHaveLength(count);
      rects.forEach((rect, index) => {
        expect(rect.x).toBeGreaterThanOrEqual(10);
        expect(rect.y).toBeGreaterThanOrEqual(46);
        expect(rect.width).toBeGreaterThanOrEqual(240);
        expect(rect.height).toBeGreaterThan(0);
        expect(rect.x + rect.width).toBeLessThanOrEqual(size.width - 10);
        expect(rect.y + rect.height).toBeLessThanOrEqual(size.height - 48);
        rects.slice(index + 1).forEach(other => expect(overlaps(rect, other)).toBe(false));
      });
    }
  });

  it('centers a single tile on wide displays and fills narrower desktops', () => {
    const wide = layoutWorkspace(windows(1), 1, viewport).welcome;
    expect(wide.width).toBe(994);
    expect(wide.x + wide.width / 2).toBe(viewport.width / 2);
    expect(layoutWorkspace(windows(1), 1, { width: 1000, height: 900 }).welcome).toEqual({ x: 10, y: 46, width: 980, height: 806 });
  });

  it('places the first tile left and recursively splits the remaining region', () => {
    const rects = layoutWorkspace(windows(3), 1, viewport);
    expect(rects.welcome).toEqual({ x: 10, y: 46, width: 705, height: 806 });
    expect(rects.terminal).toEqual({ x: 725, y: 46, width: 705, height: 398 });
    expect(rects.files).toEqual({ x: 725, y: 454, width: 705, height: 398 });
  });

  it.each([320, 390, 759])('stacks usable full-width tiles on a %ipx screen with scroll overflow', width => {
    const rects = Object.values(layoutWorkspace(windows(4), 1, { width, height: 780 }));
    rects.forEach((rect, index) => {
      expect(rect).toEqual({ x: 10, y: 46 + index * 310, width: width - 20, height: 300 });
    });
    expect(rects.at(-1)!.y + rects.at(-1)!.height).toBeGreaterThan(780);
  });

  it('clamps split ratios and protects minimum tile widths', () => {
    const state = windows(2);
    expect(layoutWorkspace(state, 1, viewport, -10)).toEqual(layoutWorkspace(state, 1, viewport, 0.3));
    expect(layoutWorkspace(state, 1, viewport, 10)).toEqual(layoutWorkspace(state, 1, viewport, 0.7));
    expect(layoutWorkspace(state, 1, viewport, NaN)).toEqual(layoutWorkspace(state, 1, viewport));
    expect(layoutWorkspace(state, 1, viewport, Infinity)).toEqual(layoutWorkspace(state, 1, viewport));
    const narrow = Object.values(layoutWorkspace(state, 1, { width: 760, height: 600 }, 0.3));
    expect(narrow.every(rect => rect.width >= 240)).toBe(true);
    expect(layoutWorkspace(state, 1, viewport, 0.6).welcome.width).toBeGreaterThan(layoutWorkspace(state, 1, viewport).welcome.width);
  });

  it('excludes floating, minimized and other-workspace windows from tiling', () => {
    const state = windows(4).map((win, index) => ({ ...win, minimized: index === 1, floating: index === 2, workspace: index === 3 ? 2 : 1 }));
    expect(tiledWindows(state, 1).map(win => win.id)).toEqual(['welcome']);
    expect(layoutWorkspace(state, 1, viewport)).toEqual(layoutWorkspace([state[0]], 1, viewport));
    expect(layoutWorkspace([], 1, viewport)).toEqual({});
  });

  it('preserves the split behind a fullscreen tile and restores it on exit', () => {
    const state = windows(3);
    const before = layoutWorkspace(state, 1, viewport);
    const zoomed = windowReducer(state, { type: 'maximize', id: 'terminal' });
    const zoomedRects = layoutWorkspace(zoomed, 1, viewport);
    expect(zoomedRects.terminal).toEqual({ x: 10, y: 46, width: 1420, height: 806 });
    expect(zoomedRects.welcome).toEqual(before.welcome);
    expect(zoomedRects.files).toEqual(before.files);
    expect(layoutWorkspace(windowReducer(zoomed, { type: 'maximize', id: 'terminal' }), 1, viewport)).toEqual(before);
  });

  it('also supplies a fullscreen rectangle for a floating window', () => {
    const terminal = { ...initialWindow('terminal', 1), floating: true, maximized: true };
    expect(layoutWorkspace([terminal], 1, viewport).terminal).toEqual({ x: 10, y: 46, width: 1420, height: 806 });
    expect(layoutWorkspace([{ ...terminal, minimized: true }], 1, viewport)).toEqual({});
  });
});

describe('stable tiled sessions', () => {
  it('tiles new apps in insertion order and does not reorder them on focus or reopen', () => {
    let state: DesktopWindow[] = [];
    for (const id of ['notes', 'terminal', 'files'] as const) state = windowReducer(state, { type: 'open', id, workspace: 1, viewportWidth: 1440 });
    expect(tiledWindows(state, 1).map(win => win.id)).toEqual(['notes', 'terminal', 'files']);
    const before = layoutWorkspace(state, 1, viewport);
    const focused = windowReducer(state, { type: 'focus', id: 'notes' });
    expect(focused.at(-1)!.id).toBe('notes');
    expect(layoutWorkspace(focused, 1, viewport)).toEqual(before);
    expect([...focused].sort((a, b) => a.createdOrder - b.createdOrder).map(win => win.id)).toEqual(['notes', 'terminal', 'files']);
    const swapped = windowReducer(focused, { type: 'swap', id: 'notes', targetId: 'files' });
    expect([...swapped].sort((a, b) => a.createdOrder - b.createdOrder).map(win => win.id)).toEqual(['notes', 'terminal', 'files']);
    expect(layoutWorkspace(windowReducer(focused, { type: 'open', id: 'terminal', workspace: 1, viewportWidth: 1440 }), 1, viewport)).toEqual(before);
  });

  it('does not let tied initial tile orders follow focus', () => {
    const state = [initialWindow('terminal', 1), initialWindow('notes', 1)];
    expect(layoutWorkspace(windowReducer(state, { type: 'focus', id: 'terminal' }), 1, viewport)).toEqual(layoutWorkspace(state, 1, viewport));
  });

  it('reflows on minimize/close and restores a minimized tile to its prior position', () => {
    const state = windows(3);
    const original = layoutWorkspace(state, 1, viewport);
    const minimized = windowReducer(state, { type: 'minimize', id: 'terminal' });
    expect(layoutWorkspace(minimized, 1, viewport).files.height).toBe(806);
    const restored = windowReducer(minimized, { type: 'open', id: 'terminal', workspace: 1, viewportWidth: 1440 });
    expect(layoutWorkspace(restored, 1, viewport)).toEqual(original);
    expect(layoutWorkspace(windowReducer(state, { type: 'close', id: 'terminal' }), 1, viewport)).toEqual(layoutWorkspace(minimized, 1, viewport));
  });

  it('retains saved floating geometry when switching between tiled and floating', () => {
    const state = windows(2).map(win => ({ ...win, x: 91, y: 127, width: 690, height: 440 }));
    const original = layoutWorkspace(state, 1, viewport);
    const floated = windowReducer(state, { type: 'toggle-floating', id: 'terminal' });
    expect(floated[1]).toMatchObject({ floating: true, x: 91, y: 127, width: 690, height: 440 });
    expect(Object.keys(layoutWorkspace(floated, 1, viewport))).toEqual(['welcome']);
    const tiled = windowReducer(floated, { type: 'toggle-floating', id: 'terminal' });
    expect(layoutWorkspace(tiled, 1, viewport)).toEqual(original);
    expect(tiled[1]).toEqual(state[1]);
  });

  it('appends moved windows to the destination without disturbing unrelated workspaces', () => {
    const state = [...windows(2), initialWindow('notes', 2, 4), initialWindow('files', 3)];
    const workspaceThree = layoutWorkspace(state, 3, viewport);
    const moved = windowReducer(state, { type: 'workspace', id: 'terminal', workspace: 2 });
    expect(tiledWindows(moved, 2).map(win => win.id)).toEqual(['notes', 'terminal']);
    expect(moved.find(win => win.id === 'terminal')).toEqual({ ...state[1], workspace: 2, tileOrder: 5 });
    expect(layoutWorkspace(moved, 3, viewport)).toEqual(workspaceThree);
    expect(Object.keys(layoutWorkspace(moved, 1, viewport))).toEqual(['welcome']);
    expect(windowReducer(moved, { type: 'workspace', id: 'terminal', workspace: 2 })).toEqual(moved);
  });

  it('appends an existing app opened on another workspace while retaining its saved geometry', () => {
    const state = [initialWindow('terminal', 1), initialWindow('notes', 2, 3)];
    const moved = windowReducer(state, { type: 'open', id: 'terminal', workspace: 2, viewportWidth: 1920 });
    expect(moved.at(-1)).toEqual({ ...state[0], workspace: 2, tileOrder: 4 });
  });

  it('swaps tile positions while preserving stacking and saved floating geometry', () => {
    const state = windows(3);
    const original = layoutWorkspace(state, 1, viewport);
    const swapped = windowReducer(state, { type: 'swap', id: 'welcome', targetId: 'files' });
    expect(swapped.map(win => win.id)).toEqual(state.map(win => win.id));
    const after = layoutWorkspace(swapped, 1, viewport);
    expect(after.welcome).toEqual(original.files);
    expect(after.files).toEqual(original.welcome);
    expect(after.terminal).toEqual(original.terminal);
    expect(swapped[0]).toEqual({ ...state[0], tileOrder: 2 });
    expect(layoutWorkspace(windowReducer(swapped, { type: 'swap', id: 'welcome', targetId: 'files' }), 1, viewport)).toEqual(original);
  });

  it('ignores swaps with missing, minimized, floating or other-workspace targets', () => {
    for (const overrides of [{ workspace: 2 }, { minimized: true }, { floating: true }]) {
      const state = [initialWindow('terminal', 1), { ...initialWindow('notes', 1), ...overrides }];
      expect(windowReducer(state, { type: 'swap', id: 'terminal', targetId: 'notes' })).toBe(state);
    }
    const state = windows(1);
    expect(windowReducer(state, { type: 'swap', id: 'welcome', targetId: 'terminal' })).toBe(state);
  });

  it('keeps at most one fullscreen window per workspace and exits zoom on focus/open', () => {
    let state = [...windows(3), { ...initialWindow('notes', 2), maximized: true }];
    state = windowReducer(state, { type: 'maximize', id: 'welcome' });
    state = windowReducer(state, { type: 'maximize', id: 'terminal' });
    expect(state.filter(win => win.maximized).map(win => win.id)).toEqual(['terminal', 'notes']);
    const focused = windowReducer(state, { type: 'focus', id: 'files' });
    expect(focused.find(win => win.id === 'terminal')!.maximized).toBe(false);
    const opened = windowReducer(state, { type: 'open', id: 'settings', workspace: 1, viewportWidth: 1440 });
    expect(opened.filter(win => win.maximized).map(win => win.id)).toEqual(['notes']);
    const moved = windowReducer(state, { type: 'workspace', id: 'terminal', workspace: 2 });
    expect(moved.some(win => win.maximized)).toBe(false);
    expect(windowReducer(state, { type: 'minimize', id: 'terminal' }).find(win => win.id === 'terminal')!.maximized).toBe(false);
  });
});

describe('directional tile navigation', () => {
  it('follows spatial neighbors instead of focus or app order', () => {
    const state = windows(3);
    const geometry = layoutWorkspace(state, 1, viewport);
    expect(directionalNeighbor(state, 1, geometry, 'welcome', 'right')).toBe('terminal');
    expect(directionalNeighbor(state, 1, geometry, 'terminal', 'down')).toBe('files');
    expect(directionalNeighbor(state, 1, geometry, 'files', 'up')).toBe('terminal');
    expect(directionalNeighbor(state, 1, geometry, 'files', 'left')).toBe('welcome');
    expect(directionalNeighbor(state, 1, geometry, 'welcome', 'left')).toBeNull();
    expect(directionalNeighbor(state, 1, geometry, 'notes', 'right')).toBeNull();
    expect(directionalNeighbor(windowReducer(state, { type: 'focus', id: 'terminal' }), 1, geometry, 'welcome', 'right')).toBe('terminal');
  });

  it('prefers aligned neighbors over a nearer diagonal tile', () => {
    const state = windows(3);
    const geometry = {
      welcome: { x: 0, y: 200, width: 200, height: 200 },
      terminal: { x: 250, y: 0, width: 200, height: 180 },
      files: { x: 500, y: 200, width: 200, height: 200 },
    };
    expect(directionalNeighbor(state, 1, geometry, 'welcome', 'right')).toBe('files');
    expect(directionalNeighbor(state.map(win => ({ ...win, minimized: win.id === 'files' })), 1, geometry, 'welcome', 'right')).toBe('terminal');
  });

  it('follows a vertical stack on mobile', () => {
    const state = windows(3);
    const geometry = layoutWorkspace(state, 1, { width: 390, height: 800 });
    expect(directionalNeighbor(state, 1, geometry, 'terminal', 'up')).toBe('welcome');
    expect(directionalNeighbor(state, 1, geometry, 'terminal', 'down')).toBe('files');
    expect(directionalNeighbor(state, 1, geometry, 'terminal', 'left')).toBeNull();
    expect(directionalNeighbor(state, 1, geometry, 'terminal', 'right')).toBeNull();
  });
});
