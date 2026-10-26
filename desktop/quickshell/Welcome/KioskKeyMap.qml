pragma ComponentBehavior: Bound
import QtQuick
import "../Common"
import "../Common/ShortcutEditor.js" as Helpers

// The Super+digit and Super+letter keys as a keyboard, in installer keycaps,
// from the same model as Settings → Keyboard shortcuts (ShortcutEditor.js).
// Keys that do something are lit and name their action; a protected
// default carries a lock, a key held twice an amber edge. One key is a tab
// stop and the arrows move between keys.
Column {
    id: root
    property var map: Helpers.keyboardMap(Keybindings.actions, Keybindings.userBinds)
    property string selected: ""
    property int focusRow: 1
    property int focusColumn: 0
    readonly property var selectedKey: [].concat.apply([], map).find(key => key.combo === selected) || null
    readonly property real gap: Kiosk.px(6)
    readonly property real unit: Math.floor((width - gap * 9) / 10.5)
    readonly property var offsets: [0, 0.5, 0.75, 1.25]
    readonly property int used: [].concat.apply([], map).filter(key => !key.free).length
    signal activated(var key)
    spacing: gap

    component KeyRow: Row {
        property Repeater keys: null
        function keyAt(column: int): Item { return keys ? keys.itemAt(column) : null; }
    }

    function label(owner) {
        if (!owner)
            return "";
        const workspace = Helpers.workspaceNumber(owner.label);
        return workspace ? I18n.format("Workspace %1", [workspace]) : I18n.actionLabel(owner.label);
    }
    function choose(key) {
        selected = key.combo;
        activated(key);
    }
    function focusKey(row, column) {
        const target = Helpers.mapMove(map, row, column, "");
        const line = rows.itemAt(target.row) as KeyRow;
        const item = line ? line.keyAt(target.column) : null;
        if (item)
            item.forceActiveFocus();
        focusRow = target.row;
        focusColumn = target.column;
    }

    Repeater {
        id: rows
        model: root.map
        delegate: KeyRow {
            id: line
            required property var modelData
            required property int index
            x: Math.round(root.offsets[index] * (root.unit + root.gap))
            spacing: root.gap
            Repeater {
                id: keyRepeater
                model: line.modelData
                Component.onCompleted: line.keys = keyRepeater
                delegate: Rectangle {
                    id: cap
                    required property var modelData
                    readonly property bool lit: !modelData.free
                    readonly property bool chosen: root.selected === modelData.combo
                    readonly property bool current: root.focusRow === modelData.row && root.focusColumn === modelData.column
                    readonly property bool user: !!modelData.owner && modelData.owner.source === "user"
                    width: root.unit
                    height: Kiosk.px(52)
                    radius: Kiosk.px(8)
                    color: chosen ? Kiosk.accent : lit ? Kiosk.accentSoft : Kiosk.bgDeep
                    border.width: Math.max(1, Kiosk.px(1))
                    border.color: chosen ? Kiosk.accent : modelData.shared ? Kiosk.amber
                        : lit ? (keyMouse.containsMouse ? Kiosk.accent : Kiosk.accentLine) : keyMouse.containsMouse ? Kiosk.line2 : Kiosk.line
                    activeFocusOnTab: current
                    Accessible.role: Accessible.Button
                    Accessible.name: I18n.format("Super+%1: %2", [modelData.key,
                        modelData.free ? I18n.tr("Free") : modelData.reservedBy ? I18n.actionLabel(modelData.reservedBy.label) : root.label(modelData.owner)])
                    Accessible.onPressAction: root.choose(modelData)
                    Keys.onPressed: event => {
                        const move = {[Qt.Key_Left]: "left", [Qt.Key_Right]: "right", [Qt.Key_Up]: "up",
                            [Qt.Key_Down]: "down", [Qt.Key_Home]: "home", [Qt.Key_End]: "end"}[event.key];
                        if (move) {
                            const next = Helpers.mapMove(root.map, cap.modelData.row, cap.modelData.column, move);
                            root.focusKey(next.row, next.column);
                            event.accepted = true;
                        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                            if (!event.isAutoRepeat) root.choose(cap.modelData);
                            event.accepted = true;
                        }
                    }
                    // The lower edge of a physical key.
                    Rectangle {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        anchors.margins: Math.max(1, Kiosk.px(1))
                        height: Kiosk.px(2)
                        radius: Kiosk.px(1)
                        color: cap.chosen ? "transparent" : Qt.rgba(1, 1, 1, 0.04)
                    }
                    KioskFocusRing { visible: cap.activeFocus; gap: 3; baseRadius: cap.radius }
                    KioskText {
                        x: Kiosk.px(7)
                        y: Kiosk.px(5)
                        text: cap.modelData.key
                        mono: true
                        size: 13
                        font.weight: Font.Bold
                        tone: cap.chosen ? "onAccent" : cap.lit ? "accent" : "faint"
                    }
                    KioskIcon {
                        visible: cap.modelData.protected
                        anchors.right: parent.right
                        anchors.rightMargin: Kiosk.px(5)
                        y: Kiosk.px(6)
                        name: "lock"
                        designSize: 11
                        color: cap.chosen ? Kiosk.accentInk : Kiosk.faint
                    }
                    KioskText {
                        x: Kiosk.px(6)
                        anchors.bottom: parent.bottom
                        anchors.bottomMargin: Kiosk.px(5)
                        width: parent.width - Kiosk.px(10)
                        visible: cap.lit
                        text: cap.modelData.reservedBy ? I18n.actionLabel(cap.modelData.reservedBy.label) : root.label(cap.modelData.owner)
                        size: 9.5
                        font.italic: cap.user
                        tone: cap.chosen ? "onAccent" : "fog"
                        wrapMode: Text.WordWrap
                        maximumLineCount: 2
                        elide: Text.ElideRight
                        lineHeight: 0.9
                    }
                    MouseArea {
                        id: keyMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            root.focusKey(cap.modelData.row, cap.modelData.column);
                            root.choose(cap.modelData);
                        }
                    }
                }
            }
        }
    }
}
