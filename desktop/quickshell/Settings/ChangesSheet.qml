pragma ComponentBehavior: Bound
import QtQuick
import "../Common"

// Review changes (2026-10 redesign): every draft waiting for Apply, from
// every page, in one sheet over the window. "Applies now" settles session
// drafts at once; "System change" prepares a deployment you review in
// Software Update and use after a restart. Each row can be dropped on its
// own; Discard all and Apply settle the rest. The sheet closes by itself
// once nothing is left to review.
Item {
    id: root

    property bool open: false
    readonly property var items: SettingsChanges.items
    readonly property var plan: SettingsChanges.plan
    readonly property var liveItems: items.filter(item => !item.system)
    readonly property var systemItems: items.filter(item => item.system)

    visible: open
    Accessible.role: Accessible.Dialog
    Accessible.name: I18n.tr("Review changes")

    function show() {
        if (SettingsChanges.count === 0)
            return;
        open = true;
        Qt.callLater(() => applyAction.forceActiveFocus());
    }

    function hide() {
        open = false;
    }

    Connections {
        target: SettingsChanges
        function onCountChanged() {
            if (SettingsChanges.count === 0 && !SettingsChanges.applying)
                root.hide();
        }
        function onApplyingChanged() {
            if (!SettingsChanges.applying && SettingsChanges.count === 0)
                root.hide();
        }
    }

    // Click outside to dismiss: the scrim is not a button, so no hand.
    Rectangle {
        anchors.fill: parent
        color: Theme.scrim
        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.ArrowCursor
            onClicked: root.hide()
        }
    }

    Rectangle {
        id: sheet
        width: Math.min(Theme.scaled(580, Theme.typeScale), root.width - Theme.scaled(32))
        height: Math.min(body.implicitHeight + Theme.scaled(40), root.height - Theme.scaled(32))
        anchors.centerIn: parent
        radius: Theme.popRadius
        color: Theme.popBg
        border.width: 1
        border.color: Theme.hairline
        // Swallow clicks so they never reach the scrim's close.
        MouseArea { anchors.fill: parent }

        Flickable {
            anchors.fill: parent
            anchors.margins: Theme.scaled(20)
            contentHeight: body.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            interactive: contentHeight > height

            Column {
                id: body
                width: parent.width
                spacing: Theme.scaled(18)

                Column {
                    width: parent.width
                    spacing: Theme.scaled(3)
                    Text {
                        text: I18n.tr("Review changes")
                        font.family: Theme.fontMenu
                        font.pixelSize: Theme.typography.heading
                        font.weight: Theme.weightSemibold
                        color: Theme.textHi
                    }
                    Text {
                        width: parent.width
                        wrapMode: Text.Wrap
                        text: (root.items.length === 1 ? I18n.tr("1 change waiting.")
                                : I18n.format("%1 changes waiting.", [root.items.length]))
                            + " " + I18n.tr("Everything else in Settings applies as you change it.")
                        font.family: Theme.fontMenu
                        font.pixelSize: Theme.typography.secondary
                        color: Theme.textFaint
                    }
                }

                SettingsGroup {
                    width: parent.width
                    visible: root.liveItems.length > 0
                    title: I18n.tr("Applies now")
                    Repeater {
                        model: root.liveItems
                        delegate: ChangeRow {}
                    }
                }

                SettingsGroup {
                    width: parent.width
                    visible: root.systemItems.length > 0
                    title: I18n.tr("System change")
                    changeTag: "restart"
                    Repeater {
                        model: root.systemItems
                        delegate: ChangeRow {}
                    }
                    SettingsHint {
                        width: parent.width
                        text: I18n.tr("Cybex OS builds the new system in the background and keeps this one as a recovery point. Review it in Software Update; after the restart it starts once on trial, and the previous system comes back if the desktop does not start.")
                    }
                    // The updater keeps one deployment at a time: say which one
                    // is in the way, and where to settle it.
                    SettingsHint {
                        width: parent.width
                        visible: root.plan.waiting.length > 0
                        tone: "warning"
                        text: Updates.ready
                            ? I18n.tr("Software Update holds a prepared change. Apply or discard it there first; these are prepared after it.")
                            : Updates.rebootRecommended
                            ? I18n.tr("Restart to finish the current system change first; these are prepared after it.")
                            : SettingsChanges.systemBusy
                            ? I18n.tr("Another system change is being prepared. These follow once it is finished.")
                            : I18n.tr("Recovery point cleanup is prepared on its own, after this change is applied.")
                    }
                    SettingsAction {
                        visible: root.plan.waiting.length > 0 && (Updates.ready || Updates.rebootRecommended)
                        text: I18n.tr("Software Update…")
                        onTriggered: {
                            root.hide();
                            Updates.show();
                        }
                    }
                }

                SettingsHint {
                    width: parent.width
                    visible: SettingsChanges.error !== ""
                    tone: "error"
                    text: SettingsChanges.error
                }

                Item {
                    width: parent.width
                    height: footer.height

                    SettingsAction {
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        text: I18n.tr("Discard all")
                        danger: true
                        enabled: !SettingsChanges.applying
                        onTriggered: SettingsChanges.discardAll()
                    }
                    Row {
                        id: footer
                        anchors.right: parent.right
                        spacing: Theme.controlSpacing
                        SettingsAction {
                            text: I18n.tr("Cancel")
                            onTriggered: root.hide()
                        }
                        SettingsAction {
                            id: applyAction
                            primary: true
                            text: SettingsChanges.applying ? I18n.tr("Applying…")
                                : root.plan.live.length > 0 && root.plan.system !== "" ? I18n.tr("Apply and prepare")
                                : root.plan.system !== "" ? I18n.tr("Prepare system change")
                                : I18n.tr("Apply changes")
                            enabled: !SettingsChanges.applying && root.plan.steps.length > 0
                            onTriggered: SettingsChanges.apply()
                        }
                    }
                }
            }
        }
    }

    // One change: where it was made, what it becomes, what it was.
    component ChangeRow: ValueRow {
        id: changeRow
        required property var modelData
        width: parent ? parent.width : 0
        label: modelData.pageLabel + " › " + modelData.label
        value: modelData.after
        hint: modelData.before !== "" ? I18n.tr("Was ") + modelData.before
            : modelData.system ? I18n.tr("Applies after a restart") : ""
        SettingsAction {
            compact: true
            glyph: "close"
            text: I18n.tr("Discard this change")
            enabled: !SettingsChanges.applying
            onTriggered: SettingsChanges.discardItem(changeRow.modelData)
        }
    }

    Keys.onEscapePressed: event => {
        root.hide();
        event.accepted = true;
    }
}
