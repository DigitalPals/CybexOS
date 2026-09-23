pragma ComponentBehavior: Bound
pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "ProcHelpers.js" as ProcHelpers
import "Format.js" as Format
import "UsageHelpers.js" as Helpers

Singleton {
    id: root

    readonly property var supportedProviderKeys: Helpers.SUPPORTED_PROVIDER_KEYS
    // Direct mode keeps sign-in/error tabs for every supported CLI. In proxy
    // mode the server inventory is authoritative: only managed providers
    // returned by that server belong in any usage surface.
    readonly property var providerKeys: Helpers.providerKeys(
        Settings.modOpts.usage.source, data)
    readonly property var meta: ({
            claude: { name: "Claude", title: "Claude Code", icon: "claude", cmd: "claude auth login" },
            codex: { name: "Codex", title: "Codex CLI", icon: "openai", cmd: "codex login" },
            kimi: { name: "Kimi", title: "Kimi Code", icon: "kimi", cmd: "kimi login" },
            gemini: { name: "Gemini", title: "Gemini / Antigravity", icon: "gemini", cmd: "" },
            xai: { name: "xAI", title: "xAI Grok", icon: "grok", cmd: "" }
        })

    readonly property int pollIntervalSecs: Settings.pollMax
    readonly property string fetchConfiguration: {
        const opts = Settings.modOpts.usage;
        return [opts.source, opts.cliproxyUrl, opts.cliproxyTlsVerify,
            opts.sub2apiUrl, opts.sub2apiTlsVerify, opts.claudeAutoRefresh, credentialRevision].join("|");
    }
    readonly property string sourceName: Settings.modOpts.usage.source === "sub2api" ? "Sub2API" : "CLIProxyAPI"
    readonly property string dashboardUrl: Settings.modOpts.usage.source === "sub2api"
        ? Settings.modOpts.usage.sub2apiUrl : Settings.modOpts.usage.cliproxyUrl
    property int credentialRevision: 0
    property bool connectionTestPending: false
    readonly property bool connectionTestBusy: connectionTestPending || connectionTestProc.running
    property string connectionTestMessage: ""
    property bool connectionTestSucceeded: false
    property bool sub2apiKeyConfigured: false
    property bool cliproxyKeyConfigured: false
    property string credentialError: ""
    property string pendingCredentialSource: ""
    readonly property bool credentialBusy: credentialProc.running

    // The Model usage chip is the only thing that needs fresh figures without
    // being asked; with it off the bar, polling `usage-fetch.py` every few
    // minutes is pure idle churn. Settings.mods is replaced wholesale on every
    // edit, so this re-evaluates whenever the module list changes.
    readonly property bool pollEnabled: {
        const mods = Settings.mods;
        for (const col of ["left", "center", "right"]) {
            const hit = mods[col].find(m => m.id === "usage");
            if (hit)
                return hit.on;
        }
        return false;
    }

    Connections {
        target: Settings

        function onPollMaxChanged() {
            root.refresh();
        }
    }
    property var data: ({})
    property bool loading: true
    // Why the last `usage-fetch.py` run produced nothing usable, "" when it
    // worked. Distinct from a provider's own {"status": "error"} row — this
    // is the fetcher itself failing, so no provider figure is trustworthy.
    // Stays "" while the module is off: nothing is being fetched, and that
    // is not a failure.
    property string fetchError: ""
    property double updatedAt: 0
    // Seconds until the next scheduled fetch, derived from when the current
    // poll period started rather than counted down. A counter is only right
    // while something ticks it, which is why the popover used to resync on
    // open and the settings page recomputed its own copy; both now read this.
    // Anchored on the period, not on updatedAt: the timer fires on schedule
    // whether or not the fetch it started succeeded.
    property double pollStartedAt: 0
    property double countdownNow: 0
    readonly property int nextPollSecs: {
        if (!pollEnabled || pollStartedAt <= 0 || countdownNow <= 0)
            return pollIntervalSecs;
        const elapsed = Math.floor((countdownNow - pollStartedAt) / 1000);
        return Math.max(0, Math.min(pollIntervalSecs, pollIntervalSecs - elapsed));
    }

    // Only the views that show the countdown pay for a 1 Hz tick.
    property int countdownWatchers: 0

    function acquireCountdown() {
        countdownWatchers++;
        countdownNow = Date.now();
    }

    function releaseCountdown() {
        countdownWatchers = Math.max(0, countdownWatchers - 1);
    }
    property string selected: "claude"

    onProviderKeysChanged: selected = Helpers.selectedProvider(
        providerKeys, selected)

    // True when any provider exposed by the current source returned ok data.
    readonly property bool anyOk: providerKeys.some(k => data[k] && data[k].status === "ok")

    function provider(key) {
        return data[key] ?? null;
    }

    function additionalFableWindows(key) {
        return key === "claude" ? Helpers.additionalFableWindows(provider(key)) : [];
    }

    function displayWindows(key) {
        const reading = provider(key);
        return reading && reading.status === "ok"
            ? (reading.windows || []).concat(additionalFableWindows(key)) : [];
    }

    // Minimum remaining percent across any reading's windows, or -1. The
    // top-level provider follows Sub2API activity, or the best available quota
    // when activity is unknown. Account rows reuse the same calculation.
    function readingRemaining(reading) {
        if (!reading || reading.status !== "ok" || !reading.windows
                || reading.windows.length === 0)
            return -1;
        const numeric = reading.windows.filter(w => typeof w.used === "number"
            && isFinite(w.used));
        if (numeric.length === 0)
            return -1;
        return Math.round(Math.min(...numeric.map(w => 100 - w.used)));
    }

    function minRemaining(key) {
        return readingRemaining(provider(key));
    }

    function lastUsedText(record) {
        if (!record || typeof record.lastUsedAt !== "number" || record.lastUsedAt <= 0)
            return "";
        return "Last used " + Qt.formatDateTime(
            new Date(record.lastUsedAt * 1000), "yyyy-MM-dd HH:mm");
    }

    function activityText(key) {
        const record = provider(key);
        if (!record || record.selectionReason !== "last-used")
            return "";
        return record.selectedAccountLabel + " · " + lastUsedText(record)
            + (record.stale === true ? " · last known" : "");
    }

    function accountCount(key) {
        const p = provider(key);
        if (!p)
            return 0;
        if (typeof p.accountCount === "number")
            return p.accountCount;
        return Array.isArray(p.accounts) ? p.accounts.length : 0;
    }

    function availableAccountCount(key) {
        const p = provider(key);
        if (!p)
            return 0;
        if (typeof p.availableCount === "number")
            return p.availableCount;
        if (!Array.isArray(p.accounts))
            return p.status === "ok" ? 1 : 0;
        return p.accounts.filter(account => account.status === "ok").length;
    }

    // "ok" | "warn" | "crit" | "stale" | "error" | "none"
    function chipStatus(key) {
        const p = provider(key);
        if (!p)
            return "none";
        if (p.status !== "ok")
            return "error";
        const rem = minRemaining(key);
        if (rem < 0)
            return "none";
        if (p.stale === true)
            return "stale";
        if (rem <= Settings.modOpts.usage.critAt)
            return "crit";
        if (rem <= Settings.modOpts.usage.warnAt)
            return "warn";
        return "ok";
    }

    // One run may invoke Claude Code to rotate its saved OAuth token. Never
    // cancel that credential transaction or overlap it with another fetch.
    function start() {
        if (fetchProc.running)
            return;
        loading = true;
        fetchProc.running = true;
    }

    function refresh() {
        start();
        // A manual refresh from the popover still works with the module off;
        // it just must not leave the poll timer running behind its binding.
        if (pollEnabled) {
            pollStartedAt = Date.now();
            pollTimer.restart();
        }
    }

    function fetchCommand(testing = false) {
        const opts = Settings.modOpts.usage;
        const args = ["python3", Quickshell.shellDir + "/scripts/usage-fetch.py",
            "--source", opts.source];
        if (opts.source === "cliproxy") {
            args.push("--cliproxy-url", opts.cliproxyUrl);
            if (!opts.cliproxyTlsVerify)
                args.push("--cliproxy-insecure");
        } else if (opts.source === "sub2api") {
            args.push("--sub2api-url", opts.sub2apiUrl);
            if (!opts.sub2apiTlsVerify)
                args.push("--sub2api-insecure");
        } else if (!testing && opts.claudeAutoRefresh) {
            args.push("--refresh-claude");
        }
        if (testing)
            args.push("--test-connection");
        return args;
    }

    function testConnection() {
        if (connectionTestProc.running || Settings.modOpts.usage.source === "direct")
            return;
        connectionTestMessage = "";
        connectionTestPending = true;
        startConnectionTest();
    }

    function startConnectionTest() {
        if (!connectionTestPending || credentialProc.running || connectionTestProc.running)
            return;
        connectionTestPending = false;
        if (credentialError !== "") {
            connectionTestSucceeded = false;
            connectionTestMessage = credentialError;
            return;
        }
        connectionTestProc.running = true;
    }

    function checkManagementKey(source = "cliproxy") {
        if (credentialProc.running) {
            pendingCredentialSource = source;
            return;
        }
        credentialError = "";
        credentialProc.source = source;
        credentialProc.action = "status";
        credentialProc.running = true;
    }

    function saveManagementKey(key, source = "cliproxy") {
        if (credentialProc.running || key.trim() === "")
            return;
        credentialProc.source = source;
        credentialProc.action = "store";
        credentialProc.pendingKey = key;
        credentialProc.running = true;
    }

    function clearManagementKey(source = "cliproxy") {
        if (credentialProc.running)
            return;
        credentialProc.source = source;
        credentialProc.action = "clear";
        credentialProc.running = true;
    }

    function formatReset(resetsAt) {
        if (!resetsAt)
            return "";
        let s = resetsAt - Date.now() / 1000;
        if (s <= 0)
            return "now";
        const d = Math.floor(s / Format.DAY);
        const h = Math.floor((s % Format.DAY) / Format.HOUR);
        const m = Math.floor((s % Format.HOUR) / Format.MINUTE);
        if (d > 0)
            return `${d}d ${Format.pad2(h)}h`;
        if (h > 0)
            return `${h}h ${m}m`;
        return `${Math.max(1, m)}m`;
    }

    // Absolute reset moment: "14:12" within 24h, else "Aug 5, 08:00".
    function formatResetAbs(resetsAt) {
        if (!resetsAt)
            return "";
        const d = new Date(resetsAt * 1000);
        if (resetsAt - Date.now() / 1000 < 86400)
            return Qt.formatTime(d, "HH:mm");
        return Qt.formatDateTime(d, "MMM d, HH:mm");
    }

    function formatCountdown(seconds) {
        return Format.mmss(seconds);
    }

    // Everything a finished run has to say, in one place. `loading` clears
    // here whatever happened, including the case where python3 itself could
    // not be launched (ProcHelpers.NOT_STARTED) and no output ever arrived.
    function settle(exitCode, body, errText) {
        loading = false;
        if (exitCode !== 0) {
            fetchError = ProcHelpers.commandError("usage-fetch.py", exitCode, errText);
            console.warn("usage-fetch failed:", fetchError);
            return;
        }
        let parsed = null;
        try {
            parsed = JSON.parse(body);
        } catch (e) {
            console.warn("usage-fetch parse failed:", e);
        }
        if (!parsed || typeof parsed !== "object") {
            fetchError = "usage-fetch.py returned output this shell could not read";
            return;
        }
        data = parsed;
        updatedAt = Date.now();
        fetchError = "";
    }

    Process {
        id: fetchProc
        // The script prints JSON and exits 0 even when a provider is signed
        // out — a nonzero status or a silent start failure means the fetcher
        // itself broke, and its traceback is on stderr. Both streams close
        // before exited(), and the falling edge of `running` is the only
        // signal that arrives when the binary cannot be launched at all.
        //
        property string configuration: ""
        property string body: ""
        property string errText: ""
        property bool exitSeen: false
        property int lastExit: 0

        command: root.fetchCommand()

        stdout: StdioCollector {
            onStreamFinished: fetchProc.body = text
        }
        stderr: StdioCollector {
            onStreamFinished: fetchProc.errText = text
        }
        onExited: (exitCode, exitStatus) => {
            fetchProc.exitSeen = true;
            fetchProc.lastExit = exitCode;
        }
        onRunningChanged: {
            if (running) {
                configuration = root.fetchConfiguration;
                body = "";
                errText = "";
                exitSeen = false;
                lastExit = 0;
            } else {
                if (configuration !== root.fetchConfiguration) {
                    Qt.callLater(root.refresh);
                    return;
                }
                root.settle(exitSeen ? lastExit : ProcHelpers.NOT_STARTED, body, errText);
            }
        }
    }

    Process {
        id: credentialProc
        property string source: "cliproxy"
        property string action: "status"
        property string pendingKey: ""
        property string body: ""
        property bool exitSeen: false
        property int lastExit: 0

        command: ["python3", Quickshell.shellDir + "/scripts/usage-credential.py", action, "--source", source]
        stdinEnabled: action === "store"
        stdout: StdioCollector { onStreamFinished: credentialProc.body = text }
        stderr: StdioCollector {}
        onStarted: {
            if (action === "store") {
                write(pendingKey + "\n");
                pendingKey = "";
            }
        }
        onExited: (exitCode, exitStatus) => {
            exitSeen = true;
            lastExit = exitCode;
        }
        onRunningChanged: {
            if (running) {
                body = "";
                exitSeen = false;
                lastExit = 0;
                return;
            }
            pendingKey = "";
            let result = null;
            try {
                result = JSON.parse(body);
            } catch (e) {
                result = null;
            }
            const success = exitSeen && lastExit === 0 && result && result.success;
            if (success) {
                if (source === "sub2api")
                    root.sub2apiKeyConfigured = result.configured === true;
                else
                    root.cliproxyKeyConfigured = result.configured === true;
                root.credentialError = "";
                if (action !== "status")
                    root.credentialRevision++;
            } else {
                root.credentialError = result && result.error
                    ? result.error : "Could not update the private usage key.";
            }
            Qt.callLater(root.startConnectionTest);
            if (root.pendingCredentialSource !== "") {
                const nextSource = root.pendingCredentialSource;
                root.pendingCredentialSource = "";
                Qt.callLater(() => root.checkManagementKey(nextSource));
            }
        }
    }

    Process {
        id: connectionTestProc
        property string configuration: ""
        property string body: ""
        property bool exitSeen: false
        property int lastExit: 0
        command: root.fetchCommand(true)
        stdout: StdioCollector { onStreamFinished: connectionTestProc.body = text }
        stderr: StdioCollector {}
        onExited: (exitCode, exitStatus) => {
            exitSeen = true;
            lastExit = exitCode;
        }
        onRunningChanged: {
            if (running) {
                configuration = root.fetchConfiguration;
                body = "";
                exitSeen = false;
                lastExit = 0;
                return;
            }
            if (configuration !== root.fetchConfiguration)
                return;
            let result = null;
            try { result = JSON.parse(body); } catch (e) {}
            root.connectionTestSucceeded = exitSeen && lastExit === 0
                && result && result.success === true;
            root.connectionTestMessage = exitSeen && lastExit === 0 && result
                && typeof result.message === "string" ? result.message
                : "The connection test could not complete. Try again.";
            if (root.connectionTestSucceeded)
                root.refresh();
        }
    }

    Timer {
        id: pollTimer
        interval: root.pollIntervalSecs * 1000
        running: root.pollEnabled
        repeat: true
        // Switching the module back on starts a fresh period.
        onRunningChanged: {
            if (running)
                root.pollStartedAt = Date.now();
        }
        onTriggered: {
            root.pollStartedAt = Date.now();
            root.start();
        }
    }

    // Warm-up: shell.qml touches this singleton at session start so the chip
    // has figures before the first interval elapses, and the same fetch primes
    // it when the module is switched back on from the settings panel. With the
    // module off there is nothing to load and nothing left loading.
    function warmUp() {
        if (!pollEnabled) {
            loading = false;
            fetchError = "";
            return;
        }
        if (fetchProc.running)
            return;
        loading = true;
        fetchProc.running = true;
    }

    Timer {
        interval: 1000
        running: root.countdownWatchers > 0
        repeat: true
        triggeredOnStart: true
        onTriggered: root.countdownNow = Date.now()
    }

    onPollEnabledChanged: {
        if (!startupWarmUp.running)
            warmUp();
    }

    onFetchConfigurationChanged: {
        connectionTestMessage = "";
        if (Settings.loaded) {
            data = ({});
            checkManagementKey(Settings.modOpts.usage.source === "sub2api" ? "sub2api" : "cliproxy");
            refresh();
        }
    }

    // Session start: the first fetch and the private-key status check wait a
    // few seconds so they do not join the burst of every other singleton
    // starting at once. Direct mode has no management key to look up.
    Timer {
        id: startupWarmUp
        interval: 5000
        onTriggered: {
            const source = Settings.modOpts.usage.source;
            if (source !== "direct")
                root.checkManagementKey(source === "sub2api" ? "sub2api" : "cliproxy");
            root.warmUp();
        }
    }

    Component.onCompleted: {
        // With the module off there is nothing to wait for: settle at once.
        if (!pollEnabled)
            warmUp();
        startupWarmUp.start();
    }
}
