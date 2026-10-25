pragma ComponentBehavior: Bound
import QtQuick
import "../Common"
import "../Common/ShortcutEditor.js" as Helpers

// The Super+letter and Super+digit keys, drawn as a keyboard, each with the
// action it runs. A protected action's reserved defaults carry a lock (its
// other keys can move like any key); free keys are lit. Choosing a
// bound key asks to edit its action; choosing a free key offers to make it
// open an app, a website, a web app or a command. Used by Settings →
// Keyboard shortcuts and by the welcome guide.
//
// One key is a tab stop; the arrows move between keys (roving focus).
Column {
    id: root

    property var actions: Keybindings.actions
    property var userBinds: Keybindings.userBinds
    // While keybindings.json is rejected the map only shows what is bound.
    property bool readOnly: Keybindings.readOnly
    readonly property var map: Helpers.keyboardMap(actions, userBinds)
    // The key whose details show under the map, by combination.
    property string selected: ""
    property int focusRow: 1
    property int focusColumn: 0
    readonly property var selectedKey: [].concat.apply([], map).find(key => key.combo === selected) || null
    readonly property real unit: Math.floor((width - Theme.scaled(3) * 9) / 10.5)
    readonly property real keyHeight: Math.min(Theme.scaled(64), Math.max(Theme.scaled(48), unit * 0.92))
    readonly property var offsets: [0, 0.5, 0.75, 1.25]
    signal editRequested(string id)
    signal addRequested(string combo, string type)

    spacing: Theme.settingsContentSpacing

    component KeyRow: Row {
        property Repeater keys: null
        function keyAt(column: int): Item { return keys ? keys.itemAt(column) : null; }
    }
    component Legend: Row {
        id: legend
        property color fill
        property color edge
        property string glyph: ""
        property string text
        spacing: Theme.iconTextSpacing
        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: Theme.iconSmall + Theme.scaled(4)
            height: width
            radius: Theme.scaled(3)
            color: legend.fill
            border.width: 1
            border.color: legend.edge
            Sym {
                anchors.centerIn: parent
                visible: legend.glyph !== ""
                name: legend.glyph
                size: Theme.iconSmall - Theme.scaled(2)
                color: Theme.textFaint
            }
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: legend.text
            font.family: Theme.fontMenu
            font.pixelSize: Theme.typography.metadata
            color: Theme.textFaint
        }
    }

    function label(owner) {
        if (!owner)
            return "";
        const workspace = Helpers.workspaceNumber(owner.label);
        return workspace ? I18n.format("Workspace %1", [workspace]) : I18n.tr(owner.label);
    }
    function describe(key) {
        if (key.free)
            return I18n.tr("Free");
        if (key.reservedBy)
            return I18n.format("Kept for %1", [I18n.tr(key.reservedBy.label)]);
        let text = label(key.owner);
        if (key.shared)
            text = I18n.format("%1 and %2 more", [text, key.owners.length - 1]);
        if (key.owner.source === "user")
            text = I18n.format("%1 (from user.lua)", [text]);
        return text;
    }
    function activate(key) {
        selected = key.combo;
        if (!readOnly && key.owner && key.owner.editable && !key.shared)
            editRequested(key.owner.id);
    }
    function focusKey(row, column) {
        const target = Helpers.mapMove(map, row, column, "");
        // Focus first: the current key is the tab stop (see PillRow).
        const line = keyRows.itemAt(target.row) as KeyRow;
        const item = line ? line.keyAt(target.column) : null;
        if (item)
            item.forceActiveFocus();
        focusRow = target.row;
        focusColumn = target.column;
    }

    Column {
        width: parent.width
        spacing: Theme.scaled(3)

        Repeater {
            id: keyRows
            model: root.map

            delegate: KeyRow {
                id: line
                required property var modelData
                required property int index
                x: Math.round(root.offsets[index] * (root.unit + spacing))
                spacing: Theme.scaled(3)

                Repeater {
                    id: keyRepeater
                    model: line.modelData
                    Component.onCompleted: line.keys = keyRepeater

                    delegate: Rectangle {
                        id: keyCap
                        required property var modelData
                        readonly property bool current: root.focusRow === modelData.row && root.focusColumn === modelData.column
                        readonly property bool chosen: root.selected === modelData.combo
                        readonly property bool user: !!modelData.owner && modelData.owner.source === "user"
                        width: root.unit
                        height: root.keyHeight
                        radius: Theme.scaled(6)
                        color: modelData.free ? Theme.accentAlpha(chosen ? 0.26 : 0.16)
                            : chosen ? Theme.chipHover : Theme.cardFill
                        border.width: activeFocus || chosen ? 2 : 1
                        border.color: activeFocus ? Theme.accentText
                            : modelData.shared ? Theme.amber
                            : modelData.free ? Theme.accentAlpha(0.55) : Theme.stroke
                        activeFocusOnTab: current
                        Accessible.role: Accessible.Button
                        Accessible.name: I18n.format("Super+%1: %2", [modelData.key, root.describe(modelData)])
                        Accessible.description: modelData.protected ? I18n.tr("A protected shortcut always keeps this key.") : ""
                        Accessible.onPressAction: root.activate(modelData)

                        Keys.onPressed: event => {
                            const move = { [Qt.Key_Left]: "left", [Qt.Key_Right]: "right", [Qt.Key_Up]: "up",
                                [Qt.Key_Down]: "down", [Qt.Key_Home]: "home", [Qt.Key_End]: "end" }[event.key];
                            if (move) {
                                const next = Helpers.mapMove(root.map, modelData.row, modelData.column, move);
                                root.focusKey(next.row, next.column);
                                event.accepted = true;
                            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                                    || event.key === Qt.Key_Space) {
                                keyState.pulseCenter();
                                root.activate(modelData);
                                event.accepted = true;
                            }
                        }

                        StateLayer {
                            id: keyState
                            anchors.fill: parent
                            radius: parent.radius
                            hovered: keyMouse.containsMouse
                            pressed: keyMouse.pressed
                            focused: keyCap.activeFocus
                            tint: keyCap.modelData.free ? Theme.accent : Theme.textHi
                            pressPoint: Qt.point(keyMouse.mouseX, keyMouse.mouseY)
                        }

                        Text {
                            x: Theme.scaled(6)
                            y: Theme.scaled(4)
                            text: keyCap.modelData.key
                            font.family: Theme.fontMono
                            font.pixelSize: Theme.typography.control
                            font.weight: Theme.weightBold
                            color: keyCap.modelData.free ? Theme.accentText : Theme.textHi
                        }
                        Sym {
                            visible: keyCap.modelData.protected || keyCap.modelData.free
                            anchors.right: parent.right
                            anchors.rightMargin: Theme.scaled(4)
                            y: Theme.scaled(5)
                            name: keyCap.modelData.free ? "add" : "lock"
                            size: Theme.iconSmall
                            color: keyCap.modelData.free ? Theme.accentText : Theme.textFaint
                        }
                        // Two lines at word boundaries; one elided line when a
                        // word alone is wider than the key (a narrow map, a
                        // long translation), so it never runs into the next.
                        TextMetrics {
                            id: longestWord
                            font: keyLabel.font
                            text: keyLabel.text.split(/\s+/).reduce((longest, word) => word.length > longest.length ? word : longest, "")
                        }
                        Text {
                            id: keyLabel
                            x: Theme.scaled(5)
                            anchors.bottom: parent.bottom
                            anchors.bottomMargin: Theme.scaled(3)
                            width: parent.width - Theme.scaled(8)
                            visible: !keyCap.modelData.free
                            text: keyCap.modelData.reservedBy ? I18n.tr(keyCap.modelData.reservedBy.label)
                                : root.label(keyCap.modelData.owner)
                            wrapMode: longestWord.advanceWidth <= width ? Text.WordWrap : Text.NoWrap
                            maximumLineCount: wrapMode === Text.NoWrap ? 1 : 2
                            elide: Text.ElideRight
                            lineHeight: 0.9
                            font.family: Theme.fontMenu
                            font.pixelSize: Theme.typography.metadata
                            font.italic: keyCap.user
                            color: keyCap.modelData.reservedBy || keyCap.user ? Theme.textFaint : Theme.textMid
                        }

                        MouseArea {
                            id: keyMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                root.focusKey(keyCap.modelData.row, keyCap.modelData.column);
                                root.activate(keyCap.modelData);
                            }
                        }
                    }
                }
            }
        }
    }

    // The legend, then what the chosen key does.
    Flow {
        width: parent.width
        spacing: Theme.panelSectionSpacing

        Legend { fill: Theme.accentAlpha(0.16); edge: Theme.accentAlpha(0.55); text: I18n.tr("Free") }
        Legend { fill: Theme.cardFill; edge: Theme.stroke; glyph: "lock"; text: I18n.tr("Protected default") }
        Legend { fill: Theme.cardFill; edge: Theme.amber; text: I18n.tr("Used more than once") }
        Legend { fill: Theme.cardFill; edge: Theme.stroke; text: I18n.tr("Italic: from user.lua") }
    }

    Rectangle {
        id: detail
        visible: root.selectedKey !== null
        width: parent.width
        height: visible ? detailBody.implicitHeight + Theme.controlSpacing * 2 : 0
        radius: Theme.chipRadius
        color: Theme.cardFill
        border.width: 1
        border.color: Theme.hairlineSoft

        Column {
            id: detailBody
            x: Theme.controlSpacing
            y: Theme.controlSpacing
            width: parent.width - Theme.controlSpacing * 2
            spacing: Theme.iconTextSpacing

            Row {
                spacing: Theme.controlSpacing
                ShortcutKeycaps { keys: root.selectedKey ? [root.selectedKey.combo] : [] }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.min(implicitWidth, detailBody.width - Theme.scaled(120))
                    elide: Text.ElideRight
                    text: !root.selectedKey ? ""
                        : root.selectedKey.free ? (root.readOnly ? I18n.tr("This key is free.") : I18n.tr("This key is free. Make it open:"))
                        : root.describe(root.selectedKey)
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.control
                    font.weight: Theme.weightMedium
                    color: Theme.textHi
                }
            }
            Text {
                width: parent.width
                visible: text !== ""
                wrapMode: Text.Wrap
                text: !root.selectedKey ? ""
                    : root.readOnly ? I18n.tr("Shortcuts cannot be changed until keybindings.json is reset.")
                    : root.selectedKey.free ? ""
                    : root.selectedKey.reservedBy ? I18n.tr("A protected shortcut always keeps this key.")
                    : root.selectedKey.protected ? I18n.format("%1 always keeps this key. You can give it other keys as well.",
                        [root.label(root.selectedKey.owner)])
                    : root.selectedKey.owner.source === "user" ? I18n.tr("Set in ~/.config/cybexos/hypr/user.lua. Change it there.")
                    : root.selectedKey.shared ? root.selectedKey.owners.map(owner => root.label(owner)).join(", ")
                    : !root.selectedKey.owner.editable ? I18n.tr("This shortcut cannot be changed here.") : ""
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.secondary
                color: Theme.textFaint
            }
            Flow {
                width: parent.width
                spacing: Theme.iconTextSpacing
                visible: root.selectedKey !== null && root.selectedKey.free && !root.readOnly

                Repeater {
                    model: [{ type: "app", label: I18n.tr("An app"), glyph: "apps" },
                        { type: "url", label: I18n.tr("A website"), glyph: "language" },
                        { type: "webapp", label: I18n.tr("A web app"), glyph: "web" },
                        { type: "command", label: I18n.tr("A command"), glyph: "terminal" }]
                    delegate: SettingsAction {
                        required property var modelData
                        text: modelData.label
                        glyph: modelData.glyph
                        onTriggered: root.addRequested(root.selected, modelData.type)
                    }
                }
            }
            Flow {
                width: parent.width
                spacing: Theme.iconTextSpacing
                visible: root.selectedKey !== null && root.selectedKey.shared && !root.readOnly

                Repeater {
                    model: root.selectedKey && root.selectedKey.shared
                        ? root.selectedKey.owners.filter(owner => owner.editable) : []
                    delegate: SettingsAction {
                        required property var modelData
                        text: I18n.format("Edit %1", [I18n.tr(modelData.label)])
                        glyph: "edit"
                        onTriggered: root.editRequested(modelData.id)
                    }
                }
            }
        }
    }
}
