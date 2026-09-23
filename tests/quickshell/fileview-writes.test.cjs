// Settings and Notes persist through Quickshell's FileView, whose write path
// has two properties that are easy to wedge on: setText() compares against
// the last bytes the view read *or tried to write* and silently skips a
// match, and a failed write still leaves its bytes in that cache. A save
// that waits for saved/saveFailed after a skipped setText waits forever.
//
// These tests run the real QML functions against a FileView double that
// follows Quickshell 0.2.1 (dacfa9de, src/io/fileview.cpp) step for step.
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const { shellDir, load } = require("./shell.cjs");

const SettingsHelpers = load("SettingsHelpers.js");
const NotesHelpers = load("NotesHelpers.js");
const FileViewError = { Success: 0, Unknown: 1, FileNotFound: 2, toString: String };

function read(relative) {
    return fs.readFileSync(path.join(shellDir, relative), "utf8");
}

function functionSource(source, name) {
    const match = source.match(new RegExp("^    function " + name + "\\([^]*?^    }", "m"));
    assert.ok(match, `function ${name} not found`);
    return match[0];
}

// Helpers a file may or may not carry are loaded only when present.
function hasFunction(source, name) {
    return new RegExp("^    function " + name + "\\(", "m").test(source);
}

// FileView::setText / saveSync / saveAsync / loadAsync / operationFinished.
function fileView(disk, blockWrites) {
    const view = {
        disk, blockWrites,
        cache: disk === null ? "" : disk,   // state.data
        writeData: null,                    // a write not yet finished
        live: null,                         // liveOperation
        queue: [],                          // completions the event loop owes
        failWrites: 0, writes: 0, skipped: 0, swallowedReloads: 0,
        on: {},
        setText(text) {
            const compare = view.writeData !== null ? view.writeData : view.cache;
            if (compare === text) {
                view.skipped++;
                return;
            }
            // cancelAsync(): a reader is disowned, a writer is waited for on
            // the GUI thread and its signal re-emitted from inside this call.
            if (view.live && view.live.kind === "write")
                throw new Error("setText under a live write blocks the GUI thread");
            view.writeData = text;
            const op = { kind: "write", text };
            if (view.blockWrites) {
                view.live = null;
                view.writeData = null;
                view.finish(op);
            } else {
                view.live = op;
                view.queue.push(op);
            }
        },
        finish(op) {
            // updateState() keeps the attempted bytes whether or not they landed.
            view.cache = op.text;
            if (view.failWrites > 0) {
                view.failWrites--;
                view.on.saveFailed(FileViewError.Unknown);
            } else {
                view.disk = op.text;
                view.writes++;
                view.on.saved();
            }
        },
        reload() {
            // loadAsync() does nothing while a write to the same path is live.
            if (view.live && view.live.kind === "write") {
                view.swallowedReloads++;
                return;
            }
            const op = { kind: "read" };
            view.live = op;
            view.queue.push(op);
        },
        settle() {
            while (view.queue.length > 0) {
                const op = view.queue.shift();
                if (op !== view.live)
                    continue;
                if (op.kind === "write") {
                    view.writeData = null;
                    view.finish(op);
                } else if (view.disk === null) {
                    view.cache = "";
                    view.on.loadFailed(FileViewError.FileNotFound);
                } else {
                    view.cache = view.disk;
                    view.on.loaded(view.cache);
                }
                // liveOperation is cleared only after the signal returns.
                view.live = null;
            }
        }
    };
    return view;
}

function timer(context, trigger) {
    return {
        running: false,
        restart() { this.running = true; },
        stop() { this.running = false; },
        fire() {
            if (!this.running)
                return false;
            this.running = false;
            trigger(context);
            return true;
        }
    };
}

function settingsHarness(disk, blockWrites) {
    const source = read("Common/Settings.qml");
    const store = fileView(disk, blockWrites);
    const context = {
        SettingsHelpers, FileViewError, Quickshell: { env: () => "" },
        console: { warn() {} },
        filePath: "/home/test/.config/cybexos/shell.json",
        loaded: false, ready: false, firstRun: false, migrationPending: false,
        loadError: false, loadErrorText: "", newerSchema: false, recheckPending: false,
        initialLoadHandled: false, lastPersistedText: "", storeText: "",
        savePending: false, saveError: false, announcement: "", revision: 0,
        corruptBackupPending: false, writeInFlight: false, writeSnapshot: "",
        reloadAfterWrite: false, lastSavedAt: 0, applied: 0,
        store,
        clearUndo() {}, backUpCorruptFile() {}, applyScrollFactor() {},
        applyGlassEffect() { context.applied++; }
    };
    context.root = context;
    context.defaults = SettingsHelpers.defaults();
    Object.assign(context, SettingsHelpers.defaults());
    context.saveTimer = timer(context, c => c.saveNow());
    context.reloadTimer = timer(context, c => c.reloadStore ? c.reloadStore() : c.store.reload());
    vm.createContext(context);
    for (const name of ["snapshot", "seedWeatherFromEnv", "protectNewerFile", "assignChanged",
            "applyLoaded", "handleLoadFailure", "sameContent", "handleSaveSucceeded",
            "handleSaveFailure", "saveNow", "scheduleSave", "retrySave", "set", "reloadStore"]
            .filter(name => hasFunction(source, name)))
        vm.runInContext(functionSource(source, name), context);
    store.on = {
        loaded: text => context.applyLoaded(text),
        loadFailed: error => context.handleLoadFailure(error),
        saved: () => context.handleSaveSucceeded(),
        saveFailed: error => context.handleSaveFailure(error)
    };
    if (disk === null)
        context.handleLoadFailure(FileViewError.FileNotFound);
    else
        context.applyLoaded(disk);
    // A property write runs its onChanged handler, which schedules a save.
    context.change = (key, value) => {
        context.set(key, value);
        context.scheduleSave();
    };
    // Lets the debounced save run and the event loop deliver what it owes.
    context.flush = () => {
        context.saveTimer.fire();
        store.settle();
    };
    return context;
}

