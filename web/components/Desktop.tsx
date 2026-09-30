'use client';

import { useCallback, useEffect, useReducer, useRef, useState, type CSSProperties } from 'react';
import { ArrowRight, BatteryFull, Bell, BellOff, Bluetooth, Check, ChevronLeft, ChevronRight, Command, Expand, Folder, Grid2X2, Keyboard, LockKeyhole, Monitor, Moon, Search, Settings2, SlidersHorizontal, StickyNote, Sun, Terminal, Volume2, VolumeX, Wifi, WifiOff, X } from 'lucide-react';
import { APP_DESCRIPTIONS, APP_IDS, APP_NAMES, STORAGE_KEY, accentInk, initialWindow, readPreferences, windowReducer } from '../lib/desktop';
import { DEFAULT_PREFERENCES, type AppId, type Preferences } from '../lib/types';
import { Window } from './Window';
import { WelcomeApp, ShortcutsApp } from './WelcomeApp';
import { TerminalApp } from './TerminalApp';
import { FilesApp } from './FilesApp';
import { NotesApp } from './NotesApp';
import { SettingsApp } from './SettingsApp';
import { Overlay } from './Overlay';
import { ModelUsageBar, ModelUsagePanel } from './ModelUsagePanel';
import { createUsageState, usageReducer, type ProviderId } from '../lib/model-usage';

const ICONS = { welcome: Command, terminal: Terminal, files: Folder, notes: StickyNote, settings: Settings2, shortcuts: Keyboard, usage: SlidersHorizontal };
type Panel = 'launcher' | 'controls' | 'calendar' | 'notifications' | 'usage' | null;

