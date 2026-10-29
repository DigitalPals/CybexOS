'use client';

import { useCallback, useEffect, useRef, useState, type Dispatch } from 'react';
import { Activity, ArrowRight, Check, ChevronDown, Clock3, Eye, EyeOff, Info, Pause, Play, RefreshCw, RotateCcw, Server, ShieldCheck, SlidersHorizontal, X } from 'lucide-react';
import { eligibleAccounts, providerSummary, usageReducer, type ProviderId, type UsageAccount, type UsageAction, type UsageState } from '../lib/model-usage';
import { Overlay } from './Overlay';
import { useWallTime } from './Clock';

export const PROVIDER_NAMES = { codex: 'Codex', claude: 'Claude' };
const PROVIDERS: ProviderId[] = ['codex', 'claude'];

function ProviderMark({ provider }: { provider: ProviderId }) {
  return <span aria-hidden="true" className={`usage-provider-mark usage-mark-${provider}`} />;
}

function remainingTone(remaining: number) {
  return remaining <= 10 ? 'critical' : remaining <= 25 ? 'warning' : 'healthy';
}

export function ModelUsageBar({ state, active, open }: { state: UsageState; active: ProviderId | null; open: (provider: ProviderId) => void }) {
  return <div className="model-usage-bar" aria-label="Model usage">
    {PROVIDERS.map(provider => {
      const summary = providerSummary(state, provider);
      const title = `${PROVIDER_NAMES[provider]} · ${summary.remaining}% remaining · ${summary.lastUsed ? `last used: ${summary.lastUsed.label}` : 'best available account'} · ${summary.eligible}/${summary.total} ready`;
      return <button key={provider} className={`bar-button usage-bar-chip ${remainingTone(summary.remaining)} ${active === provider ? 'selected' : ''}`} aria-label={`Open ${PROVIDER_NAMES[provider]} model usage`} aria-expanded={active === provider} title={title} onClick={() => open(provider)}>
        <ProviderMark provider={provider} /><span className="usage-bar-remaining">{summary.remaining}<small>%</small></span>
      </button>;
    })}
  </div>;
}

function duration(until: number, now: number) {
  const minutes = Math.max(0, Math.ceil((until - now) / 60000));
  if (minutes === 0) return 'Reset due';
  const days = Math.floor(minutes / 1440);
  const hours = Math.floor(minutes % 1440 / 60);
  return days ? `${days}d ${hours}h` : hours ? `${hours}h ${minutes % 60}m` : `${minutes}m`;
}

function compact(value: number) {
  return value >= 1e6 ? `${(value / 1e6).toFixed(2)}M` : value >= 1000 ? `${(value / 1000).toFixed(1)}k` : String(value);
}

function QuotaMeter({ label, remaining, resetAt, now }: { label: string; remaining: number; resetAt: number; now: number }) {
  return <div className={`usage-quota ${remainingTone(remaining)}`}>
    <div className="usage-quota-label"><span>{label}</span><strong>{remaining}<small>% left</small></strong></div>
    <div role="meter" aria-label={`${label} remaining`} aria-valuenow={remaining} aria-valuemin={0} aria-valuemax={100} className="usage-meter">
      {Array.from({ length: 30 }, (_, i) => <span key={i} className={i < Math.ceil(remaining * .3) ? 'filled' : ''} />)}
    </div>
    <div className="usage-reset"><Clock3 size={10} /><span>{resetAt <= now ? 'Reset due' : `Resets in ${duration(resetAt, now)}`}</span></div>
  </div>;
}

