import { afterEach, describe, expect, it, vi } from 'vitest';
import { act, fireEvent, render, screen } from '@testing-library/react';
import { Profiler } from 'react';
import { DesktopClock } from '../components/Clock';
import Desktop from '../components/Desktop';
import { ModelUsagePanel } from '../components/ModelUsagePanel';
import { createUsageState } from '../lib/model-usage';

const renders = vi.hoisted(() => ({ windows: 0 }));
vi.mock('../components/Window', async importOriginal => {
  const original = await importOriginal<typeof import('../components/Window')>();
  return { ...original, Window: (props: Parameters<typeof original.Window>[0]) => {
    renders.windows++;
    return <original.Window {...props} />;
  } };
});

afterEach(() => { vi.useRealTimers(); vi.unstubAllGlobals(); });

describe('scoped wall clocks', () => {
  it('ticks on the minute boundary and resynchronizes across midnight after sleep', () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date(2026, 9, 15, 23, 59, 59, 250));
    const commit = vi.fn();
    render(<Profiler id="clock" onRender={commit}><DesktopClock clock24 /></Profiler>);
    const before = commit.mock.calls.length;
    act(() => vi.advanceTimersByTime(749));
    expect(commit).toHaveBeenCalledTimes(before);
    act(() => vi.advanceTimersByTime(1));
    expect(screen.getByText('Fri 16')).toBeVisible();
    expect(screen.getByText('00:00')).toBeVisible();
    vi.setSystemTime(new Date(2026, 9, 17, 14, 32));
    fireEvent(document, new Event('visibilitychange'));
    expect(screen.getByText('Sat 17')).toBeVisible();
    expect(screen.getByText('14:32')).toBeVisible();
  });

  it('keeps unrelated desktop windows out of the clock update path', () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date(2026, 9, 15, 12, 34, 55));
    render(<Desktop />);
    const before = renders.windows;
    // Cross a displayed minute without reaching the existing 30s usage refresh.
    for (let second = 0; second < 20; second++) act(() => vi.advanceTimersByTime(1000));
    expect(renders.windows - before).toBe(0);
    expect(screen.getByText('12:35')).toBeVisible();
  });

  it('updates reset-due within a second while the usage panel is open', () => {
    vi.useFakeTimers();
    const start = new Date(2026, 9, 15, 12, 34, 10).getTime();
    vi.setSystemTime(start);
    const state = createUsageState(start);
    const account = state.accounts.find(item => item.provider === 'codex')!;
    account.weeklyResetAt = start + 1500;
    render(<ModelUsagePanel state={state} dispatch={vi.fn()} provider="codex" setProvider={vi.fn()} close={vi.fn()} />);
    expect(screen.queryByText('Reset due')).not.toBeInTheDocument();
    act(() => vi.advanceTimersByTime(2000));
    expect(screen.getByText('Reset due')).toBeVisible();
  });
});
