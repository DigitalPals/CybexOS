pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import "LauncherProviders.js" as ProviderHelpers
import "ProcHelpers.js" as ProcHelpers
import "WindowCommands.js" as WindowCommands

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

    // Argument mode: an action that needs one value (a web address, a Git
    // repository, which web app to remove) turns the search field into its
    // prompt. The query typed before it is restored when the user backs out.
    property var pendingAction: null
    property string pendingReturnQuery: ""
    // The web app a first Enter chose to remove; the second Enter removes it.
    property string confirmChoice: ""
    readonly property bool argumentMode: pendingAction !== null
    // The view owns the text field; this asks it to replace the text.
    signal inputReplaced(string text)

    // While a prompt is open its text is the value, never a provider prefix:
    // a URL or path may well start with "/" or ":".
    readonly property var prefixedProvider: argumentMode ? null
        : ProviderHelpers.prefixedProviderFor(query)
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

    readonly property string home: Quickshell.env("HOME")
    readonly property string dataHome: Quickshell.env("XDG_DATA_HOME") || (home + "/.local/share")
    readonly property string clipboardTool: Quickshell.shellDir + "/scripts/clipboard-tool.py"
    readonly property string pinDir: dataHome + "/cybexos/clipboard/pins"
    property var clipboardPins: []
    property var clipboardPreviews: ({})
    property string clipboardPreviewKey: ""
    property var webApps: []
    property bool webAppsLoading: false
    property string webAppsError: ""
    // argv of the catalogue command waiting for the launcher to fade out.
    property var pendingCommand: []

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
                subtitle: windowClass + (DesktopWorkspaces.isMinimized(win.address)
                    ? " · " + I18n.tr("Minimized") : "")
                    + root.workspaceDescription(win),
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

    function workspaceDescription(win) {
        const minimized = DesktopWorkspaces.minimizedWindow(win.address);
        if (!minimized && win.workspace && WindowCommands.workspaceKind(win.workspace) === "named")
            return " · " + I18n.tr("Workspace") + " " + win.workspace.name;
        const workspaceId = minimized ? minimized.workspace : win.workspace ? win.workspace.id : 0;
        const workspace = DesktopWorkspaces.workspace(workspaceId);
        return workspace ? " · " + workspace.monitor + " · " + I18n.tr("Workspace") + " " + workspace.label : "";
    }

    // Entries for a feature the installation left out (developer tools,
    // connected widgets) never appear, typed or blended.
    // Built-in entries are shown in the session's language; their English
    // name stays a keyword, so either language finds them.
    readonly property var actions: ProviderHelpers.availableActions(
        ProviderHelpers.BUILTIN_ACTIONS, {
            developerTools: Settings.developerToolsConfigured,
            connectedWidgets: Settings.connectedWidgetsConfigured
        }).map(action => Object.assign({}, action, {
            name: I18n.tr(action.name),
            subtitle: I18n.tr(action.subtitle),
            keywords: (action.keywords || []).concat([action.name])
        })).concat(userActions)

    readonly property var pendingRows: {
        const action = root.pendingAction;
        if (!action)
            return [];
        if (action.choices === "webapps")
            return ProviderHelpers.webAppChoiceRows(root.webApps, root.term,
                root.webApps.length, root.confirmChoice);
        return ProviderHelpers.argumentRows(action, root.term);
    }

    readonly property var rows: {
        if (root.argumentMode)
            return root.pendingRows;
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
                subtitle: I18n.tr("Explicit shell command"),
                glyph: root.activeProvider.glyph,
                command: root.term
            }];
        case "calculator":
            return root.calcResult === "" ? [] : [{
                providerId: "calculator",
                kind: "calc",
                title: root.calcResult,
                subtitle: I18n.tr("Press Enter to copy result"),
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
                root.term, root.maxResults, {
                    pins: root.clipboardPins,
                    previews: root.clipboardPreviews,
                    pinDir: root.pinDir
                });
        case "emoji":
            return ProviderHelpers.emojiRows(root.emojiEntries,
                root.term, root.maxResults);
        case "actions":
            return ProviderHelpers.actionRows(root.actions,
                root.term, root.actions.length);
        default:
            // A typed query also offers up to three matching actions after
            // the apps, so Super+Space is the one palette.
            return ProviderHelpers.blendRows(root.appRows, root.actions, root.term);
        }
    }

    readonly property bool busy: argumentMode
        ? pendingAction.choices === "webapps" && webAppsLoading
        : activeProviderId === "files" ? fileLoading
        : activeProviderId === "calculator" ? calcLoading
        : activeProviderId === "clipboard" ? clipboardLoading
        : activeProviderId === "emoji" ? emojiLoading : false

    readonly property string error: argumentMode
        ? (pendingAction.choices === "webapps" ? webAppsError : "")
        : activeProviderId === "files" ? fileError
        : activeProviderId === "calculator" ? calcError
        : activeProviderId === "clipboard" ? clipboardError
        : activeProviderId === "emoji" ? emojiError
        : activeProviderId === "actions" ? actionsError : ""

    readonly property string emptyText: {
        if (root.argumentMode) {
            if (root.busy)
                return "Loading…";
            if (root.error !== "")
                return root.error;
            if (root.pendingAction.choices === "webapps")
                return root.webApps.length === 0 ? "No web apps are installed"
                    : "No matching web apps";
            return ProviderHelpers.argumentEmptyText(root.pendingAction, root.term);
        }
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
        root.confirmChoice = "";
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

    // `copyOnly` is Shift+Enter: a clipboard entry or emoji is copied
    // without being pasted into the previous window.
    function activate(row, copyOnly): void {
        if (!row)
            return;
        if (row.kind === "choice" && !row.confirm) {
            root.confirmChoice = row.value;
            return;
        }
        if (row.kind === "argument" || row.kind === "choice") {
            root.runAction(root.pendingAction, row.value);
            return;
        }
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
            // A stale result must not fall back to the active window. The
            // module restores hidden windows to their saved monitor first.
            if (row.win && DesktopWorkspaces.activate(row.win.address))
                Launcher.close();
            break;
        case "clipboard":
            root.useClipboardEntry(row, !copyOnly);
            break;
        case "emoji":
            if (copyOnly) {
                Quickshell.clipboardText = row.value;
                Launcher.close();
            } else {
                root.pasteText(row.value);
            }
            break;
        case "actions":
            root.runAction(row.action);
            break;
        }
    }

    function canRemove(row): bool {
        return !!row && row.providerId === "clipboard";
    }

    // Shift+Delete on a pin unpins it; on history it deletes the entry.
    function remove(row): void {
        if (!root.canRemove(row))
            return;
        if (row.pinned) {
            root.togglePin(row);
            return;
        }
        if (clipboardDeleteProc.running)
            return;
        clipboardDeleteProc.command = ["sh", "-c",
            "printf '%s' " + root.shellQuote(row.raw) + " | cliphist delete"];
        clipboardDeleteProc.running = true;
    }

    // An action that needs a value opens its prompt instead of running; the
    // value then arrives here as `argument`.
    function runAction(action, argument): void {
        if (!action)
            return;
        if ((action.argument || action.choices) && argument === undefined) {
            root.beginArgument(action);
            return;
        }
        root.resetPending();
        Launcher.close();
        if (action.user && Array.isArray(action.command)
                && action.command.length > 0) {
            Quickshell.execDetached(action.command);
            return;
        }
        if (action.settingsPage) {
            const page = action.settingsPage;
            const key = action.settingsKey || "";
            Qt.callLater(() => key !== "" ? Settings.showSetting(page, key)
                : Settings.showPanel(page));
            return;
        }
        if (Array.isArray(action.command)) {
            const argv = ProviderHelpers.expandCommand(action.command, root.home, argument);
            if (argv.length === 0)
                return;
            // A value the user typed reaches the helper as its own argv
            // element with no shell in between; those helpers report their
            // own outcome. A fixed command runs under a fixed wrapper whose
            // only job is to say so when it fails.
            root.pendingCommand = argument !== undefined ? argv
                : ["sh", "-c", '"$@" || notify-send --app-name=CybexOS -- "$0 failed"'
                    + ' "The command exited with an error"', action.name].concat(argv);
            // Started once the launcher has left the screen, so a capture
            // never contains it and a new window takes focus from no one.
            commandTimer.interval = Theme.launcherFadeOutDuration
                + (action.settle ? 160 : 40);
            commandTimer.restart();
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

    function beginArgument(action): void {
        root.pendingReturnQuery = root.query;
        root.pendingAction = action;
        if (action.choices === "webapps")
            root.refreshWebApps();
        root.inputReplaced("");
    }

    // Escape in a prompt: back to the list it was opened from.
    function cancelPending(): bool {
        if (!root.argumentMode)
            return false;
        const text = root.pendingReturnQuery;
        root.resetPending();
        root.inputReplaced(text);
        return true;
    }

    function resetPending(): void {
        root.pendingAction = null;
        root.pendingReturnQuery = "";
        root.confirmChoice = "";
    }

    // The launcher's own rows name icons either by theme name or, for web
    // apps and other user entries, by absolute path.
    function iconSource(icon): string {
        const value = String(icon || "");
        if (value === "")
            return "";
        return ProviderHelpers.directIconUrl(value) || Quickshell.iconPath(value, true);
    }

    function refreshWebApps(): void {
        root.webAppsError = "";
        root.webAppsLoading = true;
        if (!webAppListProc.running)
            webAppListProc.running = true;
    }

    function canPin(row): bool {
        return !!row && row.providerId === "clipboard" && !clipboardPinProc.running;
    }

    // Ctrl+P keeps an entry above the history; pins live in a user-owned
    // store, so pruning or wiping cliphist does not take them along.
    function togglePin(row): void {
        if (!root.canPin(row))
            return;
        clipboardPinProc.command = row.pinned
            ? ["python3", root.clipboardTool, "unpin", "--notify", row.pinId]
            : ["python3", root.clipboardTool, "pin", "--notify", row.raw];
        clipboardPinProc.running = true;
    }

    function shellQuote(value): string {
        return "'" + String(value || "").replace(/'/g, "'\"'\"'") + "'";
    }

    // Enter copies the entry and, once the launcher has released keyboard
    // focus, pastes it into the window that was active before; Shift+Enter
    // only copies. The entry reaches the copy as a positional argument.
    function useClipboardEntry(row, paste): void {
        if (clipboardCopyProc.running)
            return;
        clipboardCopyProc.command = row.pinned
            ? ["python3", root.clipboardTool, "copy", row.pinId]
            : ["sh", "-c", 'printf "%s" "$1" | cliphist decode | wl-copy >/dev/null 2>&1',
                "sh", row.raw];
        root.pastePending = paste;
        Launcher.close();
        clipboardCopyProc.running = true;
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
        pinsView.reload();
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

    // The search processes settle on the falling edge of `running`: a binary
    // that cannot start (fd or qalc not installed) emits no `exited`, and
    // waiting for one would leave the launcher "Searching…" for good.
    Process {
        id: fileProc
        property string request: ""
        property bool exitSeen: false
        property int lastExit: 0
        onRunningChanged: {
            if (running) {
                request = root.term;
                exitSeen = false;
                lastExit = 0;
                return;
            }
            if (request !== root.term || root.activeProviderId !== "files")
                return;
            root.fileLoading = false;
            const code = exitSeen ? lastExit : ProcHelpers.NOT_STARTED;
            if (code !== 0 && root.fileError === "")
                root.fileError = ProcHelpers.commandError("File search", code, "");
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
            fileProc.exitSeen = true;
            fileProc.lastExit = exitCode;
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
        property bool exitSeen: false
        property int lastExit: 0
        onRunningChanged: {
            if (running) {
                request = root.term;
                exitSeen = false;
                lastExit = 0;
                return;
            }
            if (request !== root.term || root.activeProviderId !== "calculator")
                return;
            root.calcLoading = false;
            const code = exitSeen ? lastExit : ProcHelpers.NOT_STARTED;
            if (code !== 0 && root.calcError === "")
                root.calcError = ProcHelpers.commandError("Calculator", code, "");
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
            calcProc.exitSeen = true;
            calcProc.lastExit = exitCode;
        }
    }

    Process {
        id: clipboardListProc
        property int generation: -1
        property var buffer: []
        property string errText: ""
        property bool exitSeen: false
        property int lastExit: 0
        command: ["sh", "-c", "command -v cliphist >/dev/null 2>&1"
            + " || exit 127; exec cliphist list"]
        stdout: SplitParser {
            onRead: line => clipboardListProc.buffer.push(line)
        }
        stderr: StdioCollector {
            onStreamFinished: clipboardListProc.errText = text.trim()
        }
        onExited: (exitCode, exitStatus) => {
            clipboardListProc.exitSeen = true;
            clipboardListProc.lastExit = exitCode;
        }
        onRunningChanged: {
            if (running) {
                exitSeen = false;
                lastExit = 0;
                return;
            }
            if (generation !== root.clipboardRefreshGeneration) {
                clipboardRefreshRestart.restart();
                return;
            }
            root.clipboardLoading = false;
            const code = exitSeen ? lastExit : ProcHelpers.NOT_STARTED;
            if (code === 0) {
                root.clipboardEntries = clipboardListProc.buffer.slice();
                root.clipboardError = "";
                root.requestPreviews();
            } else if (code === 127) {
                root.clipboardEntries = [];
                root.clipboardError = "cliphist is not installed";
            } else {
                root.clipboardError = clipboardListProc.errText !== ""
                    ? clipboardListProc.errText
                    : ProcHelpers.commandError("Clipboard history", code, "");
            }
        }
    }

    // Thumbnails for image entries, decoded by the helper into a bounded
    // cache that it also prunes. Asked again only when the set changes.
    function requestPreviews(): void {
        const targets = ProviderHelpers.clipboardPreviewTargets(root.clipboardEntries, 24);
        const key = JSON.stringify(targets);
        if (key === root.clipboardPreviewKey || clipboardPreviewProc.running)
            return;
        root.clipboardPreviewKey = key;
        clipboardPreviewProc.command = ["python3", root.clipboardTool, "previews"]
            .concat(targets);
        clipboardPreviewProc.running = true;
    }

    Process {
        id: clipboardPreviewProc
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const parsed = JSON.parse(text);
                    root.clipboardPreviews = parsed && typeof parsed === "object"
                        && !Array.isArray(parsed) ? parsed : {};
                } catch (e) {
                    root.clipboardPreviews = {};
                }
            }
        }
        onRunningChanged: {
            // A preview set that changed while this ran is asked for next.
            if (!running && root.activeProviderId === "clipboard")
                Qt.callLater(() => root.requestPreviews());
        }
    }

    Process {
        id: clipboardCopyProc
        property bool exitSeen: false
        property int lastExit: 0
        onExited: (exitCode, exitStatus) => {
            clipboardCopyProc.exitSeen = true;
            clipboardCopyProc.lastExit = exitCode;
        }
        onRunningChanged: {
            if (running) {
                exitSeen = false;
                lastExit = 0;
                return;
            }
            const code = exitSeen ? lastExit : ProcHelpers.NOT_STARTED;
            if (code === 0 && root.pastePending) {
                pasteTimer.restart();
                return;
            }
            root.pastePending = false;
            if (code !== 0)
                Quickshell.execDetached(["notify-send", "--app-name=CybexOS",
                    "Clipboard", "The entry could not be copied"]);
        }
    }

    Process {
        id: clipboardPinProc
        // The helper prints the new pin; a closed pipe would fail it after
        // the pin was written. Failures reach the user as a notification.
        stdout: StdioCollector {}
        onRunningChanged: {
            if (!running)
                root.refreshClipboard();
        }
    }

    Process {
        id: webAppListProc
        property bool exitSeen: false
        property int lastExit: 0
        command: ["cybexos-webapp", "list", "--json"]
        stdout: StdioCollector {
            onStreamFinished: root.webApps = ProviderHelpers.parseWebApps(text)
        }
        onExited: (exitCode, exitStatus) => {
            webAppListProc.exitSeen = true;
            webAppListProc.lastExit = exitCode;
        }
        onRunningChanged: {
            if (running) {
                exitSeen = false;
                lastExit = 0;
                return;
            }
            root.webAppsLoading = false;
            const code = exitSeen ? lastExit : ProcHelpers.NOT_STARTED;
            if (code !== 0) {
                root.webApps = [];
                root.webAppsError = ProcHelpers.commandError("Web apps", code, "");
            }
        }
    }

    // Catalogue commands start after the launcher has faded out.
    Timer {
        id: commandTimer
        onTriggered: {
            if (root.pendingCommand.length > 0)
                Quickshell.execDetached(root.pendingCommand);
            root.pendingCommand = [];
        }
    }

    FileView {
        id: pinsView
        path: root.dataHome + "/cybexos/clipboard/pins.json"
        printErrors: false
        watchChanges: true
        onFileChanged: reload()
        onLoaded: root.clipboardPins = ProviderHelpers.parsePins(text())
        onLoadFailed: root.clipboardPins = []
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
            + "clipboard-history-store"
    }

    ClipboardWatcher {
        watch: "wl-paste --type image --watch "
            + "clipboard-history-store"
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
        path: root.emojiRequested ? "/etc/cybexos/emoji-test.txt" : ""
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
