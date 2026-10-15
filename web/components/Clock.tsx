'use client';

import { useEffect, useState } from 'react';
import { CalendarPanel } from './CalendarPanel';

// Align ticks to wall time and resync after sleep or a backgrounded tab.
// A minute-only display must not cause the desktop and hidden apps to render.
export function useWallTime(resolution = 60_000, enabled = true) {
  const [now, setNow] = useState<Date | null>(null);
  useEffect(() => {
    if (!enabled) return;
    let timer: ReturnType<typeof setTimeout>;
    const sync = () => {
      clearTimeout(timer);
      if (document.hidden) return;
      const timestamp = Date.now();
      setNow(new Date(timestamp));
      timer = setTimeout(sync, resolution - timestamp % resolution);
    };
    // Intentional post-hydration clock initialization keeps SSR deterministic.
    sync();
    document.addEventListener('visibilitychange', sync);
    window.addEventListener('focus', sync);
    window.addEventListener('pageshow', sync);
    return () => {
      clearTimeout(timer);
      document.removeEventListener('visibilitychange', sync);
      window.removeEventListener('focus', sync);
      window.removeEventListener('pageshow', sync);
    };
  }, [resolution, enabled]);
  return now;
}

export function DesktopClock({ clock24, lock = false }: { clock24: boolean; lock?: boolean }) {
  const now = useWallTime();
  const time = now?.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', hour12: !clock24 });
  return lock ? <><div className="lock-time">{time || '—:—'}</div><p>{now?.toLocaleDateString([], { weekday: 'long', month: 'long', day: 'numeric' })}</p></>
    : <><span className="clock-time">{time || '—:—'}</span><span className="clock-date">{now?.toLocaleDateString('en-GB', { weekday: 'short', day: '2-digit' }) || 'CybexOS'}</span></>;
}

export function CalendarWithClock(props: { clock24: boolean; close: () => void }) {
  const now = useWallTime();
  return now && <CalendarPanel {...props} now={now} />;
}
