# Fusebox widget

**Fusebox** watches a [Fusebox](https://github.com/DigitalPals/Fusebox) server
from the menubar: whether it is live, what has tripped and when it comes back,
the last hour of load, each account's health and quota, which clients are
connected, and the latest requests. It is the operator's view of the server. The built-in Model Usage
widget remains the place for quota history and cost estimates.

Like the other connected-service widgets, it is on for new installations,
including ISO installations, that select connected widgets. Otherwise it is
available but off. Upgrading places it immediately after Model Usage in
whichever column Model Usage occupies, and turns it on only for installations
with connected widgets. No connection starts until a server and key are set.

## Setting it up

Open Settings → Menubar → Widgets → Fusebox:

- **Server URL**: the address of Fusebox's dashboard, for example
  `https://fusebox.example.ts.net`. A pasted dashboard link such as
  `…/#/accounts` is accepted. User names, passwords and queries are refused.
- **Management key**: the server's `management-key`. The field is a password
  field. Committing it hands the key to `scripts/fusebox.py` over stdin, which
  writes it to `~/.config/cybexos/fusebox/management.key` (mode 0600 in a 0700
  directory, replaced atomically). The key is never stored in `shell.json` or
  on a command line. It is sent only to this server, as a bearer token in
  request headers, including the WebSocket upgrade, and never in a URL. The
  field's undo chip forgets the saved key.
- **Connection** shows whether the stream is live and how many accounts it
  sees, with **Reconnect**.
- **Menubar figure**: recent sessions (the default), requests in progress,
  requests in the last full minute, the number of faults, or connected
  clients (the keys and addresses in Fusebox's Connected now list). Recent sessions
  are the sessions Fusebox has seen in the last five minutes, summed over
  accounts: the count Fusebox's dashboard shows, so the widget and the
  dashboard agree. Fusebox's 30-minute `ongoing_sessions` count is not used;
  it can't tell a session waiting on you from one that has ended, so a closed
  session would keep counting for half an hour. Requests in progress count
  only while Fusebox waits on a provider, so they read 0 most of the time even
  while sessions are working: a coding session spends much of its time running
  tools or waiting for its user.
- **Quota meters**: **Used** (the default) or **Remaining**, like the Used /
  Remaining switch in Fusebox's dashboard. Remaining fills each meter with, and
  prints, the share left. The colours still measure use, as in Fusebox, so a
  window with 4% left stays red. The **Used | Left** switch beside Accounts in
  the dashboard changes the same setting.
- **Hide account emails** (on by default): account labels on Fusebox are
  usually email addresses. Hidden, accounts read as their provider and number
  ("Claude 2"), emails in error text are masked, and so are named clients,
  addresses and Tailscale logins, as in Fusebox's private mode. Programs such
  as Claude Code keep their names. The eye button in the dashboard header
  toggles the same setting.
- **Notify about faults** (off by default): a desktop notification when a new
  fault appears. Rate limits and pace warnings are excluded, as in Fusebox's
  own push notifications. Faults already present when the widget connects are
  not announced.

The server must accept remote management: set `management-key`, and do not
set `management-allow-remote: false`, when Fusebox is behind Tailscale Serve
or another proxy.

## The menubar

A healthy server shows its mark and the chosen figure. The figure is dimmed
when it is zero. The mark gains an amber badge for a fault that clears by
itself (a used-up limit, a rate limit or a large usage database) and a red one
for faults that fail requests (expired sign-ins, account errors, three or more
failed requests in an hour, a provider with no usable account, or a nearly
full disk under the usage database) and for a lost connection, a rejected key
or a lockout. Pace warnings are listed in the dashboard but, as in Fusebox's
own badge, never badge the mark or count as faults: they can hold for days
and ask for no action. The tooltip summarises the state and the first fault.

## The dashboard

Click the chip for the dashboard. Every row sits on one grid: icons in a
column on the left, names and text from the same edge after it, and values
ending at the same right edge, so meters, statuses and times line up down
the page.

- **Header**: the server's host, Fusebox version and uptime, a
  Live/Reconnecting/Restarting/Offline/Key rejected/Locked out/Connecting
  pill, and the privacy toggle. A reconnect that takes less than half a
  minute changes only the pill; after that, or straight away for a rejected
  key or a lockout, a box says what is wrong, the readings dim and the
  menubar badge turns red.
- **Faults**, errors first, each with its account and, when it clears by
  itself, "Back at 16:40, in 1h 12m". A pace warning ("Weekly limit runs out
  early at this pace", naming the client that used most of it) says when its
  window renews instead; a storage fault opens the Usage page. A fault opens
  the dashboard page Fusebox links it to. **×** (or Delete on a focused fault)
  dismisses it: it leaves the list, the menubar badge and the Faults figure
  while it lasts, and **Show** beside "1 dismissed" on the section title
  brings it back. A fault whose expected end changes is a new incident and
  shows again; one that clears (unseen for 15 minutes, so a Fusebox restart
  doesn't count) is forgotten and shows the next time it trips. Dismissals are
  kept in `~/.local/state/cybexos/shell/fusebox.json`.
- **Load**: one card with requests in progress, requests in the last full
  minute, failures in the last hour and the median time to first token of
  recent successful requests, over one bar per minute for the last hour,
  failed requests in red and the current minute highlighted.
- **Accounts**, grouped by provider, subscriptions before API keys. A group's
  head carries the provider's mark and name and its plan ("3 × Max 20x",
  "2 Max 20x, 1 Pro"; Codex Pro tiers read Pro 100, Pro 200 or Pro 500), so
  rows repeat a plan only when the group's plans differ. For two or more
  subscriptions the head also shows their **combined weekly** use, its meter
  in the accounts' weekly column, and how many points over or under even pace
  that is. Accounts count by their plan's monthly price (Claude Pro 1, Max 5x
  5, Max 20x 10) when every plan is known, and equally otherwise, as on
  Fusebox's overview. Each account row has its name, status and two meters
  filling the second line. A healthy account shows its sessions from the last
  five minutes ("2 sessions"), or Ready when it has none; one serving
  requests without a session shows Serving 1. Otherwise the status is Cooling
  1h 41m, Error, Sign-in expired or Off. The 5-hour and weekly meters have 20
  blocks of 5%, amber from 75% used and red from 95%, matching Fusebox's
  dashboard. They read as the share used or left, switched with **Used |
  Left** in the section header. A thin mark on each meter stands where even
  use over the window would be by now; it turns amber when the pace so far
  would use the window up before it resets.
- **Account details**, on click, on the same text column: provider, sign-in
  kind and last use; boxes for paused models and the last error with their
  action (**Clear** for cooldowns and errors, **Sign in** for an expired
  sign-in, which opens the dashboard); a strip of requests, failures, pinned
  coding sessions and how long the sign-in stays valid; for each meter's
  window, how fast it is being used ("3% an hour"), when it resets, is back
  or runs out early at this pace, and **who used it**: Fusebox's estimate of
  each client's share in points of the window, with use from outside
  Fusebox and from before it looked; the account's own load over the last
  hour; up to four pinned sessions with recent requests, each with its
  program and model, what it used of the windows ("4% of week · 11% of 5h")
  and the client key and address it came from (older ones are counted);
  banked resets (see below); **New sessions: First | Normal | Last**, the
  account's priority, as on its dashboard page; and **Refresh** (sign-in and
  quota, for OAuth accounts), **Turn off**/**Turn on** and **Open** in the
  dashboard. Turning an account off asks for a second click within four
  seconds.
- **Activity**: one card, one line per item. First Fusebox's Connected now
  list: the keys and addresses with requests in flight, an open socket, or a
  request in the last five minutes, busy ones first. Then **budgets** for
  named clients with a daily token or monthly spending limit: how far through
  each they are, amber from 75% and red from 95%. Then the five most recent
  requests: the provider's mark, the model, the account and the named client
  key it came with, a coloured status and the time. A failed request's reason
  follows in red. Time to first token, tokens and transport tags are read to
  screen readers. Releases without `/api/clients/usage` show only requests.

Removing accounts and signing in again stay in Fusebox's own dashboard:
sign-in redirects to fixed localhost ports on the server. **Dashboard** in the
footer opens it.

## Banked resets

When the server has `banked-resets` turned on, a Claude or ChatGPT (Codex)
subscription with saved resets shows a panel in its expanded account. It
follows Fusebox's own reset dialog (see Fusebox's
[banked resets documentation](https://github.com/DigitalPals/Fusebox/blob/main/docs/banked-resets.md)):

- The panel says what Fusebox does about the soonest-expiring reset by itself.
  With automatic redemption on (smart-quota routing and
  `banked-reset-policy.auto-redeem`), Fusebox uses one at 95% weekly use, or an
  hour before it expires, and gives the account new work first until then;
  otherwise the panel says when the reset expires. A redemption Fusebox is
  about to make is shown in amber, also in the confirmation.

- **Details** reads the reset status: each grant with how many are left, its
  expiry and which limits it clears, and why one can't be used. Fusebox asks the
  provider for this, but nothing is spent. **Recheck** runs Fusebox's quota
  refresh.
- **Use 1 reset** is enabled only with status checked in the last five minutes,
  an eligible inventory, a confirmation from Fusebox, the account turned on and
  no unresolved earlier spend. It reads the status once more and asks: "Use 1
  reset on …? This spends one saved reset and can't be undone." Claude
  subscriptions with several usable grants choose one; Codex chooses its own.
  The question counts down from Fusebox's two-minute confirmation (the widget
  withdraws it at 1:50) and starts with the keyboard on **Back**. Only **Apply
  reset** spends.
- The result is Fusebox's own message, such as "One banked reset applied".
- If a spend's answer is lost (a timeout, a dropped connection, a server error),
  the widget never sends it again. It says a reset may have been used and reads
  the status. An unresolved spend blocks further resets on that subscription
  until it's resolved: the account shows **Review reset**, the menubar badge turns
  amber and its tooltip says so. The panel then offers **Retry request** (Claude,
  within Fusebox's ten-minute window, sending the saved request with the same
  IDs, behind its own confirmation) and **Check outcome**, which records **Reset
  was used** or **No reset was used** after you check the provider account.
  Recording sends nothing to the provider.

Fusebox enforces these rules itself: it journals each spend before sending it,
locks the subscription, refuses a confirmation whose inventory has changed and
never retries. Spending is only possible from the panel; IPC and the helper's
read commands can't spend.

## Faults and Fusebox versions

Fusebox releases with the faults API (`GET /api/faults` and the `faults` live
event; see Fusebox's
[notifications documentation](https://github.com/DigitalPals/Fusebox/blob/main/docs/notifications.md#reading-faults-from-other-tools))
supply the same list as its faults menu and push notifications, including
failed-request and whole-provider faults. Their entries carry no countdown
text, so the stream only sends real changes, and the widget counts down to
`until` itself.

`pace` and `storage` faults carry `badge: false` and `badge: true`; the widget
keeps them, and leaves pace warnings out of its badge, its Faults figure and
notifications, as Fusebox leaves them out of its own badge and pushes.

Older releases answer unknown `/api` paths with 401 through client-key
authentication. Because `/api/accounts` has just accepted the same key, the
widget then works out sign-in, used-up-limit, rate-limit and account-error
faults from account state, using the same rules, and says so under the faults.
It never guesses failed-request or provider faults, which need the server's
request history.

## Implementation and lifecycle

`Common/Fusebox.qml` owns one `Process` for the whole shell, independent of
monitor count. It runs while the widget is on, or while its dashboard or
settings are open, and a server and key are set. `scripts/fusebox.py live`
holds one WebSocket to `/api/live`. On every connect it first reads
`/api/overview`, `/api/accounts`, `/api/requests?limit=40` and `/api/faults`,
then forwards `load`, `faults`, `request` and `tick` events. Line-delimited
JSON goes to the shell. Requests ask for gzip, which Fusebox's API answers
with; bodies are inflated no further than the 2 MB response limit. Account
changes are refetched at most every three seconds after Fusebox announces
them, and every minute otherwise. `/api/clients/usage` is read every 15
seconds and sent on only when it changed. When named clients exist, their
limits come from `/api/config/settings` once a minute: that answer is the
whole configuration, provider and client keys included, so the helper reads
only each named client's id, label and limits from it. Shared keys in the
connected list lose their id; only named client ids and program names reach
QML. Releases without `/api/clients/usage` refuse it with 401, as above; the
helper then stops asking until the next connection. The helper verifies TLS, ignores
proxy environment variables, refuses redirects so the key cannot follow one,
bounds response and frame sizes, and never prints exception text.

Only allowlisted fields reach QML. `/api/overview` also contains client API
keys, the server's base URL and its configuration paths. These are dropped in
the helper, along with session fingerprints, routing attempts and account
file names. IPC status reports counts, never account names.

Reconnection backs off from two to sixty seconds. Fusebox locks an address
out after five wrong management keys, from 30 seconds doubling up to 15
minutes, for every program on that address, the dashboard in a browser
included. So a rejected key is not tried again until the key file changes
(saving a key in Settings or **Reconnect** also starts over), or after an
hour, when Fusebox has forgotten the address's earlier wrong keys. A lockout
(HTTP 429) waits out Fusebox's `Retry-After`, counting down in the dashboard,
then tries once. When Fusebox restarts it closes the live socket with 1001;
the widget shows Restarting, keeps the last readings and reconnects after a
second, then after at most five seconds while the new process starts. A
missing key is rechecked every five seconds. Fusebox 0.7 sends its live `tick` only
when the totals change, so an idle server is silent: after eight quiet
seconds the helper pings the socket, and reconnects only when neither a
frame nor the pong arrives within twenty. The shell
restarts a helper that stays silent for 30 seconds; the helper prints a
heartbeat at least every five seconds. The 60-minute history starts from the
server's own minute buckets on connect and counts each finished request into
its minute, as Fusebox's dashboard does. Breaker actions, priority and account details
are one-shot `scripts/fusebox.py action|activity` requests through
`CommandRequest`; `action priority` sends only 10, 0 or -10, the dashboard's
First, Normal and Last. Nothing is retried automatically.

```sh
cybexos-runtime ipc fusebox status
cybexos-runtime ipc fusebox refresh
cybexos-runtime ipc fusebox configure
cybexos-runtime ipc popouts open fusebox
```

To remove the key, use the undo chip on the Management key row, or delete
`~/.config/cybexos/fusebox/management.key`. Uninstalling CybexOS leaves user
configuration in place.

## Tests

`tests/fusebox.py` covers key custody (permissions, atomic replacement,
symlinks, invalid keys, CLI output), URL handling, timestamps with Fusebox's
nanoseconds, the account, overview, fault, request, session and client
allowlists (plans, priority, reset plans, attribution, sources, limits read
from a configuration full of keys that must not leak), gzip answers and their
size bound, lockout, restart and rejected-key pacing, the derived fault rules,
and the live stream against a local Fusebox fake. The stream
tests check header-only authentication, snapshot order, event forwarding,
coalesced account refetches, the older-release fallback, rejected keys,
refused redirects and missing keys, and that seeded requests drop session
fingerprints. Its banked-reset tests check that reading status never spends,
that a spend sends the confirmed quote and grant exactly once, that a changed
inventory is refused, that a timeout, server error or unreadable answer is
reported as uncertain without a second request, and that unknown operation
states fail closed. No test spends a real reset. `tests/quickshell/fusebox.test.cjs` covers
the banked-reset rules and the guarantee that only the confirmation spends,
the settings schema and migration, account state, quota meters and their
Used/Remaining display, pace and run-out times, plan names, combined weekly
limits, who used a window, sources, budgets, priority, badge-worthy faults,
hidden names,
request counting, figures, fault timing and notification rules, dashboard
links and registration. `image/test_desktop_payload.py` checks that the ISO
payload ships the same widget and derives the same layout as the checkout.
Run `./tests/run` and `python3 -B image/check-source`; use
`tests/lib/quickshell-live` and the managed service for live checks.
