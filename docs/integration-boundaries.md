# Desktop integration boundaries

The public QML singletons and bridge protocol remain compatible. Internally,
transport lifetime, domain state and view code have separate owners:

- **Hermes:** `nerdos_hermes/protocol.py` owns errors, wire frames and limits;
  `auth.py` owns origin-scoped HTTP credentials and authenticated transport;
  `registry.py` owns atomic conversation metadata; `gateway.py` owns bounded
  local-client delivery and the reconnecting local upstream. `hermes_bridge.py`
  coordinates the conversation domain and keeps its public imports for tools
  and existing tests. Modules never import the bridge entrypoint. The native Nix package
  ships the Python package beside the executable.
  Authentication/status replies do not wait for optional discovery or the
  conversation list. Discovery shares in-flight work and caches results for
  the current origin and sign-in session; replacing that session cancels stale
  work. An initially unreachable configured remote retries with exponential
  backoff capped at five minutes, stopping for expired or known missing
  authentication. A healthy local bridge socket alone does not establish
  remote connectivity.
- **GitHub:** `GitHubQueue.js` implements deterministic deduplication and
  interactive FIFO priority. `CommandRequest.qml` owns subprocess output,
  launch failure and bounded termination. `GitHub.qml` owns caches, conditional
  requests and Inbox reconciliation; popovers retain presentation only.
- **T3:** `T3Rpc.qml` owns wire correlation, request deadlines and interruption.
  `T3Actions.qml` owns domain commands, capability checks, batches and action
  feedback. The RPC facade forwards its existing command methods and
  properties, preserving callers. Request acceptance still does not resolve
  provider approvals; a disconnected or partially accepted batch never replays.
- **Fusebox:** `desktop/quickshell/scripts/fusebox.py` owns the management key file, the
  authenticated transport, reconnects and the allowlist of what reaches QML.
  `Fusebox.qml` owns connection state, the request history, fault
  notifications and one-shot breaker requests through `CommandRequest`;
  `FuseboxHelpers.js` owns the dashboard-equivalent rules. Popovers and
  Settings retain presentation only.
- **Updates:** `desktop/quickshell/Common/Updates.qml` invokes the supported
  `nerd update` CLI and polls durable transaction status. The privileged updater
  owns staging and activation; reloading the shell does not interrupt its
  systemd worker. Apply requests name the reviewed transaction and token.
  Independent source errors remain visible instead of implying that an
  unreachable channel is current.

`CommandRequest` has `command`, `running`, `stdinEnabled`, `inputText`,
`timeoutMs`, `killGraceMs` and `timeoutMessage` inputs. Set the command and then
`running = true`. `completed(code, body, error)` fires once per request;
`available()` announces when the process slot is free. Launch failure has code
`-1`; timeout has code `124` and an empty body, including if a process printed
partial output before hanging. A second expiry sends SIGKILL. Do not launch the
next command while `running` is true. No command is retried by the transport.

Node behavior tests exercise GitHub queue priority, T3 partial-batch and
approval rules, and the Hermes/Fusebox presentation boundaries. They do not
establish real subprocess interruption, remote HTTP/WebSocket behavior or
installed-service qualification. Exercise those paths in isolated runtime tests
before release.
