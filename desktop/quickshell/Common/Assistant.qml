pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "AssistantHelpers.js" as AssistantHelpers

// The shell's side of the NerdOS Assistant (docs/assistant.md). The
// nerdos-assistant user service owns the agent processes and every turn, so
// a reload of this shell never ends one; this singleton is its client. It
// owns what only the desktop can know: where the character stands, whether
// its box is open, push-to-talk through Voxtype, and the one screenshot a
// question may carry.
Singleton {
    id: root

    // ---- availability ------------------------------------------------------
    readonly property bool available: Settings.assistantConfigured
    readonly property string runtimeDir:
        (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/nerdos"
    readonly property string socketPath: runtimeDir + "/assistant.sock"
    readonly property string scratchDir: runtimeDir + "/assistant"
    readonly property string home: Quickshell.env("HOME") || ""

    // ---- service state -------------------------------------------------------
    readonly property bool connected: socket.connected && helloed
    property bool helloed: false
    property var agents: ({})
    property bool speechAvailable: false
    property var turn: null
    // Whether the service holds a conversation the next question continues.
    property var conversation: null
    // The `nerd agent` default, which "auto" follows.
    property string preferredAgent: ""

    readonly property string agent: AssistantHelpers.resolveAgent(
        Settings.assistantAgent, agents, preferredAgent)
    readonly property string agentLabel: AssistantHelpers.AGENT_LABELS[agent] || agent
    readonly property bool agentInstalled: !!(agents[agent] && agents[agent].available)
    readonly property bool agentReady: agentInstalled && agents[agent].auth === "ready"
    readonly property bool setupRequired: !agentReady
    property bool authChecking: false
    property string signingIn: ""

    readonly property bool busy: AssistantHelpers.active(turn)
    readonly property bool waiting: turn !== null && turn.status === "waiting"
    readonly property var approvals: turn && turn.approvals ? turn.approvals : []
    readonly property bool hasReply: AssistantHelpers.finished(turn)

    // ---- presence and placement --------------------------------------------
    // The character is out unless game mode wants the screen to itself.
    readonly property bool shown: available && Settings.assistantShown && !GameMode.active
    readonly property ShellScreen screen: Screens.byName(Settings.assistantScreen) ?? Screens.focused
    readonly property string screenName: screen ? screen.name : ""

    // ---- box state -----------------------------------------------------------
    property bool composing: false
    // The box was opened by the keyboard or a click, so it takes the keyboard.
    property bool focusRequested: false
    property string draft: ""
    // Clicking the character while it works tucks the box away.
    property bool tucked: false
    property bool replyOpen: false
    property bool unread: false
    property bool celebrating: false
    property string notice: ""
    property bool dragging: false
    readonly property bool failed: turn !== null && turn.status === "failed" && replyOpen

    readonly property string mood: AssistantHelpers.mood({
        connected: root.connected, listening: root.listening, waiting: root.waiting,
        busy: root.busy, transcribing: root.transcribing, dragging: root.dragging,
        speaking: root.speaking, celebrating: root.celebrating, failed: root.failed,
        composing: root.composing
    })

    // ---- voice ---------------------------------------------------------------
    // Voxtype runs on every installation; Dictation watches its state for us.
    readonly property bool voiceAvailable: available && !Dictation.stateMissing
    property bool listening: false
    property bool transcribing: false
    // A tap on the microphone latches it; a held key or press does not.
    property bool voiceLatched: false
    property bool sendAfterTranscript: false
    property double listenStartedAt: 0
    readonly property string transcriptPath: scratchDir + "/voice.txt"

    // ---- screen context ------------------------------------------------------
    property bool capturing: false
    // A suggestion about the screen waits for its screenshot.
    property string pendingScreenQuestion: ""
    property bool screenAttached: false
    property string screenPath: ""
    property string screenOutput: ""

    // ---- speech ----------------------------------------------------------------
    property bool speaking: false
    property string speechId: ""
    property int speechIndex: 0
    property int speechCount: 0

    // ---- Super+I --------------------------------------------------------------
    property bool shortcutHolding: false

    signal focusComposer()

    // ---- presence ------------------------------------------------------------
    function show(outputName) {
        if (!available)
            return;
        if (outputName && outputName !== Settings.assistantScreen && Screens.byName(outputName))
            moveTo(outputName, Settings.assistantX, Settings.assistantY);
        else if (Settings.assistantScreen === "" && screen)
            Settings.set("assistantScreen", screen.name);
        Settings.set("assistantShown", true);
        // Brought back for a reply that finished while it was away.
        if (unread && hasReply && !busy) {
            unread = false;
            replyOpen = true;
        }
    }

    function hide() {
        if (listening)
            cancelListening();
        closeBox();
        Settings.set("assistantShown", false);
    }

    function toggleShown(outputName) {
        if (Settings.assistantShown)
            hide();
        else
            show(outputName);
    }

    function moveTo(outputName, x, y) {
        if (outputName !== Settings.assistantScreen)
            Settings.set("assistantScreen", outputName);
        if (x !== Settings.assistantX)
            Settings.set("assistantX", Math.round(x));
        if (y !== Settings.assistantY)
            Settings.set("assistantY", Math.round(y));
    }

    // ---- the box -------------------------------------------------------------
    function openComposer(withFocus) {
        if (!available)
            return;
        if (!Settings.assistantShown)
            show(Screens.focused ? Screens.focused.name : "");
        tucked = false;
        if (busy)
            return;
        composing = true;
        if (withFocus) {
            focusRequested = true;
            focusComposer();
        }
    }

    function toggleComposer() {
        if (composing && focusRequested && !listening)
            closeComposer();
        else if (busy && Settings.assistantShown)
            tucked = !tucked;
        else
            openComposer(true);
    }

    function closeComposer() {
        composing = false;
        focusRequested = false;
        notice = "";
    }

    // The empty box a hover opened closes again once the pointer leaves.
    function hoverEnded() {
        if (composing && !focusRequested && draft.trim() === "" && !listening
                && !transcribing && !screenAttached && !capturing)
            closeComposer();
    }

    function closeReply() {
        replyOpen = false;
        unread = false;
        stopSpeaking();
    }

    function closeBox() {
        closeComposer();
        closeReply();
    }

    function characterClicked() {
        if (unread && hasReply) {
            unread = false;
            closeComposer();
            replyOpen = true;
            return;
        }
        unread = false;
        if (busy) {
            tucked = !tucked;
            return;
        }
        if (composing && focusRequested && draft.trim() === "")
            closeComposer();
        else
            openComposer(true);
    }

    function reply() {
        closeReply();
        openComposer(true);
    }

    // ---- Super+I: tap to type, hold to talk ------------------------------------
    function shortcutPressed() {
        if (!available)
            return;
        if (listening) {
            stopListening(true);
            return;
        }
        shortcutHolding = true;
        holdTimer.restart();
    }

    function shortcutReleased() {
        if (holdTimer.running) {
            holdTimer.stop();
            shortcutHolding = false;
            toggleComposer();
            return;
        }
        if (shortcutHolding && listening && !voiceLatched)
            stopListening(true);
        shortcutHolding = false;
    }

    Timer {
        id: holdTimer
        interval: AssistantHelpers.HOLD_MS
        onTriggered: {
            if (root.voiceAvailable && !root.busy) {
                root.openComposer(false);
                root.startListening(false);
            } else {
                root.shortcutHolding = false;
                root.toggleComposer();
            }
        }
    }

    // ---- asking ----------------------------------------------------------------
    function send(text) {
        const prompt = String(text === undefined ? draft : text).trim();
        if (prompt === "" || busy)
            return;
        if (!connected) {
            notice = I18n.tr("The assistant service is not running.");
            return;
        }
        if (!agentReady) {
            draft = prompt;
            openComposer(true);
            refreshAuth();
            return;
        }
        stopSpeaking();
        const params = {
            text: prompt,
            agent: root.agent,
            model: AssistantHelpers.modelFor(root.agent, Settings.assistantClaudeModel,
                Settings.assistantCodexModel),
            screenshot: screenAttached ? screenPath : "",
            context: { output: screenName, speak: Settings.assistantSpeak, language: I18n.language }
        };
        // The service owns the screenshot from here and deletes it.
        const shot = screenAttached ? screenPath : "";
        screenAttached = false;
        screenPath = "";
        draft = "";
        notice = "";
        composing = false;
        focusRequested = false;
        replyOpen = false;
        tucked = false;
        unread = false;
        request("turn.start", params, (result, error) => {
            if (error) {
                // Refused before the service took the screenshot: remove it
                // here, so it does not outlive the question it was for.
                if (shot !== "")
                    Quickshell.execDetached(["rm", "-f", "--", shot]);
                root.draft = prompt;
                root.notice = error.message || I18n.tr("The assistant could not start.");
                root.composing = true;
                if (error.code === -32004)
                    root.refreshAuth();
                return;
            }
            root.adopt(result.turn);
        });
    }

    function stop() {
        if (busy)
            request("turn.stop", {});
    }

    function respond(approvalId, decision) {
        request("approval.respond", { id: approvalId, decision: decision });
    }

    function undo() {
        if (!turn || !turn.undo || turn.undo.length === 0)
            return;
        const id = turn.id;
        request("turn.undo", { id: id }, (result, error) => {
            if (error) {
                root.notice = error.message;
                return;
            }
            const restored = result.restored || [];
            const skipped = result.skipped || [];
            if (root.turn && root.turn.id === id)
                root.turn = Object.assign({}, root.turn, { undo: [] });
            root.notice = skipped.length > 0
                ? I18n.format("Restored %1; %2 changed again since, so it was left alone.",
                    [restored.length, skipped.length])
                : I18n.tr("Undone.");
        });
    }

    function newConversation() {
        request("conversation.reset", {}, () => {
            root.conversation = null;
        });
        closeReply();
        notice = "";
    }

    // Continues the same Claude Code or Codex session in Kitty, for work that
    // outgrows a box under a character.
    function handoff() {
        request("conversation.handoff", {}, (result, error) => {
            if (error || !result || !Array.isArray(result.argv)) {
                root.notice = error ? error.message : I18n.tr("Nothing to continue yet.");
                return;
            }
            Quickshell.execDetached(["nerdos-apps", "terminal", "--app-id=nerdos-agent",
                "--dir=" + (result.cwd || root.home), "--"].concat(result.argv));
        });
    }

    function copyReply() {
        Quickshell.clipboardText = AssistantHelpers.copyText(turn);
        notice = I18n.tr("Copied.");
    }

    function addWidget(pluginId) {
        Quickshell.execDetached(["nerd", "plugin", "enable", pluginId]);
        notice = I18n.tr("Added to the bar.");
    }

    function fix(kind) {
        const action = AssistantHelpers.errorAction(kind, turn ? turn.agent : agent);
        if (!action)
            return;
        if (action.auth) {
            openComposer(true);
            signIn(turn ? turn.agent : agent);
        } else if (action.command)
            Quickshell.execDetached(["nerdos-apps", "terminal", "--hold", "--"].concat(action.command));
        else if (action.unit)
            Quickshell.execDetached(["systemctl", "--user", "start", action.unit]);
        else if (action.page)
            Settings.showPanel(action.page, screenName);
    }

    // Sign-in stays with the agent. The service only supplies its fixed login
    // command and checks its status; no credential is sent through this socket.
    function signIn(agentId) {
        if (!connected || authChecking || busy)
            return;
        Settings.set("assistantAgent", agentId);
        request("auth.login", { agent: agentId }, (result, error) => {
            if (error || !result || !Array.isArray(result.argv)) {
                root.notice = error ? error.message : I18n.tr("Sign-in could not start.");
                return;
            }
            root.signingIn = agentId;
            root.focusRequested = false;
            Quickshell.execDetached(["nerdos-apps", "terminal", "--hold",
                "--dir=" + result.cwd, "--"].concat(result.argv));
            authPoll.restart();
            authDeadline.restart();
        });
    }

    function refreshAuth() {
        if (!connected || authChecking)
            return;
        authChecking = true;
        request("auth.status", {}, (result, error) => {
            root.authChecking = false;
            if (result)
                root.adoptAgents(result.agents || {});
            else if (error)
                root.notice = error.message;
        });
    }

    function adoptAgents(next) {
        agents = next;
        if (signingIn !== "" && next[signingIn] && next[signingIn].auth === "ready") {
            signingIn = "";
            authPoll.stop();
            authDeadline.stop();
            notice = I18n.tr("Signed in. Your question is ready to send.");
        }
    }

    Timer {
        id: authPoll
        interval: 3000
        repeat: true
        onTriggered: root.refreshAuth()
    }

    Timer {
        id: authDeadline
        interval: 300000
        onTriggered: {
            authPoll.stop();
            root.signingIn = "";
        }
    }

    // ---- voice -----------------------------------------------------------------
    function startListening(latched) {
        if (!agentReady) {
            openComposer(true);
            refreshAuth();
            return;
        }
        if (!voiceAvailable || listening || transcribing || busy)
            return;
        listening = true;
        voiceLatched = latched === true;
        listenStartedAt = Date.now();
        notice = "";
        const options = Settings.modOpts.indicators;
        // Removing the previous transcript first is what makes the next read
        // this recording's words.
        Quickshell.execDetached(["sh", "-c",
            'mkdir -p -m 0700 "$1" && rm -f -- "$2" && exec voxtype --model "$3" --language "$4" record start --file="$2"',
            "sh", scratchDir, transcriptPath, options.dictationModel,
            options.dictationPrimaryLanguage]);
        Dictation.refresh();
        transcriptTimeout.stop();
    }

    function stopListening(sendWhenDone) {
        if (!listening)
            return;
        listening = false;
        voiceLatched = false;
        transcribing = true;
        sendAfterTranscript = sendWhenDone === true;
        Quickshell.execDetached(["voxtype", "record", "stop"]);
        Dictation.refresh();
        transcriptTimeout.restart();
        transcriptCheck.restart();
    }

    function cancelListening() {
        if (!listening && !transcribing)
            return;
        listening = false;
        transcribing = false;
        voiceLatched = false;
        transcriptTimeout.stop();
        Quickshell.execDetached(["voxtype", "record", "cancel"]);
    }

    function toggleMicrophone() {
        if (listening)
            stopListening(false);
        else
            startListening(true);
    }

    // Voxtype's state returns to idle once the transcript is on disk.
    Connections {
        target: Dictation

        function onStateChanged() {
            if (root.listening && Dictation.state === "transcribing") {
                // Voxtype ended the recording itself, at its length limit:
                // the words still arrive, for the person to send.
                root.listening = false;
                root.voiceLatched = false;
                root.transcribing = true;
                root.sendAfterTranscript = false;
                transcriptTimeout.restart();
            } else if (root.transcribing && Dictation.state === "idle") {
                transcript.reload();
            } else if (root.listening && Dictation.state === "idle"
                    && Date.now() - root.listenStartedAt > 1500) {
                // The daemon dropped the recording (a device error, or Voxtype
                // restarting); there is nothing to wait for.
                root.listening = false;
                root.notice = I18n.tr("The microphone stopped. Try again.");
            }
        }
    }

    // A release that came before Voxtype had started recording leaves its
    // state idle throughout, so no change announces the end.
    Timer {
        id: transcriptCheck
        interval: 1500
        onTriggered: {
            if (root.transcribing && Dictation.state === "idle")
                transcript.reload();
        }
    }

    FileView {
        id: transcript
        path: root.transcriptPath
        printErrors: false
        onLoaded: root.transcribed(text().trim())
        onLoadFailed: root.transcribed("")
    }

    function transcribed(words) {
        if (!transcribing)
            return;
        transcribing = false;
        transcriptTimeout.stop();
        Quickshell.execDetached(["rm", "-f", "--", transcriptPath]);
        if (words === "") {
            notice = I18n.tr("Nothing was heard.");
            return;
        }
        draft = draft.trim() === "" ? words : draft.trim() + " " + words;
        if (sendAfterTranscript)
            send();
        else
            openComposer(true);
    }

    Timer {
        id: transcriptTimeout
        interval: 45000
        onTriggered: {
            if (root.transcribing) {
                root.transcribing = false;
                root.notice = I18n.tr("Transcription took too long.");
            }
        }
    }

    // ---- screen context ----------------------------------------------------------
    // One screenshot of the display the character is on, taken with the
    // character hidden; it travels with the next question only.
    function attachScreen() {
        if (!Settings.assistantScreenContext || capturing || screenName === "" || !agentReady)
            return;
        capturing = true;
        captureDelay.restart();
    }

    function askAboutScreen(question) {
        if (screenAttached) {
            send(question);
            return;
        }
        pendingScreenQuestion = question;
        attachScreen();
    }

    function detachScreen() {
        if (screenPath !== "")
            Quickshell.execDetached(["rm", "-f", "--", screenPath]);
        screenAttached = false;
        screenPath = "";
    }

    function toggleScreen() {
        if (screenAttached)
            detachScreen();
        else
            attachScreen();
    }

    // Long enough for the compositor to present a frame without the
    // character before grim reads the output.
    Timer {
        id: captureDelay
        interval: 160
        onTriggered: {
            const path = root.scratchDir + "/screen-" + Date.now() + ".png";
            capture.path = path;
            capture.output = root.screenName;
            capture.command = ["sh", "-c", 'mkdir -p -m 0700 "$1" && exec grim -o "$2" -l 6 "$3"',
                "sh", root.scratchDir, root.screenName, path];
            capture.running = true;
            captureTimeout.restart();
        }
    }

    // The character stays hidden while capturing, so a capture that hangs
    // must not hide it for good.
    Timer {
        id: captureTimeout
        interval: 8000
        onTriggered: {
            if (!root.capturing)
                return;
            capture.running = false;
            root.capturing = false;
            root.pendingScreenQuestion = "";
            root.notice = I18n.tr("The screen could not be captured.");
        }
    }

    Process {
        id: capture
        property string path: ""
        property string output: ""
        onExited: (code) => {
            captureTimeout.stop();
            if (!root.capturing)
                return;
            root.capturing = false;
            if (code === 0) {
                if (root.screenPath !== "" && root.screenPath !== capture.path)
                    Quickshell.execDetached(["rm", "-f", "--", root.screenPath]);
                root.screenPath = capture.path;
                root.screenOutput = capture.output;
                root.screenAttached = true;
                if (root.pendingScreenQuestion !== "")
                    root.send(root.pendingScreenQuestion);
            } else {
                root.notice = I18n.tr("The screen could not be captured.");
            }
            root.pendingScreenQuestion = "";
        }
    }

    // ---- speech --------------------------------------------------------------
    function speak() {
        if (!turn || !turn.text || !connected)
            return;
        request("speech.say", { text: turn.text, language: I18n.language }, (result, error) => {
            if (error || !result) {
                root.notice = error ? error.message : "";
                return;
            }
            root.speechId = result.id;
            root.speechIndex = 0;
            root.speechCount = (result.sentences || []).length;
            root.speaking = root.speechCount > 0;
        });
    }

    function stopSpeaking() {
        if (!speaking)
            return;
        speaking = false;
        request("speech.stop", {});
    }

    // ---- service ---------------------------------------------------------------
    property int nextId: 1
    property var pending: ({})

    function request(method, params, callback) {
        if (!socket.connected) {
            if (callback)
                callback(null, { code: -32000, message: I18n.tr("The assistant service is not running.") });
            return;
        }
        const id = nextId++;
        if (callback)
            pending[id] = { callback: callback, at: Date.now() };
        socket.write(JSON.stringify({ jsonrpc: "2.0", id: id, method: method, params: params || {} }) + "\n");
        socket.flush();
    }

    function receive(line) {
        let message;
        try {
            message = JSON.parse(line);
        } catch (e) {
            console.warn("assistant: unreadable message from the service");
            return;
        }
        if (message.id !== undefined && message.method === undefined) {
            const entry = pending[message.id];
            delete pending[message.id];
            if (entry)
                entry.callback(message.result ?? null, message.error ?? null);
            return;
        }
        const params = message.params || {};
        switch (message.method) {
        case "agents.updated":
            adoptAgents(params.agents || {});
            break;
        case "turn.updated":
            adopt(params.turn);
            break;
        case "turn.delta":
            if (turn && params.id === turn.id)
                turn = Object.assign({}, turn, { text: (turn.text || "") + (params.text || "") });
            break;
        case "speech.progress":
            if (params.id === speechId)
                speechIndex = params.index;
            break;
        case "speech.done":
            if (params.id === speechId)
                speaking = false;
            break;
        }
    }

    // Takes the service's snapshot of the current turn, and reacts to the
    // moment it finishes.
    function adopt(next) {
        const previous = turn;
        turn = next || null;
        if (!next)
            return;
        const wasActive = previous !== null && previous.id === next.id && AssistantHelpers.active(previous);
        if (next.status === "waiting") {
            // A question nobody can see waits forever; bring the character out.
            tucked = false;
            if (!Settings.assistantShown)
                show(Screens.focused ? Screens.focused.name : "");
        }
        if (!wasActive || !AssistantHelpers.finished(next))
            return;
        conversation = { agent: next.agent, resumable: next.resumable === true };
        if (next.status === "stopped") {
            draft = next.prompt || "";
            notice = next.undo && next.undo.length > 0
                ? I18n.tr("Stopped. Undo reverts what it had changed.")
                : I18n.tr("Stopped. Nothing was changed.");
            replyOpen = (next.undo && next.undo.length > 0) || (next.text || "") !== "";
            composing = !replyOpen;
            return;
        }
        // A box tucked away, or a character hidden, gets the dot instead: the
        // reply opens when the character is next clicked.
        unread = tucked || !Settings.assistantShown;
        replyOpen = !unread;
        tucked = false;
        if (next.status === "completed") {
            celebrating = true;
            celebrateTimer.restart();
            if (Settings.assistantSpeak && !unread)
                speak();
        }
    }

    Timer {
        id: celebrateTimer
        interval: 2400
        onTriggered: root.celebrating = false
    }

    function hello() {
        request("hello", { client: "quickshell", protocol: 1 }, (result, error) => {
            if (error || !result) {
                console.warn("assistant: hello failed:", error ? error.message : "no result");
                return;
            }
            root.helloed = true;
            root.adoptAgents(result.agents || {});
            root.speechAvailable = !!(result.speech && result.speech.available);
            root.conversation = result.conversation || null;
            // A reconnect adopts the service's view of the turn; nothing is
            // replayed.
            const previous = root.turn;
            root.turn = result.turn || null;
            if (root.turn && AssistantHelpers.finished(root.turn)
                    && (!previous || previous.id !== root.turn.id))
                root.replyOpen = false;
        });
    }

    // Recheck on opening: the person may have signed in or out in a terminal.
    onComposingChanged: {
        if (composing && connected)
            refreshAuth();
    }

    Socket {
        id: socket
        path: root.socketPath
        parser: SplitParser {
            onRead: line => root.receive(line)
        }
        onConnectionStateChanged: {
            root.helloed = false;
            if (connected) {
                retry.interval = 1000;
                root.hello();
            } else {
                // Requests in flight will never be answered.
                const waiting = root.pending;
                root.pending = {};
                for (const id of Object.keys(waiting))
                    waiting[id].callback(null, { code: -32000,
                        message: I18n.tr("The assistant service is not running.") });
            }
        }
    }

    // Reconnects with a gentle backoff; the service may start after the shell
    // or restart under it.
    Timer {
        id: retry
        interval: 1000
        repeat: true
        running: root.available && !socket.connected
        triggeredOnStart: true
        onTriggered: {
            socket.connected = true;
            interval = Math.min(15000, interval * 2);
        }
    }

    // ---- the `nerd agent` default ----------------------------------------------
    FileView {
        path: (Quickshell.env("XDG_CONFIG_HOME") || (root.home + "/.config"))
            + "/nerdos/defaults/agent"
        printErrors: false
        watchChanges: true
        onFileChanged: reload()
        onLoaded: root.preferredAgent = text().trim()
        onLoadFailed: root.preferredAgent = ""
    }

    Binding {
        target: Dictation
        property: "assistantWatching"
        value: root.available
    }

    // The elapsed time in the worker pill.
    property double now: Date.now()
    Timer {
        interval: 1000
        repeat: true
        running: root.busy || root.listening
        triggeredOnStart: true
        onTriggered: root.now = Date.now()
    }

    // A transient notice fades on its own.
    Timer {
        interval: 6000
        running: root.notice !== ""
        onTriggered: root.notice = ""
    }
}
