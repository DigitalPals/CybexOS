pragma ComponentBehavior: Bound
import QtQuick
import "../Common"
import "PluginSource.js" as PluginSource

// Omarchy plugins: community bar widgets, panels, overlays, menus and
// services built for Omarchy's shell, which Cybex runs unchanged. The page
// leads with where to find them (plugins.omarchy.org), then the three steps
// from there to a running plugin — copy its install command, paste it into
// Source, switch it on — and ends with the installed list, each plugin with
// its switch. Plugin widgets are added from the Bar page's tray like any
// other widget, so this page no longer links there.
//
// The helper runs one command at a time and reports the last one. Its
// output reads under whatever asked for it — the Source row for an install,
// the plugin's own row for an update, clone or removal — rather than at the
// top of a page that may be scrolled far from it.
SettingsPage {
    id: page

    readonly property string directoryUrl: "https://plugins.omarchy.org/"
    // "install", a plugin id, or "" for a failure nobody here asked for
    // (a registry that will not read, a scan that timed out).
    property string actionTarget: ""
    readonly property string status: UserPlugins.busy ? "Working…"
        : UserPlugins.error || UserPlugins.operationResult
    readonly property string statusTone: UserPlugins.error !== "" && !UserPlugins.busy ? "error" : "info"
    // A result for a plugin that is gone (removed, or replaced by its
    // clone) reads under the Source row instead of nowhere.
    readonly property bool targetListed: UserPlugins.plugins.some(plugin => plugin.id === actionTarget)
    // What Install would install: the URL out of a pasted
    // "omarchy plugin add <url>" command, or the field as typed.
    readonly property string source: PluginSource.parse(sourceRow.text)

    function run(target, args) {
        actionTarget = target;
        UserPlugins.enqueue(["python3", UserPlugins.helper].concat(args));
    }

    function install() {
        if (page.source === "" || UserPlugins.busy)
            return;
        page.run("install", ["add", page.source]);
    }

    // One numbered step of the how-to: a small number in a chip on the row
    // labels' lane, its copy beside it.
    component Step: Item {
        id: step

        property int number: 1
        property string text: ""

        implicitHeight: Math.max(badge.height, copy.implicitHeight)

        Rectangle {
            id: badge
            x: Theme.settingsMarkInset
            y: Math.max(0, (copy.lineHeightPx - height) / 2)
            width: Theme.scaled(20, Theme.typeScale)
            height: width
            radius: width / 2
            color: Theme.chip

            Text {
                anchors.centerIn: parent
                text: step.number
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.caption
                font.weight: Theme.weightSemibold
                color: Theme.accentText
            }
        }

        Text {
            id: copy
            readonly property real lineHeightPx: lineCount > 0 ? implicitHeight / lineCount : implicitHeight
            x: badge.x + badge.width + Theme.controlSpacing + Theme.iconTextSpacing
            width: Math.max(0, step.width - x)
            text: step.text
            textFormat: Text.StyledText
            font.family: Theme.fontMenu
            font.pixelSize: Theme.typography.secondary
            color: Theme.textMid
            linkColor: Theme.accentText
            wrapMode: Text.Wrap
            onLinkActivated: link => Qt.openUrlExternally(link)

            HoverHandler {
                enabled: copy.hoveredLink !== ""
                cursorShape: Qt.PointingHandCursor
            }
        }
    }

    Column {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Theme.settingsGroupSpacing

        // Where Omarchy plugins come from, and the way there.
        Item {
            id: directory

            readonly property bool stacked: width < Theme.settingsNarrowWidth
            readonly property real copyX: Theme.settingsMarkInset + mark.width + Theme.controlSpacing * 2
            readonly property real copyWidth: Math.max(0, width - copyX
                - (stacked ? 0 : browse.width + Theme.controlSpacing * 2))

            width: parent.width
            implicitHeight: stacked
                ? Math.max(mark.height, intro.implicitHeight) + Theme.settingsContentSpacing * 1.5 + browse.height
                : Math.max(mark.height, intro.implicitHeight, browse.height)

            Rectangle {
                id: mark
                x: Theme.settingsMarkInset
                width: Theme.scaled(44, Theme.typeScale)
                height: width
                radius: Theme.cardRadius + 3
                color: Theme.chip

                Sym {
                    anchors.centerIn: parent
                    name: "extension"
                    size: Theme.iconLarge
                    color: Theme.accentText
                }
            }

            Column {
                id: intro
                x: directory.copyX
                y: directory.stacked ? 0 : Math.max(0, (directory.height - height) / 2)
                width: directory.copyWidth
                spacing: Theme.scaled(3)

                Text {
                    width: parent.width
                    text: "Community plugins for your desktop"
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.primary
                    font.weight: Theme.weightSemibold
                    color: Theme.textHi
                    wrapMode: Text.Wrap
                }
                Text {
                    width: parent.width
                    text: "Bar widgets, panels, overlays, menus and services made for Omarchy. "
                        + "They run on CybexOS unchanged."
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.secondary
                    color: Theme.textFaint
                    wrapMode: Text.Wrap
                }
            }

            SettingsAction {
                id: browse
                x: directory.stacked ? directory.copyX : directory.width - width
                y: directory.stacked
                    ? Math.max(mark.height, intro.implicitHeight) + Theme.settingsContentSpacing * 1.5
                    : (directory.height - height) / 2
                primary: true
                glyph: "open_in_new"
                text: "Browse plugins"
                Accessible.description: "Opens " + page.directoryUrl + " in your browser"
                onTriggered: Qt.openUrlExternally(page.directoryUrl)
            }
        }

        SettingsGroup {
            width: parent.width
            title: "Add a plugin"

            Column {
                width: parent.width
                spacing: Theme.settingsContentSpacing
                bottomPadding: Theme.settingsContentSpacing

                Step {
                    width: parent.width
                    number: 1
                    text: "Pick a plugin on <a href=\"" + page.directoryUrl + "\">plugins.omarchy.org</a> and copy its install command."
                }
                Step {
                    width: parent.width
                    number: 2
                    text: "Paste it into Source below and press Install. A Git URL or a local folder works too."
                }
                Step {
                    width: parent.width
                    number: 3
                    text: "Switch it on under Installed. A bar widget then waits in the Bar page's Add widgets tray."
                }
            }

            FieldRow {
                id: sourceRow
                width: parent.width
                label: "Source"
                placeholder: "omarchy plugin add https://github.com/…"
                hint: "Plugins run as your desktop user. Install only packages you trust. New packages start disabled."
                onAccepted: page.install()

                SettingsAction {
                    text: "Install"
                    glyph: "download"
                    enabled: !UserPlugins.busy && page.source !== ""
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
            title: UserPlugins.plugins.length === 0 ? "Installed"
                : "Installed · " + UserPlugins.plugins.length

            // Empty state: what will appear here, in the row labels' lane.
            Item {
                width: parent.width
                visible: UserPlugins.plugins.length === 0
                implicitHeight: visible ? Math.max(emptyMark.height, emptyCopy.implicitHeight) : 0

                Sym {
                    id: emptyMark
                    x: Theme.settingsMarkInset
                    y: Math.max(0, (emptyTitle.implicitHeight - height) / 2)
                    name: "extension"
                    size: Theme.iconMedium
                    color: Theme.textFaint
                }
                Column {
                    id: emptyCopy
                    x: emptyMark.x + emptyMark.width + Theme.controlSpacing + Theme.iconTextSpacing
                    width: Math.max(0, parent.width - x)
                    spacing: Theme.scaled(2)

                    Text {
                        id: emptyTitle
                        width: parent.width
                        text: "No plugins yet"
                        font.family: Theme.fontMenu
                        font.pixelSize: Theme.typography.control
                        color: Theme.textMid
                        wrapMode: Text.Wrap
                    }
                    Text {
                        width: parent.width
                        text: "Plugins you install appear here, switched off until you turn them on."
                        font.family: Theme.fontMenu
                        font.pixelSize: Theme.typography.secondary
                        color: Theme.textFaint
                        wrapMode: Text.Wrap
                    }
                }
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
