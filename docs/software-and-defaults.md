# Software and application defaults

Open **Software** from the application launcher or **Settings → Applications**.
Search uses Nix, the installed machine's locked Nixpkgs and its personal overlays.
The first search indexes package metadata locally; subsequent searches use a
cache that is invalidated when the machine configuration changes. Discovery
neither refreshes inputs nor creates a second package universe.

Select packages, choose **Build preview**, then **Review deployment…**. Review
the built closure diff and choose **Apply reviewed change**. This is the same
serialized, checked deployment, trial boot, confirmation and rollback path as
system updates. Authentication starts a supervised worker; closing Software
does not cancel its build. Errors and worker exits settle the request visibly.
A selection changed elsewhere requires refreshing before another preview.

The fresh machine template imports `local/software.nix` and stores selections
in `/etc/nixos/local/software.json`. Software edits only that declaration in a
staged copy. Packages managed in another personal or vendor module are labelled
as such. Removing a Software selection never removes another module's package
declaration. The Installed list covers declarative system packages; personal
Nix profiles and Flatpak applications retain their own ownership and tools.
No migration or alternate installation/update path is provided.

**Settings → Applications** also selects a browser, terminal, text editor,
PDF viewer, image viewer and video player. These per-account preferences apply
immediately, using GIO's standard MIME associations and `xdg-terminal-exec`'s
standard terminal preference list. System defaults are fallbacks; unrelated
personal associations remain intact. A missing saved choice is retained and
shown as unavailable, while an available application handles launches. An
explicit association changed outside Settings takes precedence.

NerdOS browser/terminal shortcuts, agent windows, maintenance and firmware
terminals, web apps, and dock suggestions use the same defaults. Chromium-based
selected browsers can open web apps in app mode; other browsers open their URL
normally. Private browsing uses the selected browser's advertised desktop action;
unsupported private actions produce a notification. Explicit `VISUAL`/`EDITOR`
values and personal shortcuts retain their precedence. Arguments are passed as
argv, including filenames and URLs containing spaces; they are not shell code.

The `nerdos-apps` helper offers `status`, `set ROLE DESKTOP_ID`, `browser`,
`browser --private`, `webapp URL`, `terminal [OPTIONS] [-- COMMAND ARGS…]`, and
`edit FILE…`. `nerd software list`, `search QUERY`, `stage JSON` and `request ID`
expose the native package workflow for scripting.
