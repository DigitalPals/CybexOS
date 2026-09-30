import { describe, expect, it } from 'vitest';
import { initialWindow, readPreferences, windowReducer } from '../lib/desktop';
import { DEFAULT_PREFERENCES, type Preferences } from '../lib/types';

describe('saved desktop preferences', () => {
  it.each([null, '', '{broken', 'null', '42', '"light"', '[]'])('recovers default settings from invalid storage: %s', value => {
    expect(readPreferences(value)).toEqual(DEFAULT_PREFERENCES);
  });

  it('restores valid preferences without trusting unrelated saved properties', () => {
    const preferences: Preferences = {
      theme: 'light', accent: '#9BbcE0', wallpaper: 'dusk', glass: true,
      clock24: false, reducedMotion: true, font: 'sans',
    };
    expect(readPreferences(JSON.stringify({ ...preferences, injected: 'ignore me' }))).toEqual(preferences);
  });

  it('replaces malformed fields while retaining the valid preferences in the same record', () => {
    expect(readPreferences(JSON.stringify({
      theme: 'light', accent: 'red; background:url(https://example.com)', wallpaper: 'aurora',
      glass: 'true', clock24: 0, reducedMotion: true, font: 'Comic Sans',
    }))).toEqual({ ...DEFAULT_PREFERENCES, theme: 'light', wallpaper: 'aurora', reducedMotion: true });
  });

  it('does not expose the shared default object to later mutation', () => {
    const firstRead = readPreferences(null);
    firstRead.theme = 'light';
    expect(readPreferences(null).theme).toBe('dark');
    expect(DEFAULT_PREFERENCES.theme).toBe('dark');
  });
});

describe('desktop window sessions', () => {
  it('reopening a minimized app retains its placement and size while moving it to the current workspace', () => {
    const terminal = { ...initialWindow('terminal', 1), x: 80, y: 100, width: 680, height: 440, minimized: true, maximized: true };
    const welcome = initialWindow('welcome', 1);
    const state = [terminal, welcome];
    const next = windowReducer(state, { type: 'open', id: 'terminal', workspace: 3, viewportWidth: 1600 });

    expect(next).toHaveLength(2);
    expect(next.at(-1)).toEqual({ ...terminal, workspace: 3, minimized: false, maximized: false });
    expect(next[0]).toBe(welcome);
    expect(terminal.minimized).toBe(true);
    expect(terminal.workspace).toBe(1);
  });

  it('focusing an app raises the existing window without recreating it or affecting other workspaces', () => {
    const terminal = { ...initialWindow('terminal', 1), x: 125, y: 75 };
    const notes = initialWindow('notes', 2);
    const settings = initialWindow('settings', 1);
    const next = windowReducer([terminal, notes, settings], { type: 'focus', id: 'terminal' });

    expect(next.map(win => win.id)).toEqual(['notes', 'settings', 'terminal']);
    expect(next.at(-1)).toBe(terminal);
    expect(next[0]).toBe(notes);
  });

  it('opening apps on a narrow viewport keeps their starting position reachable', () => {
    const opened = windowReducer([], { type: 'open', id: 'settings', workspace: 5, viewportWidth: 375 });
    expect(opened).toHaveLength(1);
    expect(opened[0]).toMatchObject({ id: 'settings', workspace: 5, minimized: false, maximized: false });
    expect(opened[0].x).toBeGreaterThanOrEqual(0);
    expect(opened[0].x).toBeLessThan(375);
  });

  it('restoring after maximization preserves user-adjusted geometry', () => {
    let windows = [initialWindow('notes', 1)];
    windows = windowReducer(windows, { type: 'move', id: 'notes', x: 180, y: 120 });
    windows = windowReducer(windows, { type: 'resize', id: 'notes', width: 670, height: 480 });
    windows = windowReducer(windows, { type: 'maximize', id: 'notes' });
    expect(windows[0].maximized).toBe(true);
    windows = windowReducer(windows, { type: 'maximize', id: 'notes' });
    expect(windows[0]).toMatchObject({ maximized: false, x: 180, y: 120, width: 670, height: 480 });
  });

  it('ignores stale actions for closed apps and closes only the requested window', () => {
    const welcome = initialWindow('welcome', 1);
    const terminal = initialWindow('terminal', 2);
    const state = [welcome, terminal];
    expect(windowReducer(state, { type: 'focus', id: 'notes' })).toBe(state);
    expect(windowReducer(state, { type: 'close', id: 'terminal' })).toEqual([welcome]);
    expect(state).toEqual([welcome, terminal]);
  });
});
