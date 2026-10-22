'use client';

import { ArrowRight, Check, Command, Folder, Keyboard, SlidersHorizontal, StickyNote, Terminal } from 'lucide-react';
import { type AppProps, type Preferences } from '../lib/types';

interface WelcomeAppProps extends AppProps {
  preferences: Preferences;
  updatePreferences: (patch: Partial<Preferences>) => void;
  onFinish: () => void;
}

const wallpapers = [
  { id: 'mountains', name: 'Moonlit peaks', accent: '#d3d283' },
  { id: 'aurora', name: 'Aurora', accent: '#a6c7a0' },
  { id: 'dusk', name: 'After hours', accent: '#e4aaa1' },
] as const;

export function WelcomeApp({ openApp, notify, preferences, updatePreferences, onFinish }: WelcomeAppProps) {
  return (
    <div className="welcome-app">
      <header className="welcome-header">
        <img className="welcome-wordmark" src="/nerdos-logo.svg" alt="NerdOS" width="225" height="30" />
        <span className="welcome-section-label">Your desktop</span>
      </header>

      <div className="welcome-intro">
        <h1>Welcome to your new desktop.</h1>
        <p>NerdOS — the Opinionated System. Pick a wallpaper to start: the desktop’s colors follow it. You can come back here any time from the app launcher.</p>
      </div>

      <section className="welcome-personalize" aria-labelledby="welcome-wallpapers-heading">
        <div className="welcome-section-heading">
          <h2 className="welcome-section-label" id="welcome-wallpapers-heading">Make it yours</h2>
          <span>On this desktop</span>
        </div>
        <div className="welcome-wallpapers" role="group" aria-label="Wallpapers">
          {wallpapers.map(({ id, name, accent }) => (
            <button key={id} type="button" className={`welcome-wallpaper wallpaper-${id}`}
              aria-label={`Use wallpaper ${name}`} aria-pressed={preferences.wallpaper === id}
              onClick={() => {
                updatePreferences({ wallpaper: id, accent });
                notify(`Wallpaper set to ${name}.`);
              }}>
              <span className="welcome-wallpaper-name">{name}</span>
              {preferences.wallpaper === id && <span className="welcome-wallpaper-check"><Check size={16} strokeWidth={2.5} aria-hidden="true" /></span>}
            </button>
          ))}
        </div>
      </section>

      <nav className="welcome-explore" aria-label="Explore this desktop">
        <button type="button" onClick={() => openApp('terminal')} aria-label="Meet your terminal" title="Meet your terminal"><Terminal size={16} aria-hidden="true" /><span>Terminal</span></button>
        <button type="button" onClick={() => openApp('files')} title="Look around your files"><Folder size={16} aria-hidden="true" /><span>Files</span></button>
        <button type="button" onClick={() => openApp('shortcuts')} title="Keyboard shortcuts"><Keyboard size={16} aria-hidden="true" /><span>Shortcuts</span></button>
        <button type="button" onClick={() => openApp('usage')} aria-label="Six subscriptions · Model usage" title="Six subscriptions. One place to keep track."><SlidersHorizontal size={16} aria-hidden="true" /><span>Model usage</span></button>
        <button type="button" onClick={() => openApp('notes')} title="Start with a note"><StickyNote size={16} aria-hidden="true" /><span>Notes</span></button>
      </nav>

      <footer className="welcome-footer">
        <div className="welcome-footer-copy">
          <button type="button" onClick={() => openApp('shortcuts')}>Press <span>Alt + K</span> to see every keyboard shortcut.</button>
          <p>Browser preview · No installation needed.</p>
        </div>
        <div className="welcome-actions">
          <button type="button" className="welcome-action" onClick={onFinish}>Get started<ArrowRight size={16} aria-hidden="true" /></button>
          <button type="button" className="welcome-action welcome-action-primary" onClick={() => openApp('settings')}>Settings</button>
        </div>
      </footer>
    </div>
  );
}

export function ShortcutsApp() {
  const groups = [
    { title: 'Your browser desktop', rows: [['Open app launcher', 'Alt', 'Space'], ['Switch workspace', 'Alt', '1–5'], ['Open terminal', 'Alt', 'Enter'], ['Keyboard shortcuts', 'Alt', 'K'], ['Close a panel', 'Esc']] },
    { title: 'Hyprland-style tiling', rows: [['Focus neighboring tile', 'Alt', '↑ ↓ ← →'], ['Swap neighboring tiles', 'Alt', 'Shift', '↑ ↓ ← →'], ['Move to workspace', 'Alt', 'Shift', '1–5'], ['Float or tile window', 'Alt', 'V'], ['Maximize or restore', 'Alt', 'F'], ['Swap tiles / move floating', 'Drag title'], ['Resize floating window', 'Drag corner'], ['Adjust the main split', 'Drag divider']] },
    { title: 'Inside your terminal', rows: [['Complete command or path', 'Tab'], ['Browse command history', '↑', '↓'], ['Cancel current command', 'Ctrl', 'C'], ['Clear terminal output', 'Ctrl', 'L'], ['Clear command line', 'Ctrl', 'U']] },
  ];
  return <div className="shortcuts-app"><div className="section-heading"><Command size={24} /><div><h2>A few keys. A little faster.</h2><p>Windows fall into place. Keep moving with your keyboard.</p></div></div>{groups.map(g => <section key={g.title}><h3>{g.title}</h3>{g.rows.map(([label, ...keys]) => <div className="shortcut-row" key={label}><span>{label}</span><span>{keys.map(k => <kbd key={k}>{k}</kbd>)}</span></div>)}</section>)}<p className="inline-note">Apps tile automatically. Moving a window to another workspace leaves you on the current one. Open Tiling layout in the footer to adjust the split and see shortcut hints.</p><p className="inline-note">Native Hyprland uses Super for its main shortcuts. This browser demo adapts them to Alt. Your browser or desktop may reserve some combinations; clickable controls are also available.</p></div>;
}
