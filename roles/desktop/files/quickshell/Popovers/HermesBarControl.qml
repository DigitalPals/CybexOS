pragma ComponentBehavior: Bound
import QtQuick
import "../Common"

// One compact control on the Hermes composer bar. The popup is owned by the
// caller so model and reasoning menus can have different presentations.
Item {
    id: root

    property string text: ""
    property string accessibleDescription: ""
    property string brand: ""
    property string symbol: ""
    property color tint: HermesTheme.textSecondary
    property color iconTint: HermesTheme.textFaint
    property bool active: false
    property real maxWidth: 1000
    signal triggered()

    implicitWidth: Math.min(maxWidth, trigger.implicitWidth)
    implicitHeight: 26
    activeFocusOnTab: enabled && visible
    Accessible.role: Accessible.ComboBox
    Accessible.name: root.text
    Accessible.description: root.accessibleDescription
    Accessible.onPressAction: root.triggered()

    Keys.onPressed: event => {
        if (!root.enabled)
            return;
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                || event.key === Qt.Key_Space) {
            root.triggered();
            event.accepted = true;
        }
    }

    Rectangle {
        id: trigger
        implicitWidth: 12 + chevron.width + triggerRow.spacing
            + valueText.implicitWidth
            + (brandMark.visible ? brandMark.width + triggerRow.spacing : 0)
            + (symbolMark.visible ? symbolMark.implicitWidth + triggerRow.spacing : 0)
        anchors.fill: parent
        radius: HermesTheme.controlRadius
        color: triggerMouse.containsMouse && root.enabled
            ? HermesTheme.hover : "transparent"
        opacity: root.enabled ? 1 : 0.45
        border.width: root.activeFocus || root.active ? 1 : 0
        border.color: HermesTheme.focus

        Row {
            id: triggerRow
            anchors.left: parent.left
            anchors.leftMargin: 6
            anchors.right: parent.right
            anchors.rightMargin: 6
            anchors.verticalCenter: parent.verticalCenter
            spacing: 5

            BrandIcon {
                id: brandMark
                visible: root.brand !== ""
                anchors.verticalCenter: parent.verticalCenter
                width: visible ? 15 : 0
                height: 15
                name: root.brand
            }

            Sym {
                id: symbolMark
                visible: root.brand === "" && root.symbol !== ""
                anchors.verticalCenter: parent.verticalCenter
                name: root.symbol
                size: Theme.iconSmall
                symWeight: 450
                color: root.iconTint
            }

            Text {
                id: valueText
                anchors.verticalCenter: parent.verticalCenter
                width: Math.min(implicitWidth, Math.max(0, triggerRow.width
                    - (brandMark.visible ? brandMark.width + triggerRow.spacing : 0)
                    - (symbolMark.visible ? symbolMark.implicitWidth + triggerRow.spacing : 0)
                    - chevron.width - triggerRow.spacing))
                text: root.text
                elide: Text.ElideRight
                font.family: HermesTheme.fontUi
                font.pixelSize: Theme.typography.primary
                font.weight: Theme.weightMedium
                color: root.tint
            }

            Sym {
                id: chevron
                anchors.verticalCenter: parent.verticalCenter
                name: root.active ? "expand_less" : "expand_more"
                size: Theme.iconSmall
                symWeight: 450
                color: HermesTheme.textFaint
            }
        }

        MouseArea {
            id: triggerMouse
            anchors.fill: parent
            enabled: root.enabled
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
                root.forceActiveFocus();
                root.triggered();
            }
        }
    }
}
