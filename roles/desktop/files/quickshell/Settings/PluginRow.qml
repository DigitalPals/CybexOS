pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls as Controls
import "../Common"

// One installed plugin on the Plugins page: its name, what it is and what it
// adds, and an Enabled switch — the one thing most people change. Update,
// Preview update, Clone and Remove are for the people who develop or pin
// plugins, so they sit one step away in the ⋯ menu. Clone asks for the new
// ID and Remove for confirmation in a row that opens under this one; the
// result of the last action taken here, and any load error, read beneath.
RowCluster {
    id: root

    required property var plugin
    // The helper's latest output, when this plugin was the last one acted on.
    property string status: ""
    property string statusTone: "info"
    // Asks the page to run the plugin helper with these arguments.
    signal run(var args)

    property bool cloning: false
    property bool confirmRemoval: false

    // Each kind a manifest declares, as the thing it adds to the desktop.
    readonly property var kindLabels: ({
        "bar-widget": "a bar widget",
        "panel": "a panel",
        "overlay": "an overlay",
        "menu": "a menu",
        "service": "a background service",
        "bar": "a replacement bar"
    })
    readonly property string adds: {
        const parts = (plugin.kinds || []).map(kind => kindLabels[kind] || "").filter(part => part !== "");
        if (parts.length === 0)
            return "";
        return "adds " + (parts.length === 1 ? parts[0]
            : parts.slice(0, -1).join(", ") + " and " + parts[parts.length - 1]);
    }
    readonly property string loadError: plugin.error || Object.keys(OmarchyPlugins.errors)
        .filter(key => key.startsWith(plugin.id + ":"))
        .map(key => OmarchyPlugins.errors[key]).join("\n")

    function startClone() {
        confirmRemoval = false;
        cloning = true;
        Qt.callLater(cloneRow.focusField);
    }

    SettingsRow {
        id: row
        width: parent.width
        label: root.plugin.name
        hint: [root.plugin.id, root.plugin.version || "Unknown version", root.adds]
            .filter(part => part !== "").join(" · ")
        // A plugin is enabled or not; there is no default to go back to.
        dirty: false
        resetKeys: []
        narrowHeight: Theme.settingsControlHeight
        narrowLabelY: Math.max(0, Math.round((Theme.settingsControlHeight - row.labelTextHeight) / 2))
        narrowLabelInset: controls.width + row.undoWidth + Theme.controlSpacing
        controlLeft: controls.x

        Row {
            id: controls
            x: row.contentRight - width
            y: (row.lineHeight - height) / 2
            spacing: Theme.controlSpacing

            Toggle {
                anchors.verticalCenter: parent.verticalCenter
                metrics: Theme.switchRow
                checked: root.plugin.enabled === true
                enabled: !UserPlugins.busy
                opacity: enabled ? 1 : 0.45
                accessibleName: "Enable " + root.plugin.name
                onToggled: value => root.run([value ? "enable" : "disable", root.plugin.id])
            }
            SettingsAction {
                id: more
                anchors.verticalCenter: parent.verticalCenter
                compact: true
                glyph: "more_horiz"
                text: "More actions for " + root.plugin.name
                tooltip: "More actions"
                onTriggered: menu.popup(more.width - menu.width, more.height + Theme.scaled(4))

                Controls.Menu {
                    id: menu
                    popupType: Controls.Popup.Item
                    focus: true
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.control
                    palette.window: Theme.popBg
                    palette.base: Theme.popBg
                    palette.text: Theme.textHi
                    palette.windowText: Theme.textHi
                    palette.buttonText: Theme.textHi
                    palette.highlight: Theme.chipHover
                    palette.highlightedText: Theme.textHi

                    Controls.MenuItem {
                        text: "Update"
                        enabled: !UserPlugins.busy
                        onTriggered: root.run(["update", root.plugin.id])
                    }
                    Controls.MenuItem {
                        text: "Preview update"
                        enabled: !UserPlugins.busy
                        onTriggered: root.run(["update", root.plugin.id, "--preview"])
                    }
                    Controls.MenuItem {
                        text: "Clone as a custom copy…"
                        enabled: !UserPlugins.busy
                        onTriggered: root.startClone()
                    }
                    Controls.MenuSeparator {}
                    Controls.MenuItem {
                        text: "Remove…"
                        enabled: !UserPlugins.busy
                        palette.text: Theme.redText
                        palette.windowText: Theme.redText
                        palette.buttonText: Theme.redText
                        palette.highlightedText: Theme.redText
                        onTriggered: {
                            root.cloning = false;
                            root.confirmRemoval = true;
                        }
                    }
                }
            }
        }
    }

    SettingsHint {
        width: parent.width
        visible: root.loadError !== ""
        text: root.loadError
        tone: "error"
        maximumLines: 4
    }

    FieldRow {
        id: cloneRow
        width: parent.width
        divider: false
        visible: root.cloning
        label: "New ID"
        placeholder: root.plugin.id + "-custom"
        fieldWidth: Theme.scaled(240, Theme.typeScale)
        hint: "Copies the plugin under this ID for you to change. The copy is turned on and this one off."
        onAccepted: clone.trigger()

        SettingsAction {
            id: clone
            text: "Clone"
            glyph: "content_copy"
            enabled: !UserPlugins.busy && cloneRow.text.trim() !== ""
            Accessible.name: "Clone " + root.plugin.name
            function trigger() {
                if (!enabled)
                    return;
                root.run(["clone", root.plugin.id, cloneRow.text.trim()]);
                cloneRow.text = "";
                root.cloning = false;
            }
            onTriggered: trigger()
        }
        SettingsAction {
            text: "Cancel"
            onTriggered: {
                cloneRow.text = "";
                root.cloning = false;
            }
        }
    }

    ValueRow {
        width: parent.width
        divider: false
        visible: root.confirmRemoval
        label: "Remove this plugin?"
        hint: "Deletes its files. Its settings and data stay, so installing it again restores them."
        hintTone: "warning"

        SettingsAction {
            text: "Remove"
            glyph: "delete"
            danger: true
            enabled: !UserPlugins.busy
            Accessible.name: "Remove " + root.plugin.name
            onTriggered: {
                root.run(["remove", root.plugin.id]);
                root.confirmRemoval = false;
            }
        }
        SettingsAction {
            text: "Cancel"
            onTriggered: root.confirmRemoval = false
        }
    }

    SettingsHint {
        width: parent.width
        visible: root.status !== ""
        text: root.status
        tone: root.statusTone
        maximumLines: 6
    }
}
