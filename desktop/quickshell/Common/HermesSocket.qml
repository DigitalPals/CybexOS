import QtQuick
import QtWebSockets

// Loaded by URL so systems without QtWebSockets keep a working shell and get
// an actionable offline Hermes panel instead of failing the whole QML graph.
SocketContract {
    id: root

    property int activeGeneration: -1

    readonly property int status: socket.status
    readonly property bool open: socket.status === WebSocket.Open
    readonly property string errorString: socket.errorString

    signal textReceived(string message, int generation)
    signal socketStatusChanged(int status, string error, int generation)

    onActiveChanged: {
        if (active)
            activeGeneration = generation;
        socket.active = active;
    }

    function sendText(message) {
        if (socket.status === WebSocket.Open)
            socket.sendTextMessage(message);
    }

    WebSocket {
        id: socket
        url: root.url
        active: false
        onTextMessageReceived: message => root.textReceived(message,
            root.activeGeneration)
        onStatusChanged: root.socketStatusChanged(socket.status,
            socket.errorString, root.activeGeneration)
    }
}
