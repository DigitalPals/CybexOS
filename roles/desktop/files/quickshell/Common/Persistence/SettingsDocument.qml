import QtQuick
import "../SettingsHelpers.js" as Helpers

// The production document state is independent of FileView/Process so the
// same asynchronous transitions run under QtTest and the desktop engine.
QtObject {
    id: document
    property var values: ({})
    property var context: ({})
    property var source: ({})
    property var explicitKeys: []
    property string baseline: ""
    property string submitted: ""
    property bool busy: false

    function text() {
        return Helpers.serializeDocument(values, source, explicitKeys);
    }

    function begin() {
        if (busy)
            return false;
        submitted = text();
        busy = true;
        return true;
    }

    function complete(committed) {
        // A second UI change may arrive while fsync or another writer holds
        // the lock. Rebase only that pending change onto the committed result.
        const before = Helpers.parse(submitted).value || ({});
        const pending = Helpers.parse(text()).value || ({});
        const saved = Helpers.parse(committed);
        if (saved.status !== "ok")
            throw new Error("Settings writer returned an invalid document");
        const rebased = Helpers.rebaseDocuments(before, pending, saved.value);
        baseline = committed;
        source = saved.value;
        explicitKeys = Helpers.overrideKeys(rebased);
        submitted = "";
        busy = false;
        return { values: Helpers.merge(rebased, context),
            pending: JSON.stringify(rebased) !== JSON.stringify(saved.value) };
    }

    function abandon() {
        submitted = "";
        busy = false;
    }
}
