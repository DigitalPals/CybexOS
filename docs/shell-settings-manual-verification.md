# Shell settings — manual verification

The Shell settings workspace makes bar geometry, appearance,
widgets, wallpaper, and system behavior live-configurable, persisted to
`~/.config/cybexos/shell.json`. Automated coverage:
`tests/run` — the Node suite (store merge/clamp rules, schema/property
agreement, qmldir completeness, IPC single-declaration, typography lint) plus
`tests/qml-lint`, a qmllint sweep over every shell QML file — and
`tests/verify-system` (settings IPC liveness). Everything pointer-driven below
is manual.

## Opening and closing

- [ ] `cybexos-runtime ipc settings toggle` opens the centered window; again
      closes it.
- [ ] On an output with at least 900×664 logical pixels available, the card
      opens at 900×664 with the labeled sidebar: Personalize (Appearance,
      Wallpaper, Bar, Notifications), Devices (Displays, Sound, Network,
      Touchpad) and System (Power, Region & formats, Online accounts,
      Plugins, About), all visible without scrolling and with no dots on
      changed pages. Below 860px available width, the same navigation becomes
      an icon rail with hairlines between the groups, themed tooltips and
      42px targets.
- [ ] `cybexos-runtime ipc settings open bar` lands on the Bar page. The
      retired ids still work: `open modules` lands on Bar, with its widgets
      at the top, and `open system` on Power. The recovery-boot notification's action lands on About's
      recovery points, and the power drawer's Idle settings on Power.
- [ ] The header reads "<Page> · <description>" with the description in its
      own capitalization (Network shows "IP addresses and DNS"). It carries
      only Close, whose tip appears on hover (panel-colored, not a yellow
      system box) and never merely because it has focus.
- [ ] With the window freshly opened, the first Tab lands in the search
      field, then the current page in the rail, then the page; Close comes
      last. No Tab-then-Enter sequence from the start resets anything.
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
- [ ] A changed row wears the accent mark and, on hover or focus, its reset
      chip. A page with changed values ends in "Reset <Page> to defaults"
      (Displays: "Reset night light to defaults"); pages with nothing changed,
      and pages whose values live outside shell.json, show none.
- [ ] Reset controls reset exactly their row or page and show an eight-second
      `… reset · Undo` line in the rail footer. Undo restores the snapshot; a
      new reset replaces it; any manual edit clears it. A forced save failure
      exposes Retry.
- [ ] The rail footer is empty at rest. A change shows "Saving changes…",
      then "Saved" for about two seconds, then nothing; errors and the newer-
      schema warning stay until resolved.
- [ ] Every page draws one bounded column centered in the pane: labels on
      the left, every control ending on the same right-hand edge, a hairline
      between rows, segmented choices on one track, sliders of bounded length,
      and long choice lists as dropdowns.

## Wallpaper page

- [ ] The page keeps the bounded, centered column of the other pages: on a
      wide window its rows end on the same right-hand edge as Appearance's,
      and moving between the two does not shift the column sideways.
- [ ] A Browse row at the top chooses Library or Online on one segmented
      track, with no changed mark or reset chip.
