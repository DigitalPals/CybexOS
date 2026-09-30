# CybexOS in your browser

An interactive recreation of the CybexOS desktop: the Quickshell-inspired
menubar, workspaces, application launcher, movable windows, control drawer,
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
control drawer. Drag a window by its title bar; its controls close, minimize,
and maximize it. Settings changes apply to this browser desktop.

| Shortcut | Action |
| --- | --- |
| Alt + Space | Open the app launcher |
| Alt + 1–5 | Switch workspace |
| Alt + Enter | Open the terminal |
| Alt + K | Open keyboard shortcuts |
| Escape | Close the launcher or open panel |
| Up / Down in the terminal | Browse command history |
| Ctrl + L in the terminal | Clear terminal output |

The native desktop uses Super-based shortcuts. The web version uses Alt, but
some browsers or operating systems reserve these combinations. The same
actions remain available through clickable controls.

The terminal interprets a small, fixed command set against an in-memory sample
filesystem. Try `help`, `fastfetch`, `ls`, `cd Documents`, `cat Shortcuts.txt`,
or `cybex settings`. It never passes input to a real shell.

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
separate. Key native references are
[`Common/Theme.qml`](../roles/desktop/files/quickshell/Common/Theme.qml),
[`Common/SettingsHelpers.js`](../roles/desktop/files/quickshell/Common/SettingsHelpers.js),
and the [welcome window](../image/rootfs/usr/share/cybexos/welcome/Main.qml).
Asset sources and license information are recorded in
[ASSETS.md](ASSETS.md).

## Validation and current deployment

Validated on 2026-09-30: lint, TypeScript, 36 interaction/state tests, two
production Worker/asset tests, and the production build pass. The npm audit
reports no known vulnerabilities for the locked dependencies. Production HTTP
checks verified the page, its script/style/font assets, and the original
wallpaper checksum. Browser visual testing was not performed.

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
