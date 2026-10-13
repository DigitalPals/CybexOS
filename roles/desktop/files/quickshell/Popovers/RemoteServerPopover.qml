pragma ComponentBehavior: Bound
import QtQuick
import "../Common"
import "../Ui" as Ui
import "../Common/Format.js" as Format
import "../Common/RemoteServerHelpers.js" as Helpers

// The server dashboard. A header says which machine and whether it is live;
// four reading tiles give the state at a glance and double as the tabs for
// the one detailed view beneath them; the network stays in view below that;
// and a one-line footer carries freshness and the two actions. The common
// case fits without scrolling. Expanded lists scroll inside the body while
// the header and footer stay put.
PopoutPanel {
    id: root

    readonly property var stats: RemoteServer.sample
    readonly property var net: RemoteServer.selectedNetwork
    readonly property var disk: Helpers.disk(stats, RemoteServer.options.mount)
    readonly property var hottest: Helpers.temperature(stats)
    readonly property bool configured: RemoteServer.host !== ""
    readonly property bool dimmed: RemoteServer.stale || RemoteServer.error !== ""
    readonly property int gutter: Theme.panelPadding
    readonly property int gap: Theme.scaled(12)
    readonly property int preferredWidth: Theme.scaled(472)

    // An explicit pick wins for as long as the panel exists; otherwise the
    // dashboard opens on whatever the menubar is summarising.
    property string picked: ""
    readonly property string view: picked || Helpers.viewFor(RemoteServer.options.metric)
    property bool allDisks: false
    property bool allSensors: false
    property bool pickingInterface: false
    property bool allInterfaces: false

    readonly property double span: Helpers.chartSpan(RemoteServer.history.length
        ? RemoteServer.now - RemoteServer.history[0].at : 0)
    readonly property string spanLabel: "last " + Math.round(span / 60000) + " min"
    readonly property var cpuPoints: RemoteServer.history.map(p => ({ at: p.at, value: p.cpu }))
    readonly property var memoryPoints: RemoteServer.history.map(p => ({ at: p.at, value: p.memory }))
    readonly property var temperaturePoints: RemoteServer.history.map(
        p => ({ at: p.at, value: p.temperature ?? null }))
    function ratePoints(key) {
        const name = root.net ? root.net.name : "";
        return RemoteServer.history.map(p => {
            const n = name ? p.network.find(v => v.name === name) : null;
            return { at: p.at, value: n ? n[key] : null };
        });
    }
    readonly property var rxPoints: ratePoints("rx")
    readonly property var txPoints: ratePoints("tx")

    implicitWidth: Math.min(preferredWidth, availableWidth > 0 ? availableWidth : preferredWidth)
    implicitHeight: Math.min(gutter * 2 + header.height + gap + body.implicitHeight + gap + footer.height,
        availableHeight > 0 ? availableHeight : 860)

    Claim {
        active: root.visible
        onClaimed: RemoteServer.acquire()
        onReleased: RemoteServer.release()
    }

    function tone(level) {
        return level === "critical" ? Theme.redText : level === "warn" ? Theme.amber : Theme.textHi;
    }
    function meterTone(level) {
        return level === "critical" ? Theme.red : level === "warn" ? Theme.amber : Theme.accent;
    }
    function reading(view) {
        const s = root.stats;
        let value = null;
        let unit = "%";
        let kind = "percent";
        if (view === "memory")
            value = Helpers.memoryPercent(s);
        else if (view === "storage")
            value = root.disk ? root.disk.percent : null;
        else if (view === "temperature") {
            value = root.hottest;
            unit = "°C";
            kind = "celsius";
        } else
            value = s ? s.cpu : null;
        const known = Helpers.known(value);
        return { number: known ? String(Math.round(value)) : "—", unit: known ? unit : "",
            fraction: known ? Format.clamp01(value / 100) : 0, level: Helpers.level(value, kind),
            text: known ? Math.round(value) + unit : "unavailable" };
    }
    function spread(points, unit) {
        const s = Helpers.summary(points);
        return s ? "avg " + Math.round(s.average) + unit + " · peak " + Math.round(s.peak) + unit : "";
    }

    Rectangle {
        anchors.fill: parent
        visible: root.drawBackground
        radius: Theme.panelRadius
        color: root.surfaceColor
        border.width: Theme.surfaceBorderWidth
        border.color: root.surfaceBorderColor
    }

    component Caption: Text {
        textFormat: Text.PlainText
        elide: Text.ElideRight
        font.family: Theme.fontMenu
        font.pixelSize: Theme.typography.metadata
        color: Theme.textDim
    }
    component Figure: Text {
        textFormat: Text.PlainText
        font.family: Theme.fontNumeric
        font.pixelSize: Theme.typography.secondary
        font.weight: Theme.weightSemibold
        font.features: Theme.tabularNumberFeatures
        color: Theme.textHi
    }

    // A reading, and the tab for its detail.
    component ReadingTile: Rectangle {
        id: tile

        required property var modelData
        readonly property string view: modelData.value
        readonly property var reading: root.reading(view)
        readonly property bool selected: root.view === view

        function pick() {
            root.picked = tile.view;
        }

        height: Theme.scaled(66)
        radius: Theme.chipRadius
        color: tile.selected || tileMouse.containsMouse ? Theme.chipHover : Theme.chip
        border.width: tile.selected || tile.activeFocus ? 1 : 0
        border.color: Qt.alpha(Theme.accentText, tile.activeFocus ? 1 : 0.5)
        activeFocusOnTab: true
        Accessible.role: Accessible.PageTab
        Accessible.name: tile.modelData.label
        Accessible.description: tile.reading.text + (tile.selected ? ", shown below" : "")
        Accessible.onPressAction: tile.pick()
        Keys.onPressed: event => {
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                    || event.key === Qt.Key_Space) {
                tile.pick();
                event.accepted = true;
            }
        }

        Behavior on color {
            ColorAnimation { duration: Theme.chipFadeDuration }
        }

        Text {
            id: tileLabel
            x: Theme.scaled(10)
            y: Theme.scaled(9)
            width: parent.width - x * 2
            elide: Text.ElideRight
            text: tile.modelData.label.toUpperCase()
            font.family: Theme.fontMenu
            font.pixelSize: Theme.typography.section
            font.weight: Theme.weightSemibold
            font.letterSpacing: 1
            color: tile.selected ? Theme.accentText : Theme.textFaint
        }
        Text {
            id: tileNumber
            anchors.left: tileLabel.left
            anchors.top: tileLabel.bottom
            anchors.topMargin: Theme.scaled(2)
            text: tile.reading.number
            font.family: Theme.fontNumeric
            font.pixelSize: Theme.typography.title
            font.weight: Theme.weightSemibold
            font.features: Theme.tabularNumberFeatures
            color: root.tone(tile.reading.level)
        }
        Text {
            anchors.left: tileNumber.right
            anchors.leftMargin: 1
            anchors.baseline: tileNumber.baseline
            text: tile.reading.unit
            font.family: Theme.fontNumeric
            font.pixelSize: Theme.typography.metadata
            font.weight: Theme.weightMedium
            color: Theme.textLow
        }
        BlockMeter {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.margins: Theme.scaled(10)
            height: 5
            blockWidth: 3
            gap: 2
            value: tile.reading.fraction
            fillColor: root.meterTone(tile.reading.level)
        }
        MouseArea {
            id: tileMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: tile.pick()
        }
    }

    // A run of labelled figures on one recessed strip.
    component FactStrip: Rectangle {
        id: strip

        property var facts: []

        width: parent ? parent.width : 0
        height: Theme.scaled(46)
        radius: Theme.chipRadius
        color: Theme.chip

        Repeater {
            model: strip.facts

            Item {
                id: fact

                required property var modelData
                required property int index
                readonly property real cell: strip.width / Math.max(1, strip.facts.length)

                x: fact.index * fact.cell
                width: fact.cell
                height: strip.height
                Accessible.role: Accessible.StaticText
                Accessible.name: fact.modelData.label
                Accessible.description: fact.modelData.value
                    + (fact.modelData.detail ? ", " + fact.modelData.detail : "")

                Rectangle {
                    visible: fact.index > 0
                    anchors.verticalCenter: parent.verticalCenter
                    width: 1
                    height: parent.height - Theme.scaled(18)
                    color: Theme.hairlineSoft
                }
                Caption {
                    id: factLabel
                    x: Theme.scaled(10)
                    y: Theme.scaled(7)
                    width: parent.width - x * 2
                    text: fact.modelData.label
                }
                Figure {
                    anchors.left: factLabel.left
                    anchors.top: factLabel.bottom
                    anchors.topMargin: 1
                    width: factLabel.width
                    elide: Text.ElideRight
                    text: fact.modelData.value
                    color: root.tone(fact.modelData.level || "ok")
                }
            }
        }
    }

    // A chart with its title and summary on one line above it.
    component History: Column {
        id: history

        property string title: ""
        property string summary: ""
        property var series: []
        property real ceiling: 100
        property string ceilingLabel: ""
        property real chartHeight: Theme.scaled(84)

        width: parent ? parent.width : 0
        spacing: Theme.scaled(6)

        Item {
            width: parent.width
            height: historyTitle.implicitHeight

            Text {
                id: historyTitle
                width: Math.min(implicitWidth, parent.width - historySummary.implicitWidth
                    - historySpan.implicitWidth - 20)
                elide: Text.ElideRight
                text: history.title
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.secondary
                font.weight: Theme.weightSemibold
                color: Theme.textMid
            }
            Caption {
                id: historySpan
                anchors.left: historyTitle.right
                anchors.leftMargin: Theme.scaled(8)
                anchors.baseline: historyTitle.baseline
                text: root.spanLabel
                color: Theme.textFaint
            }
            Caption {
                id: historySummary
                anchors.right: parent.right
                anchors.baseline: historyTitle.baseline
                text: history.summary
                font.features: Theme.tabularNumberFeatures
            }
        }
        Item {
            width: parent.width
            height: history.chartHeight

            Ui.TelemetryChart {
                anchors.fill: parent
                series: history.series
                ceiling: history.ceiling
                span: root.span
                now: RemoteServer.now
                description: history.title + ", " + root.spanLabel
            }
            Caption {
                visible: history.ceilingLabel !== ""
                x: 4
                y: 3
                text: history.ceilingLabel
                color: Theme.textFaint
            }
            Caption {
                visible: !history.series.some(s => s.points.some(p => Helpers.known(p.value)))
                anchors.centerIn: parent
                text: RemoteServer.connection === "connecting" ? "Collecting readings…" : "No history yet"
                color: Theme.textFaint
            }
        }
    }

    // A pressable row inside an expanded list.
    component ListRow: Rectangle {
        id: row

        property string accessibleName: ""
        signal activated()

        width: parent ? parent.width : 0
        radius: Theme.chipRadius
        color: rowMouse.containsMouse || row.activeFocus ? Theme.hoverFill : "transparent"
        border.width: row.activeFocus ? 1 : 0
        border.color: Theme.accentText
        activeFocusOnTab: true
        Accessible.role: Accessible.Button
        Accessible.name: row.accessibleName
        Accessible.onPressAction: row.activated()
        Keys.onPressed: event => {
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                    || event.key === Qt.Key_Space) {
                row.activated();
                event.accepted = true;
            }
        }

        MouseArea {
            id: rowMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: row.activated()
        }
    }

    // ---- header ----------------------------------------------------------
    Item {
        id: header

        x: root.gutter
        y: root.gutter
        width: root.width - root.gutter * 2
        height: Theme.scaled(42)

        Rectangle {
            id: mark
            anchors.verticalCenter: parent.verticalCenter
            width: Theme.scaled(38)
            height: width
            radius: Theme.chipRadius
            color: Theme.chip

            Sym {
                anchors.centerIn: parent
                name: "dns"
                size: Theme.iconLarge
                color: root.configured ? Theme.accentText : Theme.textDim
            }
        }
        Column {
            anchors.left: mark.right
            anchors.leftMargin: Theme.scaled(12)
            anchors.right: pill.left
            anchors.rightMargin: Theme.scaled(10)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.scaled(2)

            Text {
                width: parent.width
                elide: Text.ElideRight
                textFormat: Text.PlainText
                text: root.configured ? RemoteServer.label : "Remote Server"
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.title
                font.weight: Theme.weightSemibold
                color: Theme.textHi
            }
            Text {
                width: parent.width
                elide: Text.ElideRight
                textFormat: Text.PlainText
                text: {
                    if (!root.configured)
                        return "Monitor a Linux machine over SSH";
                    const who = RemoteServer.label !== RemoteServer.host ? RemoteServer.host
                        : root.stats ? root.stats.meta.hostname : "";
                    return [who, root.stats ? "up " + Helpers.uptime(root.stats.uptime) : ""]
                        .filter(part => part !== "").join(" · ");
                }
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.secondary
                color: Theme.textLow
            }
        }
        Rectangle {
            id: pill

            readonly property string connection: RemoteServer.connection
            readonly property color tint: connection === "live" ? Theme.ok
                : connection === "offline" ? Theme.redText
                : connection === "stale" ? Theme.amber : Theme.textDim

            visible: root.configured
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: pillRow.implicitWidth + Theme.scaled(18)
            height: Theme.scaled(24)
            radius: height / 2
            color: connection === "live" ? Theme.okBgSoft
                : connection === "offline" ? Theme.redBgSoft
                : connection === "stale" ? Theme.amberBgSoft : Theme.chip
            Accessible.role: Accessible.StaticText
            Accessible.name: "Connection"
            Accessible.description: RemoteServer.status

            Row {
                id: pillRow
                anchors.centerIn: parent
                spacing: Theme.scaled(6)

                Rectangle {
                    id: pillDot
                    anchors.verticalCenter: parent.verticalCenter
                    width: 6
                    height: 6
                    radius: 3
                    color: pill.tint

                    SequentialAnimation on opacity {
                        running: pill.connection === "connecting" && !Theme.reducedMotion
                        loops: Animation.Infinite
                        onRunningChanged: if (!running) pillDot.opacity = 1
                        NumberAnimation { from: 1; to: 0.3; duration: 700; easing.type: Easing.InOutSine }
                        NumberAnimation { from: 0.3; to: 1; duration: 700; easing.type: Easing.InOutSine }
                    }
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: ({ live: "Live", offline: "Offline", stale: "Stale",
                        connecting: "Connecting" })[pill.connection] || ""
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.metadata
                    font.weight: Theme.weightSemibold
                    color: pill.tint
                }
            }
        }
    }

    // ---- body ------------------------------------------------------------
    Flickable {
        id: scroll

        x: root.gutter
        y: header.y + header.height + root.gap
        width: header.width
        height: footer.y - root.gap - y
        contentWidth: width
        contentHeight: body.implicitHeight
        boundsBehavior: Flickable.StopAtBounds
        clip: true

        Column {
            id: body

            width: scroll.width
            spacing: Theme.panelSectionSpacing

            // Nothing to monitor yet.
            Column {
                visible: !root.configured
                width: parent.width
                topPadding: Theme.scaled(10)
                bottomPadding: Theme.scaled(6)
                spacing: Theme.scaled(10)

                Text {
                    width: parent.width
                    wrapMode: Text.Wrap
                    horizontalAlignment: Text.AlignHCenter
                    textFormat: Text.PlainText
                    text: "Choose a server you can already reach with an SSH key. Nothing is installed or written on it; it needs Linux and Python 3.9 or newer."
                    lineHeight: Theme.proseLineHeight
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.secondary
                    color: Theme.textLow
                }
                ActionButton {
                    anchors.horizontalCenter: parent.horizontalCenter
                    label: "Choose SSH host"
                    tint: Theme.accentText
                    onTriggered: RemoteServer.configure()
                }
            }

            // Why the readings are missing or old. Offline is red wherever it
            // shows — here, the status pill and the menubar badge.
            Rectangle {
                visible: RemoteServer.error !== ""
                width: parent.width
                height: problem.implicitHeight + Theme.scaled(22)
                radius: Theme.chipRadius
                color: Theme.redBgSoft
                border.width: 1
                border.color: Theme.redBorder

                Sym {
                    x: Theme.scaled(12)
                    y: Theme.scaled(12)
                    name: "error"
                    size: Theme.iconMedium
                    color: Theme.redText
                }
                Column {
                    id: problem
                    x: Theme.scaled(38)
                    y: Theme.scaled(11)
                    width: parent.width - x - retry.width - Theme.scaled(22)
                    spacing: Theme.scaled(3)

                    Text {
                        width: parent.width
                        wrapMode: Text.Wrap
                        textFormat: Text.PlainText
                        text: root.stats ? "Connection lost · showing the last readings"
                            : "Can't reach " + RemoteServer.label
                        font.family: Theme.fontMenu
                        font.pixelSize: Theme.typography.secondary
                        font.weight: Theme.weightSemibold
                        color: Theme.redText
                    }
                    Text {
                        width: parent.width
                        wrapMode: Text.Wrap
                        textFormat: Text.PlainText
                        text: RemoteServer.error
                        font.family: Theme.fontMenu
                        font.pixelSize: Theme.typography.metadata
                        color: Theme.textMid
                    }
                }
                ActionButton {
                    id: retry
                    anchors.right: parent.right
                    anchors.rightMargin: Theme.scaled(10)
                    anchors.verticalCenter: parent.verticalCenter
                    label: "Retry"
                    tint: Theme.redText
                    onTriggered: RemoteServer.refresh()
                }
            }

            Rectangle {
                visible: RemoteServer.connection === "connecting"
                width: parent.width
                height: Theme.scaled(64)
                radius: Theme.chipRadius
                color: Theme.chip

                Caption {
                    anchors.centerIn: parent
                    width: Math.min(implicitWidth, parent.width - Theme.scaled(24))
                    text: "Connecting securely and collecting the first readings…"
                    color: Theme.textLow
                }
            }

            Column {
                visible: root.stats !== null
                width: parent.width
                spacing: Theme.panelSectionSpacing
                opacity: root.dimmed ? 0.6 : 1

                Behavior on opacity {
                    NumberAnimation { duration: Theme.chipFadeDuration }
                }

                Row {
                    id: tiles
                    width: parent.width
                    spacing: Theme.scaled(8)

                    Repeater {
                        model: Helpers.VIEWS
                        ReadingTile {
                            width: (tiles.width - tiles.spacing * (Helpers.VIEWS.length - 1))
                                / Helpers.VIEWS.length
                        }
                    }
                }

                // ---- CPU ----
                Column {
                    visible: root.view === "cpu"
                    width: parent.width
                    spacing: Theme.scaled(10)

                    History {
                        title: "CPU usage"
                        summary: root.spread(root.cpuPoints, "%")
                        series: [{ points: root.cpuPoints, tint: Theme.accentText }]
                    }
                    // Every logical CPU as one bar, wrapping only on very
                    // large machines, so 64 threads read as one texture.
                    Item {
                        id: cores

                        readonly property var values: root.stats ? root.stats.perCore : []
                        readonly property int count: values.length
                        readonly property real pitchGap: count > 96 ? 1 : 2
                        readonly property int perRow: Math.max(1, Math.min(count,
                            Math.floor((width + pitchGap) / (3 + pitchGap))))
                        readonly property int rows: Math.ceil(count / perRow)
                        readonly property real cell: (width - pitchGap * (perRow - 1)) / perRow
                        readonly property real rowHeight: rows > 1 ? Theme.scaled(14) : Theme.scaled(22)
                        property int hovered: -1

                        visible: count > 0
                        width: parent.width
                        height: count > 0 ? rows * rowHeight + (rows - 1) * 3 : 0
                        Accessible.role: Accessible.Chart
                        Accessible.name: "Per-CPU activity"
                        Accessible.description: count + " logical CPUs"

                        Repeater {
                            model: cores.values

                            Rectangle {
                                id: core

                                required property var modelData
                                required property int index
                                readonly property string level: Helpers.level(core.modelData)

                                x: (core.index % cores.perRow) * (cores.cell + cores.pitchGap)
                                y: Math.floor(core.index / cores.perRow) * (cores.rowHeight + 3)
                                width: cores.cell
                                height: cores.rowHeight
                                radius: Math.min(1.5, width / 2)
                                color: cores.hovered === core.index ? Theme.chip : Theme.hairlineSoft

                                Rectangle {
                                    anchors.bottom: parent.bottom
                                    width: parent.width
                                    height: Helpers.known(core.modelData)
                                        ? Math.max(1.5, parent.height * Format.clamp01(core.modelData / 100)) : 0
                                    radius: parent.radius
                                    color: root.meterTone(core.level)
                                }
                            }
                        }
                        MouseArea {
                            anchors.fill: parent
                            hoverEnabled: true
                            acceptedButtons: Qt.NoButton
                            onPositionChanged: mouse => {
                                const column = Math.floor(mouse.x / (cores.cell + cores.pitchGap));
                                const line = Math.floor(mouse.y / (cores.rowHeight + 3));
                                const index = line * cores.perRow + Math.min(cores.perRow - 1, column);
                                cores.hovered = index >= 0 && index < cores.count ? index : -1;
                            }
                            onExited: cores.hovered = -1
                        }
                    }
                    Item {
                        width: parent.width
                        height: coreModel.implicitHeight

                        Caption {
                            id: coreModel
                            width: parent.width - coreReading.implicitWidth - 12
                            text: root.stats ? [root.stats.meta.cores + " threads", root.stats.meta.model]
                                .filter(part => part).join(" · ") : ""
                        }
                        Caption {
                            id: coreReading
                            anchors.right: parent.right
                            text: cores.hovered >= 0
                                ? "CPU " + cores.hovered + " · " + Helpers.percent(cores.values[cores.hovered]) : ""
                            color: Theme.textMid
                            font.features: Theme.tabularNumberFeatures
                        }
                    }
                    FactStrip {
                        readonly property var perThread: root.stats && root.stats.meta.cores > 0
                            ? 100 * root.stats.load[0] / root.stats.meta.cores : null
                        facts: root.stats ? [
                            { label: "Load 1 min", value: root.stats.load[0].toFixed(2),
                                level: Helpers.level(perThread) },
                            { label: "5 min", value: root.stats.load[1].toFixed(2) },
                            { label: "15 min", value: root.stats.load[2].toFixed(2) },
                            { label: "Per thread", value: Helpers.known(perThread)
                                ? (perThread / 100).toFixed(2) : "—" }
                        ] : []
                    }
                }

                // ---- memory ----
                Column {
                    visible: root.view === "memory"
                    width: parent.width
                    spacing: Theme.scaled(10)

                    History {
                        title: "Memory in use"
                        summary: root.spread(root.memoryPoints, "%")
                        series: [{ points: root.memoryPoints, tint: Theme.accentText }]
                    }
                    FactStrip {
                        readonly property var memory: root.stats ? root.stats.memory : null
                        readonly property var swapPercent: memory && memory.swapTotal > 0
                            ? 100 * memory.swapUsed / memory.swapTotal : null
                        facts: memory ? [
                            { label: "Used", value: Helpers.bytes(memory.used) },
                            { label: "Available", value: Helpers.bytes(memory.available) },
                            { label: "Total", value: Helpers.bytes(memory.total) },
                            { label: "Swap used",
                                value: memory.swapTotal > 0 ? Helpers.percent(swapPercent) : "Off",
                                level: Helpers.level(swapPercent),
                                detail: Helpers.bytes(memory.swapUsed) + " of " + Helpers.bytes(memory.swapTotal) }
                        ] : []
                    }
                }

                // ---- storage ----
                Column {
                    id: storage

                    readonly property var rows: Helpers.storageRows(root.stats, RemoteServer.options.mount)

                    visible: root.view === "storage"
                    width: parent.width
                    spacing: Theme.scaled(4)

                    Item {
                        width: parent.width
                        height: storageTitle.implicitHeight + Theme.scaled(4)

                        Text {
                            id: storageTitle
                            text: "Filesystems"
                            font.family: Theme.fontMenu
                            font.pixelSize: Theme.typography.secondary
                            font.weight: Theme.weightSemibold
                            color: Theme.textMid
                        }
                        Caption {
                            anchors.right: parent.right
                            anchors.baseline: storageTitle.baseline
                            text: "Select one for the Storage tile"
                            color: Theme.textFaint
                        }
                    }
                    Caption {
                        visible: root.stats !== null && storage.rows.length === 0
                        width: parent.width
                        text: root.stats ? root.stats.storageError || "No local filesystems reported" : ""
                    }
                    Repeater {
                        model: root.allDisks ? storage.rows : storage.rows.slice(0, 4)

                        ListRow {
                            id: diskRow

                            required property var modelData
                            readonly property bool chosen: modelData.mount === RemoteServer.options.mount
                            readonly property string level: Helpers.level(modelData.percent)

                            height: Theme.scaled(48)
                            accessibleName: modelData.mount + ", " + modelData.percent + "% used, "
                                + Helpers.bytes(modelData.free) + " free"
                                + (chosen ? ", shown in the Storage tile" : "")
                            onActivated: Settings.setModuleOption("remote", "mount", diskRow.modelData.mount)

                            Text {
                                id: mountName
                                x: Theme.scaled(8)
                                y: Theme.scaled(7)
                                width: Math.min(implicitWidth, parent.width * 0.45)
                                elide: Text.ElideMiddle
                                textFormat: Text.PlainText
                                text: diskRow.modelData.mount
                                font.family: Theme.fontMenu
                                font.pixelSize: Theme.typography.primary
                                font.weight: Theme.weightMedium
                                color: diskRow.chosen ? Theme.accentText : Theme.textHi
                            }
                            Caption {
                                anchors.left: mountName.right
                                anchors.leftMargin: Theme.scaled(8)
                                anchors.right: diskFree.left
                                anchors.rightMargin: Theme.scaled(8)
                                anchors.baseline: mountName.baseline
                                text: diskRow.modelData.type
                                color: Theme.textFaint
                            }
                            Caption {
                                id: diskFree
                                anchors.right: diskPercent.left
                                anchors.rightMargin: Theme.scaled(8)
                                anchors.baseline: mountName.baseline
                                text: Helpers.bytes(diskRow.modelData.free) + " free of "
                                    + Helpers.bytes(diskRow.modelData.total)
                                font.features: Theme.tabularNumberFeatures
                            }
                            Figure {
                                id: diskPercent
                                anchors.right: parent.right
                                anchors.rightMargin: Theme.scaled(8)
                                anchors.baseline: mountName.baseline
                                text: diskRow.modelData.percent + "%"
                                color: root.tone(diskRow.level)
                            }
                            BlockMeter {
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.bottom: parent.bottom
                                anchors.leftMargin: Theme.scaled(8)
                                anchors.rightMargin: Theme.scaled(8)
                                anchors.bottomMargin: Theme.scaled(9)
                                height: 5
                                blockWidth: 3
                                gap: 2
                                value: diskRow.modelData.percent / 100
                                fillColor: root.meterTone(diskRow.level)
                            }
                        }
                    }
                    LinkText {
                        visible: storage.rows.length > 4
                        x: Theme.scaled(8)
                        text: root.allDisks ? "Show fewer" : "Show all " + storage.rows.length + " filesystems"
                        onClicked: root.allDisks = !root.allDisks
                    }
                }

                // ---- temperature ----
                Column {
                    id: thermal

                    readonly property var sensors: Helpers.sensorRows(root.stats)

                    visible: root.view === "temperature"
                    width: parent.width
                    spacing: Theme.scaled(10)

                    History {
                        title: "Hottest sensor"
                        summary: root.spread(root.temperaturePoints, "°C")
                        series: [{ points: root.temperaturePoints, tint: Theme.accentText }]
                    }
                    Caption {
                        visible: root.stats !== null && thermal.sensors.length === 0
                        width: parent.width
                        text: "This server reports no temperature sensors."
                    }
                    Grid {
                        width: parent.width
                        columns: 2
                        columnSpacing: Theme.scaled(16)

                        Repeater {
                            model: root.allSensors ? thermal.sensors : thermal.sensors.slice(0, 6)

                            Item {
                                id: sensor

                                required property var modelData

                                width: (thermal.width - Theme.scaled(16)) / 2
                                height: Theme.scaled(26)
                                Accessible.role: Accessible.StaticText
                                Accessible.name: sensor.modelData.name
                                Accessible.description: Math.round(sensor.modelData.celsius) + " °C"

                                Text {
                                    anchors.left: parent.left
                                    anchors.right: sensorValue.left
                                    anchors.rightMargin: Theme.scaled(8)
                                    anchors.verticalCenter: parent.verticalCenter
                                    elide: Text.ElideRight
                                    textFormat: Text.PlainText
                                    text: sensor.modelData.name
                                    font.family: Theme.fontMenu
                                    font.pixelSize: Theme.typography.secondary
                                    color: Theme.textMid
                                }
                                Figure {
                                    id: sensorValue
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: Math.round(sensor.modelData.celsius) + "°C"
                                    color: root.tone(Helpers.level(sensor.modelData.celsius, "celsius"))
                                }
                                Rectangle {
                                    anchors.bottom: parent.bottom
                                    width: parent.width
                                    height: 1
                                    color: Theme.hairlineSoft
                                }
                            }
                        }
                    }
                    LinkText {
                        visible: thermal.sensors.length > 6
                        text: root.allSensors ? "Show fewer" : "Show all " + thermal.sensors.length + " sensors"
                        onClicked: root.allSensors = !root.allSensors
                    }
                }

                // ---- network ----
                Column {
                    id: network

                    readonly property var choices: {
                        const rows = Helpers.interfaceRows(root.stats);
                        return root.allInterfaces ? rows
                            : rows.filter(n => n.addresses.length > 0 || (n.rx || 0) + (n.tx || 0) > 0
                                || n.name === RemoteServer.options.interface);
                    }
                    readonly property real ceiling: {
                        const rx = Helpers.summary(root.rxPoints);
                        const tx = Helpers.summary(root.txPoints);
                        return Helpers.chartCeiling(Math.max(rx ? rx.peak : 0, tx ? tx.peak : 0));
                    }

                    width: parent.width
                    spacing: Theme.scaled(8)

                    Item {
                        width: parent.width
                        height: networkLabel.height

                        SectionLabel {
                            id: networkLabel
                            width: parent.width - (pickLink.visible ? pickLink.width + Theme.scaled(10) : 0)
                            text: "NETWORK"
                            detail: root.net ? root.net.name
                                + (RemoteServer.options.interface === "" ? " · automatic" : "") : ""
                        }
                        LinkText {
                            id: pickLink
                            visible: root.stats !== null && root.stats.network.length > 1
                            anchors.right: parent.right
                            anchors.verticalCenter: networkLabel.verticalCenter
                            font.pixelSize: Theme.typography.secondary
                            text: root.pickingInterface ? "Done" : "Change"
                            accessibleName: root.pickingInterface ? "Close interface list" : "Choose network interface"
                            onClicked: root.pickingInterface = !root.pickingInterface
                        }
                    }

                    Row {
                        width: parent.width

                        Repeater {
                            model: [
                                { key: "rx", label: "in", tint: Theme.accentText, glyph: "arrow_downward" },
                                { key: "tx", label: "out", tint: Theme.textMid, glyph: "arrow_upward" }
                            ]

                            Row {
                                id: rate

                                required property var modelData

                                width: network.width / 2
                                spacing: Theme.scaled(6)
                                Accessible.role: Accessible.StaticText
                                Accessible.name: rate.modelData.key === "rx" ? "Download" : "Upload"
                                Accessible.description: rateValue.text

                                Sym {
                                    anchors.verticalCenter: parent.verticalCenter
                                    name: rate.modelData.glyph
                                    size: Theme.iconMedium
                                    color: rate.modelData.tint
                                }
                                Text {
                                    id: rateValue
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: Helpers.rate(root.net ? root.net[rate.modelData.key] : null)
                                    font.family: Theme.fontNumeric
                                    font.pixelSize: Theme.typography.title
                                    font.weight: Theme.weightSemibold
                                    font.features: Theme.tabularNumberFeatures
                                    color: Theme.textHi
                                }
                                Caption {
                                    anchors.baseline: rateValue.baseline
                                    text: rate.modelData.label
                                }
                            }
                        }
                    }

                    Item {
                        width: parent.width
                        height: Theme.scaled(54)

                        Ui.TelemetryChart {
                            anchors.fill: parent
                            ceiling: network.ceiling
                            span: root.span
                            now: RemoteServer.now
                            description: "Network traffic, " + root.spanLabel
                            series: [
                                { points: root.txPoints, tint: Theme.textMid },
                                { points: root.rxPoints, tint: Theme.accentText }
                            ]
                        }
                        Caption {
                            x: 4
                            y: 3
                            text: Helpers.bytes(network.ceiling) + "/s"
                            color: Theme.textFaint
                        }
                    }

                    Caption {
                        visible: text !== ""
                        width: parent.width
                        text: root.net ? root.net.addresses.join(" · ")
                            : root.stats ? "Interface " + RemoteServer.options.interface + " is not present" : ""
                    }

                    // The interface list, opened from the section's link.
                    Column {
                        visible: root.pickingInterface
                        width: parent.width
                        spacing: 0

                        Repeater {
                            model: [{ name: "", addresses: [], rx: null, tx: null }].concat(network.choices)

                            ListRow {
                                id: choice

                                required property var modelData
                                readonly property bool automatic: modelData.name === ""
                                readonly property bool chosen: modelData.name === RemoteServer.options.interface

                                height: Theme.listRowHeight
                                accessibleName: choice.automatic ? "Automatic interface" : choice.modelData.name
                                onActivated: {
                                    Settings.setModuleOption("remote", "interface", choice.modelData.name);
                                    root.pickingInterface = false;
                                }

                                Sym {
                                    id: choiceCheck
                                    x: Theme.scaled(8)
                                    anchors.verticalCenter: parent.verticalCenter
                                    name: "check"
                                    size: Theme.iconSmall
                                    color: Theme.accentText
                                    opacity: choice.chosen ? 1 : 0
                                }
                                Text {
                                    id: choiceName
                                    anchors.left: choiceCheck.right
                                    anchors.leftMargin: Theme.scaled(8)
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: Math.min(implicitWidth, parent.width * 0.4)
                                    elide: Text.ElideRight
                                    textFormat: Text.PlainText
                                    text: choice.automatic ? "Automatic" : choice.modelData.name
                                    font.family: Theme.fontMenu
                                    font.pixelSize: Theme.typography.primary
                                    font.weight: choice.chosen ? Theme.weightSemibold : Theme.weightMedium
                                    color: choice.chosen ? Theme.accentText : Theme.textHi
                                }
                                Caption {
                                    anchors.left: choiceName.right
                                    anchors.leftMargin: Theme.scaled(8)
                                    anchors.right: choiceRate.left
                                    anchors.rightMargin: Theme.scaled(8)
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: choice.automatic
                                        ? "default route" + (root.stats && root.stats.meta.defaultInterface
                                            ? " · " + root.stats.meta.defaultInterface : "")
                                        : choice.modelData.addresses[0] || ""
                                }
                                Row {
                                    id: choiceRate
                                    anchors.right: parent.right
                                    anchors.rightMargin: Theme.scaled(8)
                                    anchors.verticalCenter: parent.verticalCenter
                                    visible: !choice.automatic
                                    spacing: Theme.scaled(3)

                                    Sym {
                                        anchors.verticalCenter: parent.verticalCenter
                                        name: "arrow_downward"
                                        size: Theme.iconTiny
                                        color: Theme.textDim
                                    }
                                    Caption {
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: implicitWidth + Theme.scaled(8)
                                        text: Helpers.compactRate(choice.modelData.rx)
                                        font.features: Theme.tabularNumberFeatures
                                    }
                                    Sym {
                                        anchors.verticalCenter: parent.verticalCenter
                                        name: "arrow_upward"
                                        size: Theme.iconTiny
                                        color: Theme.textDim
                                    }
                                    Caption {
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: Helpers.compactRate(choice.modelData.tx)
                                        font.features: Theme.tabularNumberFeatures
                                    }
                                }
                            }
                        }
                        LinkText {
                            visible: root.stats !== null && root.stats.network.length > network.choices.length
                                || root.allInterfaces
                            x: Theme.scaled(8)
                            topPadding: Theme.scaled(6)
                            text: root.allInterfaces ? "Hide idle interfaces"
                                : "Show all " + (root.stats ? root.stats.network.length : 0) + " interfaces"
                            onClicked: root.allInterfaces = !root.allInterfaces
                        }
                    }
                }

                Caption {
                    visible: root.stats !== null
                    width: parent.width
                    text: root.stats ? [root.stats.meta.os, "Linux " + root.stats.meta.kernel,
                        root.stats.meta.hostname].join(" · ") : ""
                    color: Theme.textFaint
                }
            }
        }
    }
    ScrollChrome {
        x: scroll.x
        y: scroll.y
        width: scroll.width
        height: scroll.height
        target: scroll
        edgeColor: root.surfaceColor
    }

    // ---- footer ----------------------------------------------------------
    Item {
        id: footer

        x: root.gutter
        y: root.height - root.gutter - height
        width: header.width
        height: Theme.panelFooterHeight

        Rectangle {
            width: parent.width
            height: 1
            color: Theme.hairlineSoft
        }
        Caption {
            anchors.left: parent.left
            anchors.leftMargin: 2
            anchors.right: actions.left
            anchors.rightMargin: Theme.scaled(10)
            anchors.verticalCenter: parent.verticalCenter
            anchors.verticalCenterOffset: 1
            text: {
                switch (RemoteServer.connection) {
                case "setup": return "Nothing to monitor yet";
                case "connecting": return "Connecting to " + RemoteServer.host + "…";
                case "live": return "Updated " + RemoteServer.age + " · every " + RemoteServer.cadence + " s";
                default: return root.stats ? "Last reading " + RemoteServer.age : "Retrying automatically";
                }
            }
            color: Theme.textFaint
        }
        Row {
            id: actions
            anchors.right: parent.right
            anchors.rightMargin: 2
            anchors.verticalCenter: parent.verticalCenter
            anchors.verticalCenterOffset: 1
            spacing: Theme.scaled(16)

            LinkText {
                visible: root.configured
                text: "Refresh"
                accessibleName: "Refresh server readings"
                onClicked: RemoteServer.refresh()
            }
            LinkText {
                text: "Settings"
                accessibleName: "Remote Server settings"
                onClicked: RemoteServer.configure()
            }
        }
    }
}
