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
    // An unresolved reset spend blocks further resets: at least an amber badge.
    readonly property int resetReviews: accounts.filter(a => a.bankedReview).length
    readonly property string faultLevel: {
        const level = Helpers.faultLevel(faults);
        return level === "ok" && resetReviews > 0 ? "warn" : level;
    }
    readonly property bool resetsEnabled: overview !== null && overview.bankedResets === true
    readonly property string barValue: Helpers.barValue(options.metric, figures, faults)
    readonly property var startedAt: overview ? overview.startedAt : null

    // Breaker actions: one at a time, and only the latest result is kept.
    readonly property bool actionBusy: actionRequest.running
    property string actionAccount: ""
    property string actionName: ""
    property var actionResult: null
    // Account details, fetched when an account is expanded: id -> { at, sessions, series, error }.
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
        activity = ({}); actionResult = null; resets = ({});
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

    // ---- banked resets ----------------------------------------------------
    // Per account: { view, fetchedAt, error, uncertain, message, dialog }, where a
    // dialog is { action: redeem | retry | resolve, request, grant, inventory,
    // startedAt }. Spending is only ever a click on a confirmation in the
    // dashboard view; there is deliberately no IPC or command for it.
    property var resets: ({})
    property string resetAccount: ""
    property string resetOperation: ""
    readonly property bool resetBusy: resetRequest.running

    function resetState(id) {
        return resets[id] || null;
    }

    function patchReset(id, change) {
        const next = Object.assign({}, resets);
        next[id] = Object.assign({}, resets[id] || {}, change);
        resets = next;
    }

    function runReset(id, operation, command) {
        if (resetRequest.running || !keySaved || !url)
            return false;
        resetAccount = id;
        resetOperation = operation;
        patchReset(id, { error: "" });
        resetRequest.command = ["python3", "-B", script].concat(command);
        resetRequest.running = true;
        return true;
    }

    // Reads status (Fusebox asks the provider; nothing is spent).
    function loadReset(id) {
        runReset(id, "load", ["banked", "--url", url, id]);
    }

    function refreshReset(id) {
        runReset(id, "refresh", ["banked-refresh", "--url", url, id]);
    }

    // "Use 1 reset" reads status again, then confirms against exactly that
    // inventory and its quote, as Fusebox's own dialog does.
    function beginRedeem(id) {
        runReset(id, "open", ["banked", "--url", url, id]);
    }

    function beginRecovery(id, action) {
        const state = resetState(id);
        const op = state && state.view ? state.view.operation : null;
        if (!op || !op.requestId || resetRequest.running)
            return;
        patchReset(id, { dialog: { action: action, request: op.requestId, grant: "", startedAt: Date.now() },
            error: "", message: "" });
    }

    function chooseResetGrant(id, grant) {
        const state = resetState(id);
        if (state && state.dialog && state.dialog.action === "redeem")
            patchReset(id, { dialog: Object.assign({}, state.dialog, { grant: grant }) });
    }

    function cancelReset(id) {
        patchReset(id, { dialog: null });
    }

    // The only path that spends: the confirmation's own button.
    function confirmReset(id, resolution) {
        const state = resetState(id);
        const d = state ? state.dialog : null;
        if (!d)
            return;
        const action = d.action === "resolve" ? resolution : d.action;
        if (["redeem", "retry", "resolve-used", "resolve-unused"].indexOf(action) === -1)
            return;
        if (d.action === "redeem" && Helpers.quoteLeft(d.startedAt, Date.now()) <= 0) {
            expireReset(id);
            return;
        }
        const command = ["banked-action", "--url", url, "--action", action, "--request", d.request];
        if (d.grant)
            command.push("--grant", d.grant);
        command.push(id);
        runReset(id, "confirm", command);
    }

    function expireReset(id) {
        const state = resetState(id);
        patchReset(id, { dialog: null, view: state && state.view ? Object.assign({}, state.view, { quote: null }) : null,
            error: "The confirmation expired. Refresh to try again." });
    }

    function resetDone(code, body, failure) {
        const id = resetAccount;
        const operation = resetOperation;
        let reply = null;
        try {
            reply = JSON.parse(body);
        } catch (e) {
            reply = null;
        }
        const ok = code === 0 && reply !== null && reply.ok === true && reply.view;
        if (operation === "confirm") {
            if (ok) {
                const op = reply.view.operation;
                patchReset(id, { view: reply.view, fetchedAt: Date.now(), dialog: null, uncertain: false,
                    message: op && op.message ? op.message : "" });
                return;
            }
            // Never resend. Show what happened, then read the status again.
            const uncertain = code === 124 || !reply || reply.state === "uncertain";
            const state = resetState(id);
            patchReset(id, { dialog: null, uncertain: uncertain, message: "",
                view: state && state.view ? Object.assign({}, state.view, { quote: null }) : null,
                error: uncertain ? "The reset request didn't finish, so a reset may have been used. Checking its status…"
                    : privateText(reply.error) + " Refresh the status before continuing." });
            Qt.callLater(() => loadReset(id));
            return;
        }
        if (!ok) {
            patchReset(id, { error: code === 124 ? "Fusebox took too long to answer."
                : reply && reply.error ? privateText(reply.error) : failure ? "The request didn't complete." : "Couldn't read reset status." });
            return;
        }
        const now = Date.now();
        const change = { view: reply.view, fetchedAt: now };
        if (operation === "open") {
            const account = accountById(id);
            const block = account ? Helpers.resetBlock(reply.view, account, now) : "Unknown account.";
            const grants = Helpers.usableGrants(reply.view);
            // Codex picks its grant on the provider side, so it may list none.
            if (block === "" && (grants.length > 0 || account.provider === "codex")) {
                const selected = reply.view.inventory.selectedGrant;
                change.dialog = { action: "redeem", request: reply.view.quote, inventory: reply.view.inventory,
                    startedAt: now,
                    // Codex chooses its own grant; Claude defaults to the provider's choice.
                    grant: account.provider === "codex" ? ""
                        : grants.some(g => g.id === selected) ? selected : grants.length ? grants[0].id : "" };
                change.message = "";
            } else {
                change.error = block || "No reset can be used right now.";
            }
        }
        patchReset(id, change);
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
            ? { at: Date.now(), sessions: reply.sessions, series: Array.isArray(reply.series) ? reply.series : [], error: "" }
            : { at: Date.now(), sessions: [], series: [],
                error: reply && reply.error ? reply.error : "Couldn't load sessions." };
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
                resetReviews: root.resetReviews,
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
            // A confirmation Fusebox would refuse is withdrawn here first.
            for (const id in root.resets) {
                const d = root.resets[id].dialog;
                if (d && d.action === "redeem" && Helpers.quoteLeft(d.startedAt, root.now) <= 0)
                    root.expireReset(id);
            }
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
        id: resetRequest
        // A spend waits for Fusebox's provider calls; the helper itself gives up
        // at 90 seconds and reports that outcome as uncertain.
        timeoutMs: 100000
        timeoutMessage: "Fusebox took too long to answer."
        onCompleted: (code, body, failure) => root.resetDone(code, body, failure)
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
