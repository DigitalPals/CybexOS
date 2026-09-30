import { afterEach, describe, expect, it, vi } from 'vitest';
import { act, fireEvent, render, screen, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { useReducer } from 'react';
import Desktop from '../components/Desktop';
import { ModelUsagePanel } from '../components/ModelUsagePanel';
import { createUsageState, usageReducer } from '../lib/model-usage';
import { STORAGE_KEY } from '../lib/desktop';
import { DEFAULT_PREFERENCES } from '../lib/types';

afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllGlobals();
});

async function openUsage(user: ReturnType<typeof userEvent.setup>, provider = 'Codex') {
  await user.click(screen.getByRole('button', { name: `Open ${provider} model usage` }));
  return screen.getByRole('dialog', { name: 'Model Usage' });
}

function account(name: string) {
  return screen.getByRole('article', { name });
}

function remaining(name: string, window = 'Weekly limit') {
  return Number(within(account(name)).getByRole('meter', { name: `${window} remaining` }).getAttribute('aria-valuenow'));
}

describe('model usage desktop experience', () => {
  it('opens three distinct subscriptions per provider and expands their quota windows', async () => {
    const user = userEvent.setup();
    render(<Desktop />);
    const panel = await openUsage(user);
    expect(within(panel).getByText('CLIProxyAPI')).toBeVisible();
    expect(within(panel).getByText('6 subscriptions')).toBeVisible();
    expect(within(panel).getAllByRole('article')).toHaveLength(3);
    expect(within(account('Codex Studio')).getByRole('heading', { name: 'Pro 20×' })).toBeVisible();
    expect(within(account('Codex Personal')).getByRole('heading', { name: 'Pro 5×' })).toBeVisible();
    expect(within(account('Codex Backup')).getByRole('heading', { name: 'Plus' })).toBeVisible();
    expect(within(panel).getByText('2 of 3 accounts ready')).toBeVisible();
    expect(within(account('Codex Backup')).getByText('Limit reached')).toBeVisible();

    await user.click(within(panel).getByRole('button', { name: 'Fewer limits' }));
    expect(within(panel).queryByRole('meter', { name: '5-hour limit remaining' })).not.toBeInTheDocument();
    expect(within(panel).getAllByRole('meter', { name: 'Weekly limit remaining' })).toHaveLength(3);
    await user.click(within(panel).getByRole('button', { name: 'Additional limits' }));
    expect(within(panel).getAllByRole('meter', { name: '5-hour limit remaining' })).toHaveLength(3);

    await user.click(within(panel).getByRole('button', { name: /^Claude\s*3$/ }));
    expect(within(panel).getAllByRole('article')).toHaveLength(3);
    expect(screen.queryByRole('article', { name: 'Codex Studio' })).not.toBeInTheDocument();
    expect(within(account('Claude Studio')).getByRole('heading', { name: 'Max 20×' })).toBeVisible();
    expect(within(account('Claude Personal')).getByRole('heading', { name: 'Max 5×' })).toBeVisible();
    expect(within(account('Claude Backup')).getByRole('heading', { name: 'Pro' })).toBeVisible();
    expect(within(panel).getByText('3 of 3 accounts ready')).toBeVisible();
  });

  it('routes requests between available accounts and synchronizes quotas, the bar, and activity', async () => {
    const user = userEvent.setup();
    render(<Desktop />);
    const panel = await openUsage(user);
    const initialStudio = remaining('Codex Studio');
    const initialPersonal = remaining('Codex Personal');
    const backupSession = remaining('Codex Backup', '5-hour limit');
    const send = within(panel).getByRole('button', { name: 'Send demo request' });

    await user.click(send);
    expect(remaining('Codex Personal')).toBeLessThan(initialPersonal);
    expect(remaining('Codex Studio')).toBe(initialStudio);
    expect(within(account('Codex Personal')).getByText('Last used')).toBeVisible();
    expect(screen.getByRole('button', { name: 'Open Codex model usage' })).toHaveAttribute('title', expect.stringContaining('last used: Personal'));
    expect(screen.getByRole('button', { name: 'Open Codex model usage' })).toHaveTextContent(`${remaining('Codex Personal')}%`);

    await user.click(send);
    expect(remaining('Codex Studio')).toBeLessThan(initialStudio);
    expect(remaining('Codex Backup', '5-hour limit')).toBe(backupSession);
    expect(within(account('Codex Studio')).getByText('Last used')).toBeVisible();
    expect(screen.getByRole('button', { name: 'Open Codex model usage' })).toHaveAttribute('title', expect.stringContaining('last used: Studio'));
    await user.click(within(panel).getByRole('button', { name: 'Activity' }));
    const requests = within(panel).getAllByRole('article');
    expect(requests).toHaveLength(5);
    expect(requests[0]).toHaveTextContent('Studio');
    expect(requests[1]).toHaveTextContent('Personal');
    expect(requests[0]).toHaveTextContent(/tokens · \d+ ms/);
  });

  it('skips paused and exhausted accounts, records unavailable requests, and resumes routing', async () => {
    const user = userEvent.setup();
    render(<Desktop />);
    const panel = await openUsage(user);
    await user.click(within(panel).getByRole('button', { name: 'Pause Codex Studio' }));
    await user.click(within(panel).getByRole('button', { name: 'Pause Codex Personal' }));
    const initialPersonal = remaining('Codex Personal');
    expect(within(panel).getByText('0 of 3 accounts ready')).toBeVisible();
    await user.click(within(panel).getByRole('button', { name: 'Send demo request' }));
    expect(remaining('Codex Personal')).toBe(initialPersonal);
    expect(remaining('Codex Backup', '5-hour limit')).toBe(0);
    expect(within(panel).getByRole('status')).toHaveTextContent('No eligible Codex account');
    await user.click(within(panel).getByRole('button', { name: 'Activity' }));
    expect(within(panel).getAllByRole('article')[0]).toHaveTextContent('No eligible account');
    expect(within(panel).getAllByRole('article')[0]).toHaveTextContent('Request not routed');

    await user.click(within(panel).getByRole('button', { name: 'Limits' }));
    await user.click(within(panel).getByRole('button', { name: 'Resume Codex Personal' }));
    expect(within(panel).getByText('1 of 3 accounts ready')).toBeVisible();
    await user.click(within(panel).getByRole('button', { name: 'Send demo request' }));
    expect(remaining('Codex Personal')).toBeLessThan(initialPersonal);
    expect(within(account('Codex Personal')).getByText('Last used')).toBeVisible();
    expect(within(account('Codex Studio')).getByText('Paused')).toBeVisible();
  });

  it('changes proxy routing locally while keeping its displayed endpoint read-only', async () => {
    const fetch = vi.fn();
    vi.stubGlobal('fetch', fetch);
    const user = userEvent.setup();
    render(<Desktop />);
    const panel = await openUsage(user);
    const personalQuota = remaining('Codex Personal');
    await user.click(within(panel).getByRole('button', { name: 'Proxy' }));
    expect(within(panel).getByText('http://127.0.0.1:8317/v1')).toBeVisible();
    expect(within(panel).getByText('Display only · no network connection')).toBeVisible();
    expect(within(panel).queryByRole('textbox')).not.toBeInTheDocument();
    await user.click(within(panel).getByRole('radio', { name: /^Fill first/ }));
    expect(within(panel).getByRole('radio', { name: /^Fill first/ })).toBeChecked();
    await user.click(within(panel).getByRole('button', { name: 'Limits' }));
    await user.click(within(panel).getByRole('button', { name: 'Send demo request' }));
    const studioAfterFirst = remaining('Codex Studio');
    await user.click(within(panel).getByRole('button', { name: 'Send demo request' }));
    expect(remaining('Codex Studio')).toBeLessThan(studioAfterFirst);
    expect(remaining('Codex Personal')).toBe(personalQuota);

    await user.click(within(panel).getByRole('button', { name: 'Proxy' }));
    await user.click(within(panel).getByRole('radio', { name: /^Round robin/ }));
    await user.click(within(panel).getByRole('button', { name: 'Limits' }));
    await user.click(within(panel).getByRole('button', { name: 'Send demo request' }));
    expect(remaining('Codex Personal')).toBeLessThan(personalQuota);
    await user.click(within(panel).getByRole('button', { name: 'Refresh demo usage' }));
    expect(fetch).not.toHaveBeenCalled();
  });

  it('reveals only fictional emails and preserves consumption through refresh and reopening', async () => {
    const user = userEvent.setup();
    render(<Desktop />);
    let panel = await openUsage(user, 'Claude');
    expect(within(panel).queryByText(/@example\.com/)).not.toBeInTheDocument();
    await user.click(within(panel).getByRole('button', { name: 'Show demo account emails' }));
    expect(within(panel).getAllByText(/@example\.com$/)).toHaveLength(3);
    expect(within(account('Claude Studio')).getByText('claude-studio@example.com')).toBeVisible();
    await user.click(within(panel).getByRole('button', { name: /^Codex\s*3$/ }));
    expect(within(account('Codex Studio')).getByText('codex-studio@example.com')).toBeVisible();
    await user.click(within(panel).getByRole('button', { name: 'Hide demo account emails' }));
    expect(within(panel).queryByText(/@example\.com/)).not.toBeInTheDocument();
    await user.click(within(panel).getByRole('button', { name: 'Send demo request' }));
    const consumed = remaining('Codex Personal');
    await user.click(within(panel).getByRole('button', { name: 'Refresh demo usage' }));
    expect(remaining('Codex Personal')).toBe(consumed);
    expect(within(panel).getByRole('status')).toHaveTextContent('Existing usage is preserved');
    await user.click(within(panel).getByRole('button', { name: 'Close model usage' }));
    expect(screen.queryByRole('dialog', { name: 'Model Usage' })).not.toBeInTheDocument();
    panel = await openUsage(user);
    expect(remaining('Codex Personal')).toBe(consumed);
    expect(within(account('Codex Personal')).getByText('Last used')).toBeVisible();
    await user.keyboard('{Escape}');
    expect(screen.queryByRole('dialog', { name: 'Model Usage' })).not.toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Open Codex model usage' })).toHaveFocus();
  });

  it('confirms a usage reset and restores subscriptions without changing saved notes or preferences', async () => {
    const user = userEvent.setup();
    const preferences = JSON.stringify({ ...DEFAULT_PREFERENCES, theme: 'light' });
    localStorage.setItem(STORAGE_KEY, preferences);
    localStorage.setItem('cybexos-demo-notes-v1', 'Keep this note.');
    render(<Desktop />);
    const panel = await openUsage(user);
    const initialPersonal = remaining('Codex Personal');
    await user.click(within(panel).getByRole('button', { name: 'Send demo request' }));
    const consumed = remaining('Codex Personal');
    await user.click(within(panel).getByRole('button', { name: 'Pause Codex Studio' }));
    await user.click(within(panel).getByRole('button', { name: 'Proxy' }));
    await user.click(within(panel).getByRole('button', { name: 'Reset demo subscriptions' }));
    await user.click(within(within(panel).getByRole('group', { name: 'Confirm usage reset' })).getByRole('button', { name: 'Cancel' }));
    await user.click(within(panel).getByRole('button', { name: 'Limits' }));
    expect(remaining('Codex Personal')).toBe(consumed);
    expect(within(account('Codex Studio')).getByText('Paused')).toBeVisible();

    await user.click(within(panel).getByRole('button', { name: 'Proxy' }));
    await user.click(within(panel).getByRole('button', { name: 'Reset demo subscriptions' }));
    await user.click(within(within(panel).getByRole('group', { name: 'Confirm usage reset' })).getByRole('button', { name: 'Reset usage demo' }));
    expect(within(panel).queryByRole('group', { name: 'Confirm usage reset' })).not.toBeInTheDocument();
    await user.click(within(panel).getByRole('button', { name: 'Limits' }));
    expect(remaining('Codex Personal')).toBe(initialPersonal);
    expect(within(account('Codex Studio')).getByText('Ready')).toBeVisible();
    await user.click(within(panel).getByRole('button', { name: 'Activity' }));
    expect(within(panel).getAllByRole('article')).toHaveLength(3);
    expect(localStorage.getItem(STORAGE_KEY)).toBe(preferences);
    expect(localStorage.getItem('cybexos-demo-notes-v1')).toBe('Keep this note.');
    expect(screen.getByRole('main')).toHaveClass('theme-light');
  });

  it('announces successful routing when an exhausted session quota resets before the request', () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date('2026-09-30T10:00:00Z'));
    const initial = createUsageState(Date.now());
    initial.accounts = initial.accounts.map(value => value.provider === 'codex'
      ? { ...value, sessionRemaining: 0, sessionResetAt: Date.now() - 1 }
      : value);
    function ResetBoundaryPanel() {
      const [state, dispatch] = useReducer(usageReducer, initial);
      return <ModelUsagePanel state={state} dispatch={dispatch} provider="codex" setProvider={() => {}} now={initial.updatedAt} close={() => {}} />;
    }
    render(<ResetBoundaryPanel />);
    expect(screen.getByText('0 of 3 accounts ready')).toBeVisible();
    fireEvent.click(screen.getByRole('button', { name: 'Send demo request' }));
    expect(screen.getByRole('status')).toHaveTextContent('Demo Codex request routed.');
    expect(screen.getByText('3 of 3 accounts ready')).toBeVisible();
    expect(remaining('Codex Personal', '5-hour limit')).toBeGreaterThan(0);
    expect(remaining('Codex Personal', '5-hour limit')).toBeLessThan(100);
    expect(within(account('Codex Personal')).getByText('Last used')).toBeVisible();
    fireEvent.click(screen.getByRole('button', { name: 'Activity' }));
    expect(screen.getAllByRole('article')[0]).toHaveTextContent('Personal');
    expect(screen.queryByText('Request not routed')).not.toBeInTheDocument();
  });

  it('runs auto traffic only while enabled, stops in Proxy, and cleans up when the panel closes', () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date('2026-09-30T10:00:00Z'));
    const dispatch = vi.fn();
    const props = { state: createUsageState(Date.now()), dispatch, setProvider: vi.fn(), now: Date.now(), close: vi.fn() };
    const view = render(<ModelUsagePanel {...props} provider="codex" />);
    act(() => vi.advanceTimersByTime(5000));
    expect(dispatch).not.toHaveBeenCalled();
    fireEvent.click(screen.getByRole('button', { name: 'Auto demo traffic' }));
    act(() => vi.advanceTimersByTime(10000));
    expect(dispatch).toHaveBeenCalledTimes(2);
    expect(dispatch).toHaveBeenLastCalledWith({ type: 'request', provider: 'codex', now: Date.now() });

    view.rerender(<ModelUsagePanel {...props} provider="claude" />);
    act(() => vi.advanceTimersByTime(5000));
    expect(dispatch).toHaveBeenCalledTimes(3);
    expect(dispatch).toHaveBeenLastCalledWith({ type: 'request', provider: 'claude', now: Date.now() });
    fireEvent.click(screen.getByRole('button', { name: 'Proxy' }));
    act(() => vi.advanceTimersByTime(10000));
    expect(dispatch).toHaveBeenCalledTimes(3);
    fireEvent.click(screen.getByRole('button', { name: 'Limits' }));
    expect(screen.getByRole('button', { name: 'Auto demo traffic' })).toHaveAttribute('aria-pressed', 'false');
    act(() => vi.advanceTimersByTime(5000));
    expect(dispatch).toHaveBeenCalledTimes(3);
    fireEvent.click(screen.getByRole('button', { name: 'Auto demo traffic' }));
    act(() => vi.advanceTimersByTime(5000));
    expect(dispatch).toHaveBeenCalledTimes(4);
    fireEvent.click(screen.getByRole('button', { name: 'Auto demo traffic' }));
    act(() => vi.advanceTimersByTime(10000));
    expect(dispatch).toHaveBeenCalledTimes(4);
    fireEvent.click(screen.getByRole('button', { name: 'Auto demo traffic' }));
    view.unmount();
    act(() => vi.advanceTimersByTime(10000));
    expect(dispatch).toHaveBeenCalledTimes(4);
    expect(vi.getTimerCount()).toBe(0);
  });
});
