pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "Format.js" as Format
import "ProcHelpers.js" as ProcHelpers
import "TailscaleHelpers.js" as TailscaleHelpers

// One `tailscale status --json` for the whole shell. The Network menubar
// summary, Network view and Tailscale detail panel all read this snapshot, so
// one run answers both "am I connected?" and "who else is on the tailnet?"
//
// This is a poll rather than a subscription because `tailscale status` has
// no watch mode; watchers keep it running only while something is on screen
// to read it. The enabled Network module is normally the long-lived watcher,
// and a menubar glyph and tooltip do not need a fresh tailnet every 30s: only
// an open view (acquireLive) polls at the fast cadence.
Singleton {
    id: root

    // This machine.
    property bool running: false
    property string backendState: ""
    property string authUrl: ""
    property bool authPending: false
    property bool browserRequested: false
    property string actionError: ""
    property bool permissionRetry: false
    readonly property bool busy: actionProc.running || permissionRetry
    readonly property bool needsLogin: backendState === "NeedsLogin"
    readonly property bool needsApproval: backendState === "NeedsMachineAuth"
    readonly property string statusText: actionError !== "" ? actionError
        : missing ? "Tailscale is not installed"
        : statusError !== "" ? "Tailscale service unavailable"
        : !statusKnown ? "Checking status…"
        : connected ? "Connected"
        : needsApproval ? "Waiting for administrator approval"
        : authPending && authUrl !== "" ? "Waiting for sign-in…"
        : busy || authPending || backendState === "Starting" ? "Connecting…"
        : needsLogin ? "Sign-in required" : "Disconnected"
    property string host: ""
    property string net: ""
    property string ip: ""
    property bool exitNode: false
    // BackendState alone is not enough for a visible "connected" claim: a
    // usable tailnet session also has this machine's Tailscale address, and a
    // failed read must never leave a stale mark lit in the menubar.
    readonly property bool connected: running && ip !== "" && statusError === ""

    // The tailnet. A status run has come back, either way: an empty `peers`
    // with no statusError is a genuinely empty tailnet, while a failed run
    // says so rather than counting to zero.
    property var peers: []
    property bool statusKnown: false
    property string statusError: ""

    // How long tailscaled takes to settle after `up`/`down` before a status
    // read reflects it. The two call sites had drifted to 1400ms and 1200ms;
    // this is the longer of the two, because the shorter one occasionally
    // read the pre-toggle state back.
    readonly property int settleMs: 1400

    // ---- watchers ---------------------------------------------------------
    // Polling is the consumer's business, not Popouts': a view that wants
    // fresh status says so for as long as it is alive. Every newly visible
    // consumer asks for a fresh snapshot unless one is already in flight.
    // This matters now the menubar holds a long-lived claim: opening a detail
    // view must not inherit a snapshot that is almost one poll interval old.
    property int watchers: 0
    // The subset of watchers that are open views rather than the menubar.
    property int liveWatchers: 0
    readonly property int livePollMs: 30000
    readonly property int idlePollMs: 120000
    // No `tailscale` binary: every run would fork only for Quickshell to log
    // that it could not start. Probe hourly instead, and whenever a view
    // opens, so installing it later is still noticed.
    property bool missing: false
    readonly property int missingPollMs: Format.MS_HOUR

    function acquire() {
        watchers++;
        if (!statusProc.running)
            refresh();
    }

    function release() {
        watchers = Math.max(0, watchers - 1);
    }

    // A panel or detail view: a watcher that also wants the fast cadence.
    function acquireLive() {
        liveWatchers++;
        acquire();
    }

    function releaseLive() {
        liveWatchers = Math.max(0, liveWatchers - 1);
        release();
    }

    // Nobody reads the tailnet from an idle or locked session; the first
    // input afterwards takes one fresh snapshot instead.
    Timer {
        interval: root.missing ? root.missingPollMs
            : root.liveWatchers > 0 ? root.livePollMs : root.idlePollMs
        running: root.watchers > 0 && !Activity.idle
        repeat: true
        onTriggered: root.refresh()
    }

    Connections {
        target: Activity

        function onResumed() {
            if (root.watchers > 0 && !root.missing && !statusProc.running)
                root.refresh();
        }
    }

    function refresh() {
        statusProc.staleRuns += statusProc.running ? 1 : 0;
        statusProc.running = false;
        statusProc.running = true;
    }

    function showSetup() {
        NetworkOverlayState.openTailscale();
        refresh();
    }

    function setRunning(value) {
        if (busy)
            return;
        if (value && (needsLogin || needsApproval || authPending || !statusKnown
                || backendState !== "Stopped" && backendState !== "Running")) {
            showSetup();
            return;
        }
        startAction(value);
    }

    function toggle() {
        setRunning(!running);
    }

    function startAction(value) {
        if (busy)
            return;
        actionError = "";
        authPending = value;
        if (value) {
            authExpiry.restart();
        } else {
            authExpiry.stop();
            authUrl = "";
            browserRequested = false;
        }
        actionProc.login = value && backendState !== "Stopped" && backendState !== "Running";
        runAction(value, false);
    }

    function runAction(value, privileged) {
        actionProc.up = value;
        actionProc.privileged = privileged;
        actionProc.command = TailscaleHelpers.command(value, privileged, actionProc.login);
        actionProc.running = true;
        permissionRetry = false;
    }

    function signIn() {
        if (authUrl !== "") {
            openBrowser();
            return;
        }
        if (busy)
            return;
        browserRequested = true;
        // Release the exclusive overlay focus before a possible polkit prompt.
        NetworkOverlayState.close();
        startAction(true);
    }

    function openBrowser() {
        if (authUrl === "")
            return;
        browserRequested = false;
        NetworkOverlayState.close();
        Popouts.close();
        const url = authUrl;
        Qt.callLater(() => {
            if (!Qt.openUrlExternally(url)) {
                actionError = "The browser could not be opened. Copy the sign-in link and open it in your browser.";
                showSetup();
            }
        });
    }

    function copySignInLink() {
        if (authUrl !== "")
            Quickshell.execDetached(["wl-copy", authUrl]);
    }

    function actionLine(line) {
        const output = TailscaleHelpers.outputLine(actionProc.buffer, line);
        actionProc.buffer = output.buffer;
        const event = output.event;
        if (!event)
            return;
        if (event.Error) {
            actionProc.errorText += "\n" + String(event.Error);
            return;
        }
        if (event.BackendState === "NeedsMachineAuth") {
            backendState = "NeedsMachineAuth";
            authUrl = "";
            browserRequested = false;
        }
        if (event.AuthURL) {
            const url = TailscaleHelpers.authUrl(event.AuthURL);
            if (url === "") {
                actionProc.errorText = "Tailscale returned an invalid sign-in link.";
                return;
            }
            authUrl = url;
            authPending = true;
            if (browserRequested)
                openBrowser();
            else
                showSetup();
        }
        // A command event is not proof of connectivity: use a fresh snapshot.
        refresh();
    }

    function actionErrorLine(line) {
        if (/To approve your machine/.test(line)) {
            backendState = "NeedsMachineAuth";
            authUrl = "";
            browserRequested = false;
            refresh();
            return;
        }
        const url = TailscaleHelpers.authUrl(String(line).trim());
        if (url !== "") {
            if (!needsApproval)
                actionLine(JSON.stringify({ AuthURL: url }));
            return;
        }
        actionProc.errorText = (actionProc.errorText + "\n" + line).slice(-8192);
    }

    function finishAction(code) {
        const detail = actionProc.errorText;
        if (code !== 0 && !actionProc.privileged && TailscaleHelpers.needsPermission(detail)) {
            permissionRetry = true;
            NetworkOverlayState.close();
            Popouts.close();
            Qt.callLater(() => root.runAction(actionProc.up, true));
            return;
        }
        const waiting = actionProc.up
            && (connected || authPending && (authUrl !== "" || needsApproval))
            && (code === 124 || TailscaleHelpers.waitingTimeout(detail));
        if (code !== 0 && !waiting) {
            actionError = TailscaleHelpers.errorMessage(code, detail, actionProc.privileged);
            authPending = false;
            authUrl = "";
            browserRequested = false;
            authExpiry.stop();
            showSetup();
        }
        settle.restart();
    }

    Timer {
        interval: 2000
        running: (root.authPending || root.busy) && !Activity.idle
        repeat: true
        onTriggered: if (!statusProc.running) root.refresh()
    }

    Timer {
        id: authExpiry
        interval: 300000
        onTriggered: {
            root.authPending = false;
            root.authUrl = "";
            root.browserRequested = false;
            root.actionError = root.needsApproval
                ? "This device still needs administrator approval. Reopen Tailscale to check its status."
                : "Sign-in has not completed. Try again to get a sign-in link.";
        }
    }

    Process {
        id: actionProc
        property bool up: true
        property bool login: true
        property bool privileged: false
        property bool exitSeen: false
        property string buffer: ""
        property string errorText: ""
        // qmllint disable incompatible-type
        environment: ({ LC_ALL: "C" })
        // qmllint enable incompatible-type
        stdout: SplitParser { onRead: line => root.actionLine(line) }
        stderr: SplitParser {
            onRead: line => root.actionErrorLine(line)
        }
        onExited: (exitCode, exitStatus) => {
            exitSeen = true;
            root.finishAction(exitCode);
        }
        onRunningChanged: {
            if (running) {
                buffer = "";
                errorText = "";
                exitSeen = false;
            } else {
                Qt.callLater(() => {
                    if (!actionProc.running && !actionProc.exitSeen) {
                        actionProc.exitSeen = true;
                        root.finishAction(ProcHelpers.NOT_STARTED);
                    }
                });
            }
        }
    }

    // Bound time spent waiting for a graphical authorization prompt as well.
    Timer {
        interval: 90000
        running: actionProc.running
        onTriggered: {
            actionProc.errorText = "Authorization timed out. Try again.";
            actionProc.running = false;
        }
    }

    Timer {
        id: settle
        interval: root.settleMs
        onTriggered: root.refresh()
    }

    function apply(exitCode, body, errText) {
        statusKnown = true;
        missing = exitCode === ProcHelpers.NOT_STARTED;
        const self = exitCode === 0 ? ProcHelpers.tailscaleSelf(body) : null;
        const list = exitCode === 0 ? ProcHelpers.tailscalePeers(body) : null;
        if (self !== null && list !== null) {
            running = self.running;
            backendState = self.backendState;
            host = self.host;
            net = self.net;
            ip = self.ip;
            exitNode = self.exitNode;
            peers = list;
            statusError = "";
            if (connected) {
                if (actionProc.up)
                    actionError = "";
                if (authPending) {
                    Quickshell.execDetached(["notify-send", "--app-name=CybexOS",
                        "Connected to Tailscale", host + (ip !== "" ? " · " + ip : "")]);
                }
                authPending = false;
                authUrl = "";
                browserRequested = false;
                authExpiry.stop();
            } else if (needsApproval) {
                authUrl = "";
                browserRequested = false;
            }
            return;
        }
        // Unreadable output says nothing about the backend, so `running`
        // is cleared too: claiming "connected" off a failed read is worse
        // than saying nothing.
        running = false;
        backendState = "";
        peers = [];
        statusError = exitCode === 0
            ? "tailscale status returned output this shell could not read"
            : ProcHelpers.commandError("tailscale status", exitCode, errText);
        if (statusError !== lastLogged) {
            console.warn("tailscale status unavailable:", statusError);
            lastLogged = statusError;
        }
    }

    // The poll runs every 30s while a view is open; logging on change keeps
    // a persistent failure from filling the journal.
    property string lastLogged: ""
    onStatusErrorChanged: {
        if (statusError === "")
            lastLogged = "";
    }

    Process {
        id: statusProc
        // `tailscale status --json` writes its complaint to stderr and exits
        // nonzero when tailscaled is unreachable; both streams close before
        // exited(), and the falling edge of `running` is the only signal
        // there is when the binary cannot be launched at all.
        //
        // Runs killed by refresh() have yet to report in: their exit lands as
        // a crash some time after the replacement started, and is not news.
        property int staleRuns: 0
        property string body: ""
        property string errText: ""
        property bool exitSeen: false
        property int lastExit: 0

        command: ["tailscale", "status", "--json"]

        stdout: StdioCollector {
            onStreamFinished: statusProc.body = text
        }
        stderr: StdioCollector {
            onStreamFinished: statusProc.errText = text
        }
        onExited: (exitCode, exitStatus) => {
            statusProc.exitSeen = true;
            statusProc.lastExit = exitCode;
        }
        onRunningChanged: {
            if (running) {
                body = "";
                errText = "";
                exitSeen = false;
                lastExit = 0;
            } else if (staleRuns > 0) {
                staleRuns--;
            } else {
                root.apply(exitSeen ? lastExit : ProcHelpers.NOT_STARTED, body, errText);
            }
        }
    }
}
