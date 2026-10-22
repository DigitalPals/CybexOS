pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// Origin-to-favicon resolver shared by every toast and notification-history
// row. One worker serializes lookups so the same burst cannot fan out into a
// process per card; reassigning `sources` invalidates consumers when a lookup
// finishes.
Singleton {
    id: root

    readonly property string helper:
        Quickshell.shellDir + "/scripts/notification-icon.py"
    property var sources: ({})
    property var requested: ({})
    property var queue: []
    property string activeOrigin: ""

    function sourceFor(origin) {
        return sources[String(origin || "")] || "";
    }

    function request(origin) {
        const key = String(origin || "");
        if (key === "" || Object.prototype.hasOwnProperty.call(requested, key))
            return;
        const updated = Object.assign({}, requested);
        updated[key] = true;
        requested = updated;
        queue = queue.concat([key]);
        Qt.callLater(startNext);
    }

    function startNext() {
        if (worker.running || activeOrigin !== "" || queue.length === 0)
            return;
        activeOrigin = queue[0];
        queue = queue.slice(1);
        worker.body = "";
        worker.command = ["python3", helper, activeOrigin];
        worker.running = true;
    }

    function finish() {
        const origin = activeOrigin;
        const value = worker.body.trim();
        const usable = value.startsWith("file://") || value.startsWith("https://")
            ? value : "";
        activeOrigin = "";
        if (origin !== "") {
            const updated = Object.assign({}, sources);
            updated[origin] = usable;
            sources = updated;
        }
        Qt.callLater(startNext);
    }

    Process {
        id: worker
        property string body: ""

        stdout: StdioCollector {
            onStreamFinished: worker.body = text
        }
        onRunningChanged: {
            if (!running && root.activeOrigin !== "")
                root.finish();
        }
    }
}
