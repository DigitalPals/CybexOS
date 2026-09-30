# CybexOS in your browser

An interactive recreation of the CybexOS desktop: the Quickshell-inspired
menubar, workspaces, application launcher, Hyprland-style tiling, control drawer,
terminal, sample files, Omawrite notes, and appearance settings. The default
mountain wallpaper and Cybex wordmark come from the native desktop.

This is a browser simulation. It does not boot Linux, connect to your desktop,
install applications, execute shell commands, or change the host's settings.
System readings, networks, and notifications are demonstration data. The clock
uses your browser's local time. The installed OS is documented in the
[repository README](../README.md).

## Run locally

Use Node.js 24 LTS and npm. From this directory:

```bash
npm ci
npm run dev -- --hostname 0.0.0.0 --port 5174
```

Open <http://localhost:5174>. For a production build:

```bash
npm run build
npm start -- --hostname 0.0.0.0 --port 5174
```

The application uses React, TypeScript, and vinext. The Vite build keeps the
Sites-compatible Worker entry at `dist/server/index.js` and browser assets in
`dist/client/`. `vinext start` serves that build through its Node production
server. There is no database, API credential, or environment file to configure.

## Run with Docker Compose

From this directory:

```bash
docker compose up --build -d --wait
docker compose ps
```

The service listens on port 5174 of the host by default. Open
`http://<host>:5174` from another device, or <http://localhost:5174> on the host.
The image builds the app, runs as the unprivileged `node` user, and checks the
production page for readiness. Source files and the host filesystem are not
mounted into the container.

Set `CYBEXOS_WEB_PORT` to choose another host port. Set `CYBEXOS_WEB_HOST` to
choose the host interface; for example, to serve only on loopback:

```bash
CYBEXOS_WEB_HOST=127.0.0.1 CYBEXOS_WEB_PORT=5175 docker compose up --build -d --wait
```

After changing the application on `thebeast`, rebuild and restart this service
with `docker compose up --build -d --wait` before handing it over. Inspect logs
with `docker compose logs --tail=100 web`, and stop it with `docker compose down`.
Notes and preferences live in visitors' browsers, so no container data volume
is required. For an Internet-facing deployment, serve this app through the
host's HTTPS reverse proxy or use the Sites build.

## Explore the desktop

Click the launcher to open applications, the workspace numbers to switch
desktops, the clock to open the day sheet, or the status icons to open the
control drawer. Settings changes apply to this browser desktop.

Windows tile by default in a dwindle-inspired layout with 10 px gaps. A single
window is centered on wide screens; opening another divides the available
space. Drag a tile's title onto another tile to swap them. Floating windows
move freely. Use the floating control before dragging a corner to resize.
Window controls close, minimize, maximize, or toggle floating. Double-clicking
a title also maximizes or restores the window.

Drag the main divider or open **Tiling layout** in the footer to adjust the
workspace split. The panel also shows shortcut hints and links to the full
keyboard guide. Moving a window leaves the current workspace selected. Narrow
screens use a vertical stack with no overlapping tiles.

| Shortcut | Action |
| --- | --- |
| Alt + Space | Open the app launcher |
| Alt + 1–5 | Switch workspace |
| Alt + Shift + 1–5 | Move focused window to workspace without following |
| Alt + Enter | Open the terminal |
| Alt + K | Open keyboard shortcuts |
| Alt + arrows | Focus a neighboring tile |
| Alt + Shift + arrows | Swap neighboring tiles |
| Alt + V | Toggle floating / tiling |
| Alt + F | Maximize / restore |
| Escape | Close the launcher or open panel |
| Tab in the terminal | Complete commands and sample paths |
| Up / Down in the terminal | Browse history and return to the current draft |
| Ctrl + C in the terminal | Cancel the current command |
| Ctrl + L in the terminal | Clear terminal output |
| Ctrl + U in the terminal | Clear the command line |

Native Hyprland uses Super-based shortcuts. This browser preview adapts them
to Alt; some browsers or operating systems reserve these combinations.
Clickable controls are also available.

## Terminal and Fedora overview

The Kitty-inspired terminal has a Fish-style prompt and a small, fixed command
set against an in-memory sample filesystem. `fastfetch` and `neofetch` show a
blue Fedora ASCII logo beside Fedora Linux 44, Hyprland on Wayland, Quickshell,
Kitty, and sample kernel, CPU, GPU, package, memory, and disk information. The
overview identifies its data as simulated and adapts to narrow tiled windows.
No hardware, installed packages, or kernel information is read from the host.

