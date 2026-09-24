# Sub2API model usage

In **Settings → Bar → Model usage**, select **Sub2API** as the usage source.
Enter the server URL (including any reverse-proxy prefix) and the **admin API
key** generated in Sub2API's admin settings. A gateway/inference API key is not
an admin key. Server URLs, `/admin/accounts`, `/admin/dashboard`, and
`/api/v1` URLs are accepted. Keep Verify TLS enabled for trusted certificates.

Press **Test connection** to check the current server and saved key immediately,
without cached readings or quota requests. The result reports authentication
errors or the number of supported enabled accounts. HTTP 401 means the admin
key was rejected: copy the admin API key from Sub2API admin settings, rather
than a gateway/inference key, and test again. The button waits for an in-progress
key save, and changing the key invalidates old readings.

The key is sent to the credential helper over stdin and stored separately from
shell settings, in `$XDG_STATE_HOME/quickshell/model-usage-sub2api.key`
(default `~/.local/state/quickshell/model-usage-sub2api.key`), owned by the user
with mode 0600. Resetting the key row removes it. CLIProxyAPI's saved connection
and key remain independent when switching sources.

The widget discovers accounts across every inventory page and groups them as:

| Sub2API platform | Widget provider |
| --- | --- |
| Anthropic | Claude |
| OpenAI | Codex |
| Gemini, Antigravity | Gemini |
| Grok | xAI |

Disabled accounts and absent providers are omitted. The drawer shows individual
accounts, including failures, and automatically expands the most recently used
account per provider. Its quota drives the menubar and overview; the drawer,
popover, and chip tooltip identify it with a masked name and a local-time
**Last used** timestamp. Manual drawer expansion overrides automatic expansion.
If no account has a valid activity timestamp, selection falls back to the account
with the most remaining capacity; invalid and future timestamps are ignored.
If the most recently used account has no quota
reading, its quota stays unavailable instead of showing another account's.
Provider toggles control menubar chips; the drawer retains
all discovered providers for inspection. Account email labels are masked.
If the selected Claude account has no Fable window, the overview also shows
Fable limits from other accounts with their account labels. These extra cards
do not change the selected-account summary or the menubar percentage.

Activity comes from `last_used_at` in the existing lightweight account inventory,
so it adds no requests and follows the normal polling interval. It reflects all
traffic on the server, not a particular client's API key. **Last used** does not
mean a request is currently running or predict which account will handle the
next request. Cached activity retains the existing last-known/stale indication.

Quota percentages and reset times come from the admin account usage response.
Gemini pool/model windows and Grok request/token limits are supported. Unknown
percentages remain unknown, and elapsed windows are omitted. A missing snapshot
shows a pending reading rather than full capacity. The existing private cache,
stale-reading labels, and retry backoff also apply to Sub2API.

Codex reads the saved `codex_5h_*` and `codex_7d_*` fields in the account
inventory. Sub2API's active Codex usage endpoint can send an inference probe,
so the widget does not call it. Use the account through Sub2API to update its
saved quota snapshot, then refresh the widget. Other platforms use the normal
admin usage endpoint without forcing a refresh. Changing the server or key
invalidates the previous cache identity.

## API contract and verification

The implementation was checked against Sub2API revision
`b7dba62678a834080564966c002fd0ca2b328b7a`:

- [Admin routes](https://github.com/Wei-Shaw/sub2api/blob/b7dba62678a834080564966c002fd0ca2b328b7a/backend/internal/server/routes/admin.go):
  `GET /api/v1/admin/accounts?lite=true&page=…&page_size=100` and
  `GET /api/v1/admin/accounts/:id/usage`.
- [Admin authentication](https://github.com/Wei-Shaw/sub2api/blob/b7dba62678a834080564966c002fd0ca2b328b7a/backend/internal/server/middleware/admin_auth.go):
  `x-api-key` header. Redirects are rejected to keep this key on the configured
  server.
- [Usage schema and Codex snapshot behavior](https://github.com/Wei-Shaw/sub2api/blob/b7dba62678a834080564966c002fd0ca2b328b7a/backend/internal/service/account_usage_service.go).

Regression checks: `python3 tests/usage-fetch.py`,
`node --test tests/quickshell/*.test.cjs`, and `tests/qml-lint`.
The HTTP integration test uses a local fixture, not a live Sub2API deployment.
