pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import "../Common"
import "../Common/ShortcutEditor.js" as Helpers

// Add or edit a custom shortcut: what it opens (an app from the desktop
// entries, a website, a seeded web app or a command), its name and group,
// and its keys. The host owns the recorder: `recordRequested` asks for a
// combination and the host passes it back with setKeys(). Saving edits the
// Keybindings draft; the page's apply bar commits it.
SettingsGroup {
    id: root

    property string editId: ""
    property bool opened: false
    property string type: "app"
    property string appQuery: ""
    property string desktopId: ""
    property string appName: ""
    property string url: ""
    property string webapp: "slack"
    property string command: ""
    property string label: ""
    property string group: ""
    property bool labelTouched: false
    property bool groupTouched: false
    property var keys: []
    property string problem: ""
    readonly property var apps: opened && type === "app"
        ? Helpers.appChoices(DesktopEntries.applications.values, appQuery, 6) : []
    readonly property var webapps: Helpers.webappChoices(Welcome.webapps)
    signal recordRequested(string exceptId, string label, var keys)
    signal closed()

    function begin(id, combo, kind) {
        const row = id ? Keybindings.action(id) : null;
        editId = row ? id : "";
        const run = row ? row.run || {} : {};
        type = row ? run.type : Helpers.RUN_TYPES.indexOf(kind) >= 0 ? kind : "app";
        appQuery = "";
        desktopId = run.type === "app" ? run.desktopId : "";
        appName = desktopId;
        url = run.type === "url" ? run.url : "";
        webapp = run.type === "webapp" ? run.id : "slack";
        command = run.type === "command" ? run.command : "";
        label = row ? row.label : "";
        group = row ? row.group : Helpers.DEFAULT_GROUPS[type];
        labelTouched = !!row;
        groupTouched = !!row;
        keys = row ? row.keys.slice() : combo ? [combo] : [];
        problem = "";
        opened = true;
        if (type === "webapp")
            Welcome.refreshWebapps();
        Qt.callLater(() => typeRow.forceActiveFocus());
    }
    function setKeys(value) { keys = value; problem = ""; }
    function close() {
        opened = false;
        closed();
    }
    function chooseType(value) {
        type = value;
        if (!groupTouched)
            group = Helpers.DEFAULT_GROUPS[value];
        if (!labelTouched)
            label = suggestedLabel();
        if (value === "webapp")
            Welcome.refreshWebapps();
        problem = "";
    }
    function suggestedLabel() {
        if (type === "app")
            return appName;
        if (type === "webapp") {
            const app = webapps.find(entry => entry.id === webapp);
            return app ? app.name : webapp;
        }
        if (type === "url") {
            const host = /^(?:https?:\/\/)?([^/\s]+)/i.exec(url.trim());
            return host ? host[1].replace(/^www\./, "") : "";
        }
        return "";
    }
    function suggest() {
        if (!labelTouched)
            label = suggestedLabel();
    }
    function save() {
        const target = Helpers.runTarget(type, type === "app" ? desktopId : type === "url" ? url
            : type === "webapp" ? webapp : command);
        const issue = target.error || Helpers.labelError(group, label) || (keys.length ? "" : "keys");
        const messages = { app: I18n.tr("Choose an app to open."), url: I18n.tr("Enter a website address that starts with http:// or https://."),
            webapp: I18n.tr("Choose a web app."), command: I18n.tr("Enter a command of at most 512 bytes on one line."),
            control: I18n.tr("Use one line of text without control characters."), type: I18n.tr("Choose what the shortcut opens."),
            label: I18n.tr("Give the shortcut a name."), group: I18n.tr("Give it a group without a colon."),
            length: I18n.tr("Names and groups can be at most 64 characters."), keys: I18n.tr("Record the keys for this shortcut.") };
        if (issue) {
            problem = messages[issue] || issue;
            return false;
        }
        const entry = { group: group.trim(), label: label.trim(), keys: keys, run: target.run };
        const result = editId ? Keybindings.updateCustom(editId, entry) : Keybindings.addCustom(entry);
        if (result === false)
            return false;
        close();
        return true;
    }

    visible: opened
    width: parent ? parent.width : 0
    title: editId ? I18n.tr("Edit shortcut") : I18n.tr("Add shortcut")

    PickerRow {
        id: typeRow
        width: parent.width
        label: I18n.tr("Opens")
        model: [{ value: "app", label: I18n.tr("An app") }, { value: "url", label: I18n.tr("A website") },
            { value: "webapp", label: I18n.tr("A web app") }, { value: "command", label: I18n.tr("A command") }]
        current: root.type
        onPicked: value => root.chooseType(value)
    }

    DraftFieldRow {
        width: parent.width
        visible: root.type === "app"
        label: I18n.tr("Find an app")
        mono: false
        value: root.appQuery
        placeholder: root.desktopId !== "" ? root.appName : I18n.tr("Name of the app")
        onEdited: text => root.appQuery = text
    }
    Column {
        id: appList
        width: parent.width
        visible: root.type === "app"
        spacing: Theme.scaled(2)
        property int current: 0

        Repeater {
            id: appRepeater
            model: root.apps
            delegate: Rectangle {
                id: app
                required property var modelData
                required property int index
                readonly property bool chosen: root.desktopId === modelData.desktopId
                x: Theme.settingsMarkInset
                width: appList.width - Theme.settingsMarkInset - Theme.chipHeight
                height: Theme.listRowHeight
                radius: Theme.rowRadius
                color: chosen ? Theme.chipHover : appMouse.containsMouse || activeFocus ? Theme.hoverFill : "transparent"
                border.width: activeFocus ? 1 : 0
                border.color: Theme.accentText
                activeFocusOnTab: index === Math.min(appList.current, root.apps.length - 1)
                Accessible.role: Accessible.RadioButton
                Accessible.name: modelData.name
                Accessible.checked: chosen
                Accessible.onPressAction: pick()

                function pick() {
                    root.desktopId = modelData.desktopId;
                    root.appName = modelData.name;
                    appList.current = index;
                    root.suggest();
                }
                function focusAt(next) {
                    const clamped = Math.max(0, Math.min(root.apps.length - 1, next));
                    appList.current = clamped;
                    const item = appRepeater.itemAt(clamped);
                    if (item)
                        item.forceActiveFocus();
                }
                Keys.onPressed: event => {
                    if (event.key === Qt.Key_Up) { focusAt(index - 1); event.accepted = true; }
                    else if (event.key === Qt.Key_Down) { focusAt(index + 1); event.accepted = true; }
                    else if (event.key === Qt.Key_Home) { focusAt(0); event.accepted = true; }
                    else if (event.key === Qt.Key_End) { focusAt(root.apps.length - 1); event.accepted = true; }
                    else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                        pick(); event.accepted = true;
                    }
                }

                Sym {
                    id: appCheck
                    anchors.left: parent.left
                    anchors.leftMargin: Theme.controlSpacing
                    anchors.verticalCenter: parent.verticalCenter
                    name: app.chosen ? "radio_button_checked" : "radio_button_unchecked"
                    size: Theme.iconSmall
                    color: app.chosen ? Theme.accentText : Theme.textFaint
                }
                Text {
                    anchors.left: appCheck.right
                    anchors.leftMargin: Theme.iconTextSpacing
                    anchors.right: parent.right
                    anchors.rightMargin: Theme.controlSpacing
                    anchors.verticalCenter: parent.verticalCenter
                    elide: Text.ElideRight
                    text: app.modelData.name
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.control
                    color: app.chosen ? Theme.textHi : Theme.textMid
                }
                MouseArea {
                    id: appMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: { app.forceActiveFocus(); app.pick(); }
                }
            }
        }
        SettingsHint {
            width: parent.width
            visible: root.apps.length === 0
            text: I18n.tr("No apps match.")
        }
    }
    DraftFieldRow {
        width: parent.width
        visible: root.type === "url"
        label: I18n.tr("Website address")
        value: root.url
        placeholder: "https://example.org" // i18n: untranslated (URL)
        onEdited: text => { root.url = text; root.suggest(); }
    }
    SelectRow {
        width: parent.width
        visible: root.type === "webapp"
        label: I18n.tr("Web app")
        model: root.webapps.map(app => ({ value: app.id, label: app.name }))
        current: root.webapp
        onPicked: value => { root.webapp = value; root.suggest(); }
    }
    DraftFieldRow {
        width: parent.width
        visible: root.type === "command"
        label: I18n.tr("Command")
        value: root.command
        placeholder: "kitty -e nvim ~/notes.md" // i18n: untranslated (command)
        hint: I18n.tr("Runs as one line through Hyprland, as a terminal would.")
        onEdited: text => root.command = text
    }
    DraftFieldRow {
        width: parent.width
        label: I18n.tr("Name")
        mono: false
        value: root.label
        placeholder: I18n.tr("Shown in the shortcut sheet")
        onEdited: text => { root.label = text; root.labelTouched = true; }
    }
    DraftFieldRow {
        width: parent.width
        label: I18n.tr("Group")
        mono: false
        value: root.group
        onEdited: text => { root.group = text; root.groupTouched = true; }
    }
    ValueRow {
        width: parent.width
        label: I18n.tr("Keys")

        ShortcutKeycaps {
            anchors.verticalCenter: parent.verticalCenter
            keys: root.keys
            emptyText: I18n.tr("None yet")
        }
        SettingsAction {
            text: root.keys.length ? I18n.tr("Change…") : I18n.tr("Record…")
            glyph: "keyboard"
            onTriggered: root.recordRequested(root.editId, root.label || I18n.tr("New shortcut"), root.keys)
        }
    }
    SettingsHint {
        width: parent.width
        text: root.problem
        tone: "error"
    }
    ValueRow {
        width: parent.width
        divider: false
        label: ""

        SettingsAction {
            visible: root.editId !== ""
            text: I18n.tr("Remove")
            glyph: "delete"
            danger: true
            onTriggered: {
                if (Keybindings.removeCustom(root.editId))
                    root.close();
            }
        }
        SettingsAction {
            text: I18n.tr("Cancel")
            onTriggered: root.close()
        }
        SettingsAction {
            primary: true
            text: root.editId ? I18n.tr("Save") : I18n.tr("Add shortcut")
            onTriggered: root.save()
        }
    }
}
