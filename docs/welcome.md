# Welcome to Cybex OS

The welcome guide opens on your focused display after your first desktop login.
It shows your installed language (by name, such as *English (United States)*,
in the guide's language), keyboard layout and time zone, then helps you
choose a wallpaper, appearance and a few useful shortcuts. Changes apply to the
real desktop immediately. Hold Space on the wallpaper step to peek behind the
guide; release it to return. While you type in the Wallhaven search field,
Space types a space instead.

The wallpaper step opens directly in Wallhaven. Selecting a wallpaper downloads
and applies it immediately; progress and errors appear beside the gallery.
Wallhaven lists wallpapers automatically on a known unmetered connection.
Metered or unknown connections show a button to load the listing. A fresh
installation shows the bundled *Moon Mountains* wallpaper until you pick another.
The Style step matches your wallpaper's colours by default, using the bundled
Matugen generator. You can choose fixed colours or a theme preset instead.
**Settings → Wallpaper** also offers the Cybex OS collection and your own pictures.

Use Tab and Enter to operate controls, and Ctrl+PageUp / Ctrl+PageDown to move
between steps. Every step is optional. Escape, the close button and **Skip for
now** keep your progress and dismiss the guide. It will not reopen automatically.
**Finish** marks it complete. Open the launcher and search for **Welcome** to
return, or use **Settings → About → Welcome guide**. A completed guide starts
again at Hello when opened manually.

The steps are Hello, Wallpaper, Style, Shortcuts and Finish. Shortcuts shows
your actual bindings, including changes made in Settings or `user.lua`, and
lets you edit them. An action you disabled shows **Not bound**. The shortcut
backend runs only while that step is shown.

The step list on the left also lists the optional items, each with its own
icon and a tick once done; choosing one opens it on the Finish step. The
Finish step sums up your choices: light or dark, a swatch of the accent and
where it comes from (a theme such as *Cybex OS*, your wallpaper, or your own),
the text size and the wallpaper's name.

In a small window or with large text, the step list on the left is hidden.
Back, Continue and Ctrl+PageUp / Ctrl+PageDown still move between steps.

The optional checklist reads actual assistant sign-in, fingerprint, backup and
online-account state. **Later** remembers an item for another time and never
marks it complete. Web apps are personal choices, so they have no completion
tick. Seeded apps can be kept or removed, and **Install another…** opens the
existing launcher workflow. Hardware security keys remain a plain Settings
link: the security service does not report their physical presence. Fingerprint
setup appears only when its reader is available.

Progress lives in `$XDG_STATE_HOME/cybexos/welcome.json`, normally
`~/.local/state/cybexos/welcome.json`. An unreadable or invalid document is
reported and kept unchanged; the guide can run without saving over it.
`CYBEXOS_WELCOME=0` suppresses automatic opening. Safe mode does not load it.

The shell exposes:

```sh
cybexos-runtime ipc welcome open ''         # resume, or Hello after completion
cybexos-runtime ipc welcome open wallpaper # open a particular step
cybexos-runtime ipc welcome status          # JSON: open/status/step/checklist
cybexos-runtime ipc welcome close           # dismiss, preserving progress
cybexos-runtime ipc welcome reset           # delete only welcome.json
```

For implementation and integration interfaces, see the
[shared contract](architecture/welcome-and-shortcuts.md).

## Validation

`tests/quickshell/welcome*.test.cjs` cover the pure state logic and every action
ID the guide uses against the ungated Lua catalog.
`tests/welcome-guide.py --screenshots DIR` runs the real
shell under a private headless Sway from a private git copy of the checkout
with a test-only IPC target. Shortcut state is served by a fake `hyprctl`
(remapped launcher, disabled Close window). It runs through `nix develop` and checks:

- the fresh-install default wallpaper behind the first frame, against the
  bundled image;
- direct Wallhaven browsing and automatic apply after keyboard selection, with
  a scripted offline listing/download boundary;
- real Matugen generation for the default and selected images, light/dark
  palettes, explicit fixed-colour preservation, and Style → Shortcuts navigation;
- Space typing in Wallhaven search without a request;
- the Space peek, by comparing a frame taken while Space is held (past the
  key-repeat delay) with a desktop-only frame;
- the guide's own keys (Ctrl+PageUp / Ctrl+PageDown, Escape) working at once
  after the shortcut recorder closes by Escape or by accepting a key;
- a resize sweep through the height at which the guide switches to its short
  layout, in both directions, with no binding-loop warning in the log;
- the minimum size at text/density extremes, Escape from inside the picker,
  and the claim release;
- a tour of every step in English and Dutch at the default and minimum
  sizes, saved as `tour-<language>-<size>-<step>.png` cropped to the guide.

It draws with the installed desktop's fonts (`tests/shell_fonts.py`), so the
screenshots match an installation rather than the host's font fallback.

With wtype 0.5, `-P KEY` presses and `-p KEY` releases a key, and an unknown
flag makes it exit before typing anything. Keep a press and its release in one
wtype process, and check its exit status. This is not Hyprland runtime,
installation or physical hardware qualification.
