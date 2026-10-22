pragma Singleton
import QtQuick
import Quickshell

// Loopback WebSocket transport for hermes-menubar-bridge. Authentication,
// replay and Hermes process ownership live in the bridge; this layer owns only
// one socket generation and bounded reconnect/backoff.
Singleton {
    id: root

    readonly property SocketContract socket: socketLoader.item as SocketContract

    // "connecting" | "connected" | "offline" | "disabled"
    property string state: "offline"
    property string connectionError: ""
    // The next retry's delay. It doubles with every failed attempt and starts
    // over only once a link has stayed up (stableTimer) or the user asks
    // (reconnect), never merely because the socket opened: a bridge that
    // accepts and then drops would otherwise be retried every two seconds.
    property int retrySecs: 2
    property int generation: 0

    // Whether anything wants the bridge. The bar module is the one consumer
    // that needs it unasked; with the module off, a socket (or a retry every
    // minute for an absent bridge) is pure idle churn, and merely
    // constructing this singleton (Settings → About) must not connect. The
    // panel still connects while it is open. Settings.mods is replaced
    // wholesale on every edit, so this re-evaluates with the module list.
    readonly property bool enabled: {
        const mods = Settings.mods;
        for (const col of ["left", "center", "right"]) {
            if (mods[col].some(m => m.id === "hermes" && m.on))
                return true;
        }
        return Popouts.open && Popouts.currentName === "hermes";
    }
    // There is no settings key for the address: normalizeModOpts keeps only
    // the hermes options it validates, so the environment is the override.
    readonly property string endpoint: {
        const rawEnvironment = Quickshell.env("HERMES_MENUBAR_WS_URL");
        const environment = typeof rawEnvironment === "string"
            ? rawEnvironment.trim() : "";
        return environment !== "" ? environment : "ws://127.0.0.1:9120/ws";
    }
    readonly property bool websocketsMissing: socketLoader.status === Loader.Error
    readonly property int retryInSecs: retryTimer.running
        ? Math.max(1, Math.ceil(retryTimer.interval / 1000)) : 0

    signal message(string text)
    signal opened()
    signal dropped()

    function friendlyError(value) {
        const text = typeof value === "string" ? value.trim() : "";
        if (text === "")
            return "Hermes bridge is unavailable";
        if (/refused/i.test(text))
            return "Hermes bridge is not running";
        if (/host not found|name or service/i.test(text))
            return "Hermes bridge address was not found";
        if (/ssl|certificate|tls/i.test(text))
            return "Hermes bridge TLS failed";
        return text.length > 180 ? text.slice(0, 177) + "…" : text;
    }

    function connect() {
        if (!enabled) {
            disconnect();
            state = "disabled";
            return;
        }
        if (websocketsMissing) {
            state = "offline";
            return;
        }
        if (socketLoader.status !== Loader.Ready) {
            state = "offline";
            if (!retryTimer.running)
                scheduleRetry(false);
            return;
        }
        if (state === "connected" || state === "connecting")
            return;
        generation++;
        retryTimer.stop();
        // Keep the optional type's Loader stable. Rebuilding it from its own
        // Ready handler is re-entrant, and a same-frame off/on pair can also
        // lose the replacement item's activation. The generation guard below
        // is sufficient to reject every late status/frame from the old attempt.
        state = "connecting";
        socketLoader.item.active = false;
        socketLoader.item.generation = generation;
        socketLoader.item.url = endpoint;
        connectTimeout.generation = generation;
        connectTimeout.restart();
        socketLoader.item.active = true;
    }

    function disconnect() {
        retryTimer.stop();
        connectTimeout.stop();
        stableTimer.stop();
        const wasLive = state === "connected" || state === "connecting";
        generation++;
        state = enabled ? "offline" : "disabled";
        if (socketLoader.item)
            socketLoader.item.active = false;
        if (wasLive)
            dropped();
    }

    function reconnect() {
        disconnect();
        retrySecs = 2;
        connectionError = "";
        if (enabled)
            connectDelay.restart();
    }

    function scheduleRetry(emitDrop) {
        connectTimeout.stop();
        stableTimer.stop();
        if (emitDrop === true)
            dropped();
        // Publish offline before deactivating the WebSocket. Its synchronous
        // Closed signal then cannot schedule a nested retry.
        state = enabled ? "offline" : "disabled";
        if (socketLoader.item)
            socketLoader.item.active = false;
        // Unattended, nobody would see another attempt: leave the timer off
        // and let Activity.resumed start it. The bridge is on loopback, so
        // the network state is no reason to wait.
        if (!enabled || Activity.idle)
            return;
        retryTimer.interval = retrySecs * 1000;
        retrySecs = Math.min(60, retrySecs * 2);
        retryTimer.restart();
    }

    function send(text) {
        if (state !== "connected" || !socketLoader.item)
            return false;
        socket.sendText(text);
        return true;
    }

    onEnabledChanged: enabled ? reconnect() : disconnect()

    Component.onCompleted: connectDelay.restart()

    Timer {
        id: connectDelay
        interval: 1
        onTriggered: root.connect()
    }

    Timer {
        id: retryTimer
        // Idleness that began while this was pending: onResumed connects.
        onTriggered: {
            if (!Activity.idle)
                root.connect();
        }
    }

    Timer {
        id: stableTimer
        interval: 60000
        property int generation: -1
        onTriggered: {
            if (generation === root.generation && root.state === "connected")
                root.retrySecs = 2;
        }
    }

    Timer {
        id: connectTimeout
        interval: 10000
        property int generation: -1
        onTriggered: {
            if (generation !== root.generation || root.state !== "connecting")
                return;
            root.connectionError = "Hermes bridge connection timed out";
            root.scheduleRetry(true);
        }
    }

    Loader {
        id: socketLoader
        source: "HermesSocket.qml"
        onStatusChanged: {
            if (status === Loader.Error) {
                retryTimer.stop();
                connectTimeout.stop();
                root.connectionError = "QtWebSockets is not installed";
                root.state = "offline";
                console.warn("hermes: QtWebSockets unavailable — install qt6-qtwebsockets-devel");
            } else if (status === Loader.Ready) {
                // Defer out of Loader's synchronous status callback. The same
                // timer also coalesces this with Component.onCompleted.
                if (root.enabled && root.state !== "connected"
                        && root.state !== "connecting") {
                    retryTimer.stop();
                    connectDelay.restart();
                }
            }
        }
    }

    // Back at the machine: a link that is down gets its attempt now, whether
    // idleness held the retry back or a long backoff is still running.
    // `idle` itself is not read here; it may not have settled yet.
    Connections {
        target: Activity

        function onResumed() {
            if (!root.enabled || root.state !== "offline" || root.websocketsMissing)
                return;
            retryTimer.stop();
            root.connect();
        }
    }

    Connections {
        target: socketLoader.item
        enabled: socketLoader.status === Loader.Ready

        function onTextReceived(text, generation) {
            if (generation === root.generation)
                root.message(text);
        }

        function onSocketStatusChanged(status, socketError, generation) {
            if (generation !== root.generation)
                return;
            if (status === 1) {
                connectTimeout.stop();
                root.connectionError = "";
                root.state = "connected";
                stableTimer.generation = generation;
                stableTimer.restart();
                root.opened();
            } else if (status === 3 || status === 4) {
                connectTimeout.stop();
                if (socketError !== "")
                    root.connectionError = root.friendlyError(socketError);
                if (root.state === "connected" || root.state === "connecting")
                    root.scheduleRetry(true);
            }
        }
    }
}
