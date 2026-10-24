pragma ComponentBehavior: Bound
import QtQuick
import "../Common"
import "../Common/Format.js" as Format

// Bars that follow the microphone while the assistant listens: the most
// recent level enters on the right and the history scrolls left, so a
// spoken phrase reads as a shape rather than one jittering meter.
Item {
    id: root

    property real level: 0
    property bool running: false
    property color color: Theme.accent
    property int bars: 28
    property var history: []

    implicitHeight: Theme.scaled(26)

    function sample() {
        // Peaks are linear; a square root is closer to how loud it sounds.
        const value = Math.sqrt(Format.clamp01(root.level));
        const next = root.history.slice(Math.max(0, root.history.length - root.bars + 1));
        next.push(value);
        root.history = next;
    }

    onRunningChanged: {
        if (!running)
            history = [];
    }

    Timer {
        interval: 45
        repeat: true
        running: root.running && root.visible
        onTriggered: root.sample()
    }

    Row {
        anchors.verticalCenter: parent.verticalCenter
        anchors.right: parent.right
        spacing: Math.max(2, Math.round(root.width / root.bars * 0.35))

        Repeater {
            model: root.bars

            delegate: Rectangle {
                required property int index
                readonly property int offset: root.bars - 1 - index
                readonly property real value: offset < root.history.length
                    ? root.history[root.history.length - 1 - offset] : 0

                anchors.verticalCenter: parent.verticalCenter
                width: Math.max(2, Math.round(root.width / root.bars * 0.65))
                height: Math.max(3, root.height * (0.12 + 0.88 * value))
                radius: width / 2
                color: root.color
                opacity: 0.45 + 0.55 * value

                Behavior on height {
                    enabled: !Theme.reducedMotion
                    NumberAnimation { duration: 60 }
                }
            }
        }
    }
}
