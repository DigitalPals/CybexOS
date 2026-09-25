import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import "Bar"
import "Common"

// The static linter cannot resolve Quickshell's private PostReloadHook base from the
// installed qmltypes. The shell does not instantiate it; importing Quickshell
// nevertheless makes the tool inspect that private base.
// qmllint disable import

ShellRoot {
    id: shell

    SettingsWindow {}

    // Hyprland dispatches this in-process. Super+Space no longer waits for a
    // new `qs ipc` client process to start and connect before opening.
    GlobalShortcut {
        appid: "quickshell"
        name: "launcherToggle"
        description: "Toggle the application launcher"
        onPressed: Launcher.toggle()
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

        // Read-only lifecycle diagnostics; no device or account metadata.
        function status(): string {
            const services = {};
            for (const name of ["sound", "network", "accounts"]) {
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

        // Starts the default Popular listing unless it is already loaded.
        function popular(): void {
            OnlineWallpapers.showPopular();
        }

        function results(): string {
            return JSON.stringify(OnlineWallpapers.state());
        }

        // Downloads (if needed) and applies a listed result.
        function pick(id: string): string {
            return OnlineWallpapers.pick(id) ? "ok" : "unknown";
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

            Image {
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

    LauncherWindow {}
    NetworkOverlayWindow {}
    NotificationToasts {}
    OsdWindow {}
    ShortcutsOverlay {}

    // Reading a singleton's property is what constructs it. Notifications
    // must start collecting, GitHub must start polling — GitHub
    // also raises the toasts for watched repositories, which must not wait
    // for the popover — and settings must load from session start rather than
    // from the first popover open. Constructing them is cheap; the
    // non-critical first fetches stagger themselves behind their own
    // start-up timers (Reminders restore 8 s, Calendar 12 s,
    // Updates 20 s) so a login does not run them all at once.
    Component.onCompleted: {
        void OmarchyPlugins.ready;
        void Notifs.server;
        void GitHub.pollEnabled;
        void Calendar.enabled;
        void Settings.loaded;
        void SystemTheme.settled;
        void Updates.total;
        void Recorder.active;
        void Dictation.state;
        void Reminders.count;
        // A recovery boot must announce itself without waiting for Settings.
        void Recovery.recoveryBoot;
    }
}
