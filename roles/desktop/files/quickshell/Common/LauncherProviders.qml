pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import "LauncherProviders.js" as ProviderHelpers

// All command-palette data and side effects live here. LauncherView only
// renders normalized rows, so adding a provider no longer expands the view's
// input, result and activation branches independently.
Singleton {
    id: root

    property string query: ""
    property string selectedProviderId: "apps"
    readonly property int maxResults: 8
    readonly property var providers: ProviderHelpers.PROVIDERS
    readonly property var tabProviders: ProviderHelpers.TAB_IDS.map(id =>
        ProviderHelpers.providerById(id))
    readonly property var prefixedProvider:
        ProviderHelpers.prefixedProviderFor(query)
    readonly property bool prefixActive: prefixedProvider !== null
    readonly property var activeProvider: prefixActive ? prefixedProvider
        : ProviderHelpers.providerById(selectedProviderId)
    readonly property string activeProviderId: activeProvider.id
    readonly property string mode: prefixActive ? activeProvider.prefix : ""
    readonly property string term: prefixActive
        ? ProviderHelpers.termFor(query, activeProvider) : query.trim()

    property var fileResults: []
    property bool fileLoading: false
    property string fileError: ""
    property string calcResult: ""
    property bool calcLoading: false
    property string calcError: ""

    property var clipboardEntries: []
    property bool clipboardLoading: false
    property string clipboardError: ""
    property int clipboardRefreshGeneration: 0
    property var emojiEntries: []
    property bool emojiLoading: true
    // emoji-test.txt is ~600 KB parsed on the UI thread; nothing reads it
    // until the Emoji provider is first shown.
    property bool emojiRequested: false
    property string emojiError: ""
    property bool pastePending: false
    property var userActions: []
    property string actionsError: ""

    readonly property var appRows: {
        if (root.activeProviderId !== "apps")
            return [];
        return DesktopEntries.applications.values
            .filter(app => !app.noDisplay)
            .map(app => ({
                providerId: "apps",
                kind: "app",
                title: app.name || "Application",
                subtitle: app.genericName && app.genericName !== app.name
                    ? app.genericName : (app.comment || "Application"),
                glyph: root.activeProvider.glyph,
                icon: app.icon || "",
                app: app,
                score: ProviderHelpers.appScore(app, root.term,
                    Launcher.usageBoost(app))
            }))
            .filter(row => row.score >= 0)
            .sort((a, b) => b.score - a.score
                || a.title.localeCompare(b.title));
    }

    readonly property var windowRows: {
        if (root.activeProviderId !== "windows")
            return [];
        return Hyprland.toplevels.values.map(win => {
            const ipc = win.lastIpcObject || {};
            const windowClass = ipc.class || ipc.initialClass || "Hyprland window";
            return {
                providerId: "windows",
                kind: "window",
                title: win.title || "Untitled window",
                subtitle: windowClass,
                glyph: root.activeProvider.glyph,
                win: win,
                score: ProviderHelpers.windowScore(win.title, windowClass,
                    root.term, win.activated)
            };
        }).filter(row => row.score >= 0)
            .sort((a, b) => b.score - a.score
                || a.title.localeCompare(b.title))
            .slice(0, root.maxResults);
    }

    readonly property var actions:
        ProviderHelpers.BUILTIN_ACTIONS.concat(userActions)

    readonly property var rows: {
        switch (root.activeProviderId) {
        case "files":
            return root.fileResults.slice(0, root.maxResults).map(path => ({
                providerId: "files",
                kind: "file",
                title: path.split("/").pop(),
                subtitle: path,
                glyph: root.activeProvider.glyph,
                path: path
            }));
        case "command":
            return root.term === "" ? [] : [{
                providerId: "command",
                kind: "command",
                title: "Run " + root.term,
                subtitle: "Explicit shell command",
                glyph: root.activeProvider.glyph,
                command: root.term
            }];
        case "calculator":
            return root.calcResult === "" ? [] : [{
                providerId: "calculator",
                kind: "calc",
                title: root.calcResult,
                subtitle: "Press Enter to copy result",
                glyph: root.activeProvider.glyph,
                value: root.calcResult,
                highlight: false
            }];
        case "web":
            return root.term === "" ? [] : [{
                providerId: "web",
                kind: "web",
                title: "Search DuckDuckGo for “" + root.term + "”",
                subtitle: "duckduckgo.com",
                glyph: root.activeProvider.glyph,
                value: root.term
            }];
        case "windows":
            return root.windowRows;
        case "clipboard":
            return ProviderHelpers.clipboardRows(root.clipboardEntries,
                root.term, root.maxResults);
        case "emoji":
            return ProviderHelpers.emojiRows(root.emojiEntries,
                root.term, root.maxResults);
        case "actions":
            return ProviderHelpers.actionRows(root.actions,
                root.term, root.maxResults);
        default:
            return root.appRows;
        }
    }

    readonly property bool busy: activeProviderId === "files" ? fileLoading
        : activeProviderId === "calculator" ? calcLoading
        : activeProviderId === "clipboard" ? clipboardLoading
        : activeProviderId === "emoji" ? emojiLoading : false

    readonly property string error: activeProviderId === "files" ? fileError
        : activeProviderId === "calculator" ? calcError
        : activeProviderId === "clipboard" ? clipboardError
        : activeProviderId === "emoji" ? emojiError
        : activeProviderId === "actions" ? actionsError : ""

    readonly property string emptyText: {
        if (root.activeProviderId === "files" && root.term.length < 2)
            return "Type at least two characters to search files";
        if (root.busy)
            return "Searching…";
        if (root.error !== "")
            return root.error;
        if (root.activeProviderId === "command")
            return "Enter a shell command";
        if (root.activeProviderId === "web")
            return "Enter a web query";
        if (root.activeProviderId === "clipboard")
            return "Clipboard history is empty";
        if (root.activeProviderId === "emoji")
            return "No matching emoji";
        if (root.activeProviderId === "actions")
            return "No matching actions";
        return "No matching results";
    }

    onQueryChanged: {
        root.fileError = "";
        root.calcError = "";
        if (root.activeProviderId === "files" && root.term.length >= 2) {
            root.fileResults = [];
            root.fileLoading = true;
            fileDebounce.restart();
        } else {
            fileDebounce.stop();
            root.fileLoading = false;
            root.fileResults = [];
        }
        if (root.activeProviderId === "calculator" && root.term !== "") {
            root.calcResult = "";
            root.calcLoading = true;
            calcDebounce.restart();
        } else {
            calcDebounce.stop();
            root.calcLoading = false;
            root.calcResult = "";
        }
    }

    onActiveProviderIdChanged: {
        if (root.activeProviderId === "clipboard")
            root.refreshClipboard();
        else if (root.activeProviderId === "emoji" && !root.emojiRequested) {
            // Whatever the pathless FileView reported before this is moot.
            root.emojiLoading = true;
            root.emojiError = "";
            root.emojiRequested = true;
        }
    }

    function activate(row): void {
        if (!row)
            return;
        switch (row.providerId) {
        case "apps":
            Launcher.recordLaunch(row.app);
            row.app.execute();
            Launcher.close();
            break;
        case "files":
            Quickshell.execDetached(["xdg-open", row.path]);
            Launcher.close();
            break;
        case "command":
            Launcher.executeCommand(row.command);
            break;
        case "calculator":
            Quickshell.clipboardText = row.value;
            Launcher.close();
            break;
        case "web":
            Quickshell.execDetached(["xdg-open",
                "https://duckduckgo.com/?q=" + encodeURIComponent(row.value)]);
            Launcher.close();
            break;
        case "windows":
            // Hyprland reads a dispatch as Lua, and its address selector
            // matches the 0x-prefixed form that Quickshell's hex address
            // leaves out.
            Hyprland.dispatch('hl.dsp.focus({ window = "address:0x'
                + row.win.address + '" })');
            Launcher.close();
            break;
        case "clipboard":
            root.copyClipboardEntry(row.raw);
            Launcher.close();
            break;
        case "emoji":
            root.pasteText(row.value);
            break;
        case "actions":
            root.runAction(row.action);
            break;
        }
    }

    function canRemove(row): bool {
        return !!row && row.providerId === "clipboard";
    }

    function remove(row): void {
        if (!root.canRemove(row) || clipboardDeleteProc.running)
            return;
        clipboardDeleteProc.command = ["sh", "-c",
            "printf '%s' " + root.shellQuote(row.raw) + " | cliphist delete"];
        clipboardDeleteProc.running = true;
    }

    function runAction(action): void {
        if (!action)
            return;
        Launcher.close();
        if (action.user && Array.isArray(action.command)
                && action.command.length > 0) {
            Quickshell.execDetached(action.command);
            return;
        }
        switch (action.id) {
        case "settings":
            Qt.callLater(() => Settings.showPanel("appearance"));
            break;
        case "wallpaper-shuffle":
            Wallpaper.shuffle();
            break;
        case "dnd-toggle":
            Notifs.setDnd(!Notifs.dnd);
            break;
        case "lock":
            Session.lock();
            break;
        case "power":
            Qt.callLater(() => Popouts.toggle("control", undefined, undefined,
                Screens.focused ? Screens.focused.name : ""));
            break;
        }
    }

    function shellQuote(value): string {
        return "'" + String(value || "").replace(/'/g, "'\"'\"'") + "'";
    }

    function copyClipboardEntry(raw): void {
        Quickshell.execDetached(["sh", "-c", "printf '%s' "
            + root.shellQuote(raw) + " | cliphist decode | wl-copy"]);
    }

    function pasteText(value): void {
        const text = String(value || "");
        if (text === "")
            return;
        Quickshell.clipboardText = text;
        root.pastePending = true;
        Launcher.close();
        pasteTimer.restart();
    }

    function refreshClipboard(): void {
        clipboardRefreshGeneration++;
        root.clipboardError = "";
        root.clipboardLoading = true;
        if (clipboardListProc.running)
            return;
        root.startClipboardRefresh();
    }

    function startClipboardRefresh(): void {
        clipboardListProc.generation = clipboardRefreshGeneration;
        clipboardListProc.buffer = [];
        clipboardListProc.errText = "";
        clipboardListProc.running = true;
    }

    Timer {
        id: fileDebounce
        interval: 180
        onTriggered: {
            fileProc.running = false;
            fileProc.command = ["fd", "--absolute-path", "--color", "never",
                "--hidden", "--fixed-strings", "--max-results",
                String(root.maxResults), "--exclude", ".cache", "--exclude",
                ".git", "--", root.term, Quickshell.env("HOME")];
            fileProc.running = true;
        }
    }

    Process {
        id: fileProc
        property string request: ""
        onRunningChanged: {
            if (running)
                request = root.term;
        }
        stdout: StdioCollector {
            onStreamFinished: {
                if (fileProc.request === root.term
                        && root.activeProviderId === "files")
                    root.fileResults = text.trim() === "" ? []
                        : text.trim().split("\n").slice(0, root.maxResults);
            }
        }
        stderr: StdioCollector {
            onStreamFinished: {
                if (fileProc.request === root.term
                        && root.activeProviderId === "files")
                    root.fileError = text.trim();
            }
        }
        onExited: (exitCode, exitStatus) => {
            if (request === root.term && root.activeProviderId === "files") {
                root.fileLoading = false;
                if (exitCode !== 0 && root.fileError === "")
                    root.fileError = `File search exited with status ${exitCode}`;
            }
        }
    }

    Timer {
        id: calcDebounce
        interval: 120
        onTriggered: {
            calcProc.running = false;
            calcProc.command = ["qalc", "-t", root.term];
            calcProc.running = true;
        }
    }

    // Let the launcher release its exclusive keyboard focus before asking the
    // compositor to paste into the window that was active before it opened.
    Timer {
        id: pasteTimer
        interval: Theme.launcherFadeOutDuration + 40
        onTriggered: {
            if (root.pastePending && !Launcher.open)
                Quickshell.execDetached([
                    "wtype", "-M", "shift", "-k", "Insert", "-m", "shift"
                ]);
            root.pastePending = false;
        }
    }

    Process {
        id: calcProc
        property string request: ""
        onRunningChanged: {
            if (running)
                request = root.term;
        }
        stdout: StdioCollector {
            onStreamFinished: {
                if (calcProc.request === root.term
                        && root.activeProviderId === "calculator")
                    root.calcResult = text.trim().split("\n").pop() || "";
            }
        }
        stderr: StdioCollector {
            onStreamFinished: {
                if (calcProc.request === root.term
                        && root.activeProviderId === "calculator")
                    root.calcError = text.trim();
            }
        }
        onExited: (exitCode, exitStatus) => {
            if (request === root.term
                    && root.activeProviderId === "calculator") {
                root.calcLoading = false;
                if (exitCode !== 0 && root.calcError === "")
                    root.calcError = `Calculator exited with status ${exitCode}`;
            }
        }
    }

    Process {
        id: clipboardListProc
        property int generation: -1
        property var buffer: []
        property string errText: ""
        command: ["sh", "-c", "command -v cliphist >/dev/null 2>&1"
            + " || exit 127; exec cliphist list"]
        stdout: SplitParser {
            onRead: line => clipboardListProc.buffer.push(line)
        }
        stderr: StdioCollector {
            onStreamFinished: clipboardListProc.errText = text.trim()
        }
        onExited: (exitCode, exitStatus) => {
            if (generation !== root.clipboardRefreshGeneration) {
                clipboardRefreshRestart.restart();
                return;
            }
            root.clipboardLoading = false;
            if (exitCode === 0) {
                root.clipboardEntries = clipboardListProc.buffer.slice();
                root.clipboardError = "";
            } else if (exitCode === 127) {
                root.clipboardEntries = [];
                root.clipboardError = "cliphist is not installed";
            } else {
                root.clipboardError = clipboardListProc.errText !== ""
                    ? clipboardListProc.errText
                    : `Clipboard history exited with status ${exitCode}`;
            }
        }
    }

    Timer {
        id: clipboardRefreshRestart
        interval: 0
        onTriggered: {
            if (!clipboardListProc.running)
                root.startClipboardRefresh();
            else
                restart();
        }
    }

    Process {
        id: clipboardDeleteProc
        onExited: (exitCode, exitStatus) => root.refreshClipboard()
    }

    // The two MIME-specific watchers make clipboard history useful for both
    // text and images. Process lifetime follows Quickshell, preventing stale
    // duplicate watchers after a shell restart. A watcher that dies (the
    // compositor restarted, wl-paste crashed) is restarted on the falling
    // edge of `running` — the only signal a failed launch sends — with a
    // backoff that resets once a run has lasted a minute.
    component ClipboardWatcher: Process {
        id: watcher

        // The wl-paste invocation this watcher keeps alive.
        required property string watch
        property double startedAt: 0
        property int failures: 0
        readonly property Timer restartTimer: Timer {
            onTriggered: watcher.running = true
        }

        command: ["sh", "-c", "command -v cliphist >/dev/null 2>&1"
            + " && command -v wl-paste >/dev/null 2>&1"
            + " || exec sleep infinity;"
            + " exec " + watch]
        running: true
        onRunningChanged: {
            if (running) {
                startedAt = Date.now();
                return;
            }
            if (Date.now() - startedAt >= 60000)
                failures = 0;
            restartTimer.interval = ProviderHelpers.watcherRestartDelayMs(failures);
            failures++;
            restartTimer.restart();
        }
    }

    ClipboardWatcher {
        watch: "wl-paste --type text --watch "
            + Quickshell.env("HOME") + "/.local/bin/clipboard-history-store"
    }

    ClipboardWatcher {
        watch: "wl-paste --type image --watch "
            + Quickshell.env("HOME") + "/.local/bin/clipboard-history-store"
    }

    Connections {
        target: Quickshell
        function onClipboardTextChanged() {
            if (root.activeProviderId === "clipboard")
                clipboardRefreshDelay.restart();
        }
    }

    Timer {
        id: clipboardRefreshDelay
        interval: 100
        onTriggered: root.refreshClipboard()
    }

    FileView {
        id: emojiFile
        path: root.emojiRequested ? "/usr/share/unicode/emoji/emoji-test.txt" : ""
        printErrors: false
        onLoaded: {
            root.emojiEntries = ProviderHelpers.parseEmojiData(text());
            root.emojiLoading = false;
            root.emojiError = root.emojiEntries.length > 0
                ? "" : "Unicode emoji data is empty";
        }
        onLoadFailed: {
            root.emojiEntries = [];
            root.emojiLoading = false;
            root.emojiError = "Unicode emoji data is unavailable";
        }
    }

    FileView {
        id: actionsFile
        path: Quickshell.shellDir + "/launcher-actions.json"
        printErrors: false
        watchChanges: true
        onFileChanged: reload()
        onLoaded: {
            const parsed = ProviderHelpers.parseActions(text());
            root.userActions = parsed.actions;
            root.actionsError = parsed.error;
        }
        onLoadFailed: {
            root.userActions = [];
            root.actionsError = "launcher-actions.json could not be read";
        }
    }
}
