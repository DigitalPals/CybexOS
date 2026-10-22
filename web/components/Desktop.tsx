'use client';

import { useCallback, useEffect, useMemo, useReducer, useRef, useState, type CSSProperties } from 'react';
import { ArrowRight, BatteryFull, Bell, BellOff, Bluetooth, Check, Command, Expand, Folder, Grid2X2, Keyboard, LockKeyhole, PanelsTopLeft, Search, Settings2, SlidersHorizontal, StickyNote, Terminal, Volume2, VolumeX, Wifi, WifiOff, X } from 'lucide-react';
import { APP_DESCRIPTIONS, APP_IDS, APP_NAMES, STORAGE_KEY, accentInk, initialWindow, readPreferences, windowReducer, type WindowAction } from '../lib/desktop';
import { directionalNeighbor, layoutWorkspace, tiledWindows, type Direction } from '../lib/tiling';
import { DEFAULT_PREFERENCES, type AppId, type Preferences } from '../lib/types';
import { Window } from './Window';
import { WelcomeApp, ShortcutsApp } from './WelcomeApp';
import { TerminalApp } from './TerminalApp';
import { FilesApp } from './FilesApp';
import { NotesApp } from './NotesApp';
import { SettingsApp } from './SettingsApp';
import { Overlay } from './Overlay';
import { ControlDrawer, type DrawerTab } from './ControlDrawer';
import { CalendarWithClock, DesktopClock } from './Clock';
import { ModelUsageBar, ModelUsagePanel } from './ModelUsagePanel';
import { createUsageState, usageReducer, type ProviderId } from '../lib/model-usage';

const ICONS = { welcome: Command, terminal: Terminal, files: Folder, notes: StickyNote, settings: Settings2, shortcuts: Keyboard, usage: SlidersHorizontal };
type Panel = 'launcher' | 'controls' | 'calendar' | 'usage' | 'layout' | null;