Try `help`, `ls`, `cd Documents`, `cat Shortcuts.txt`, or `cybex settings`.
`hostname`, `uptime`, `uname -a`, `free -h`, and `df -h` report the same sample
workstation. Tab completes commands, desktop app names, and virtual paths,
including quoted filenames with spaces. History preserves an unfinished draft;
`history` lists submitted commands. Ctrl+C cancels a draft without running it.

The terminal never passes input to a real shell. Shell operators, substitutions,
and variables remain literal text; commands cannot run programs, install
packages, access the host filesystem, or make network requests.

## Model Usage and CLIProxyAPI demo

Click the Codex or Claude mark in the menubar, choose **Model Usage** from the
launcher, use the welcome window's subscription shortcut, or run `cybex usage`
in the simulated terminal. Each provider has three fictional subscriptions:
Codex Pro 20×, Pro 5× and Plus; Claude Max 20×, Max 5× and Pro.

The **Limits** view shows individual weekly and five-hour quotas, reset
countdowns, last-used indicators, pause/resume controls, and account email
visibility. Bar percentages use the last-used account's lowest remaining
quota, matching the native widget. They do not average or add account quotas.

**Send demo request** consumes a small amount of quota and records an activity
entry. **Auto** generates a request every five seconds while the panel is open;
closing the panel, pausing Auto, or entering Proxy settings stops the traffic.
The **Activity** view shows account routing, request counts, tokens and sample
latency. All values are illustrative, not provider limits or billing estimates.

The **Proxy** view presents CLIProxyAPI's local endpoint and lets visitors try
round-robin or fill-first routing. Paused and exhausted accounts are skipped.
Refresh preserves usage unless a quota window has elapsed. Reset restores the
six sample subscriptions after confirmation, without touching notes or desktop
preferences. Usage simulation state lasts for the page session; reloading starts
a new sample session. It is not persisted or uploaded.

The endpoint is display-only. There are no real proxy connections, credentials,
OAuth sessions, provider API calls or paid subscriptions. Demo identities use
reserved `example.com` addresses. Only the web app and its local assets are
requested by the browser.

## Browser storage

Appearance preferences use the localStorage key `cybexos-web-preferences-v1`.
Omawrite saves notes under `cybexos-demo-notes-v1` and offers a Markdown download.
These values are local to this browser profile and site origin; they are not
uploaded or synchronized. Changing the hostname, scheme, or port opens a
different storage area. Clearing site data removes the saved values, and
private browsing may discard them when the session closes.

## Checks and source references

```bash
npm run lint
npm run typecheck
npm test
npm run build
npm run test:render
```

The [web workflow](../.github/workflows/web.yml) runs these checks and a
production HTTP smoke test for changes in `web/`. Native desktop checks remain
separate. Layout and interaction coverage includes nonoverlapping tiles,
floating and minimized reflow, stable editor focus, swaps, workspace moves,
main split controls, narrow-screen stacking, and Fedora terminal completion.
Key native references are
[`Common/Theme.qml`](../roles/desktop/files/quickshell/Common/Theme.qml),
[`Common/SettingsHelpers.js`](../roles/desktop/files/quickshell/Common/SettingsHelpers.js),
[Hyprland layout settings](../roles/desktop/templates/looknfeel.lua.j2),
and the [welcome window](../image/rootfs/usr/share/cybexos/welcome/Main.qml).
Asset sources and license information are recorded in
[ASSETS.md](ASSETS.md).

## Validation and current deployment

Validated on 2026-09-30: lint, TypeScript, 106 interaction/state tests, two
production Worker/asset tests, and the production build pass. The npm audit
reports no known vulnerabilities for the locked dependencies. Production HTTP
checks verified the page, its script/style/font assets, the provider marks,
and the original wallpaper checksum. Browser visual testing was not performed.

The task's Docker Compose service is running on `thebeast` at
<http://10.10.0.7:5174> (network/VPN access required). Sites publishing was
unavailable because this session had no callable Sites connector; no public
Internet domain has been configured. The source and Worker build remain ready
for either deployment path.

The only retained runtime artifact is `cybexos-web-web:latest` (approximately
765 MiB reported image size), used by the healthy `cybexos-web-web-1` service.
Local compiled output, temporary logs, and dependencies were removed after
validation, and the task development process was stopped. The superseded task
image is no longer present. Run `npm ci` before local
development to recreate the dependencies.
