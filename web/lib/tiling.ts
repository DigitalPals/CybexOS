import type { AppId, DesktopWindow } from './types';

export interface Rect { x: number; y: number; width: number; height: number }
export type Direction = 'left' | 'right' | 'up' | 'down';

const GAP = 10;
const MIN_WIDTH = 240;
const MIN_HEIGHT = 180;

export function tiledWindows(windows: DesktopWindow[], workspace: number): DesktopWindow[] {
  return windows.filter(win => win.workspace === workspace && !win.minimized && !win.floating)
    .sort((a, b) => a.tileOrder - b.tileOrder || a.id.localeCompare(b.id));
}

function split(rect: Rect, horizontal: boolean, ratio = 0.5): [Rect, Rect] {
  const length = Math.max(0, (horizontal ? rect.width : rect.height) - GAP);
  const minimum = Math.min(horizontal ? MIN_WIDTH : MIN_HEIGHT, length / 2);
  const first = Math.min(length - minimum, Math.max(minimum, Math.round(length * ratio)));
  return horizontal
    ? [{ ...rect, width: first }, { ...rect, x: rect.x + first + GAP, width: length - first }]
    : [{ ...rect, height: first }, { ...rect, y: rect.y + first + GAP, height: length - first }];
}

/** Keep the first tile large, then recursively divide the remaining region. */
export function layoutWorkspace(windows: DesktopWindow[], workspace: number, viewport: { width: number; height: number }, ratio = 0.5): Record<string, Rect> {
  const area: Rect = { x: 10, y: 46, width: Math.max(0, viewport.width - 20), height: Math.max(0, viewport.height - 94) };
  const tiles = tiledWindows(windows, workspace);
  const result: Record<string, Rect> = {};

  function partition(group: DesktopWindow[], rect: Rect) {
    if (group.length === 1) { result[group[0].id] = rect; return; }
    const horizontalRoom = rect.width >= MIN_WIDTH * 2 + GAP;
    const verticalRoom = rect.height >= MIN_HEIGHT * 2 + GAP;
    const horizontal = horizontalRoom && (!verticalRoom || rect.width >= rect.height);
    const [first, second] = split(rect, horizontal);
    const half = Math.ceil(group.length / 2);
    partition(group.slice(0, half), first);
    partition(group.slice(half), second);
  }

  if (viewport.width < 760) {
    // A scrollable stack keeps apps usable when a side-by-side split cannot fit.
    const height = Math.max(300, (area.height - GAP * (tiles.length - 1)) / Math.max(1, tiles.length));
    tiles.forEach((win, index) => { result[win.id] = { ...area, y: area.y + index * (height + GAP), height }; });
  } else if (tiles.length === 1) {
    // The installed welcome opens centered at half-screen width. Retain the
    // browser's shared tiling behavior once a second app opens.
    const welcome = tiles[0].id === 'welcome';
    const width = welcome ? Math.min(area.width, Math.max(760, Math.round(viewport.width * 0.5)))
      : viewport.width >= 1200 ? Math.round(area.width * 0.7) : area.width;
    const height = welcome ? Math.min(area.height, Math.max(660, Math.round(viewport.height * 0.48))) : area.height;
    result[tiles[0].id] = { ...area, x: area.x + (area.width - width) / 2, y: area.y + (area.height - height) / 2, width, height };
  } else if (tiles.length > 1) {
    const safeRatio = Number.isFinite(ratio) ? Math.max(0.3, Math.min(0.7, ratio)) : 0.5;
    const [first, rest] = split(area, true, safeRatio);
    result[tiles[0].id] = first;
    partition(tiles.slice(1), rest);
  }

  // Keep the underlying split tree intact while one window is fullscreen.
  windows.filter(win => win.workspace === workspace && !win.minimized && win.maximized)
    .forEach(win => { result[win.id] = { ...area }; });
  return result;
}

/** Prefer neighbors whose perpendicular spans overlap, then the nearest edge. */
export function directionalNeighbor(windows: DesktopWindow[], workspace: number, geometry: Record<string, Rect>, id: AppId, direction: Direction): AppId | null {
  const origin = geometry[id];
  if (!origin) return null;
  const horizontal = direction === 'left' || direction === 'right';
  const sign = direction === 'left' || direction === 'up' ? -1 : 1;
  const center = (rect: Rect) => horizontal ? rect.x + rect.width / 2 : rect.y + rect.height / 2;
  const crossCenter = (rect: Rect) => horizontal ? rect.y + rect.height / 2 : rect.x + rect.width / 2;
  const crossStart = (rect: Rect) => horizontal ? rect.y : rect.x;
  const crossEnd = (rect: Rect) => horizontal ? rect.y + rect.height : rect.x + rect.width;
  const size = (rect: Rect) => horizontal ? rect.width : rect.height;

  return tiledWindows(windows, workspace)
    .filter(win => win.id !== id && geometry[win.id] && sign * (center(geometry[win.id]) - center(origin)) > 0.5)
    .map(win => {
      const rect = geometry[win.id];
      const overlap = Math.min(crossEnd(rect), crossEnd(origin)) - Math.max(crossStart(rect), crossStart(origin));
      const distance = sign * (center(rect) - center(origin));
      return { id: win.id, aligned: overlap > 0 ? 0 : 1, edge: Math.max(0, distance - (size(origin) + size(rect)) / 2), cross: Math.abs(crossCenter(rect) - crossCenter(origin)), distance };
    })
    .sort((a, b) => a.aligned - b.aligned || a.edge - b.edge || a.cross - b.cross || a.distance - b.distance)[0]?.id ?? null;
}
