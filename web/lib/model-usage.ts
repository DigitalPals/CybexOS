export type ProviderId = 'codex' | 'claude';

export type UsageAccount = {
  id: string;
  provider: ProviderId;
  label: string;
  email: string;
  plan: string;
  enabled: boolean;
  sessionRemaining: number;
  weeklyRemaining: number;
  sessionResetAt: number;
  weeklyResetAt: number;
  lastUsedAt: number | null;
  requests: number;
  tokens: number;
};

export type UsageEvent = {
  id: string;
  provider: ProviderId;
  accountId: string | null;
  model: string;
  createdAt: number;
  status: 'ok' | 'unavailable';
  tokens: number;
  latencyMs: number;
};

export type UsageState = {
  accounts: UsageAccount[];
  events: UsageEvent[];
  sequence: number;
  updatedAt: number;
  routing: 'round-robin' | 'fill-first';
  lastRouted: Record<ProviderId, string | null>;
};

export type UsageAction =
  | { type: 'initialize' | 'refresh' | 'reset'; now: number }
  | { type: 'request'; provider: ProviderId; now: number }
  | { type: 'toggle-account'; id: string }
  | { type: 'routing'; routing: UsageState['routing'] };

const HOUR = 60 * 60 * 1000;
const SESSION_WINDOW = 5 * HOUR;
const WEEKLY_WINDOW = 7 * 24 * HOUR;
const HISTORY_LIMIT = 24;
const MODEL_NAMES: Record<ProviderId, string> = { codex: 'Codex', claude: 'Claude Sonnet' };

// Fictional demo data and consumption rules; these do not model provider billing.
export function createUsageState(now = 0): UsageState {
  const examples: Pick<UsageAccount, 'id' | 'provider' | 'label' | 'plan' | 'sessionRemaining' | 'weeklyRemaining'>[] = [
    { id: 'codex-studio', provider: 'codex', label: 'Studio', plan: 'Pro 20×', sessionRemaining: 72, weeklyRemaining: 84 },
    { id: 'codex-personal', provider: 'codex', label: 'Personal', plan: 'Pro 5×', sessionRemaining: 44, weeklyRemaining: 18 },
    { id: 'codex-backup', provider: 'codex', label: 'Backup', plan: 'Plus', sessionRemaining: 0, weeklyRemaining: 67 },
    { id: 'claude-studio', provider: 'claude', label: 'Studio', plan: 'Max 20×', sessionRemaining: 61, weeklyRemaining: 79 },
    { id: 'claude-personal', provider: 'claude', label: 'Personal', plan: 'Max 5×', sessionRemaining: 28, weeklyRemaining: 9 },
    { id: 'claude-backup', provider: 'claude', label: 'Backup', plan: 'Pro', sessionRemaining: 92, weeklyRemaining: 35 },
  ];
  const accounts: UsageAccount[] = examples.map((account, index) => ({
    ...account,
    email: `${account.id}@example.com`,
    enabled: true,
    sessionResetAt: now + (1.5 + index * 0.4) * HOUR,
    weeklyResetAt: now + (24 + index * 9) * HOUR,
    lastUsedAt: now - (index % 3 + 1) * 60_000 - (account.provider === 'codex' ? 15_000 : 0),
    requests: 1,
    tokens: 1800 + index * 460,
  }));
  const events = accounts.map<UsageEvent>((account, index) => ({
    id: `request-${index + 1}`,
    provider: account.provider,
    accountId: account.id,
    model: MODEL_NAMES[account.provider],
    createdAt: account.lastUsedAt!,
    status: 'ok',
    tokens: account.tokens,
    latencyMs: 640 + index * 115,
  })).sort((a, b) => b.createdAt - a.createdAt);
  return {
    accounts, events, sequence: events.length, updatedAt: now, routing: 'round-robin',
    lastRouted: { codex: 'codex-studio', claude: 'claude-studio' },
  };
}

export function eligibleAccounts(state: UsageState, provider: ProviderId): UsageAccount[] {
  return state.accounts.filter(account => account.provider === provider && account.enabled
    && account.sessionRemaining > 0 && account.weeklyRemaining > 0);
}

