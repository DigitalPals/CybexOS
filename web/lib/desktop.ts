import { DEFAULT_PREFERENCES, type AppId, type DesktopWindow, type Preferences } from './types';

export const APP_NAMES: Record<AppId, string> = {
  welcome: 'Welcome to NerdOS', terminal: 'Kitty', files: 'Files', notes: 'Omawrite', settings: 'Settings', shortcuts: 'Keyboard shortcuts', usage: 'Model Usage',
};
export const APP_DESCRIPTIONS: Record<AppId, string> = {
  welcome: 'A little introduction to your desktop', terminal: 'Explore the terminal', files: 'Browse your demo files', notes: 'A quiet place for your thoughts', settings: 'Make this desktop yours', shortcuts: 'Find your way around', usage: 'Codex & Claude subscriptions · CLIProxyAPI',
};
export const APP_IDS = Object.keys(APP_NAMES) as AppId[];
export const STORAGE_KEY = 'nerdos-web-preferences-v1';

export function readPreferences(value: string | null): Preferences {
  try {
    const p = JSON.parse(value || '{}');
    if (!p || typeof p !== 'object') return { ...DEFAULT_PREFERENCES };
    return {
      theme: p.theme === 'light' ? 'light' : 'dark',
      accent: /^#[\da-f]{6}$/i.test(p.accent) ? p.accent : DEFAULT_PREFERENCES.accent,
      wallpaper: ['mountains', 'aurora', 'dusk'].includes(p.wallpaper) ? p.wallpaper : 'mountains',
      glass: typeof p.glass === 'boolean' ? p.glass : false,
      clock24: typeof p.clock24 === 'boolean' ? p.clock24 : true,
      reducedMotion: typeof p.reducedMotion === 'boolean' ? p.reducedMotion : false,
      font: p.font === 'sans' ? 'sans' : 'mono',
    };
  } catch { return { ...DEFAULT_PREFERENCES }; }
}

export function initialWindow(id: AppId, workspace: number, offset = 0): DesktopWindow {
  const width = id === 'welcome' ? 940 : id === 'settings' ? 850 : 800;
  return { id, workspace, minimized: false, maximized: false, floating: false, tileOrder: offset, createdOrder: 0, x: -1, y: 65 + offset * 24, width, height: id === 'welcome' ? 560 : 530 };
}

export type WindowAction =
  | { type: 'open'; id: AppId; workspace: number; viewportWidth: number }
  | { type: 'focus' | 'close' | 'minimize' | 'maximize' | 'toggle-floating'; id: AppId }
  | { type: 'swap'; id: AppId; targetId: AppId }
  | { type: 'move'; id: AppId; x: number; y: number }
  | { type: 'resize'; id: AppId; width: number; height: number }
  | { type: 'workspace'; id: AppId; workspace: number };

function nextTileOrder(state: DesktopWindow[], workspace: number) {
  return Math.max(-1, ...state.filter(w => w.workspace === workspace).map(w => w.tileOrder)) + 1;
}

// Array order is focus/stacking order; tileOrder is independent of focus.
export function windowReducer(state: DesktopWindow[], action: WindowAction): DesktopWindow[] {
  const win = state.find(w => w.id === action.id);
  if (action.type === 'open') {
    const others = state.filter(w => w.id !== action.id).map(w => w.workspace === action.workspace && w.maximized ? { ...w, maximized: false } : w);
    if (win) return [...others, {
      ...win, minimized: false, workspace: action.workspace,
      maximized: win.workspace === action.workspace && win.maximized,
      tileOrder: win.workspace === action.workspace ? win.tileOrder : nextTileOrder(state, action.workspace),
    }];
    const next = initialWindow(action.id, action.workspace, state.filter(w => w.workspace === action.workspace).length % 4);
    next.x = Math.max(12, (action.viewportWidth - next.width) / 2);
    next.tileOrder = nextTileOrder(state, action.workspace);
    next.createdOrder = Math.max(-1, ...state.map(w => w.createdOrder)) + 1;
    return [...others, next];
  }
  if (!win) return state;
  if (action.type === 'close') return state.filter(w => w.id !== action.id);
  if (action.type === 'focus') return [...state.filter(w => w.id !== action.id)
    .map(w => w.workspace === win.workspace && w.maximized ? { ...w, maximized: false } : w), win];
  if (action.type === 'swap') {
    const target = state.find(w => w.id === action.targetId);
    if (!target || target.id === win.id || target.workspace !== win.workspace || target.minimized || win.minimized || target.floating || win.floating) return state;
    // Resolve tied initial orders deterministically, independent of stacking.
    const ordered = state.filter(w => w.workspace === win.workspace).sort((a, b) => a.tileOrder - b.tileOrder || a.id.localeCompare(b.id));
    const order = (w: DesktopWindow) => win.tileOrder === target.tileOrder ? ordered.indexOf(w) : w.tileOrder;
    return state.map(w => w.workspace !== win.workspace ? w : {
      ...w, tileOrder: w.id === win.id ? order(target) : w.id === target.id ? order(win) : order(w),
    });
  }
  return state.map(w => {
    if (w.id !== action.id) {
      const leaveZoom = (action.type === 'maximize' && w.workspace === win.workspace)
        || (action.type === 'workspace' && action.workspace !== win.workspace && w.workspace === action.workspace);
      return leaveZoom && w.maximized ? { ...w, maximized: false } : w;
    }
    switch (action.type) {
      case 'minimize': return { ...w, minimized: true, maximized: false };
      case 'maximize': return { ...w, maximized: !w.maximized };
      case 'toggle-floating': return { ...w, floating: !w.floating };
      case 'move': return { ...w, x: action.x, y: action.y };
      case 'resize': return { ...w, width: action.width, height: action.height };
      case 'workspace': return {
        ...w, workspace: action.workspace,
        maximized: w.workspace === action.workspace && w.maximized,
        tileOrder: w.workspace === action.workspace ? w.tileOrder : nextTileOrder(state, action.workspace),
      };
      default: return w;
    }
  });
}

export function accentInk(hex: string) {
  const parts = hex.slice(1).match(/.{2}/g)!.map(v => parseInt(v, 16) / 255).map(v => v <= .04045 ? v / 12.92 : ((v + .055) / 1.055) ** 2.4);
  return parts[0] * .2126 + parts[1] * .7152 + parts[2] * .0722 > .4 ? '#1a1917' : '#ffffff';
}
