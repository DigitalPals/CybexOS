'use client';

import { useRef, useState, type CSSProperties, type PointerEvent, type ReactNode } from 'react';
import { ArrowLeftRight, Maximize2, Minimize2, Minus, PanelsTopLeft, PictureInPicture2, X } from 'lucide-react';
import { APP_NAMES, type WindowAction } from '../lib/desktop';
import type { Rect } from '../lib/tiling';
import type { AppId, DesktopWindow } from '../lib/types';

interface WindowProps {
  win: DesktopWindow;
  children: ReactNode;
  active: boolean;
  zIndex: number;
  rect?: Rect;
  nextTileId?: AppId;
  dispatch: (action: WindowAction) => void;
}

export function Window({ win, children, active, zIndex, rect, nextTileId, dispatch }: WindowProps) {
  const ref = useRef<HTMLElement>(null);
  const [dragging, setDragging] = useState(false);
  const pointer = useRef<{ kind: 'move' | 'resize' | 'tile'; x: number; y: number; left: number; top: number; width: number; height: number; moved: boolean } | null>(null);

  function start(event: PointerEvent<HTMLElement>, kind: 'move' | 'resize') {
    if (event.button !== 0 || win.maximized || (event.target as HTMLElement).closest('button,select')) return;
    const bounds = ref.current!.getBoundingClientRect();
    pointer.current = { kind: win.floating ? kind : 'tile', x: event.clientX, y: event.clientY, left: bounds.left, top: bounds.top, width: bounds.width, height: bounds.height, moved: false };
    event.currentTarget.setPointerCapture?.(event.pointerId);
  }

  function move(event: PointerEvent<HTMLElement>) {
    const p = pointer.current;
    if (!p) return;
    if (Math.hypot(event.clientX - p.x, event.clientY - p.y) > 6) p.moved = true;
    if (p.kind === 'tile') { if (p.moved) setDragging(true); return; }
    if (p.kind === 'move') {
      dispatch({ type: 'move', id: win.id, x: Math.max(8, Math.min(innerWidth - Math.min(p.width, innerWidth - 16) - 8, p.left + event.clientX - p.x)), y: Math.max(46, Math.min(innerHeight - 100, p.top + event.clientY - p.y)) });
    } else {
      dispatch({ type: 'resize', id: win.id, width: Math.max(240, Math.min(innerWidth - p.left - 8, p.width + event.clientX - p.x)), height: Math.max(180, Math.min(innerHeight - p.top - 48, p.height + event.clientY - p.y)) });
    }
  }

  function finish(event: PointerEvent<HTMLElement>) {
    const p = pointer.current;
    pointer.current = null;
    setDragging(false);
    if (p?.kind !== 'tile' || !p.moved) return;
    const target = document.elementFromPoint(event.clientX, event.clientY)?.closest<HTMLElement>('[data-app][data-layout="tiled"]');
    const targetId = target?.dataset.app as AppId | undefined;
    if (targetId && targetId !== win.id) dispatch({ type: 'swap', id: win.id, targetId });
  }

  const floatingStyle: CSSProperties = {
    left: win.x < 0 ? `max(10px, calc((100vw - ${win.width}px) / 2))` : `clamp(8px, ${win.x}px, max(8px, calc(100vw - ${win.width}px - 8px)))`,
    top: `clamp(46px, ${win.y}px, calc(100dvh - 150px))`,
    width: win.width, height: win.height,
  };
  const position = rect ? { left: rect.x, top: rect.y, width: rect.width, height: rect.height } : floatingStyle;

  return <section ref={ref} tabIndex={-1} data-app={win.id} data-layout={win.floating ? 'floating' : 'tiled'} aria-label={`${APP_NAMES[win.id]} window`}
    className={`desktop-window ${win.floating ? 'floating' : 'tiled'} ${active ? 'active' : ''} ${win.maximized ? 'maximized' : ''} ${dragging ? 'tile-dragging' : ''} window-${win.id}`}
    style={{ ...position, zIndex }} onPointerDownCapture={() => !active && dispatch({ type: 'focus', id: win.id })} onFocusCapture={() => !active && dispatch({ type: 'focus', id: win.id })}>
    <header className="window-titlebar" title={win.floating ? 'Drag to move · double-click to maximize' : 'Drag onto another tile to swap · double-click to maximize'}
      onPointerDown={event => start(event, 'move')} onPointerMove={move} onPointerUp={finish}
      onPointerCancel={() => { pointer.current = null; setDragging(false); }}
      onDoubleClick={event => { if (!(event.target as HTMLElement).closest('button,select')) dispatch({ type: 'maximize', id: win.id }); }}>
      <div className="window-label"><span className={`app-dot dot-${win.id}`} /><span>{APP_NAMES[win.id]}</span><span className="window-layout-label">{win.maximized ? 'maximized' : win.floating ? 'floating' : 'tiled'}</span></div>
      <div className="window-controls">
        <select aria-label={`Move ${APP_NAMES[win.id]} to workspace`} value={win.workspace} onChange={event => dispatch({ type: 'workspace', id: win.id, workspace: Number(event.target.value) })}>{[1, 2, 3, 4, 5].map(n => <option key={n} value={n}>↗ {n}</option>)}</select>
        {!win.floating && <button aria-label={`Swap ${APP_NAMES[win.id]} with next tile`} title="Swap with next tile · Alt+Shift+arrows" disabled={!nextTileId || win.maximized} onClick={() => { if (nextTileId) dispatch({ type: 'swap', id: win.id, targetId: nextTileId }); }}><ArrowLeftRight size={13} /></button>}
        <button aria-label={`${win.floating ? 'Tile' : 'Float'} ${APP_NAMES[win.id]}`} title="Toggle floating · Alt+V" disabled={win.maximized} onClick={() => dispatch({ type: 'toggle-floating', id: win.id })}>{win.floating ? <PanelsTopLeft size={13} /> : <PictureInPicture2 size={13} />}</button>
        <button aria-label={`Minimize ${APP_NAMES[win.id]}`} onClick={() => dispatch({ type: 'minimize', id: win.id })}><Minus size={14} /></button>
        <button aria-label={`${win.maximized ? 'Restore' : 'Maximize'} ${APP_NAMES[win.id]}`} title="Maximize / restore · Alt+F" onClick={() => dispatch({ type: 'maximize', id: win.id })}>{win.maximized ? <Minimize2 size={13} /> : <Maximize2 size={13} />}</button>
        <button className="close-window" aria-label={`Close ${APP_NAMES[win.id]}`} onClick={() => dispatch({ type: 'close', id: win.id })}><X size={15} /></button>
      </div>
    </header>
    <div className="window-content">{children}</div>
    {win.floating && !win.maximized && <div className="window-resize" aria-hidden="true" onPointerDown={event => start(event, 'resize')} onPointerMove={move} onPointerUp={finish} onPointerCancel={() => { pointer.current = null; }} />}
  </section>;
}
