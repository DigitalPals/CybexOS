# Shell settings — manual verification

The Shell settings workspace makes bar geometry, appearance,
modules, wallpaper, and system behavior live-configurable, persisted to
`~/.config/fedora-config/shell.json`. Automated coverage:
`tests/run` — the Node suite (store merge/clamp rules, schema/property
agreement, qmldir completeness, IPC single-declaration, typography lint) plus
`tests/qml-lint`, a qmllint sweep over every shell QML file — and
`tests/verify-system` (settings IPC liveness). Everything pointer-driven below
is manual.

## Opening and closing

- [ ] `qs ipc call settings toggle` opens the centered window; again closes it.
- [ ] On an output with at least 900×664 logical pixels available, the card
      opens at 900×664 with the labeled sidebar. Below 860px available width,
      the same navigation becomes an icon rail with tooltips and 42px targets.
- [ ] `qs ipc call settings open modules` lands on the Widgets page.
- [ ] Gear in the Control Panel footer opens it (and closes the popout).
- [ ] Right-click anywhere on the bar slab opens it; left-clicks on modules
      still open their popouts.
- [ ] `Super+,` opens Settings directly without making the menubar focusable.
- [ ] Drag the header to move the floating window; Super+right-drag resizes it.
      The sidebar responds to the window width, and page contents scroll.
- [ ] Esc first clears search or closes a widget subpage, then closes Settings.
      The close button and the normal compositor close shortcut also work.
- [ ] Clicking another application, opening the launcher, or opening a bar
      popout leaves Settings open. It participates in normal window switching.
- [ ] Repeated `settings open` calls focus the existing window without creating
      duplicates. Closing and reopening works through every entry point.
- [ ] Opening settings while a popout is open closes the popout first.

## Launcher keyboard path

- [ ] Restart Quickshell, then immediately press `Super+Space` and type. The
      first character appears in the search field; no click or second key is
      needed to establish focus.
- [ ] With the empty query and its first result selected (for example,
      1Password), press Enter immediately after `Super+Space`. It launches
      even while the card is still completing its short entrance animation.
- [ ] Down/Up, Tab, Home/End, Alt+1…8, Enter, and Esc all work without moving
      focus out of the search field. Closing restores focus to the prior app.
- [ ] Reopen repeatedly: results appear together without a row-by-row delay,
      and the first open after shell startup feels the same as later opens.

## Persistence

- [ ] First slider drag creates the JSON; `watch -n1 stat -c %y` on it shows
      at most ~2 writes/s during a continuous drag.
- [ ] Editing the JSON externally applies live (no restart); junk values are
      clamped or reverted to defaults on the next save.
- [ ] A schema-5 pristine floating bar migrates to Hug; a customized height,
      radius, or gap remains Floating; an old non-floating bar becomes Attached.
      Module order and centered Clock/Weather remain unchanged.
- [ ] Deleting the file live restores defaults; restart keeps them.
- [ ] Reset controls reset exactly their group and show an eight-second
      `… reset · Undo` footer. Undo restores the snapshot; a new reset replaces
      it; any manual edit clears it. A forced save failure exposes Retry.

## Wallpaper page

- [ ] Grid lists the configured wallpaper folder; clicking a thumb swaps the
      wallpaper live and moves the accent ring + ✓.
- [ ] "Shuffle now" picks a different wallpaper each press.
- [ ] Rotate 15 min / 1 hour / Daily arms the timer ("Off" disarms).
- [ ] "Choose folder" stays inside the settings surface. Valid folders,
      including paths with spaces, preserve the current basename or choose the
      first alphabetic supported image. Empty/unreadable folders change nothing.
- [ ] "Open" opens the selected directory in the file manager. Large folders
      scroll smoothly without constructing every thumbnail at once.
- [ ] Narrow the content below 520px: the gallery switches to one column and
      folder path/actions stack without clipping or covering each other.

## Appearance page

- [ ] Dark / Light changes the shell palette; Glass effect switches the bar,
      popouts, launcher, notifications, OSD, shortcuts, tooltips,
      and floating menus between blurred translucent and opaque surfaces.
      The full-screen shortcut scrim stays translucent in both modes.
- [ ] Glass effect applies without closing Settings or remapping/flickering the
      bar. Toggle it twice quickly, then reload Hyprland and restart Quickshell;
      the final persisted state wins each time.
- [ ] Wallpaper palette shows surface/primary/error swatches and generation
      status. Switching Dark / Light selects the cached variant without a new
      Matugen process; changing wallpaper regenerates once after the debounce.
      Accent colors follow the wallpaper while the selected menubar background
      remains unchanged.
