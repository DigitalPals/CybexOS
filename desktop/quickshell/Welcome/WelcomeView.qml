pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Window
import "../Common"

// The guide's 1280×800 design canvas, drawn like the installer: the top bar
// with the wordmark, the Connect · Wallpaper · Style · Shortcuts steps and the
// status pills; the step below it, which owns its footer; and the
// installer-style sheets over everything. Hello and Ready stand outside the
// numbered steps, as the installer's welcome and done screens stand outside
// Disk · You · Review. Connect is left out when there is nothing to connect.
FocusScope {
    id: root
    property bool peeking: false
    readonly property var names: ({connect: I18n.tr("Connect"), wallpaper: I18n.tr("Wallpaper"),
        style: I18n.tr("Style"), shortcuts: I18n.tr("Shortcuts")})
    readonly property var numbered: Welcome.steps.filter(id => id in root.names)
    readonly property var stepNames: root.numbered.map(id => root.names[id])
    readonly property int stepperIndex: root.numbered.indexOf(Welcome.step) + 1
    readonly property bool sheetOpen: Welcome.sheet !== ""
    width: Kiosk.px(1280)
    height: Kiosk.px(800)
    focus: true
    function focusInitial() { root.forceActiveFocus(); }
    Keys.onPressed: event => {
        if (event.key === Qt.Key_Escape) {
            root.peeking = false;
            if (root.sheetOpen) Welcome.closeSheet(); else Welcome.leave("dismiss");
            event.accepted = true;
        } else if (root.sheetOpen) {
            // A key a sheet left alone does not move the guide beneath it.
        } else if (event.modifiers & Qt.ControlModifier) {
            if (event.key === Qt.Key_PageDown || event.key === Qt.Key_PageUp) {
                Welcome.move(event.key === Qt.Key_PageDown ? 1 : -1);
                event.accepted = true;
            }
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            if (Welcome.step === "finish") Welcome.finish(); else Welcome.move(1);
            event.accepted = true;
        }
    }
    // Holding Space peeks at the desktop from the Wallpaper and Style steps,
    // also with a tile or button focused (Enter activates those), except in
    // a text field such as Wallhaven search, where Space types. Qt Wayland
    // repeats a held key as release/press pairs: the non-repeating shortcut
    // swallows the repeated presses, and only the physical release ends it.
    readonly property Item focusedItem: root.Window.window ? root.Window.window.activeFocusItem : null
    readonly property bool typing: focusedItem instanceof TextInput || focusedItem instanceof TextEdit
    Keys.onReleased: event => {
        if (event.key === Qt.Key_Space && !event.isAutoRepeat && root.peeking) {
            root.peeking = false;
            event.accepted = true;
        }
    }
    Shortcut {
        sequence: "Space"
        context: Qt.WindowShortcut
        autoRepeat: false
        enabled: Welcome.open && !Welcome.aside && !root.sheetOpen && !root.typing
            && (Welcome.step === "wallpaper" || Welcome.step === "style")
        onActivated: root.peeking = true
    }
    Connections {
        target: root.Window.window
        function onActiveChanged() { if (root.Window.window && !root.Window.window.active) root.peeking = false; }
    }
    Connections {
        target: Welcome
        function onStepChanged() {
            root.peeking = false;
            Qt.callLater(root.focusInitial);
            fade.restart();
        }
        function onOpenChanged() { root.peeking = false; }
        function onAsideChanged() { root.peeking = false; }
        function onSheetChanged() { if (Welcome.sheet === "") Qt.callLater(root.focusInitial); }
    }
    Item {
        id: page
        anchors.fill: parent
        enabled: !root.sheetOpen
        opacity: root.peeking ? 0 : 1
        Behavior on opacity { NumberAnimation { duration: 140 } }
        KioskTopBar {
            id: topBar
            width: parent.width
            steps: root.stepNames
            current: root.stepperIndex
        }
        Loader {
            id: content
            y: topBar.height
            width: parent.width
            height: parent.height - y
            source: ({hello: "HelloStep.qml", connect: "ConnectStep.qml", wallpaper: "WallpaperStep.qml",
                style: "StyleStep.qml", shortcuts: "ShortcutsStep.qml", finish: "FinishStep.qml"})[Welcome.step]
            NumberAnimation { id: fade; target: content; property: "opacity"; from: 0; to: 1; duration: 160 }
        }
    }
    Loader {
        id: sheetLoader
        anchors.fill: parent
        active: root.sheetOpen && !root.peeking
        source: ({language: "LanguageSheet.qml", keyboard: "KeyboardSheet.qml", timezone: "TimezoneSheet.qml",
            theme: "ThemeSheet.qml", shortcuts: "ShortcutChangesSheet.qml"})[Welcome.sheet] || ""
        onLoaded: (item as Item)?.forceActiveFocus()
    }
}
