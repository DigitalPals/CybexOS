# Hermes menubar client

The Quickshell Hermes widget is a native remote-only conversation client backed
by the lightweight local `hermes-menubar-bridge.service`. Hermes Agent itself
is not installed or run on this workstation. The dropdown lists the remote
WebUI's existing conversations directly. Opening the widget starts on **New
chat**; choosing a historical conversation loads its transcript, and sending
the first message in New chat creates a normal WebUI session. When other
conversations need attention, failed, are working, or have unread activity,
New chat uses its otherwise-empty body for the three highest-priority shortcuts.
The history menu becomes searchable once it contains more than six conversations
and keeps request and unread counts visible in both places.

## Remote sign-in

The remote origin is intentionally not tracked in inventory or embedded in the
systemd unit. Enter it in the widget on first sign-in; the bridge then keeps the
origin and its session cookies together in its private state file. The widget
probes the public `/api/auth/status` endpoint and only reports **Connected**
after Hermes confirms an authenticated session.

When sign-in is required, open the Hermes popover and enter:

- **URL:** the configured Hermes WebUI origin, including its port
- **Password:** the password configured on that Hermes WebUI

The password is used for one `POST /api/auth/login` request, cleared from the
field immediately, and not retained by the bridge after that request. It is
never written to inventory, a systemd environment, or the conversation cache.
The resulting origin-bound cookie is stored at
`~/.local/state/hermes-menubar/remote-webui-auth.json` with mode `0600`.

An HTTP 302 pointing to `/login` means that there is no valid WebUI session; it
must not be treated as agent connectivity. Expired cookies return the widget to
the URL-and-password form automatically.

## Activity and streaming

Conversation history comes from `GET /api/sessions` and `GET /api/session`.
The detail request uses WebUI's `msg_limit`/`msg_before` window contract, loads
80 visible rows at a time, and keeps at most 250 renderable messages in the QML
model. **Load earlier history** retrieves preceding windows without making a
large tool-heavy session cross the loopback bridge in one response.

History is projected at an explicit presentation boundary. Only non-empty
user, assistant, and system prose becomes a message bubble. `role: tool`,
`session_meta`, empty assistant tool-call carriers, and other protocol records
never fall through to assistant Markdown. OpenAI `tool_calls`, Anthropic
`tool_use`/`tool_result` blocks, and session-level tool summaries are joined by
their call ID, but they do not accumulate as transcript rows. While a turn is
active, one compact activity line follows the newest tool name, short detail,
and status in place; it disappears when the turn settles. Structured text,
image markers, and file markers are normalized without serializing arbitrary
content objects into chat.

Prompts use `POST /api/chat/start`, with the response consumed from Hermes'
authenticated server-sent-event stream. The bar and conversation view
translate those events into useful live states, including working, thinking,
tool use, context compression, waiting for approval or clarification,
interrupted, failed, and done. Reasoning, warnings, goals, todos, context usage,
token metering, and unconsumed steering are retained as compact session state
instead of synthetic transcript messages. The view docks their summary to the
composer; reasoning detail can be expanded there without adding a second
transcript header. Long settled messages start collapsed and can be expanded
in place. Stream reconnects resume with the last event ID and reconcile against
Hermes' session and stream-status endpoints.

Normal conversation views use one toolbar: conversation switching stays in the
title control, while connection status and endpoint details, setup, refresh,
and conversation-specific actions live in its overflow. Failures remain in a
dismissible banner above the composer even when the transcript already contains
messages. Only history and
status reload failures offer **Retry**; prompt and mutation failures are never
replayed implicitly. Dismissal applies to one error occurrence, so the same
message is shown again if a later operation fails independently.

The composer reads Hermes' configured `active_provider` and `default_model`
from `GET /api/models`; its picker lists only models for that provider. Provider
changes remain in Hermes model setup, so unrelated catalog groups never appear
as usable credentials in the conversation UI. The selected model's configured
reasoning effort and supported effort ladder come from the model-scoped
`GET /api/reasoning` response. Model changes on an existing conversation use
`POST /api/session/update`, and the returned session is authoritative; new
sessions and chat starts carry the explicit model/provider choice. Reasoning
effort changes use `POST /api/reasoning`. Catalog and reasoning responses are
bounded and sanitized by the loopback bridge before QML receives them, and the
controls disappear or disable themselves when the WebUI does not advertise
usable choices.