- [ ] Change wallpapers rapidly: no stale palette flashes. Temporarily hide
      `matugen` or feed malformed output: the selector remains Wallpaper,
      the fallback error appears, and the stored fixed palette renders.
- [ ] Bar Background offers Shell Default, macOS, Black, Graphite, Slate, White,
      and Custom in both Wallpaper and Fixed modes. Only the Accent area is
      absent in Wallpaper mode, leaves Tab/Orca traversal immediately, and
      returns with its values unchanged after switching back to Fixed.
- [ ] A Black menubar changes its text/icons to light tones; White changes
      them to dark tones. Accent, warning, error, workspace, weather, and T3
      marks remain legible, with no change to popover colors.
- [ ] Custom reveals Hue, Saturation, and Lightness sliders. Their tracks and
      the real bar update live, the chosen HSL survives a preset round-trip,
      and the Bar Background reset restores the adaptive Shell Default.
- [ ] Font rows render their own family; picking one reflows the bar and
      popovers instantly. Test every menu font: names and samples stay in
      separate bounded lanes with no overlap.
- [ ] Fixed accent swatches and hue recolor the whole shell in Fixed mode and
      are not focusable or exposed in Wallpaper mode.
- [ ] Appearance has no preset actions. Fresh settings use Dark mode, Hug,
      wallpaper colors, opaque surfaces, numbered workspaces, JetBrains Mono
      at size 12 and 100% scale, and no panel borders.

## Bar page

- [ ] Position Bottom moves the bar; every popout opens above it with its
      directional motion mirrored, content upright; tooltips flip
      above modules; toasts hug the top edge; Esc/hover-switching still work.
- [ ] Style picker renders Hug as full-width with 16px concave corners,
      Floating as the existing detached rounded slab, and Attached full-width
      and square. Top/Bottom mirrors Hug's corners without mirroring content.
- [ ] Height slider resizes the real bar live; the miniature tracks it; the
      labeled Height presets row snaps to 38/46/54 without detaching its pills.
- [ ] Edge gap and corner radius are shown only for Floating and leave keyboard
      and accessibility traversal immediately when hidden. Their stored values
      survive a round trip through Hug and Attached.
- [ ] Changing Height or Corner radius dirties/reset-enables Bar only;
      Appearance remains clean. Reset Bar owns and restores both values.
- [ ] Auto-hide: bar slides away after ~1.6 s without hover; hovering the
      screen edge reveals it; it stays out while a popout or the settings
      window is open; clicks pass through the vacated strip.
- [ ] Reserve space off lets tiled windows extend under the bar
      (exclusive zone released; Hyprland re-tiles once per toggle).
- [ ] Every connected output keeps its own bar while focus moves between
      monitors; hotplug creates/removes only that output's bar.
- [ ] Opening a module or Shell settings from either bar shows exactly one
      panel, attached to the bar that was clicked.

## Widgets page

- [ ] Left, Center and Right cards show enabled widgets as pills in bar order,
      including widgets currently hidden by runtime conditions. There is no
      duplicate preview, permanent inspector, or available-widget panel.
- [ ] Each section's searchable selector lists only disabled built-ins and
      installed plugin widget instances. Choose a result and press +: it appears
      in that section with its existing settings retained.
- [ ] The gear opens a dialog sized to its settings, with scrolling for longer
      forms. Close or Esc returns focus to the pill without closing Settings.
- [ ] Drag within and between cards; the ghost and insertion marker track both
      axes, wrapped rows, empty sections and edge scrolling. Escape cancels
      without writing. Alt+arrow keys and menu Earlier/Later also reorder.
- [ ] Right-click, Menu, and Shift+F10 expose Move to Left/Center/Right and Remove.
      Remove retains settings; Undo restores only that widget and its placement.
- [ ] Plugin adds are atomic, and reported success waits for the saved registry.
      Plugin ordering matches the bar's separate plugin block in each section.
- [ ] At 480px window width, headers stack where needed, pills use fewer columns,
      and pickers/dialogs remain inside the window with accessible controls.
- [ ] Layout actions expose preset preview/application, Manage plugins, reset,
      and Undo. Presets preserve placement and all plugin preferences.
- [ ] Detail policy (Auto / Prefer detail / Always compact) is picked in the
      dialog; Prefer detail compacts only after Auto widgets.
- [ ] Notifications → Grouping switches live between Separate and Status
      group. It joins only adjacent Volume, Network, Bluetooth, or Battery
      widgets, and every glyph keeps its own click target inside the pill.
- [ ] Per-module options apply live: clock seconds/date format, battery and
      volume percentage toggles and thresholds, media title format and width,
      usage provider toggles and warn/critical thresholds, T3 label and pulse,
      workspaces min slots / hide empty / dots, notification grouping.
