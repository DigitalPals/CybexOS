pragma ComponentBehavior: Bound
import QtQuick
import "../Common"
import "../Common/WelcomeHelpers.js" as Helpers
import "../Settings" as SettingsUi
Column {
    id: root
    spacing: Theme.scaled(20)
    property string selected: ""
    // The keycaps follow the workspace where practice actually started.
    readonly property var workspaceActions: Helpers.workspaceActions(Welcome.tracker.start)
    // Names each shortcut of a two-step task, so "Not bound" is unambiguous.
    function actionLabel(id) {
        if (id.indexOf("workspaces.switch.") === 0) return I18n.format("Workspace %1", [id.split(".").pop()]);
        return ({"shell.launcher": I18n.tr("Launcher"), "apps.terminal": I18n.tr("Terminal"),
            "windows.close": I18n.tr("Close window"), "windows.overview": I18n.tr("Overview"),
            "shell.shortcuts": I18n.tr("Keyboard shortcuts")})[id] || id;
    }
    readonly property var tasks: [
        {id: "launcher", title: I18n.tr("Open the launcher"), detail: I18n.tr("Find apps, settings and actions in one place."), actions: ["shell.launcher"]},
        {id: "terminal", title: I18n.tr("Open and close a terminal"), detail: I18n.tr("Open a terminal, then close that new window with the second shortcut."), actions: ["apps.terminal", "windows.close"]},
        {id: "workspace", title: I18n.tr("Visit another workspace"), detail: I18n.format("Switch to workspace %1, then return to the workspace where you started.", [root.workspaceActions[0].split(".").pop()]), actions: root.workspaceActions},
        {id: "overview", title: I18n.tr("See all your windows"), detail: I18n.tr("Open the overview for a little more perspective."), actions: ["windows.overview"]},
        {id: "shortcuts", title: I18n.tr("Open the shortcut sheet"), detail: I18n.tr("Your shortcuts are always one key combination away."), actions: ["shell.shortcuts"]}
    ]
    readonly property var current: tasks.find(task => task.id === selected)
        || tasks.find(task => !Welcome.practice[task.id]) || tasks[tasks.length - 1]
    readonly property bool done: tasks.every(task => Welcome.practice[task.id])
    // A narrow guide (small window or large text) puts the task list below.
    readonly property bool stacked: width < Theme.scaled(600)
    Grid {
        width: parent.width; columns: root.stacked ? 1 : 2
        columnSpacing: Theme.scaled(18); rowSpacing: Theme.scaled(18)
        Rectangle {
            width: root.stacked ? parent.width : Math.max(0, parent.width - taskList.width - parent.columnSpacing)
            height: Math.max(card.implicitHeight + Theme.scaled(48), root.stacked ? 0 : Math.max(Theme.scaled(300), taskList.height))
            radius: Theme.cardRadius; color: Theme.accentBgSoft
            border.width: Settings.highContrast ? 1 : 0; border.color: Theme.stroke
            Column {
                id: card
                anchors.fill: parent; anchors.margins: Theme.scaled(24); spacing: Theme.scaled(18)
                GuideText { width: parent.width; text: root.done ? I18n.tr("You have the essentials.") : root.current.title; font.pixelSize: Theme.typography.title; font.weight: Theme.weightSemibold }
                Repeater {
                    model: root.current.actions
                    delegate: Column {
                        id: action
                        required property string modelData
                        readonly property var combos: Welcome.keysFor(action.modelData)
                        width: parent.width; spacing: Theme.controlSpacing
                        Accessible.role: Accessible.StaticText
                        Accessible.name: I18n.format("%1: %2", [root.actionLabel(action.modelData), action.combos.length > 0
                            ? action.combos.map(caps => caps.join("+")).join(", ") : unbound.text])
                        GuideText {
                            visible: root.current.actions.length > 1
                            text: root.actionLabel(action.modelData); tone: "muted"; font.pixelSize: Theme.typography.secondary
                        }
                        Keycaps { combos: action.combos; large: true; visible: action.combos.length > 0 }
                        GuideText {
                            id: unbound
                            visible: action.combos.length === 0 && (Keybindings.loaded || !Keybindings.busy)
                            width: parent.width; tone: "muted"
                            // Loaded but empty: the user disabled or never had
                            // this binding. Not loaded: shortcuts are unavailable.
                            text: Keybindings.loaded ? I18n.tr("Not bound")
                                : I18n.tr("No live binding is available. You can continue and try this later.")
                        }
                    }
                }
                GuideText { width: parent.width; text: root.current.detail; tone: "muted" }
                Row {
                    spacing: Theme.controlSpacing
                    Rectangle {
                        id: pulse
                        width: Theme.scaled(8); height: width; radius: width / 2
                        anchors.verticalCenter: parent.verticalCenter
                        color: root.done ? Theme.connected : Theme.accent
                        SequentialAnimation on opacity {
                            running: !root.done && !Theme.reducedMotion && root.visible
                            loops: Animation.Infinite
                            NumberAnimation { to: 0.35; duration: Theme.surfaceDuration * 2 }
                            NumberAnimation { to: 1; duration: Theme.surfaceDuration * 2 }
                        }
                    }
                    GuideText { text: root.done ? I18n.tr("All five tried. Nicely done.") : I18n.tr("Waiting for you…"); tone: "accent"; font.pixelSize: Theme.typography.secondary }
                }
            }
        }
        Column {
            id: taskList
            width: root.stacked ? parent.width : Theme.scaled(210); spacing: Theme.scaled(12)
            Repeater {
                model: root.tasks
                delegate: SettingsUi.SettingsAction {
                    id: task
                    required property var modelData
                    width: taskList.width
                    height: Theme.scaled(48)
                    text: modelData.title
                    glyph: Welcome.practice[modelData.id] ? "check" : "circle"
                    color: root.current.id === modelData.id ? Theme.accentBg : "transparent"
                    Accessible.name: I18n.format("%1: %2", [modelData.title,
                        Welcome.practice[modelData.id] ? I18n.tr("Done") : I18n.tr("Not tried yet")])
                    onTriggered: root.selected = modelData.id
                }
            }
        }
    }
    GuideText { width: parent.width; text: I18n.tr("Super is the key with the Windows or ⌘ logo. Try these on your real desktop; the guide will follow you between workspaces."); tone: "muted" }
    GuideText { width: parent.width; text: I18n.tr("There is no test to pass. Continue whenever you are ready."); tone: "muted"; font.pixelSize: Theme.typography.secondary }
}
