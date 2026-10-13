'use client';

import { useEffect, useRef, type ReactNode } from 'react';

export function Overlay({ label, className, children, close }: { label: string; className: string; children: ReactNode; close: () => void }) {
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const previous = document.activeElement as HTMLElement | null;
    const panel = ref.current;
    const first = panel?.querySelector<HTMLElement>('input,button:not([tabindex="-1"]),select,textarea,a[href]');
    (first || panel)?.focus();
    return () => { if (previous?.isConnected) previous.focus(); };
  }, []);
  return <div className={`overlay-layer ${className}-layer`} onPointerDown={e => { if (e.target === e.currentTarget) close(); }}>
    <div ref={ref} role="dialog" aria-modal="true" aria-label={label} tabIndex={-1} className={`shell-panel ${className}`} onKeyDown={e => {
      if (e.key === 'Escape') { e.stopPropagation(); close(); }
      if (e.key !== 'Tab') return;
      const items = Array.from(ref.current!.querySelectorAll<HTMLElement>('button:not(:disabled):not([tabindex="-1"]),input,select,textarea,a[href],[tabindex="0"]')).filter(el => el.getClientRects().length > 0);
      const first = items[0]; const last = items.at(-1);
      if (!first) { e.preventDefault(); return; }
      if (e.shiftKey && (document.activeElement === first || document.activeElement === ref.current)) { e.preventDefault(); last?.focus(); }
      else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first.focus(); }
    }}>{children}</div>
  </div>;
}