function AccountCard({ account, lastUsed, now, details, hideEmails, toggle }: { account: UsageAccount; lastUsed: boolean; now: number; details: boolean; hideEmails: boolean; toggle: () => void }) {
  const remaining = Math.min(account.sessionRemaining, account.weeklyRemaining);
  const unavailable = remaining === 0;
  return <article aria-label={`${PROVIDER_NAMES[account.provider]} ${account.label}`} className={`usage-account ${!account.enabled ? 'paused' : ''}`}>
    <div className="usage-account-heading">
      <span className="usage-account-symbol"><ProviderMark provider={account.provider} /></span>
      <div className="usage-account-identity"><h3>{account.plan}</h3><span>{hideEmails ? account.label : account.email}</span></div>
      {lastUsed && <span className="usage-last-used"><span />Last used</span>}
      <button className="icon-button" aria-label={`${account.enabled ? 'Pause' : 'Resume'} ${PROVIDER_NAMES[account.provider]} ${account.label}`} title={account.enabled ? 'Pause routing to this account' : 'Resume routing to this account'} onClick={toggle}>{account.enabled ? <Pause size={13} /> : <Play size={13} />}</button>
    </div>
    <QuotaMeter label="Weekly limit" remaining={account.weeklyRemaining} resetAt={account.weeklyResetAt} now={now} />
    {details && <QuotaMeter label="5-hour limit" remaining={account.sessionRemaining} resetAt={account.sessionResetAt} now={now} />}
    <div className="usage-account-footer"><span className={`usage-account-status ${!account.enabled ? 'muted' : remainingTone(remaining)}`}><span />{!account.enabled ? 'Paused' : unavailable ? 'Limit reached' : remaining <= 25 ? 'Running low' : 'Ready'}</span><span>{compact(account.requests)} requests<span className="usage-divider">·</span>{compact(account.tokens)} tokens</span></div>
  </article>;
}

type View = 'limits' | 'activity' | 'proxy';
interface ModelUsagePanelProps {
  state: UsageState;
  dispatch: Dispatch<UsageAction>;
  provider: ProviderId;
  setProvider: (provider: ProviderId) => void;
  now?: number;
  close: () => void;
}

