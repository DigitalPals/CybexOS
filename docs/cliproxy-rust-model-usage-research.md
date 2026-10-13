# CLIProxyAPI Rust support for Model Usage

Research date: 2026-10-03. Scope: CybexOS's Model Usage widget and the Rust
proxy running at `root@10.10.0.235`.

The recommended change is a native Rust adapter in the upstream Model Usage
plugin, followed by a vendor update in CybexOS. Rust already exposes the
account inventory, subscription quota windows, and account activity needed
for the main widget. The existing server URL and management key work with
that API. A proxy upgrade is unnecessary for this first stage.

## Verified deployment and failure

The active service is `cli-proxy-api.service`, running
`/opt/cli-proxy-api-rust/current/cliproxyapi-rust`. Its current release is
`0.3.2+gui.5862bb7fdbe8`, based on upstream `v0.3.2`, with a local GUI
configuration editor. GitHub's latest official release was also `v0.3.2`.
The backend listens on TLS `127.0.0.1:8318`, behind the existing admission
gate on `:8317`. The configured widget URL,
`https://aiproxy.risk-bull.ts.net`, reaches it through Tailscale Serve.

The installed RPM and this checkout have identical `usage-fetch.py` files.
Both use the Go implementation's `/v0/management/auth-files` and
`/v0/management/api-call` endpoints. The vendored plugin is version 1.1.1 at
`8266a07495674d2d425f6d76b67833872a69d466`; that was also the upstream plugin's
latest commit at inspection. Re-vendoring the current upstream alone cannot
resolve the incompatibility.

Authenticated reads through the widget's configured URL produced:

| Check | Observed result | Implication |
| --- | --- | --- |
| Existing client's account discovery | HTTP 401 and “CLIProxyAPI rejected the management key or remote management access.” | The current error suggests a credential problem. |
| `GET /api/accounts` with the same management key | HTTP 200; three Claude and three Codex OAuth accounts | The saved management key is valid; the API implementation differs. |
| `GET /api/accounts` with a deliberately invalid key | HTTP 401 | Native management authentication is enforced. |
| Native account quota data | Six accounts and nine windows in the feasibility snapshot | Claude had 5-hour and weekly windows; Codex exposed weekly windows at that moment. |
| Native account activity | All six accounts had `last_used` timestamps | Keeper is unnecessary for Rust account activity. |
| `GET /api/overview` | Reported the local Rust version and `round-robin` routing | Do not infer the deployed routing strategy from upstream's `least-used` default. |
| `GET /healthz` | HTTP 200 | The backend was available during inspection. |

Upstream explicitly documents that `/v0/management` and the Redis usage
queue are unsupported. Unsupported paths can return 401 through the client
authentication middleware; 401 on the legacy path alone does not establish
that the management key is wrong.

CPA Usage Keeper remains active, but its current logs repeatedly report
failed metadata reads and “management usage queue request returned status
401,” alongside a Redis protocol mismatch. Service activity does not prove
that Keeper is collecting new usage. Preserve its existing database and
historical records; Rust requires a different collection source.

## Native data and feature limits

`GET /api/accounts` returns a JSON array of account snapshots. It is an
authenticated read of cached server state, so the widget need not send
OAuth tokens or trigger provider quota calls. Rust normally polls Claude
and Codex quota about every five minutes, checks polling eligibility every
minute, and also observes quota information on model responses.

| Widget data | Rust field or behavior | Proposed handling |
| --- | --- | --- |
| Provider and account label | `provider`, `email`, `label` | Reuse provider grouping, sanitization, and email hiding. |
| Account identity | `id`; OAuth IDs are `file:<filename>`; `file` is also present | Hash a canonical identity. Verify filename mapping against previous Go history and labels before claiming migration continuity. |
| Paused account | `disabled` | Retain it as paused and exclude it from capacity selection. |
| Quota amount | `quota.windows[].used`, a percentage from 0 to 100 | Map to `used` and `remaining = 100 - used`. Validate finite numbers; missing data remains unknown. |
| Window label and scope | `name`, optional `model` | Translate known names such as `5h` and `week`; preserve model scope and unknown names. |
| Reset and freshness | `resets_at`, `quota.updated_at` | Parse timezone-aware timestamps and retain the server's observation time. A successful HTTP read does not make an old quota fresh. |
| Plan | Optional `quota.plan` | Map Codex plan metadata when present. Claude plan metadata was absent in the live response. |
| Last account used | `last_used` | Select the latest account per provider, preserving ties as ambiguous. |
| Credits and banked resets | Absent from account snapshots | Keep values unknown and disable banked-reset actions for Rust. |
| Other provider quotas | Quota polling currently covers Claude and Codex | Show other providers with quota unavailable; preserve inventory and pause state. |