function settingsText(changes) {
    return SettingsHelpers.serialize(Object.assign(SettingsHelpers.defaults(), changes || {}));
}

for (const blockWrites of [true, false]) {
    const mode = blockWrites ? "blocking" : "async";

    test(`settings: Retry after a failed save writes the same content (${mode})`, () => {
        const settings = settingsHarness(settingsText({ barHeight: 40 }), blockWrites);
        const store = settings.store;

        store.failWrites = 1;
        settings.change("barHeight", 44);
        settings.flush();
        assert.equal(settings.saveError, true);
        assert.equal(settings.writeInFlight, false);
        assert.equal(JSON.parse(store.disk).barHeight, 40, "the failed write left the file alone");

        // Nothing changed since: FileView still holds the failed attempt and
        // would skip the identical bytes without a signal.
        settings.retrySave();
        store.settle();
        assert.equal(store.skipped, 0, "Retry must never hand FileView the bytes it would skip");
        assert.equal(settings.writeInFlight, false, "the write guard must not outlive the save");
        assert.equal(settings.saveError, false);
        assert.equal(settings.savePending, false,
            "a newline-only difference is not a change made while saving");
        assert.equal(JSON.parse(store.disk).barHeight, 44);

        // Its own echo, extra newline and all, is not an external edit.
        const applied = settings.applied;
        store.reload();
        store.settle();
        assert.equal(settings.applied, applied);

        // And the session keeps saving afterwards.
        settings.change("barHeight", 48);
        settings.flush();
        assert.equal(settings.writeInFlight, false);
        assert.equal(settings.savePending, false);
        assert.equal(store.disk, settingsText({ barHeight: 48 }));
    });

    test(`settings: repeated failures alternate until a write lands (${mode})`, () => {
        const settings = settingsHarness(settingsText(), blockWrites);
        const store = settings.store;

        store.failWrites = 3;
        settings.change("gap", 6);
        settings.flush();
        for (let attempt = 0; attempt < 2; attempt++) {
            settings.retrySave();
            store.settle();
            assert.equal(settings.saveError, true);
            assert.equal(settings.writeInFlight, false);
        }
        settings.retrySave();
        store.settle();
        assert.equal(store.skipped, 0);
        assert.equal(settings.saveError, false);
        assert.equal(JSON.parse(store.disk).gap, 6);
    });

    test(`settings: a failed change undone before Retry settles without writing (${mode})`, () => {
        const initial = settingsText({ barHeight: 40 });
        const settings = settingsHarness(initial, blockWrites);
        const store = settings.store;

        store.failWrites = 1;
        settings.change("barHeight", 44);
        settings.flush();
        assert.equal(settings.saveError, true);
        settings.change("barHeight", 40);
        settings.flush();
        assert.equal(settings.saveError, false, "the file already holds these settings");
        assert.equal(settings.writeInFlight, false);
        assert.equal(settings.savePending, false);
        assert.equal(store.writes, 0);
        assert.equal(store.disk, initial);
    });

    test(`settings: first run failure and retry reach the missing file (${mode})`, () => {
        const settings = settingsHarness(null, blockWrites);
        const store = settings.store;
        assert.equal(settings.firstRun, true);

        store.failWrites = 1;
        settings.change("barHeight", 44);
        settings.flush();
        assert.equal(settings.saveError, true);
        assert.equal(store.disk, null);
        settings.retrySave();
        store.settle();
        assert.equal(settings.saveError, false);
        assert.equal(settings.writeInFlight, false);
        assert.equal(JSON.parse(store.disk).barHeight, 44);
    });
}

