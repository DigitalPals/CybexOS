pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls as Controls
import "../Common"
import "../Ui" as Ui
import "../Common/RemoteServerHelpers.js" as Helpers

PopoutPanel {
    id: root
    property bool allDisks: false
    property bool allInterfaces: false
    property bool allTemperatures: false
    readonly property var stats: RemoteServer.sample
    readonly property var net: RemoteServer.selectedNetwork
    readonly property int gutter: Theme.panelPadding
    implicitWidth: Math.min(520, availableWidth > 0 ? availableWidth : 520)
    implicitHeight: Math.min(body.implicitHeight + gutter * 2 + footer.height + 12,
        840, availableHeight > 0 ? availableHeight : 840)

    Claim {
        active: root.visible
        onClaimed: RemoteServer.acquire()
        onReleased: RemoteServer.release()
    }
    Rectangle {
        anchors.fill: parent
        visible: root.drawBackground
        radius: Theme.panelRadius
        color: root.surfaceColor
        border.width: 1
        border.color: root.surfaceBorderColor
    }
    component Label: Text {
        textFormat: Text.PlainText
        font.family: Theme.fontMenu
        font.pixelSize: Theme.typography.secondary
        color: Theme.textDim
        wrapMode: Text.Wrap
    }
    component Heading: Label {
        font.pixelSize: Theme.typography.section
        font.weight: Theme.weightSemibold
        font.letterSpacing: 1
        color: Theme.textMid
    }
    component Card: Rectangle {
        radius: Theme.rowRadius
        color: Theme.cardFill
        border.width: 1
        border.color: Theme.hairlineSoft
    }
    component Meter: Rectangle {
        id: meter
        property real value: 0
        property color tint: value >= 90 ? Theme.amber : Theme.accentText
        height: 5
        radius: 2.5
        color: Theme.hoverFill
        Rectangle {
            width: parent.width * Math.max(0, Math.min(100, meter.value)) / 100
            height: parent.height
            radius: parent.radius
            color: meter.tint
        }
    }
    component StatCard: Card {
        id: stat
        property string title: ""
        property string value: ""
        property string detail: ""
        property var points: []
        height: content.implicitHeight + 28
        Column {
            id: content
            x: 14; y: 14; width: parent.width - 28
            spacing: 8
            Heading { text: stat.title }
            Label {
                width: parent.width
                text: stat.value
                font.family: Theme.fontNumeric
                font.pixelSize: Theme.typography.display
                font.weight: Theme.weightSemibold
                font.features: Theme.tabularNumberFeatures
                color: Theme.textHi
            }
            Ui.TelemetryChart {
                width: parent.width
                points: stat.points
                description: stat.title + " history"
            }
            Label { width: parent.width; text: stat.detail }
        }
    }

    Flickable {
        id: scroll
        anchors.fill: parent
        anchors.margins: root.gutter
        anchors.bottomMargin: root.gutter + footer.height + 12
        contentHeight: body.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        Controls.ScrollBar.vertical: Controls.ScrollBar {}

        Column {
            id: body
            width: scroll.width
            spacing: 16
            Row {
                width: parent.width
                spacing: 12
                Rectangle {
                    width: 42; height: 42; radius: 12
                    color: Qt.alpha(Theme.accentText, 0.10)
                    Sym { anchors.centerIn: parent; name: "dns"; size: 24; color: Theme.accentText }
                }
                Column {
                    width: parent.width - 54
                    spacing: 4
                    Label {
                        width: parent.width
                        text: RemoteServer.label
                        font.pixelSize: Theme.typography.heading
                        font.weight: Theme.weightSemibold
                        color: Theme.textHi
                    }
                    Label {
                        width: parent.width
                        text: root.stats ? root.stats.meta.os + " · Up " + Helpers.uptime(root.stats.uptime)
                            : "Your server, at a glance"
                    }
                }
            }
            Row {
                spacing: 7
                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: 6; height: 6; radius: 3
                    color: RemoteServer.stale || RemoteServer.error ? Theme.amber : Theme.accentText
                }
                Label {
                    text: RemoteServer.status + (root.stats ? " · Updated " + RemoteServer.age : "")
                    color: RemoteServer.stale || RemoteServer.error ? Theme.amber : Theme.textMid
                }
            }
            Card {
                width: parent.width
                height: message.implicitHeight + 24
                visible: !root.stats || RemoteServer.error !== ""
                Label {
                    id: message
                    x: 12; y: 12; width: parent.width - 24
                    text: !RemoteServer.host
                        ? "Choose an SSH host in Settings to start monitoring. Your existing SSH keys and host aliases work here."
                        : RemoteServer.error || "Connecting securely and collecting the first readings…"
                    color: RemoteServer.error ? Theme.amber : Theme.textMid
                }
            }
            Column {
                width: parent.width
                spacing: 16
                visible: root.stats !== null
                opacity: RemoteServer.stale ? 0.6 : 1
                Row {
                    width: parent.width
                    spacing: 10
                    StatCard {
                        width: (parent.width - 10) / 2
                        title: "CPU"
                        value: root.stats ? Helpers.percent(root.stats.cpu) : "—"
                        detail: root.stats ? root.stats.meta.cores + " logical CPUs" : ""
                        points: RemoteServer.history.map(p => ({ at: p.at, value: p.cpu }))
                    }
                    StatCard {
                        width: (parent.width - 10) / 2
                        title: "MEMORY"
                        value: Helpers.percent(Helpers.memoryPercent(root.stats))
                        detail: root.stats ? Helpers.bytes(root.stats.memory.used) + " / " + Helpers.bytes(root.stats.memory.total) : ""
                        points: RemoteServer.history.map(p => ({ at: p.at, value: p.memory }))
                    }
                }
                Label {
                    width: parent.width
                    text: root.stats ? root.stats.meta.model : ""
                }
                // Per-core activity remains useful on large machines without
                // turning 64 logical CPUs into 64 rows.
                Flow {
                    width: parent.width
                    spacing: 3
                    Repeater {
                        model: root.stats ? root.stats.perCore : []
                        Rectangle {
                            required property var modelData
                            required property int index
                            width: 9; height: 12; radius: 2
                            color: Helpers.known(modelData)
                                ? Qt.alpha(Theme.accentText, 0.15 + 0.85 * modelData / 100) : Theme.hoverFill
                            Accessible.name: "CPU " + index + ": " + Helpers.percent(modelData)
                            HoverHandler { id: coreHover }
                            Controls.ToolTip.visible: coreHover.hovered
                            Controls.ToolTip.text: "CPU " + index + " · " + Helpers.percent(modelData)
                        }
                    }
                }
                Heading { text: "LOAD AVERAGE" }
                Row {
                    width: parent.width
                    Repeater {
                        model: ["1 minute", "5 minutes", "15 minutes"]
                        Column {
                            required property int index
                            required property string modelData
                            width: body.width / 3
                            spacing: 4
                            Label {
                                text: root.stats ? root.stats.load[parent.index].toFixed(2) : "—"
                                font.pixelSize: Theme.typography.heading
                                font.family: Theme.fontNumeric
                                color: Theme.textHi
                            }
                            Label { text: parent.modelData }
                        }
                    }
                }
                Label {
                    width: parent.width
                    text: root.stats ? Helpers.bytes(root.stats.memory.available) + " memory available · Swap "
                        + Helpers.bytes(root.stats.memory.swapUsed) + " / " + Helpers.bytes(root.stats.memory.swapTotal) : ""
                }
                HDivider { width: parent.width }
                Heading { text: "STORAGE" }
                Label {
                    width: parent.width
                    visible: root.stats !== null && (root.stats.storage.length === 0 || (!root.allDisks && !Helpers.disk(root.stats, RemoteServer.options.mount)))
                    text: root.stats ? root.stats.storageError || "Selected filesystem unavailable" : ""
                }
                Repeater {
                    model: root.stats ? (root.allDisks ? root.stats.storage : root.stats.storage.filter(d => d.mount === RemoteServer.options.mount).slice(0, 1)) : []
                    Column {
                        id: diskRow
                        required property var modelData
                        width: body.width
                        spacing: 7
                        Label {
                            width: parent.width
                            text: diskRow.modelData.mount + " · " + diskRow.modelData.percent + "% used"
                            color: Theme.textHi
                        }
                        Meter { width: parent.width; value: diskRow.modelData.percent }
                        Label {
                            width: parent.width
                            text: Helpers.bytes(diskRow.modelData.free) + " free of " + Helpers.bytes(diskRow.modelData.total)
                                + " · " + diskRow.modelData.type
                        }
                    }
                }
                ActionButton {
                    visible: root.stats !== null && root.stats.storage.length > 1
                    label: root.allDisks ? "Show fewer filesystems" : "All " + (root.stats ? root.stats.storage.length : 0) + " filesystems"
                    onTriggered: root.allDisks = !root.allDisks
                }
                HDivider { width: parent.width }
                Heading { text: "NETWORK" + (root.net ? " · " + root.net.name : "") }
                Row {
                    width: parent.width
                    spacing: 12
                    Repeater {
                        model: ["rx", "tx"]
                        Column {
                            id: networkRate
                            required property string modelData
                            width: (body.width - 12) / 2
                            spacing: 8
                            Label {
                                width: parent.width
                                text: (networkRate.modelData === "rx" ? "In  " : "Out  ")
                                    + Helpers.rate(root.net ? root.net[networkRate.modelData] : null)
                                font.pixelSize: Theme.typography.title
                                font.family: Theme.fontNumeric
                                color: Theme.textHi
                            }
                            Ui.TelemetryChart {
                                width: parent.width
                                ceiling: 0
                                tint: networkRate.modelData === "rx" ? Theme.accentText : Theme.textMid
                                description: networkRate.modelData === "rx" ? "Download history" : "Upload history"
                                points: RemoteServer.history.map(p => {
                                    const n = root.net ? p.network.find(v => v.name === root.net.name) : null;
                                    return { at: p.at, value: n ? n[networkRate.modelData] : null };
                                })
                            }
                        }
                    }
                }
                Label {
                    width: parent.width
                    text: root.net ? root.net.addresses.join(" · ") : "Selected interface unavailable"
                }
                Flow {
                    width: parent.width
                    spacing: 6
                    Repeater {
                        model: root.stats ? root.stats.network.filter(n => root.allInterfaces || (root.net && n.name === root.net.name)).slice(0, 256) : []
                        ActionButton {
                            required property var modelData
                            label: modelData.name
                            tint: root.net && root.net.name === modelData.name ? Theme.accentText : Theme.textDim
                            onTriggered: Settings.setModuleOption("remote", "interface", modelData.name)
                        }
                    }
                    ActionButton {
                        label: "Auto"
                        tint: RemoteServer.options.interface === "" ? Theme.accentText : Theme.textDim
                        onTriggered: Settings.setModuleOption("remote", "interface", "")
                    }
                }
                ActionButton {
                    visible: root.stats !== null && root.stats.network.length > 1
                    label: root.allInterfaces ? "Fewer interfaces" : "All interfaces"
                    onTriggered: root.allInterfaces = !root.allInterfaces
                }
                HDivider { width: parent.width }
                Heading { text: "TEMPERATURES" }
                Label {
                    text: "No temperature sensors available"
                    visible: root.stats !== null && root.stats.temperatures.length === 0
                }
                Flow {
                    width: parent.width
                    spacing: 8
                    Repeater {
                        model: root.stats ? (root.allTemperatures ? root.stats.temperatures : root.stats.temperatures.slice().sort((a, b) => b.celsius - a.celsius).slice(0, 2)) : []
                        Label {
                            required property var modelData
                            width: (body.width - 8) / 2
                            text: modelData.name + "  " + Math.round(modelData.celsius) + "°C"
                            color: modelData.celsius >= 85 ? Theme.amber : Theme.textMid
                        }
                    }
                }
                ActionButton {
                    visible: root.stats !== null && root.stats.temperatures.length > 2
                    label: root.allTemperatures ? "Fewer sensors" : "All sensors"
                    onTriggered: root.allTemperatures = !root.allTemperatures
                }
                Label {
                    width: parent.width
                    text: root.stats ? root.stats.meta.hostname + " · " + root.stats.meta.kernel : ""
                    color: Theme.textFaint
                }
            }
        }
    }
    Row {
        id: footer
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: root.gutter
        spacing: 8
        ActionButton { label: "Refresh"; enabled: RemoteServer.host !== ""; onTriggered: RemoteServer.refresh() }
        ActionButton { label: "Settings"; onTriggered: RemoteServer.configure() }
    }
}
