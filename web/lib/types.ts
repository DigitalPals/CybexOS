export type AppId = 'welcome' | 'terminal' | 'files' | 'notes' | 'settings' | 'shortcuts' | 'usage';
export type SettingsPage = 'appearance' | 'wallpaper' | 'bar' | 'about';
export interface Preferences {
  theme: 'dark' | 'light';
  accent: string;
  wallpaper: 'mountains' | 'aurora' | 'dusk';
  glass: boolean;
  clock24: boolean;
  reducedMotion: boolean;
  font: 'mono' | 'sans';
}
export interface AppProps {
  openApp: (app: AppId) => void;
  notify: (message: string) => void;
}
export interface DesktopWindow {
  id: AppId;
  workspace: number;
  minimized: boolean;
  maximized: boolean;
  x: number;
  y: number;
  width: number;
  height: number;
}
export const DEFAULT_PREFERENCES: Preferences = {
  theme: 'dark', accent: '#d3d283', wallpaper: 'mountains', glass: false,
  clock24: true, reducedMotion: false, font: 'mono',
};
export const REPOSITORY_URL = 'https://github.com/DigitalPals/CybexOS';
