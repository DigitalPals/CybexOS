pragma Singleton
import QtQuick
import "../Common"

QtObject {
    id: root
    property var service: SystemSettings.input
    readonly property InputDraftState keyboard: InputDraftState {
        service: root.service
        section: "keyboard"
        fields: ["layouts", "shortcut"]
        draft: ({layouts: [], shortcut: ""})
        original: ({layouts: [], shortcut: ""})
    }
    readonly property InputDraftState touchpad: InputDraftState {
        service: root.service
        section: "touchpad"
        fields: ["tap", "naturalScroll", "workspaceSwipe", "sensitivity"]
        draft: ({tap: true, naturalScroll: true, workspaceSwipe: true, sensitivity: 0})
        original: ({tap: true, naturalScroll: true, workspaceSwipe: true, sensitivity: 0})
    }
}
