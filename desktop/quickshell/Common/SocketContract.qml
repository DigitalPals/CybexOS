import QtQuick

// Typed surface shared by WebSocket wrappers that are loaded by URL. The
// wrappers themselves stay out of qmldir so QtWebSockets remains optional.
Item {
    property string url: ""
    property bool active: false
    property int generation: 0

    function sendText(message) {}
}
