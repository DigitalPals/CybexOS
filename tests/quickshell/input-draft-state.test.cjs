const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const { shellDir } = require("./shell.cjs");
const Draft = require(path.join(shellDir, "Settings/InputDraft.js"));

// Execute the production component's methods; tests/qml-lifecycle also
// exercises its bindings and the actual page Loader in the real Qt engine.
function state(section, service) {
    const source = fs.readFileSync(path.join(shellDir, "Settings/InputDraftState.qml"), "utf8");
    const context = {Draft, service, section, fields: ["value"], draft: {}, original: {}, version: "", submitted: null,
        supersededSnapshot: null};
    Object.defineProperties(context, {
        changes: {get() { return Draft.patch(context.draft, context.original, context.fields); }},
        dirty: {get() { return Object.keys(context.changes).length > 0; }}
    });
    context.root = context;
    vm.createContext(context);
    for (const name of ["load", "apply"])
        vm.runInContext(source.match(new RegExp(`^    function ${name}\\([^]*?^    }`, "m"))[0], context);
    vm.runInContext(source.match(/^    function refresh\(\) [^\n]+/m)[0], context);
    vm.runInContext(source.match(/^        function onCompleted\(result\) \{[^]*?^        }/m)[0], context);
    return context;
}

function service() {
    return {loaded: true, busy: false, snapshot: {version: "a", keyboard: {value: "old"}, touchpad: {value: true}},
        run(request) { this.request = request; return true; }};
}

test("dirty input drafts keep their baseline across a fresh snapshot and failed apply", () => {
    const backend = service();
    const draft = state("keyboard", backend);
    draft.refresh();
    draft.draft = {value: "edited"};
    backend.snapshot = {version: "b", keyboard: {value: "external"}};
    draft.refresh();
    draft.apply();
    assert.equal(backend.request.version, "a");
    assert.equal(backend.request.values.value, "edited");
    draft.onCompleted({success: false});
    assert.equal(draft.dirty, true);
    assert.equal(draft.draft.value, "edited");
    draft.load();
    assert.equal(draft.dirty, false);
    assert.equal(draft.draft.value, "external");
    assert.equal(draft.version, "b");
});

test("completion after page teardown settles only submitted values in the submitted section", () => {
    const backend = service();
    const keyboard = state("keyboard", backend);
    const touchpad = state("touchpad", backend);
    keyboard.refresh();
    touchpad.refresh();
    keyboard.draft = {value: "sent"};
    touchpad.draft = {value: false};
    keyboard.apply();
    // Even if a later edit slips in before completion it must remain pending.
    keyboard.draft = {value: "later"};
    keyboard.onCompleted({success: true, version: "b"});
    touchpad.onCompleted({success: true, version: "b"});
    assert.equal(keyboard.original.value, "sent");
    assert.equal(keyboard.version, "b");
    assert.equal(keyboard.dirty, true);
    assert.equal(touchpad.original.value, true);
    assert.equal(touchpad.draft.value, false);
    assert.equal(touchpad.dirty, true);
});

for (const section of ["keyboard", "touchpad"]) {
    for (const snapshotFirst of [true, false]) {
        for (const editBeforeCompletion of [true, false]) {
            test(`${section}: ${snapshotFirst ? "snapshot before completion" : "completion before snapshot"}, edit ${editBeforeCompletion ? "during Apply" : "after completion"}`, () => {
                const backend = service();
                const draft = state(section, backend);
                draft.refresh();
                draft.draft = {value: "sent"};
                draft.apply();
                assert.equal(backend.request.version, "a");
                if (editBeforeCompletion) draft.draft = {value: "later"};
                if (snapshotFirst) {
                    backend.snapshot = {version: "b", [section]: {value: "sent"}};
                    draft.refresh();
                }
                draft.onCompleted({success: true, version: "b"});
                if (!editBeforeCompletion) draft.draft = {value: "later"};
                if (!snapshotFirst) {
                    backend.snapshot = {version: "b", [section]: {value: "sent"}};
                    draft.refresh();
                }
                assert.equal(draft.original.value, "sent");
                assert.equal(draft.draft.value, "later");
                assert.equal(draft.version, "b");
                assert.equal(draft.dirty, true);
                draft.apply();
                assert.equal(backend.request.version, "b");
                assert.equal(backend.request.values.value, "later");
            });
        }
    }
}

test("completion while closed protects the committed values on reopen and Discard until a fresh snapshot", () => {
    const backend = service();
    const draft = state("keyboard", backend);
    draft.refresh();
    draft.draft = {value: "sent"};
    draft.apply();
    // No page/polling claim survives; the service still caches version a.
    draft.onCompleted({success: true, version: "b"});
    assert.equal(draft.dirty, false);
    draft.refresh(); // Page reacquires the service before its snapshot arrives.
    assert.equal(draft.original.value, "sent");
    assert.equal(draft.draft.value, "sent");
    assert.equal(draft.version, "b");
    draft.draft = {value: "later"};
    draft.load(); // Explicit Discard also uses the settled baseline.
    assert.equal(draft.draft.value, "sent");
    assert.equal(draft.dirty, false);
    assert.equal(draft.version, "b");
    backend.snapshot = {version: "b", keyboard: {value: "sent"}};
    draft.refresh();
    draft.draft = {value: "next"};
    draft.apply();
    assert.equal(backend.request.version, "b");
});

test("a successful Apply never adopts an external writer's version for edits made during the request", () => {
    const backend = service();
    const draft = state("keyboard", backend);
    draft.refresh();
    draft.draft = {value: "sent"};
    draft.apply();
    draft.draft = {value: "later"};
    // Another writer commits c after our successful write b, before its reply.
    backend.snapshot = {version: "c", keyboard: {value: "external"}};
    draft.refresh();
    draft.onCompleted({success: true, version: "b"});
    draft.refresh();
    draft.apply();
    assert.equal(backend.request.version, "b");
    assert.equal(draft.original.value, "sent");
    draft.onCompleted({success: false});
    assert.equal(draft.draft.value, "later");
    draft.load();
    assert.equal(draft.draft.value, "external");
    assert.equal(draft.version, "c");
});

test("a success without its committed version cannot falsely settle the baseline", () => {
    const backend = service();
    const draft = state("keyboard", backend);
    draft.refresh();
    draft.draft = {value: "sent"};
    draft.apply();
    draft.onCompleted({success: true});
    assert.equal(draft.original.value, "old");
    assert.equal(draft.version, "a");
    assert.equal(draft.dirty, true);
});

test("a refused request cannot be mistaken for a submitted draft on unrelated success", () => {
    const backend = service();
    backend.run = () => false;
    const draft = state("keyboard", backend);
    draft.refresh();
    draft.draft = {value: "edited"};
    draft.apply();
    draft.onCompleted({success: true});
    assert.equal(draft.submitted, null);
    assert.equal(draft.original.value, "old");
    assert.equal(draft.dirty, true);
});
