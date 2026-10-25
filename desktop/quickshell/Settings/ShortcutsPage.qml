pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import "../Common"
import "../Common/ShortcutEditor.js" as Helpers

// Settings → Keyboard shortcuts. Every row is a Keybindings action, in the
// Super+K sheet's group order: search by name or keys, filter what changed,
// what conflicts and what user.lua binds, record new keys, reset, disable,
// and add custom shortcuts. Edits form a draft that the Apply bar saves
// through the keybindings service; user.lua still loads last and wins.
// A keybindings.json the loader rejects makes the page read only: the banner
// says why, and only Reset all (which keeps the broken file) is offered.
SettingsPage {
    id: page
    objectName: "shortcutsPage"

    property string query: ""
    property string filter: "all"
    property string view: "list"
    property string currentId: ""
    property bool confirmingReset: false
    property string problem: ""
    // Where the recorder's result goes: a row's keys or the custom form.
    property string recordFor: "row"
    property var rowItems: ({})
    readonly property var groups: Helpers.groups(Keybindings.actions, Keybindings.userBinds,
        Keybindings.diagnostics, { query: page.query, filter: page.filter, translate: text => I18n.tr(text) })
    readonly property var order: groups.reduce((all, group) => all.concat(group.rows.map(row => row.id)), [])
    readonly property var counts: Helpers.counts(Keybindings.actions, Keybindings.userBinds, Keybindings.diagnostics)
    readonly property bool anyChanged: Keybindings.dirty
        || Keybindings.actions.some(row => row.custom || (row.changed && row.source !== "user"))
    readonly property bool readOnly: Keybindings.readOnly
    // The reset that replaces a rejected file is pending until applied.
    readonly property bool recovering: Keybindings.readOnly && Keybindings.dirty
    // Lua's load error is also preferencesError; the read-only banner shows it.
    readonly property string message: Keybindings.error !== "" && Keybindings.error !== Keybindings.preferencesError
        ? Keybindings.error : page.problem
    bottomInset: applyBar.reservedHeight

    Claim {
        active: page.visible && Settings.panelOpen
        onClaimed: Keybindings.acquire()
        onReleased: Keybindings.release()
    }
    Connections {
        target: Keybindings
        function onFailed(message) { page.problem = message; }
        function onApplied() { page.problem = ""; }
    }

    function edit(id) {
        problem = "";
        const row = Keybindings.action(id);
        if (!row || !row.editable || readOnly)
            return;
        if (row.custom) {
            form.begin(id);
            return;
        }
        recordFor = "row";
        recorder.start(id, row.label, row.keys, true, Helpers.lockedKeys(row));
    }
    function add(combo, type) {
        problem = "";
        if (!readOnly)
            form.begin("", combo || "", type || "app");
    }
    function recorded(combo, mode) {
        if (recordFor === "form") {
            form.setKeys(Helpers.nextKeys(form.keys, combo, "replace"));
            return;
        }
        // A protected action's locked defaults stay; only its extra keys change.
        const keys = Helpers.nextKeys(Helpers.editableKeys(Keybindings.action(recorder.actionId)), combo, mode);
        if (keys)
            Keybindings.setKeys(recorder.actionId, keys);
        focusRow(recorder.actionId);
    }
    // Focus moves before `currentId` does: the current row is the tab stop,
    // and Qt will not drop activeFocusOnTab from the row that has focus.
    function focusRow(id) {
        Qt.callLater(() => {
            const item = page.rowItems[id];
            if (item)
                item.forceActiveFocus();
            page.currentId = id;
        });
    }
    // SettingsView's Escape chain: an open reset question or Add form closes
    // first, so only a second Escape closes Settings.
    function handleEscape(): bool {
        if (confirmingReset) {
            confirmingReset = false;
            return true;
        }
        if (form.opened) {
            form.close();
            Qt.callLater(() => page.forceActiveFocus());
            return true;
        }
        return false;
    }
    function moveFocus(id, delta) {
        const at = order.indexOf(id);
        if (at >= 0)
            focusRow(order[Math.max(0, Math.min(order.length - 1, at + delta))]);
    }

    overlay: [
        ApplyBar {
            id: applyBar
            pending: Keybindings.dirty
            title: I18n.tr("Shortcut changes not applied yet")
            detail: page.message !== "" ? page.message
                : page.recovering ? I18n.tr("Apply replaces keybindings.json with the defaults. The broken file is kept beside it as keybindings.json.invalid-<time>.")
                : I18n.tr("Apply reloads Hyprland. Your user.lua still loads last.")
            busy: Keybindings.backend.busy
            applyEnabled: Keybindings.loaded
            onApply: { page.problem = ""; Keybindings.apply(); }
            onDiscard: { page.problem = ""; Keybindings.discard(); }
        },
        ShortcutRecorder {
            id: recorder
            objectName: "shortcutRecorder"
            onAccepted: (combo, mode) => page.recorded(combo, mode)
            onCanceled: if (page.recordFor === "row") page.focusRow(recorder.actionId)
        }
    ]

    Column {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Theme.settingsGroupSpacing

        SettingsHint {
            width: parent.width
            visible: text !== ""
            text: page.message !== "" ? page.message
                : !Keybindings.loaded ? I18n.tr("Loading shortcuts…") : ""
            tone: page.message !== "" ? "error" : "info"
        }
        // keybindings.json was rejected: the defaults are in effect and
        // nothing can be edited until Reset all replaces the file.
        SettingsHint {
            objectName: "shortcutsReadOnly"
            width: parent.width
            visible: page.readOnly
            text: Keybindings.preferencesError
            tone: "error"
        }
        SettingsHint {
            width: parent.width
            visible: page.readOnly
            text: page.recovering
                ? I18n.tr("Reset pending. Apply to replace keybindings.json with the defaults; the broken file is kept beside it as keybindings.json.invalid-<time>.")
                : I18n.tr("The default shortcuts are in effect and nothing can be changed here. Repair keybindings.json by hand, or use Reset all to start again from the defaults.")
            tone: page.recovering ? "warning" : "info"
        }

        SettingsGroup {
            width: parent.width
            title: I18n.tr("Keyboard shortcuts")

            DraftFieldRow {
                width: parent.width
                label: I18n.tr("Search")
                mono: false
                value: page.query
                placeholder: I18n.tr("Action or keys, such as Super+B")
                onEdited: text => page.query = text
            }
            PickerRow {
                width: parent.width
                label: I18n.tr("Show")
                visible: page.view === "list"
                model: [{ value: "all", label: I18n.tr("All") }, { value: "changed", label: I18n.tr("Changed") },
                    { value: "conflicts", label: I18n.tr("Conflicts") }, { value: "user", label: I18n.tr("From user.lua") }]
                current: page.filter
                hint: page.filter === "all" ? "" : I18n.format("%1 shown", [page.counts[page.filter]])
                onPicked: value => page.filter = value
            }
            PickerRow {
                width: parent.width
                label: I18n.tr("View")
                property string searchAnchor: "shortcuts-map"
                model: [{ value: "list", label: I18n.tr("List") }, { value: "map", label: I18n.tr("Keyboard map") }]
                current: page.view
                onPicked: value => page.view = value
            }
            ValueRow {
                width: parent.width
                label: I18n.tr("Your own shortcuts")
                hint: I18n.tr("Open an app, a website, a web app or a command.")
                property string searchAnchor: "shortcuts-add"

                SettingsAction {
                    text: I18n.tr("Add shortcut")
                    glyph: "add"
                    enabled: Keybindings.loaded && !page.readOnly
                    onTriggered: page.add("", "app")
                }
            }
            ValueRow {
                width: parent.width
                label: I18n.tr("All shortcuts")
                hint: page.readOnly ? I18n.tr("Replace the unreadable keybindings.json with the defaults.")
                    : I18n.tr("Return every shortcut to its default and remove your own.")
                visible: !page.confirmingReset
                property string searchAnchor: "shortcuts-reset"

                SettingsAction {
                    text: I18n.tr("Reset all…")
                    glyph: "undo"
                    enabled: Keybindings.loaded && (page.anyChanged || page.readOnly) && !page.recovering
                    onTriggered: page.confirmingReset = true
                }
            }
            ValueRow {
                width: parent.width
                visible: page.confirmingReset
                label: I18n.tr("Reset all shortcuts?")
                hint: page.readOnly
                    ? I18n.tr("When you apply, keybindings.json is replaced with the defaults. The broken file is kept beside it as keybindings.json.invalid-<time>, so nothing is lost. Your user.lua is not touched.")
                    : I18n.tr("Every change and custom shortcut goes when you apply. Your user.lua is not touched.")
                hintTone: "warning"

                SettingsAction {
                    text: I18n.tr("Reset all")
                    danger: true
                    onTriggered: {
                        Keybindings.resetAll();
                        page.confirmingReset = false;
                    }
                }
                SettingsAction {
                    text: I18n.tr("Cancel")
                    onTriggered: page.confirmingReset = false
                }
            }
        }

        ShortcutCustomForm {
            id: form
            objectName: "shortcutForm"
            width: parent.width
            onRecordRequested: (exceptId, label, keys) => {
                page.recordFor = "form";
                recorder.start(exceptId, label, keys, false);
            }
        }

        SettingsGroup {
            width: parent.width
            visible: page.view === "map"
            title: I18n.tr("Super and a letter or digit")

            SettingsHint {
                width: parent.width
                text: I18n.tr("Choose a key to change what it does. Lit keys are free.")
            }
            ShortcutKeyboardMap {
                objectName: "settingsShortcutMap"
                x: Theme.settingsMarkInset
                width: parent.width - Theme.settingsMarkInset
                onEditRequested: id => page.edit(id)
                onAddRequested: (combo, type) => page.add(combo, type)
            }
        }

        SettingsHint {
            width: parent.width
            visible: page.view === "list" && Keybindings.loaded && page.groups.length === 0
            text: page.query.trim() !== "" ? I18n.tr("No shortcuts match your search.")
                : page.filter === "conflicts" ? I18n.tr("No shortcuts share a key.")
                : page.filter === "user" ? I18n.tr("Your user.lua adds no described shortcuts.")
                : I18n.tr("Nothing has changed.")
        }

        Repeater {
            model: ScriptModel {
                values: page.view === "list" ? page.groups : []
                objectProp: "title"
            }

            delegate: SettingsGroup {
                id: group
                required property var modelData
                width: parent.width
                title: I18n.tr(modelData.title)

                Repeater {
                    model: ScriptModel {
                        values: group.modelData.rows
                        objectProp: "id"
                    }

                    delegate: ShortcutRow {
                        id: shortcut
                        required property var modelData
                        entry: modelData
                        width: group.width
                        current: page.currentId === modelData.id
                            || (page.order.indexOf(page.currentId) < 0 && page.order[0] === modelData.id)
                        onFocused: page.currentId = modelData.id
                        onMoveRequested: delta => page.moveFocus(modelData.id, delta)
                        onMoveToEdge: last => page.focusRow(page.order[last ? page.order.length - 1 : 0])
                        onEditRequested: page.edit(modelData.id)
                        onResetRequested: Keybindings.reset(modelData.id)
                        onDisableRequested: Keybindings.disable(modelData.id)
                        onRemoveRequested: Keybindings.removeCustom(modelData.id)
                        Component.onCompleted: page.rowItems[modelData.id] = shortcut
                        Component.onDestruction: {
                            if (page.rowItems[modelData.id] === shortcut)
                                delete page.rowItems[modelData.id];
                        }
                    }
                }
            }
        }

        SettingsHint {
            width: parent.width
            text: I18n.tr("Changes are saved in ~/.config/cybexos/keybindings.json. Bindings in ~/.config/cybexos/hypr/user.lua load afterwards and win.")
        }
    }
}
