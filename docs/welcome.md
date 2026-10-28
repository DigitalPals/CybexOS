# Welcome to Cybex OS

The welcome guide opens on your focused display after your first desktop
login. It continues the installer: the same full-screen layout, colours and
type, and the installer's step indicator, here Connect · Wallpaper · Style ·
Shortcuts.
Like the installer, it scales its 1280×800 design to the display, so it looks
the same on every screen size.

**Hello** greets you by name and lists what the installer already set:
language, keyboard layout, time zone, network, account and computer name.
Nothing is asked twice. **Change** opens a sheet from the right for the
language, keyboard or time zone, as in the installer; the network opens
Settings. The pills in the top bar show the network, keyboard layout and
language, and the last one closes the guide.

**Connect** offers two optional sign-ins, each on its own card. Both open
windows, so the guide steps aside while you use them:

- **1Password** comes first, when it is installed, so it can fill in the
  password for your AI account in the browser. Its extension in Brave connects
  to the app while 1Password is running, so the browser needs no sign-in of its
  own. The guide comes back when you close the 1Password window it opened. It
  cannot tell whether you signed in, so this card never shows a tick.
- **The AI assistant** (recommended) signs in to Claude Code or Codex with that
  agent's own sign-in, in a terminal and your browser. The guide comes back by
  itself once the agent reports you are signed in. Your sign-in stays with the
  agent; Cybex OS never stores it.

Without a network the step says so and links to the network settings. When
neither 1Password nor the assistant is installed, the guide leaves Connect out.

**Wallpaper** opens on Wallhaven, with the Cybex OS collection and your own
pictures one click away. Choosing a tile applies it straight away. A card
shows it on a miniature of your desktop, with the colours Cybex OS reads from
it. Wallhaven lists wallpapers automatically on a known unmetered connection;
on metered or unknown connections it asks first. A fresh installation shows
the bundled *Moon Mountains* wallpaper until you pick another.

**Style** chooses dark or light, where the accent comes from (your
wallpaper, a Cybex OS theme or one colour of your own), the text size and
glass. A preview beside the choices is drawn with your real settings. The
guide itself keeps the installer's colours.

**Shortcuts** shows the Super keys as a keyboard. Lit keys do something;
choose one to see what, and **Change key** to record another. The essentials
are listed beside it. A change takes effect only once you apply it: when
you leave the step with **Continue**, **Back** or Close, the guide lists what
would change and asks you to **Apply** or **Discard** it first. Enter
applies; **Keep editing** or Escape returns to the step. Your bindings come
from the same data as Settings, including changes made there or in
`user.lua`; an action you disabled shows **Not bound**.

**Ready** sums up your choices and shows what the [system check](system-check.md)
found. It runs `cybex doctor` while you go through the guide: drivers,
services, sound, Secure Boot, firmware updates, storage, battery, the clock
and the desktop. Nothing leaves the computer for that. With the assistant
signed in, **Ask the assistant** hands the check to it: the guide steps
aside, and the assistant explains what it found and proposes fixes, which
change nothing until you agree. Without it, **Connect the assistant** goes
back to Connect.

Ready also offers optional extras: web apps, fingerprint (when a reader is
available), security keys, backups and online accounts. Each opens its page in
Settings; a tick shows what is actually set up.

On Wallpaper and Style, hold Space to look at your desktop; release it to
return. While you type in the Wallhaven search field, Space types a space.

The guide covers the screen, so it steps aside when you open Settings, an
app or a shortcut, and leaves a **Resume** pill at the bottom of the screen.
After the launcher or the overview it comes back by itself.

Use Tab and Enter to operate controls, and Ctrl+PageUp / Ctrl+PageDown to move
between steps. Every step is optional. Escape, the close button and **Not
now** keep your progress and dismiss the guide. It will not reopen
automatically. **Start using Cybex OS** marks it complete. Open the launcher
and search for **Welcome** to return, or use **Settings → About → Welcome
guide**. A completed guide starts again at Hello when opened manually.