The API does not guarantee that both 5-hour and weekly windows are present
on every read. Missing windows must not become zero usage or full capacity.
An initial cache can be empty after startup, and failed provider polling can
leave old values in it. A proposed stale policy should allow for the normal
five-minute polling interval and scheduling delay; its threshold still
needs an implementation decision and tests.

Rust sets `last_used` when a tracked request finishes, including failed
requests. It does not identify an account serving a request still in
progress. Activity and counters reset on process restart. The widget should
describe this as the last completed request, including failures, and return
to unknown when the server has no recorded activity.

Rust's `POST /api/accounts/{id}/reset` only clears local cooldowns, strikes,
and the last error. It must never substitute for spending a Codex banked
reset. The account API also omits paid credit balances, Claude extra usage,
and Codex code-review/additional quota buckets available to the existing Go
adapter. Full feature parity would require further server API work.

## Proposed implementation

Keep `usageSource: cliproxy` and the current connection settings. Detect the
implementation through authenticated account responses, then feed both
implementations into the existing normalized `schemaVersion: 1` contract.
An additive implementation identifier and capability fields can let QML
select activity and reset behavior without a new setup flow.

1. Extend `scripts/usage-fetch.py` with a Rust client and account normalizer.
   Probe `/api/accounts` and the legacy account endpoint within one bounded
   deadline, accepting only validated response shapes. In particular, allow
   a legacy 401 to be resolved by a successful native probe without treating
   every authentication failure as proof of Rust. Preserve redirect refusal,
   TLS validation, secret-file protections, response-size limits, and
   provider/account bounds. Avoid `/api/overview` for routine discovery: its
   response includes client API keys that the widget does not need.
2. Reuse the account grouping, best-capacity selection, quota display, and
   history code. Separate fetch time from quota observation time, show stale
   or unknown data honestly, and avoid appending unchanged stale observations
   as fresh history. Verify canonical account and window identities so
   existing private labels and quota history can survive the transition.
3. Adapt `scripts/proxy-activity.py` and `UsageActivityBackend.qml` to read
   native `last_used` values for Rust. Remove the Keeper URL requirement for
   that implementation and update the current Keeper-only notice. Reuse an
   available account snapshot or make a cheap native read for the existing
   15-second activity refresh; do not repeat provider quota checks.
4. Make reset availability depend on implementation capabilities as well as
   credit data. Update `ResetBackend.qml` and `scripts/reset-credit.py` so a
   Rust connection cannot execute Go-only reset actions. Clear incompatible
   cached credits when the detected implementation changes, even if the URL
   is unchanged. Missing credits must remain unknown rather than zero.
5. Update the plugin's settings help and documentation to explain Rust
   support and its limits. Keep local and T3 transcript cost sources working
   independently of the quota adapter.

