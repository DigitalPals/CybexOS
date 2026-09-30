import { DEFAULT_PREFERENCES, type AppId, type DesktopWindow, type Preferences } from './types';

export const APP_NAMES: Record<AppId, string> = {
  welcome: 'Welcome to CybexOS', terminal: 'Kitty', files: 'Files', notes: 'Omawrite', settings: 'Settings', shortcuts: 'Keyboard shortcuts',
};
export const APP_DESCRIPTIONS: Record<AppId, string> = {
  welcome: 'A little introduction to your desktop', terminal: 'Explore the terminal', files: 'Browse your demo files', notes: 'A quiet place for your thoughts', settings: 'Make this desktop yours', shortcuts: 'Find your way around',
};
export const APP_IDS = Object.keys(APP_NAMES) as AppId[];
export const STORAGE_KEY = 'cybexos-web-preferences-v1';

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
  return { id, workspace, minimized: false, maximized: false, x: -1, y: 65 + offset * 24, width, height: id === 'welcome' ? 560 : 530 };
}

export type WindowAction =
  | { type: 'open'; id: AppId; workspace: number; viewportWidth: number }
  | { type: 'focus' | 'close' | 'minimize' | 'maximize'; id: AppId }
  | { type: 'move'; id: AppId; x: number; y: number }
  | { type: 'resize'; id: AppId; width: number; height: number }
  | { type: 'workspace'; id: AppId; workspace: number };

// Order is the stacking order; focusing never resets an app's state.
export function windowReducer(state: DesktopWindow[], action: WindowAction): DesktopWindow[] {
  const win = state.find(w => w.id === action.id);
  if (action.type === 'open') {
    if (win) return [...state.filter(w => w.id !== action.id), { ...win, minimized: false, workspace: action.workspace }];
    const next = initialWindow(action.id, action.workspace, state.filter(w => w.workspace === action.workspace).length % 4);
    next.x = Math.max(12, (action.viewportWidth - next.width) / 2);
    return [...state, next];
  }
  if (!win) return state;
  if (action.type === 'close') return state.filter(w => w.id !== action.id);
  if (action.type === 'focus') return [...state.filter(w => w.id !== action.id), win];
  return state.map(w => w.id !== action.id ? w : action.type === 'minimize' ? { ...w, minimized: true }
    : action.type === 'maximize' ? { ...w, maximized: !w.maximized }
    : action.type === 'move' ? { ...w, x: action.x, y: action.y }
    : action.type === 'resize' ? { ...w, width: action.width, height: action.height }
    : action.type === 'workspace' ? { ...w, workspace: action.workspace } : w);
}

export function accentInk(hex: string) {
  const parts = hex.slice(1).match(/.{2}/g)!.map(v => parseInt(v, 16) / 255).map(v => v <= .04045 ? v / 12.92 : ((v + .055) / 1.055) ** 2.4);
  return parts[0] * .2126 + parts[1] * .7152 + parts[2] * .0722 > .4 ? '#1a1917' : '#ffffff';
}