The same composer supports up to 20 local file attachments per turn (20 MiB
each). Quickshell only passes the selected absolute paths to the loopback
bridge; the bridge opens regular files with a bounded read, uploads them with
the saved WebUI cookie to `POST /api/upload`, and sends only the WebUI's upload
records to `POST /api/chat/start`. Local paths, cookie values, and uploaded
bytes never enter the QML transcript or conversation registry. Persisted
attachment metadata is reduced to filename, MIME type, size, and image status
for display.

During a live turn, Enter steers the active Hermes run; Shift+Enter or
Ctrl+Enter inserts a newline, and the round primary action remains Stop. Approval
cards retain server-provided decision descriptions, allow long request details
to expand, and require a second explicit confirmation before **Always allow**.

Writable conversations expose the WebUI's native advanced actions:

- **Branch conversation** uses `POST /api/session/branch`; a message-level
  branch retains the transcript through that message. Older WebUIs fall back
  to `POST /api/session/duplicate` followed by a truncate of the new copy.
- **Edit & resend** uses `POST /api/session/truncate` at the selected user's
  absolute source row and submits the replacement as a new turn.
- **Regenerate** fetches a fresh session snapshot and supplies its
  `regeneration_revision` to `POST /api/chat/start`. The revision guard prevents
  a stale client from replacing a newer turn.

These actions follow the WebUI's server-side Gateway/Run integration, so the
Gateway bearer key remains on the remote host rather than becoming a second
menubar credential.

After authentication the bridge reads the WebUI gateway-stream capability
probe and publishes the negotiated contract to QML. It also supervises the
always-on `/api/sessions/events` list-invalidation stream and the selected
conversation's `/api/session/stream` channel. These recover conversations
created by another client, background-task completions, and server-initiated
turns without polling or replaying a prompt. A dropped observer stream
reconnects after a jittered delay that starts near 3 seconds and doubles up to
2 minutes; only a stream that stayed open for a minute resets that backoff, so
a server or proxy that accepts and immediately closes is not hammered. A
burst of list invalidations shares one list refresh plus at most one trailing
refresh per second. Older WebUI versions degrade to manual/list refresh when a
stream endpoint is genuinely unavailable. Advanced write routes are discovered
with empty validation requests that contain no session ID, file, or prompt and
therefore cannot mutate remote state. A 400 or 422 validation response confirms
the route; a missing or retired route keeps the matching control hidden.
Runtime 404/405/410/501 responses downgrade the capability immediately. Model
selection and reasoning effort are enabled only after their read-only discovery
endpoints return a usable contract.

The small Python bridge remains loopback-only on `ws://127.0.0.1:9120/ws`. It
owns the remote cookie and never exposes it to QML; it does not contain or run
the Hermes Agent model/runtime. Remote requests never hold the bridge's
credential lock while they wait on the network, so a slow or unreachable WebUI
delays only its own request: local RPCs, other remote calls, and live stream
relays stay responsive. Browser-originated turns are owned by the
remote Hermes Gateway rather than imported into the long-running WebUI Python
process. Updating the Agent checkout therefore cannot stale the WebUI process
used by this widget.

## Diagnostics

```bash
systemctl --user status hermes-menubar-bridge.service
journalctl --user -u hermes-menubar-bridge.service -b --no-pager
curl -fsS "${HERMES_WEBUI_ORIGIN%/}/api/auth/status" | jq
```

A bridge that crashes is restarted after 2 seconds at first; repeated failures
stretch the delay to 5 minutes, so a startup fault such as a taken port 9120 or
a missing `python3-websockets` does not loop for the whole session. After fixing
the cause, `systemctl --user restart hermes-menubar-bridge.service` retries
immediately.

The public status request should be reachable even while signed out. A healthy
password-protected server reports `auth_enabled: true`,
`password_auth_enabled: true`, and `logged_in: false` until the widget has a
valid cookie.

The remote WebUI must keep gateway-backed chat enabled. On the WebUI host,
check the non-secret settings that Hermes hot-reloads from its configuration:

```bash
hermes config get webui_chat_backend
hermes config get webui_gateway_base_url
hermes config get webui_gateway_use_runs_api
```

The expected values are `gateway`, the existing private Gateway API origin,
and `true`. The WebUI reuses its existing `API_SERVER_KEY` internally; never put
that credential in this repository or in the menubar bridge. A new
`agent_runtime_stale` response means the remote WebUI has fallen back to its
legacy in-process chat backend and should be treated as a routing-configuration
regression, not as a reason to restart WebUI after every Agent update.
