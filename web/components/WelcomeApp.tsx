'use client';

import { ArrowDownToLine, ArrowRight, Command, ExternalLink, Folder, Keyboard, Palette, Terminal } from 'lucide-react';
import { REPOSITORY_URL, type AppProps } from '../lib/types';

export function WelcomeApp({ openApp }: AppProps) {
  return <div className="welcome-app app-copy">
    <aside className="welcome-art">
      <img className="welcome-wordmark" src="/cybex-wordmark.svg" alt="Cybex" />
      <div className="welcome-art-copy"><span className="eyebrow">YOUR DESKTOP. YOUR RULES.</span><h2>A little less friction.<br />A lot more flow.</h2><p>Fedora at its core.<br />Cybex in every detail.</p></div>
      <span className="welcome-art-footer"><span className="status-dot" /> FEDORA 44 · HYPRLAND · QUICKSHELL</span>
    </aside>
    <div className="welcome-content">
      <div className="welcome-kicker"><span className="red-dot" /> THE CYBEX OPINIONATED SYSTEM <span className="preview-pill">WEB PREVIEW</span></div>
      <h1>Welcome home<span>.</span></h1>
      <p className="welcome-lead">A desktop that gets out of your way.<br />Open a few apps. Your windows fall into place.</p>
      <div className="welcome-feature-grid">
        <button onClick={() => openApp('terminal')}><span className="feature-icon"><Terminal size={21} /></span><span><strong>Meet your terminal</strong><small>Fish, fastfetch, and a Fedora welcome.</small></span><ArrowRight size={16} /></button>
        <button onClick={() => openApp('settings')}><span className="feature-icon"><Palette size={21} /></span><span><strong>Make it yours</strong><small>Your colors. Your atmosphere.</small></span><ArrowRight size={16} /></button>
        <button onClick={() => openApp('files')}><span className="feature-icon"><Folder size={21} /></span><span><strong>Look around</strong><small>A place for everything you do.</small></span><ArrowRight size={16} /></button>
        <button onClick={() => openApp('shortcuts')}><span className="feature-icon"><Keyboard size={21} /></span><span><strong>Find your flow</strong><small>Tile, focus, and move with a few keys.</small></span><ArrowRight size={16} /></button>
      </div>
      <button className="welcome-tip welcome-usage-tip" onClick={() => openApp('usage')}><span aria-hidden="true" className="usage-provider-mark usage-mark-codex" /><span aria-hidden="true" className="usage-provider-mark usage-mark-claude" /><span>Six subscriptions. One place to keep track.</span><ArrowRight size={14} /></button>
      <div className="welcome-bottom"><a href={`${REPOSITORY_URL}#install`} target="_blank" rel="noreferrer" className="red-button"><ArrowDownToLine size={16} />Get CybexOS<ExternalLink size={13} /></a><button className="text-button" onClick={() => openApp('notes')}>Start with a note<ArrowRight size={15} /></button></div>
      <p className="welcome-disclaimer">An interactive browser demo. No installation needed.<br />Files and system information are examples; notes stay in this browser.</p>
    </div>
  </div>;
}

export function ShortcutsApp() {
  const groups = [
    { title: 'Your browser desktop', rows: [['Open app launcher', 'Alt', 'Space'], ['Switch workspace', 'Alt', '1–5'], ['Open terminal', 'Alt', 'Enter'], ['Keyboard shortcuts', 'Alt', 'K'], ['Close a panel', 'Esc']] },
    { title: 'Hyprland-style tiling', rows: [['Focus neighboring tile', 'Alt', '↑ ↓ ← →'], ['Swap neighboring tiles', 'Alt', 'Shift', '↑ ↓ ← →'], ['Move to workspace', 'Alt', 'Shift', '1–5'], ['Float or tile window', 'Alt', 'V'], ['Maximize or restore', 'Alt', 'F'], ['Swap tiles / move floating', 'Drag title'], ['Resize floating window', 'Drag corner'], ['Adjust the main split', 'Drag divider']] },
    { title: 'Inside your terminal', rows: [['Complete command or path', 'Tab'], ['Browse command history', '↑', '↓'], ['Cancel current command', 'Ctrl', 'C'], ['Clear terminal output', 'Ctrl', 'L'], ['Clear command line', 'Ctrl', 'U']] },
  ];
  return <div className="shortcuts-app"><div className="section-heading"><Command size={24} /><div><h2>A few keys. A little faster.</h2><p>Windows fall into place. Keep moving with your keyboard.</p></div></div>{groups.map(g => <section key={g.title}><h3>{g.title}</h3>{g.rows.map(([label, ...keys]) => <div className="shortcut-row" key={label}><span>{label}</span><span>{keys.map(k => <kbd key={k}>{k}</kbd>)}</span></div>)}</section>)}<p className="inline-note">Apps tile automatically. Moving a window to another workspace leaves you on the current one. Open Tiling layout in the footer to adjust the split and see shortcut hints.</p><p className="inline-note">Native Hyprland uses Super for its main shortcuts. This browser demo adapts them to Alt. Your browser or desktop may reserve some combinations; clickable controls are also available.</p></div>;
}
