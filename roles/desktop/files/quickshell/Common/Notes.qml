pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "NotesHelpers.js" as NotesHelpers
import "PanelRegistryData.js" as PanelRegistry

// Process-wide Markdown notes with a strict, atomic local state file. The
// editor view is rebuilt whenever its popout closes, so all durable and undo
// state lives here rather than in NotesPopover.
Singleton {
    id: root

    readonly property string filePath:
        Quickshell.env("HOME") + "/.local/state/cybexos/shell/notes.json"

    property var records: []
    readonly property int count: records.length
    property bool ready: false
    property bool dirty: false
    property bool writeInFlight: false
    property bool flushRequested: false
    property string writeSnapshot: ""
    // The file's bytes as last read or saved, and what FileView compares
    // the next setText against: the bytes it last read or tried to write,
    // which after a failed save is not the file. See saveNow().
    property string persistedText: ""
    property string storeText: ""
    property string error: ""
    property string errorKind: ""
    property double lastSavedAt: 0
    property var deletedRecord: null
    property int idCounter: 0
    property bool initialLoadHandled: false

    property var titleStates: ({})
    property var titleQueue: []
    property var activeTitleRequest: null
    property int titleRequestCounter: 0

    readonly property bool saving: writeInFlight
        || (dirty && errorKind === "")
    readonly property bool undoAvailable: deletedRecord !== null

    function canMutate() {
        return ready && errorKind !== "load";
    }

    function record(id) {
        return NotesHelpers.findRecord(records, id);
    }

    function titleState(id) {
        return titleStates[id] || ({ pending: false, error: "", request: null });
    }

    function titlePending(id) {
        return titleState(id).pending === true;
    }

    function titleError(id) {
        return titleState(id).error || "";
    }

    function titleProvider() {
        return Settings.modOpts.notes.titleProvider;
    }

    function titleModel(provider) {
        const options = Settings.modOpts.notes;
        return provider === "codex" ? options.codexModel : options.claudeModel;
    }

    function titleEffort(provider) {
        const options = Settings.modOpts.notes;
        return provider === "codex" ? options.codexEffort : options.claudeEffort;
    }

    function setTitleState(id, state) {
        const next = Object.assign({}, titleStates);
        if (state === null)
            delete next[id];
        else
            next[id] = state;
        titleStates = next;
    }

    function invalidateTitleRequest(id) {
        titleQueue = titleQueue.filter(request => request.id !== id);
        setTitleState(id, null);
    }

    function nextId() {
        let id = "";
        do {
            idCounter++;
            id = "note-" + Date.now().toString(36) + "-"
                + idCounter.toString(36) + "-"
                + Math.floor(Math.random() * 0x100000000).toString(36);
        } while (record(id) !== null);
        return id;
    }

    function markDirty() {
        dirty = true;
        if (errorKind === "")
            saveTimer.restart();
    }

    function add(body, title) {
        if (!canMutate() || NotesHelpers.isBlank(body))
            return "";
        const now = Date.now();
        const id = nextId();
        const result = NotesHelpers.addRecord(records, body, id, now, title || "");
        if (!result.changed)
            return "";
        records = result.records;
        markDirty();
        return id;
    }

    function update(id, body) {
        if (!canMutate())
            return false;
        if (NotesHelpers.isBlank(body))
            return remove(id);
        const result = NotesHelpers.updateRecord(records, id, body, Date.now());
        if (!result.changed)
            return false;
        invalidateTitleRequest(id);
        records = result.records;
        markDirty();
        return true;
    }

    function updateTitle(id, title) {
        if (!canMutate())
            return false;
        invalidateTitleRequest(id);
        const result = NotesHelpers.updateTitleRecord(records, id, title, Date.now());
        if (!result.changed)
            return false;
        records = result.records;
        markDirty();
        return true;
    }

    function remove(id) {
        if (!canMutate())
            return false;
        const result = NotesHelpers.removeRecord(records, id);
        if (!result.changed)
            return false;
        invalidateTitleRequest(id);
        records = result.records;
        deletedRecord = result.deleted;
        undoTimer.restart();
        markDirty();
        return true;
    }

    function requestTitle(id) {
        if (!canMutate() || titlePending(id))
            return false;
        const provider = titleProvider();
        if (provider === "off") {
            setTitleState(id, {
                pending: false,
                error: "Choose a title provider in Notes settings.",
                request: null
            });
            return false;
        }
        const captured = NotesHelpers.captureTitleRequest(record(id), provider,
            titleModel(provider), titleEffort(provider));
        if (captured === null)
            return false;
        titleRequestCounter++;
        captured.token = titleRequestCounter;
        titleQueue = titleQueue.concat([captured]);
        setTitleState(id, { pending: true, error: "", request: captured });
        Qt.callLater(root.pumpTitleQueue);
        return true;
    }

    function retryTitle(id) {
        const state = titleState(id);
        if (state.error === "")
            return false;
        setTitleState(id, null);
        return requestTitle(id);
    }

    function titleRequestIsCurrent(request) {
        if (request === null)
            return false;
        const provider = titleProvider();
        return NotesHelpers.titleRequestCurrent(records, request, provider,
            titleModel(provider), titleEffort(provider));
    }

    function titleTokenIsCurrent(request) {
        const state = titleState(request.id);
        return state.pending === true && state.request !== null
            && state.request.token === request.token;
    }

    function pumpTitleQueue() {
        if (titleProc.running || activeTitleRequest !== null)
            return;
        while (titleQueue.length > 0) {
            const request = titleQueue[0];
            titleQueue = titleQueue.slice(1);
            if (!titleTokenIsCurrent(request) || !titleRequestIsCurrent(request)) {
                if (titleTokenIsCurrent(request))
                    setTitleState(request.id, null);
                continue;
            }
            activeTitleRequest = request;
            titleProc.running = true;
            return;
        }
    }

    function settleTitleRequest(exitSeen, exitCode, output) {
        const request = activeTitleRequest;
        activeTitleRequest = null;
        if (request === null) {
            Qt.callLater(root.pumpTitleQueue);
            return;
        }
        if (!titleTokenIsCurrent(request) || !titleRequestIsCurrent(request)) {
            if (titleTokenIsCurrent(request))
                setTitleState(request.id, null);
            Qt.callLater(root.pumpTitleQueue);
            return;
        }

        let response = null;
        try {
            response = JSON.parse(output);
        } catch (parseError) {
            response = null;
        }
        if (exitSeen && exitCode === 0 && response && response.ok === true
                && typeof response.title === "string") {
            const result = NotesHelpers.applyGeneratedTitle(records, request.id,
                response.title);
            if (result.changed) {
                records = result.records;
                markDirty();
            }
            setTitleState(request.id, null);
        } else {
            const message = response && typeof response.error === "string"
                && response.error.trim() !== "" ? response.error.trim()
                : !exitSeen ? "The title helper could not be started."
                : "Title generation failed.";
            setTitleState(request.id, {
                pending: false,
                error: message.slice(0, 240),
                request: null
            });
        }
        Qt.callLater(root.pumpTitleQueue);
    }

    function undoDelete() {
        if (!canMutate() || deletedRecord === null)
            return false;
        const result = NotesHelpers.restoreDeleted(records, deletedRecord);
        if (!result.changed)
            return false;
        undoTimer.stop();
        deletedRecord = null;
        records = result.records;
        markDirty();
        return true;
    }

    function retrySave() {
        if (!ready || errorKind === "load") {
            error = "";
            errorKind = "";
            initialLoadHandled = false;
            store.reload();
            return;
        }
        error = "";
        errorKind = "";
        flush();
    }

    function flush() {
        saveTimer.stop();
        if (!dirty)
            return;
        if (writeInFlight) {
            flushRequested = true;
            return;
        }
        saveNow();
    }

    // A retried write may carry one extra trailing newline (see saveNow());
    // it is still the same notes file.
    function sameContent(text, written) {
        return text === written || text + "\n" === written;
    }

    function saveNow() {
        if (!ready || !dirty || writeInFlight || errorKind !== "")
            return;
        const next = NotesHelpers.serializeState(records);
        // Already on disk: undoing a delete inside the debounce lands here.
        if (sameContent(next, persistedText)) {
            dirty = false;
            flushRequested = false;
            return;
        }
        // FileView.setText compares against the bytes the view last read or
        // tried to write, not against the file, and skips a match without
        // emitting saved or saveFailed. After a failed save that is the
        // attempt itself, so a Retry of the same notes would hold the write
        // guard for the rest of the session. The same JSON with one more
        // trailing newline makes it a real write.
        writeSnapshot = next === storeText ? next + "\n" : next;
        writeInFlight = true;
        try {
            store.setText(writeSnapshot);
        } catch (saveException) {
            handleSaveFailure(FileViewError.Unknown);
            console.warn("notes save threw:", saveException);
        }
    }

    function handleSaveSucceeded() {
        const completed = writeSnapshot;
        persistedText = completed;
        storeText = completed;
        writeSnapshot = "";
        writeInFlight = false;
        error = "";
        errorKind = "";
        lastSavedAt = Date.now();
        const changedWhileSaving = !sameContent(NotesHelpers.serializeState(records),
            completed);
        dirty = changedWhileSaving;
        if (!changedWhileSaving) {
            flushRequested = false;
            return;
        }
        if (flushRequested) {
            flushRequested = false;
            Qt.callLater(root.saveNow);
        } else {
            saveTimer.restart();
        }
    }

    function handleSaveFailure(fileError) {
        // FileView keeps the attempted bytes even though they never reached
        // the file; saveNow() has to write around them.
        storeText = writeSnapshot;
        writeSnapshot = "";
        writeInFlight = false;
        flushRequested = false;
        dirty = true;
        errorKind = "save";
        error = "Could not save notes";
        console.warn("notes save failed:", FileViewError.toString(fileError));
    }

    function applyLoaded(rawText) {
        initialLoadHandled = true;
        persistedText = rawText;
        storeText = rawText;
        const parsed = NotesHelpers.parseState(rawText);
        if (parsed.status === "corrupt") {
            ready = false;
            dirty = false;
            saveTimer.stop();
            errorKind = "load";
            error = "Notes file is malformed and was left untouched";
            console.warn("notes load blocked:", parsed.error, "at", filePath);
            return;
        }
        records = parsed.records;
        ready = true;
        dirty = parsed.migrated === true;
        error = "";
        errorKind = "";
        titleStates = ({});
        titleQueue = [];
        if (dirty)
            saveTimer.restart();
    }

    function handleLoadFailure(fileError) {
        initialLoadHandled = true;
        persistedText = "";
        storeText = "";
        if (fileError === FileViewError.FileNotFound) {
            records = [];
            ready = true;
            dirty = false;
            error = "";
            errorKind = "";
            return;
        }
        ready = false;
        dirty = false;
        saveTimer.stop();
        errorKind = "load";
        error = "Could not load notes; the file was left untouched";
        console.warn("notes load failed:", FileViewError.toString(fileError));
    }

    Timer {
        id: saveTimer
        interval: 400
        onTriggered: root.saveNow()
    }

    Timer {
        id: undoTimer
        interval: 5000
        onTriggered: root.deletedRecord = null
    }

    Process {
        id: titleProc

        property string body: ""
        property bool exitSeen: false
        property int lastExit: 0

        command: ["python3", Quickshell.shellDir + "/scripts/note-title.py"]
        stdinEnabled: true
        stdout: StdioCollector {
            onStreamFinished: titleProc.body = text
        }
        stderr: StdioCollector {}
        onStarted: {
            const request = root.activeTitleRequest;
            if (request !== null) {
                write(JSON.stringify({
                    provider: request.provider,
                    model: request.model,
                    effort: request.effort,
                    body: request.body.slice(0, 12000)
                }) + "\n");
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
            } else if (root.activeTitleRequest !== null) {
                root.settleTitleRequest(exitSeen, lastExit, body);
            }
        }
    }

    FileView {
        id: store
        path: root.filePath
        printErrors: false
        atomicWrites: true
        blockWrites: true
        blockLoading: true
        onLoaded: root.applyLoaded(text())
        onLoadFailed: error => root.handleLoadFailure(error)
        onSaved: root.handleSaveSucceeded()
        onSaveFailed: error => root.handleSaveFailure(error)
    }

    // Closing or switching away from Notes is a persistence boundary even if
    // the panel instance has not been destroyed by its exit animation yet.
    Connections {
        target: Popouts

        function onChanged() {
            if (!Popouts.open || Popouts.currentName !== PanelRegistry.NOTES)
                root.flush();
        }
    }

    Component.onCompleted: {
        if (!initialLoadHandled) {
            const initialText = store.text();
            if (!initialLoadHandled && store.loaded)
                applyLoaded(initialText);
        }
    }
}
