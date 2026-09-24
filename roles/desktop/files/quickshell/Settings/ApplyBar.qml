import QtQuick
import "../Common"
import "../Common/Format.js" as Format

// The bar pinned to the foot of a page whose changes wait for confirmation
// (Displays, Network): shell settings apply as they change, these do not, and
// the bar is where a page says so. It has two states.
//
// pending — edits exist that are not applied: "N changes not applied yet",
//           the changed rows named underneath, Discard and Apply.
// trial   — applied, and counting down to an automatic revert: the question,
//           the time left as copy and as a draining line, Revert and Keep.
//
// Place it in a SettingsPage's `overlay` and give the page `bottomInset:
// applyBar.reservedHeight` so the last row scrolls clear of it.
Rectangle {
    id: root

    property bool trial: false
    property bool pending: false
    property string title: ""
    property string detail: ""
    // Share of the trial still left, 1 → 0.
    property real remaining: 1
    property bool busy: false
    property string applyText: "Apply"
    property string discardText: "Discard"
    property string keepText: "Keep changes"
    property string revertText: "Revert now"
    signal apply()
    signal discard()
    signal keep()
    signal revert()

    readonly property bool shown: trial || pending
    readonly property real reservedHeight: shown ? height + Theme.settingsContentSpacing : 0

    anchors.left: parent ? parent.left : undefined
    anchors.right: parent ? parent.right : undefined
    anchors.bottom: parent ? parent.bottom : undefined
    height: Math.max(Theme.scaled(52), copy.implicitHeight + Theme.scaled(18))
    visible: shown
    color: Theme.popBg
    Accessible.role: root.trial ? Accessible.AlertMessage : Accessible.StaticText
    Accessible.name: root.title + ". " + root.detail

    Rectangle {
        width: parent.width
        height: 1
        color: Theme.stroke
    }

    // The trial's clock, drawn as the line along the bar's top edge.
    Rectangle {
        visible: root.trial
        width: parent.width * Format.clamp01(root.remaining)
        height: 2
        color: Theme.accent
        Behavior on width { NumberAnimation { duration: 450 } }
    }

    Column {
        id: copy
        anchors.left: parent.left
        anchors.leftMargin: Theme.settingsMarkInset
        anchors.right: actions.left
        anchors.rightMargin: Theme.controlSpacing
        anchors.verticalCenter: parent.verticalCenter
        spacing: Theme.scaled(1)

        Text {
            width: parent.width
            text: root.title
            font.family: Theme.fontMenu
            font.pixelSize: Theme.typography.control
            font.weight: Theme.weightSemibold
            color: Theme.textHi
            elide: Text.ElideRight
        }
        Text {
            width: parent.width
            visible: text !== ""
            text: root.detail
            font.family: Theme.fontMenu
            font.pixelSize: Theme.typography.secondary
            color: Theme.textFaint
            elide: Text.ElideRight
        }
    }

    Row {
        id: actions
        anchors.right: parent.right
        anchors.rightMargin: Theme.scaled(10)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Theme.controlSpacing
        enabled: !root.busy

        SettingsAction {
            text: root.trial ? root.revertText : root.discardText
            glyph: root.trial ? "undo" : ""
            onTriggered: root.trial ? root.revert() : root.discard()
        }
        SettingsAction {
            primary: true
            text: root.busy ? "Applying…" : root.trial ? root.keepText : root.applyText
            onTriggered: root.trial ? root.keep() : root.apply()
        }
    }
}
