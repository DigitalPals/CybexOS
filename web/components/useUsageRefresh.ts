'use client';

import { useEffect, type Dispatch } from 'react';
import type { UsageAction, UsageState } from '../lib/model-usage';

// Quotas only change at their reset deadlines. Keep an idle desktop out of
// React's update path, and catch up when a sleeping/backgrounded page returns.
export function useUsageRefresh(state: UsageState, dispatch: Dispatch<UsageAction>) {
  const initialized = state.updatedAt !== 0;
  const nextResetAt = Math.min(...state.accounts.flatMap(account => [account.sessionResetAt, account.weeklyResetAt]));

  useEffect(() => {
    dispatch({ type: 'initialize', now: Date.now() });
  }, [dispatch]);

  useEffect(() => {
    if (!initialized || !Number.isFinite(nextResetAt)) return;
    let timer: ReturnType<typeof setTimeout>;
    const sync = () => {
      clearTimeout(timer);
      if (document.hidden) return;
      const now = Date.now();
      if (now >= nextResetAt) dispatch({ type: 'refresh', now });
      // Timeouts use elapsed time. A cheap bounded check also notices a
      // foreground wall-clock correction without dispatching idle updates.
      else timer = setTimeout(sync, Math.min(30_000, nextResetAt - now));
    };
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
  }, [initialized, nextResetAt, dispatch]);
}
