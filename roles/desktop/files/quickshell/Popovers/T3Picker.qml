pragma ComponentBehavior: Bound
import QtQuick
import "../Common"

// Small keyboard-friendly picker used by the T3 composer and New Thread form.
Item {
    id: root

    property string label: ""
    property string value: ""
    property color valueColor: T3Theme.textSecondary
    property var options: []
    property bool expanded: false
    property bool openUpward: true
    property int menuRows: 7
    property bool alignRight: false
    property Item popupBoundsItem: null
    // Host the menu at the page boundary so a clipped form viewport does not
    // clip its choices or remove them from pointer hit testing.
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
    // Kept in trigger coordinates for parents that reserve scroll space even
    // though the painted menu itself is reparented to popupHostItem.
    readonly property real popupOffsetY: menu.triggerY
    signal selected(string value)

    implicitHeight: 34
    z: expanded ? 100 : 0
    activeFocusOnTab: enabled && visible
    Accessible.role: Accessible.ComboBox
    Accessible.name: root.label
    Accessible.description: root.value

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
        return found ? optionLabel(found) : (value !== "" ? value : "Unavailable");
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
        // The containing form may scroll after expansion to reserve the
        // menu's height, so refresh after that deferred layout settles.
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
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                || event.key === Qt.Key_Space) {
            root.toggle();
            event.accepted = true;
        } else if (event.key === Qt.Key_Down || event.key === Qt.Key_Right) {
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

    // Observe the entire popout window without consuming the click. This
    // lets the underlying control keep working while dismissing this menu
    // whenever the tap lands outside both its button and floating panel.
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

    Rectangle {
        id: button

        anchors.fill: parent
        radius: T3Theme.controlRadius
        color: pickerMouse.containsMouse && root.enabled
            ? T3Theme.hoverStrong : T3Theme.surfaceRaised
        opacity: root.enabled ? 1 : 0.45
        border.width: root.activeFocus || root.expanded ? 1 : 0
        border.color: T3Theme.focus

        Column {
            anchors.left: parent.left
            anchors.leftMargin: 8
            anchors.right: chevron.left
            anchors.rightMargin: 5
            anchors.verticalCenter: parent.verticalCenter
            spacing: 0

            Text {
                visible: root.label !== ""
                width: parent.width
                text: root.label
                elide: Text.ElideRight
                font.family: T3Theme.fontUi
                font.pixelSize: Theme.typography.metadata
                font.weight: Theme.weightMedium
                color: T3Theme.textFaint
            }

            Text {
                width: parent.width
                text: root.selectedLabel()
                elide: Text.ElideRight
                font.family: T3Theme.fontUi
                font.pixelSize: Theme.typography.control
                color: root.valueColor
            }
        }

        Sym {
            id: chevron
            anchors.right: parent.right
            anchors.rightMargin: 7
            anchors.verticalCenter: parent.verticalCenter
            name: root.expanded ? "expand_less" : "expand_more"
            size: Theme.iconSmall
            symWeight: 450
            color: T3Theme.textFaint
        }

        MouseArea {
            id: pickerMouse
            anchors.fill: parent
            enabled: root.enabled
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
                root.forceActiveFocus();
                root.toggle();
            }
        }
    }

    Rectangle {
        id: menu

        parent: root.popupHostItem
        z: 1000
        visible: root.expanded && root.enabled
        readonly property real preferredX: root.alignRight
            ? root.width - width : 0
        readonly property real preferredY: root.openUpward
            ? -height - 4 : root.height + 4
        readonly property real triggerX: Math.max(root.popupBoundsLeft,
            Math.min(preferredX, root.popupBoundsRight - width))
        readonly property real triggerY: Math.max(root.popupBoundsTop,
            Math.min(preferredY, root.popupBoundsBottom - height))
        x: root.popupHostOrigin.x + triggerX
        y: root.popupHostOrigin.y + triggerY
        width: Math.min(root.width,
            Math.max(1, root.popupBoundsRight - root.popupBoundsLeft))
        height: root.popupHeight
        radius: T3Theme.panelRadius
        // This panel floats over the rest of the composer. A recessed tile
        // fill is intentionally very translucent and lets the controls below
        // compete with the choices, so use the dense menu glass instead.
        color: T3Theme.overlay
        border.width: 1
        border.color: T3Theme.borderStrong
        clip: true

        Flickable {
            id: pickerFlick
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

                        Text {
                            anchors.left: parent.left
                            anchors.leftMargin: 7
                            anchors.right: shortcut.left
                            anchors.rightMargin: 5
                            anchors.verticalCenter: parent.verticalCenter
                            text: root.optionLabel(choice.modelData)
                            elide: Text.ElideRight
                            font.family: T3Theme.fontUi
                            font.pixelSize: Theme.typography.control
                            color: choice.chosen ? T3Theme.textPrimary : T3Theme.textSecondary
                        }

                        Text {
                            id: shortcut
                            anchors.right: parent.right
                            anchors.rightMargin: mark.visible ? 27 : 9
                            anchors.verticalCenter: parent.verticalCenter
                            text: choice.index < 9 ? String(choice.index + 1) : ""
                            font.family: T3Theme.fontUi
                            font.pixelSize: Theme.typography.secondary
                            font.features: T3Theme.tabularNumberFeatures
                            color: T3Theme.textFaint
                        }

                        Sym {
                            id: mark
                            visible: choice.chosen
                            anchors.right: parent.right
                            anchors.rightMargin: 7
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
            target: pickerFlick
            fadeSize: 16
            edgeColor: T3Theme.overlay
            thumbColor: T3Theme.accent
        }
    }
}