- [ ] Indicators expands inline with Clock hover / Always show / Active only,
      per-action switches, and drag/keyboard ordering. A hidden Dictation or
      Screen recording action returns while running so it can always be stopped.
- [ ] The OCR clock-side action starts region selection, copies recognized text
      to the clipboard, and remains hidden in Active only mode.
- [ ] In Clock hover mode, reveal the indicators and click the clock without
      moving the pointer. They stay expanded; moving into Calendar or switching
      to another bar view causes no collapse or flicker. Close the view and
      leave the bar: indicators collapse normally. A view on another output
      does not hold them open, and opening an unrelated view with indicators
      already collapsed does not expand them.
- [ ] Indicator action options apply live: dictation languages/model, recording
      region/window/screen and elapsed label, reminder icon/count and quick-add
      duration, DND click lifetime, and Stay awake click duration/countdown.
- [ ] Night light, DND, and Stay awake each honor Remember / Off / On after a
      new desktop login. Restarting only `quickshell.service` preserves the
      live state; timed DND/idle requests keep their original absolute deadline.
- [ ] Weather place/latitude/longitude edits commit on Enter or focus loss and
      refetch; Esc inside a text field restores the value without closing
      anything; junk input snaps back to the stored value.
- [ ] Reset page on Widgets resets layout, detail policies, and all module
      options (with Undo); per-row undo chips reset one option.
- [ ] Toggles apply to the bar instantly; auto-rules keep working (Media
      only while playing, Bluetooth only when connected, Battery on
      laptops).
- [ ] Drag a row: source dims, proxy follows the pointer, accent caret
      marks the gap (rows never shift); drop reorders within and across
      columns, including end-of-column; Esc during a drag cancels it (a
      second Esc closes the window).
- [ ] Disabling a module whose popout is open closes that popout.
- [ ] T3 Code and Model usage can each be toggled, reordered, and moved across
      columns; Claude, Codex, and Kimi remain grouped under Model usage.
- [ ] Disabling T3 Code or Model usage while its popout is open closes only
      that popout; the other module still opens normally.
- [ ] Volume, Network, Bluetooth, and Battery can be reordered within or
      across columns; each dedicated popout follows its widget. The fixed
      Fedora Control Panel button remains at the right edge.
- [ ] In a narrow/stacked settings panel, pointer and keyboard drops use the
      correct column-relative index, edge dragging scrolls, and focus returns
      to the dropped row.
- [ ] At 640px of Modules content width, LEFT/CENTER/RIGHT render as three
      columns; below it they stack. In the preview, each lane clips its own
      chips and never paints into another lane. Optional tags disappear before
      a full module name is shortened.

## Notifications page

- [ ] Preview updates live for position, duration, density, icons, body lines,
      and timeout progress. “Timeout progress” and its description never
      collide with the switch or reset lane.
- [ ] Quiet Hours Off/Nights hides custom time sliders and removes them from
      Tab/Orca traversal; Custom reveals both, preserving the stored range.
- [ ] “Send test notification” and its current suppression explanation sit on
      one line when they fit and stack cleanly on a narrow panel.

## System page

- [ ] 12 h clock reformats the bar clock and both live captions.
- [ ] °F refetches weather in Fahrenheit (bar chip + popover + forecast).
- [ ] Warmth drag with Night light on retints smoothly (single hyprsunset
      restart per pause, not per step).
- [ ] OSD placement Top shows volume/brightness pills top-center, clearing
      the bar; Bottom returns them; slide-in direction matches the edge.
- [ ] Poll every 1 min shortens the countdown; the usage popover and the
      caption agree.
- [ ] The full config path elides in its own lane; Open and Reset all remain
      reachable and stack below it before any collision.

## Regression sweep

- [ ] Volume, Network, Bluetooth, and Battery are distinct transparent-resting
      buttons. Each opens its own Audio, Network, Bluetooth, or Battery view;
      with one open, crossing another button switches the panel in place.
- [ ] The rightmost Fedora logo opens the Control Panel. Its SESSION row shows
      five equal controls in order: Lock, Suspend, Log out, Restart, and red
      Shut down. Each closes the panel before running its established action.
- [ ] The launcher's Power action and `qs ipc call session power` open/toggle
      the Control Panel on the focused output; `qs ipc call session lock`
      remains a direct lock action.
- [ ] All popouts open/close/hover-switch as before at default settings;
      Calendar → Weather and other adjacent-module switches work without a
      second click; with Settings open, hovering a module also switches.
