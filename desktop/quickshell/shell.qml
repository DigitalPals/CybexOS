import QtQuick
import QtQuick.Window
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import "Bar"
import "Common"
import "Common/DockHelpers.js" as DockHelpers

// The static linter cannot resolve Quickshell's private PostReloadHook base from the
// installed qmltypes. The shell does not instantiate it; importing Quickshell
// nevertheless makes the tool inspect that private base.
// qmllint disable import

ShellRoot {
    id: shell

    WelcomeWindow {}
    IpcHandler {
        target: "welcome"
        function open(step: string): string { return Welcome.show(step); }
        function close(): void { Welcome.dismiss(); }
        function status(): string { return Welcome.status(); }
        function reset(): void { Welcome.reset(); }
    }

    SettingsWindow {}
    SoftwareWindow {}
    SoftwareUpdateWindow {}

    IpcHandler {
        target: "software"
        function open(): void { Software.show(); }
        function close(): void { Software.close(); }
    }

    // Hyprland dispatches this in-process. Super+Space no longer waits for a
    // new `qs ipc` client process to start and connect before opening.
    GlobalShortcut {
        appid: "quickshell"
        name: "launcherToggle"
        description: I18n.tr("Toggle the application launcher")
        onPressed: Launcher.toggle()
    }

    // Super+Tab, in-process like the launcher. The `overview` IPC target in
    // OverviewWindow serves the touchpad gesture and scripts.
    GlobalShortcut {
        appid: "quickshell"
        name: "overviewToggle"
        description: I18n.tr("Toggle the window overview")
        onPressed: Overview.toggle()
    }

    // Super+I, in-process so a held key reports its release: a tap opens the
    // assistant's box, holding it records a question that is sent on
    // release (docs/assistant.md).
    GlobalShortcut {
        appid: "quickshell"
        name: "assistantTalk"
        description: I18n.tr("Ask the Cybex OS Assistant; hold to talk")
        onPressed: Assistant.shortcutPressed()
        onReleased: Assistant.shortcutReleased()
    }

    // `cybex assistant show|hide|toggle|ask` and scripts.
    IpcHandler {
        target: "assistant"

        function show(): void {
            Assistant.show(Screens.focused ? Screens.focused.name : "");
        }

        function hide(): void {
            Assistant.hide();
        }

        function toggle(): void {
            Assistant.toggleShown(Screens.focused ? Screens.focused.name : "");
        }

        // Opens the box with the keyboard, as a tap of Super+I does.
        function compose(): void {
            Assistant.openComposer(true);
        }

        function ask(text: string): void {
            Assistant.openComposer(false);
            Assistant.send(text);
        }

        // "Check this computer": the question that starts from `cybex doctor`.
        function check(): void {
            Assistant.checkSystem();
        }

        // Read-only state for diagnostics.
        function status(): string {
            return JSON.stringify({available: Assistant.available, shown: Assistant.shown,
                connected: Assistant.connected, screen: Assistant.screenName,
                agent: Assistant.agent, busy: Assistant.busy,
                agentReady: Assistant.agentReady, setupRequired: Assistant.setupRequired,
                authChecking: Assistant.authChecking, hasDraft: Assistant.draft.trim() !== "",
                x: Settings.assistantX, y: Settings.assistantY, size: Theme.scaled(64),
                turn: Assistant.turn ? Assistant.turn.status : "",
                composing: Assistant.composing, listening: Assistant.listening});
        }
    }

    // Popout IPC lives here rather than in Bar: the bar is instantiated
    // once per output, and an IpcHandler target may only be registered
    // once shell-wide.
    IpcHandler {
        target: "popouts"

        function toggle(name: string): void {
            Popouts.toggle(name, undefined, undefined,
                Screens.focused ? Screens.focused.name : "");
        }

        function open(name: string): void {
            Popouts.openPanel(name, undefined, undefined,
                Screens.focused ? Screens.focused.name : "");
        }

        function close(): void {
            Popouts.close();
        }
    }

    // Shell-wide because every output has a bar and an IpcHandler target may
    // only be registered once. IPC opens on the focused output; pointer opens
    // pass their own output through the bar instead.
    IpcHandler {
        target: "settings"

        function toggle(): void {
            Settings.togglePanel(undefined,
                Screens.focused ? Screens.focused.name : "");
        }

        function open(page: string): void {
            Settings.showPanel(page,
                Screens.focused ? Screens.focused.name : "");
        }

        function close(): void {
            Settings.closePanel();
        }

        // Read-only effective preferences for same-source installation audits.
        function values(): string { return JSON.stringify(Settings.snapshot()); }

        // Read-only lifecycle diagnostics; no device or account metadata.
        function status(): string {
            const services = {};
            for (const name of ["sound", "network", "accounts", "input", "region"]) {
                const service = SystemSettings[name];
                services[name] = {loaded: service.loaded, busy: service.busy,
                    loading: service.loading, watchers: service.watchers,
                    watching: service.watching, failed: service.error !== ""};
            }
            return JSON.stringify({page: Settings.page, open: Settings.panelOpen, services: services});
        }
    }

    // Wallpaper calls for the welcome window: its row of popular Wallhaven
    // images (popular, results, pick), the wallpaper folder as the offline
    // fallback (list, set), and the Settings Online view (browse). The Online
    // singleton is created by the first call, not at startup.
    IpcHandler {
        target: "wallpaper"

        function browse(): void {
            OnlineWallpapers.view = "online";
            Settings.showPanel("wallpaper",
                Screens.focused ? Screens.focused.name : "");
        }

        function list(): string {
            return JSON.stringify({dir: Settings.wallDir, current: Settings.wall,
                files: Wallpaper.files.map(file => Wallpaper.basename(file))});
        }

        function set(name: string): string {
            return Wallpaper.setByName(name) ? "ok" : "unknown";
        }

        // Read-only diagnostics of the Online view's search and download.
        function status(): string {
            return JSON.stringify({view: OnlineWallpapers.view,
                results: OnlineWallpapers.results.length,
                page: OnlineWallpapers.page, lastPage: OnlineWallpapers.lastPage,
                busy: OnlineWallpapers.busy, error: OnlineWallpapers.error,
                downloading: OnlineWallpapers.downloadingId,
                downloadError: OnlineWallpapers.downloadError});
        }
    }

    // The desktop outside the shell (terminal, compositor, GTK, lock screen)
    // follows the shell's appearance on its own; `apply` re-renders and
    // reloads every target even when nothing changed, for an application
    // that missed a reload or a target file edited by hand.
    IpcHandler {
        target: "theme"

        function apply(): void {
            SystemTheme.apply(true);
        }

        function status(): string {
            return SystemTheme.status();
        }

        // `cybex theme apply`: a named theme its helper has validated and
        // resolved (scripts/theme-packs.py), checked again here before it
        // changes anything. Returns "ok" or "error: <reason>".
        function use(theme: string): string {
            return Themes.use(theme);
        }

        // Re-reads the theme folders after `cybex theme install` or `remove`.
        function refresh(): void {
            Themes.refresh();
        }
    }

    // Pinged by brightness-control after brightnessctl runs; volume needs
    // no IPC because the OSD watches Pipewire directly.
    IpcHandler {
        target: "osd"

        function brightness(): void {
            Osd.brightnessChanged();
        }
    }

    // Timer services call this after delivering a reminder so the indicator
    // and an open manager update without waiting for their polling fallback.
    IpcHandler {
        target: "reminders"

        function refresh(): void {
            Reminders.refresh();
        }
    }

    // Shell-wide session routes. The compatibility `power` call now targets
    // the focused output's Control Panel; direct actions keep their names.
    IpcHandler {
        target: "session"

        function power(): void {
            Session.closeKeys();
            Launcher.close();
            Popouts.toggle("control", undefined, undefined,
                Screens.focused ? Screens.focused.name : "");
        }

        function keys(): void {
            Session.toggleKeys();
        }

        function lock(): void {
            Session.lock();
        }

        function close(): void {
            Session.closeAll();
            if (Popouts.open && Popouts.currentName === "control")
                Popouts.close();
        }
    }

    // The launcher's "Check for updates", `cybexos-software-update` and
    // scripts. `check` refreshes every source (a run in progress is left
    // alone); `open` shows Software Update, which refreshes stale discovery.
    IpcHandler {
        target: "updates"

        function check(): void {
            Updates.check(true);
        }

        function open(): void {
            Updates.show();
        }

        function close(): void {
            Updates.close();
        }
    }

    // A configuration reload rebuilds Hyprland's Lua state; runtime choices
    // the compositor cannot read back from a file are sent again.
    Connections {
        target: Hyprland

        function onRawEvent(event) {
            if (event.name === "configreloaded")
                Settings.compositorReloaded();
        }
    }

    // Wallpaper on the background layer, one per output. The model also
    // changes identity when a surviving output moves, forcing the layer
    // surface to remap instead of retaining its old global coordinates.
    Variants {
        model: Screens.layerSurfaceModel

        PanelWindow {
            id: wallpaperWindow

            required property var modelData

            screen: modelData.screen
            anchors {
                top: true
                left: true
                right: true
                bottom: true
            }
            exclusionMode: ExclusionMode.Ignore
            color: "#101116"

            WlrLayershell.layer: WlrLayer.Background
            WlrLayershell.namespace: "qs-wallpaper"

            // The frame signal is emitted after rendering, including the
            // solid fallback when a wallpaper is absent or cannot decode.
            Connections {
                target: wallpaperImage.Window.window
                enabled: !Welcome.wallpaperDrawn
                function onFrameSwapped() {
                    if (wallpaperImage.status !== Image.Loading) Welcome.wallpaperReady();
                }
            }
            Image {
                id: wallpaperImage
                anchors.fill: parent
                source: Wallpaper.current !== "" ? Wallpaper.url(Wallpaper.current) : ""
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                // Keep drawing the outgoing wallpaper until the next one has
                // decoded, instead of flashing the window's fallback colour
                // for the length of every asynchronous load (Qt 6.8+).
                retainWhileLoading: true
                cache: true
                // screen is briefly null while an output is torn down;
                // 0 falls back to the image's own size for that instant.
                sourceSize.width: wallpaperWindow.screen
                    ? Math.ceil(wallpaperWindow.screen.width * wallpaperWindow.screen.devicePixelRatio) : 0
                sourceSize.height: wallpaperWindow.screen
                    ? Math.ceil(wallpaperWindow.screen.height * wallpaperWindow.screen.devicePixelRatio) : 0
            }
        }
    }

    // One permanently mapped bar per output. Binding each window to one
    // output for its lifetime avoids layer-surface migration during focus
    // changes and lets hotplug create or destroy just that output's bar.
    Variants {
        model: OmarchyPlugins.replacementActive ? [] : Screens.layerSurfaceModel

        Scope {
            id: barScope

            required property var modelData
            readonly property ShellScreen output: modelData ? modelData.screen : null
            property string outputName: ""

            Component.onCompleted: outputName = output ? output.name : ""
            Component.onDestruction: {
                if (Popouts.open && Popouts.hostScreenName === outputName)
                    Popouts.close();
            }

            Bar {
                id: bar
                screen: barScope.output
                visible: barScope.output !== null
            }

            BarPopoutWindow {
                bar: bar
                screen: barScope.output
            }
        }
    }

    // Floating workspaces get a dock automatically, independently per output.
    // The saved dock preference additionally shows it in other layouts.
    // With no eligible output, even the shared Dock model stays unconstructed.
    Variants {
        model: Screens.layerSurfaceModel.filter(output => {
            const monitor = Hyprland.monitorFor(output.screen);
            const active = monitor ? monitor.activeWorkspace : null;
            return DockHelpers.showOnWorkspace(Settings.dock, active,
                DesktopWorkspaces.workspace(active ? active.id : 0));
        })

        DockWindow {}
    }

    LauncherWindow {}
    OverviewWindow {}
    NetworkOverlayWindow {}
    NotificationToasts {}
    OsdWindow {}
    ShortcutsOverlay {}
    PolkitWindow {}

    // The webcam bubble exists only for a --webcam recording: the window,
    // the camera and its device list are created when one starts and
    // destroyed, releasing the camera, when it stops.
    LazyLoader {
        active: Recorder.webcamWanted

        WebcamOverlay {}
    }

    // The assistant's character and box exist while it is out; its client
    // singleton keeps the service connection either way.
    LazyLoader {
        active: Assistant.shown

        AssistantWindow {}
    }

    // Reading a singleton's property is what constructs it. Notifications
    // must start collecting, GitHub must start polling — GitHub
    // also raises the toasts for watched repositories, which must not wait
    // for the popover — and settings must load from session start rather than
    // from the first popover open. Constructing them is cheap; the
    // non-critical first fetches stagger themselves behind their own
    // start-up timers (Reminders restore 8 s, Calendar 12 s,
    // Updates 20 s) so a login does not run them all at once.
    Component.onCompleted: {
        void DesktopWorkspaces.ready;
        void OmarchyPlugins.ready;
        void Notifs.server;
        void GitHub.pollEnabled;
        void Calendar.enabled;
        void Settings.loaded;
        void SystemTheme.settled;
        void Updates.hasUpdates;
        void Recorder.active;
        void Dictation.state;
        void Assistant.available;
        void Reminders.count;
        // A recovery boot must announce itself without waiting for Settings.
        void Recovery.recoveryBoot;
    }
}
