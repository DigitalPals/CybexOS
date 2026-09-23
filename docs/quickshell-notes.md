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
- `tests/run` is the strict fifteen-stage source gate: language-aware static
  analysis, Node tests, QML static/runtime checks, integration contracts, and
  the repository's other fixtures. `update --full` runs it before deploying,
  and the Ansible role lints the tree before copying it. See `./tests/run --list` and
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
effects; `LauncherView.qml` only renders its normalized rows. Every open resets
to the Apps tab; Emoji, History (clipboard), and Actions are discoverable tabs
beside it in a compact 460px card. The strip is 34px tall, the search field is
44px, and an up-to-eight-row viewport uses 42px rows with 28px icons. The Apps
tab keeps every visible desktop entry in its model and scrolls inside that
fixed viewport; keyboard selection keeps the active row in view. Rows show one
line only; action subtitles and keywords remain searchable metadata but do not
add visual bulk.

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
  Overview · Sound · Network · Power · Notifications · Usage. Every
  established popout name (`control`, `audio`, `wifi`, `bluetooth`,
  `tailscale`, `battery`, `notifications`, `usage`) still works from IPC and
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

- **Pinned shell fonts.** `JetBrains Mono` is the default UI face;
  `Google Sans Flex`, `Urbanist`, `OPPO Sans 4.0`, and `IBM Plex Sans` remain
  optional menu faces, and `Material Symbols Rounded` supplies every generic
  interface glyph. Audited product marks go through `Common/BrandIcon.qml`,
  while application identities come from the desktop icon theme. The apps
  role installs the packaged faces and the remaining fonts come from
  `inventory/group_vars/all.yml`. **Qt reads the font database once at
  startup**, so a freshly installed face needs
  `systemctl --user restart quickshell.service`, not a hot reload — a missing
  icon font renders each ligature as its own name in plain text.
- **Icons are ligatures, not codepoints.** `Sym { name: "wifi" }` draws the
  word "wifi" shaped into one mark. A name the face does not carry is not a
  blank box, it is the word — invisible to qmllint.
  `tests/quickshell/material-symbols.test.cjs` reads the installed TTF's `post`
  table and checks every name the shell draws.
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
- **Automatic shell restart on config deploy**: Quickshell hot-reloads; a
  forced restart is more disruptive than the problem it solves. Installing a
  new shell font is the narrow exception: Qt does not add a newly cached face
  to an already-running process, so the apps role `try-restart`s Quickshell
  after a font install and leaves an inactive service alone.
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

Settings → Widgets opens **Your bar**, with Left, Center, and Right cards.
Each card has a searchable widget selector and an Add button. Enabled widgets
appear as compact pills with leading icons and the dark settings background, in a responsive
grid (up to three columns). This includes widgets whose runtime conditions
currently hide them from the bar. Plugins without a declared catalog icon use
the extension symbol. The gear
opens built-in or plugin settings in an embedded, scrollable dialog; closing it
returns focus to the pill. The arrangement has no duplicate preview or permanent
detail/browser pane. This interaction design follows Noctalia's legacy QML bar
editor; our implementation uses Cybex components and storage.

Drag a pill to reorder or move it between cards. The drag ghost and insertion
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
