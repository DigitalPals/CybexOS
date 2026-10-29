# Onboarding accents and assistant permissions — 2026-10-29

## Findings and changes

Selecting **One accent colour** after a named theme only set `paletteMode` to
`fixed`, which was already the theme's mode. The theme identity and surface
palette remained active. The real welcome-guide test reproduced this with
Nord: after activating the solid-colour radio, `styleSource` was still `theme`,
`theme` was `nord`, and `themePaletteActive` was true.

The row and its six swatches now use the same operation: clear the named
theme and its palette, select fixed colours, and apply the chosen accent.
Wallpaper, text size, font and other preferences are preserved.

The assistant previously asked for most commands and edits outside its own
preferences/plugins. Both agent adapters now automatically accept those tool
requests by default. `assistantApprovalPolicy` defaults to `always`; Settings
→ Assistant → Tool permissions also offers `ask` (**Ask first**). The service
reads the choice from the user's shell settings for each new turn. Automatic
approval does not create conversation grants that would bypass later checks.
Existing refusals, staged system updates, polkit authentication, cancellation
and file snapshots for Undo remain in place. Agent instructions describe the
new behavior so they do not ask for duplicate command/edit confirmations.

## Validation

- `nix develop -c tests/run`: passed, including 730 primary Python cases,
  1,509 passed Node cases (16 skipped), the standalone protocol/helper checks,
  theme/plugin tests and Model Usage tests. The subsequently added assistant
  restart regression also passed in the final focused suite of 49 cases.
- `nix develop -c tests/qml-lint`: 447 production QML files and four harnesses
  passed; eight existing warnings remained.
- `tests/welcome-guide.py --screenshots DIR`: passed under private headless
  Sway with the real production shell and Matugen. Actual keyboard activation
  selects the solid-accent row from Nord, clears its palette, applies all six
  accents, and persists the last accent and cleared palette to disk. The
  broader welcome, sign-in, wallpaper, navigation and restart checks passed.
- `tests/assistant-overlay.py`: passed with the real shell and assistant
  service against a scripted Claude CLI. A command proceeds without a card
  on fresh defaults; explicitly selecting Ask first makes the next command
  wait for a card, without restarting the service. Undo, sign-in, dragging,
  widget hand-off and hiding also passed.
- Both Claude and Codex protocol suites cover automatic command and ordinary
  file-edit approvals, other tools/access requests, repeated turns, restart,
  invalid preference fallback, opt-in cards, refusals, cancellation and Undo.
- Rebuilt the desktop, assistant and lifecycle test-driver closures. Ran the
  actual `checks.x86_64-linux.vm` driver in a disposable QEMU guest: passed
  in 190 seconds, including real software, maintenance, regional and local
  staging, preservation of personal files, and interrupted-worker recovery.

The VM initially encountered the Debian host's unreadable QEMU configuration;
`QEMU_OPTS=-no-user-config` avoids loading it. The completed run used a private
runtime and temporary directory inside its managed workspace, with a short
symlink for Unix sockets. This validation did not run real provider/model
sessions, fresh ISO installation or physical hardware qualification. No new
ISO was built or served, and the running workstation was not activated.

## Cleanup

All test services and task-owned Quickshell/QEMU processes were stopped.
Managed test leases were released and checked. Temporary VM state, private
source copies, logs, screenshots, build links and the task staging directory
were removed. The CI capacity reservation was released. No task-specific
binary artifacts are retained; normal Nix package outputs remain in the shared
build cache.