- [ ] Click Claude once, then hover Codex and Kimi; the open Usage view changes
      immediately while its panel stays anchored. From another open popout,
      hovering a provider opens Usage after the normal hover delay and selects
      the provider under the pointer.
- [ ] Resize/hotplug from a wide output down to 800 logical px: detail compacts
      Media → Weather → Clock date → T3 → Volume → Battery → Usage, every
      enabled module remains, clusters retain an 8px gutter, and the center
      shifts only after all eligible detail is compact.
- [ ] Fine-grained touchpad scrolling over Volume changes it once per
      accumulated wheel step, not once per raw event.
- [ ] Workspace cells keep a 22px width and full 30px target. Moving right
      sends the lozenge's right edge in 120ms and left edge in 300ms; moving
      left reverses those assignments. Hide-empty/model/settings changes snap,
      while urgency, numbered mode, tooltips, and accessible actions persist.
- [ ] Tab/arrow traversal, automatic focus scrolling, roles/states/actions,
      and Orca announcements work for navigation, custom controls, resets,
      drag/drop, module cogs and their sub-pages, and save errors.
- [ ] Capture comparison screenshots for default Hug/Wallpaper, Floating/Fixed,
      and a narrow panel. In each, check header title/description, preset/test
      action copy, font samples, notification labels, config/folder paths,
      module names, and preview chips for clipping or overlap.
- [ ] `journalctl --user -u quickshell.service` free of QML errors and
      binding loops after exercising every page.
- [ ] `tests/verify-system` passes.

## Consistency regression checks (September 2026)

- [ ] At 900px and 480px window widths, switch Wallpaper/Fixed and Custom bar
      color. Subsection headings, swatches and status text follow the label
      gutter; closed revealers leave no subsection spacer. Long palette errors
      wrap rather than disappearing after two lines.
- [ ] Picker captions stack below narrow controls. Long options can wrap in
      wide rows too, without painting over the next row. Tab to a reset chip:
      its announcement includes the setting name, and focus does not shift the
      control or scroll the page when it moves into navigation/search.
- [ ] Dirty/clean group headers keep their height and label width. Long titles
      wrap within the reserved reset lane. Plugin install/clone fields follow
      the shell palette and show a focus outline in light, dark and contrast
      modes. Test Enter, blur, Escape and normalized/rejected text edits.
- [ ] In the drawer, Tab reaches the current tab; Left/Right and Home/End select
      adjacent/edge tabs. Labels elide before tabs overflow, and a single-tab
      configuration fills the lane. Usage hides the provider selector when
      there is no choice to make.
- [ ] Pale fixed accents remain readable as text/icons/outlines in Light and
      High contrast. The actual swatch/fill is unchanged. Test default, larger
      text/comfortable density, and 80% UI scale/compact density.
- [ ] Notification actions wrap inside their card. Shortcuts become one column
      at narrow widths and scroll with arrows, Page Up/Down and Home/End.
      Wallpaper filename overlays retain white copy over their dark scrim.

### Scope and verification record

The pass covers the Settings workspace and all eight pages, widget detail
controls, wallpaper folder dialog, Bar and tooltip/menu components, launcher,
notification cards/actions, OSD, shortcuts and network overlays, all six Drawer
tabs, Day sheet, updates, notes, reminders, media, GitHub, T3 and Hermes. Legacy
popover entry points and the configurable `Ui`/`Commons` plugin kit were
reviewed through their shared controls and foreground roles. The standalone
welcome UI was inspected separately: its installer typography, palette and
minimum window size are deliberate and remain independent of the live shell.

Rendered checks use the managed service and `tests/lib/quickshell-live` at
both boundaries. Captures exercise each Settings page, the available popout
entry points, launcher and shortcuts, plus wide/narrow appearance combinations.
Runtime component tests additionally cover wrapping picker bounds, subsection
sizing, hidden trailing group content, stable dirty headings, constrained drawer tabs, and text-field commit
normalization. See `tests/qml-lifecycle/shell.qml` and
`tests/quickshell/settings-layout.test.cjs`.

Service-dependent states need an appropriate account/device: this workstation
presents T3/Hermes authentication screens, no managed usage providers, and an
updater endpoint error. Those data sources and commands were not changed for
visual verification. Existing compatibility surfaces keep their separate
cursor-navigation and theme APIs; dense transaction/transcript/list layouts
were not forced into the settings row geometry.

Generated wallpaper palettes were also checked in dark, light and high-contrast
modes, including gallery captions and keyboard selection in Drawer tabs. The
Widgets catalog switches to one column at the settings breakpoint, with inline
settings beneath their owning row and secondary tags yielding to widget names.
