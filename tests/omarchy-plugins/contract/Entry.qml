import QtQuick
import Quickshell
Item {
    id: root
    property var shell: null
    property var service: null
    property var manifest: null
    property var pluginRegistry: null
    property var settings: ({})
    property bool opened: false
    property var received: []
    function open(payload) { received = received.concat([payload]); opened = true; }
    function close() { opened = false; }
    function echo(value) { return value; }
    FloatingWindow {
        visible: root.opened
        implicitWidth: 180
        implicitHeight: 60
        Text { text: root.manifest ? root.manifest.name : "loading" }
    }
}
