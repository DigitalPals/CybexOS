pragma ComponentBehavior: Bound
import QtQuick
import "../Common"

// A composer-bar dropdown: mark, current value, chevron, and nothing else.
//
// T3Picker is the form-shaped sibling — a filled tile with a caption above its
// value — which is right inside a settings sheet and wrong on the composer's
// action bar, where the controls are meant to read as part of the sentence
// "GPT-5.6-Sol · Max · Full access" rather than as three form fields. Same
// option shape, same keyboard contract, different silhouette.
Item {
    id: root

    property string text: ""
    // Either an approved brand name or a Material Symbol. A control that shows
    // both marks would be two icons for one idea, so brand wins.
    property string brand: ""
    property string symbol: ""
    property color tint: T3Theme.textSecondary
    property color iconTint: T3Theme.textFaint
    property string value: ""
    property var options: []
    property bool expanded: false
    property bool openUpward: true
    property int menuRows: 8
    property int menuWidth: 200
    property real maxWidth: 1000
    property bool alignRight: false
    property Item popupBoundsItem: null
    // Host the menu at the page boundary so a clipped composer viewport does
    // not clip its choices or remove them from pointer hit testing.
    readonly property Item popupHostItem: popupBoundsItem ? popupBoundsItem : root
    property point popupHostOrigin: Qt.point(0, 0)
    property point popupBoundsOrigin: Qt.point(0, 0)
    readonly property real popupBoundsLeft: popupBoundsItem
        ? popupBoundsOrigin.x : 0
    readonly property real popupBoundsTop: popupBoundsItem
        ? popupBoundsOrigin.y : -100000
    readonly property real popupBoundsRight: popupBoundsItem
        ? popupBoundsOrigin.x + popupBoundsItem.width : 100000
    readonly property real popupBoundsBottom: popupBoundsItem
        ? popupBoundsOrigin.y + popupBoundsItem.height : 100000
    readonly property int naturalPopupHeight:
        Math.min(menuRows, options.length) * Theme.pickerRowHeight + 8
    readonly property int popupHeight: Math.min(naturalPopupHeight,
        Math.max(Theme.pickerRowHeight + 8,
            Math.floor(popupBoundsBottom - popupBoundsTop)))
    readonly property Item popupItem: menu
    // The bar is a fixed width the prompt above it does not have to respect,
    // so the longest label yields first instead of pushing the send action off
    // the end.
    signal selected(string value)

    implicitWidth: trigger.implicitWidth
    implicitHeight: trigger.implicitHeight
    readonly property real naturalWidth: trigger.naturalWidth
    z: expanded ? 100 : 0

    function optionId(option) {
        if (!option)
            return "";
        return String(option.id ?? option.instanceId ?? option.slug ?? option.value ?? "");
    }

    function optionLabel(option) {
        if (!option)
            return "";
        return String(option.label ?? option.displayName ?? option.name ?? option.shortName
            ?? optionId(option));
    }

    function selectedLabel() {
        const found = (Array.isArray(options) ? options : [])
            .find(option => optionId(option) === value);
        return found ? optionLabel(found) : root.text;
    }

    function updatePopupGeometry() {
        popupHostOrigin = popupHostItem === root ? Qt.point(0, 0)
            : popupHostItem.mapFromItem(root, 0, 0);
        popupBoundsOrigin = popupBoundsItem
            ? root.mapFromItem(popupBoundsItem, 0, 0) : Qt.point(0, 0);
    }

    function open() {
        updatePopupGeometry();
        expanded = true;
        // New Thread scrolls after expansion to reserve the menu's height.
        // Refresh once that deferred layout has moved the trigger.
        Qt.callLater(updatePopupGeometry);
    }

    function close() {
        expanded = false;
    }

    function toggle() {
        if (expanded)
            close();
        else
            open();
    }

    function containsPickerPoint(item, x, y) {
        if (!item)
            return false;
        const buttonPoint = root.mapFromItem(item, x, y);
        const menuPoint = menu.mapFromItem(item, x, y);
        const inButton = buttonPoint.x >= 0 && buttonPoint.x <= root.width
            && buttonPoint.y >= 0 && buttonPoint.y <= root.height;
        const inMenu = menu.visible && menuPoint.x >= 0
            && menuPoint.x <= menu.width && menuPoint.y >= 0
            && menuPoint.y <= menu.height;
        return inButton || inMenu;
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
                root.close();
                event.accepted = true;
            }
        } else if (event.key === Qt.Key_Escape && root.expanded) {
            root.close();
            event.accepted = true;
        }
    }

    onEnabledChanged: {
        if (!enabled)
            close();
    }

    onVisibleChanged: {
        if (!visible)
            close();
    }

    // Watch the whole popout without consuming the click, so a tap elsewhere
    // dismisses this menu and still reaches whatever it landed on.
    TapHandler {
        enabled: root.expanded && root.enabled && root.visible
        margin: root.Window.window
            ? Math.max(root.Window.window.width, root.Window.window.height) : 0
        onTapped: eventPoint => {
            if (!root.containsPickerPoint(root,
                    eventPoint.position.x, eventPoint.position.y))
                root.close();
        }
    }

    T3BarControl {
        id: trigger
        anchors.fill: parent
        text: root.selectedLabel()
        accessibleDescription: root.text
        maxWidth: root.maxWidth
        brand: root.brand
        symbol: root.symbol
        tint: root.tint
        iconTint: root.iconTint
        active: root.expanded
        enabled: root.enabled
        onTriggered: root.toggle()
    }

    Rectangle {
        id: menu

        parent: root.popupHostItem
        z: 1000
        visible: root.expanded && root.enabled
        readonly property real preferredX: root.alignRight
            ? root.width - width : 0
        readonly property real preferredY: root.openUpward
            ? -height - 6 : root.height + 6
        x: root.popupHostOrigin.x + Math.max(root.popupBoundsLeft,
            Math.min(preferredX, root.popupBoundsRight - width))
        y: root.popupHostOrigin.y + Math.max(root.popupBoundsTop,
            Math.min(preferredY, root.popupBoundsBottom - height))
        width: Math.min(Math.max(root.menuWidth, root.width),
            Math.max(1, root.popupBoundsRight - root.popupBoundsLeft))
        height: root.popupHeight
        radius: T3Theme.panelRadius
        color: T3Theme.overlay
        border.width: 1
        border.color: T3Theme.borderStrong
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
                    model: root.options

                    delegate: Rectangle {
                        id: choice

                        required property var modelData
                        required property int index
                        readonly property string choiceId: root.optionId(modelData)
                        readonly property bool chosen: choiceId === root.value

                        width: parent ? parent.width : 0
                        height: Theme.pickerRowHeight
                        radius: T3Theme.controlRadius
                        color: chosen ? T3Theme.accentSoft
                            : choiceMouse.containsMouse ? T3Theme.hoverStrong : "transparent"
                        opacity: modelData.disabled === true ? 0.35 : 1

                        BrandIcon {
                            id: choiceMark
                            visible: String(choice.modelData.icon ?? "") !== ""
                            anchors.left: parent.left
                            anchors.leftMargin: 8
                            anchors.verticalCenter: parent.verticalCenter
                            width: visible ? 14 : 0
                            height: 14
                            name: String(choice.modelData.icon ?? "")
                        }

                        Text {
                            id: choiceLabel
                            anchors.left: choiceMark.visible ? choiceMark.right : parent.left
                            anchors.leftMargin: choiceMark.visible ? 7 : 8
                            anchors.right: choiceDetail.left
                            anchors.rightMargin: 6
                            anchors.verticalCenter: parent.verticalCenter
                            text: root.optionLabel(choice.modelData)
                            elide: Text.ElideRight
                            font.family: T3Theme.fontUi
                            font.pixelSize: Theme.typography.control
                            color: choice.chosen ? T3Theme.textPrimary : T3Theme.textSecondary
                        }

                        Text {
                            id: choiceDetail
                            anchors.right: mark.visible ? mark.left : parent.right
                            anchors.rightMargin: mark.visible ? 5 : 9
                            anchors.verticalCenter: parent.verticalCenter
                            width: Math.min(implicitWidth, parent.width / 3)
                            text: String(choice.modelData.detail ?? "")
                            elide: Text.ElideRight
                            horizontalAlignment: Text.AlignRight
                            font.family: T3Theme.fontUi
                            font.pixelSize: Theme.typography.metadata
                            color: T3Theme.textFaint
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
                            color: T3Theme.accent
                        }

                        MouseArea {
                            id: choiceMouse
                            anchors.fill: parent
                            enabled: choice.modelData.disabled !== true
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                root.selected(choice.choiceId);
                                root.close();
                                root.forceActiveFocus();
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
            edgeColor: T3Theme.overlay
            thumbColor: T3Theme.accent
        }
    }
}