- [ ] Grid lists the configured wallpaper folder inside the row grid (from
      the label lane to the controls' edge); clicking a thumb swaps the
      wallpaper live, moves the accent ring + ✓, and the Current row under the
      grid names the new file.
- [ ] "Shuffle now" on the Current row picks a different wallpaper each press
      and is disabled while the folder holds fewer than two images.
- [ ] `Super+K` opens the shortcut sheet at up to 1180 logical pixels wide with
      three balanced columns on a wide screen (fewer on a narrow one). There is
      no Hardware keys group, and a long row such as Resize window wraps its keys
      under the label without clipping.
- [ ] The page opens on Library and makes no network request. Choosing Online
      (or `cybexos-runtime ipc wallpaper browse`) shows popular Wallhaven
      results sized for the connected displays; Sort, Category and Size search
      again, and their reset chips restore Popular / General / Fits my displays.
      The Search row runs on Enter or its search button, never on leaving the
      field, and Down moves from the field to the results.
      Scrolling to the end, or pressing Down on the last row, appends the next
      24 results without jumping back to the top.
- [ ] Picking an online result shows download progress on the tile, then saves
      `wallhaven-<id>.<ext>` into the wallpaper folder and applies it (palette
      follows). Picking another result mid-download cancels the first and leaves
      no `.part` file. A saved result shows its download mark and applies
      without a new download. Offline, the view reports a connection error.
- [ ] Rotate 15 min / 1 hour / Daily arms the timer ("Off" disarms).
- [ ] The Folder row shows the folder path as its label in the mono face,
      with the image count on its hint line; an unusable folder shows its error
      there instead. A long path elides in the middle before it reaches
      Choose… and Open.
- [ ] "Choose…" stays inside the settings surface. Valid folders,
      including paths with spaces, preserve the current basename or choose the
      first alphabetic supported image. Empty/unreadable folders change nothing.
- [ ] "Open" opens the selected directory in the file manager. Large folders
      scroll smoothly without constructing every thumbnail at once.
- [ ] Narrow the content below 520px: the gallery switches to one column, the
      rows stack their controls under their labels, and the folder actions drop
      under the path without clipping or covering each other.

## Appearance page

- [ ] Dark / Light changes the shell palette; Glass effect switches the bar,
      popouts, launcher, notifications, OSD, shortcuts, tooltips,
      and floating menus between blurred translucent and opaque surfaces.
      The full-screen shortcut scrim stays translucent in both modes.
- [ ] Glass effect applies without closing Settings or remapping/flickering the
      bar. Toggle it twice quickly, then reload Hyprland and restart Quickshell;
      the final persisted state wins each time.
- [ ] Text & size opens with a live preview — a bar strip (workspaces, date
      and clock, status icons) and a popover with two rows — captioned
      "Preview · text renders at N px". Text size, Interface scale and Density
      resize it along with the rest of the shell, and N matches the rendered
      base size (12 at defaults, 14 at Large with 100%).
- [ ] Text size, Interface scale and Density are in view; Base font size is
      under "Advanced text options", which stays closed on opening. Searching
      "Base font size" opens the disclosure and highlights the row. With a
      changed base size and the disclosure closed, the page foot still offers
      "Reset Appearance to defaults".
- [ ] Interface font is a dropdown at the controls' edge. The closed button
      and every option draw in their own face; picking one reflows the bar and
      popovers instantly. Test every menu font: option names stay within the
      list without clipping.
- [ ] Accent source Wallpaper shows a Wallpaper palette row: six swatches at
      the controls' edge (hover names each) and a hint that reads "Generated
      from <file>" or the generation status. Switching Dark / Light selects the
      cached variant without a new Matugen process; changing wallpaper
      regenerates once after the debounce.
- [ ] Change wallpapers rapidly: no stale palette flashes. Temporarily hide
      `matugen` or feed malformed output: the selector remains Wallpaper,
      the fallback error appears on the palette row, and the stored fixed
      palette renders.
- [ ] Accent source Fixed reveals an Accent color row (six presets, right
      aligned, their name and hex on the hint line) and an Accent hue row
      directly under Accent source, and scrolls them into view. The presets
      are one Tab stop; arrow keys, Home and End move and pick. Presets and
      hue recolor the whole shell, and in Wallpaper mode they are neither
      focusable nor exposed.
- [ ] Resetting Accent source returns to Wallpaper and restores the fixed
      accent with it; Undo brings both back.
- [ ] On the Bar page (moved there from Appearance), Background offers Shell
      Default, macOS, Black, Graphite, Slate, White, and Custom in both
      Wallpaper and Fixed accent modes, and the accent choice leaves it
      unchanged.
- [ ] A Black menubar changes its text/icons to light tones; White changes
      them to dark tones. Accent, warning, error, workspace, weather, and T3
      marks remain legible, with no change to popover colors.
- [ ] Custom reveals Hue, Saturation, and Lightness sliders. Their tracks and
      the real bar update live, the chosen HSL survives a preset round-trip,
      and the Bar Background reset restores the adaptive Shell Default.
- [ ] Panels: Border color appears directly under Border only for Custom, and
      resetting Border also restores the custom color. Border opacity is
      disabled and says why at width 0.
- [ ] Plugins: with Match shell style off, Interface scale, Border and Corners
      appear; Border color only for Custom, Border width and opacity for every
      mode except Shell.
- [ ] Appearance has no preset actions. Fresh settings use Dark mode, Hug,
      wallpaper colors, opaque surfaces, numbered workspaces, JetBrains Mono
      at size 12 and 100% scale, and no panel borders.

## Bar page

- [ ] A preview of the bar stays pinned at the top of the page while the rows
      below it scroll. Over the current wallpaper it draws the bar at its edge,
      in its style (Hug with its inverted corners, Floating inset by the edge
      gap with its corner radius, Attached square), at its height and in its
      background colour, with each section's enabled widgets as their icons,
      the workspace strip and the clock's time. Every Layout, Background and
      Behavior row changes it as it changes the real bar; Auto-hide fades it,
      and Reserve space off lets its window slide under the bar.
- [ ] Clicking a widget in the preview opens that widget's options; closing
      the dialog leaves the page scrolled where it was. At a short window
      height the preview shrinks before the rows lose their room.
- [ ] Position Bottom moves the bar; every popout opens above it with its
      directional motion mirrored, content upright; tooltips flip
      above modules; toasts hug the top edge; Esc/hover-switching still work.
- [ ] Style picker renders Hug as full-width with 16px concave corners,
      Floating as the existing detached rounded slab, and Attached full-width
      and square. Top/Bottom mirrors Hug's corners without mirroring content.
- [ ] Edge gap and Corner radius appear directly under Style only for
      Floating and leave keyboard and accessibility traversal immediately when
      hidden. Their stored values survive a round trip through Hug and
      Attached; resetting Style restores them along with it.
- [ ] Height offers Compact (30), Classic (34), Default (36), Roomy (42) and
      Custom, with the value beside them. A stored height no preset names
      shows Custom. Custom reveals a Custom height slider (28–60 px) that keeps
      the current value, and dragging it across 34 or 42 does not fold it away.
      Resetting Height, the page, or everything returns the picker to its
      preset. Where the bar cannot be that short at the current text size, the
      row names the height it is drawn at. A search for Height lands on the row.
- [ ] Bar background is one row: the label on the left, the seven swatches on
      the control edge. Arrow keys, Home and End move and pick; the hint names
      the colour, its hex value, and whether it adapts to the theme. Custom
      reveals Hue, Saturation and Lightness as attached rows; the row's reset
      restores Shell Default together with the custom values.
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

## Bar page — widgets

- [ ] Left, Center and Right are rows of the Widgets group, separated by
      hairlines rather than cards: the section's name in the label column and
      its enabled widgets as chips in bar order, including widgets currently
      hidden by runtime conditions (drawn quieter). An empty section says so
      and still takes a drop. There is no per-section widget picker.
- [ ] Clicking a chip opens its options in a dialog sized to its settings, with
      scrolling for longer forms. Close or Esc returns focus to the chip
      without closing Settings.
- [ ] Every chip has a ⋯ button with Widget settings…, Move earlier/later,
      Move to Left/Center/Right and Remove from bar; right-click, Menu and
      Shift+F10 open the same menu. Remove retains settings; Undo restores
      only that widget and its placement.
- [ ] Add widgets lists every disabled built-in and every installed plugin
      widget instance as an outlined chip. Clicking one adds it to the section
      it last lived in, settings retained, and keeps focus in the tray; its ⋯
      offers the other sections and its options. With every widget on the bar,
      the tray says so.
- [ ] Drag within and between sections; the section under the pointer lights
      up, the ghost and insertion marker track both axes, wrapped rows, empty
      sections and edge scrolling, and the preview dims the dragged widget.
      Escape cancels without writing. Alt+arrow keys and menu Earlier/Later
      also reorder.
- [ ] Plugin adds are atomic, and reported success waits for the saved registry.
      Plugin ordering matches the bar's separate plugin block in each section.
- [ ] At 480px window width, each section stacks its name above its chips,
      chips use fewer columns, and menus/dialogs remain inside the window with
      accessible controls.
- [ ] The ⋯ beside the caption under the preview offers Presets…, Manage
      plugins…, Restore default built-in layout and Undo. Presets show the
      chosen preset on the preview before it is applied; applying preserves
      placement and all plugin preferences.
- [ ] Detail policy (Auto / Prefer detail / Always compact) is picked in the
      dialog; Prefer detail compacts only after Auto widgets.
- [ ] Notifications → Grouping switches live between Separate and Status
      group. It joins only adjacent Volume, Network, Bluetooth, or Battery
      widgets, and every glyph keeps its own click target inside the pill.
- [ ] Per-module options apply live: clock seconds/date format, battery and
      volume percentage toggles and thresholds, media title format and width,
      T3 label and pulse,
      workspaces min slots / hide empty / dots, notification grouping.
- [ ] Option rows in the dialog follow the page grammar: controls end on one
      edge, rows are separated by hairlines, and explanatory copy (notes title
      privacy, notification grouping, the sign-in policy) sits on the row's
      own hint line.
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
- [ ] GitHub's account and watched repositories sit on the row grid without
      cards: add a repository with Enter or Add, remove one with its ×, and a
      watch error shows under that repository.
- [ ] Reset Bar resets layout, detail policies, and all module options (with
      Undo); per-row undo chips reset one option.
- [ ] Toggles apply to the bar instantly; auto-rules keep working (Media
      only while playing, Bluetooth only when connected, Battery on
      laptops).
- [ ] Disabling a module whose popout is open closes that popout.
- [ ] T3 Code and Model Usage can each be toggled, reordered, and moved
      across columns, including between built-in widgets; a fresh install
      with connected widgets shows Model Usage first in the right section.
- [ ] Model Usage's options (bar display, bar providers, thresholds, refresh,
      account privacy, square cards) apply live, and "Source and accounts" and
      "Cost sources" open the panel's own settings.
