pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "FuseboxHelpers.js" as Helpers
import "ExternalUrl.js" as ExternalUrl

// One live connection to a Fusebox server for the whole shell, whatever the
// monitor count. scripts/fusebox.py owns the WebSocket, its reconnects and the
// management key, and prints allowlisted JSON lines; this keeps the state the
// chip, the dashboard, Settings and IPC read. Breaker actions and account
// details are one-shot requests; nothing is retried behind the user's back.
Singleton {
    id: root

    readonly property var options: Settings.modOpts.fusebox
    readonly property string url: options.url
    readonly property bool hideEmails: options.hideEmails
    readonly property string quotaDisplay: options.quotaDisplay
    readonly property string host: url.replace(/^https?:\/\//i, "").replace(/\/+$/, "")
    readonly property bool widgetOn: ["left", "center", "right"].some(
        column => Settings.mods[column].some(entry => entry.id === "fusebox" && entry.on))
    property int watchers: 0
    readonly property bool active: widgetOn || watchers > 0
    // key-status has answered at least once, and what it said.
    property bool keyKnown: false
    property bool keySaved: false
    property string keyNotice: ""
    readonly property bool keyBusy: keyRequest.running
    readonly property bool wanted: url !== "" && keySaved && active
    readonly property string script: Quickshell.shellDir + "/scripts/fusebox.py"

    // The helper's connection state: connecting, live, offline, auth, setup or unsupported.
    property string linkState: ""
    property string error: ""
    property var overview: null
    property var accounts: []
    property var load: ({})
    property var faults: []
    // "server" from /api/faults, or "accounts" when an older Fusebox makes the
    // widget work out what it can from account state.
    property string faultSource: ""
    property var requests: []
    property var series: []
    property var totals: null
    property int serving: 0
    property double updatedAt: 0
    property double heartbeat: 0
    property double now: Date.now()
    property int failures: 0
    property var seenFaultKeys: []
    property bool faultsSeeded: false

    readonly property bool hasData: overview !== null
    readonly property string connection: {
        if (!url || (keyKnown && !keySaved) || linkState === "setup")
            return "setup";
        if (linkState === "auth")
            return "auth";
        if (linkState === "live" && worker.running)
            return "live";
        if (error)
            return "offline";
        return "connecting";
    }
    readonly property string status: ({ setup: "Set up", auth: "Key rejected", live: "Live",
        offline: "Offline", connecting: "Connecting…" })[connection]
    readonly property bool stale: hasData && connection !== "live"
    readonly property var figures: Helpers.figures(series, requests, serving, now, load)
    readonly property string faultLevel: Helpers.faultLevel(faults)
    readonly property string barValue: Helpers.barValue(options.metric, figures, faults)
    readonly property var startedAt: overview ? overview.startedAt : null

    // Breaker actions: one at a time, and only the latest result is kept.
    readonly property bool actionBusy: actionRequest.running
    property string actionAccount: ""
    property string actionName: ""
    property var actionResult: null
    // Account details, fetched when an account is expanded: id -> { at, sessions, error }.
    property var activity: ({})
    property string activityAccount: ""
    property string queuedActivity: ""

    // Opening a view also rechecks the key, which may have been saved or
    // removed outside this shell.
    function acquire() {
        watchers++;
        checkKey();
    }
    function release() { watchers = Math.max(0, watchers - 1); }

    function configure() {
        Settings.openWidgetSettings("fusebox");
        Settings.showPanel("bar", Popouts.hostScreenName);
    }

    function setQuotaDisplay(mode) {
        if (mode !== quotaDisplay)
            Settings.setModuleOption("fusebox", "quotaDisplay", mode);
    }

    function accountName(a) {
        return Helpers.accountName(a, accounts, hideEmails);
    }

    function accountById(id) {
        return accounts.find(a => a.id === id) || null;
    }

    function privateText(text) {
        return hideEmails ? Helpers.maskEmails(text) : String(text || "");
    }

    function openDashboard(path) {
        const safe = ExternalUrl.safeHttpUrl(Helpers.dashboardUrl(url, path || ""));
        if (safe !== "")
            Quickshell.execDetached(["xdg-open", safe]);
    }

    function clearData() {
        overview = null; accounts = []; load = ({}); faults = []; faultSource = "";
        requests = []; series = []; totals = null; serving = 0; updatedAt = 0;
        activity = ({}); actionResult = null;
    }

    function start() {
        if (!wanted || worker.running)
            return;
        retry.stop();
        worker.issuedUrl = url;
        worker.command = ["python3", "-B", script, "live", "--url", url];
        worker.running = true;
    }

    // Reconnect now: a new helper fetches a fresh snapshot.
    function refresh() {
        failures = 0;
        checkKey();
        if (worker.running) {
            worker.restarting = true;
            worker.running = false;
        } else {
            Qt.callLater(start);
        }
    }

    function receive(line) {
        if (!wanted || worker.issuedUrl !== url)
            return;
        let message;
        try {
            if (line.length > 4194304)
                throw new Error("too large");
            message = JSON.parse(line);
        } catch (e) {
            error = "The Fusebox helper sent something unreadable; reconnecting…";
            worker.running = false;
            return;
        }
        now = Date.now();
        heartbeat = now;
        switch (message.type) {
        case "state":
            linkState = message.state;
            error = message.state === "live" ? "" : message.message || "";
            if (message.state === "live")
                failures = 0;
            return;
        case "overview":
            overview = message.data;
            series = Helpers.trimSeries(message.data.series, now);
            totals = message.data.totals;
            serving = message.data.active;
            break;
        case "accounts":
            accounts = message.data;
            break;
        case "faults":
            takeFaults(message.data, message.source);
            break;
        case "load":
            load = message.data;
            break;
        case "requests":
            requests = message.data;
            break;
        case "request":
            requests = [message.data].concat(requests.filter(r => r.id !== message.data.id)).slice(0, 40);
            series = Helpers.applyRequest(series, message.data, now);
            break;
        case "tick":
            totals = message.totals;
            serving = message.active;
            break;
        default:
            return;
        }
        updatedAt = now;
    }

    function takeFaults(list, source) {
        const fresh = faultsSeeded ? Helpers.newFaults(seenFaultKeys, list) : [];
        faults = list;
        faultSource = source;
        seenFaultKeys = list.map(f => f.key);
        faultsSeeded = true;
        if (options.notify)
            fresh.forEach(notify);
    }

    function notify(f) {
        const a = accountById(f.accountId);
        const who = a ? accountName(a) : f.providerName;
        const body = [who, privateText(f.detail), Helpers.faultTiming(f, Date.now())]
            .filter(part => part).join(" · ");
        Quickshell.execDetached(["notify-send", "--app-name=Fusebox",
            "--urgency=" + (f.level === "err" ? "critical" : "normal"), f.title, body]);
    }

    // ---- the management key --------------------------------------------
    function checkKey() {
        if (keyRequest.running)
            return;
        keyRequest.operation = "status";
        keyRequest.inputText = "";
        keyRequest.stdinEnabled = false;
        keyRequest.command = ["python3", "-B", script, "key-status"];
        keyRequest.running = true;
    }

    function storeKey(text) {
        const key = String(text || "").trim();
        if (keyRequest.running || key === "")
            return;
        keyNotice = "";
        keyRequest.operation = "store";
        // The key goes over stdin, never argv, and is dropped as soon as it is written.
        keyRequest.stdinEnabled = true;
        keyRequest.inputText = key + "\n";
        keyRequest.command = ["python3", "-B", script, "store-key"];
        keyRequest.running = true;
    }

    function forgetKey() {
        if (keyRequest.running)
            return;
        keyNotice = "";
        keyRequest.operation = "forget";
        keyRequest.stdinEnabled = false;
        keyRequest.inputText = "";
        keyRequest.command = ["python3", "-B", script, "forget-key"];
        keyRequest.running = true;
    }

    function keyDone(code, body) {
        const operation = keyRequest.operation;
        keyRequest.inputText = "";
        let reply = null;
        try {
            reply = JSON.parse(body);
        } catch (e) {
            reply = null;
        }
        if (!reply) {
            keyNotice = "The key helper didn't answer.";
            return;
        }
        if (operation === "status") {
            keyKnown = true;
            keySaved = reply.saved === true;
            if (reply.error)
                keyNotice = reply.error;
            return;
        }
        if (code !== 0) {
            keyNotice = reply.error || "The key couldn't be saved.";
            return;
        }
        keyKnown = true;
        keySaved = reply.saved === true;
        keyNotice = operation === "store" ? "Key saved" : "Key removed";
        if (operation === "store") {
            linkState = "";
            error = "";
            refresh();
        } else {
            clearData();
        }
    }

    // ---- breaker actions and account details ----------------------------
    function runAction(accountId, name, disabled) {
        if (actionRequest.running || !keySaved || !url)
            return;
        actionAccount = accountId;
        actionName = name;
        actionResult = null;
        const command = ["python3", "-B", script, "action", "--url", url, name, accountId];
        if (name === "toggle")
            command.push("--disabled", disabled ? "true" : "false");
        actionRequest.command = command;
        actionRequest.running = true;
    }

    function actionDone(code, body, failure) {
        let reply = null;
        try {
            reply = JSON.parse(body);
        } catch (e) {
            reply = null;
        }
        actionResult = {
            account: actionAccount, name: actionName, at: Date.now(),
            ok: code === 0 && reply !== null && reply.ok === true,
            error: code === 124 ? "Fusebox took too long to answer."
                : reply && reply.error ? privateText(reply.error)
                : code === 0 ? "" : failure ? "The request didn't complete." : "The request failed."
        };
        // Fusebox broadcasts the account change; the live helper refetches.
        if (actionResult.ok && actionAccount === activityAccount)
            loadActivity(actionAccount);
    }

    function loadActivity(accountId) {
        if (!keySaved || !url)
            return;
        if (activityRequest.running) {
            queuedActivity = accountId;
            return;
        }
        activityAccount = accountId;
        activityRequest.command = ["python3", "-B", script, "activity", "--url", url, accountId];
        activityRequest.running = true;
    }

    function activityDone(code, body) {
        let reply = null;
        try {
            reply = JSON.parse(body);
        } catch (e) {
            reply = null;
        }
        const next = Object.assign({}, activity);
        next[activityAccount] = reply && Array.isArray(reply.sessions)
            ? { at: Date.now(), sessions: reply.sessions, error: "" }
            : { at: Date.now(), sessions: [], error: reply && reply.error ? reply.error : "Couldn't load sessions." };
        activity = next;
    }

    onUrlChanged: {
        clearData();
        linkState = ""; error = ""; failures = 0;
        // Another server's faults are not news about this one.
        seenFaultKeys = []; faultsSeeded = false;
        retry.stop();
        if (worker.running)
            worker.running = false;
        else
            Qt.callLater(start);
    }
    onWantedChanged: {
        if (wanted)
            Qt.callLater(start);
        else {
            retry.stop();
            worker.running = false;
        }
    }
    onActiveChanged: if (active && !keyKnown) checkKey()
    Component.onCompleted: {
        if (active)
            checkKey();
    }

    IpcHandler {
        target: "fusebox"
        function status(): string {
            // Counts and states only: never the key, and no account names.
            return JSON.stringify({ url: root.url, connection: root.connection, status: root.status,
                state: root.linkState, error: root.error, keySaved: root.keySaved, running: worker.running,
                watchers: root.watchers, updatedAt: root.updatedAt, version: root.overview ? root.overview.version : null,
                accounts: root.accounts.length, faults: root.faults.length, faultSource: root.faultSource,
                sessions: root.figures.sessions, serving: root.serving, metric: root.options.metric,
                value: root.barValue });
        }
        function refresh(): void { root.refresh(); }
        function configure(): void { root.configure(); }
    }

    Timer {
        id: retry
        onTriggered: root.start()
    }
    Timer {
        interval: 1000
        running: root.wanted
        repeat: true
        onTriggered: {
            root.now = Date.now();
            // The helper prints at least every five seconds while it runs.
            if (worker.running && root.now - root.heartbeat > 30000) {
                root.error = "The Fusebox helper stopped responding; reconnecting…";
                worker.running = false;
            }
        }
    }
    Process {
        id: worker
        property string issuedUrl: ""
        property string diagnostic: ""
        // Stopped on purpose, to start again at once.
        property bool restarting: false
        stdout: SplitParser { onRead: data => root.receive(data) }
        stderr: SplitParser {
            onRead: data => { if (data.trim()) worker.diagnostic = data.trim().slice(0, 240); }
        }
        onExited: code => {
            // 2: the URL can't be used; a new one starts a new helper.
            if (code === 2 && root.linkState === "setup")
                worker.issuedUrl = "";
        }
        onRunningChanged: {
            if (running) {
                diagnostic = "";
                root.heartbeat = Date.now();
                return;
            }
            if (!root.wanted || root.linkState === "setup" && issuedUrl === "") {
                restarting = false;
                return;
            }
            if (restarting || issuedUrl !== root.url) {
                restarting = false;
                retry.interval = 1;
            } else {
                if (!root.error)
                    root.error = "The Fusebox helper stopped. Retrying…";
                root.failures++;
                retry.interval = Math.min(60000, 5000 * Math.pow(2, Math.min(root.failures - 1, 4)));
            }
            retry.restart();
        }
    }
    CommandRequest {
        id: keyRequest
        property string operation: ""
        timeoutMs: 10000
        timeoutMessage: "The key helper timed out."
        onCompleted: (code, body) => root.keyDone(code, body)
    }
    CommandRequest {
        id: actionRequest
        timeoutMs: 60000
        timeoutMessage: "Fusebox took too long to answer."
        onCompleted: (code, body, failure) => root.actionDone(code, body, failure)
    }
    CommandRequest {
        id: activityRequest
        timeoutMs: 15000
        onCompleted: (code, body) => root.activityDone(code, body)
        onAvailable: {
            if (root.queuedActivity !== "") {
                const next = root.queuedActivity;
                root.queuedActivity = "";
                Qt.callLater(() => root.loadActivity(next));
            }
        }
    }
}
