# Working on the Quickshell shell

Notes for anyone changing `roles/desktop/files/quickshell/` — how to test it,
the traps that cost real time to find, and the things already decided against.

Distilled from `docs/qml-improvement-plan.md`, a 43-package refactor completed
2026-08-08 (42 done, 1 measured and declined). That plan is in git history if
you need the reasoning behind a particular change; `git log --oneline
-- roles/desktop/files/quickshell` is usually faster.

## Ground rules

- The Ansible role is the vendor source of truth. Its deployed runtime is
  `~/.local/share/cybexos/runtime/quickshell`; never edit that generated
  copy expecting the change to survive. User settings and overrides live in
  the paths documented by `docs/architecture/ownership.md`.
- Match the surrounding style. **Do not run qmlformat** (see "Already decided
  against").
- Theme values come from `Common/Theme.qml`. Add a token rather than a literal
  when the value expresses a design role.
- New shared components: PascalCase file in the directory that owns the
  concern, and **add it to that directory's `qmldir`** — a directory carrying a
  `qmldir` is no longer implicitly scanned, so an unlisted type fails at
  runtime as "X is not a type". `tests/quickshell/qmldir.test.cjs` enforces it.
- Pure logic goes in a `.js` module in `Common/` with a Node test in
  `tests/quickshell/` — that suite runs in under a second without Qt.
- `tests/run` is the strict source gate: language-aware static analysis, Node
  tests, QML static/runtime checks, integration contracts, and the
  repository's other fixtures. `update --full` runs it before deploying, and
  the Ansible role lints the tree before copying a changed one. See
  `./tests/run --list` and
  [the operations guide](operations.md#the-strict-source-gate).

## Testing without a GUI

Run `./tests/run` first; it needs no live shell. External widget tests require
`sway` for a disposable headless Wayland compositor (also installed by CI);
this is a test dependency, not a change to the desktop's compositor.
For a live deployment, keep
`quickshell.service` as the only `qs` process and use the shared safety harness
at both boundaries:

```sh
set -euo pipefail
source tests/lib/quickshell-live
cleanup() {
  rc=$?
  trap - EXIT INT TERM
  qs_live_end || rc=1
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

qs_live_begin
ansible-playbook site.yml -e @/etc/cybexos/config.yml --tags quickshell
qs_live_wait_ipc 20 popouts close >/dev/null
qs_live_wait_ipc 20 popouts toggle t3code # or: audio, control, wifi, notifications, …
qs_live_wait_ipc 20 settings open notifications
grim -g "1020,50 400x420" /tmp/shot.png
qs_live_end
trap - EXIT INT TERM
```

`qs_live_begin` compares the service MainPID with every `pgrep -x qs` result,
inspects command lines and cgroups, and only terminates a confirmed unmanaged
`qs -d`/`qs -p` developer process. `qs_live_end` requires the service to be
active, its MainPID to be the sole `qs`, and the current invocation journal to
be free of known QML/runtime errors. IPC readiness checks target the service PID
so runtime migration cannot send them to a dead default configuration. Never
replace this with `pkill qs`.

The Ansible role is the supported deployment path. A test that temporarily
edits the deployed tree must be trap-protected, restore the exact managed
manifest (including destination-only file removal), wait for IPC readiness,
and then call `qs_live_end`; `tests/t3-contract-snapshot` is the working
example. Do not commit while a throwaway live copy is deployed.

### Techniques that work here

- **`console.log` never reaches stdout or the qslog**, under any
  `QT_LOGGING_RULES`. `console.warn` *does* reach
  `journalctl --user -u quickshell.service`. A harness that must report a value
  writes a file:
  `Quickshell.execDetached(["sh", "-c", "printf '%s' \"$1\" > \"$2\"", "sh", text, path])`.
- **Offscreen harness**: `tests/run` points HOME/XDG paths at a scratch
  directory. Generic `qmltestrunner` covers helpers; Quickshell's plugin is
  statically linked into `qs`, so the production-component lifecycle harness
  runs through the real engine in CI and refuses to run beside an active local
  `qs`. If another direct source-tree `qs -d`/`qs -p` probe is indispensable,
  stop `quickshell.service` first and install a trap that terminates the exact
  developer PID, restores the service, and finishes with the same sole-PID and
  current-journal checks as `qs_live_end`. Never run the probe beside the
  managed service.
- **Triggering internal code paths live**: add a throwaway `IpcHandler` target
  to the *deployed* `shell.qml`. Cheaper than staging the real event, and it
  exercises the shipped code rather than a copy.
- **Keyboard**: `wtype -k Tab` / `wtype -k space` sends real key events, which
  is how focus order and activation get tested end to end.
- **Updates drawer states without updating anything**: write a run record
  (`status.json`, `dnf.log`, `flatpak.log`, `firmware-events.log`) under
  `~/.local/state/cybexos/update/logs/<id>/` and put the id in `../current`.
  The id has the form `YYYYmmdd-HHMMSS-N-N`. Set the record's `unit` to a
  disposable `systemd-run --user … sleep 900` unit, never a real service:
  `status` treats an inactive unit as an abandoned run, and a stray Cancel
  stops whatever unit the record names. Restart `quickshell.service` so it
  attaches, rewrite the record with the same log prefixes to advance it, and
  remove the run and `current` afterwards.
- **Pointer**: `hyprctl dispatch 'hl.dsp.cursor.move({ x = …, y = … })'` takes
  absolute screen-logical coordinates. Call it in a loop until
  `hyprctl cursorpos` agrees — the first call after the pointer has been
  elsewhere can land short. With `grim -c` this makes cursor shape and hover
  state observable.
- **Multi-monitor without hardware**: `hyprctl output create headless`, then
  read the name back (`HEADLESS-1`). The shell keeps a bar mapped on every
  output, so `hyprctl layers -j` can directly verify one `qs-bar` surface per
  output and only one `qs-bar-popout` on the output whose bar was clicked.
- **This Hyprland speaks a Lua dispatch dialect** —
  `hyprctl dispatch 'hl.dsp.focus({ monitor = "<name>" })'`. Plain
  `focusmonitor` / `movecursor` do not exist.
- **Prove the probe has teeth.** Reconstruct the pre-fix code in the throwaway
  copy and confirm the probe fails. A check that cannot fail has not verified
  anything.

### Pixel diffs

`compare -metric AE` is **not** a pixel count in this ImageMagick 7 — it
returned 6.7e7 for a 120×80 crop. Use:

```sh
magick a.png b.png -compose difference -composite -colorspace Gray \
  -threshold 8% -format '%[fx:mean*w*h]' info:
```

and always check it against a deliberately broken variant before believing a
zero. Then subtract the noise floor: capture the *same* tree twice and diff
that too. Live values move constantly — the control centre differs from itself
by ~134k px eight seconds apart (CPU/RAM/temp), the battery popover by its time
estimate, several settings pages by their clock previews. A panel's outer edge
blends with whatever is behind it, so `-shave 12x0` before comparing.

## Traps

- **An unqualified reference to another singleton's property lints clean and
  throws at runtime.** Inside a Quickshell `Singleton`, qmllint cannot resolve
  the scope, so `threadMap` where `T3Threads.threadMap` was meant produces no
  warning — and every call throws `ReferenceError`, invisibly except in the
  journal. This shipped three times during the T3 split (WP5.1, WP5.2, and
  settle/snooze after Phase 5). `tests/quickshell/t3-singleton-scope.test.cjs`
  now enforces a watchlist; extend the list when a new cross-singleton name
  appears.
- **A `Connections` handler that matches nothing on its target is silently
  dead.** qmllint has no opinion, the configuration loads, and Quickshell logs
  one WARN at reload and never calls it — so the code reads as wired and does
  nothing. The T3 façade makes this easy: views only talk to `T3Code`, so a
  handler for state that still lives on `T3Drafts`/`T3Detail` looks right at
  both ends. Shipped three times (`threadDrafts`/`userInputDrafts`,
  `newThreadConfirmed`, `detailThreadId`). Re-export on the façade — a
  property binds, a signal needs its own declaration plus a relaying
  `Connections`. `tests/quickshell/connections-handlers.test.cjs` now resolves
  every handler against its target singleton's real surface.
- **In-place mutation never re-evaluates a binding.** Mutating an object or
  array in place is invisible to QML; reassigning it notifies. Both behaviours
  are useful — a memo cache wants the former, an invalidation wants the latter
  — but mixing them up silently breaks either the update or the performance.
- **A counter written from inside a binding can feed back into the binding
  graph.** Instrumenting `iconSource` with `property int` counters drove the
  shell to 171% CPU and 6.6 GB and filled `/run/user/1000` with a 3.1 GB log,
  after which the restarted instance could not create its IPC socket. Count in
  a `.pragma library` script instead — module scope is not a QML property, so
  nothing can capture it. Note such scripts are **cached past a hot reload**;
  changing one needs `systemctl --user restart quickshell.service`.
- **A `.js` imported without `.pragma library` gets a separate copy per
  importing component.** Fine for stateless helpers, useless for shared state.
- **`readonly property int` silently truncates.** Card heights are text metrics
  plus padding and land on fractions; an `int` cost a pixel and shifted
  everything below it. Use `real` for anything derived from text.
- **Quickshell does not watch `qmldir` files.** A qmldir edit needs a `.qml`
  touch before it reloads.
- **`Loader.active` defaults to true**, so `onActiveChanged` fires only for
  slots that evaluate false. Absence of `active=true` lines is a logging
  artifact, not a gate that failed.
- **`signal-handler-parameters` cannot be satisfied** for
  `Process.exited(int, QProcess::ExitStatus)` — the enum is not registered with
  QML. The apparent fix (`function onExited(exitCode) {}`) silences qmllint
  *and* stops Quickshell calling the handler. Disabled in `.qmllint.ini` with
  that reason.
- **Quickshell emits no `exited` at all when a binary cannot be launched** —
  only the falling edge of `running`. Anything reading exit status must handle
  a never-started process; `Common/ProcHelpers.js` has the sentinel.
- **Popout lifetime**: `PopoutHost` latches the Control Panel, so it is
  constructed once and never destroyed. Anything refcounted must key on
  `visible` via `Common/Claim.qml`, not on construction or destruction.
- **Idle CPU is not measurable with `top` on a machine in use** — sampling the
  live shell gave 0.12%–6.44% across windows of *identical* code. Instrument
  both trees and count timer firings in the journal instead.
- **A pixel-identical bar is not a working bar.** WP4.3 shipped a module
  registration regression that looked perfect in a screenshot. `tests/run`
  carries a duplicate-handler check because qmllint has no opinion on that and
  the failure mode is a shell silently running stale code.
- **`hyprctl cursor.move` warps the pointer without delivering hover to the
  client.** No `MouseArea` under it sees `onEntered`, and `containsMouse` stays
  false — verified by probe, with the bar's own `HoverHandler` reporting
  `hovered: true` and a live position at the same moment. The cursor *shape*
  still changes, so a screenshot looks like a real hover and is not one. A
  uinput virtual pointer emitting `EV_REL` a pixel at a time does generate real
  motion, but Qt's legacy hover path still did not pick it up here — so testing
  anything gated on `containsMouse` needs a human hand on the mouse. What is
  testable without one: pin the raw hover state to `true` in the deployed copy
  and check what the bar-wide validation does with it.
- **Binding an item's visibility to a descendant's `visible` latches it at
  false.** `visible` reads back *effective* visibility — the item's own flag
  ANDed with its parents' — so a wrapper written as `visible: child.visible`
  depends on itself and can never leave false. It looks correct as long as the
  child starts visible, which is why it survived review: only modules that turn
  on *later* (a track starts playing, updates appear, a tray icon registers)
  stayed missing. Bind to the underlying condition instead — `Loader.active`,
  not `Loader.visible`.
- **A defaulted property that a safety check depends on will eventually be
  left unset.** `BarIcon.host` looked like panel wiring, so the idle module —
  which owns no panel — never set it, and `BarTooltip` silently fell back to
  the local `containsMouse` it exists to second-guess. A missed exit event
  then stranded "Idle inhibit off" on screen with no path back to false.
  `host` is `required` on `BarIcon`/`BarChip`/`BarTooltip` now and
  `RequiredProperty` is an error in `.qmllint.ini`; the general lesson is that
  a null-degrades default turns a loud failure into a silent one.
- **Lock state comes from `hyprctl locked`, never logind's `LockedHint`.**
  Nothing in this session sets the hint, so it reads "no" behind a working
  lock screen. A lock helper that times out must leave a running locker alone:
  stopping it unlocks the session with nobody at the keyboard, and staying
  locked is the only safe failure (`cybexos-session-action`).
- **`hyprctl` speaks the Lua config too.** `hyprctl dispatch X` runs
  `hl.dispatch(X)`, so X must be an `hl.dsp.*` expression; a bare `exit` is
  nil and does nothing. `hyprctl keyword` is refused under a Lua config and
  still exits 0; set options with `hyprctl eval 'hl.config({ … })'`, which
  fails loudly. `HyprlandToplevel.address` is bare hex, while the `address:`
  selector needs the `0x` prefix.
- **A bare `qs ipc call` reaches nothing.** The shell runs by path
  (`qs -p <runtime>`), so there is no default configuration to find. Scripts,
  bindings and docs use `cybexos-runtime ipc TARGET FUNCTION …`, which
  resolves the path the service started with, development checkout included.
- **`luajit` reading a script from stdin without `-` exits 0 after a failed
  assertion**, so a heredoc fixture can never fail. Write `luajit - <<'LUA'`.
- **FileView `setText` skips text it believes it already holds.** It compares
  against the last bytes it read *or tried to write*, a failed attempt
  included, and a match emits neither `saved` nor `saveFailed`, so a write
  guard waiting for one never clears. Settings and Notes track that text
  (`storeText`), settle without writing when the file already has the
  content, and retry identical content with one extra trailing newline.
  Quickshell logs a failed atomic commit (fsync or rename) and still emits
  `saved`. Never call `setText` under a live async write; a `reload()` issued
  under a write is dropped, which is why Settings' `reloadStore()` defers it.
- **Qt refuses to clear `activeFocusOnTab` on the focused item.** A roving tab
  stop that follows the selection must `forceActiveFocus()` the new target
  before committing it, or the old item keeps a second tab stop.
- **hypridle's `condition_cmd` runs synchronously in its loop** (0.1.8), so
  keep it fast and bounded. A failing condition skips the listener's
  `on-resume` as well as its `on-timeout`, and any input cancels pending
  `condition_retry` attempts.
- **Python retries `poll()` and `sleep()` after a signal handler runs**, so a
  handler alone never ends an unbounded wait: register the loop's pipe with
  `signal.set_wakeup_fd` and poll it too (`xps-haptic-touchpad`).
- **`pactl` translates the headers of its long listings** ("Sink Input #" is
  "Afvoer-invoer #" in Dutch). Parse them under `LC_ALL=C`.
- **An EDS connect wait of 0 means "wait forever".** `calendar-events.py`
  connects its sources in parallel with a one-second wait, and at its deadline
  returns the calendars that answered plus a `sourceErrors` entry for each
  that did not.

## Churn and lifetime invariants (2026-09 robustness pass)

A review of efficiency and robustness left these contracts in the code. Keep
them when changing the surrounding files.

- **Streaming transcripts update rows, not arrays.** `T3ThreadPage` and
  `HermesTranscript` draw from a `ListModel` keyed by message id and apply
  edit scripts (`T3CodeHelpers.historyRowOps`, `HermesHelpers.listSyncOps`);
  a token is one `setProperty`. Per-row UI state (expanded, editing) lives on
  the page keyed by id. T3 detail histories stay sorted, so `upsertHistory`
  inserts by binary search instead of re-sorting. Hermes stores messages in
  place: bind to `transcriptRevision`/`transcriptChanged`, not to
  `messagesByConversation`.
- **Repeaters over derived lists take a structural key.** Bar clusters,
  indicators, workspaces, the drawer network list, and the
  GitHub Inbox and repository rows parse their model from a JSON string of
  ids, and delegates look up live data by id, so a value change flows through
  bindings instead of recreating delegates. GitHub Inbox sections and drawer
  Bluetooth sections are fixed models; drawer Bluetooth and Sound rows go
  through `ScriptModel`, which diffs them by device and node identity.
- **`Settings.applyLoaded` assigns only changed keys** (`assignChanged`) and
  ignores a reload whose bytes equal the last write. Reassigning an unchanged
  var key still notifies and rebuilds every bar module. A settings file from a
  newer schema is applied read-only and never saved over.
- **Popout slots are visible only while fronted, fading or requested.** An
  outgoing panel turns invisible when its fade ends, which releases its
  `Claim`s and visible-gated timers. A presented slot is fronted before its
  card turns visible; otherwise the latched drawer counts as visible for one
  turn, and its tab's claims start and release their pollers on every
  unrelated open. A spinner's `running` includes its own `visible`, since the
  outgoing panel stays alive until it closes.
- **One `nmcli monitor`** lives in `NetworkStatus`; `EthernetState` listens to
  its `monitorEvent`. Both 30 s safety polls run only while it is down, and
  restarts back off 5 s → 60 s. Battery health follows the same rule with
  `upower --monitor-detail`: a safety poll runs only while its event stream is
  down. Tailscale polls every 120 s for plain `acquire()` claims and every
  30 s for `acquireLive()` views, neither while idle; a missing binary drops
  it to an hourly probe, and a view that opens probes at once.
- **Tailscale sign-in** uses the Network overlay for first-use setup and the
  shared `Tailscale` singleton for the pending session. Continue releases the
  overlay's keyboard focus before browser handoff or a polkit prompt. Login
  URLs stay in memory; closing the dialog keeps sign-in running. A two-second
  status poll lasts up to five minutes, and only a successful status snapshot
  with a Tailscale address reports connection success. `NeedsMachineAuth`
  displays administrator approval separately. Stop connecting uses `down`,
  preserving the account. Commands are bounded by `timeout`; permission
  failures retry once through `pkexec`, without changing the machine's
  operator or polkit policy. First sign-in consumes `up --json` incrementally;
  reconnection uses bare `up` to preserve non-default preferences (even adding
  `--json` changes Tailscale's preference checks). The existing-account path
  also recognizes a standalone HTTPS authentication URL on stderr.
- **The Network panel's live figures cost no process per sample.** Throughput
  reads `/sys/class/net/<if>/statistics` through FileView on the 1.5 s tick,
  and `primary` carries those live counters; latency comes from two
  long-running `ping -n -O` processes. The device/route/profile/scan snapshot
  runs on `NetworkStatus.monitorEvent` (debounced), on a change in the scanned
  SSID set, after actions, and on a 10 s safety poll. All of it runs only
  while a view holds the panel.
- **Plugin discovery** watches `plugins.json`, which `plugin update` touches.
  Package trees are polled every 5 min only while a plugin is enabled (2 s
  while Settings is open), never while idle, and a package is rehashed only
  when its stat signature in `<runtime-root>/.revisions.json` changes. A
  registry error keeps the last good plugins.
- **Long-lived helpers are bounded.** `gh` reads, brightness reads/writes,
  matugen, `calendar-events.py`, wallpaper thumbnails and the plugin scanner
  each have a timeout or watchdog. Helpers settle on the falling
  edge of `running`, so one that never starts cannot wedge its queue; that
  includes the Reminders list, the plugin writer, the launcher's search
  processes and the brightness re-read a mid-read refresh leaves pending.
- **Settings, Notes and launcher usage write asynchronously.** Settings and
  Notes keep one write in flight (see the FileView trap); launcher usage is
  written 2 s after a burst of launches, and synchronously if the shell goes
  first.

### Idle and energy (2026-09-23)

- **`Common/Activity.qml` is the one idle and power signal.** `idle` comes
  from an `IdleMonitor` (300 s, respecting inhibitors, off outside a Wayland
  session); `onBattery` and `powerSaver` follow UPower and the power profile;
  `resumed` fires on the first input after idle. Background pollers stop while
  idle and refresh what went stale on `resumed`. A timer longer than an idle
  spell (wallpaper rotation) keeps running, and work that falls due while idle
  is owed to `resumed`.
- **GitHub gates scheduled timers on `scheduleActive`**: the module
  is on, the session is not idle, and the network is not known to be down.
  Manual refreshes are never gated.
- **Poll only for a consumer.** Updates checks in the background only for its
  widget or its notifications; opening the Updates panel or the drawer
  Overview refreshes a stale count. Weather fetches only for a set location
  with its widget on or a Day sheet claim; the calendar polls only for a Day
  sheet claim.
- **Updates retries only what failed.** The retry budget resets on the online
  edge, startup, a manual refresh or an all-success check, never on a
  scheduled poll, and each source has its own notification baseline. dnf's
  answer is reused while the repomd/repo/rpmdb signature is unchanged; manual
  and post-run checks force a real read, and one happens at least every 6 h.
- **Never reload a watched FileView on a timer.** Each reload rebuilds its
  inotify watches, and the directory watch already sees creation and atomic
  replacement. Poll only while the file is missing, and make sure its
  directory exists (Recorder, Dictation).
- **Parsed commands set `LC_ALL` through the Process `environment`**, not an
  `env` process per run.
- **Integration sockets exist only while wanted.** `T3Connection.enabled` and
  `HermesConnection.enabled` follow their bar module, or their panel while it
  is open, and `T3Connection.connect()` is the single gated entry. Naming a
  connection singleton constructs it, so ShellHealth checks `Settings.mods`
  first. Backoff starts over only once a link has proven healthy (T3: its
  first shell snapshot via `markHealthy`, or 60 s connected; Hermes: 60 s),
  never merely because a socket opened. T3 retries rest while the machine is
  known offline (a loopback server is exempt) or idle, Hermes's only while
  idle. An expired T3 Connect session is a state, not an error: the ticket
  helper exits 3, the link goes signed-out without retrying, and the panel
  offers Sign in.
- **Nothing ticks faster than it reads.** The recording mark steps with
  `Recorder.elapsed` instead of an infinite animation; the mic meter samples
  at ~15 Hz into whole pixels; reminder countdowns wake at
  `CountdownHelpers.soonestChangeMs`; HH:mm captions use a minutes clock that
  runs only while visible.
- **Power saver** is part of `Theme.reducedMotion` (`Activity.powerSaver`).
  The compositor side is `cybexos_power_saver()` in `looknfeel.lua`, whose
  state lives in `_G` so a config reload reapplies it.

## Layout

- `Common/` — singletons (services, settings, theme), pure `.js` helpers, and
  the shared controls both other directories draw (`Toggle`, `HSlider`,
  `NotifCard`, `NotifIcon`, `NotifActions`).
- `Bar/` — the menubar, the popout host, and 13 modules under `Bar/Modules/`
  sharing a `BarModule` base. `Cluster.qml` is what turns a run of adjacent
  modules into one shared pill (see `LayoutHelpers.groupModules`); `Bar.qml`
  owns the furniture at either end and the fit pass.
- `Popovers/` — panel contents, all built on `PopoutPanel` / `Surface`.
- `Settings/` — the settings window; rows build on `Settings/SettingsRow.qml`.
- `tests/quickshell/` — Node tests. `shell.cjs` locates the source tree;
  `load("X.js")` pulls a helper out of `Common/`.

Two conventions worth knowing: a settings row that names a `settingKey` gets
its value, dirty state, commit and undo from the base, and per-surface styling
travels as a single `var` object (`Theme.switchRow`, a card's `style`) rather
than as a dozen properties.

### Launcher providers and actions

`Common/LauncherProviders.qml` owns command-palette routing, results and side
effects; `LauncherView.qml` only renders its normalized rows. Every open and
every close resets to the Apps tab; Emoji, History (clipboard), and Actions
are discoverable tabs beside it in a compact 460px card. The strip is 34px
tall, the search field is 44px, and an up-to-eight-row viewport uses 42px rows
with 28px icons. The Apps tab keeps every visible desktop entry in its model
and scrolls inside that fixed viewport; keyboard selection keeps the active
row in view. Rows show one line only; action subtitles and keywords remain
searchable metadata but do not add visual bulk.

The launcher's layer surface is the card's full-height envelope plus its
entry travel, anchored top-left at offsets from the output edge, not the whole
output: the compositor blurs every pixel of a blurred surface. Clicks outside
it clear the `HyprlandFocusGrab`, which closes the launcher.

`Left`/`Right` cycle tabs, as do `Ctrl+Tab` and `Ctrl+Shift+Tab`. `Up`, `Down`,
and result-navigation `Tab` wrap at the list ends; `PageUp`/`PageDown` jump six
rows and clamp to the first or last result. `Home`, `End`, `Alt+1…8`, immediate
`Enter`, and clipboard `Shift+Delete` remain available. Escape clears a
non-empty query and returns to the active tab's full results; a second Escape
closes the launcher. The result highlight and its glyph color change
immediately without a transition. Switching tabs clears the search field so
results never carry across provider boundaries.

Typed prefixes temporarily override the selected tab: `/` files, `>` command,
`=` calculator, `@` web, `$` windows, `;` clipboard, `:` emoji, and `!` actions.
Removing the prefix returns to the selected tab, so the compact tab strip does
not displace the existing keyboard-first routes.

Clipboard history is collected by `cliphist`; `Shift+Delete` or right-click
removes the selected clipboard entry. Emoji names come from Fedora's
`unicode-emoji` data. Activating an emoji copies it and, once the launcher has
released keyboard focus, pastes it into the previously active window. Both
providers degrade to a readable empty-state error when their package is
unavailable.

`launcher-actions.json` at the shell root is watched for changes. Each user
action must provide a display name and an argv-style command; a string shell
command is rejected deliberately. For example:

```json
[
  {
    "id": "notes",
    "name": "Open notes",
    "subtitle": "Open the notes folder in Nautilus",
    "keywords": ["documents", "writing"],
    "command": ["nautilus", "/home/alex/Documents/Notes"]
  }
]
```

## Dialogs are the menubar unrolled

Every surface in the shell — the settings workspace, T3 Code, the GitHub
workspace, the control centre, the network and audio panels, the notification
centre and its toasts, the launcher, the OSD, the shortcut sheet — used to be
a stack of filled, bordered cards on a lighter surface, and two of them were
in a face of their own. They all follow the menubar now. Four rules, and
`Common/Theme.qml` carries the tokens:

- **One surface.** A dialog sits on `Theme.panelSurface` (the shell's deepest
  surface, glass-aware) with no card stacked on it. `Theme.chip` /
  `Theme.chipHover` are the only fills left inside: a text field, a row that is
  current, a segment that is taken.
- **A section is a label plus a hairline.** `Settings/SectionHeader.qml` is the
  shape — uppercase `fontMicro`, letter-spaced, then a rule to the edge.
  T3's inbox groups and the GitHub workspace draw the same mark inline.
  `SettingsGroup.qml` is a layout, not a Rectangle; there is nothing left to
  paint.
- **One accent, four places.** The current workspace pill, a live status dot
  and its working label, the current page's icon in the settings rail, and an
  on-switch track or selected swatch ring. Never a nav-row background, never a
  selected segment fill, never a wash behind a title, never a slab behind the
  selected launcher result or a connected device. `typography.test.cjs` bans
  `accentBg*` / `accentSoft` / `accentSubtle` / `accentContainer` as a `color:`
  or `border.color:` shell-wide, with a short allow-list naming the four fills
  that earn it: a slider's value readout, a switch or quick-toggle track, the
  one primary action per panel, and the current-day / current-workspace pill.
- **One face.** `Theme.fontMenu`, the Typography setting, everywhere.
  `T3Theme.fontUi` is the T3/GitHub indirection. `Theme.fontSans` is now only
  what `fontMenu` falls back to; **naming it in a view is how a surface opts
  out of the setting**, which is exactly the bug this closed, so
  `typography.test.cjs` bans it outside Theme itself.

Metrics live in Theme's `---- dialog metrics ----` block: `panelRadius` follows
`Settings.barRadius`, so squaring the menubar squares the panels under it;
`panelRowHeight` 28 is a settings row, `listRowHeight` 34 is one menubar-tall
list row, `panelTileHeight` 48 is the occasional two-line form,
`sectionHeaderHeight` 22 is the mark above them, and `panelHeaderHeight` /
`panelFooterHeight` are a panel's title block and its one-line footer.

Two aliases changed meaning rather than value: `Theme.cardFill`,
`Theme.tile` and `Theme.insetSurface` now resolve to `Theme.chip`, and
`cardRadius` / `rowRadius` / `tileRadius` to `chipRadius`. There are no cards
left, so the names that meant "a container with a fill and a border" mean the
menubar's resting chip — which is why most panels needed no edit of their own.
`popRadius` follows `panelRadius`. `surfaceRadius` did **not** move: it is
Hyprland's window rounding (`roles/desktop/files/looknfeel.lua`) and the Hug
corners that must match it, and `bar-geometry.test.cjs` pins the pair.

Two things this pass had to fix, both worth remembering:

- **A fixed pixel lane beside a text label breaks when the face changes.** The
  GitHub inbox positioned its Settled count at `leftMargin: 62`, which cleared
  the word only in a proportional face; in JetBrains Mono the two overlapped.
  Anchor a count to `label.right`, never to a measured constant. Lanes that
  clear a fixed-size *icon* (the 30–32px ones) are fine.
- **Compact a row as a layout change, not a token change.** T3 first moved its
  inbox to one line; GitHub later followed. GitHub's Inbox is deliberately only
  a coloured status glyph and meaningful title; workflow rows prefer GitHub's
  run display title over generic workflow names such as `CI`. Repositories and
  commits keep their context in bounded lanes beside the title. Simply
  shortening the old two-line card would draw its detail through the next
  section header.
  `github-inbox-structure.test.cjs` requires all three lists to use the shared
  flat row and pins the Inbox's quieter status treatment separately.

`SettingsHelpers.semanticPalette` also gained a real step at every level. It
built the ladder with `ensureContrast`, which only ever *raises* a colour, so a
Material palette whose `onSurfaceVariant` already cleared 7:1 returned the same
tone for all five steps — in wallpaper mode every label, value and piece of
metadata rendered identically. `paletteTone` folds the tone back toward the
background when it over-clears, so each step lands on its own floor.

## The edge drawer and the Day sheet (2026-09 redesign)

The 2026-09-03 redesign ("Quickshell Menubar", Claude Design project
`8cf85161`, direction 2) introduced the attached surface family:

- **The Control Dashboard** (`Popovers/Drawer/`) is one edge-drawer surface
  with six tabs —
  Overview · Sound · Network · Bluetooth · Power · Notifications. Every
  established popout name (`control`, `audio`, `wifi`, `bluetooth`,
  `tailscale`, `battery`, `notifications`) still works from IPC and
  the bar; each one presents its tab of
  `DrawerPopover.qml`. The tab is derived from `Popouts.currentName` at
  creation, and the drawer's own tab strip navigates by reopening the
  canonical name for the wanted tab (`PanelRegistryData.nameForTab`), so the
  bar's held states, hover-crossing and the module-ownership sweep all keep
  working unchanged.
- **Updates is a dedicated edge drawer** (`Popovers/UpdatesPopover.qml`). The
  widget and `updates` IPC name open its full pending, running, completed, and
  failed views rather than deep-linking to Overview. It still carries the new
  drawer template's width, attached geometry, Hug corners, palette, and type.
  Every state uses one layout. A one-line header states what is happening.
  Fixed System, Apps, Firmware and CybexOS rows move from a count to progress
  to a result. There is one primary action (Update, Restart now or Try again).
  A collapsed **Details** section holds package names, the live transaction,
  dnf's own error and the recovery point. Keep backend vocabulary (dnf,
  Flatpak, poll cadence, log paths) and negative results ("no restart
  needed") out of the rows and header.
- **Firmware installs inside the update run, never in a terminal.** When
  firmware is pending, `Updates.run()` passes `--firmware`. The durable worker
  then runs `cybexos-firmware-update` (libfwupd over D-Bus, as root) after
  the packages and streams JSON events to `firmware-events.log`, which the
  panel reads like the dnf and Flatpak logs. fwupd's device requests (such as
  replugging a dock) appear as a card under the Firmware row. Capsules staged
  for the next boot turn the run's restart recommendation on. On battery, a
  device that requires AC power is left out of the run, and the row asks for
  power instead of letting fwupd fail the flash. A firmware failure never
  fails the package update; the row explains it.
- **T3 Code is a separate attached panel**, not a seventh status tab. Its
  existing `t3code` panel name, bar ownership, source, and IPC route are
  unchanged; unlike the status drawer, it is not pinned to a screen edge, so
  it follows the T3 widget when that widget is reordered or moved between bar
  sections. It uses the wider `Theme.t3MaxWidth` measure and hugs the active
  page's content until it reaches the host's usable-height cap, at which point
  only the page's content viewport scrolls.
  Inbox search and connection chrome stay fixed around a scrolling grouped
  list; thread headers and response/composer controls stay fixed around the
  transcript; New Thread scrolls its form below a fixed header. Below 360px of
  effective content width, inbox rows become two-line tiles and composer
  reasoning moves into Run settings. Picker geometry is clamped to the drawer
  body and New Thread reserves popup room in its own scroller rather than
  extending a transparent surface tail.
- **The Day sheet** (`Popovers/DaySheetPopover.qml`) hangs under the clock
  (and the weather pill): big time, today's sky, a Monday-first week strip
  with per-day forecast and calendar event dots, and the next three events.
- Clock and Weather options share `Settings/WeatherLocationPicker.qml`.
  City search uses Open-Meteo geocoding (GeoNames), debounces typing, and
  distinguishes matches by region, country, and coordinates. Typing previews;
  Enter applies a sole match, while ambiguous results require selection.
  A selection saves the name and both coordinates in one settings write.
  Clearing or dismissing a search preserves the saved location; timeouts and
  stale replies cannot overwrite it. Manual coordinates remain available.
  This sets the forecast location, not the system clock's time zone.
- The registry gained two flags: `attached` (flush under the bar, squared
  bar-side corners, Hug-corner bridges drawn by `Bar/PopoutHost.qml`) and
  `edge: "right"` (pinned to the screen edge instead of centred on the
  trigger). Both are read by the popout host; detached panels are untouched.
- The visual system moved with it: warm charcoal surfaces (`#1a1917` bar and
  panel, chartreuse `#d3d283` accent), Figtree as the default UI face, and
  `Theme.fontNumeric` (Geist Mono) for every instrument reading — the clock,
  percentages, meters, resets. Clock+weather group into one filled `time`
  pill; notifications joins the filled vol/wifi/bt/batt `status` pill by
  default and can be separated under Widgets → Notifications. Grouping still
  follows adjacency (`SettingsHelpers.MODULE_GROUPS` / `FILLED_GROUP_KINDS`);
  the usage chips
  carry a 2px remaining meter; the bell wears an unread dot instead of a
  count.
- The pre-drawer popovers (`AudioPopover`, `WifiPopover`,
  `ControlCenterPopover`, …) are no longer reachable from the registry but
  remain in the tree with their tests until a deliberate removal pass.

## Layered Hug, glass, and the wallpaper palette

The 2026-08-15 redesign ("QuickShell Menubar", Claude Design project
`facd7f56`) replaced an opaque bar and its bar-fused popouts with translucent
glass and detached panels. What that added, and what it needs:

- **Pinned shell fonts.** The UI typeface remains configurable. Generic
  interface icons use bundled Tabler 3.48.0, loaded once by
  `Common/TablerIcons.qml`; no icon font installation or font-cache refresh is
  needed. Product marks still use `BrandIcon`, and application icons use the
  desktop theme.
- **Icons use an explicit registry.** `Sym { name: "wifi" }` resolves through
  `Common/TablerGlyphs.js`. Existing semantic names remain as compatibility
  aliases for built-ins and plugins; canonical bundled Tabler names also work.
  Unknown names show help-circle and empty names draw nothing. `Sym` reserves
  a square slot and always draws the outline variant, including active states
  and playback controls. Selection uses colour, backgrounds, borders, labels
  and checkmarks; pinned thread actions use accent ink and favourite stars
  use amber. Icon colour fades, press feedback and spinners remain. Legacy
  `fill`/`animateFill`/`glyphFill`/`symbolFill` inputs are accepted but inert,
  as are `symWeight`/`grade`. The filled font is no longer shipped.
  `tests/quickshell/tabler-icons.test.cjs` checks names and actual codepoint
  coverage in the bundled font, without system dependencies. Brand/application
  artwork and functional shapes such as switch tracks and progress meters
  retain their own presentation.
  Update assets with `scripts/update-tabler-icons`; see `assets/tabler/README.md`.
- **Blur is the compositor's.** `roles/desktop/files/looknfeel.lua` exports the
  named `quickshell_blur_rule` matching the `qs-*` namespaces. The Appearance
  switch calls that handle through `hyprctl eval`; its initial `enabled` value
  is read from the persisted JSON so compositor reloads retain the choice.
  Layer namespaces stay fixed because changing one after a Wayland surface is
  connected does not update the compositor rule safely.
- **Nothing that floats over the desktop may draw a drop shadow.** Blur is
  applied per pixel of the *surface*, and every one of these layers is larger
  than the shape it draws — the menubar's runs past the slab to leave room for
  tooltips, a panel's runs past the card. Anything painted into that margin is
  blurred with the shape, at the full size of the layer, so a shadow does not
  read as a shadow: it reads as a haze band the height of the whole surface.
  Both the design's `0 20px 50px` shadows shipped that way and both were
  reported. Raising `ignore_alpha` only trims the falloff — the shadow is at
  full strength directly under the shape, which is exactly the band you can
  see. Glass over a real blur already reads as floating; the hairline border
  and the rim highlight do the rest. Glows *inside* a surface (the focused
  workspace pip, the T3 running dot) are fine — they composite over the glass,
  not into the margin.
- **Render semantic surfaces, never raw variants.** `Theme.barSurface`,
  `surfaceStrong`, and `surfaceMenu` select translucent glass or their opaque
  references from `Settings.glassEnabled`. Directly painting `Theme.glass*`,
  `popBg`, or `barBg` bypasses that switch. Modal scrims are deliberately
  separate: they remain translucent safety layers when glass is off.
- **Wallpaper mode is one validated Material palette.** `Common/Palette.qml`
  runs Matugen's tonal-spot scheme for the selected wallpaper, whitelists the
  semantic roles in `PaletteHelpers.js`, and atomically caches both light and
  dark variants at `~/.local/state/cybexos/shell/wallpaper-palette.json`. Theme
  changes select the cached variant. The menubar background remains the user's
  independent bar-color choice while its accents follow this palette. Missing
  or malformed Matugen output leaves the user's mode unchanged and renders the
  stored fixed colors as fallback. Copy-bearing tones are still forced to a
  4.5:1 floor against their opaque reference surface.
- **Bar style is explicit.** `hug` is the default edge-attached slab with local
  `QtQuick.Shapes` concave corners; `floating` alone uses the stored gap and
  radius; `attached` is full-width and square. Hug/attached reserve exactly the
  bar height, and the decorators travel with auto-hide without joining its
  input mask.
- **State layers are shared.** `Common/StateLayer.qml` supplies the 8% hover
  and 12% pressed/focused overlay used by bar primitives, workspace targets,
  shared actions, toggles, and settings controls. Controls retain their press
  scale and accessibility behavior.
- **One spring for continuous motion.** `Theme.springCurve` drives controls and
  in-place movement. Bar popouts use a faster directional enter/exit and a
  lower-overshoot morph between triggers. Colour and opacity never spring — an
  overshooting fade reads as a flicker — so they use the ease curves.
- **The launcher is always keyboard-ready.** Its view and first eight
  alphabetically sorted apps are constructed at shell startup, while
  `Super+Space` reaches it through
  Hyprland's global-shortcut protocol instead of spawning an IPC client. It
  takes exclusive keyboard focus while mapped, forwards an early character or
  Enter across the mapping frame, and never stages result rows behind an
  animation. Launcher-only motion is brief and purely visual.
- **Schema 7 adopts the softer type and density pass.** A stored `Urbanist`
  value from an older schema follows the new `Google Sans Flex` default;
  OPPO Sans, IBM Plex Sans, and JetBrains Mono remain explicit choices. Shared
  popovers gain modest width and padding, metadata floors at 11px, and soft
  inner hairlines recede while outer surface boundaries remain intact.
- **Schema 6 adds bar style and palette mode.** A v5 attached bar remains
  attached. A v5 floating bar adopts Hug only when height, radius, and gap are
  pristine; custom geometry remains floating. Old wallpaper-accent users and
  untouched colors adopt wallpaper mode, while active custom colors select
  fixed mode without discarding either stored choice. Module order is never
  part of this migration. `SettingsHelpers.adoptRedesign` still gives a v3
  file the schema-4 geometry only where the user never moved it.

## Layout and foreground roles

- Settings use `settingsRowSpacing` for ordinary rows, `settingsContentSpacing`
  for related rich content, `settingsSubsectionSpacing` before a subsection,
  and `settingsGroupSpacing` between groups. Do not use a page's group gap
  inside a compact run of controls.
- `SettingsSubsection` owns its heading and leading separation. Put it **inside**
  a `Revealer` so the separation collapses with the subsection. Keep full-width
  content for `SettingsRow` children; set `insetContent` only for rich content
  that does not already reserve `settingsMarkInset`.
- Standard rows keep the modified-state gutter in wide and stacked layouts.
  Picker height follows its wrapped pills at either width; narrow captions
  sit below the control. Reset lanes remain reserved. Section headings reserve
  reset geometry even when clean; non-resettable subsections opt out of the
  trailing lane.
- Use `SettingsField` for native settings text inputs, including standalone
  forms. `SettingsTextRow` retains ownership of commit/reset/persistence wiring.
  Plugin-kit fields continue using their configurable `Ui`/`Commons` styling.
- `SectionLabel` owns the bounded label/count/rule layout used by ordinary
  popovers and the T3/GitHub group headers. Product-specific colors remain
  overrides; their list row implementations remain separate.
- `Theme.accent` is the chosen fill/swatch color. `Theme.accentText` is its
  contrast-adjusted foreground counterpart for native copy, icons and focus
  outlines. Do not darken the stored accent to make a light-mode label legible.
  T3 and Hermes retain their existing independently adjusted accent roles.

## Already decided against — do not pick these up

- **qmlformat one-shot reformat**: most files would churn and the tool fights
  the deliberate hand-wrapped style. Revisit only as a dedicated commit with a
  tuned `.qmlformat.ini`.
- **Restarting the shell on every converge**: Quickshell hot-reloads, and a
  restart is more disruptive than the problem it solves. A converge that
  changes the deployed tree or unit restarts once from the complete tree,
  because sequential copies can trip rejected intermediate hot reloads, and
  verifies it; an unchanged converge leaves the shell alone. Installing a new
  shell font is the other exception: Qt does not add a newly cached face to an
  already-running process, so the apps role `try-restart`s Quickshell after a
  font install and leaves an inactive service alone.
- **The remaining perf items** (toast countdown timer, memoising
  `Notifs.iconSource`, a `Clock` singleton, a launcher token index): measured
  2026-08-08 and declined. Two premises were already false in the code, and the
  third does not reproduce — with eight notifications the icon lookups go
  8 → 24 → 96 and then flat, identically with and without a memo. Do not reopen
  without new numbers.
- **Merging the remaining list rows into one `ListRow`**: they differ more than
  the shared action buttons did. Reopen only if a fifth consumer appears.
- **`Theme.fontSans` → `Theme.fontMenu` in the launcher and toasts**: those are
  overlay surfaces, not menubar chrome, so they follow the general UI face and
  do not track the menu font setting. `typography.test.cjs` enforces the split.

Still open: **deeper QML state-machine coverage**. The mandatory runtime stage
now exercises helpers under `qmltestrunner-qt6` and constructs, mutates,
signals, and destroys production controls under the real Quickshell engine in
CI. The next targets are the Settings load/merge/save cycle and the
`T3Connection` process/socket lifecycle against controlled test doubles.

## Bluetooth drawer

Bluetooth has its own tab immediately after Network by default. Existing drawer
settings gain the new tab beside Network while retaining their saved order and
visibility; it can then be hidden or reordered in Drawer settings. The Bluetooth
bar button and `popouts open bluetooth` open this same tab.

The tab lists connected and paired devices for the default adapter, with battery
levels when available. Opening the tab while Bluetooth is on automatically starts
a 60-second discovery session and shows named nearby devices. Unpaired discoveries
with empty, address-only, UUID-like or hexadecimal identifier names are hidden;
paired and connected devices remain visible even without a readable name.
Turning Bluetooth on
while the tab is open also starts discovery. **Stop scan** ends it early, and
**Scan again** restarts it after it stops; revisiting the tab starts a fresh scan.
Pairing supports PIN entry, passkey entry/display and code
confirmation inline; successful pairing trusts and connects the selected device.
Errors remain visible for retry. Closing the drawer, switching tabs or powering
off Bluetooth terminates the tab's helper, rejects pending prompts, cancels its
pairing attempt and releases its discovery session. Other applications' scan
sessions and default pairing agent are left alone.

`bluetooth-tool.py` uses the existing `python3-gobject` dependency and BlueZ's
application-scoped agent API. `tests/bluetooth-tool.py` checks input validation,
authorization, cancellation, action failures and discovery lifetime without
operating the host radio.

## Widget editor

Settings → Bar opens with a live preview of the bar pinned above the page:
the wallpaper, the bar at its position, style, height, gap, radius and
background, and each section's enabled widgets as their icons. Clicking a
widget there opens its options. Below it, the **Widgets** group lists Left,
Center, and Right as rows of compact pills with leading icons (no cards).
This includes widgets whose runtime conditions currently hide them from the
bar. Plugins without a declared catalog icon use the extension symbol.
Clicking a pill opens built-in or plugin settings in an embedded, scrollable
dialog; closing it returns focus to the pill. Each pill's ⋯ menu offers
Widget settings…, Move earlier/later, Move to Left/Center/Right, and Remove
from bar. The bar's Layout, Background, and Behavior rows follow on the same
page. This interaction design follows Noctalia's legacy QML bar editor; our
implementation uses Cybex components and storage.

Disabled widgets sit in the **Add widgets** tray below the sections. A click
adds one to its own section; its ⋯ menu picks another. Control Center is a
normal widget: the Fedora button can move, be removed, and be restored. Its
options contain the tab, overview, and behavior controls. Settings search
opens this widget dialog too; there is no separate Control Center sidebar
entry.

Schema 24 adds the Fedora widget at the right edge of older layouts and keeps
all other widget placements. Schema 25 retires the first built-in Model usage
widget (`usage`), its drawer tab and its `modOpts.usage`/`pollMax` settings.
Schema 26 adds `modelusage`, the Model Usage widget vendored from the
`digitalpals.model-usage` Omarchy plugin (see `ModelUsage/README.md`), at the
start of the right section of older layouts. It starts on when the install
has connected widgets. Its settings are `modOpts.modelusage`; sources,
credentials and cost servers stay in the panel's own forms, which Settings
opens.

Drag a pill to reorder or move it between sections. The drag ghost and insertion
marker follow wrapped grid positions and the arrangement scrolls near its edges.
Alt+arrow keys reorder; right-click, Menu, or Shift+F10 exposes placement,
earlier/later, settings, and removal actions. Plugin blocks match the native bar:
before built-ins on the left and right, after them in the center. Drop indicators
snap to those supported boundaries. `Common/WidgetEditor.js` translates visible
gaps to stored indices without changing disabled entries or compaction preferences.

Removal retains placement and settings and offers an eight-second Undo that
restores only that widget. Plugin success is confirmed by both the write result
and the refreshed membership/section before showing success. Section-specific
plugin adds enable and place the instance in one atomic registry write. The settings
writer skips already-persisted bytes before taking its in-flight guard: FileView
does not emit `saved` for an identical `setText`, which would otherwise block
subsequent edits after opening a form that re-applies an unchanged value.

The layout actions menu contains presets, plugin management, built-in layout
reset, and layout Undo. Presets preview their enabled built-ins before applying,
preserve placement and plugin preferences, and use the existing eight-second undo.

Plugin widget details expose width, saved/default setting values, and an
advanced key/JSON-value field. `configure-widget` changes widget enablement,
width, or the destination of a newly added widget atomically. Removing a widget
does not disable its package services or sibling instances. Settings are merged
through the plugin registry, never written into `shell.json`. The Plugins page
retains package installation, updates, cloning and removal; shared plugin
appearance controls live under Appearance.