Implement this in
[DigitalPals/omarchy-modelusage](https://github.com/DigitalPals/omarchy-modelusage)
first. CybexOS deliberately vendors its runtime files unchanged; local edits
would be overwritten by the next sync. Import the reviewed upstream commit
with `scripts/sync-model-usage <full-commit>`. Update
`Common/SettingsHelpers.js` only if the plugin's settings schema changes.
The shared runtime must ship through both checkout and ISO/RPM paths.

## Persistent costs are separate work

Rust has token counts in `GET /api/requests`, aggregate counters in
`/api/overview`, and live events on `/api/live`. These are in memory:
`src/state.rs` retains at most 300 recent request records and 60 minute
buckets. The request log stores an account label rather than a stable
account ID. Polling that ring cannot guarantee complete history across high
traffic, disconnects, or restarts.

For reliable Rust-backed Keeper costs, add durable events with stable
account IDs, an instance/event identity, replay cursors, and deduplication,
then adapt Keeper ingestion. Preserve historical Go records. That work can
follow the quota/activity adapter; the widget's local/T3 cost collection
does not depend on it. No widget change can recover proxy usage that was
never persisted.

## Validation required for implementation

Add native fixtures and HTTP integration coverage for account discovery,
bad keys, implementation detection including the observed legacy 401,
empty inventories, disabled/unknown providers, missing and stale quotas,
model-scoped windows, malformed numbers/timestamps, oversized payloads,
restart behavior, and activity ties. Test private-label/history identity
continuity, capability changes at the same URL, and that Rust polling never
calls `api-call`, account mutation, or banked-reset endpoints. Retain the
existing Go behavior and tests.

Run `python3 -B tests/model-usage.py`, the source gate `./tests/run`, and
`python3 -B image/check-source`. Add any necessary shared-payload parity
coverage. For live UI testing, use `tests/lib/quickshell-live` and the managed
service, including sole-process and current-invocation journal checks. A
release with changed runtime payload needs a new same-revision RPM/ISO and
installation qualification; fixture tests do not qualify an installation.

The initial research validated source contracts, authenticated live reads, and an
in-memory normalization experiment. That experiment produced six unique
hashed account identities, nine quota windows, and six activity timestamps
without writing state or calling provider/model/action endpoints. It was
not a production implementation, widget UI test, identity migration test,
or end-to-end installation test. At that stage, only this research document
was added; server, installed desktop, credentials, and preferences were
unchanged. The subsequent implementation and live deployment are recorded
below.

## Implementation and live verification

The native adapter was implemented and applied to the workstation on
2026-10-03 at the user's request. Model Usage 1.2.0 is pinned to upstream
commit `d34db479f99ea4afc3edb539cfb8775a50a57433`, published to
`DigitalPals/omarchy-modelusage`'s `main` branch at the user's request. The
CybexOS vendored runtime and test manifest now pin the follow-up commit
`bc771a070ba1a18a3566a7006ecd1ba8c000713c`, which also accepts Rust nanosecond timestamps on
Python 3.10. The original live RPM below was built from `d34db47`; its
Python 3.14 runtime already accepts those timestamps. No proxy-server
change was made.

The adapter detects a validated native account inventory after an unsupported
legacy endpoint response. Discovery shares one timeout budget. It normalizes
Claude and Codex OAuth quota windows, preserves filename-based account hashes,
and reads native last-completed-request activity without Keeper. Cached quota
observations older than ten minutes are marked stale; missing or expired
windows remain unavailable. Rust credits stay unknown, and banked-reset
actions are blocked in the UI and backend.

The checkout and RPM packaging now share `prepare_quickshell`, with a
byte-for-byte Model Usage payload regression check. The live installation
received a development `cybexos-desktop` RPM through DNF, preserving the
installed baseline's other files, dependencies, package scripts, and existing
session-file customization. This scoped development build replaces Model
Usage and adds update provenance; it is not a full release build.

Verification completed:

- `python3 -B tests/model-usage.py` passed, including 158 upstream Python
  tests and JavaScript assertions. Fourteen new Rust tests cover native
  discovery, authentication failures, response limits, quota freshness and
  identities, activity, and rejection of unsupported actions.
- `./tests/run` passed all 17 stages, including 1,173 unit tests and lint of
  327 QML files. The separate real-engine lifecycle stage was skipped because
  the managed live shell was active; QML component runtime checks passed.
- `python3 -B image/check-source` passed image tooling, 276 image unit tests,
  and installer JavaScript tests. These are source and payload parity checks,
  not an end-to-end ISO installation qualification.
- Authenticated reads through the installed adapter detected Rust, three
  Claude accounts, three Codex accounts, and nine fresh quota windows. Native
  activity matched the normalized quota identities for both providers.
- The managed live Limits panel rendered both Claude and Codex, each with
  three account cards and reset times. The Codex view displayed its plan
  metadata and weekly limits. `rpm -V cybexos-desktop` reported no drift after
  installation.
- The saved Model Usage preferences, management-key file contents and path,
  and private key permissions were unchanged. The restarted
  `quickshell.service` was active, its MainPID was the sole `qs` process, and
  its current invocation journal contained no QML/runtime errors. Live checks
  used `tests/lib/quickshell-live` with cleanup traps.

After publishing, upstream CI exposed Python 3.10 rejecting native
nanosecond timestamps. The follow-up normalizes fractional seconds to
microsecond precision and adds coverage for one through nine fractional
digits and timezone offsets. All 159 upstream Python tests and JavaScript
assertions passed locally after that correction.

The development RPM is retained for reinstalling the tested payload in
`/home/john/.local/share/cybexos/images/rust-widget-live.GHVEIEZX/` alongside
`SHA256SUMS`, `provenance.json`, and `rpm-validation.json`. Its filename is
`cybexos-desktop-0.0.0~dev-1.20260926095228.g4054070a4078.hwfix3.fc44.rustwidget1.x86_64.rpm`
and its size is 1,720,360,693 bytes (1.60 GiB). Build intermediates, temporary
test logs, and desktop screenshots were removed after verification. No test
VMs or mounts were created. No ISO was built or qualified; release qualification
remains separate from this live development test.

## Fusebox live account activity assessment (2026-10-08)

Adding a live account indicator is feasible at the inspected deployment's
scale. Use one persistent WebSocket connection per configured proxy, shared
by all bars, rather than increasing the frequency of the existing Python
activity subprocess. This assessment does not implement or deploy the feature.

The service at `root@10.10.0.235` runs
`0.3.2+gui.93d3af0bb855`. Its deployment record identifies clean source commit
`fecb778830c13e80c1cd24e041da2107e9917a51`, also the Fusebox repository's HEAD
at inspection. The deployed README matched that commit byte-for-byte by
SHA-256. There were five configured accounts across Claude and Codex.

The authenticated `wss://aiproxy.risk-bull.ts.net/api/live` endpoint already
sends `load` events with account IDs and `{in_flight, sessions}` counts. A
connection receives an initial snapshot; the server samples every second
and sends another snapshot only when its serialized contents change.
Bearer authentication in the upgrade headers worked, so a desktop helper
does not need to put the management key in its URL. The existing
`GET /api/accounts` response does not contain these live counts.

- `in_flight` counts actual account request attempts, including unfinished
  streams. The request guard decrements on completion or cancellation.
- `sessions` counts distinct assigned sessions seen in the last five minutes,
  plus sessions with a call still in flight, subject to the configured shorter
  affinity expiry. It does not mean that every session is generating now.
- `last_used` remains the latest completed request, including failures. Keep
  this separate from a new "Serving now" indicator. Concurrent accounts can
  all be serving; do not choose one by its quota or last-used timestamp.

The load computation reads the account pool, atomic request counters, and
the in-memory session registry. It performs no provider quota call or SQLite
query. The full dashboard socket additionally sends request metadata,
account-change notifications, and five-second totals ticks.

Read-only production measurements, with ordinary model traffic continuing:

| Measurement | Result |
| --- | --- |
| Account inventory GET | 10.62 ms; approximately 6.7 KB of reserialized JSON |
| WebSocket connection | 11.68 ms; header authentication accepted |
| Load event size | 169 bytes in the observed snapshots |
| 30-second WebSocket observation | 6 load events, 6 ticks, 7 completed-request events; 7,963 payload bytes total (265 bytes/second) |
| Desktop observer CPU | 9.37 ms over 30 seconds, about 0.031% of one core |
| Desktop observer memory | Approximately 33.1 MiB RSS for the whole Python observer; 28 KiB growth during observation |
| Fusebox CPU before connection | 80 ms over 15.24 seconds, about 0.53% of one core |
| Fusebox CPU during connection | 140 ms over approximately 30 seconds, about 0.47% of one core |
| Existing activity helper, three invocations | 87–96 ms elapsed and 75–83 ms child CPU per invocation |

The desktop observer imported the existing adapter and used the installed
Python `websockets` library; its memory is not a measured incremental
Quickshell allocation. Server CPU and memory include concurrent production
work, so these observations cannot isolate the socket's overhead or prove
performance under a much larger workload. They showed no material CPU
increase at the current scale. No synthetic model requests were generated.

For implementation, replace Rust activity polling with a bounded persistent
collector and keep the slower quota refresh independent. Publish only changes
to QML, use static indicators, preserve hashed identity matching and hidden
emails, and mark live activity unknown on disconnect. Reconnect with bounded
backoff and stop the collector when its feature is disabled. Python
`websockets` is already included by both the desktop role and RPM dependency
contract. Implement upstream in Model Usage and import through the existing
vendor workflow, including source/image payload parity coverage.

No Fusebox change is required for one desktop. For wider deployment, an
activity-only subscription would avoid forwarding request metadata and
totals. Compute a shared load snapshot once per second for all subscribers:
the current implementation scans the session registry separately for each
socket while holding its mutex, and the registry can contain up to 10,000
assignments. Bound slow-client sends and recover with a complete snapshot
after reconnect or lag. These changes would protect scaling without adding
work to every token or provider request.

Source references at the deployed commit:

- [Live load snapshots and WebSocket loop](https://github.com/DigitalPals/Fusebox/blob/fecb778830c13e80c1cd24e041da2107e9917a51/src/mgmt.rs#L912).
- [Request guards](https://github.com/DigitalPals/Fusebox/blob/fecb778830c13e80c1cd24e041da2107e9917a51/src/accounts.rs#L366).
- [Recent-session counting](https://github.com/DigitalPals/Fusebox/blob/fecb778830c13e80c1cd24e041da2107e9917a51/src/affinity.rs#L272).
- [Dashboard consumption of load events](https://github.com/DigitalPals/Fusebox/blob/fecb778830c13e80c1cd24e041da2107e9917a51/ui/app.js#L347).

Temporary source inspection files were removed. No runtime code,
configuration, credentials, service, RPM, or ISO was changed.

## Sources

- [Rust v0.3.2 release](https://github.com/IuCC123/CLIProxyAPI-Rust/releases/tag/v0.3.2).
- [Pinned Rust README and compatibility limits](https://github.com/IuCC123/CLIProxyAPI-Rust/blob/3f937ce690d7507065a42be9ce11b26fc16eee06/README.md#coming-from-cliproxyapi).
- [Management routes and authentication](https://github.com/IuCC123/CLIProxyAPI-Rust/blob/3f937ce690d7507065a42be9ce11b26fc16eee06/src/mgmt.rs#L292).
- [Account snapshots and filename identities](https://github.com/IuCC123/CLIProxyAPI-Rust/blob/3f937ce690d7507065a42be9ce11b26fc16eee06/src/accounts.rs#L483).
- [Quota fields and polling](https://github.com/IuCC123/CLIProxyAPI-Rust/blob/3f937ce690d7507065a42be9ce11b26fc16eee06/src/quota.rs).
- [Activity semantics](https://github.com/IuCC123/CLIProxyAPI-Rust/blob/3f937ce690d7507065a42be9ce11b26fc16eee06/src/proxy.rs#L100) and [in-memory request retention](https://github.com/IuCC123/CLIProxyAPI-Rust/blob/3f937ce690d7507065a42be9ce11b26fc16eee06/src/state.rs#L195).
- [CybexOS vendoring contract](../roles/desktop/files/quickshell/ModelUsage/README.md), [existing proxy client](../roles/desktop/files/quickshell/ModelUsage/scripts/usage-fetch.py), and [installation parity requirements](installation-parity.md).
- Live observations from `root@10.10.0.235`, its local deployment records,
  updater status, authenticated native API, and Keeper error logs on the
  research date. No credentials or raw account identities are reproduced.


### Implemented session badges

Model Usage 1.3.1 uses one shared, reference-counted live collector per proxy
URL/key-file connection. Fusebox and its deployment are unchanged. The menubar
shows quota percentages only. A badge at the upper-right of each account card,
aligned with its subscription title, shows Fusebox's recent assigned-session
count. The count is not an unfinished-request count and may stay positive after
requests finish. Tooltip and keyboard-accessible expandable details explain
this. Broken, stale or unsupported streams display “Sessions unknown”. Models
are not displayed or queried. Quota layout, last-used selection, account order,
and saved email privacy are preserved. Obsolete bar-count and separate
recent-session settings are dropped by normalization.

The collector reads only cached native inventory, coalesces changes to at most
one inventory request per 15 seconds, refreshes idle inventory every 60 seconds,
and throttles stdout heartbeats to five seconds. Frames, queues and QML stdout
are bounded. Initial load and heartbeat expiry prevent false zero counts;
reconnect backoff caps at 60 seconds. Older Rust endpoints retain cached
last-used activity with live activity unavailable. Go/Keeper retains its
existing polling path. No server changes, new connections, per-session queries,
model discovery or extra polling are required for the badge.

A final 20-second live sample measured 0.1% of one core and 32.3 MiB RSS for the
shared helper; the entire shell consumed 1.2% of one core. The presentation-only
revision retains the existing collector and protocol. This short observation
does not claim a stress benchmark.

Validation covers real WebSocket authentication, normalization, idle,
disconnect, malformed counts, missing initial snapshots, reconnect backoff and
shared QML lifetime. Badge tests distinguish session counts from unfinished
requests, including zero requests with positive recent sessions. Checkout
settings and ISO desktop payload fixtures share the same settings and transport
dependency. Live verification confirmed quota-only chips and the upper-right
session badge beside “Codex Pro · 20×”. The managed service's current invocation
passed QML journal and sole-managed-`qs` checks. Its development source selection
was preserved. Deployment uses a scoped development RPM preserving the installed
payload's unrelated files, dependencies and scriptlets; this is not a rebuilt or
end-to-end-qualified ISO release.

### Fusebox naming and repository link

Model Usage 1.3.2 names the native Rust connection Fusebox in Limits settings,
quota source diagnostics and account notices. Limits settings expose a visible,
keyboard-accessible “Fusebox on GitHub” link to
`https://github.com/DigitalPals/Fusebox`. Before discovery, the source option says
“Fusebox / CLIProxyAPI”; detected Go connections retain the CLIProxyAPI name.
The existing source value, URL/key settings and Rust protocol marker are
unchanged, so saved connections continue to work. This is a presentation change
with no new network calls, polling or processes. The desktop payload equality
fixture covers both checkout and ISO/RPM source packaging. The scoped desktop
RPM is a development update, not an end-to-end-qualified ISO release.
