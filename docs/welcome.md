# Welcome to Cybex OS

The welcome guide opens on your focused display after your first desktop login.
It shows your installed language, keyboard layout and time zone, then helps you
choose a wallpaper, appearance and a few useful shortcuts. Changes apply to the
real desktop immediately. Hold Space on the wallpaper step to peek behind the
guide; release it to return.

Use Tab and Enter to operate controls, and Ctrl+PageUp / Ctrl+PageDown to move
between steps. Every step is optional. Escape, the close button and **Skip for
now** keep your progress and dismiss the guide. It will not reopen automatically.
**Finish** marks it complete. Open the launcher and search for **Welcome** to
return, or use **Settings → About → Welcome guide**. A completed guide starts
again at Hello when opened manually.

Practice ticks come from what the shell observes: opening the launcher, opening
and closing a new window, switching away from your starting workspace and back,
opening the overview, and opening the shortcut sheet. The guide follows you
between workspaces during practice. On another compositor the live shortcuts
may be unavailable; you can still continue.

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
cybexos-runtime ipc welcome status          # JSON: open/status/step/practice/checklist
cybexos-runtime ipc welcome close           # dismiss, preserving progress
cybexos-runtime ipc welcome reset           # delete only welcome.json
```

For implementation and integration interfaces, see the
[shared contract](architecture/welcome-and-shortcuts.md). The temporary wallpaper
step uses the existing Settings gallery, and the shortcut step uses live
shortcut rows until the reusable picker and keyboard map are integrated.