function Calendar({ now, close }: { now: Date; close: () => void }) {
  const [view, setView] = useState(() => new Date(now.getFullYear(), now.getMonth(), 1));
  const offset = (view.getDay() + 6) % 7;
  const count = new Date(view.getFullYear(), view.getMonth() + 1, 0).getDate();
  return <Overlay label="Calendar" className="calendar-panel" close={close}>
    <div className="calendar-intro"><span className="eyebrow">A LITTLE SPACE IN YOUR DAY</span><div className="calendar-time">{now.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', hour12: false })}</div><p>{now.toLocaleDateString([], { weekday: 'long', month: 'long', day: 'numeric' })}</p><span className="calendar-greeting"><Sun size={18} />Make room for something good.</span></div>
    <div className="calendar-main"><div className="panel-heading"><h2>{view.toLocaleDateString([], { month: 'long', year: 'numeric' })}</h2><div><button className="icon-button" aria-label="Previous month" onClick={() => setView(new Date(view.getFullYear(), view.getMonth() - 1, 1))}><ChevronLeft size={16} /></button><button className="icon-button" aria-label="Next month" onClick={() => setView(new Date(view.getFullYear(), view.getMonth() + 1, 1))}><ChevronRight size={16} /></button></div></div><div className="calendar-grid">{['M', 'T', 'W', 'T', 'F', 'S', 'S'].map((d, i) => <span className="weekday" key={`w${i}`}>{d}</span>)}{Array.from({ length: offset }, (_, i) => <span key={`s${i}`} />)}{Array.from({ length: count }, (_, i) => <span key={i} className={view.getFullYear() === now.getFullYear() && view.getMonth() === now.getMonth() && i + 1 === now.getDate() ? 'today' : ''}>{i + 1}</span>)}</div><button className="text-button" onClick={() => setView(new Date(now.getFullYear(), now.getMonth(), 1))}>Back to today<ArrowRight size={13} /></button></div>
  </Overlay>;
}

export default function Desktop() {
  const [preferences, setPreferences] = useState<Preferences>(DEFAULT_PREFERENCES);
  const [windows, dispatch] = useReducer(windowReducer, [initialWindow('welcome', 1)]);
  const [workspace, setWorkspace] = useState(1);
  const [panel, setPanel] = useState<Panel>(null);
  const [usage, usageDispatch] = useReducer(usageReducer, undefined, () => createUsageState());
  const [usageProvider, setUsageProvider] = useState<ProviderId>('codex');
  const [query, setQuery] = useState('');
  const [selected, setSelected] = useState(0);
  const [now, setNow] = useState<Date | null>(null);
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
    setNow(new Date());
    const interval = setInterval(() => setNow(new Date()), 1000);
    return () => { clearInterval(interval); if (toastTimer.current) clearTimeout(toastTimer.current); };
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
    requestAnimationFrame(() => {
      const app = document.querySelector<HTMLElement>(`[data-app="${id}"]`);
      if (!app || app.closest('[hidden]')) return;
      const editor = app.querySelector<HTMLElement>('input:not([type="radio"]):not([type="range"]),textarea');
      (editor || app).focus({ preventScroll: true });
    });
  }, [workspace]);

  function togglePanel(next: Panel) {
    setPanel(current => current === next ? null : next);
    setQuery(''); setSelected(0);
  }

  useEffect(() => {
    const handler = (event: KeyboardEvent) => {
      if (locked) { if (event.key === 'Escape') setLocked(false); return; }
      if (event.key === 'Escape') setPanel(null);
      if (!event.altKey || event.ctrlKey || event.metaKey) return;
      if (event.code === 'Space') { event.preventDefault(); setPanel(p => p === 'launcher' ? null : 'launcher'); setQuery(''); setSelected(0); }
      if (/^[1-5]$/.test(event.key)) { event.preventDefault(); setWorkspace(Number(event.key)); setPanel(null); }
      if (event.key === 'Enter') { event.preventDefault(); openApp('terminal'); }
      if (event.key.toLowerCase() === 'k') { event.preventDefault(); openApp('shortcuts'); }
    };
    window.addEventListener('keydown', handler);
    return () => window.removeEventListener('keydown', handler);
  }, [openApp, locked]);

  const filtered = APP_IDS.filter(id => `${APP_NAMES[id]} ${id} ${APP_DESCRIPTIONS[id]}`.toLowerCase().includes(query.toLowerCase()));
  const visible = windows.filter(w => w.workspace === workspace && !w.minimized);
  const focused = visible.at(-1)?.id;
  const props = { openApp, notify };
  const time = now?.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', hour12: !preferences.clock24 });
  const date = now?.toLocaleDateString('en-GB', { weekday: 'short', day: '2-digit' });

  async function fullscreen() {
    try {
      if (document.fullscreenElement) await document.exitFullscreen();
      else if (document.documentElement.requestFullscreen) await document.documentElement.requestFullscreen();
      else notify('Fullscreen is unavailable in this browser. Try your browser’s fullscreen option.');
    } catch { notify('Fullscreen was unavailable. You can keep exploring in this window.'); }
  }

  return <main className={`desktop theme-${preferences.theme} font-${preferences.font} ${preferences.glass ? 'glass-enabled' : ''} ${preferences.reducedMotion ? 'reduced-motion' : ''}`} style={{ '--accent': preferences.accent, '--accent-ink': accentInk(preferences.accent) } as CSSProperties}>
    <div className={`desktop-wallpaper wallpaper-${preferences.wallpaper}`} style={{ filter: `brightness(${brightness / 100})` }} />
    <div className="desktop-vignette" />
    <div className="desktop-interface" inert={locked || undefined}>
      <header className="menubar" aria-label="Desktop menubar">
        <div className="bar-left"><button className={`bar-button launcher-button ${panel === 'launcher' ? 'selected' : ''}`} title="Applications · Alt+Space" aria-label="Open app launcher" onClick={() => togglePanel('launcher')}><Grid2X2 size={17} /></button><div className="bar-divider" /><nav className="workspaces" aria-label="Workspaces">{[1, 2, 3, 4, 5].map(n => <button className={workspace === n ? 'current' : ''} key={n} aria-label={`Workspace ${n}`} aria-current={workspace === n ? 'page' : undefined} title={`Workspace ${n} · Alt+${n}`} onClick={() => { setWorkspace(n); setPanel(null); }}>{workspace === n || windows.some(w => w.workspace === n) ? n : <span className="workspace-dot" />}</button>)}</nav><div className="bar-divider optional" /><span className="active-app-name">{focused ? APP_NAMES[focused] : 'Desktop'}</span></div>
        <div className="bar-center"><button className={`bar-button clock-button ${panel === 'calendar' ? 'selected' : ''}`} aria-label="Open calendar" onClick={() => togglePanel('calendar')}><span>{date || 'CybexOS'}</span><span className="clock-separator">·</span><span>{time || 'Desktop'}</span></button><button className="bar-button notes-button" title="Omawrite" aria-label="Open notes" onClick={() => openApp('notes')}><StickyNote size={15} /></button></div>
        <div className="bar-right"><ModelUsageBar state={usage} active={panel === 'usage' ? usageProvider : null} open={provider => { setUsageProvider(provider); setPanel(current => current === 'usage' && usageProvider === provider ? null : 'usage'); }} /><span className="bar-demo-label">BROWSER DEMO</span><button className={`bar-button ${panel === 'notifications' ? 'selected' : ''}`} aria-label="Notifications" onClick={() => togglePanel('notifications')}>{dnd ? <BellOff size={15} /> : <Bell size={15} />}{notices.length > 0 && <span className="notification-dot" />}</button><button className={`bar-button status-cluster ${panel === 'controls' ? 'selected' : ''}`} aria-label="Open control panel" onClick={() => togglePanel('controls')}>{volume ? <Volume2 size={15} /> : <VolumeX size={15} />}{wifi ? <Wifi size={15} /> : <WifiOff size={15} />}<Bluetooth className="optional" size={14} /><BatteryFull className="optional" size={19} /><span className="optional">100%</span><SlidersHorizontal size={15} /></button></div>
      </header>

      {!visible.length && <div className="empty-desktop"><span className="empty-workspace-number">0{workspace}</span><h1>A little room to think.</h1><p>Workspace {workspace} is yours to make.</p><button className="desktop-start-button" onClick={() => togglePanel('launcher')}><Grid2X2 size={16} />Open an app<ArrowRight size={16} /></button></div>}
      <div className="window-layer">{windows.map((win, index) => <div key={win.id} hidden={win.workspace !== workspace || win.minimized}><Window win={win} active={focused === win.id} zIndex={10 + index} dispatch={dispatch}>{win.id === 'welcome' ? <WelcomeApp {...props} /> : win.id === 'terminal' ? <TerminalApp {...props} /> : win.id === 'files' ? <FilesApp {...props} /> : win.id === 'notes' ? <NotesApp {...props} /> : win.id === 'settings' ? <SettingsApp preferences={preferences} updatePreferences={updatePreferences} notify={notify} /> : <ShortcutsApp />}</Window></div>)}</div>

      <footer className="desktop-footer"><span className="desktop-signature"><span className="status-dot" />CYBEX<span className="signature-os">OS</span><span className="footer-preview"> / browser preview</span></span><div className="desktop-taskbar" aria-label="Open applications">{windows.filter(w => w.workspace === workspace).map(w => { const Icon = ICONS[w.id]; return <button key={w.id} title={`${w.minimized ? 'Restore' : 'Focus'} ${APP_NAMES[w.id]}`} aria-label={`${w.minimized ? 'Restore' : 'Focus'} ${APP_NAMES[w.id]}`} className={focused === w.id ? 'focused' : ''} onClick={() => openApp(w.id)}><Icon size={15} /><span>{APP_NAMES[w.id]}</span>{w.minimized && <span className="minimized-dot" />}</button>; })}</div><div className="desktop-hints"><button onClick={() => togglePanel('launcher')} title="Open app launcher"><kbd>alt</kbd><kbd>space</kbd><span>to explore</span></button><button className="fullscreen-button" aria-label="Toggle fullscreen" title="Toggle fullscreen" onClick={fullscreen}><Expand size={16} /></button></div></footer>

      {panel === 'launcher' && <Overlay label="App launcher" className="launcher-panel" close={() => setPanel(null)}><div className="launcher-search"><Search size={20} /><input autoComplete="off" aria-label="Search applications" placeholder="What would you like to do?" value={query} onChange={e => { setQuery(e.target.value); setSelected(0); }} onKeyDown={e => { if (e.key === 'ArrowDown') { e.preventDefault(); setSelected(i => (i + 1) % Math.max(1, filtered.length)); } if (e.key === 'ArrowUp') { e.preventDefault(); setSelected(i => (i + filtered.length - 1) % Math.max(1, filtered.length)); } if (e.key === 'Enter' && filtered[selected]) { e.preventDefault(); openApp(filtered[selected]); } }} /><kbd>esc</kbd></div><div className="launcher-section-label">APPLICATIONS <span>{filtered.length}</span></div><div className="launcher-results">{filtered.length ? filtered.map((id, index) => { const Icon = ICONS[id]; return <button key={id} className={selected === index ? 'highlighted' : ''} onPointerMove={() => setSelected(index)} onClick={() => openApp(id)}><span className={`launcher-app-icon icon-${id}`}><Icon size={21} /></span><span><strong>{APP_NAMES[id]}</strong><small>{APP_DESCRIPTIONS[id]}</small></span>{selected === index && <span className="launcher-enter">↵</span>}</button>; }) : <div className="launcher-empty"><Search size={28} /><p>No apps found for “{query}”.</p><button className="text-button" onClick={() => setQuery('')}>Show all applications</button></div>}</div><div className="launcher-footer"><span><kbd>↑</kbd><kbd>↓</kbd> navigate</span><span><kbd>↵</kbd> open</span><span>CYBEXOS</span></div></Overlay>}

      {panel === 'calendar' && now && <Calendar now={now} close={() => setPanel(null)} />}

      {panel === 'usage' && <ModelUsagePanel state={usage} dispatch={usageDispatch} provider={usageProvider} setProvider={setUsageProvider} now={now?.getTime() ?? usage.updatedAt} close={() => setPanel(null)} />}

      {panel === 'controls' && <Overlay label="Control panel" className="control-panel" close={() => setPanel(null)}><div className="panel-heading"><div><h2>Control panel</h2><p>Your desktop, at a glance.</p></div><button className="icon-button" aria-label="Close control panel" onClick={() => setPanel(null)}><X size={18} /></button></div><div className="control-identity"><div className="identity-icon"><Monitor size={24} /></div><div><strong>visitor@cybexos</strong><span>Browser session</span></div><span className="demo-tag">DEMO</span></div><div className="control-toggles"><button className={wifi ? 'on' : ''} aria-pressed={wifi} onClick={() => setWifi(v => !v)}>{wifi ? <Wifi size={22} /> : <WifiOff size={22} />}<strong>Wi-Fi</strong><small>{wifi ? 'Cybex network' : 'Disconnected'}</small></button><button className={bluetooth ? 'on' : ''} aria-pressed={bluetooth} onClick={() => setBluetooth(v => !v)}><Bluetooth size={22} /><strong>Bluetooth</strong><small>{bluetooth ? 'Discoverable' : 'Off'}</small></button><button className={preferences.theme === 'dark' ? 'on' : ''} aria-pressed={preferences.theme === 'dark'} onClick={() => updatePreferences({ theme: preferences.theme === 'dark' ? 'light' : 'dark' })}><Moon size={22} /><strong>Dark mode</strong><small>{preferences.theme === 'dark' ? 'A softer glow' : 'Light & bright'}</small></button><button className={dnd ? 'on' : ''} aria-pressed={dnd} onClick={() => { setDnd(v => !v); setToast(''); }}><BellOff size={22} /><strong>Focus</strong><small>{dnd ? 'Do not disturb' : 'Notifications on'}</small></button></div><div className="control-sliders"><label><Sun size={18} /><span>Brightness</span><input aria-label="Demo wallpaper brightness" type="range" min="30" max="100" value={brightness} onChange={e => setBrightness(Number(e.target.value))} /><output>{brightness}%</output></label><label>{volume ? <Volume2 size={18} /> : <VolumeX size={18} />}<span>Volume</span><input aria-label="Demo volume" type="range" min="0" max="100" value={volume} onChange={e => setVolume(Number(e.target.value))} /><output>{volume}%</output></label></div><p className="control-note">Network, audio, and battery are simulated. Brightness changes the demo wallpaper.</p><div className="control-links"><button onClick={() => openApp('settings')}><Settings2 size={17} /><span>Settings</span><ChevronRight size={16} /></button><button onClick={() => openApp('shortcuts')}><Keyboard size={17} /><span>Keyboard shortcuts</span><ChevronRight size={16} /></button></div><div className="control-bottom"><span><BatteryFull size={19} />100% · Demo battery</span><button className="icon-button" title="Lock demo" aria-label="Lock demo" onClick={() => { setPanel(null); setLocked(true); }}><LockKeyhole size={17} /></button></div></Overlay>}

      {panel === 'notifications' && <Overlay label="Notifications" className="notifications-panel" close={() => setPanel(null)}><div className="panel-heading"><div><h2>Notifications</h2><p>{dnd ? 'Focus is on. Enjoy the quiet.' : 'A little less to keep in your head.'}</p></div><button className="icon-button" aria-label="Close notifications" onClick={() => setPanel(null)}><X size={18} /></button></div><button className={`focus-row ${dnd ? 'on' : ''}`} aria-pressed={dnd} onClick={() => { setDnd(v => !v); setToast(''); }}><BellOff size={18} /><span>Do not disturb</span><span className="switch-track"><span /></span></button>{notices.length ? <><div className="notifications-label"><span>THIS SESSION</span><button className="text-button" onClick={() => setNotices([])}>Clear all</button></div>{notices.map((notice, i) => <div className="notification-card" key={`${notice}-${i}`}><div className="notification-app"><Command size={14} />CybexOS<span>Now</span></div><p>{notice}</p><button className="icon-button" aria-label={`Dismiss notification ${i + 1}`} onClick={() => setNotices(items => items.filter((_, n) => n !== i))}><X size={13} /></button></div>)}</> : <div className="notifications-empty"><Check size={30} /><h3>All caught up.</h3><p>Back to whatever matters.</p></div>}</Overlay>}

      {toast && <div className="toast" role="status"><span className="toast-icon"><Check size={16} /></span><div><strong>CybexOS</strong><p>{toast}</p></div><button aria-label="Dismiss message" onClick={() => setToast('')}><X size={14} /></button></div>}
    </div>
    {locked && <div className="lock-screen"><img src="/cybex-wordmark.svg" alt="Cybex" /><div className="lock-time">{time}</div><p>{now?.toLocaleDateString([], { weekday: 'long', month: 'long', day: 'numeric' })}</p><div className="lock-user"><span>V</span>Visitor</div><button autoFocus onClick={() => setLocked(false)}><LockKeyhole size={17} />Unlock demo<ArrowRight size={17} /></button><small>Just a pause. Your apps are right where you left them.</small></div>}
  </main>;
}
