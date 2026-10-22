import QtQuick
import "../LocationHelpers.js" as LocationHelpers

// A view-owned search. Cancel on edits/close; a late reply must never select a
// city for an older query. Typing only previews; Enter can apply a sole match.
QtObject {
    id: root

    property string query: ""
    property var results: []
    property bool busy: false
    property bool searched: false
    property string error: ""
    property bool applySingle: false
    property var request: null
    property int generation: 0
    property var createRequest: () => new XMLHttpRequest()
    signal chosen(var location)

    function cancel() {
        generation++;
        debounce.stop();
        deadline.stop();
        const old = request;
        request = null;
        busy = false;
        applySingle = false;
        if (old) {
            old.onreadystatechange = null;
            old.abort();
        }
    }

    function edit(text) {
        cancel();
        query = text.trim();
        results = [];
        searched = false;
        error = "";
        if (query.length >= 2)
            debounce.restart();
    }

    function choose(index) {
        if (index < 0 || index >= results.length)
            return;
        const location = results[index];
        cancel();
        results = [];
        searched = false;
        error = "";
        chosen(location);
    }

    function submit() {
        if (query.length < 2)
            return;
        if (searched && error === "" && results.length > 0) {
            if (results.length === 1)
                choose(0);
            return;
        }
        if (busy) {
            applySingle = true;
            return;
        }
        search(true);
    }

    function fail(message) {
        cancel();
        results = [];
        searched = true;
        error = message;
    }

    function search(acceptSingle) {
        cancel();
        if (query.length < 2)
            return;
        busy = true;
        searched = false;
        error = "";
        applySingle = acceptSingle;
        const token = generation;
        try {
            const xhr = createRequest();
            request = xhr;
            xhr.onreadystatechange = () => {
                if (token !== root.generation || xhr.readyState !== 4)
                    return;
                deadline.stop();
                root.request = null;
                root.busy = false;
                root.searched = true;
                if (xhr.status !== 200) {
                    root.fail("City search is unavailable. Check your connection and try again.");
                    return;
                }
                try {
                    root.results = LocationHelpers.parseResults(xhr.responseText);
                } catch (e) {
                    root.fail("The location service returned an unreadable response. Try again.");
                    return;
                }
                if (root.applySingle && root.results.length === 1)
                    root.choose(0);
            };
            xhr.open("GET", LocationHelpers.searchUrl(query));
            deadline.restart();
            xhr.send();
        } catch (e) {
            fail("City search could not start. Try again.");
        }
    }

    property Timer debounce: Timer {
        interval: 400
        onTriggered: root.search(false)
    }
    property Timer deadline: Timer {
        interval: 10000
        onTriggered: root.fail("City search timed out. Check your connection and try again.")
    }

    Component.onDestruction: cancel()
}
