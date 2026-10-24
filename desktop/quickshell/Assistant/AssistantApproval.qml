pragma ComponentBehavior: Bound
import QtQuick
import "../Common"
import "../Common/AssistantHelpers.js" as AssistantHelpers

// One thing the agent wants to do that the policy would not decide alone
// (desktop/assistant/cybexos_assistant/policy.py): a command, an edit outside
// the desktop's own preferences, or applying a staged system change. The
// agent waits until this card is answered. Applying a staged change shows
// the actual package changes; polkit then asks for the password.
Rectangle {
    id: root

    required property var approval
    readonly property string kind: approval.kind || "other"
    readonly property bool applying: kind === "apply"
    readonly property var closure: AssistantHelpers.closureChanges(approval.changes || "", 6)
    readonly property string body: kind === "command" ? (approval.command || "")
        : kind === "edit" ? (approval.diff || "")
        : applying ? "" : (approval.command || approval.diff || "")

    implicitHeight: column.implicitHeight + Theme.scaled(20)
    radius: Theme.scaled(12)
    color: Theme.cardFill
    border.width: 1
    border.color: applying ? Theme.hairline : Theme.amberBorder

    Column {
        id: column
        x: Theme.scaled(10)
        y: Theme.scaled(10)
        width: parent.width - Theme.scaled(20)
        spacing: Theme.scaled(8)

        Row {
            width: parent.width
            spacing: Theme.scaled(8)

            Sym {
                id: kindGlyph
                anchors.verticalCenter: parent.verticalCenter
                name: AssistantHelpers.APPROVAL_GLYPHS[root.kind] || "security"
                size: Theme.iconMedium
                color: root.applying ? Theme.accentText : Theme.amber
            }

            Text {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - kindGlyph.width - parent.spacing
                text: root.approval.title || I18n.tr("Allow this?")
                elide: Text.ElideRight
                color: Theme.textHi
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.secondary
                font.weight: Theme.weightSemibold
            }
        }

        Text {
            width: parent.width
            visible: text !== ""
            text: root.kind === "edit" && root.approval.path
                ? AssistantHelpers.displayPath(root.approval.path, Assistant.home)
                : (root.approval.detail || "")
            wrapMode: Text.WrapAtWordBoundaryOrAnywhere
            maximumLineCount: 4
            elide: Text.ElideRight
            color: Theme.textMid
            font.family: root.kind === "edit" ? Theme.fontMono : Theme.fontMenu
            font.pixelSize: Theme.typography.metadata
        }

        // The command or the change, as the agent wrote it.
        Rectangle {
            width: parent.width
            visible: root.body !== ""
            height: visible ? Math.min(bodyText.implicitHeight, Theme.scaled(150)) + Theme.scaled(14) : 0
            radius: Theme.chipRadius
            color: Theme.well
            clip: true

            Flickable {
                anchors.fill: parent
                anchors.margins: Theme.scaled(7)
                contentWidth: width
                contentHeight: bodyText.implicitHeight
                boundsBehavior: Flickable.StopAtBounds

                Text {
                    id: bodyText
                    width: parent.width
                    text: root.body
                    textFormat: Text.PlainText
                    wrapMode: Text.WrapAnywhere
                    color: Theme.textHi
                    font.family: Theme.fontMono
                    font.pixelSize: Theme.typography.metadata
                }
            }
        }

        // A staged change: what the reviewed build adds, removes and updates.
        Column {
            width: parent.width
            visible: root.applying
            spacing: Theme.scaled(3)

            Repeater {
                model: root.closure.rows

                delegate: Row {
                    id: changeRow
                    required property var modelData
                    width: column.width
                    spacing: Theme.scaled(6)

                    Text {
                        text: changeRow.modelData.kind === "added" ? "+"
                            : changeRow.modelData.kind === "removed" ? "−" : "~"
                        color: changeRow.modelData.kind === "added" ? Theme.ok
                            : changeRow.modelData.kind === "removed" ? Theme.redText : Theme.textLow
                        font.family: Theme.fontMono
                        font.pixelSize: Theme.typography.metadata
                    }

                    Text {
                        width: changeRow.width - Theme.scaled(14)
                        text: changeRow.modelData.name + "  " + changeRow.modelData.change
                        elide: Text.ElideRight
                        color: Theme.textMid
                        font.family: Theme.fontMono
                        font.pixelSize: Theme.typography.metadata
                    }
                }
            }

            Text {
                visible: root.closure.more > 0 || root.closure.rows.length === 0
                text: root.closure.rows.length === 0 ? I18n.tr("No package changes; configuration only.")
                    : I18n.format("and %1 more", [root.closure.more])
                color: Theme.textLow
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.metadata
            }

            Text {
                width: parent.width
                text: root.approval.ready === false
                    ? I18n.tr("The updater does not hold this change as built and checked, so it cannot be applied. Deny it and ask again.")
                    : I18n.tr("Applying asks for the administrator password. A reboot may be needed afterwards; it never happens on its own.")
                wrapMode: Text.WordWrap
                color: Theme.textLow
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.metadata
            }
        }

        Flow {
            width: parent.width
            spacing: Theme.scaled(6)
            layoutDirection: Qt.RightToLeft

            AssistantButton {
                label: root.applying ? I18n.tr("Apply…") : I18n.tr("Allow")
                primary: true
                enabled: !root.applying || root.approval.ready !== false
                onTriggered: Assistant.respond(root.approval.id, "allow")
            }

            AssistantButton {
                visible: !root.applying
                label: I18n.tr("Always in this conversation")
                onTriggered: Assistant.respond(root.approval.id, "always")
            }

            AssistantButton {
                label: root.applying ? I18n.tr("Not now") : I18n.tr("Deny")
                onTriggered: Assistant.respond(root.approval.id, "deny")
            }
        }
    }
}