function notesHarness(disk, blockWrites) {
    const source = read("Common/Notes.qml");
    const store = fileView(disk, blockWrites);
    const later = [];
    const context = {
        NotesHelpers, FileViewError, console: { warn() {} },
        Qt: { callLater: fn => later.push(fn) },
        records: [], ready: false, dirty: false, writeInFlight: false,
        flushRequested: false, writeSnapshot: "", persistedText: "", storeText: "",
        error: "", errorKind: "", lastSavedAt: 0, deletedRecord: null, idCounter: 0,
        initialLoadHandled: false, titleStates: {}, titleQueue: [],
        store,
        undoTimer: { restart() {}, stop() {} }
    };
    context.root = context;
    context.saveTimer = timer(context, c => c.saveNow());
    vm.createContext(context);
    for (const name of ["canMutate", "record", "setTitleState", "invalidateTitleRequest",
            "nextId", "markDirty", "add", "update", "remove", "undoDelete", "retrySave",
            "flush", "sameContent", "saveNow", "handleSaveSucceeded", "handleSaveFailure",
            "applyLoaded", "handleLoadFailure"].filter(name => hasFunction(source, name)))
        vm.runInContext(functionSource(source, name), context);
    store.on = {
        loaded: text => context.applyLoaded(text),
        loadFailed: error => context.handleLoadFailure(error),
        saved: () => context.handleSaveSucceeded(),
        saveFailed: error => context.handleSaveFailure(error)
    };
    if (disk === null)
        context.handleLoadFailure(FileViewError.FileNotFound);
    else
        context.applyLoaded(disk);
    context.settle = () => {
        do {
            store.settle();
            while (later.length > 0)
                later.shift()();
        } while (store.queue.length > 0);
    };
    context.flushTimers = () => {
        context.saveTimer.fire();
        context.settle();
    };
    return context;
}

function notesText(bodies) {
    return NotesHelpers.serializeState(bodies.map((body, index) => ({
        id: "note-seed-" + index,
        title: NotesHelpers.fallbackTitle(body),
        body,
        createdAt: 1000 + index,
        updatedAt: 1000 + index
    })));
}

for (const blockWrites of [true, false]) {
    const mode = blockWrites ? "blocking" : "async";

    test(`notes: Retry after a failed save writes the same notes (${mode})`, () => {
        const notes = notesHarness(notesText(["first"]), blockWrites);
        const store = notes.store;

        store.failWrites = 1;
        const id = notes.add("second");
        notes.flushTimers();
        assert.equal(notes.errorKind, "save");
        assert.equal(notes.writeInFlight, false);

        notes.retrySave();
        notes.settle();
        assert.equal(store.skipped, 0, "Retry must never hand FileView the bytes it would skip");
        assert.equal(notes.writeInFlight, false, "the write guard must not outlive the save");
        assert.equal(notes.dirty, false,
            "a newline-only difference is not a change made while saving");
        assert.equal(notes.errorKind, "");
        assert.equal(NotesHelpers.parseState(store.disk).records.length, 2);

        notes.update(id, "second, edited");
        notes.flushTimers();
        assert.equal(notes.writeInFlight, false);
        assert.equal(notes.dirty, false);
        assert.equal(NotesHelpers.findRecord(
            NotesHelpers.parseState(store.disk).records, id).body, "second, edited");
    });

    test(`notes: deleting and undoing inside the debounce settles without a write (${mode})`, () => {
        const initial = notesText(["keep", "delete me"]);
        const notes = notesHarness(initial, blockWrites);
        const store = notes.store;

        notes.remove("note-seed-1");
        notes.undoDelete();
        notes.flushTimers();
        assert.equal(store.skipped, 0);
        assert.equal(notes.writeInFlight, false);
        assert.equal(notes.dirty, false);
        assert.equal(store.writes, 0);
        assert.equal(store.disk, initial);

        notes.add("still saves");
        notes.flushTimers();
        assert.equal(notes.writeInFlight, false);
        assert.equal(NotesHelpers.parseState(store.disk).records.length, 3);
    });

    test(`notes: a flush during a failed-then-retried write keeps its edits (${mode})`, () => {
        const notes = notesHarness(null, blockWrites);
        const store = notes.store;

        store.failWrites = 1;
        notes.add("one");
        notes.flush();
        notes.settle();
        assert.equal(notes.errorKind, "save");
        notes.retrySave();
        notes.settle();
        assert.equal(notes.writeInFlight, false);
        assert.equal(notes.dirty, false);
        assert.equal(NotesHelpers.parseState(store.disk).records.length, 1);
    });
}

test("the persistence comments describe what FileView actually reports", () => {
    const settings = read("Common/Settings.qml");
    assert.doesNotMatch(settings, /a failed atomic rename is still a failed save/,
        "Quickshell logs a failed atomic commit and still emits saved");
    for (const file of ["Common/Settings.qml", "Common/Notes.qml"]) {
        const source = read(file);
        assert.match(functionSource(source, "handleSaveFailure"), /storeText = writeSnapshot;/,
            `${file} must remember that FileView kept the failed attempt`);
        assert.match(functionSource(source, "saveNow"),
            /writeSnapshot = next === storeText \? next \+ "\\n" : next;/, file);
    }
});
