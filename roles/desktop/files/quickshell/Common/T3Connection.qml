pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "T3CodeHelpers.js" as Helpers

// The transport half of the T3 client: the authenticated state file, ticket
// exchange, the WebSocket itself, and the retry/backoff that ties them
// together. It knows nothing about the protocol spoken over the socket —
// T3Code owns that and listens to `message`.
//
// T3 Connect auth is implemented by scripts/t3-cloud.mjs using a browser-backed
// native Clerk session and relay JWT template. T3 Connect environment tokens
// are DPoP-bound, so the helper also creates each short-lived WebSocket ticket.
// Older bearer state files remain readable.
Singleton {
    id: root

    // "signed-out" | "cloud-empty" | "connecting" | "connected" | "offline"
    property string state: "offline"
    // Why the last attempt failed, already shortened for a tooltip. Both hops
    // of connect() fill it — the ticket request and the socket — because a
    // dead host fails the first one and never reaches the second. Empty means
    // "nothing worth showing", which leaves every consumer on its generic
    // offline wording; consumers must also ignore it while signed out, where
    // the missing T3 Connect credential, not the network, is the story.
    property string connectionError: ""
    // The one offline state no retry can end: the WebSocket component itself
    // failed to load. Consumers use it to drop any "retrying" wording, which
    // would be a lie here — connect() deliberately arms no timer for it.
    readonly property bool websocketsMissing: socketLoader.status === Loader.Error

    property string host: ""            // https base url from the state file
    property string wsBaseUrl: ""
    property string accessToken: ""
    property string authMode: ""
    property string tokenType: "Bearer"
    property string cloudStatus: "signed-out"
    property string cloudIdentity: ""
    readonly property bool paired: host !== "" && accessToken !== ""
    readonly property bool cloudLoginRunning: cloudLoginProc.running
    property string cloudLoginError: ""
    // Every credential replacement/removal invalidates all asynchronous work
    // created by the preceding session.
    property int sessionEpoch: 0
    property string credentialFingerprint: ""
    property var ticketRequest: null
    property var descriptorRequest: null
    property string pendingSocketUrl: ""
    property int pendingSocketEpoch: -1

    property string environmentLabel: ""
    property string environmentId: ""
    property string serverVersion: ""
    property var environmentCapabilities: ({})

    // Scope is persisted alongside the environment token. Older bearer state
    // files do not contain it; absence keeps the old server-authorizes model.
    property bool scopeMetadataKnown: false
    property var tokenScope: ""

    // What this token is allowed to do. Derived here because the scope comes
    // off the credential file, and because "can dispatch" also needs the live
    // socket state — both of which are this file's business.
    readonly property var scopeInfo: Helpers.normalizeScopes(tokenScope, scopeMetadataKnown)
    readonly property bool canRead: scopeInfo.canRead
    readonly property bool canOperate: scopeInfo.canOperate
    readonly property bool readOnly: scopeMetadataKnown && !canOperate
    readonly property bool canDispatch: canOperate && state === "connected"

    // Every frame the server sends, verbatim. T3Code parses it.
    signal message(string text)
    // The socket just opened: the protocol layer resubscribes here.
    signal opened()
    // The link is going away and a retry is being armed. The protocol layer
    // fails its in-flight work here; this fires before the retry is scheduled.
    signal dropped()

    function stateWithoutCredential() {
        return authMode === "cloud" && cloudStatus === "no-environments"
            ? "cloud-empty" : "signed-out";
    }

    function loginCloud() {
        if (cloudLoginProc.running)
            return;
        cloudLoginError = "";
        connectionError = "";
        cloudLoginProc.attempted = true;
        cloudLoginProc.attemptEpoch = sessionEpoch;
        cloudLoginProc.running = true;
    }

    // Identifies the credential session rather than its current token: the
    // DPoP ticket helper refreshes a near-expiry environment token in this
    // file while it is producing a ticket, and treating that write as a new
    // session would discard the ticket and spawn a second helper.
    function fingerprint(data) {
        return Helpers.credentialFingerprint(data);
    }

    function resetTransport() {
        const shouldDrop = state === "connected" || state === "connecting";
        sessionEpoch++;
        retryTimer.stop();
        ticketTimeout.stop();
        cloudTicketTimeout.stop();
        socketConnectTimeout.stop();
        descriptorTimeout.stop();
        if (ticketRequest) {
            ticketRequest.abort();
            ticketRequest = null;
        }
        if (descriptorRequest) {
            descriptorRequest.abort();
            descriptorRequest = null;
        }
        cloudTicketProc.reconnectEpoch = -1;
        cloudTicketProc.timedOutEpoch = -1;
        if (cloudTicketProc.running)
            cloudTicketProc.running = false;
        state = "offline";
        pendingSocketUrl = "";
        pendingSocketEpoch = -1;
        // Destroy the wrapper, not merely its underlying WebSocket. A late
        // signal from the old C++ socket would otherwise be delivered through
        // the same QML object after its epoch property had been overwritten.
        socketLoader.active = false;
        if (shouldDrop)
            dropped();
        retrySecs = 5;
        environmentLabel = "";
        environmentId = "";
        serverVersion = "";
        environmentCapabilities = ({});
    }

    function clearCredential() {
        host = "";
        wsBaseUrl = "";
        accessToken = "";
        authMode = "";
        tokenType = "Bearer";
        cloudStatus = "signed-out";
        cloudIdentity = "";
        scopeMetadataKnown = false;
        tokenScope = "";
    }

    // ---- state file ------------------------------------------------------

    FileView {
        id: stateFile
        readonly property string stateHome: Quickshell.env("XDG_STATE_HOME")
            || (Quickshell.env("HOME") + "/.local/state")
        path: stateHome + "/t3code-bar.json"
        printErrors: false
        watchChanges: true
        onFileChanged: reload()
        onLoaded: {
            const nextFingerprint = root.fingerprint(stateData);
            if (nextFingerprint !== root.credentialFingerprint) {
                root.resetTransport();
                root.credentialFingerprint = nextFingerprint;
            }
            root.host = (stateData.httpBaseUrl ?? "").replace(/\/+$/, "");
            root.wsBaseUrl = stateData.wsBaseUrl ?? "";
            root.accessToken = stateData.accessToken ?? "";
            root.authMode = stateData.authMode ?? "";
            root.tokenType = stateData.tokenType || "Bearer";
            root.cloudStatus = stateData.cloudStatus || "signed-out";
            root.cloudIdentity = stateData.cloudIdentity ?? "";
            if (stateData.environmentId)
                root.environmentId = stateData.environmentId;
            if (stateData.environmentLabel)
                root.environmentLabel = stateData.environmentLabel;
            root.scopeMetadataKnown = typeof stateData.scope === "string"
                || Array.isArray(stateData.scope);
            root.tokenScope = root.scopeMetadataKnown ? stateData.scope : "";
            if (!socketLoader.active)
                socketLoader.active = true;
            if (root.paired) {
                if (root.state !== "connected") {
                    if (cloudTicketProc.running
                            && cloudTicketProc.attemptEpoch !== root.sessionEpoch) {
                        // The old DPoP helper must finish before its Process can
                        // be reused. Remember only the newest generation; its
                        // stale exit consumes this slot exactly once.
                        cloudTicketProc.reconnectEpoch = root.sessionEpoch;
                        root.state = "offline";
                    } else if (!cloudTicketProc.running) {
                        root.connect();
                    }
                }
            } else {
                root.state = root.stateWithoutCredential();
            }
        }
        onLoadFailed: error => {
            root.resetTransport();
            root.credentialFingerprint = "";
            root.clearCredential();
            if (cloudLoginProc.running)
                cloudLoginProc.running = false;
            if (error === FileViewError.FileNotFound) {
                root.connectionError = "";
                root.state = "signed-out";
            } else {
                root.connectionError = "Could not read the T3 credential file";
                root.state = "offline";
            }
        }

        JsonAdapter {
            id: stateData
            property string httpBaseUrl: ""
            property string wsBaseUrl: ""
            property string accessToken: ""
            property string authMode: ""
            property string tokenType: "Bearer"
            property string cloudStatus: "signed-out"
            property string cloudIdentity: ""
            property string environmentId: ""
            property string environmentLabel: ""
            property var scope: null
        }
    }

    Process {
        id: cloudLoginProc

        property bool attempted: false
        property int attemptEpoch: -1
        property bool exitSeen: false
        property int lastExit: 0
        property string errText: ""

        command: ["node", Quickshell.shellDir + "/scripts/t3-cloud.mjs", "login"]
        stdout: StdioCollector {}
        stderr: StdioCollector {
            onStreamFinished: cloudLoginProc.errText = text.trim()
        }
        onExited: (exitCode, exitStatus) => {
            cloudLoginProc.exitSeen = true;
            cloudLoginProc.lastExit = exitCode;
        }
        onRunningChanged: {
            if (running) {
                cloudLoginProc.errText = "";
                cloudLoginProc.exitSeen = false;
                cloudLoginProc.lastExit = 0;
                return;
            }
            if (!cloudLoginProc.attempted)
                return;
            cloudLoginProc.attempted = false;
            if (cloudLoginProc.attemptEpoch !== root.sessionEpoch)
                return;
            if (cloudLoginProc.exitSeen && cloudLoginProc.lastExit === 0) {
                root.cloudLoginError = "";
                stateFile.reload();
                return;
            }
            root.cloudLoginError = cloudLoginProc.errText !== ""
                ? cloudLoginProc.errText : "T3 Connect sign-in did not complete.";
        }
    }

    // scripts/t3-cloud.mjs exits with this (SIGN_IN_REQUIRED_EXIT) when it
    // found no active T3 Connect session: a state, not a transient failure.
    readonly property int signInRequiredExit: 3

    Process {
        id: cloudTicketProc

        property bool attempted: false
        property int attemptEpoch: -1
        property bool exitSeen: false
        property int lastExit: 0
        property string outText: ""
        property string errText: ""
        // A credential refresh can arrive while the preceding helper is still
        // terminating. Process instances cannot run two commands at once, so
        // this single epoch slot hands the newest attempt off after shutdown.
        property int reconnectEpoch: -1
        property int timedOutEpoch: -1

        command: ["node", Quickshell.shellDir + "/scripts/t3-cloud.mjs", "ticket"]
        stdout: StdioCollector {
            onStreamFinished: cloudTicketProc.outText = text
        }
        stderr: StdioCollector {
            onStreamFinished: cloudTicketProc.errText = text.trim()
        }
        onExited: (exitCode, exitStatus) => {
            cloudTicketProc.exitSeen = true;
            cloudTicketProc.lastExit = exitCode;
        }
        onRunningChanged: {
            if (running) {
                cloudTicketProc.outText = "";
                cloudTicketProc.errText = "";
                cloudTicketProc.exitSeen = false;
                cloudTicketProc.lastExit = 0;
                cloudTicketTimeout.epoch = cloudTicketProc.attemptEpoch;
                cloudTicketTimeout.restart();
                return;
            }
            cloudTicketTimeout.stop();
            if (!cloudTicketProc.attempted)
                return;
            const attemptEpoch = cloudTicketProc.attemptEpoch;
            cloudTicketProc.attempted = false;
            if (attemptEpoch !== root.sessionEpoch) {
                const reconnectEpoch = cloudTicketProc.reconnectEpoch;
                cloudTicketProc.reconnectEpoch = -1;
                if (reconnectEpoch === root.sessionEpoch && root.paired)
                    root.connect();
                return;
            }
            if (cloudTicketProc.timedOutEpoch === attemptEpoch) {
                cloudTicketProc.timedOutEpoch = -1;
                root.connectionError = "T3 Connect authorization timed out";
                root.scheduleRetry(attemptEpoch);
                return;
            }
            if (cloudTicketProc.exitSeen && cloudTicketProc.lastExit === 0) {
                try {
                    const response = JSON.parse(cloudTicketProc.outText);
                    if (typeof response.socketUrl === "string"
                            && response.socketUrl !== "") {
                        root.openSocketUrl(response.socketUrl,
                            attemptEpoch);
                        return;
                    }
                } catch (e) {
                    console.warn("t3code: bad cloud ticket response");
                }
                root.connectionError = "Malformed T3 Connect ticket response";
            } else if (cloudTicketProc.exitSeen
                    && cloudTicketProc.lastExit === root.signInRequiredExit) {
                // No browser session is left to mint credentials from: it
                // expired or was revoked. Only an interactive sign-in can end
                // that, so offer it — as for a rejected bearer token — instead
                // of retrying the helper and its Clerk calls forever.
                root.connectionError = "T3 Connect sign-in has expired";
                root.state = root.stateWithoutCredential();
                return;
            } else {
                root.connectionError = cloudTicketProc.errText !== ""
                    ? cloudTicketProc.errText : "T3 Connect authorization failed";
            }
            root.scheduleRetry(attemptEpoch);
        }
    }

    // ---- connection ------------------------------------------------------

    property int retrySecs: 5
    // When the open socket last delivered a frame. Pings go out every
    // pingTimer interval and the server answers each, so a long silence
    // means the link is gone even though no close was ever reported.
    property double lastFrameMs: 0
    onMessage: lastFrameMs = Date.now()

    function connect() {
        if (!paired) {
            state = stateWithoutCredential();
            return;
        }
        const epoch = sessionEpoch;
        // The state file routinely loads before the socket component does.
        // Without a retry the shell would sit offline until a restart; the
        // loader's onStatusChanged connects the moment it wins that race and
        // cancels the pending retry so the two never race each other. A load
        // *error* is permanent (QtWebSockets missing) and not worth retrying.
        if (socketLoader.status !== Loader.Ready) {
            state = "offline";
            if (socketLoader.status !== Loader.Error)
                scheduleRetry(epoch);
            return;
        }
        if (authMode === "cloud" && tokenType === "DPoP") {
            if (cloudTicketProc.running) {
                if (cloudTicketProc.attemptEpoch !== epoch) {
                    cloudTicketProc.reconnectEpoch = epoch;
                    state = "offline";
                }
                return;
            }
            cloudTicketProc.attempted = true;
            cloudTicketProc.attemptEpoch = epoch;
            cloudTicketProc.running = true;
            state = "connecting";
            fetchDescriptor(epoch);
            return;
        }
        if (ticketRequest) {
            state = "connecting";
            return;
        }
        const xhr = new XMLHttpRequest();
        ticketRequest = xhr;
        xhr.open("POST", host + "/api/auth/websocket-ticket");
        xhr.setRequestHeader("Authorization", "Bearer " + accessToken);
        xhr.onreadystatechange = () => {
            if (xhr.readyState !== XMLHttpRequest.DONE)
                return;
            if (root.ticketRequest === xhr) {
                root.ticketRequest = null;
                ticketTimeout.stop();
            }
            if (epoch !== root.sessionEpoch)
                return;
            if (xhr.status === 200) {
                try {
                    const ticket = JSON.parse(xhr.responseText).ticket;
                    openSocket(ticket, epoch);
                    return;
                } catch (e) {
                    console.warn("t3code: bad ticket response");
                    root.connectionError = "Malformed ticket response";
                }
            } else if (xhr.status === 401 || xhr.status === 403) {
                root.connectionError = "Stored T3 credential was rejected";
                root.state = root.stateWithoutCredential();
                return;
            } else {
                root.connectionError = Helpers.ticketErrorText(xhr.status);
            }
            root.scheduleRetry(epoch);
        };
        xhr.send();
        ticketTimeout.epoch = epoch;
        ticketTimeout.restart();
        state = "connecting";
        fetchDescriptor(epoch);
    }

    function openSocket(ticket, epoch) {
        openSocketUrl(host.replace(/^https:/, "wss:").replace(/^http:/, "ws:")
            + "/ws?wsTicket=" + encodeURIComponent(ticket), epoch);
    }

    function openSocketUrl(url, epoch) {
        if (epoch !== sessionEpoch)
            return;
        // A Loader generation owns exactly one WebSocket attempt. Recreating
        // it severs every signal connection from the preceding attempt, so a
        // delayed close/frame cannot be mistaken for this one.
        pendingSocketUrl = url;
        pendingSocketEpoch = epoch;
        socketLoader.active = false;
        socketLoader.active = true;
    }

    function activatePendingSocket() {
        if (pendingSocketEpoch !== sessionEpoch || pendingSocketUrl === ""
                || !socketLoader.item)
            return false;
        const epoch = pendingSocketEpoch;
        socketLoader.item.sessionEpoch = epoch;
        socketLoader.item.url = pendingSocketUrl;
        pendingSocketUrl = "";
        pendingSocketEpoch = -1;
        socketConnectTimeout.epoch = epoch;
        socketConnectTimeout.restart();
        socketLoader.item.active = true;
        return true;
    }

    function fetchDescriptor(epoch) {
        if (descriptorRequest) {
            descriptorRequest.onreadystatechange = null;
            descriptorRequest.abort();
        }
        const xhr = new XMLHttpRequest();
        descriptorRequest = xhr;
        xhr.open("GET", host + "/.well-known/t3/environment");
        xhr.onreadystatechange = () => {
            if (xhr.readyState !== XMLHttpRequest.DONE)
                return;
            if (root.descriptorRequest === xhr) {
                root.descriptorRequest = null;
                descriptorTimeout.stop();
            }
            if (epoch !== root.sessionEpoch || xhr.status !== 200)
                return;
            try {
                const d = JSON.parse(xhr.responseText);
                root.environmentId = d.environmentId ?? "";
                root.environmentLabel = d.label ?? "";
                root.serverVersion = typeof d.serverVersion === "string"
                    ? d.serverVersion : root.serverVersion;
                if (d.capabilities && typeof d.capabilities === "object")
                    root.environmentCapabilities = Object.assign({}, d.capabilities);
            } catch (e) {
                // Optional metadata: the shell works without it, and the
                // connection attempt this rode along with reports its own
                // failures. Worth a line so a malformed descriptor is not
                // completely silent.
                console.warn("t3code: unreadable environment descriptor:", e);
            }
        };
        xhr.send();
        descriptorTimeout.epoch = epoch;
        descriptorTimeout.restart();
    }

    function scheduleRetry(epoch) {
        if (epoch !== undefined && epoch !== sessionEpoch)
            return;
        socketConnectTimeout.stop();
        dropped();
        if (socketLoader.item)
            socketLoader.item.active = false;
        if (state !== "signed-out" && state !== "cloud-empty")
            state = "offline";
        retryTimer.interval = retrySecs * 1000;
        retryTimer.epoch = sessionEpoch;
        retrySecs = Math.min(retrySecs * 2, 120);
        retryTimer.restart();
    }

    // Send a frame. No-op while the socket is not open, which is what every
    // caller wants: the protocol layer resubscribes on `opened` anyway.
    function send(text) {
        socketLoader.item?.sendText(text);
    }

    Timer {
        id: retryTimer
        property int epoch: -1
        onTriggered: {
            if (epoch === root.sessionEpoch)
                root.connect();
        }
    }

    Timer {
        id: ticketTimeout
        interval: 20000
        property int epoch: -1
        onTriggered: {
            if (epoch !== root.sessionEpoch || !root.ticketRequest)
                return;
            const request = root.ticketRequest;
            root.ticketRequest = null;
            request.onreadystatechange = null;
            request.abort();
            root.connectionError = "T3 authorization timed out";
            root.scheduleRetry(epoch);
        }
    }

    Timer {
        id: cloudTicketTimeout
        // The helper may refresh the browser session, relay JWT and environment
        // token through separate bounded requests before exchanging a ticket.
        interval: 90000
        property int epoch: -1
        onTriggered: {
            if (epoch !== root.sessionEpoch || !cloudTicketProc.running
                    || cloudTicketProc.attemptEpoch !== epoch)
                return;
            // Terminate first. onRunningChanged schedules the retry only after
            // the Process reports that this generation has fully stopped.
            cloudTicketProc.timedOutEpoch = epoch;
            cloudTicketProc.running = false;
        }
    }

    Timer {
        id: socketConnectTimeout
        interval: 20000
        property int epoch: -1
        onTriggered: {
            if (epoch !== root.sessionEpoch || root.state !== "connecting"
                    || !socketLoader.item || !socketLoader.item.active)
                return;
            root.connectionError = "T3 connection timed out";
            root.scheduleRetry(epoch);
        }
    }

    Timer {
        id: descriptorTimeout
        interval: 15000
        property int epoch: -1
        onTriggered: {
            if (epoch !== root.sessionEpoch || !root.descriptorRequest)
                return;
            const request = root.descriptorRequest;
            root.descriptorRequest = null;
            request.onreadystatechange = null;
            request.abort();
        }
    }

    // A half-open socket — typically after a suspend — never reports a close,
    // so "connected" would outlive the link indefinitely. A Ping that went
    // unanswered for over an interval recycles the connection instead.
    Timer {
        id: pingTimer
        interval: 30000
        repeat: true
        running: root.state === "connected"
        onTriggered: {
            if (Helpers.socketSilent(root.lastFrameMs, Date.now(),
                    pingTimer.interval)) {
                root.connectionError = "T3 connection stopped responding";
                root.scheduleRetry(root.sessionEpoch);
                return;
            }
            root.send(JSON.stringify({ _tag: "Ping" }));
        }
    }

    Loader {
        id: socketLoader
        source: "T3Socket.qml"
        onStatusChanged: {
            if (status === Loader.Error) {
                console.warn("t3code: QtWebSockets unavailable — install qt6-qtwebsockets-devel");
                // Not a transport failure but the same symptom — a permanently
                // off chip — and the only one the user must act on. Nothing can
                // overwrite it: connect() returns on the not-Ready branch before
                // it ever requests a ticket, the Connections block below only
                // enables while the loader is Ready, and the one line that
                // clears connectionError runs on a socket that can never open.
                root.connectionError = "QtWebSockets is not installed";
                root.pendingSocketUrl = "";
                root.pendingSocketEpoch = -1;
                retryTimer.stop();
                socketConnectTimeout.stop();
                root.state = "offline";
                return;
            }
            if (status === Loader.Ready && root.activatePendingSocket())
                return;
            // Pick up a connect() that arrived before this component finished
            // loading. retryTimer is stopped first: connect() armed it on the
            // not-ready path, and letting it fire afterwards would tear down
            // the socket this call is about to open.
            if (status === Loader.Ready && root.paired
                    && root.state !== "connected" && root.state !== "connecting") {
                retryTimer.stop();
                root.connect();
            }
        }
    }

    Connections {
        target: socketLoader.item
        enabled: socketLoader.status === Loader.Ready

        function onTextReceived(message, epoch) {
            if (epoch === root.sessionEpoch)
                root.message(message);
        }

        function onSocketStatusChanged(st, socketError, epoch) {
            if (epoch !== root.sessionEpoch)
                return;
            if (st === 1) { // open
                socketConnectTimeout.stop();
                // Cleared before the state change so no listener ever sees a
                // connected shell still carrying the failure it recovered from.
                root.connectionError = "";
                root.lastFrameMs = Date.now();
                root.state = "connected";
                root.retrySecs = 5;
                root.opened();
            } else if (st === 3 || st === 4) { // closed | error
                socketConnectTimeout.stop();
                // Qt raises the close and the error that caused it as two
                // separate transitions, in either order and with only one of
                // them carrying text (a refusal closes first, a TLS failure
                // errors first). So the reason is read on both, an empty
                // string never overwrites a real one, and the read sits
                // outside the guard below — by the time the error arrives the
                // close has often already scheduled the retry.
                const reason = Helpers.socketErrorText(socketError);
                if (reason !== "")
                    root.connectionError = reason;
                if (root.state === "connected" || root.state === "connecting")
                    root.scheduleRetry(epoch);
            }
        }
    }
}
