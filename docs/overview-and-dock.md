# Window overview, dock and top processes

Three ways to find and manage what is running. The overview and the process
list ship on; floating workspaces show the dock automatically.

## Window overview

`Super+Tab` opens the overview on the focused screen. A three-finger swipe up
on the touchpad, and `cybexos-runtime ipc overview toggle` (also `open` and
`close`), open the same overview.

Every workspace that has windows is a tile, along with the workspace on screen
now and one empty **New workspace** tile at the end. Each tile shows its
windows as live thumbnails, placed and sized as they are on the monitor. The
current workspace's number has the accent pill, as on the bar. Scratchpad and
other special workspaces are not shown.

- Click a window, or select it and press `Enter`, to switch to it.
- Arrow keys move the selection to the nearest window in that direction,
  across workspaces. `Tab` and `Shift+Tab` step through windows in order.
- Typing filters windows by title or application, ranked as the launcher's
  `$` window search ranks them. Windows that do not match are dimmed.
- Drag a thumbnail onto another tile to move the window there; dropping it
  on **New workspace** moves it to the lowest unused workspace number. You
  stay where you are.
- Click an empty part of a tile to switch to that workspace.
- `Esc` clears the filter, then closes. `Super+Tab` or a click on the
  background closes at once.

The overview draws the wallpaper behind the tiles instead of a blurred
desktop, because a blur behind live captures would be recomputed every frame.
Thumbnails capture only while the overview is open. When it closes, the view
and every capture are released. Reduce motion (Settings → Appearance) turns its
fade and scale into a cut.

## Dock

The dock appears automatically on each screen whose current workspace uses
the Floating layout. The [Mac-like desktop style](mac-style.md) shows it in
every layout, draws it as a Mac dock and opens the overview as Mission
Control. Switching that screen to Tiled or Scrolling removes its
dock. **Settings → Bar → Dock → Show in all layouts** also shows it in other
layouts; existing saved choices for that switch are retained. Auto-hide is
available in either case, and changing layout never changes your pins.

It sits centred at the bottom of the screen and shows pinned apps first,
then other running apps, with a line between them. A running app has a dot;
the focused app has a wider accent mark.

- Click an app to open it, switch to its last-used window, or cycle through
  its windows when one is already focused.
- Middle-click opens a new window.
- Right-click for **New window**, **Pin to dock** or **Unpin from dock**, and
  **Close window**. Close asks each window to close, as its title bar does, so
  applications still ask about unsaved work.

Until you pin or unpin something, the dock suggests your default browser,
Files and the terminal. Pins are desktop entry ids stored in `dockPinned` in
`~/.config/cybexos/shell.json`. A pinned app that is not installed is not
shown, but it stays pinned.

Browser web-app windows, including Brave's URL-based app windows, match their
installed web-app launcher so the dock uses the app's name and saved icon and
can pin or relaunch it. Different app paths on the same host stay separate;
ambiguous matches keep the normal window fallback.

With **Auto-hide** on, the dock slides away when the pointer leaves it. Point
at the bottom edge where it was to bring it back. Without auto-hide, tiled
windows stay clear of it.

When the bar is at the bottom, the dock sits above the bar and never covers
it. In that layout the dock does not reserve space of its own: two reserved
zones on the same edge would be ordered by the compositor, and a hotplug
could put the dock under the bar.

## Top processes

The Control Center's Overview tab lists the six busiest processes under the
CPU and memory meters. **CPU** and **Memory** choose the ranking. CPU is each
process's share of the whole machine since the previous reading, on the same
scale as the CPU meter. The list is read every two seconds only while it is on
screen, by one short-lived helper (`desktop/quickshell/scripts/processes`) that uses shell
builtins only. Hide it under the Control Center widget's **Overview** settings
(**Top processes**).

The × on a row ends one of your own processes after a confirmation. The shell
sends SIGTERM so the application can save and quit. If it is still running
three seconds later, the list offers **Force quit** (SIGKILL). Both signals
check the process's start time, so a process ID reused in the meantime is never
signalled. Processes that belong to other users have no end button, and neither
do processes whose end would end the session or the shell (Hyprland, systemd,
Xwayland, the lock screen and the shell itself).

**Open system monitor** opens `btop` in Kitty, as `Super+Shift+T` does.

## Verification

Node tests cover the pure rules: `overview-helpers`, `dock-helpers`,
`process-list-helpers` (including the helper script against the live `/proc`)
and `window-commands`. `desktop-navigation.test.cjs` covers the QML lifetimes
and wiring. The real-engine lifecycle harness builds the overview view on an
empty desktop and runs two samples of the process list.
The shared NixOS module checks checks that both installation paths ship the
same files and defaults. Live behaviour still needs checking on a Hyprland
session: thumbnail capture, drag-to-move, multi-monitor tiles, dock auto-hide
over a bottom bar and the touchpad gesture.

The 2026-10-21 development-session check verified automatic dock appearance
on an empty Floating workspace, removal on Tiled and Scrolling, and the
all-layout override. The running Brave WhatsApp window resolved to its
WhatsApp launcher, name and saved icon; a dock-only capture confirmed the
rendered icon. The test restored the temporary workspace override and focus,
left pins and auto-hide unchanged, and finished with one service-owned
Quickshell process and a clean current-invocation journal. This was a live
desktop check, not an ISO build or an end-to-end installation qualification.
