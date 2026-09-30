'use client';

import { ArrowDownToLine, ArrowRight, Command, ExternalLink, Folder, Keyboard, Palette, Terminal, Zap } from 'lucide-react';
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
      <p className="welcome-lead">A desktop that gets out of your way.<br />Take a look around. Make yourself at home.</p>
      <div className="welcome-feature-grid">
        <button onClick={() => openApp('terminal')}><span className="feature-icon"><Terminal size={21} /></span><span><strong>Meet your terminal</strong><small>A familiar prompt. A fresh start.</small></span><ArrowRight size={16} /></button>
        <button onClick={() => openApp('settings')}><span className="feature-icon"><Palette size={21} /></span><span><strong>Make it yours</strong><small>Your colors. Your atmosphere.</small></span><ArrowRight size={16} /></button>
        <button onClick={() => openApp('files')}><span className="feature-icon"><Folder size={21} /></span><span><strong>Look around</strong><small>A place for everything you do.</small></span><ArrowRight size={16} /></button>
        <button onClick={() => openApp('shortcuts')}><span className="feature-icon"><Keyboard size={21} /></span><span><strong>Find your flow</strong><small>A few keys go a long way.</small></span><ArrowRight size={16} /></button>
      </div>
      <div className="welcome-tip"><Zap size={16} /><span>Five workspaces. Room for every train of thought.</span><span className="mini-workspaces"><b>1</b>2 3 4 5</span></div>
      <div className="welcome-bottom"><a href={`${REPOSITORY_URL}#install`} target="_blank" rel="noreferrer" className="red-button"><ArrowDownToLine size={16} />Get CybexOS<ExternalLink size={13} /></a><button className="text-button" onClick={() => openApp('notes')}>Start with a note<ArrowRight size={15} /></button></div>
      <p className="welcome-disclaimer">An interactive browser demo. No installation needed.<br />Files and system information are examples; notes stay in this browser.</p>
    </div>
  </div>;
}

export function ShortcutsApp() {
  const groups = [
    { title: 'Your browser desktop', rows: [['Open app launcher', 'Alt', 'Space'], ['Switch workspace', 'Alt', '1–5'], ['Open terminal', 'Alt', 'Enter'], ['Keyboard shortcuts', 'Alt', 'K'], ['Close a panel', 'Esc']] },
    { title: 'Inside your windows', rows: [['Move window', 'Drag title'], ['Maximize or restore', 'Double-click title'], ['Resize window', 'Drag corner'], ['Terminal history', '↑', '↓'], ['Clear terminal', 'Ctrl', 'L']] },
  ];
  return <div className="shortcuts-app"><div className="section-heading"><Command size={24} /><div><h2>A few keys. A little faster.</h2><p>Keep your hands where your ideas happen.</p></div></div>{groups.map(g => <section key={g.title}><h3>{g.title}</h3>{g.rows.map(([label, ...keys]) => <div className="shortcut-row" key={label}><span>{label}</span><span>{keys.map(k => <kbd key={k}>{k}</kbd>)}</span></div>)}</section>)}<p className="inline-note">The installed OS uses Super for its main shortcuts. This demo uses Alt to avoid most browser shortcuts. Your browser or desktop may reserve some combinations; every action is also available by clicking.</p></div>;
}
