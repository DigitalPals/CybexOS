# Mac-like desktop style

**Settings → Appearance → Desktop style** switches the whole desktop between
the Cybex OS look and a Mac-like one. It is an appearance setting only: it
does not change keyboard shortcuts, workspace layouts or how windows tile.
Floating workspaces still give windows title bars; tiled and scrolling ones
still tile.

The style overrides other choices without changing them. While it is on, the
colours, font, glass, menubar style and dock visibility come from the style.
Your own accent, palette, font, bar colour, bar style, glass and dock choices
stay stored, and choosing **Cybex** brings each of them back as it was. Those
rows on the Appearance page say so while the Mac-like style is on.

The setting is `desktopStyle` (`"cybex"` or `"mac"`) in
`~/.config/cybexos/shell.json`.

## What changes

### Colours, font and glass

- Apple's system colours for surfaces, text and status hues, with the system
  blue accent (`#0a84ff` dark, `#007aff` light), in both light and dark mode.
- Inter for the shell, the title bars and GTK applications. Apple's SF Pro
  cannot be redistributed; Inter is the closest open font.
- Glass: the menubar, menus and dock are translucent over a blurred desktop.
  High contrast still turns glass off.

### Menubar

A thin, full-width translucent bar:

- **Cybex symbol:** the system menu with About Cybex OS, System Settings,
  Software Update, Sleep, Restart, Shut Down, Lock Screen and Log Out.
- **The focused app's name, in bold:** New Window, Hide, Hide Others, Show All
  and Quit.
- **Window:** Minimize, Zoom, Enter Full Screen, Float or Tile, Move to
  Workspace (each workspace, or a new one), Bring All to Front, the app's
  windows (the focused one checked, minimized ones marked) and Close Window.
- **On the right:** your status widgets, a search glyph that opens Spotlight
  and the time at the right end.

Menus open from their title, and once one is open, pointing at another title
switches to it, as on a Mac. The arrow keys and Enter work inside a menu;
Escape closes it.

Hide minimizes every window of the app; Quit asks each of its windows to
close, as their title bars do, so unsaved work still prompts. Linux
applications do not publish their own File, Edit and View menus to a Wayland
menubar, so those menus are not shown.

Your widgets keep their order, but the centre group (the time) moves to the
right end. Dragging widgets along the bar is off in this style; rearrange
them on the Bar page.

### Windows

- **Title bars** on floating windows carry the traffic lights on the left,
  close, minimize and zoom, which show their symbols while the pointer is
  over any of them. On a window out of focus they turn grey and the centred
  title dims. Double-clicking a title bar still zooms the window.
- **Corners and shadows:** windows get continuous ("squircle") corners and a
  deep, soft shadow below them, lighter on windows out of focus. The corner
  radius itself does not change.
- **GTK applications** (Files, Text Editor and other GNOME apps) draw their
  own title bars. Their window buttons move to the left and are drawn as
  traffic lights. GTK greys out their minimize button because Hyprland does
  not let applications minimize themselves; use the dock, the Window menu or
  the title-bar button of a Hyprland-drawn window instead. GTK reads its
  stylesheet as an application starts, so restart a GTK application after
  switching style. Its button layout and font follow at once.
- **Browsers and Electron applications** draw their own buttons. Browsers
  follow the left-hand layout; their look depends on the browser's theme.

### Dock

The dock appears in every layout, not only on floating workspaces. In the
Mac-like style:

- Icons grow under the pointer and bounce while an app starts.
- Running apps carry a small dot.
- After a divider come the minimized windows, each as its last frame with its
  app's icon in the corner, and the Trash, which opens the trash in Files.
- Minimizing a window draws its last frame shrinking into the dock. With
  reduced motion, or when a frame cannot be captured, the window minimizes
  at once. Keyboard shortcuts minimize directly.

### Spotlight and Mission Control

- **The launcher** (Super Space, or the menubar's search glyph) opens as
  Spotlight: wider, higher on the screen, led by one large search field and
  without the tab strip. The prefixes and Ctrl+Tab still switch providers.
- **The window overview** (Super Tab) opens as Mission Control: the other
  workspaces in a strip along the top and the current workspace's windows
  spread out side by side below it. Clicking, dragging a window onto another
  workspace, typing to filter and the arrow keys work as in the overview.

## How it reaches each part

The setting is a shell setting. Everything outside the shell follows it
through the system theme's tokens (`~/.local/state/cybexos/theme/tokens.json`,
`style`):

| Part | Where |
| --- | --- |
| Shell colours, font, menubar, menus, dock, Spotlight, Mission Control, minimize animation | `desktop/quickshell` (`Common/Settings.qml` effective values, `Common/MacDesktop.qml`, `Common/Minimizer.qml`) |
| Corners and shadows | `scripts/theme_hyprland.py`, applied by `desktop/hypr/looknfeel.lua` |
| Title bars | `desktop/hypr/workspaces.lua` and the title-bar plugin; `desktop/hypr/titlebars-native.patch` adds the unfocused title colour |
| GTK buttons, font and stylesheets | `scripts/theme_gtk.py` |

The theme's ownership rules apply. A compositor value that `user.lua` sets is
left alone until the next configuration reload. GTK's button layout and
interface font are changed only while they hold GNOME's default or the value
the style set, and switching back to Cybex returns a key the style set to
GNOME's default. A layout or font of your own is never replaced.

GTK applications read the style's stylesheet through an `@import` line that
`cybexos-personal-init` puts at the top of `~/.config/gtk-3.0/gtk.css` and
`~/.config/gtk-4.0/gtk.css` when those files do not exist yet. Rules of your
own belong below that line. An existing `gtk.css` is never changed: add the
line yourself to use the style's GTK buttons with it.

## Verification

Node tests (`tests/quickshell/mac-style.test.cjs` and the system-theme tests)
cover the setting and its effective values, the GTK and compositor theme
targets, the menubar's fit pass, Mission Control's layout and exposé, the
menus' actions and the minimize paths.

`checks.x86_64-linux.mac-style` (`nix/tests/mac-style.nix`) boots a real
Hyprland session with the style seeded. It checks the tokens, Inter, the
compositor's corners and shadows, the title bars, GTK's button layout, font
and stylesheets, the menus, Spotlight, Mission Control, the dock, the minimize
animation through the title bar's IPC route and the light half of the style.
It then switches back to Cybex and checks that each part returns, and fails
on QML errors in the style's files. Screenshots of each view are kept in its
output.

This is VM qualification of the session, not of physical hardware.

On 2026-10-28 the check passed in a NixOS VM (1280×800, Hyprland 0.56.2)
on top of main at e4bcc97, with these results:

- **Mac-like style:**
  - Inter is installed, and the tokens carry `style: "mac"`.
  - The compositor reported `rounding_power` 3 and a 34 px shadow dropped
    `[0, 12]`, lighter on unfocused windows.
  - Title bars were left-aligned and centred, with symbols on hover.
  - GTK used `close,minimize,maximize:` and `Inter 11`.
  - The title bar's minimize route answered `ok`, and the window landed in
    the dock.
- **Back to Cybex:** `rounding_power` 2, the 4 px shadow, right-hand buttons,
  and GNOME's default button layout and font all returned.
- **Not covered:** the light half was checked only by screenshot.
- **Found along the way:**
  - The dock's item names and menu hover highlight never appeared in either
    style: the auto-hide hover layer above the items took the pointer's hover
    events. Items now read the pointer from that layer, as the menubar's
    widgets do.
  - The title-bar plugin kept a title's first colour after a live theme
    change; it now redraws the title when its colour changes.
