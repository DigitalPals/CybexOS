import QtQuick
import ".."

// Workspace pager.
BarModule {
    id: root

    moduleId: "ws"

    Workspaces {
        host: root.host
    }
}
