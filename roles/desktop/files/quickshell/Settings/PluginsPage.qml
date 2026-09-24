pragma ComponentBehavior: Bound
import QtQuick
import "../Common"

// Plugins: install a package from a source, then turn each one on or off.
// Plugin widgets are added from the Bar page's tray like any other widget,
// so this page no longer links there.
//
// The helper runs one command at a time and reports the last one. Its
// output reads under whatever asked for it — the Source row for an install,
// the plugin's own row for an update, clone or removal — rather than at the
// top of a page that may be scrolled far from it.
SettingsPage {
    id: page

    // "install", a plugin id, or "" for a failure nobody here asked for
    // (a registry that will not read, a scan that timed out).
    property string actionTarget: ""
    readonly property string status: UserPlugins.busy ? "Working…"
        : UserPlugins.error || UserPlugins.operationResult
    readonly property string statusTone: UserPlugins.error !== "" && !UserPlugins.busy ? "error" : "info"
    // A result for a plugin that is gone (removed, or replaced by its
    // clone) reads under the Source row instead of nowhere.
    readonly property bool targetListed: UserPlugins.plugins.some(plugin => plugin.id === actionTarget)

    function run(target, args) {
        actionTarget = target;
        UserPlugins.enqueue(["python3", UserPlugins.helper].concat(args));
    }

    function install() {
        const source = sourceRow.text.trim();
        if (source === "" || UserPlugins.busy)
            return;
        page.run("install", ["add", source]);
    }

    Column {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Theme.settingsGroupSpacing

        SettingsGroup {
            width: parent.width
            title: "Install plugin"

            FieldRow {
                id: sourceRow
                width: parent.width
                label: "Source"
                placeholder: "Git repository URL or local path"
                hint: "Plugins run as your desktop user. Install only packages you trust. New packages start disabled."
                onAccepted: page.install()

                SettingsAction {
                    text: "Install"
                    glyph: "add"
                    enabled: !UserPlugins.busy && sourceRow.text.trim() !== ""
                    onTriggered: page.install()
                }
            }
            SettingsHint {
                width: parent.width
                text: page.targetListed ? "" : page.status
                tone: page.statusTone
                maximumLines: 6
            }
        }

        SettingsGroup {
            width: parent.width
            title: "Installed"

            SettingsHint {
                width: parent.width
                text: UserPlugins.plugins.length === 0 ? "None yet. Installed plugins appear here, turned off until you enable them." : ""
            }

            Repeater {
                model: UserPlugins.plugins

                delegate: PluginRow {
                    required property var modelData
                    width: parent.width
                    plugin: modelData
                    status: page.targetListed && page.actionTarget === modelData.id ? page.status : ""
                    statusTone: page.statusTone
                    onRun: args => page.run(modelData.id, args)
                }
            }
        }
    }
}