export function ModelUsagePanel({ state, dispatch, provider, setProvider, now: suppliedNow, close }: ModelUsagePanelProps) {
  const [view, setView] = useState<View>('limits');
  const [details, setDetails] = useState(true);
  // Labels have minute precision, but their boundaries follow each quota or
  // request timestamp rather than wall-clock minutes. Wake exactly when a
  // displayed label can change, including sub-second reset deadlines.
  const nextUpdateAt = useCallback((now: number) => {
    let next = now + 60_000;
    if (view === 'limits') {
      for (const account of state.accounts) {
        if (account.provider !== provider) continue;
        for (const resetAt of details ? [account.weeklyResetAt, account.sessionResetAt] : [account.weeklyResetAt]) {
          if (resetAt > now) next = Math.min(next, resetAt - (Math.ceil((resetAt - now) / 60_000) - 1) * 60_000);
        }
      }
    } else if (view === 'activity') {
      for (const event of state.events) {
        if (event.provider !== provider) continue;
        const age = Math.max(0, now - event.createdAt);
        const resolution = age < 3_600_000 ? 60_000 : 3_600_000;
        next = Math.min(next, event.createdAt + (Math.floor(age / resolution) + 1) * resolution);
      }
    }
    return next;
  }, [state.accounts, state.events, provider, view, details]);
  const clock = useWallTime(60_000, suppliedNow === undefined && view !== 'proxy', nextUpdateAt);
  const now = suppliedNow ?? clock?.getTime() ?? state.updatedAt;
  const [hideEmails, setHideEmails] = useState(true);
  const [live, setLive] = useState(false);
  const [refreshed, setRefreshed] = useState(false);
  const [confirmReset, setConfirmReset] = useState(false);
  const refreshTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const [announcement, setAnnouncement] = useState('');
  const summary = providerSummary(state, provider);
  const accounts = state.accounts.filter(account => account.provider === provider);
  const events = state.events.filter(event => event.provider === provider);
  const ready = eligibleAccounts(state, provider).length;

  useEffect(() => {
    if (!live) return;
    // This clock generates local fixture traffic; it never contacts a proxy.
    const timer = setInterval(() => dispatch({ type: 'request', provider, now: Date.now() }), 5000);
    return () => clearInterval(timer);
  }, [live, provider, dispatch]);
  useEffect(() => () => { if (refreshTimer.current) clearTimeout(refreshTimer.current); }, []);

  function refresh() {
    dispatch({ type: 'refresh', now: Date.now() });
    setRefreshed(true);
    setAnnouncement('Demo quotas refreshed. Existing usage is preserved.');
    if (refreshTimer.current) clearTimeout(refreshTimer.current);
    refreshTimer.current = setTimeout(() => setRefreshed(false), 1800);
  }

  function sendRequest() {
    const action = { type: 'request', provider, now: Date.now() } as const;
    // Routing first rolls any elapsed quota windows forward. Announce that
    // result, rather than the possibly stale count currently on screen.
    const routed = usageReducer(state, action).events[0].status === 'ok';
    dispatch(action);
    setAnnouncement(routed ? `Demo ${PROVIDER_NAMES[provider]} request routed. Quotas and recent activity updated.` : `No eligible ${PROVIDER_NAMES[provider]} account. Resume an account or wait for its quota reset.`);
  }

  function reset() {
    dispatch({ type: 'reset', now: Date.now() });
    setLive(false); setConfirmReset(false);
    setAnnouncement('Six demo subscriptions restored. Your desktop preferences and notes are unchanged.');
  }

  return <Overlay label="Model Usage" className="model-usage-panel" close={close}>
    <div className="usage-panel-header"><div><div className="usage-eyebrow">YOUR MODELS, IN ONE PLACE</div><h2>Model Usage<span className="usage-demo-badge">DEMO</span></h2></div><div className="usage-header-actions"><button className="icon-button" aria-label="Refresh demo usage" title="Refresh usage" onClick={refresh}>{refreshed ? <Check size={16} /> : <RefreshCw size={16} />}</button><button className="icon-button" aria-label="Close model usage" onClick={close}><X size={17} /></button></div></div>

    <div className="usage-connection"><span className="usage-connected-dot" /><strong>CLIProxyAPI</strong><span>6 subscriptions</span><span className="usage-connection-right"><Server size={12} />Local proxy</span></div>
    <div className="usage-navigation" aria-label="Model usage views">{(['limits', 'activity', 'proxy'] as const).map(tab => { const Icon = tab === 'limits' ? Activity : tab === 'activity' ? Clock3 : SlidersHorizontal; return <button key={tab} aria-pressed={view === tab} onClick={() => { setView(tab); if (tab === 'proxy') setLive(false); }}><Icon size={13} />{tab === 'limits' ? 'Limits' : tab === 'activity' ? 'Activity' : 'Proxy'}</button>; })}</div>

    {view !== 'proxy' && <>
      <div className="usage-provider-tabs" aria-label="Provider selection">{PROVIDERS.map(id => <button key={id} aria-pressed={id === provider} onClick={() => setProvider(id)}><ProviderMark provider={id} /><span>{PROVIDER_NAMES[id]}</span><span className="usage-provider-count">{state.accounts.filter(a => a.provider === id).length}</span></button>)}</div>
      <div className="usage-pool-summary"><span>{ready} of {accounts.length} accounts ready</span><span><span className="usage-small-dot" />{state.routing === 'round-robin' ? 'Round robin' : 'Fill first'}</span></div>
    </>}

    {view === 'limits' && <>
      <div className="usage-accounts">{accounts.map(account => <AccountCard key={account.id} account={account} lastUsed={summary.lastUsed?.id === account.id} now={now} details={details} hideEmails={hideEmails} toggle={() => dispatch({ type: 'toggle-account', id: account.id })} />)}</div>
      <div className="usage-account-options"><button aria-expanded={details} onClick={() => setDetails(value => !value)}><ChevronDown size={13} className={details ? 'rotated' : ''} />{details ? 'Fewer limits' : 'Additional limits'}</button><button aria-pressed={!hideEmails} aria-label={hideEmails ? 'Show demo account emails' : 'Hide demo account emails'} onClick={() => setHideEmails(value => !value)}>{hideEmails ? <Eye size={13} /> : <EyeOff size={13} />}{hideEmails ? 'Show accounts' : 'Hide accounts'}</button></div>
      <div className="usage-reading-note"><Info size={12} /><p>Bar percentages follow the last-used account’s lowest remaining limit. Ready accounts can take the next request.</p></div>
    </>}

    {view === 'activity' && <div className="usage-activity">
      <div className="usage-activity-stats"><div><span>Requests</span><strong>{accounts.reduce((sum, account) => sum + account.requests, 0).toLocaleString('en-US')}</strong></div><div><span>Tokens</span><strong>{compact(accounts.reduce((sum, account) => sum + account.tokens, 0))}</strong></div><div><span>Available</span><strong>{ready}<small> / {accounts.length}</small></strong></div></div>
      <div className="usage-section-heading"><h3>Recent requests</h3><span>Demo session</span></div>
      <div className="usage-request-list">{events.map(event => {
        const account = state.accounts.find(a => a.id === event.accountId);
        const age = Math.max(0, Math.floor((now - event.createdAt) / 1000));
        return <article className={`usage-request ${event.status}`} key={event.id}><span className="usage-request-icon">{event.status === 'ok' ? <Check size={13} /> : <X size={13} />}</span><div><strong>{event.model}</strong><p>{account ? hideEmails ? account.label : account.email : 'No eligible account'}<span>·</span>{event.status === 'ok' ? `${compact(event.tokens)} tokens · ${event.latencyMs} ms` : 'Request not routed'}</p></div><time>{age < 60 ? 'Just now' : age < 3600 ? `${Math.floor(age / 60)}m ago` : `${Math.floor(age / 3600)}h ago`}</time></article>;
      })}</div>
      <p className="usage-footnote">A sample of requests routed through the demo proxy. Token counts and latency are illustrative.</p>
    </div>}

    {view === 'proxy' && <div className="usage-proxy">
      <div className="usage-proxy-title"><span><Server size={23} /></span><div><h3>CLIProxyAPI</h3><p>One endpoint. All your subscriptions.</p></div><span className="usage-proxy-connected">Connected<span>Simulation</span></span></div>
      <div className="usage-endpoint"><span>DEMO ENDPOINT</span><code>http://127.0.0.1:8317/v1</code><small>Display only · no network connection</small></div>
      <div className="usage-proxy-facts"><div><span>Authentication</span><strong><ShieldCheck size={13} />6 demo OAuth accounts</strong></div><div><span>Usage source</span><strong>CLIProxyAPI management</strong></div><div><span>API format</span><strong>OpenAI-compatible</strong></div></div>
      <fieldset className="usage-routing"><legend>Account routing</legend><label><input type="radio" name="proxy-routing" checked={state.routing === 'round-robin'} onChange={() => dispatch({ type: 'routing', routing: 'round-robin' })} /><span><strong>Round robin</strong><small>Share requests across available accounts.</small></span></label><label><input type="radio" name="proxy-routing" checked={state.routing === 'fill-first'} onChange={() => dispatch({ type: 'routing', routing: 'fill-first' })} /><span><strong>Fill first</strong><small>Use the first ready account, then fall back.</small></span></label></fieldset>
      <div className="usage-reading-note"><Info size={13} /><p>Paused accounts and accounts with an exhausted weekly or 5-hour limit are skipped automatically.</p></div>
      <div className="usage-simulation-note"><ShieldCheck size={17} /><p>All identities, subscriptions, and activity are fictional. No API key, sign-in, network request, or real subscription is used.</p></div>
      <button className="usage-reset-demo" aria-expanded={confirmReset} onClick={() => setConfirmReset(value => !value)}><RotateCcw size={13} />Reset demo subscriptions</button>
      {confirmReset && <div className="usage-reset-confirm" role="group" aria-label="Confirm usage reset"><p>Restore all six sample subscriptions and their activity?</p><div><button onClick={() => setConfirmReset(false)}>Cancel</button><button onClick={reset}>Reset usage demo</button></div></div>}
    </div>}

    {view !== 'proxy' && <div className="usage-demo-controls"><div><button className="usage-send-request" onClick={sendRequest}><Play size={12} />Send demo request<ArrowRight size={13} /></button><button className={`usage-live-toggle ${live ? 'is-live' : ''}`} aria-label="Auto demo traffic" aria-pressed={live} onClick={() => setLive(value => !value)}>{live ? <Pause size={12} /> : <Activity size={12} />}{live ? 'Pause' : 'Auto'}</button></div><p>{live ? `Simulating a ${PROVIDER_NAMES[provider]} request every 5 seconds while this panel is open.` : `Route a sample request through your ${PROVIDER_NAMES[provider]} subscriptions.`}</p></div>}
    <div className="usage-panel-footer"><span><span className="usage-small-dot" />{refreshed ? 'Refreshed just now' : 'CLIProxyAPI · simulated'}</span><span>Quota remaining, not spend</span></div>
    <span className="usage-sr-only" role="status">{announcement}</span>
  </Overlay>;
}
