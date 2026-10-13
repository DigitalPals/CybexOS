import { describe, expect, it } from 'vitest';
import { createUsageState, eligibleAccounts, providerSummary, usageReducer } from '../lib/model-usage';

const NOW = 1_700_000_000_000;
const HOUR = 60 * 60 * 1000;

describe('simulated subscription pool', () => {
  it('starts deterministically with fictional accounts and coherent sample activity', () => {
    const state = createUsageState(NOW);
    expect(createUsageState(NOW)).toEqual(state);
    expect(state.accounts.filter(account => account.provider === 'codex')).toHaveLength(3);
    expect(state.accounts.filter(account => account.provider === 'claude')).toHaveLength(3);
    for (const account of state.accounts) {
      const events = state.events.filter(event => event.accountId === account.id);
      expect(account.email).toMatch(/@example\.com$/);
      expect(account.requests).toBe(events.length);
      expect(account.tokens).toBe(events.reduce((sum, event) => sum + event.tokens, 0));
      expect(account.lastUsedAt).toBe(Math.max(...events.map(event => event.createdAt)));
    }
    expect(state.events[0].createdAt).toBeGreaterThan(state.events.at(-1)!.createdAt);
  });

  it('rotates each provider independently and skips an exhausted account', () => {
    let state = createUsageState(NOW);
    state = usageReducer(state, { type: 'request', provider: 'codex', now: NOW });
    expect(state.events[0].accountId).toBe('codex-personal');
    state = usageReducer(state, { type: 'request', provider: 'claude', now: NOW });
    expect(state.events[0].accountId).toBe('claude-personal');
    state = usageReducer(state, { type: 'request', provider: 'codex', now: NOW });
    expect(state.events[0].accountId).toBe('codex-studio');
    expect(state.lastRouted.claude).toBe('claude-personal');
  });

  it('preserves the rotation position when the last used account is paused', () => {
    let state = createUsageState(NOW);
    state = usageReducer(state, { type: 'request', provider: 'codex', now: NOW });
    state = usageReducer(state, { type: 'toggle-account', id: 'codex-personal' });
    state = usageReducer(state, { type: 'request', provider: 'codex', now: NOW + 1 });
    expect(state.events[0].accountId).toBe('codex-studio');
    expect(eligibleAccounts(state, 'codex').map(account => account.id)).toEqual(['codex-studio']);
    state = usageReducer(state, { type: 'toggle-account', id: 'codex-personal' });
    state = usageReducer(state, { type: 'request', provider: 'codex', now: NOW + 2 });
    expect(state.events[0].accountId).toBe('codex-personal');
  });

  it('fills the first eligible subscription then fails over on either quota limit', () => {
    let state = createUsageState(NOW);
    state = usageReducer(state, { type: 'routing', routing: 'fill-first' });
    state = { ...state, accounts: state.accounts.map(account => account.id === 'claude-studio'
      ? { ...account, weeklyRemaining: 1 } : account.id === 'claude-personal'
        ? { ...account, sessionRemaining: 0 } : account) };
    state = usageReducer(state, { type: 'request', provider: 'claude', now: NOW });
    expect(state.events[0].accountId).toBe('claude-studio');
    expect(state.accounts.find(account => account.id === 'claude-studio')!.weeklyRemaining).toBe(0);
    state = usageReducer(state, { type: 'request', provider: 'claude', now: NOW });
    expect(state.events[0].accountId).toBe('claude-backup');
    state = usageReducer(state, { type: 'request', provider: 'claude', now: NOW });
    expect(state.events[0].accountId).toBe('claude-backup');
  });

  it('attributes counters and consumption only to the routed subscription without mutating input', () => {
    const state = createUsageState(NOW);
    const snapshot = structuredClone(state);
    const next = usageReducer(state, { type: 'request', provider: 'codex', now: NOW });
    const event = next.events[0];
    for (const account of next.accounts) {
      const before = state.accounts.find(item => item.id === account.id)!;
      if (account.id !== event.accountId) expect(account).toEqual(before);
      else {
        expect(account.sessionRemaining).toBeLessThan(before.sessionRemaining);
        expect(account.weeklyRemaining).toBeLessThan(before.weeklyRemaining);
        expect(account.requests).toBe(before.requests + 1);
        expect(account.tokens).toBe(before.tokens + event.tokens);
        expect(account.lastUsedAt).toBe(NOW);
      }
    }
    expect(state).toEqual(snapshot);
  });

  it('keeps last used quota distinct from the best available pool quota', () => {
    let state = createUsageState(NOW);
    state = { ...state, accounts: state.accounts.map(account => account.id === 'codex-personal'
      ? { ...account, lastUsedAt: NOW, enabled: false, weeklyRemaining: 0 } : account) };
    const summary = providerSummary(state, 'codex');
    expect(summary).toMatchObject({ remaining: 0, poolRemaining: 72, eligible: 1, total: 3 });
    expect(summary.lastUsed?.id).toBe('codex-personal');
    const unused = { ...state, accounts: state.accounts.map(account => ({ ...account, lastUsedAt: null })) };
    expect(providerSummary(unused, 'codex')).toMatchObject({ remaining: 72, poolRemaining: 72, lastUsed: null });
  });

  it('uses routing history to break last-used ties for requests in the same millisecond', () => {
    let state = createUsageState(NOW);
    state = usageReducer(state, { type: 'request', provider: 'claude', now: NOW });
    state = usageReducer(state, { type: 'request', provider: 'claude', now: NOW });
    state = usageReducer(state, { type: 'request', provider: 'claude', now: NOW });
    expect(providerSummary(state, 'claude').lastUsed?.id).toBe('claude-studio');
  });

  it('refreshes timestamps without replenishing consumed quota early', () => {
    const consumed = usageReducer(createUsageState(NOW), { type: 'request', provider: 'codex', now: NOW });
    const refreshed = usageReducer(consumed, { type: 'refresh', now: NOW + 60_000 });
    expect(refreshed.accounts).toEqual(consumed.accounts);
    expect(refreshed.events).toEqual(consumed.events);
    expect(refreshed.updatedAt).toBe(NOW + 60_000);
  });

  it('replenishes elapsed windows independently without clearing activity or enabling accounts', () => {
    let state = createUsageState(NOW);
    state = usageReducer(state, { type: 'toggle-account', id: 'codex-studio' });
    const before = state.accounts[0];
    const refreshed = usageReducer(state, { type: 'refresh', now: before.sessionResetAt });
    expect(refreshed.accounts[0]).toEqual({
      ...before, sessionRemaining: 100, sessionResetAt: before.sessionResetAt + 5 * HOUR,
    });
    expect(refreshed.events).toEqual(state.events);
    const weekly = { ...state, accounts: [{ ...before, sessionResetAt: before.weeklyResetAt + HOUR }] };
    const weeklyRefresh = usageReducer(weekly, { type: 'refresh', now: before.weeklyResetAt });
    expect(weeklyRefresh.accounts[0]).toMatchObject({
      sessionRemaining: before.sessionRemaining, weeklyRemaining: 100,
      weeklyResetAt: before.weeklyResetAt + 7 * 24 * HOUR,
    });
  });

  it('advances reset windows beyond a large time jump and preserves their original cadence', () => {
    const state = createUsageState(NOW);
    const later = NOW + 400 * 24 * HOUR;
    const refreshed = usageReducer(state, { type: 'refresh', now: later });
    for (const [index, account] of refreshed.accounts.entries()) {
      expect(account.sessionRemaining).toBe(100);
      expect(account.weeklyRemaining).toBe(100);
      expect(account.sessionResetAt).toBeGreaterThan(later);
      expect(account.sessionResetAt).toBeLessThanOrEqual(later + 5 * HOUR);
      expect(account.weeklyResetAt).toBeGreaterThan(later);
      expect(account.weeklyResetAt).toBeLessThanOrEqual(later + 7 * 24 * HOUR);
      expect((account.sessionResetAt - state.accounts[index].sessionResetAt) % (5 * HOUR)).toBe(0);
      expect((account.weeklyResetAt - state.accounts[index].weeklyResetAt) % (7 * 24 * HOUR)).toBe(0);
    }
    expect(usageReducer(refreshed, { type: 'refresh', now: later })).toEqual(refreshed);
  });

  it('refreshes elapsed quotas before routing a request', () => {
    let state = createUsageState(NOW);
    state = { ...state, accounts: state.accounts.map(account => account.provider === 'codex'
      ? { ...account, sessionRemaining: 0 } : account) };
    const next = usageReducer(state, { type: 'request', provider: 'codex', now: state.accounts[0].sessionResetAt });
    expect(next.events[0]).toMatchObject({ status: 'ok', accountId: 'codex-studio' });
    expect(next.accounts[0].sessionRemaining).toBeLessThan(100);
    expect(next.accounts[0].sessionRemaining).toBeGreaterThan(0);
    expect(next.accounts[1].sessionRemaining).toBe(0);
  });

  it('bounds quotas and activity history and logs unavailable requests without usage', () => {
    let state = createUsageState(NOW);
    for (let index = 0; index < 120; index++) {
      state = usageReducer(state, { type: 'request', provider: 'codex', now: NOW + index });
    }
    expect(state.events).toHaveLength(24);
    expect(new Set(state.events.map(event => event.id)).size).toBe(24);
    expect(state.events[0]).toMatchObject({ status: 'unavailable', accountId: null, tokens: 0, latencyMs: 0 });
    expect(eligibleAccounts(state, 'codex')).toEqual([]);
    for (const account of state.accounts) {
      expect(account.sessionRemaining).toBeGreaterThanOrEqual(0);
      expect(account.weeklyRemaining).toBeGreaterThanOrEqual(0);
      expect(account.sessionRemaining).toBeLessThanOrEqual(100);
      expect(account.weeklyRemaining).toBeLessThanOrEqual(100);
    }
    const next = usageReducer(state, { type: 'request', provider: 'codex', now: NOW + 121 });
    expect(next.accounts).toEqual(state.accounts);
    expect(next.lastRouted).toEqual(state.lastRouted);
    expect(next.sequence).toBe(state.sequence + 1);
    expect(next.events[0].id).not.toBe(state.events[0].id);
  });

  it('does not route into paused accounts even when they have quota', () => {
    let state = createUsageState(NOW);
    for (const account of state.accounts.filter(account => account.provider === 'claude')) {
      state = usageReducer(state, { type: 'toggle-account', id: account.id });
    }
    const next = usageReducer(state, { type: 'request', provider: 'claude', now: NOW });
    expect(next.events[0].status).toBe('unavailable');
    expect(next.accounts).toEqual(state.accounts);
    expect(providerSummary(next, 'claude')).toMatchObject({ eligible: 0, poolRemaining: 0 });
  });

  it.each(['initialize', 'reset'] as const)('%s restores the demo with reset windows relative to now', type => {
    let state = usageReducer(createUsageState(NOW), { type: 'routing', routing: 'fill-first' });
    state = usageReducer(state, { type: 'request', provider: 'codex', now: NOW });
    state = usageReducer(state, { type: 'toggle-account', id: 'claude-studio' });
    expect(usageReducer(state, { type, now: NOW + HOUR })).toEqual(createUsageState(NOW + HOUR));
  });
});
