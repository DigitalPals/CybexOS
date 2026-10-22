import QtQuick
import QtWebSockets

// Thin WebSocket wrapper loaded dynamically by T3Code so a machine
// without the QtWebSockets QML module degrades
// to an offline chip instead of taking down the whole shell.
Item {
    id: root

    property string url: ""
    property bool active: false
    // Transport generation that opened this socket. The connection singleton
    // ignores late frames/status changes from an invalidated credential.
    property int sessionEpoch: 0
    property int activeSessionEpoch: -1

    // Mirrors WebSocket.status without leaking the enum import upstream:
    // 0 connecting · 1 open · 2 closing · 3 closed · 4 error
    readonly property int status: sock.status
    readonly property bool open: sock.status === WebSocket.Open
    readonly property string errorString: sock.errorString

    signal textReceived(string message, int epoch)
    signal socketStatusChanged(int status, string error, int epoch)

    onActiveChanged: {
        if (active)
            activeSessionEpoch = sessionEpoch;
        // Assign imperatively so activeSessionEpoch is captured before the
        // underlying socket sees activation. A binding offers no such order.
        sock.active = active;
    }

    function sendText(message) {
        if (sock.status === WebSocket.Open)
            sock.sendTextMessage(message);
    }

    WebSocket {
        id: sock
        url: root.url
        active: false
        onTextMessageReceived: message => root.textReceived(message,
            root.activeSessionEpoch)
        onStatusChanged: root.socketStatusChanged(sock.status, sock.errorString,
            root.activeSessionEpoch)
    }
}
