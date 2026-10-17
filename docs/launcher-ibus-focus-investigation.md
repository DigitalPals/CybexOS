# Launcher typing and IBus focus handoff

Investigated on 2026-10-17 at CybexOS source revision `6f4bdca`, using
Hyprland 0.56.2 (`efb50993780079460b0cbed1363e2166a2de1d9f`),
Quickshell 0.2.1 (`dacfa9d`), Qt 6.11.2 and IBus 1.5.34 on Fedora 44.

The fault is in Hyprland's focus-grab path. Activating the launcher's
`HyprlandFocusGrab` before the overlay maps can change seat keyboard focus
without updating the input-method relay. IBus consequently retains the
previous application's context and keyboard grab. Its printable-key commits
are discarded, while its virtual keyboard can still forward navigation keys.

The local fix lets the exclusive layershell surface obtain keyboard focus
first. `LauncherWindow.qml` observes the backing window's `Window.active`
notification and then enables the dismissal grab. Readiness is latched until
close so a focus loss cannot delete the grab before its `cleared` event.
Reopening during the exit animation also handles an already-active window.
After the grab reports active, layershell keyboard mode becomes OnDemand.
Hyprland 0.56 forces pointer hit tests onto exclusive layers even outside their
geometry (`InputManager.cpp`, the `m_exclusiveLSes` branch). Switching only
after the grab is established keeps keyboard ownership and permits outside
clicks to clear the grab. Keeping Exclusive throughout prevented dismissal in
the live check.
The search remains an editable native Qt `TextInput`; applications and the
launcher retain IBus, Compose, preedit, and dead-key support.

Protocol evidence was captured with a temporary runtime drop-in for
`cybexos-input-method.service`, setting `WAYLAND_DEBUG=client` and redirecting
stderr to a task-owned file. The service was restarted before capture and
again after removing the drop-in. Hyprland logging settings were untouched.
The excerpts below contain only the test's synthetic input.

Before the fix, a native Qt fixture accepted exactly `hello` through IBus.
After clearing it, opening the launcher left `CurrentInputContext` at
`/org/freedesktop/IBus/InputContext_3`. The fixture received
`wl_keyboard.leave` at 07:13:14.364, but no `zwp_text_input_v3.leave` until
the launcher closed. There was no IME `deactivate`, `activate`, or grab release
between opening and typing. All five characters disappeared in this captured
run, and the fixture remained empty. The relevant IBus trace was:

```text
07:13:14.364957  zwp_input_method_v2#34.done()
07:13:14.364967  zwp_input_method_v2#34.done()
07:13:14.781402  launcher open; CurrentInputContext = InputContext_3
07:13:14.834857  zwp_input_method_keyboard_grab_v2#39.key(..., 35, 1)
07:13:14.837043  -> zwp_input_method_v2#34.commit_string("h")
07:13:14.837058  -> zwp_input_method_v2#34.commit(13)
07:13:14.996168  -> zwp_input_method_v2#34.commit_string("e")
07:13:15.153150  -> zwp_input_method_v2#34.commit_string("l")
07:13:15.298776  -> zwp_input_method_v2#34.commit_string("l")
07:13:15.455469  -> zwp_input_method_v2#34.commit_string("o")
07:13:16.263956  launcher OCR: Search applications; previous app: empty
07:13:16.342171  zwp_input_method_v2#34.deactivate()  [launcher closing]
07:13:16.342217  zwp_input_method_v2#34.done()
07:13:16.342309  -> zwp_input_method_keyboard_grab_v2#39.release()
```

With the focus gate, the same transition released the old grab and created a
new launcher context before typing. The old fixture stayed empty and OCR
read `hello` in the launcher:

```text
07:13:49.783058  before open; CurrentInputContext = InputContext_3
07:13:49.929896  zwp_input_method_v2#34.deactivate()
07:13:49.929938  zwp_input_method_v2#34.done()
07:13:49.930028  -> zwp_input_method_keyboard_grab_v2#39.release()
07:13:49.930641  zwp_input_method_v2#34.activate()
07:13:49.930646  zwp_input_method_v2#34.done()
07:13:50.300399  launcher open; CurrentInputContext = InputContext_4
```

The source explains the missing notification:

