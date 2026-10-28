pragma ComponentBehavior: Bound
import QtQuick
import "../Common"

// The Mac-like menubar's menus (Common/MacDesktop.qml): a compact list of
// commands with separators, section captions and check marks, highlighted in
// the accent under the pointer or the arrow keys as a Mac menu is. One view
// serves all three names; Popouts.currentName says which menu it shows.
PopoutPanel {
    id: root

    readonly property string menuName: Popouts.currentName
    readonly property var rows: MacDesktop.menu(menuName)
    property int current: -1
    readonly property int pad: Theme.scaled(5)
    readonly property int rowHeight: Theme.scaled(24)
    readonly property int gutter: Theme.scaled(22)
    readonly property real widest: {
        let width = 0;
        for (const row of rows) {
            const detail = row.detail !== "" ? metrics.advanceWidth(row.detail) + Theme.scaled(24) : 0;
            width = Math.max(width, metrics.advanceWidth(row.label) + detail);
        }
        return width;
    }

    surfaceColor: Theme.surfaceMenu
    focus: visible
    implicitWidth: Math.min(availableWidth > 0 ? availableWidth : Theme.scaled(420),
        Math.max(Theme.scaled(200), Math.ceil(widest) + gutter + Theme.scaled(28) + pad * 2))
    implicitHeight: column.implicitHeight + pad * 2

    onMenuNameChanged: current = -1

    function step(direction) {
        if (rows.length === 0)
            return;
        let index = current;
        for (let i = 0; i < rows.length; i++) {
            index = (index + direction + rows.length) % rows.length;
            if (rows[index].kind === "item" && rows[index].enabled) {
                current = index;
                return;
            }
        }
    }

    function activate(index) {
        const row = rows[index];
        if (!row || row.kind !== "item" || !row.enabled)
            return;
        const screenName = Popouts.hostScreenName;
        Popouts.close();
        MacDesktop.run(row, screenName);
    }

    Keys.onPressed: event => {
        if (event.key === Qt.Key_Down) {
            step(1);
        } else if (event.key === Qt.Key_Up) {
            step(-1);
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                || event.key === Qt.Key_Space) {
            activate(current);
        } else {
            return;
        }
        event.accepted = true;
    }

    FontMetrics {
        id: metrics
        font.family: Theme.fontMenu
        font.pixelSize: Theme.typography.primary
        font.weight: Theme.weightMedium
    }

    Column {
        id: column
        x: root.pad
        y: root.pad
        width: root.width - root.pad * 2

        Repeater {
            model: root.rows

            delegate: Item {
                id: entry
                required property var modelData
                required property int index
                readonly property bool lit: root.current === index && modelData.kind === "item"
                    && modelData.enabled

                width: column.width
                height: modelData.kind === "separator" ? Theme.scaled(11) : root.rowHeight
                Accessible.role: modelData.kind === "separator" ? Accessible.Separator : Accessible.MenuItem
                Accessible.name: modelData.label
                Accessible.checked: modelData.checked
                Accessible.onPressAction: root.activate(index)

                Rectangle {
                    visible: entry.modelData.kind === "separator"
                    anchors.verticalCenter: parent.verticalCenter
                    x: Theme.scaled(10)
                    width: parent.width - Theme.scaled(20)
                    height: 1
                    color: Theme.stroke
                }

                Rectangle {
                    visible: entry.modelData.kind !== "separator"
                    anchors.fill: parent
                    radius: Theme.scaled(5)
                    color: entry.lit ? Theme.accent : "transparent"
                }

                Sym {
                    visible: entry.modelData.checked
                    anchors.verticalCenter: parent.verticalCenter
                    x: Theme.scaled(5)
                    name: "check"
                    size: Theme.iconSmall
                    color: entry.lit ? Theme.accentFg : Theme.textHi
                }

                Text {
                    id: label
                    anchors.verticalCenter: parent.verticalCenter
                    x: entry.modelData.kind === "header" ? Theme.scaled(10) : root.gutter
                    width: parent.width - x - (detail.visible ? detail.implicitWidth + Theme.scaled(20) : Theme.scaled(10))
                    elide: Text.ElideRight
                    text: entry.modelData.label
                    font.family: Theme.fontMenu
                    font.pixelSize: entry.modelData.kind === "header"
                        ? Theme.typography.secondary : Theme.typography.primary
                    font.weight: entry.modelData.kind === "header" ? Theme.weightSemibold : Theme.weightMedium
                    color: entry.lit ? Theme.accentFg
                        : entry.modelData.kind === "header" || !entry.modelData.enabled ? Theme.textLow
                        : Theme.textHi
                }

                Text {
                    id: detail
                    visible: entry.modelData.detail !== ""
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.right: parent.right
                    anchors.rightMargin: Theme.scaled(10)
                    text: entry.modelData.detail
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.secondary
                    color: entry.lit ? Theme.accentFg : Theme.textLow
                }

                MouseArea {
                    anchors.fill: parent
                    enabled: entry.modelData.kind === "item"
                    hoverEnabled: true
                    cursorShape: Qt.ArrowCursor
                    onEntered: root.current = entry.modelData.enabled ? entry.index : -1
                    onExited: {
                        if (root.current === entry.index)
                            root.current = -1;
                    }
                    onClicked: root.activate(entry.index)
                }
            }
        }
    }
}
