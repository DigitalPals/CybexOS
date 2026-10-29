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

afterEach(() => { vi.useRealTimers(); vi.unstubAllGlobals(); vi.restoreAllMocks(); });

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
    // An idle hour includes 120 former quota polling intervals.
    act(() => vi.advanceTimersByTime(60 * 60_000));
    expect(renders.windows - before).toBe(0);
    expect(screen.getByText('13:34')).toBeVisible();
  });

  it('refreshes quotas at their exact deadline and catches up after a hidden tab wakes', () => {
    vi.useFakeTimers();
    const start = new Date(2026, 9, 15, 12, 0).getTime();
    vi.setSystemTime(start);
    const hidden = vi.spyOn(document, 'hidden', 'get').mockReturnValue(false);
    const view = render(<Desktop />);
    const codex = screen.getByRole('button', { name: 'Open Codex model usage' });
    expect(codex).toHaveAttribute('title', expect.stringContaining('72% remaining'));
    act(() => vi.advanceTimersByTime(90 * 60_000 - 1));
    expect(codex).toHaveAttribute('title', expect.stringContaining('72% remaining'));
    act(() => vi.advanceTimersByTime(1));
    expect(codex).toHaveAttribute('title', expect.stringContaining('84% remaining'));

    hidden.mockReturnValue(true);
    fireEvent(document, new Event('visibilitychange'));
    expect(vi.getTimerCount()).toBe(0);
    vi.setSystemTime(start + 8 * 24 * 60 * 60_000);
    fireEvent(window, new Event('focus'));
    expect(codex).toHaveAttribute('title', expect.stringContaining('84% remaining'));
    hidden.mockReturnValue(false);
    fireEvent(document, new Event('visibilitychange'));
    expect(codex).toHaveAttribute('title', expect.stringContaining('100% remaining'));
    view.unmount();
    expect(vi.getTimerCount()).toBe(0);
    hidden.mockRestore();
  });

  it('handles foreground clock corrections without refreshing unchanged quotas', () => {
    vi.useFakeTimers();
    const start = new Date(2026, 9, 15, 12, 0).getTime();
    vi.setSystemTime(start);
    const view = render(<Desktop />);
    const codex = screen.getByRole('button', { name: 'Open Codex model usage' });
    const before = renders.windows;

    vi.setSystemTime(start - 3 * 60 * 60_000);
    act(() => vi.advanceTimersByTime(30_000));
    expect(codex).toHaveAttribute('title', expect.stringContaining('72% remaining'));
    expect(renders.windows).toBe(before);

    vi.setSystemTime(start + 2 * 60 * 60_000);
    act(() => vi.advanceTimersByTime(29_999));
    expect(codex).toHaveAttribute('title', expect.stringContaining('72% remaining'));
    act(() => vi.advanceTimersByTime(1));
    expect(codex).toHaveAttribute('title', expect.stringContaining('84% remaining'));
    view.unmount();
    expect(vi.getTimerCount()).toBe(0);
  });

  it('renders usage countdowns only when their displayed minute changes and stops the clock in Proxy', () => {
    vi.useFakeTimers();
    const start = new Date(2026, 9, 15, 12, 34, 10).getTime();
    vi.setSystemTime(start);
    const commit = vi.fn();
    const view = render(<Profiler id="usage" onRender={commit}><ModelUsagePanel state={createUsageState(start)} dispatch={vi.fn()} provider="codex" setProvider={vi.fn()} close={vi.fn()} /></Profiler>);
    const before = commit.mock.calls.length;
    expect(screen.getByText('Resets in 1h 30m')).toBeVisible();
    act(() => vi.advanceTimersByTime(59_999));
    expect(commit).toHaveBeenCalledTimes(before);
    act(() => vi.advanceTimersByTime(1));
    expect(commit).toHaveBeenCalledTimes(before + 1);
    expect(screen.getByText('Resets in 1h 29m')).toBeVisible();
    fireEvent.click(screen.getByRole('button', { name: 'Proxy' }));
    expect(vi.getTimerCount()).toBe(0);
    const inProxy = commit.mock.calls.length;
    act(() => vi.advanceTimersByTime(5 * 60_000));
    expect(commit).toHaveBeenCalledTimes(inProxy);
    fireEvent.click(screen.getByRole('button', { name: 'Limits' }));
    expect(screen.getByText('Resets in 1h 24m')).toBeVisible();
    view.unmount();
    expect(vi.getTimerCount()).toBe(0);
  });

  it('updates activity ages at request-relative minute boundaries', () => {
    vi.useFakeTimers();
    const start = new Date(2026, 9, 15, 12, 34, 10).getTime();
    vi.setSystemTime(start);
    const state = createUsageState(start);
    state.events[0] = { ...state.events[0], createdAt: start - 59_900 };
    render(<ModelUsagePanel state={state} dispatch={vi.fn()} provider="claude" setProvider={vi.fn()} close={vi.fn()} />);
    fireEvent.click(screen.getByRole('button', { name: 'Activity' }));
    expect(screen.getAllByRole('article')[0]).toHaveTextContent('Just now');
    act(() => vi.advanceTimersByTime(100));
    expect(screen.getAllByRole('article')[0]).toHaveTextContent('1m ago');
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