- [`CSeatManager::refocusGrab()` in 0.56.2](https://github.com/hyprwm/Hyprland/blob/efb50993780079460b0cbed1363e2166a2de1d9f/src/managers/SeatManager.cpp#L582)
  calls `setKeyboardFocus()` directly. That updates seat focus and emits
  `m_events.keyboardFocusChange`, but not the global keyboard-focus event.
  `CFocusGrab::start()` installs the seat grab first; its later
  `refocusKeyboard()` returns when that surface already has seat focus.
- [`CFocusState::rawSurfaceFocus()`](https://github.com/hyprwm/Hyprland/blob/efb50993780079460b0cbed1363e2166a2de1d9f/src/desktop/state/FocusState.cpp#L223)
  returns immediately when the seat already focuses the requested surface.
  When the layer subsequently maps, this skips its focus-state update and
  global keyboard-focus notification.
- [`CInputMethodRelay`](https://github.com/hyprwm/Hyprland/blob/efb50993780079460b0cbed1363e2166a2de1d9f/src/managers/input/InputMethodRelay.cpp#L9)
  listens to that global event. Its normal `onKeyboardFocus()` and
  `CTextInput::leave()` deactivation path is therefore bypassed.
- [`IBus 1.5.34 input_method_done_v2()`](https://github.com/ibus/ibus/blob/1.5.34/client/wayland/ibuswaylandim.c#L2327)
  acts on pending activate/deactivate flags. The missing compositor
  `deactivate` never sets the flag. The captured close and fixed-open
  sequences show that IBus releases its grab when deactivation is delivered.

Upstream searches covered issues and commits in both projects. Hyprland
[#16359](https://github.com/hyprwm/Hyprland/issues/16359) reports a related
0.56.2 focus-grab/text-input mismatch for an unmapped popup. It was closed by
the issue-policy bot without a technical fix; its popup-selection problem is
related evidence, not an exact match for this layer-surface reproduction.
Hyprland main at
[`25f09b26`](https://github.com/hyprwm/Hyprland/blob/25f09b26f9db7dbca4a4b3c265fdb96802db122c/src/managers/SeatManager.cpp)
still uses direct seat focus in `refocusGrab()`.

IBus [#2742](https://github.com/ibus/ibus/issues/2742) was fixed by
[`5f2c6c4`](https://github.com/ibus/ibus/commit/5f2c6c444d5d01d147829647ca423bf2056a7752),
destroying the virtual keyboard on deactivation. That behavior is already
present in 1.5.34. Its subsequent Sway zero-size-keymap fix,
[`8757b87`](https://github.com/ibus/ibus/commit/8757b8741ce942a0a9ddfc48eaec4a2668d14861),
is present too. IBus [#2870](https://github.com/ibus/ibus/issues/2870) and
[#2872](https://github.com/ibus/ibus/issues/2872) concern monitor-hotplug serial
and modifier state; the captured launcher failure has no such hotplug or
keymap transition. No upstream fix for this exact missing handoff was found.
A compositor fix should synchronize focus state and the input-method relay
when a seat grab redirects keyboard focus.

The opt-in live regression is:

```bash
python3 -B tests/launcher-input-live.py
```

It requires the managed shell and IBus services, `python3-evdev`, user access
to `/dev/uinput`, Qt's `qml` runner, `grim`, and `tesseract`. It verifies a
native Qt control accepts exactly `hello` and enables text-input-v3, runs at
least ten launcher trials, and repeats the control and launcher check with
`QT_IM_MODULE=compose` on the fixture to verify the non-IBus path. The launcher
keeps its normal input module. Each injected key is guarded by service PID,
fixture keyboard-focus events, launcher-layer ownership, and current window
and authentication-surface checks. No Enter is injected. It also checks
outside-click dismissal using a disposable mouse and an exposed area of the
fixture, then restores the pointer and original window focus. All fixture
processes, input devices, screenshots and logs are cleaned on exit.

Separate workstation checks verified Caps Lock produces `Aa` when toggled
between two `a` presses, and Right Ctrl, apostrophe, `e` produces `é` in both
the IBus-active fixture and launcher. Escape cleared the query and then closed
the launcher. The user's blur preference was preserved in `user.lua`; a
personal `compose:rctrl,lv3:ralt_switch` override supplies the requested Caps
Lock/Compose mapping. Its original 127-byte file is backed up beside it as
`user.lua.before-caps-lock-20261017`.

Both installation paths already consume the shared launcher source. The
desktop-payload regression packages and compares `LauncherWindow.qml`,
`LauncherView.qml`, and `shell.qml` against the checkout. These are source and
payload fixture checks; no new RPM/ISO was built and no end-to-end installation
qualification is claimed. A release containing this change requires rebuilding
and qualifying its installed payload from the release's source revision.

Final validation on the completed workaround:

- The retained live regression passed 10/10 IBus-active opens, the 1/1
  non-IBus control, and outside-click dismissal from both fixture modes.
- `./tests/run`: 16/17 stages passed, including 1,373 JavaScript tests and QML
  lint. The Python stage reproduced only the two failures disclosed before
  this task: report redaction's `xps`/`XPS 14` collision, and the hardware
  package parity fixture's root-owned temporary JSON permission error.
- `python3 -B image/check-source`: the new launcher payload comparison
  passed. The 519-test image suite reproduced the same hardware-package
  permission error; the 14 installer JavaScript tests passed.
- Every live run used `tests/lib/quickshell-live`. The final service was
  active with its MainPID as the only `qs` process, and its current invocation
  had no QML errors. Temporary input-method drop-ins, fixture windows,
  uinput devices, screenshots, source downloads and diagnostic logs were
  removed. The small personal configuration backup is intentionally retained.
