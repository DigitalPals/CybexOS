# Desktop integration boundaries

The public QML singletons and bridge protocol remain compatible. Internally,
transport lifetime, domain state and view code have separate owners:

- **Hermes:** `cybex_hermes/protocol.py` owns errors, wire frames and limits;
  `auth.py` owns origin-scoped HTTP credentials and authenticated transport;
  `registry.py` owns atomic conversation metadata; `gateway.py` owns bounded
  local-client delivery and the reconnecting local upstream. `hermes_bridge.py`
  coordinates the conversation domain and keeps its public imports for tools
  and existing tests. Modules never import the bridge entrypoint. Both install
  paths must ship the package beside the executable.
- **GitHub:** `GitHubQueue.js` implements deterministic deduplication and
  interactive FIFO priority. `CommandRequest.qml` owns subprocess output,
  launch failure and bounded termination. `GitHub.qml` owns caches, conditional
  requests and Inbox reconciliation; popovers retain presentation only.
- **T3:** `T3Rpc.qml` owns wire correlation, request deadlines and interruption.
  `T3Actions.qml` owns domain commands, capability checks, batches and action
  feedback. The RPC facade forwards its existing command methods and
  properties, preserving callers. Request acceptance still does not resolve
  provider approvals; a disconnected or partially accepted batch never replays.
- **Updates:** `UpdateLogReader.qml` owns bounded byte-range transport and
  run/offset validation. `Updates.qml` owns transaction state and parses only
  accepted log data. The privileged updater still owns the transaction; a shell
  reload does not stop it. Log responses for another run or an earlier offset
  trigger a fresh read instead of modifying the current transaction.

`CommandRequest` has `command`, `running`, `stdinEnabled`, `inputText`,
`timeoutMs`, `killGraceMs` and `timeoutMessage` inputs. Set the command and then
`running = true`. `completed(code, body, error)` fires once per request;
`available()` announces when the process slot is free. Launch failure has code
`-1`; timeout has code `124` and an empty body, including if a process printed
partial output before hanging. A second expiry sends SIGKILL. Do not launch the
next command while `running` is true. No command is retried by the transport.

The real-engine lifecycle fixture covers output, missing executables,
SIGTERM-resistant timeouts, reuse after timeout and stdin. It runs in CI with an
isolated HOME/session when no other Quickshell is active. Node behavior tests
exercise GitHub queue priority and T3 partial-batch, approval and expiry rules;
the existing Hermes HTTP/WebSocket fixtures exercise the split Python modules.
