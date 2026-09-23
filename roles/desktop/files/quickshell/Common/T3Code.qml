pragma Singleton
import QtQuick
import Quickshell
import "T3CodeHelpers.js" as Helpers
import "ExternalUrl.js" as ExternalUrl

// T3 Code session monitor and remote control: keeps a live WebSocket
// subscription to the orchestration shell of the remote T3 Code server
// (t3.codes) and exposes project/thread state for the bar chip and
// popover, plus command T3Rpc.dispatch (approvals, prompts, settle,
// T3Rpc.interrupt) and desktop notifications on session transitions.
//
// Auth is owned by T3Connection. The primary path signs in to T3 Connect in the
// browser, discovers a linked environment, and uses DPoP-bound relay and
// environment credentials.
Singleton {
    id: root

    // ---- connection re-exports -------------------------------------------
    // The transport lives in Common/T3Connection.qml. These stay here because
    // 274 call sites across seven files read them off T3Code, and the façade
    // is what lets that stay true while the inside is split up.
    readonly property string state: T3Connection.state
    readonly property string connectionError: T3Connection.connectionError
    readonly property bool websocketsMissing: T3Connection.websocketsMissing
    readonly property bool cloudLoginRunning: T3Connection.cloudLoginRunning
    readonly property string cloudLoginError: T3Connection.cloudLoginError
    readonly property string cloudStatus: T3Connection.cloudStatus
    readonly property string cloudIdentity: T3Connection.cloudIdentity
    readonly property string host: T3Connection.host
    readonly property string environmentLabel: T3Connection.environmentLabel
    readonly property string environmentId: T3Connection.environmentId
    readonly property string serverVersion: T3Connection.serverVersion
    readonly property var environmentCapabilities: T3Connection.environmentCapabilities
    readonly property bool scopeMetadataKnown: T3Connection.scopeMetadataKnown
    readonly property var tokenScope: T3Connection.tokenScope

    // All relay- and server-provided links cross one protocol allow-list
    // before reaching the desktop opener. Callers can use the result to avoid
    // closing their panel when an invalid link was rejected.
    function openExternalUrl(value) {
        const url = ExternalUrl.safeHttpUrl(value);
        if (url === "")
            return false;
        Quickshell.execDetached(["xdg-open", url]);
        return true;
    }

    function connect() {
        T3Connection.connect();
    }

    function loginCloud() {
        T3Connection.loginCloud();
    }

    readonly property var scopeInfo: T3Connection.scopeInfo
    readonly property bool canRead: T3Connection.canRead
    readonly property bool canOperate: T3Connection.canOperate
    readonly property bool readOnly: T3Connection.readOnly
    readonly property bool canDispatch: T3Connection.canDispatch

    // Sanitized server.getConfig projection. Credentials, settings, paths,
    // scripts, and skills never enter this singleton.
    property bool configReady: false
    property bool configLoading: false
    property string configError: ""
    property var providerConfigurations: []
    readonly property bool hasReadyProvider: configReady
        && providerConfigurations.some(provider => provider.ready === true
            && Array.isArray(provider.models) && provider.models.length > 0)
    readonly property bool supportsSettlement: T3Rpc.supportsSettlement
    readonly property bool supportsSnooze: T3Rpc.supportsSnooze
    readonly property bool supportsTitleRegeneration: T3Rpc.supportsTitleRegeneration
    readonly property bool supportsPinning: T3Rpc.supportsPinning

    // threadId → thread shell, projectId → project shell (raw server shapes)

    // Expanded-thread detail (orchestration.subscribeThread). The popover
    // owns one selection, so there is deliberately only one detail stream.

    // Structured-input drafts live in the singleton rather than the Loader
    // delegate. A rejected response therefore survives closing the popover,
    // selecting another thread, and retrying. Only user-input.resolved removes
    // the matching draft.
    readonly property bool paired: T3Connection.paired

    // ---- rpc / action re-exports -----------------------------------------
    // Common/T3Rpc.qml owns request ids, the in-flight handler table and the
    // per-command action states. These nine are the part consumers touch.
    readonly property var actionStates: T3Rpc.actionStates

    function actionPending(kind, threadId, requestId) {
        return T3Rpc.actionPending(kind, threadId, requestId);
    }

    function actionError(kind, threadId, requestId) {
        return T3Rpc.actionError(kind, threadId, requestId);
    }

    function respondApproval(threadId, requestId, decision) {
        T3Rpc.respondApproval(threadId, requestId, decision);
    }

    function respondUserInput(threadId, requestId, answers) {
        T3Rpc.respondUserInput(threadId, requestId, answers);
    }

    function settle(threadId) {
        T3Rpc.settle(threadId);
    }

    function unsettle(threadId) {
        T3Rpc.unsettle(threadId);
    }

    function snooze(threadId, snoozedUntil) {
        T3Rpc.snooze(threadId, snoozedUntil);
    }

    function unsnooze(threadId) {
        T3Rpc.unsnooze(threadId);
    }

    function pin(threadId) {
        T3Rpc.pin(threadId);
    }

    function unpin(threadId) {
        T3Rpc.unpin(threadId);
    }

    // Ends the running turn but leaves the session up, so the thread stays
    // ready for the next prompt. stopSession() below is the heavier one.
    function interrupt(threadId) {
        T3Rpc.interrupt(threadId);
    }

    function stopSession(threadId) {
        T3Rpc.stopSession(threadId);
    }

    // Stacked git actions stream progress while the server generates a
    // commit message and runs hooks; the deadline slides on each chunk.
    readonly property int gitActionTimeoutMs: 120000
    readonly property int maxPromptChars: Helpers.MAX_PROMPT_CHARS

    // ---- thread re-exports -----------------------------------------------
    // Common/T3Threads.qml owns the maps, the classification and the
    // projections. These are what the chip and the inbox read.
    readonly property var threads: T3Threads.threads
    readonly property var pinnedThreads: T3Threads.pinnedThreads
    readonly property var snoozedThreads: T3Threads.snoozedThreads
    readonly property var settledThreads: T3Threads.settledThreads
    readonly property int runningCount: T3Threads.runningCount
    readonly property int monitoringCount: T3Threads.monitoringCount
    readonly property int attentionCount: T3Threads.attentionCount
    readonly property int doneCount: T3Threads.doneCount
    readonly property bool shellReady: T3Threads.shellReady
    readonly property bool hasProjects: T3Threads.hasProjects

    function projectedThread(threadId) {
        return T3Threads.projectedThread(threadId);
    }

    function threadUrl(threadId) {
        return T3Threads.threadUrl(threadId);
    }

    function threadPath(threadId) {
        return T3Threads.threadPath(threadId);
    }

    function relTime(iso) {
        return T3Threads.relTime(iso);
    }

    function workingTimerLabel(iso) {
        return T3Threads.workingTimerLabel(iso);
    }

    function sortedProjects() {
        return T3Threads.sortedProjects();
    }

    function snoozePresets() {
        return T3Threads.snoozePresets();
    }

    function snoozeWakeLabel(iso) {
        return T3Threads.snoozeWakeLabel(iso);
    }

    function historyPage(messages, visibleCount) {
        return T3Threads.historyPage(messages, visibleCount);
    }

    // Edit script from the rows a thread page is showing to the rows for
    // `items`; see Helpers.historyRowOps.
    function historyRowOps(currentRows, items) {
        return Helpers.historyRowOps(currentRows, items);
    }

    function styleMarkdownLinks(markdown, linkColor) {
        return Helpers.styleMarkdownLinks(markdown, linkColor);
    }

    // ---- protocol --------------------------------------------------------

    function loadServerConfig() {
        configLoading = true;
        configReady = false;
        configError = "";
        T3Rpc.requestOnce("server.getConfig", {}, value => {
            if (!value || typeof value !== "object") {
                root.configLoading = false;
                root.configError = "Malformed server configuration";
                return;
            }
            const safe = Helpers.sanitizeServerConfig(value);
            root.providerConfigurations = safe.providers;
            // The environment fields belong to the connection: the descriptor
            // fetch fills them first and this refines them, so both writers
            // have to target the same properties.
            T3Connection.environmentCapabilities = safe.capabilities;
            if (safe.environmentId !== "")
                T3Connection.environmentId = safe.environmentId;
            if (safe.label !== "")
                T3Connection.environmentLabel = safe.label;
            if (safe.serverVersion !== "")
                T3Connection.serverVersion = safe.serverVersion;
            root.configLoading = false;
            root.configReady = true;
            T3Drafts.reconcileDraftSelections();
        }, error => {
            root.configLoading = false;
            root.configReady = false;
            root.configError = error;
        }, { fallback: "Server configuration unavailable" });
    }

    function subscribe() {
        const selected = T3Detail.detailThreadId;
        T3Rpc.clearRpcHandlers();
        T3Rpc.nextReqId = 2;
        T3Threads.threadMap = {};
        T3Threads.projectMap = {};
        T3Threads.shellReady = false;
        T3Detail.detailReqId = "";
        T3Detail.resetDetailData();
        T3Threads.nowMs = Date.now();
        T3Threads.rebuild();
        configReady = false;
        loadServerConfig();
        if (canRead)
            T3Rpc.sendRequest(T3Rpc.shellReqId, "orchestration.subscribeShell", {});
        else
            T3Threads.shellReady = false;
        // A reconnect invalidates every stream request id. Keep the user's
        // selection and establish a fresh detail stream on the new socket.
        if (selected !== "") {
            T3Detail.pendingDetailResubscribeId = selected;
            detailResubscribeTimer.restart();
        }
    }

    function handleMessage(text) {
        let msgs;
        try {
            msgs = JSON.parse(text);
        } catch (e) {
            return;
        }
        if (!Array.isArray(msgs))
            msgs = [msgs];
        let dirty = false;
        for (const msg of msgs) {
            const reqId = msg.requestId !== undefined ? String(msg.requestId) : "";
            if (msg._tag === "Chunk") {
                T3Connection.send(JSON.stringify({ _tag: "Ack", requestId: msg.requestId }));
                if (reqId === T3Rpc.shellReqId) {
                    dirty = T3Threads.applyItems(msg.values) || dirty;
                } else if (T3Rpc.rpcHandlers[reqId]) {
                    for (const item of (Array.isArray(msg.values) ? msg.values : []))
                        T3Rpc.rpcHandlers[reqId].item?.(item);
                }
            } else if (msg._tag === "Exit") {
                if (reqId === T3Rpc.shellReqId) {
                    // Stream ended server-side (shutdown/restart): reconnect.
                    T3Connection.scheduleRetry();
                } else if (T3Rpc.rpcHandlers[reqId]) {
                    T3Rpc.rpcHandlers[reqId].exit?.(msg);
                    T3Rpc.dropRpcHandler(reqId);
                }
            }
        }
        if (dirty)
            T3Threads.scheduleRebuild();
    }

    // Server configuration is protocol state, so it is owned here and bound
    // down into the draft layer rather than pushed at each write site — the
    // selection logic there is its main reader, but it is not draft state.
    Binding {
        target: T3Drafts
        property: "providerConfigurations"
        value: root.providerConfigurations
    }

    Binding {
        target: T3Drafts
        property: "configReady"
        value: root.configReady
    }

    Binding {
        target: T3Drafts
        property: "hasReadyProvider"
        value: root.hasReadyProvider
    }

    // ---- draft re-exports --------------------------------------------------
    // Common/T3Drafts.qml holds everything typed but not yet sent. It is a
    // singleton because T3CodePopover is rebuilt on every open.
    readonly property var newThreadDraft: T3Drafts.newThreadDraft
    readonly property string pendingNewThreadId: T3Drafts.pendingNewThreadId
    // Re-exported for their change signals: the composer and request card
    // watch these through `Connections { target: T3Code }`, and a Connections
    // handler on a façade without the property is silently dead — Quickshell
    // logs one WARN at reload and never calls it.
    readonly property var threadDrafts: T3Drafts.threadDrafts
    readonly property var userInputDrafts: T3Drafts.userInputDrafts

    // The same re-export, for a signal instead of a property: there is no
    // value to bind, so the façade declares its own and relays it. Views never
    // reference T3Drafts, so without this the popover's handler is dead and a
    // thread the user just created is never opened.
    signal newThreadConfirmed(string threadId)

    Connections {
        target: T3Drafts

        function onNewThreadConfirmed(threadId) {
            root.newThreadConfirmed(threadId);
        }
    }

    function buildInputAnswers(threadId, pendingInput) {
        return T3Drafts.buildInputAnswers(threadId, pendingInput);
    }

    function draftTraitDescriptors(draft) {
        return T3Drafts.draftTraitDescriptors(draft);
    }

    function ensureNewThreadDraft(contextThreadId) {
        return T3Drafts.ensureNewThreadDraft(contextThreadId);
    }

    function ensureThreadDraft(threadId) {
        return T3Drafts.ensureThreadDraft(threadId);
    }

    function implementPlanHere(threadId, plan) {
        return T3Drafts.implementPlanHere(threadId, plan);
    }

    function inputCustomAnswer(threadId, requestId, questionId) {
        return T3Drafts.inputCustomAnswer(threadId, requestId, questionId);
    }

    function inputQuestionAnswered(threadId, requestId, question) {
        return T3Drafts.inputQuestionAnswered(threadId, requestId, question);
    }

    function inputQuestionIndex(threadId, requestId) {
        return T3Drafts.inputQuestionIndex(threadId, requestId);
    }

    function inputSelectedLabels(threadId, requestId, questionId) {
        return T3Drafts.inputSelectedLabels(threadId, requestId, questionId);
    }

    function newModelChoices() {
        return T3Drafts.newModelChoices();
    }

    function newProviderChoices() {
        return T3Drafts.newProviderChoices();
    }

    function prepareNewThreadForPlan(sourceThreadId, plan) {
        return T3Drafts.prepareNewThreadForPlan(sourceThreadId, plan);
    }

    function providerConfiguration(instanceId) {
        return T3Drafts.providerConfiguration(instanceId);
    }

    function providerIcon(instanceId) {
        return T3Drafts.providerIcon(instanceId);
    }

    function modelConfiguration(instanceId, model) {
        return T3Drafts.modelConfiguration(instanceId, model);
    }

    // ---- model picker ----------------------------------------------------

    function providerRail() {
        return T3Drafts.providerRail();
    }

    function threadPickerRows(threadId, railId, query, legacyExpanded) {
        return T3Drafts.threadPickerRows(threadId, railId, query, legacyExpanded);
    }

    function newPickerRows(railId, query, legacyExpanded) {
        return T3Drafts.newPickerRows(railId, query, legacyExpanded);
    }

    function isFavoriteModel(instanceId, model) {
        return T3Favorites.isFavorite(instanceId, model);
    }

    function toggleFavoriteModel(instanceId, model) {
        T3Favorites.toggle(instanceId, model);
    }

    readonly property var favoriteModels: T3Favorites.favorites

    function providerShowsInteraction(instanceId) {
        return T3Drafts.providerShowsInteraction(instanceId);
    }

    function refinePlan(threadId) {
        return T3Drafts.refinePlan(threadId);
    }

    function setInputCustomAnswer(threadId, requestId, questionId, value) {
        return T3Drafts.setInputCustomAnswer(threadId, requestId, questionId, value);
    }

    function setInputQuestionIndex(threadId, requestId, value) {
        return T3Drafts.setInputQuestionIndex(threadId, requestId, value);
    }

    function setNewInteraction(interactionMode) {
        return T3Drafts.setNewInteraction(interactionMode);
    }

    function setNewModel(model) {
        return T3Drafts.setNewModel(model);
    }

    function setNewProject(projectId) {
        return T3Drafts.setNewProject(projectId);
    }

    function setNewPrompt(prompt) {
        return T3Drafts.setNewPrompt(prompt);
    }

    function setNewProvider(instanceId) {
        return T3Drafts.setNewProvider(instanceId);
    }

    function setNewRuntime(runtimeMode) {
        return T3Drafts.setNewRuntime(runtimeMode);
    }

    // Provider and model travel as one choice — see T3Drafts.selectionId().
    readonly property string selectionSeparator: T3Drafts.selectionSeparator

    function setNewSelection(instanceId, model) {
        return T3Drafts.setNewSelection(instanceId, model);
    }

    function setThreadSelection(threadId, instanceId, model) {
        return T3Drafts.setThreadSelection(threadId, instanceId, model);
    }

    function selectionId(instanceId, model) {
        return T3Drafts.selectionId(instanceId, model);
    }

    function setThreadInteraction(threadId, interactionMode) {
        return T3Drafts.setThreadInteraction(threadId, interactionMode);
    }

    function setThreadModel(threadId, model) {
        return T3Drafts.setThreadModel(threadId, model);
    }

    function setThreadPrompt(threadId, prompt) {
        return T3Drafts.setThreadPrompt(threadId, prompt);
    }

    function setThreadProvider(threadId, instanceId) {
        return T3Drafts.setThreadProvider(threadId, instanceId);
    }

    function setThreadRuntime(threadId, runtimeMode) {
        return T3Drafts.setThreadRuntime(threadId, runtimeMode);
    }

    function submitExisting(threadId, overrideText, interactionOverride, sourceProposedPlan,
            clearDraft) {
        return T3Drafts.submitExisting(threadId, overrideText, interactionOverride, sourceProposedPlan, clearDraft);
    }

    function submitNewThread() {
        return T3Drafts.submitNewThread();
    }

    function threadDraft(threadId) {
        return T3Drafts.threadDraft(threadId);
    }

    function threadModelChoices(threadId) {
        return T3Drafts.threadModelChoices(threadId);
    }

    function threadProviderChoices(threadId) {
        return T3Drafts.threadProviderChoices(threadId);
    }

    function threadProviderIcon(threadId) {
        return T3Drafts.threadProviderIcon(threadId);
    }

    function threadSelectionLabel(threadId) {
        return T3Drafts.threadSelectionLabel(threadId);
    }

    function toggleInputOption(threadId, requestId, questionId, label, multiSelect) {
        return T3Drafts.toggleInputOption(threadId, requestId, questionId, label, multiSelect);
    }

    function updateNewTrait(descriptorId, value) {
        return T3Drafts.updateNewTrait(descriptorId, value);
    }

    function updateThreadTrait(threadId, descriptorId, value) {
        return T3Drafts.updateThreadTrait(threadId, descriptorId, value);
    }
    // ---- detail re-exports -------------------------------------------------
    // Common/T3Detail.qml owns the open thread's stream and its projections.
    // Only T3ThreadPage reads these.
    //
    // detailThreadId is re-exported for its change signal more than its value:
    // the page resets its message window and re-follows the tail when the
    // stream switches threads, and that handler was dead without it here.
    readonly property string detailThreadId: T3Detail.detailThreadId
    readonly property bool detailLoading: T3Detail.detailLoading
    readonly property string detailError: T3Detail.detailError
    readonly property var detailMessages: T3Detail.detailMessages
    readonly property var detailSession: T3Detail.detailSession
    readonly property int detailLiveAgentCount: T3Detail.detailLiveAgentCount
    readonly property var detailTaskProgress: T3Detail.detailTaskProgress
    readonly property var detailApprovals: T3Detail.detailApprovals
    readonly property var detailPendingInputs: T3Detail.detailPendingInputs
    readonly property var detailLatestActivity: T3Detail.detailLatestActivity
    readonly property var detailActionablePlan: T3Detail.detailActionablePlan
    readonly property var detailCheckpointSummary: T3Detail.detailCheckpointSummary
    readonly property var detailDiff: T3Detail.detailDiff
    readonly property var detailVcs: T3Git.detailVcs
    readonly property var detailGit: T3Git.detailGit

    function rememberThread(threadId) {
        T3Detail.rememberThread(threadId);
    }

    function forgetThread(threadId) {
        T3Detail.forgetThread(threadId);
    }

    function restorableThreadId() {
        // During reconnect the shell snapshot is deliberately empty. Keep the
        // remembered identity until there is authoritative lifecycle data.
        if (!T3Threads.shellReady)
            return "";
        const threadId = T3Detail.lastViewedThreadId;
        if (threadId === "")
            return "";
        const thread = T3Threads.projectedThread(threadId);
        if (!thread || thread.lifecycle === "settled") {
            T3Detail.forgetThread(threadId);
            return "";
        }
        return threadId;
    }

    function openDetail(threadId) {
        T3Detail.openDetail(threadId);
    }

    function closeDetail() {
        T3Detail.closeDetail();
    }

    function loadFullThreadDiff(threadId, checkpoint) {
        T3Detail.loadFullThreadDiff(threadId, checkpoint);
    }

    function copyFullThreadDiff(threadId, checkpoint) {
        return T3Detail.copyFullThreadDiff(threadId, checkpoint);
    }

    // ---- git re-exports ----------------------------------------------------
    function gitActionApplies(action) {
        return T3Git.gitActionApplies(action);
    }

    function refreshVcsStatus(threadId, force) {
        T3Git.refreshVcsStatus(threadId, force);
    }

    function runGitAction(threadId, action) {
        return T3Git.runGitAction(threadId, action);
    }

    Connections {
        target: T3Detail

        function onDraftMessageConfirmed(threadId, messageId) {
            T3Drafts.confirmDraftMessage(threadId, messageId);
        }

        function onUserInputResolved(threadId, requestId) {
            T3Drafts.clearUserInputDraft(threadId, requestId);
        }

    }

    Connections {
        target: T3Threads

        // A snapshot replaced the world: draft selections may point at threads
        // or projects that no longer exist.
        function onSnapshotApplied() {
            T3Drafts.reconcileDraftSelections();
            T3Drafts.reconcileNewThreadCreation();
        }

        function onThreadUpserted(threadId) {
            T3Drafts.reconcileNewThreadCreation(threadId);
        }

        // Shell updates carry a fresher session summary than the detail stream
        // while that stream is catching up.
        function onRebuilt() {
            T3Detail.adoptShellSummary(T3Threads.threadMap[T3Detail.detailThreadId]);
        }
    }

    Connections {
        target: T3Rpc

        // The RPC layer dropped everything in flight; the detail subscription
        // id it was holding is meaningless now.
        function onAborted() {
            T3Detail.detailReqId = "";
        }
    }

    Connections {
        target: T3Connection

        function onMessage(text) {
            root.handleMessage(text);
        }

        function onOpened() {
            root.subscribe();
        }

        // Fired before a retry is armed: nothing in flight can still land.
        function onDropped() {
            T3Rpc.abortPendingRpcs();
            T3Rpc.failAllPendingActions("Disconnected before confirmation");
            root.configLoading = false;
            root.configReady = false;
        }
    }
}
