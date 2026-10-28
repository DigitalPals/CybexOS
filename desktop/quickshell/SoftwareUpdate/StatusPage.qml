import QtQuick
import QtQuick.Controls as Controls
import "../Common"
import "../Common/Format.js" as Format

// A centred status: a toned icon, what is happening, and what to do next.
// The page's buttons, facts and choices follow as its own content.
Flickable {
    id: root

    property string glyph: "info-circle"
    // accent, ok, warn, error or neutral.
    property string tone: "accent"
    property string title: ""
    property string body: ""
    property bool busy: false
    // A measured transfer fraction only; -1 means indeterminate activity.
    property real progress: -1
    property string progressLabel: ""
    default property alias content: extra.data

    readonly property color toneFill: tone === "ok" ? Theme.okBg : tone === "warn" ? Theme.amberBg
        : tone === "error" ? Theme.redBg : Theme.chip
    readonly property color toneInk: tone === "ok" ? Theme.ok : tone === "warn" ? Theme.amber
        : tone === "error" ? Theme.redText : tone === "neutral" ? Theme.textMid : Theme.accentText

    contentWidth: width
    contentHeight: Math.max(height, column.implicitHeight + Theme.scaled(64))
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    flickableDirection: Flickable.VerticalFlick
    Controls.ScrollBar.vertical: Controls.ScrollBar {}

    Column {
        id: column
        width: Math.min(root.width - Theme.scaled(56), Theme.scaled(520))
        x: Math.round((root.width - width) / 2)
        y: Math.max(Theme.scaled(32), Math.round((root.contentHeight - implicitHeight) / 2))
        spacing: Theme.scaled(10)

        Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            width: Theme.scaled(80)
            height: width
            radius: Theme.scaled(24)
            color: root.toneFill
            Sym {
                anchors.centerIn: parent
                name: root.glyph
                size: Theme.scaled(38)
                color: root.toneInk
            }
        }

        Item { width: 1; height: Theme.scaled(6) }

        Text {
            objectName: "updateTitle"
            width: parent.width
            text: root.title
            color: Theme.textHi
            horizontalAlignment: Text.AlignHCenter
            font.family: Theme.fontMenu
            font.pixelSize: Theme.typography.heading
            font.weight: Theme.weightSemibold
            wrapMode: Text.Wrap
            textFormat: Text.PlainText
            Accessible.role: Accessible.Heading
            Accessible.name: text
        }

        Text {
            width: parent.width
            visible: text !== ""
            text: root.body
            color: Theme.textMid
            horizontalAlignment: Text.AlignHCenter
            font.family: Theme.fontMenu
            font.pixelSize: Theme.typography.primary
            lineHeight: 1.15
            wrapMode: Text.Wrap
            textFormat: Text.PlainText
        }

        Rectangle {
            id: track
            objectName: "updateProgress"
            visible: root.busy
            anchors.horizontalCenter: parent.horizontalCenter
            width: Math.min(parent.width, Theme.scaled(380))
            height: Theme.scaled(6)
            radius: height / 2
            color: Theme.chip
            clip: true
            Accessible.role: Accessible.ProgressBar
            Accessible.name: root.progressLabel
            Accessible.description: root.progress >= 0 ? Math.round(root.progress * 100) + "%" : I18n.tr("In progress")
            Rectangle {
                visible: root.progress >= 0
                width: track.width * Format.clamp01(root.progress)
                height: track.height
                radius: height / 2
                color: Theme.accent
            }
            Rectangle {
                id: sweep
                visible: root.progress < 0
                width: track.width * 0.32
                height: track.height
                radius: height / 2
                color: Theme.accent
                x: Theme.reducedMotion ? (track.width - width) / 2 : 0
                NumberAnimation on x {
                    running: track.visible && sweep.visible && !Theme.reducedMotion
                    from: -sweep.width
                    to: track.width
                    duration: 1500
                    loops: Animation.Infinite
                    easing.type: Easing.InOutQuad
                }
            }
        }

        Column {
            id: extra
            width: parent.width
            topPadding: Theme.scaled(12)
            spacing: Theme.scaled(14)
        }
    }
}