export function providerSummary(state: UsageState, provider: ProviderId) {
  const accounts = state.accounts.filter(account => account.provider === provider);
  const eligible = eligibleAccounts(state, provider);
  const lastUsed = accounts.reduce<UsageAccount | null>((latest, account) => {
    if (account.lastUsedAt === null) return latest;
    if (!latest || account.lastUsedAt > latest.lastUsedAt!
      || (account.lastUsedAt === latest.lastUsedAt && account.id === state.lastRouted[provider])) return account;
    return latest;
  }, null);
  const poolRemaining = Math.max(0, ...eligible.map(account => Math.min(account.sessionRemaining, account.weeklyRemaining)));
  return {
    remaining: lastUsed ? Math.min(lastUsed.sessionRemaining, lastUsed.weeklyRemaining) : poolRemaining,
    poolRemaining,
    eligible: eligible.length,
    total: accounts.length,
    lastUsed,
  };
}

function advanceReset(resetAt: number, now: number, window: number): number {
  return resetAt + (Math.floor((now - resetAt) / window) + 1) * window;
}

function refreshUsage(state: UsageState, now: number): UsageState {
  return {
    ...state,
    updatedAt: now,
    accounts: state.accounts.map(account => {
      const sessionElapsed = now >= account.sessionResetAt;
      const weeklyElapsed = now >= account.weeklyResetAt;
      if (!sessionElapsed && !weeklyElapsed) return account;
      return {
        ...account,
        sessionRemaining: sessionElapsed ? 100 : account.sessionRemaining,
        weeklyRemaining: weeklyElapsed ? 100 : account.weeklyRemaining,
        sessionResetAt: sessionElapsed ? advanceReset(account.sessionResetAt, now, SESSION_WINDOW) : account.sessionResetAt,
        weeklyResetAt: weeklyElapsed ? advanceReset(account.weeklyResetAt, now, WEEKLY_WINDOW) : account.weeklyResetAt,
      };
    }),
  };
}

function routeAccount(state: UsageState, provider: ProviderId): UsageAccount | undefined {
  const eligible = eligibleAccounts(state, provider);
  if (state.routing === 'fill-first') return eligible[0];
  const accounts = state.accounts.filter(account => account.provider === provider);
  const previous = accounts.findIndex(account => account.id === state.lastRouted[provider]);
  for (let offset = 1; offset <= accounts.length; offset++) {
    const account = accounts[(previous + offset) % accounts.length];
    if (eligible.includes(account)) return account;
  }
}

export function usageReducer(state: UsageState, action: UsageAction): UsageState {
  if (action.type === 'initialize' || action.type === 'reset') return createUsageState(action.now);
  if (action.type === 'refresh') return refreshUsage(state, action.now);
  if (action.type === 'routing') return { ...state, routing: action.routing };
  if (action.type === 'toggle-account') {
    return { ...state, accounts: state.accounts.map(account => account.id === action.id ? { ...account, enabled: !account.enabled } : account) };
  }
  if (action.type !== 'request') return state;

  const current = refreshUsage(state, action.now);
  const selected = routeAccount(current, action.provider);
  const sequence = current.sequence + 1;
  const tokens = selected ? 1200 + sequence * 977 % 3600 : 0;
  const event: UsageEvent = {
    id: `request-${sequence}`,
    provider: action.provider,
    accountId: selected?.id ?? null,
    model: MODEL_NAMES[action.provider],
    createdAt: action.now,
    status: selected ? 'ok' : 'unavailable',
    tokens,
    latencyMs: selected ? 420 + sequence * 137 % 1100 : 0,
  };
  return {
    ...current,
    sequence,
    accounts: current.accounts.map(account => account !== selected ? account : {
      ...account,
      sessionRemaining: Math.max(0, account.sessionRemaining - (4 + sequence % 3)),
      weeklyRemaining: Math.max(0, account.weeklyRemaining - (1 + sequence % 2)),
      requests: account.requests + 1,
      tokens: account.tokens + tokens,
      lastUsedAt: action.now,
    }),
    lastRouted: selected ? { ...current.lastRouted, [action.provider]: selected.id } : current.lastRouted,
    events: [event, ...current.events].slice(0, HISTORY_LIMIT),
  };
}
