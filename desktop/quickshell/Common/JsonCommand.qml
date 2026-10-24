import QtQuick
import Quickshell

// A finite JSON helper request. Missing executables and rejected requests also
// settle, without forwarding arbitrary diagnostics into the desktop journal.
Scope {
    id: root
    readonly property bool busy: process.running
    property var result: ({})
    property string error: ""
    signal completed(var value)
    signal failed(string message)

    function run(args) {
        if (process.running) return false;
        error = "";
        process.command = args;
        process.running = true;
        return true;
    }

    CommandRequest {
        id: process
        timeoutMs: 650000
        onCompleted: (code, body, diagnostics) => {
            let value = null;
            try { value = JSON.parse(body); } catch (_) {}
            if (code !== 0 || !value) {
                let failure = null;
                try { failure = JSON.parse(diagnostics); } catch (_) {}
                root.error = (failure && failure.error) || (value && value.error)
                    || (code === -1 ? "The helper could not be started." : "The request failed. Retry or inspect its private log.");
                root.failed(root.error);
                return;
            }
            root.result = value;
            root.completed(value);
        }
    }
}
