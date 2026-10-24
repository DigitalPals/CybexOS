pragma ComponentBehavior: Bound
import QtQuick
import "../Common"
import "../Common/AssistantHelpers.js" as AssistantHelpers

// The pill while the agent works: what it is doing right now, how long it
// has taken and Stop. Anything it needs a decision on stacks underneath;
// the turn does not continue until it is answered.
AssistantSurface {
    id: root

    readonly property var turn: Assistant.turn
    padding: Theme.scaled(8)

    Item {
        width: parent.width
        height: Theme.scaled(32)

        Item {
            id: spinner
            anchors.left: parent.left
            anchors.leftMargin: Theme.scaled(4)
            anchors.verticalCenter: parent.verticalCenter
            width: Theme.iconMedium
            height: Theme.iconMedium

            Sym {
                anchors.fill: parent
                visible: !Assistant.waiting
                name: "progress_activity"
                size: Theme.iconMedium
                color: Theme.accentText

                RotationAnimator on rotation {
                    running: !Assistant.waiting && root.visible && !Theme.reducedMotion
                    from: 0
                    to: 360
                    duration: 900
                    loops: Animation.Infinite
                }
            }

            // Its own glyph: a stopped spinner would leave it tilted.
            Sym {
                anchors.fill: parent
                visible: Assistant.waiting
                name: "priority_high"
                size: Theme.iconMedium
                color: Theme.amber
            }
        }

        AnimatedText {
            anchors.left: spinner.right
            anchors.leftMargin: Theme.scaled(10)
            anchors.right: elapsed.left
            anchors.rightMargin: Theme.scaled(8)
            anchors.verticalCenter: parent.verticalCenter
            text: Assistant.waiting ? I18n.tr("Needs your answer")
                : root.turn && root.turn.step ? root.turn.step : I18n.tr("Thinking")
            elide: Text.ElideRight
            color: Theme.textHi
            font.family: Theme.fontMenu
            font.pixelSize: Theme.typography.secondary
        }

        Text {
            id: elapsed
            anchors.right: stopButton.left
            anchors.rightMargin: Theme.scaled(6)
            anchors.verticalCenter: parent.verticalCenter
            text: root.turn ? AssistantHelpers.elapsedLabel(Assistant.now - root.turn.startedAt) : ""
            color: Theme.textLow
            font.family: Theme.fontNumeric
            font.pixelSize: Theme.typography.metadata
            font.features: Theme.tabularNumberFeatures
        }

        AssistantButton {
            id: stopButton
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            label: I18n.tr("Stop")
            glyph: "stop"
            danger: true
            controlHeight: Theme.scaled(28)
            onTriggered: Assistant.stop()
        }
    }

    Repeater {
        model: Assistant.approvals

        delegate: AssistantApproval {
            required property var modelData
            width: root.width - root.padding * 2
            approval: modelData
        }
    }
}
