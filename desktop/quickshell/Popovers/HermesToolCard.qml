import QtQuick
import "../Common"

// The single ephemeral tool-activity line. HermesTranscript swaps its payload
// as calls advance instead of retaining a card for every tool transition.
Rectangle {
    id: root

    required property var tool

    readonly property bool running: !tool.terminal
        && ["running", "started", "pending", "working"].indexOf(tool.status) >= 0
    readonly property bool failed: tool.status === "error" || tool.status === "failed"
    readonly property string toolName: String(tool.label || tool.name || "Tool")
    readonly property string toolStatus: String(tool.status
        || (running ? "running" : "completed"))
    readonly property string statusIcon: failed ? "error"
        : running ? "progress_activity"
            : tool.status === "interrupted" || tool.status === "cancelled"
                ? "cancel" : "check_circle"
    readonly property color statusColor: failed ? HermesTheme.red
        : running ? HermesTheme.accent : HermesTheme.success
    readonly property string detailText: String(tool.label || tool.input
        || tool.error || tool.output || tool.detail || "")
        .replace(/\s+/g, " ").trim()

    width: parent ? parent.width : 0
    implicitHeight: 30
    radius: HermesTheme.rowRadius
    color: failed ? HermesTheme.redSoft
        : running ? HermesTheme.accentSubtle : "transparent"
    border.width: failed || running ? 1 : 0
    border.color: failed ? HermesTheme.redBorder : HermesTheme.border
    Accessible.role: Accessible.StaticText
    Accessible.name: toolName + ", " + toolStatus

    Sym {
        id: statusGlyph
        x: 8
        anchors.verticalCenter: parent.verticalCenter
        name: root.statusIcon
        size: Theme.iconSmall
        symWeight: 460
        color: root.statusColor

        // Hidden behind another panel it stops too, and a stopped value
        // source leaves its angle behind for the finished status glyph.
        RotationAnimation on rotation {
            running: root.running && statusGlyph.visible && !Theme.reducedMotion
            from: 0
            to: 360
            loops: Animation.Infinite
            duration: 950
            onRunningChanged: if (!running) statusGlyph.rotation = 0
        }
    }

    Text {
        id: toolStatusLabel
        anchors.right: parent.right
        anchors.rightMargin: 8
        anchors.verticalCenter: parent.verticalCenter
        text: root.running ? "running…" : root.toolStatus
        font.family: HermesTheme.fontUi
        font.pixelSize: Theme.typography.metadata
        color: root.statusColor
    }

    Text {
        anchors.left: statusGlyph.right
        anchors.leftMargin: 7
        anchors.right: toolStatusLabel.left
        anchors.rightMargin: 8
        anchors.verticalCenter: parent.verticalCenter
        text: root.detailText !== ""
            ? root.toolName + " · " + root.detailText : root.toolName
        textFormat: Text.PlainText
        maximumLineCount: 1
        elide: Text.ElideRight
        font.family: HermesTheme.fontMono
        font.pixelSize: Theme.typography.metadata
        color: root.failed ? HermesTheme.red : HermesTheme.textSecondary
    }
}
