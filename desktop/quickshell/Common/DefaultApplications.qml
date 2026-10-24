pragma Singleton
import QtQuick
import Quickshell

Singleton {
    id: root
    property var roles: ({})
    readonly property bool busy: client.busy
    readonly property string error: client.error
    function refresh() { client.run(["cybexos-apps", "status"]); }
    function select(role, id) { client.run(["cybexos-apps", "set", role, id]); }
    JsonCommand {
        id: client
        onCompleted: value => root.roles = value.roles || ({})
    }
}