export default function Desktop() {
  const [preferences, setPreferences] = useState<Preferences>(DEFAULT_PREFERENCES);
  const [windows, dispatch] = useReducer(windowReducer, [initialWindow('welcome', 1)]);
  const [workspace, setWorkspace] = useState(1);
  const [viewport, setViewport] = useState({ width: 1280, height: 800 });
  const [ratios, setRatios] = useState<Record<number, number>>({});
  const windowLayer = useRef<HTMLDivElement>(null);
  const draggingSplit = useRef(false);
  const [panel, setPanel] = useState<Panel>(null);
  const [drawerTab, setDrawerTab] = useState<DrawerTab>('overview');
  const [usage, usageDispatch] = useReducer(usageReducer, undefined, () => createUsageState());
  const [usageProvider, setUsageProvider] = useState<ProviderId>('codex');
  const [query, setQuery] = useState('');
  const [selected, setSelected] = useState(0);
  const [volume, setVolume] = useState(68);
  const [brightness, setBrightness] = useState(100);
  const [wifi, setWifi] = useState(true);
  const [bluetooth, setBluetooth] = useState(false);
  const [dnd, setDnd] = useState(false);
  const [locked, setLocked] = useState(false);
  const [toast, setToast] = useState('');
  const [notices, setNotices] = useState(['Welcome to your CybexOS browser desktop.']);
  const toastTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const restored = useRef(false);
  const ratio = ratios[workspace] ?? 0.5;
  const visible = useMemo(() => windows.filter(w => w.workspace === workspace && !w.minimized), [windows, workspace]);
  const focused = visible.at(-1)?.id;
  const maximized = visible.find(w => w.maximized)?.id;
  const tiles = tiledWindows(windows, workspace);
  const geometry = useMemo(() => layoutWorkspace(windows, workspace, viewport, ratio), [windows, workspace, viewport, ratio]);
  const canvasHeight = maximized ? viewport.height : Math.max(viewport.height, ...Object.values(geometry).map(rect => rect.y + rect.height + 48));
  const firstTile = tiles[0] && geometry[tiles[0].id];

  useEffect(() => {
    const resize = () => setViewport({ width: window.innerWidth, height: window.innerHeight });
    // Match the real viewport after hydration, keeping the server snapshot stable.
    resize();
    window.addEventListener('resize', resize);
    return () => window.removeEventListener('resize', resize);
  }, []);

  useEffect(() => {
    if (windowLayer.current) windowLayer.current.scrollTop = 0;
  }, [workspace, maximized]);

  const focusApp = useCallback((id?: AppId) => {
    if (!id) return;
    requestAnimationFrame(() => {
      const app = document.querySelector<HTMLElement>(`[data-app="${id}"]`);
      if (!app || app.closest('[hidden]')) return;
      const editor = app.querySelector<HTMLElement>('input:not([type="radio"]):not([type="range"]),textarea');
      (editor || app).focus({ preventScroll: true });
      if (window.innerWidth < 760) app.scrollIntoView?.({ block: 'nearest' });
    });
  }, []);

  const selectWorkspace = useCallback((next: number) => {
    setWorkspace(next);
    setPanel(null);
    focusApp(windows.filter(w => w.workspace === next && !w.minimized).at(-1)?.id);
  }, [windows, focusApp]);

  const actOnWindow = useCallback((action: WindowAction) => {
    dispatch(action);
    const leavesWorkspace = action.type === 'close' || action.type === 'minimize'
      || (action.type === 'workspace' && action.workspace !== workspace);
    if (leavesWorkspace && action.id === focused) {
      focusApp(visible.filter(win => win.id !== action.id).at(-1)?.id);
    }
  }, [workspace, focused, visible, focusApp]);

  function setRatio(next: number) {
    setRatios(current => ({ ...current, [workspace]: Math.max(0.3, Math.min(0.7, next)) }));
  }

  useEffect(() => {
    usageDispatch({ type: 'initialize', now: Date.now() });
    const timer = setInterval(() => usageDispatch({ type: 'refresh', now: Date.now() }), 30_000);
    return () => clearInterval(timer);
  }, []);

  const notify = useCallback((message: string) => {
    setNotices(items => [message, ...items].slice(0, 20));
    if (!dnd) {
      setToast(message);
      if (toastTimer.current) clearTimeout(toastTimer.current);
      toastTimer.current = setTimeout(() => setToast(''), 4200);
    }
  }, [dnd]);

  useEffect(() => {
    // Browser storage has no server snapshot. One post-hydration update is
    // intentional and keeps the initial server/client markup identical.
    // eslint-disable-next-line react-hooks/set-state-in-effect
    try { setPreferences(readPreferences(localStorage.getItem(STORAGE_KEY))); }
    catch { notify('Browser storage is unavailable. Changes will last for this visit.'); }
    restored.current = true;
    return () => { if (toastTimer.current) clearTimeout(toastTimer.current); };
    // Only restore once; changing notification preferences must not reset the session.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const updatePreferences = useCallback((patch: Partial<Preferences>) => {
    setPreferences(current => {
      const next = { ...current, ...patch };
      if (restored.current) {
        try { localStorage.setItem(STORAGE_KEY, JSON.stringify(next)); }
        catch { setToast('This browser could not save your preferences. They still apply for this visit.'); }
      }
      return next;
    });
  }, []);

  const openApp = useCallback((id: AppId) => {
    if (id === 'usage') { setPanel('usage'); setQuery(''); return; }
    dispatch({ type: 'open', id, workspace, viewportWidth: window.innerWidth });
    setPanel(null);
    setQuery('');
    focusApp(id);
  }, [workspace, focusApp]);

  function togglePanel(next: Panel) {
    setPanel(current => current === next ? null : next);
    setQuery(''); setSelected(0);
  }

  useEffect(() => {
    const handler = (event: KeyboardEvent) => {
      if (locked) { if (event.key === 'Escape') setLocked(false); return; }
      if (event.key === 'Escape') { setPanel(null); return; }
      if (!event.altKey || event.ctrlKey || event.metaKey) return;
      if (event.code === 'Space') {
        event.preventDefault(); setPanel(p => p === 'launcher' ? null : 'launcher'); setQuery(''); setSelected(0); return;
      }
      // Shell panels own input while open; window shortcuts must not act behind them.
      if (panel) return;
      const digit = /^Digit[1-5]$/.test(event.code) ? Number(event.code.slice(-1)) : /^[1-5]$/.test(event.key) ? Number(event.key) : null;
      if (digit) {
        event.preventDefault();
        if (event.shiftKey) {
          if (focused && digit !== workspace) {
            dispatch({ type: 'workspace', id: focused, workspace: digit });
            focusApp(visible.filter(w => w.id !== focused).at(-1)?.id);
          }
        } else selectWorkspace(digit);
        return;
      }
      if (event.key === 'Enter') { event.preventDefault(); openApp('terminal'); return; }
      if (event.key.toLowerCase() === 'k') { event.preventDefault(); openApp('shortcuts'); return; }
      if (!focused) return;
      if (event.key.toLowerCase() === 'v' && !maximized) { event.preventDefault(); dispatch({ type: 'toggle-floating', id: focused }); return; }
      if (event.key.toLowerCase() === 'f') { event.preventDefault(); dispatch({ type: 'maximize', id: focused }); return; }
      if (/^Arrow(Left|Right|Up|Down)$/.test(event.key)) {
        event.preventDefault();
        if (maximized) return;
        const targetId = directionalNeighbor(windows, workspace, geometry, focused, event.key.slice(5).toLowerCase() as Direction);
        if (!targetId) return;
        if (event.shiftKey) dispatch({ type: 'swap', id: focused, targetId });
        else { dispatch({ type: 'focus', id: targetId }); focusApp(targetId); }
      }
    };
    window.addEventListener('keydown', handler);
    return () => window.removeEventListener('keydown', handler);
  }, [openApp, locked, panel, focused, maximized, windows, workspace, geometry, visible, focusApp, selectWorkspace]);

  function openDrawer(tab: DrawerTab) {
    setDrawerTab(tab);
    setPanel(current => current === 'controls' && drawerTab === tab ? null : 'controls');
  }

  const filtered = APP_IDS.filter(id => `${APP_NAMES[id]} ${id} ${APP_DESCRIPTIONS[id]}`.toLowerCase().includes(query.toLowerCase()));
  const props = { openApp, notify };

  async function fullscreen() {
    try {
      if (document.fullscreenElement) await document.exitFullscreen();
      else if (document.documentElement.requestFullscreen) await document.documentElement.requestFullscreen();
      else notify('Fullscreen is unavailable in this browser. Try your browser’s fullscreen option.');
    } catch { notify('Fullscreen was unavailable. You can keep exploring in this window.'); }
  }

  return <main className={`desktop theme-${preferences.theme} font-${preferences.font} ${preferences.glass ? 'glass-enabled' : ''} ${preferences.reducedMotion ? 'reduced-motion' : ''}`} style={{ '--accent': preferences.accent, '--accent-ink': accentInk(preferences.accent) } as CSSProperties}>
    <div className={`desktop-wallpaper wallpaper-${preferences.wallpaper}`} style={{ filter: `brightness(${brightness / 100})` }} />
    <div className="desktop-interface" inert={locked || undefined}>
      <header className="menubar" aria-label="Desktop menubar">
        <div className="bar-left">
          <nav className="workspaces" aria-label="Workspaces">{[1, 2, 3, 4, 5].map(n => <button className={workspace === n ? 'current' : ''} key={n} aria-label={`Workspace ${n}`} aria-current={workspace === n ? 'page' : undefined} title={`Workspace ${n} · Alt+${n}`} onClick={() => selectWorkspace(n)}>{workspace === n || windows.some(w => w.workspace === n) ? n : <span className="workspace-dot" />}</button>)}</nav>
          <div className="bar-divider" />
          <button className={`bar-button launcher-button ${panel === 'launcher' ? 'selected' : ''}`} title="Applications · Alt+Space" aria-label="Open app launcher" aria-expanded={panel === 'launcher'} onClick={() => togglePanel('launcher')}><Grid2X2 size={15} /><span className="launcher-label">Applications</span></button>
        </div>
        <div className="bar-center bar-group">
          <button className={`bar-button clock-button ${panel === 'calendar' ? 'selected' : ''}`} aria-label="Open calendar" aria-expanded={panel === 'calendar'} onClick={() => togglePanel('calendar')}><DesktopClock clock24={preferences.clock24} /></button>
          <button className="bar-button notes-button" title="Omawrite" aria-label="Open notes" onClick={() => openApp('notes')}><StickyNote size={15} /></button>
        </div>
        <div className="bar-right">
          <ModelUsageBar state={usage} active={panel === 'usage' ? usageProvider : null} open={provider => { setUsageProvider(provider); setPanel(current => current === 'usage' && usageProvider === provider ? null : 'usage'); }} />
          <div className="bar-group status-cluster">
            <button className={`bar-button ${panel === 'controls' && drawerTab === 'notifications' ? 'selected' : ''}`} title="Notifications" aria-label="Notifications" aria-expanded={panel === 'controls' && drawerTab === 'notifications'} onClick={() => openDrawer('notifications')}>{dnd ? <BellOff size={15} /> : <Bell size={15} />}{notices.length > 0 && <span className="notification-dot" />}</button>
            <button className={`bar-button status-detail ${panel === 'controls' && drawerTab === 'sound' ? 'selected' : ''}`} title="Sound" aria-label="Open sound controls" onClick={() => openDrawer('sound')}>{volume ? <Volume2 size={16} /> : <VolumeX size={16} />}</button>
            <button className={`bar-button status-detail ${panel === 'controls' && drawerTab === 'network' ? 'selected' : ''}`} title="Network" aria-label="Open network controls" onClick={() => openDrawer('network')}>{wifi ? <Wifi size={16} /> : <WifiOff size={16} />}</button>
            <button className={`bar-button optional ${bluetooth ? '' : 'status-off'} ${panel === 'controls' && drawerTab === 'bluetooth' ? 'selected' : ''}`} title="Bluetooth" aria-label="Open Bluetooth controls" onClick={() => openDrawer('bluetooth')}><Bluetooth size={15} /></button>
            <button className={`bar-button optional ${panel === 'controls' && drawerTab === 'power' ? 'selected' : ''}`} title="Battery · 100% (demo)" aria-label="Open power controls" onClick={() => openDrawer('power')}><BatteryFull size={20} /><span className="battery-reading">100</span></button>
          </div>
          <button className={`bar-button cybexos-button ${panel === 'controls' ? 'selected' : ''}`} title="Control Center" aria-label="Open control panel" aria-expanded={panel === 'controls'} onClick={() => openDrawer('overview')}><span className="cybexos-mark" aria-hidden="true" /></button>
        </div>
      </header>

      {!visible.length && <div className="empty-desktop"><button className="desktop-start-button" onClick={() => togglePanel('launcher')}><Grid2X2 size={16} />Open an app<kbd>alt + space</kbd></button></div>}
      <div className="window-layer" ref={windowLayer}><div className="window-canvas" style={{ height: canvasHeight }}>
        {[...windows].sort((a, b) => a.createdOrder - b.createdOrder).map(win => {
          const tileIndex = tiles.findIndex(tile => tile.id === win.id);
          const nextTileId = tileIndex >= 0 && tiles.length > 1 ? tiles[(tileIndex + 1) % tiles.length].id : undefined;
          return <div key={win.id} hidden={win.workspace !== workspace || win.minimized || !!maximized && maximized !== win.id}>
            <Window win={win} rect={geometry[win.id]} nextTileId={nextTileId} active={focused === win.id} zIndex={(win.floating ? 40 : 10) + windows.indexOf(win)} dispatch={actOnWindow}>{win.id === 'welcome' ? <WelcomeApp {...props} preferences={preferences} updatePreferences={updatePreferences} onFinish={() => actOnWindow({ type: 'close', id: 'welcome' })} /> : win.id === 'terminal' ? <TerminalApp {...props} /> : win.id === 'files' ? <FilesApp {...props} /> : win.id === 'notes' ? <NotesApp {...props} /> : win.id === 'settings' ? <SettingsApp preferences={preferences} updatePreferences={updatePreferences} notify={notify} /> : <ShortcutsApp />}</Window>
          </div>;
        })}
        {viewport.width >= 760 && tiles.length > 1 && !maximized && firstTile && <div className="split-divider" role="separator" tabIndex={0} aria-label="Main tile split" aria-orientation="vertical" aria-valuemin={30} aria-valuemax={70} aria-valuenow={Math.round(ratio * 100)} style={{ left: firstTile.x + firstTile.width, top: firstTile.y, height: firstTile.height, zIndex: 30 }}
          onPointerDown={event => { if (event.button !== 0) return; draggingSplit.current = true; event.currentTarget.setPointerCapture?.(event.pointerId); }}
          onPointerMove={event => { if (draggingSplit.current) setRatio((event.clientX - 10) / Math.max(1, viewport.width - 30)); }}
          onPointerUp={() => { draggingSplit.current = false; }} onPointerCancel={() => { draggingSplit.current = false; }}
          onKeyDown={event => {
            if (event.altKey || event.ctrlKey || event.metaKey) return;
            if (event.key === 'ArrowLeft' || event.key === 'ArrowRight') { event.preventDefault(); setRatio(ratio + (event.key === 'ArrowLeft' ? -0.02 : 0.02)); }
            if (event.key === 'Home' || event.key === 'End') { event.preventDefault(); setRatio(event.key === 'Home' ? 0.3 : 0.7); }
          }} />}
      </div></div>

      <footer className="desktop-footer"><span className="desktop-signature" title="Interactive browser preview of the CybexOS desktop">Browser preview</span><div className="desktop-taskbar" aria-label="Open applications" hidden={windows.filter(w => w.workspace === workspace).length < 2 && !windows.some(w => w.workspace === workspace && w.minimized)}>{windows.filter(w => w.workspace === workspace).map(w => { const Icon = ICONS[w.id]; return <button key={w.id} title={`${w.minimized ? 'Restore' : 'Focus'} ${APP_NAMES[w.id]}`} aria-label={`${w.minimized ? 'Restore' : 'Focus'} ${APP_NAMES[w.id]}`} className={focused === w.id ? 'focused' : ''} onClick={() => openApp(w.id)}><Icon size={15} /><span>{APP_NAMES[w.id]}</span>{w.minimized && <span className="minimized-dot" />}</button>; })}</div><div className="desktop-hints"><button onClick={() => togglePanel('launcher')} title="Open app launcher"><kbd>alt</kbd><kbd>space</kbd><span>to explore</span></button><button className="layout-toggle" aria-label="Tiling layout" title="Hyprland · dwindle layout" aria-expanded={panel === 'layout'} onClick={() => togglePanel('layout')}><PanelsTopLeft size={16} /></button><button className="fullscreen-button" aria-label="Toggle fullscreen" title="Toggle fullscreen" onClick={fullscreen}><Expand size={16} /></button></div></footer>

      {panel === 'launcher' && <Overlay label="App launcher" className="launcher-panel" close={() => setPanel(null)}><div className="launcher-search"><Search size={20} /><input autoComplete="off" aria-label="Search applications" placeholder="What would you like to do?" value={query} onChange={e => { setQuery(e.target.value); setSelected(0); }} onKeyDown={e => { if (e.key === 'ArrowDown') { e.preventDefault(); setSelected(i => (i + 1) % Math.max(1, filtered.length)); } if (e.key === 'ArrowUp') { e.preventDefault(); setSelected(i => (i + filtered.length - 1) % Math.max(1, filtered.length)); } if (e.key === 'Enter' && filtered[selected]) { e.preventDefault(); openApp(filtered[selected]); } }} /><kbd>esc</kbd></div><div className="launcher-section-label">APPLICATIONS <span>{filtered.length}</span></div><div className="launcher-results">{filtered.length ? filtered.map((id, index) => { const Icon = ICONS[id]; return <button key={id} className={selected === index ? 'highlighted' : ''} onPointerMove={() => setSelected(index)} onClick={() => openApp(id)}><span className={`launcher-app-icon icon-${id}`}><Icon size={21} /></span><span><strong>{APP_NAMES[id]}</strong><small>{APP_DESCRIPTIONS[id]}</small></span>{selected === index && <span className="launcher-enter">↵</span>}</button>; }) : <div className="launcher-empty"><Search size={28} /><p>No apps found for “{query}”.</p><button className="text-button" onClick={() => setQuery('')}>Show all applications</button></div>}</div><div className="launcher-footer"><span><kbd>↑</kbd><kbd>↓</kbd> navigate</span><span><kbd>↵</kbd> open</span><span>CYBEXOS</span></div></Overlay>}

      {panel === 'layout' && <Overlay label="Tiling layout" className="layout-panel" close={() => setPanel(null)}>
        <div className="panel-heading"><div><h2>Hyprland</h2><p>dwindle · workspace {workspace}</p></div><button className="icon-button" aria-label="Close tiling layout" onClick={() => setPanel(null)}><X size={18} /></button></div>
        <p className="layout-description">Open an app and the workspace makes room. Drag a titlebar onto another tile to swap them, or float a window to place it freely.</p>
        <label className="layout-slider"><span>Main split</span><input aria-label="Main tile width" type="range" min="30" max="70" value={Math.round(ratio * 100)} onChange={event => setRatio(Number(event.target.value) / 100)} /><output>{Math.round(ratio * 100)}%</output></label>
        <p className="inline-note">{viewport.width < 760 ? 'Narrow screens use a scrollable stack. Your split is kept for wider screens.' : 'Applies to two or more tiles. You can also drag the gap between them.'}</p>
        <div className="layout-actions"><button className="text-button" onClick={() => setRatio(0.5)}>Reset split</button><span>{tiles.length} tiled · {visible.filter(win => win.floating).length} floating</span></div>
        <div className="layout-shortcuts"><span>Focus a tile<kbd>alt + arrows</kbd></span><span>Swap tiles<kbd>alt + shift + arrows</kbd></span><span>Toggle floating<kbd>alt + V</kbd></span><span>Maximize / restore<kbd>alt + F</kbd></span></div>
        <button className="text-button" onClick={() => openApp('shortcuts')}>All keyboard shortcuts<ArrowRight size={13} /></button>
      </Overlay>}

      {panel === 'calendar' && <CalendarWithClock clock24={preferences.clock24} close={() => setPanel(null)} />}

      {panel === 'usage' && <ModelUsagePanel state={usage} dispatch={usageDispatch} provider={usageProvider} setProvider={setUsageProvider} close={() => setPanel(null)} />}

      {panel === 'controls' && <ControlDrawer tab={drawerTab} setTab={setDrawerTab} close={() => setPanel(null)} volume={volume} setVolume={setVolume} brightness={brightness} setBrightness={setBrightness} wifi={wifi} setWifi={setWifi} bluetooth={bluetooth} setBluetooth={setBluetooth} dnd={dnd} setDnd={value => { setDnd(value); setToast(''); }} preferences={preferences} updatePreferences={updatePreferences} notices={notices} setNotices={setNotices} openApp={openApp} lock={() => { setPanel(null); setLocked(true); }} />}

      {toast && <div className="toast" role="status"><span className="toast-icon"><Check size={16} /></span><div><strong>CybexOS</strong><p>{toast}</p></div><button aria-label="Dismiss message" onClick={() => setToast('')}><X size={14} /></button></div>}
    </div>
    {locked && <div className="lock-screen"><img src="/cybex-wordmark.svg" alt="Cybex" /><DesktopClock clock24={preferences.clock24} lock /><div className="lock-user"><span>V</span>Visitor</div><button autoFocus onClick={() => setLocked(false)}><LockKeyhole size={17} />Unlock demo<ArrowRight size={17} /></button><small>Just a pause. Your apps are right where you left them.</small></div>}
  </main>;
}
