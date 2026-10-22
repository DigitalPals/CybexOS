pragma Singleton
import QtQuick
import Quickshell
import "T3CodeHelpers.js" as Helpers

// Git and working-tree actions for the thread the popover has open: the
// repository status card, and commit/push run server-side.
//
// `detailVcs` and `detailGit` live here rather than in T3Detail, where WP5.4
// briefly left them: this file is their only writer, and having git reach
// across to set another singleton's properties was the wrong direction. Their
// lifecycle is still the detail view's, so T3Detail raises `detailReset` and
// this clears them.
Singleton {
    id: root

    // Stacked git actions stream progress while the server generates a commit
    // message and runs hooks; the deadline slides on each chunk.
    readonly property int gitActionTimeoutMs: 120000

    property var detailVcs: ({ cwd: "", loading: false, error: "", status: null, fetchedAt: 0 })
    property var detailGit: ({ actionId: "", action: "", label: "", summary: "",
        prUrl: "", error: "" })

    function clearForThreadChange() {
        detailVcs = ({ cwd: "", loading: false, error: "", status: null, fetchedAt: 0 });
        detailGit = ({ actionId: "", action: "", label: "", summary: "", prUrl: "", error: "" });
    }

    Connections {
        target: T3Detail

        // The detail view moved to another thread (or closed).
        function onDetailReset() {
            root.clearForThreadChange();
        }

        function onVcsRefreshWanted(threadId) {
            root.refreshVcsStatus(threadId, true);
        }
    }

    function threadCwd(threadId) {
        const thread = T3Threads.threadMap[threadId];
        return Helpers.resolveThreadCwd(thread, thread ? T3Threads.projectMap[thread.projectId] : null);
    }

    // Reads detailVcs so QML visibility bindings refresh with the status.
    function gitActionApplies(action) {
        return Helpers.gitActionVisible(detailVcs.status, action);
    }

    function refreshVcsStatus(threadId, force) {
        if (T3Connection.state !== "connected" || !T3Connection.canRead || T3Detail.detailThreadId !== threadId)
            return;
        if (force !== true && detailVcs.fetchedAt > 0
                && Date.now() - detailVcs.fetchedAt < 10000)
            return;
        const cwd = threadCwd(threadId);
        if (cwd === "") {
            // No worktree and no project root: nothing to show, hide the card.
            detailVcs = ({ cwd: "", loading: false, error: "", status: null,
                fetchedAt: Date.now() });
            return;
        }
        detailVcs = Object.assign({}, detailVcs, { cwd: cwd, loading: true, error: "" });
        T3Rpc.requestOnce("vcs.refreshStatus", { cwd: cwd }, value => {
            if (T3Detail.detailThreadId !== threadId)
                return;
            detailVcs = ({ cwd: cwd, loading: false, error: "",
                status: Helpers.sanitizeVcsStatus(value), fetchedAt: Date.now() });
        }, error => {
            if (T3Detail.detailThreadId !== threadId)
                return;
            detailVcs = Object.assign({}, detailVcs, {
                loading: false, error: error, fetchedAt: Date.now()
            });
        }, { fallback: "Repository status unavailable" });
    }

    // action: "commit_push" (commit on the current branch + push — the
    // default flow) or "push". The commit message is generated server-side.
    function runGitAction(threadId, action) {
        const key = T3Rpc.actionKey("git", threadId, "");
        if (!Helpers.canBeginAction(T3Rpc.actionStates, key))
            return "";
        if (!T3Connection.canOperate)
            return T3Rpc.rejectAction(key, "This pairing is read-only", false);
        if (T3Connection.state !== "connected")
            return T3Rpc.rejectAction(key, "Not connected", false);
        const payload = Helpers.buildGitActionPayload({
            actionId: T3Rpc.genId(), cwd: threadCwd(threadId), action: action });
        if (!payload)
            return T3Rpc.rejectAction(key, "No repository folder for this thread", false);
        T3Rpc.beginAction(key, "", false, gitActionTimeoutMs);
        detailGit = ({ actionId: payload.actionId, action: action,
            label: action === "push" ? "Pushing…" : "Committing…",
            summary: "", prUrl: "", error: "" });
        // The terminal chunk (action_finished/action_failed) is what
        // T3Rpc.requestOnce retains; a Failure exit prefers the streamed message.
        let streamedFailure = "";
        const finish = fields => {
            if (T3Detail.detailThreadId === threadId
                    && detailGit.actionId === payload.actionId)
                detailGit = Object.assign({ actionId: "", action: "", label: "",
                    summary: "", prUrl: "", error: "" }, fields);
            root.refreshVcsStatus(threadId, true);
        };
        return T3Rpc.requestOnce("git.runStackedAction", payload, value => {
            T3Rpc.clearAction(key);
            const failure = streamedFailure !== "" ? streamedFailure
                : value && value.kind === "action_finished" ? "" : "Git action failed";
            if (failure !== "") {
                finish({ error: failure });
                return;
            }
            const summary = Helpers.gitResultSummary(value.result);
            finish({ summary: summary.text, prUrl: summary.prUrl });
        }, error => {
            const message = streamedFailure !== "" ? streamedFailure : error;
            T3Rpc.failAction(key, message);
            finish({ error: message });
        }, {
            actionKey: key,
            timeoutMs: gitActionTimeoutMs,
            slidingDeadline: true,
            fallback: "Git action failed",
            onItem: event => {
                const failure = Helpers.gitFailureMessage(event);
                if (failure !== "")
                    streamedFailure = failure;
                // Keep the expiry sweep fed while progress is flowing.
                const current = T3Rpc.actionStates[key];
                if (current && current.pending === true)
                    T3Rpc.putActionState(key, Object.assign({}, current,
                        { startedAt: Date.now() }));
                if (T3Detail.detailThreadId !== threadId
                        || detailGit.actionId !== payload.actionId)
                    return;
                const label = Helpers.gitProgressLabel(event);
                if (label !== "")
                    detailGit = Object.assign({}, detailGit, { label: label });
            }
        });
        // Deliberately not interrupted on detail close/switch: interrupting
        // could abort a server-side push mid-flight. Late results are no-ops
        // behind the T3Detail.detailThreadId/actionId guards above.
    }

    // The transport's half of the conversation. T3Connection owns the socket;
    // this is where its frames become protocol.
}