- [ ] Disabling T3 Code or Model Usage while its popout is open closes only
      that popout; the other widget still opens normally.
- [ ] Volume, Network, Bluetooth, and Battery can be reordered within or
      across columns; each dedicated popout follows its widget. The fixed
      Fedora Control Panel button remains at the right edge.
- [ ] In a narrow/stacked settings panel, pointer and keyboard drops use the
      correct column-relative index, edge dragging scrolls, and focus returns
      to the dropped row.
- [ ] With the Everything preset, the preview's center section moves aside
      rather than painting over a crowded left or right section.

## Notifications page

- [ ] The sample toast heads the Style group, above Density, in the page's
      one column (no second column beside the rows at any width). It updates
      live for density, icons, body lines and timeout progress; the line under
      it reads position · duration · density.
- [ ] Body preview is a segmented choice of Off / 1 line / 2 lines / 3 lines,
      and the sample and real toasts follow it.
- [ ] Quiet hours Off/Nights hides the Quiet from / Quiet until rows and
      removes them from Tab/Orca traversal; Custom reveals both directly under
      Quiet hours, preserving the stored range. Nights and Custom show the
      range beside the choices.
- [ ] "Send test" sits at the sample's foot and sends a real toast using the
      current settings. With Do Not Disturb or quiet hours active, a line
      under it says the test only collects in the center.
