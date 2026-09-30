'use client';

import { useRef, type PointerEvent, type ReactNode } from 'react';
import { Maximize2, Minimize2, Minus, X } from 'lucide-react';
import { APP_NAMES, type WindowAction } from '../lib/desktop';
import type { DesktopWindow } from '../lib/types';

export function Window({ win, children, active, zIndex, dispatch }: { win: DesktopWindow; children: ReactNode; active: boolean; zIndex: number; dispatch: (action: WindowAction) => void }) {
  const ref = useRef<HTMLElement>(null);
  const pointer = useRef<{ kind: 'move' | 'resize'; x: number; y: number; left: number; top: number; width: number; height: number } | null>(null);
  function start(e: PointerEvent<HTMLElement>, kind: 'move' | 'resize') {
    if (e.button !== 0 || win.maximized || (e.target as HTMLElement).closest('button,select')) return;
    const r = ref.current!.getBoundingClientRect();
    pointer.current = { kind, x: e.clientX, y: e.clientY, left: r.left, top: r.top, width: r.width, height: r.height };
    e.currentTarget.setPointerCapture(e.pointerId);
  }
  function move(e: PointerEvent<HTMLElement>) {
    const p = pointer.current;
    if (!p) return;
    if (p.kind === 'move') dispatch({ type: 'move', id: win.id, x: Math.max(0, Math.min(innerWidth - Math.min(p.width, innerWidth), p.left + e.clientX - p.x)), y: Math.max(45, Math.min(innerHeight - 100, p.top + e.clientY - p.y)) });
    else dispatch({ type: 'resize', id: win.id, width: Math.min(innerWidth - p.left - 8, Math.max(360, p.width + e.clientX - p.x)), height: Math.min(innerHeight - p.top - 48, Math.max(280, p.height + e.clientY - p.y)) });
  }
  return <section ref={ref} tabIndex={-1} data-app={win.id} aria-label={`${APP_NAMES[win.id]} window`} className={`desktop-window ${active ? 'active' : ''} ${win.maximized ? 'maximized' : ''} window-${win.id}`} style={{ left: win.x < 0 ? `max(12px, calc((100vw - ${win.width}px) / 2))` : `clamp(8px, ${win.x}px, max(8px, calc(100vw - ${win.width}px - 8px)))`, top: `clamp(45px, ${win.y}px, calc(100dvh - 150px))`, width: win.width, height: win.height, zIndex }} onPointerDownCapture={() => !active && dispatch({ type: 'focus', id: win.id })} onFocusCapture={() => !active && dispatch({ type: 'focus', id: win.id })}>
    <header className="window-titlebar" onPointerDown={e => start(e, 'move')} onPointerMove={move} onPointerUp={() => { pointer.current = null; }} onPointerCancel={() => { pointer.current = null; }} onDoubleClick={e => { if (!(e.target as HTMLElement).closest('button,select')) dispatch({ type: 'maximize', id: win.id }); }}>
      <div className="window-label"><span className={`app-dot dot-${win.id}`} /><span>{APP_NAMES[win.id]}</span>{win.id === 'terminal' && <span className="window-subtitle">visitor@cybexos</span>}</div>
      <div className="window-controls"><select aria-label={`Move ${APP_NAMES[win.id]} to workspace`} value={win.workspace} onChange={e => dispatch({ type: 'workspace', id: win.id, workspace: Number(e.target.value) })}>{[1, 2, 3, 4, 5].map(n => <option key={n} value={n}>↗ {n}</option>)}</select><button aria-label={`Minimize ${APP_NAMES[win.id]}`} onClick={() => dispatch({ type: 'minimize', id: win.id })}><Minus size={14} /></button><button aria-label={`${win.maximized ? 'Restore' : 'Maximize'} ${APP_NAMES[win.id]}`} onClick={() => dispatch({ type: 'maximize', id: win.id })}>{win.maximized ? <Minimize2 size={13} /> : <Maximize2 size={13} />}</button><button className="close-window" aria-label={`Close ${APP_NAMES[win.id]}`} onClick={() => dispatch({ type: 'close', id: win.id })}><X size={15} /></button></div>
    </header>
    <div className="window-content">{children}</div>
    {!win.maximized && <div className="window-resize" aria-hidden="true" onPointerDown={e => start(e, 'resize')} onPointerMove={move} onPointerUp={() => { pointer.current = null; }} onPointerCancel={() => { pointer.current = null; }} />}
  </section>;
}
