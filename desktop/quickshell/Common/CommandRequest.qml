import QtQuick
import Quickshell.Io
import "ProcHelpers.js" as ProcHelpers

// One bounded subprocess request. Owns launch failure, stream collection and
// cancellation; domain owners only receive a completed response. A timed-out
// process never publishes partial stdout as a successful response.
Item {
    id: root
    property alias command: process.command
    // Request intent is separate from QProcess state. A failed start never
    // emits running=true, so resetting on that edge would reuse the previous
    // completion flag and strand every subsequent request.
    property bool running: false
    onRunningChanged: {
        if (!running) {
            if (process.running)
                process.running = false;
            return;
        }
        process.body = "";
        process.error = "";
        process.exitSeen = false;
        process.exitCode = ProcHelpers.NOT_STARTED;
        timedOut = false;
        settled = false;
        watchdog.interval = Math.max(1, timeoutMs);
        if (timeoutMs > 0)
            watchdog.restart();
        process.running = true;
    }
    property bool stdinEnabled: false
    property string inputText: ""
    property int timeoutMs: 30000
    property int killGraceMs: 5000
    property string timeoutMessage: "Command timed out"
    property bool timedOut: false
    property bool settled: false
    signal completed(int code, string body, string error)
    signal available()

    function finish(code, body, error) {
        if (settled)
            return;
        settled = true;
        completed(code, body, error);
    }

    function expire() {
        if (!process.running)
            return;
        if (!timedOut) {
            timedOut = true;
            watchdog.interval = killGraceMs;
            watchdog.restart();
            process.running = false;
        } else {
            process.signal(9);
            finish(124, "", timeoutMessage);
        }
    }

    Process {
        id: process
        stdinEnabled: root.stdinEnabled
        onStarted: if (root.stdinEnabled) write(root.inputText)
        property string body: ""
        property string error: ""
        property bool exitSeen: false
        property int exitCode: ProcHelpers.NOT_STARTED
        stdout: StdioCollector { onStreamFinished: process.body = text }
        stderr: StdioCollector { onStreamFinished: process.error = text }
        onExited: code => {
            exitSeen = true;
            exitCode = code;
        }
        onRunningChanged: {
            if (running)
                return;
            root.running = false;
            watchdog.stop();
            if (root.timedOut)
                root.finish(124, "", root.timeoutMessage);
            else
                root.finish(exitSeen ? exitCode : ProcHelpers.NOT_STARTED, body, error);
            root.available();
        }
    }
    Timer { id: watchdog; onTriggered: root.expire() }
}