- [ ] On-screen display → Placement Top shows volume/brightness pills
      top-center, clearing the bar; Bottom returns them; slide-in direction
      matches the edge.

## Displays page

- [ ] The arrangement is the display picker. Clicking a tile, or tabbing to it
      and pressing Enter or Space, selects it: the tile gains a check and an
      accent outline, and the group below is titled with its kind and maker
      (for example BUILT-IN DISPLAY · BOE) over a connector · model note.
      Arrow keys on a focused tile place it beside the others and keep focus
      on it.
- [ ] Turning a display off, or setting it to mirror another, moves it out of
      the layout to a chip under it ("DP-1 · off", "HDMI-A-1 · mirrors
      eDP-1"). Selecting the chip opens its rows; turning it on returns it to
      the layout.
- [ ] Every property is one row with its control on the right edge:
      Resolution, Refresh rate, Scale, Mirror and Adaptive sync as dropdowns,
      Rotation as one segmented control, Flipped and Use this display as
      switches. Rotation and Flipped together round-trip all eight transforms.
- [ ] Any edit raises the Apply bar at the page foot: "N changes not applied
      yet" and which ones. Discard restores the live values. An overlap or
      other problem replaces the list with the reason, and Apply does
      nothing. The last row scrolls clear of the bar.
- [ ] Apply turns the bar into "Keep these display settings?" with a
      15-second countdown and a draining line. Keep changes saves; Revert now,
      Escape, closing Settings or the countdown restore the previous
      settings, and a countdown that ran out leaves a note at the top.
- [ ] There is no standing Refresh. Loading and errors appear as a line at
      the top, with Refresh only after an error. Night light and Warmth still
      apply as they change.
- [ ] Warmth drag with Night light on retints smoothly (single hyprsunset
      restart per pause, not per step).

## Network page

- [ ] Saved Wi-Fi and wired connections are a list with their type and a
      Connected status; the physical adapters are a quiet line under it.
      Selecting one opens its settings below, under its name.
- [ ] Connect to Wi-Fi… and Advanced connection editor share one row with the
      VPN, certificates, bridges and routing hint.
- [ ] Autoconnect and Metered connection read as ordinary rows; the metered
      label no longer runs into its choices.
- [ ] IPv4 or IPv6 Manual reveals labelled Address and Gateway fields. A
      malformed entry outlines its field, names the problem under it and in
      the Apply bar. The DNS field reads Additional DNS while Automatic DNS
      is on and DNS servers while it is off.
- [ ] Typing in a field raises the Apply bar at once, and the other
      connections dim until the edits are applied or discarded. Applying an
      active connection starts a trial in the bar ("Keep these network
      settings?"): Keep saves; Revert now, closing Settings or the countdown
      restore. An inactive connection saves directly and says so.

## Sound page

- [ ] The page is settings rows only: no drawer header, no MICROPHONE 100
      heading, no standing Refresh.
- [ ] Output: Volume with a mute button and a percent readout (Muted while
      muted); one row per output device with a check on the default, and
      AirPlay/network outputs folded under "N network outputs". Port appears
      for a device with several ports; Balance (Center, L n, R n) follows a
      drag without snapping back and is greyed out with a reason on a
      non-stereo output.
- [ ] Input: the device list, Input volume with mute, and a live Input level
      meter lined up under the volume track.
- [ ] Hardware profiles are dropdown rows. Each application is one row with
      mute, its level and its output or input device. Advanced audio
      controls opens Volume Control.

## Touchpad page

- [ ] Scroll speed reads 1.0× at the default, snaps to its 1.0 tick, and
      applies to touchpad scrolling as it changes.

## Power page

- [ ] The Idle timeline marks Screen off, Lock and Suspend at their current
      delays on a 1m–2h axis, with Never as a dashed zone at its end. Delays
      that share a value share one dot; neighbouring labels rise onto a longer
      stem instead of touching, at 900px and 480px window widths.
- [ ] Set Lock screen to 30 min with Screen off at 10 min: the span between
      them is shaded amber and the line under the timeline warns that the
      screen turns off 20 minutes before it locks. Lock at Never warns that it
      never locks. Otherwise the line reads the order back in words.
- [ ] Lock screen, Screen off and Suspend are dropdowns that save and restart
      hypridle as before; the power drawer's idle link lands on Lock screen.
- [ ] With `~/.config/cybexos/hypr/hypridle.conf` present, the timeline dims
      and says it is shown for reference; the three dropdowns and Only on
      battery are disabled with "Set in your hypridle.conf".
- [ ] Stay awake Duration starts, retimes and stops the inhibitor; its hint
      shows the time left. Bar indicator → Indicator settings opens the
      Indicators widget on the Bar page.

## Region & formats page

- [ ] 12 h clock reformats the bar clock and the "Now …" caption.
- [ ] °F refetches weather in Fahrenheit (bar chip + popover + forecast);
      the caption reads "… outside" in the new unit.

## Online accounts page

- [ ] With no accounts the group shows "No accounts connected" and an
      accent-filled Add account, which opens the account window. There is no
      standing Refresh.
- [ ] Each connected account is a row (address, provider and status) with a
      Use calendars switch under it. An account needing attention says so in
      amber and offers Reconnect. Remove… asks first; Cancel leaves it.
- [ ] Stop the accounts helper (or break GOA): an error row with Refresh
      appears; Refresh clears it once the helper answers again.

## Omarchy plugins page

- [ ] The rail and header say "Omarchy plugins". Browse plugins opens
      https://plugins.omarchy.org/ in the browser, as does the link in step 1.
      Below 520 px the button drops under the intro copy.
- [ ] Three numbered steps explain finding, pasting and enabling a plugin.
- [ ] Install is disabled until Source holds text; Enter in the field installs.
      Pasting `omarchy plugin add <url> --enable` installs `<url>` (still
      disabled). The result or error reads under the Source row.
- [ ] With nothing installed, Installed shows the "No plugins yet" state;
      otherwise its heading carries the count.
- [ ] Each installed plugin is one row: name, "id · version · adds …", an
      Enabled switch and a ⋯ menu with Update, Preview update, Clone as a
      custom copy… and Remove…. Clone opens a New ID row under the plugin;
      Remove… opens a confirmation row. A command's output reads under the
      plugin it ran on.
- [ ] There is no "Configure bar widgets" link; plugin widgets appear in the
      Bar page's tray.

## About page

- [ ] Status shows a green dot for Healthy, amber for issues or a failed or
      rolled-back deployment, red when the service is down.
- [ ] Last deploy check reads "Today at 19:16", "Yesterday at …", a weekday or
      a date in local time, in the Region clock format; Refresh re-reads it.
- [ ] Recovery points list as rows named by local time, with the UTC stamp the
      boot menu shows for bootable points. Restore… turns the row into a
      warning with Confirm restore and Cancel. With none, the row says
      "None yet".
- [ ] The settings file path elides in the middle; Open saves then opens it.
      Reset all settings is red, resets every page and offers the rail's
      eight-second Undo.

## Regression sweep

- [ ] Volume, Network, Bluetooth, and Battery are distinct transparent-resting
      buttons. Each opens its own Audio, Network, Bluetooth, or Battery view;
      with one open, crossing another button switches the panel in place.
- [ ] The rightmost Fedora logo opens the Control Panel. Its SESSION row shows
      five equal controls in order: Lock, Suspend, Log out, Restart, and red
      Shut down. Each closes the panel before running its established action.
- [ ] The launcher's Power action and `cybexos-runtime ipc session power`
      open/toggle the Control Panel on the focused output;
      `cybexos-runtime ipc session lock` remains a direct lock action.
- [ ] All popouts open/close/hover-switch as before at default settings;
      Calendar → Weather and other adjacent-module switches work without a
      second click; with Settings open, hovering a module also switches.
- [ ] Resize/hotplug from a wide output down to 800 logical px: detail compacts
      Media → Weather → Clock date → T3 → Volume → Battery, every
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
      configuration fills the lane.
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
presents T3/Hermes authentication screens and an
updater endpoint error. Those data sources and commands were not changed for
visual verification. Existing compatibility surfaces keep their separate
cursor-navigation and theme APIs; dense transaction/transcript/list layouts
were not forced into the settings row geometry.

Generated wallpaper palettes were also checked in dark, light and high-contrast
modes, including gallery captions and keyboard selection in Drawer tabs. The
Widgets catalog switches to one column at the settings breakpoint, with inline
settings beneath their owning row and secondary tags yielding to widget names.
