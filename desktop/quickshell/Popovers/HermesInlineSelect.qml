pragma ComponentBehavior: Bound
import QtQuick
import "../Common"

Item {
    id: root

    property string text: ""
    property string symbol: ""
    property string value: ""
    property var options: []
    property bool expanded: false
    property bool openUpward: true
    property int menuRows: 8
    property int menuWidth: 176
    property real maxWidth: 1000
    readonly property int popupHeight:
        Math.min(menuRows, options.length) * Theme.pickerRowHeight + 8
    readonly property Item popupItem: menu
    signal selected(string value)

    implicitWidth: trigger.implicitWidth
    implicitHeight: trigger.implicitHeight
    z: expanded ? 100 : 0

    function optionId(option) {
        return option ? String(option.id ?? option.value ?? "") : "";
    }

    function optionLabel(option) {
        return option ? String(option.label ?? option.name ?? optionId(option)) : "";
    }

    function selectedLabel() {
        const found = (Array.isArray(options) ? options : [])
            .find(option => optionId(option) === value);
        return found ? optionLabel(found) : text;
    }

    function move(delta) {
        const choices = (Array.isArray(options) ? options : [])
            .filter(option => option.disabled !== true);
        if (choices.length === 0)
            return;
        let at = choices.findIndex(option => optionId(option) === value);
        at = (at + delta + choices.length) % choices.length;
        selected(optionId(choices[at]));
    }

    function focusAdjacentChoice(index, delta) {
        if (!root.expanded || choiceRepeater.count === 0)
            return;
        let at = index;
        for (let checked = 0; checked < choiceRepeater.count; checked++) {
            at = (at + delta + choiceRepeater.count) % choiceRepeater.count;
            const item = choiceRepeater.itemAt(at);
            const option = root.options[at];
            if (!item || option.disabled === true)
                continue;
            item.forceActiveFocus();
            const rowTop = at * Theme.pickerRowHeight;
            if (rowTop < menuFlick.contentY)
                menuFlick.contentY = rowTop;
            else if (rowTop + Theme.pickerRowHeight
                    > menuFlick.contentY + menuFlick.height)
                menuFlick.contentY = Math.max(0, rowTop
                    + Theme.pickerRowHeight - menuFlick.height);
            return;
        }
    }

    function containsPickerPoint(item, x, y) {
        if (!item)
            return false;
        const point = root.mapFromItem(item, x, y);
        const inButton = point.x >= 0 && point.x <= root.width
            && point.y >= 0 && point.y <= root.height;
        const inMenu = menu.visible && point.x >= menu.x
            && point.x <= menu.x + menu.width && point.y >= menu.y
            && point.y <= menu.y + menu.height;
        return inButton || inMenu;
    }

    function itemBelongsTo(item, ancestor) {
        let current = item;
        while (current) {
            if (current === ancestor)
                return true;
            current = current.parent;
        }
        return false;
    }

    function restoreTriggerIfFocusHidden() {
        Qt.callLater(() => {
            const focused = root.Window.window?.activeFocusItem ?? null;
            if (!focused || root.itemBelongsTo(focused, menu))
                trigger.forceActiveFocus();
        });
    }

    onEnabledChanged: if (!enabled) expanded = false
    onVisibleChanged: if (!visible) expanded = false

    Keys.onPressed: event => {
        if (!root.enabled)
            return;
        if (event.key === Qt.Key_Down || event.key === Qt.Key_Right) {
            root.move(1);
            event.accepted = true;
        } else if (event.key === Qt.Key_Up || event.key === Qt.Key_Left) {
            root.move(-1);
            event.accepted = true;
        } else if (event.key >= Qt.Key_1 && event.key <= Qt.Key_9) {
            const at = event.key - Qt.Key_1;
            if (at < root.options.length && root.options[at].disabled !== true) {
                root.selected(root.optionId(root.options[at]));
                root.expanded = false;
                Qt.callLater(() => trigger.forceActiveFocus());
                event.accepted = true;
            }
        } else if (event.key === Qt.Key_Escape && root.expanded) {
            root.expanded = false;
            Qt.callLater(() => trigger.forceActiveFocus());
            event.accepted = true;
        }
    }

    TapHandler {
        enabled: root.expanded && root.enabled && root.visible
        margin: root.Window.window
            ? Math.max(root.Window.window.width, root.Window.window.height) : 0
        onTapped: eventPoint => {
            if (!root.containsPickerPoint(root, eventPoint.position.x,
                    eventPoint.position.y)) {
                root.expanded = false;
                root.restoreTriggerIfFocusHidden();
            }
        }
    }

    HermesBarControl {
        id: trigger
        anchors.fill: parent
        text: root.selectedLabel()
        accessibleDescription: root.text
        symbol: root.symbol
        maxWidth: root.maxWidth
        active: root.expanded
        enabled: root.enabled
        onTriggered: root.expanded = !root.expanded
    }

    Rectangle {
        id: menu
        z: 1000
        visible: root.expanded && root.enabled
        x: 0
        y: root.openUpward ? -height - 6 : root.height + 6
        width: Math.max(root.menuWidth, root.width)
        height: root.popupHeight
        radius: HermesTheme.panelRadius
        color: HermesTheme.overlay
        border.width: 1
        border.color: HermesTheme.borderStrong
        clip: true

        Flickable {
            id: menuFlick
            anchors.fill: parent
            anchors.margins: 4
            contentWidth: width
            contentHeight: choices.implicitHeight
            boundsBehavior: Flickable.StopAtBounds
            interactive: contentHeight > height
            clip: true

            Column {
                id: choices
                width: parent.width

                Repeater {
                    id: choiceRepeater
                    model: root.options

                    delegate: Rectangle {
                        id: choice
                        required property var modelData
                        required property int index
                        readonly property string choiceId: root.optionId(modelData)
                        readonly property bool chosen: choiceId === root.value
                        width: parent.width
                        height: Theme.pickerRowHeight
                        radius: HermesTheme.controlRadius
                        color: chosen ? Theme.chip
                            : choiceMouse.containsMouse || activeFocus
                                ? HermesTheme.hoverStrong
                                : "transparent"
                        border.width: activeFocus ? 1 : 0
                        border.color: HermesTheme.focus
                        opacity: modelData.disabled === true ? 0.35 : 1
                        activeFocusOnTab: modelData.disabled !== true
                        Accessible.role: Accessible.ListItem
                        Accessible.name: root.optionLabel(modelData)
                        Accessible.selected: chosen
                        Accessible.onPressAction: {
                            if (modelData.disabled !== true) {
                                root.selected(choiceId);
                                root.expanded = false;
                                Qt.callLater(() => trigger.forceActiveFocus());
                            }
                        }

                        Keys.onPressed: event => {
                            if (modelData.disabled === true)
                                return;
                            if (event.key === Qt.Key_Down
                                    || event.key === Qt.Key_Right) {
                                root.focusAdjacentChoice(choice.index, 1);
                                event.accepted = true;
                            } else if (event.key === Qt.Key_Up
                                    || event.key === Qt.Key_Left) {
                                root.focusAdjacentChoice(choice.index, -1);
                                event.accepted = true;
                            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                                    || event.key === Qt.Key_Space) {
                                root.selected(choice.choiceId);
                                root.expanded = false;
                                Qt.callLater(() => trigger.forceActiveFocus());
                                event.accepted = true;
                            } else if (event.key === Qt.Key_Escape) {
                                root.expanded = false;
                                Qt.callLater(() => trigger.forceActiveFocus());
                                event.accepted = true;
                            }
                        }

                        Text {
                            anchors.left: parent.left
                            anchors.leftMargin: 8
                            anchors.right: mark.left
                            anchors.rightMargin: 6
                            anchors.verticalCenter: parent.verticalCenter
                            text: root.optionLabel(choice.modelData)
                            elide: Text.ElideRight
                            font.family: HermesTheme.fontUi
                            font.pixelSize: Theme.typography.control
                            color: choice.chosen ? HermesTheme.textPrimary
                                : HermesTheme.textSecondary
                        }

                        Sym {
                            id: mark
                            visible: choice.chosen
                            anchors.right: parent.right
                            anchors.rightMargin: 8
                            anchors.verticalCenter: parent.verticalCenter
                            name: "check"
                            size: Theme.iconSmall
                            symWeight: 550
                            color: HermesTheme.accent
                        }

                        MouseArea {
                            id: choiceMouse
                            anchors.fill: parent
                            enabled: choice.modelData.disabled !== true
                            hoverEnabled: true
                            cursorShape: enabled ? Qt.PointingHandCursor
                                : Qt.ForbiddenCursor
                            onClicked: {
                                root.selected(choice.choiceId);
                                root.expanded = false;
                                Qt.callLater(() => trigger.forceActiveFocus());
                            }
                        }
                    }
                }
            }
        }

        ScrollChrome {
            anchors.fill: parent
            anchors.margins: 4
            target: menuFlick
            fadeSize: 16
            edgeColor: HermesTheme.overlay
            thumbColor: HermesTheme.accent
        }
    }
}