Progress lives in `$XDG_STATE_HOME/cybexos/welcome.json`, normally
`~/.local/state/cybexos/welcome.json`. An unreadable or invalid document is
reported and kept unchanged; the guide can run without saving over it.
`CYBEXOS_WELCOME=0` suppresses automatic opening. Safe mode does not load it.

The shell exposes:

```sh
cybexos-runtime ipc welcome open ''         # resume, or Hello after completion
cybexos-runtime ipc welcome open wallpaper # open a particular step
cybexos-runtime ipc welcome status          # JSON: open/status/step/steps/checklist/connect/doctor
cybexos-runtime ipc welcome close           # dismiss, preserving progress
cybexos-runtime ipc welcome reset           # delete only welcome.json
cybexos-runtime ipc welcome connect password # Connect's buttons: password, claude or codex
```

For implementation and integration interfaces, see the
[shared contract](architecture/welcome-and-shortcuts.md). The design comp the
guide was built from is `desktop/welcome-ui-reference/index.html`.

## Validation

`tests/quickshell/welcome*.test.cjs` cover the pure state logic, every action
ID the guide uses against the ungated Lua catalog, the installer tokens and
zoom rule (`welcome-kiosk.test.cjs` compares them with
`installer/kiosk/ui/theme.slint` and `installer/kiosk/src/zoom.rs`), and that
every Settings link steps aside first.
`tests/welcome-guide.py --screenshots DIR` runs the real
shell under a private headless Sway from a private git copy of the checkout
with a test-only IPC target. Shortcut state is served by a fake `hyprctl`
(remapped launcher, disabled Close window). It runs through `nix develop` and checks:

- the full-screen canvas at the installer's zoom, centred, on 1440×900,
  1280×800, 1920×1080 and 1024×600 outputs, with no binding-loop warning;
- the fresh-install default wallpaper behind the guide when it steps aside,
  against the bundled image, and that the guide covers it otherwise;
- stepping aside while the launcher is open and resuming after it closes,
  with the shortcut claim released meanwhile;
- Wallhaven as the first source and automatic apply after keyboard
  selection, with a scripted offline listing/download boundary;
- real Matugen generation for the default and selected images, light/dark
  palettes, explicit fixed-colour preservation, and Style → Shortcuts navigation;
- Space typing in Wallhaven search without a request;
- the Space peek, by comparing a frame taken while Space is held (past the
  key-repeat delay) with a desktop-only frame;
- a sheet over the guide, which Escape closes without dismissing the guide;
- Ctrl+PageUp / Ctrl+PageDown, Escape from the wallpaper grid, and the claim
  release;
- Connect: Hello continues to it; 1Password opens from its desktop entry, the
  guide steps aside and returns only when that window closes; the assistant's
  own login command runs in a terminal against the real `cybexos-assistant`
  service with a scripted Claude Code, and the guide returns by itself once
  the service reports the sign-in;
- Ready's system-check card from a fixture `cybex doctor` report, and
  **Ask the assistant** sending the system-check question to the service;
- a tour of every step, sheet (including the question about unapplied
  shortcut changes) and the resume pill in English and Dutch at
  1440×900 and 1024×600, saved as `tour-<language>-<size>-<name>.png`.

`tests/shortcut-editor.py` drives the Shortcuts step's recorder: the
keyboard-shortcut inhibitor, conflicts, and the guide's own keys working at
once after the recorder closes by Escape or by accepting a key. With a change
waiting, it checks that leaving the step asks first, lists the change and
focuses Apply; that Escape keeps the draft on the step; that Discard
restores the keys and goes on; and that Enter twice applies the change
through the real resolver and opens Ready.

It draws with the installed desktop's fonts (`tests/shell_fonts.py`), so the
screenshots match an installation rather than the host's font fallback.

With wtype 0.5, `-P KEY` presses and `-p KEY` releases a key, and an unknown
flag makes it exit before typing anything. Keep a press and its release in one
wtype process, and check its exit status. This is not Hyprland runtime,
installation or physical hardware qualification.
