pragma ComponentBehavior: Bound
import QtQuick
import "../Common"

// One control on the composer's action bar: mark, current value, chevron.
//
// Purely the button. What opens below or above it is the caller's business —
// a short list for reasoning and access, a whole provider/model panel for the
// model — which is exactly why the button lives on its own: three controls
// that must read as one sentence cannot afford to drift apart.
Item {
    id: root

    property string text: ""
    // What the control is for, when the value alone ("Max") does not say.
    property string accessibleDescription: ""
    // Either an approved brand name or a Tabler icon. A control that shows
    // both marks would be two icons for one idea, so brand wins.
    property string brand: ""
    property string symbol: ""
    property color tint: T3Theme.textSecondary
    property color iconTint: T3Theme.textFaint
    // Whether the thing this button opens is currently open.
    property bool active: false
    // The bar is a fixed width the prompt above it does not have to respect,
    // so the longest label yields first instead of pushing the send action off
    // the end.
    property real maxWidth: 1000
    property real minimumWidth: 48
    readonly property real naturalWidth: trigger.implicitWidth
    signal triggered()

    implicitWidth: Math.min(maxWidth,
        Math.max(Math.min(minimumWidth, maxWidth), naturalWidth))
    implicitHeight: 26
    clip: true
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

        // Measured from the *content* widths, never from the laid-out Row:
        // the label's own width is clamped against this Row, so reading the
        // Row back here would close a binding loop.
        implicitWidth: 12 + chevron.width + triggerRow.spacing
            + valueText.implicitWidth
            + (brandMark.visible ? brandMark.width + triggerRow.spacing : 0)
            + (symbolMark.visible ? symbolMark.implicitWidth + triggerRow.spacing : 0)
        anchors.fill: parent
        radius: T3Theme.controlRadius
        color: triggerMouse.containsMouse && root.enabled
            ? T3Theme.hover : "transparent"
        opacity: root.enabled ? 1 : 0.45
        border.width: root.activeFocus || root.active ? 1 : 0
        border.color: T3Theme.focus

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
                font.family: T3Theme.fontUi
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
                color: T3Theme.textFaint
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
