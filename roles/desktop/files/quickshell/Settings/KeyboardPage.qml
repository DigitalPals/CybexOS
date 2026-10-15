pragma ComponentBehavior: Bound
import QtQuick
import "../Common"
import "InputDraft.js" as Draft

SettingsPage {
    id: page
    readonly property SystemSettingsBackend service: SystemSettings.input
    property var draft: ({layouts: [], shortcut: ""})
    property var original: ({layouts: [], shortcut: ""})
    property string version: ""
    property string query: ""
    readonly property var changes: Draft.patch(draft, original, ["layouts", "shortcut"])
    readonly property bool dirty: Object.keys(changes).length > 0
    readonly property var catalog: service.snapshot.catalog || []
    readonly property string disabledReason: service.busy ? "Applying…" : !service.loaded ? "Loading…" : ""
    bottomInset: applyBar.reservedHeight

    function load() {
        if (!service.loaded || !service.snapshot.keyboard) return;
        original = Draft.clone(service.snapshot.keyboard);
        draft = Draft.clone(original);
        version = service.snapshot.version;
    }
    function editLayouts(value) { draft = Object.assign({}, draft, {layouts: value}); }
    function variants(layout) {
        const entry = catalog.find(choice => choice.value === layout);
        return entry ? entry.variants : [{value: "", label: I18n.tr("Default")}];
    }
    Claim {
        active: page.visible && Settings.panelOpen
        onClaimed: { page.service.acquire(); page.load(); }
        onReleased: page.service.release()
    }
    Connections {
        target: page.service
        function onSnapshotChanged() { if (!page.dirty) page.load(); }
        function onLoadedChanged() { if (!page.dirty) page.load(); }
        function onCompleted(result) { if (result.success) page.original = Draft.clone(page.draft); }
    }
    overlay: ApplyBar {
        id: applyBar
        pending: page.dirty
        title: I18n.tr("Keyboard changes not applied yet")
        detail: I18n.tr("Layouts apply to your desktop session.")
        busy: page.service.busy
        applyEnabled: page.service.loaded && page.draft.layouts.length > 0
        onDiscard: page.load()
        onApply: page.service.run({action: "apply", section: "keyboard", version: page.version, values: page.changes})
    }
    Column {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Theme.settingsGroupSpacing
        SystemServiceStatus { width: parent.width; service: page.service; notice: page.service.message }
        SettingsGroup {
            width: parent.width
            title: I18n.tr("Keyboard layouts")
            DraftFieldRow {
                width: parent.width
                label: I18n.tr("Find a layout")
                value: page.query
                mono: false
                placeholder: I18n.tr("Language or country")
                onEdited: text => page.query = text
            }
            Repeater {
                model: page.draft.layouts.length
                delegate: RowCluster {
                    id: entry
                    required property int index
                    readonly property var layout: page.draft.layouts[index]
                    width: parent.width
                    SelectRow {
                        width: parent.width
                        label: "Layout " + (entry.index + 1)
                        model: Draft.filtered(page.catalog, page.query, entry.layout.layout)
                        current: entry.layout.layout
                        disabledReason: page.disabledReason
                        onPicked: value => page.editLayouts(Draft.changeLayout(page.draft.layouts, entry.index, value, ""))
                    }
                    SelectRow {
                        width: parent.width
                        label: I18n.tr("Variant")
                        model: page.variants(entry.layout.layout)
                        current: entry.layout.variant || ""
                        disabledReason: page.disabledReason
                        onPicked: value => page.editLayouts(Draft.changeLayout(page.draft.layouts, entry.index, entry.layout.layout, value))
                    }
                    ValueRow {
                        width: parent.width
                        label: entry.index === 0 ? I18n.tr("Default layout") : I18n.tr("Layout order")
                        SettingsAction {
                            text: I18n.tr("Move up")
                            visible: entry.index > 0
                            enabled: !page.service.busy
                            onTriggered: page.editLayouts(Draft.move(page.draft.layouts, entry.index, -1))
                        }
                        SettingsAction {
                            text: I18n.tr("Remove")
                            enabled: page.draft.layouts.length > 1 && !page.service.busy
                            onTriggered: page.editLayouts(page.draft.layouts.filter((_, at) => at !== entry.index))
                        }
                    }
                }
            }
            ValueRow {
                width: parent.width
                label: I18n.tr("Add another layout")
                hint: I18n.tr("Up to four layouts; the first is used when you sign in.")
                SettingsAction {
                    text: I18n.tr("Add layout")
                    glyph: "add"
                    enabled: page.service.loaded && !page.service.busy && page.draft.layouts.length < 4 && page.catalog.length > 0
                    onTriggered: page.editLayouts(page.draft.layouts.concat([{layout: page.catalog.some(c => c.value === "us") ? "us" : page.catalog[0].value, variant: ""}]))
                }
            }
        }
        SettingsGroup {
            width: parent.width
            title: I18n.tr("Switch layouts")
            SelectRow {
                width: parent.width
                label: I18n.tr("Shortcut")
                current: page.draft.shortcut
                model: Draft.filtered([{value: "", label: I18n.tr("None")},
                    {value: "grp:alt_shift_toggle", label: I18n.tr("Alt + Shift")}, {value: "grp:ctrl_shift_toggle", label: I18n.tr("Ctrl + Shift")},
                    {value: "grp:caps_toggle", label: I18n.tr("Caps Lock")}], "", page.draft.shortcut)
                disabledReason: page.disabledReason
                onPicked: value => page.draft = Object.assign({}, page.draft, {shortcut: value})
            }
            ValueRow {
                width: parent.width
                label: I18n.tr("Current layout")
                value: (page.service.snapshot.keyboard?.active || []).map(device => device.layout).join(", ")
                SettingsAction {
                    text: I18n.tr("Next layout")
                    enabled: page.service.loaded && !page.service.busy && !page.dirty
                    onTriggered: page.service.run({action: "switch"})
                }
            }
        }
    }
}
