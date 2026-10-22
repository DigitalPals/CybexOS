pragma ComponentBehavior: Bound
import QtQuick
import "../Common"
import "../Common/FuseboxHelpers.js" as Helpers

// The Fusebox dashboard, read like the fusebox it is named after. The header
// says whether the main line is live. Anything that has tripped comes first,
// with when it comes back; then the hour of load, every account as a circuit
// with its quota meters and breaker, and the latest requests. Removing
// accounts, signing in and spending banked resets stay in Fusebox's own
// dashboard, one click away.
PopoutPanel {
    id: root

    readonly property bool configured: Fusebox.connection !== "setup"
    readonly property bool dimmed: Fusebox.stale && Fusebox.longDown
    readonly property double now: Fusebox.now
    // Accounts by provider; recomputed when the accounts change, not by the clock.
    readonly property var groups: Helpers.accountGroups(Fusebox.accounts)
    readonly property var latest: Fusebox.requests.slice(0, 5)
    readonly property var loadBars: Helpers.bars(Fusebox.series, now)
    readonly property int loadPeak: Math.max(4, ...loadBars.map(b => b.requests))
    readonly property int loadTotal: loadBars.reduce((sum, b) => sum + b.requests, 0)
    readonly property var pools: Helpers.weeklyPools(Fusebox.accounts, now)
    readonly property var connected: Helpers.connectedRows(Fusebox.clients, Fusebox.hideEmails)
    readonly property var budgets: Helpers.budgets(Fusebox.clients, Fusebox.hideEmails)
    readonly property var priorityOptions: [
        { value: 10, label: "First", description: "Take new sessions first" },
        { value: 0, label: "Normal", description: "Take new sessions by the routing strategy" },
        { value: -10, label: "Last", description: "Take new sessions only when no other account can" }
    ]
    readonly property var loadFigures: [
        { value: String(Fusebox.figures.serving), label: "in progress" },
        { value: String(Fusebox.figures.rpm), label: "req/min" },
        { value: String(Fusebox.figures.failed), label: "failed", level: Fusebox.figures.failed > 0 ? "critical" : "ok" },
        { value: Helpers.seconds(Fusebox.figures.ttft), label: "first token" }
    ]
    readonly property int gutter: Theme.panelPadding
    // One grid for every row: content starts at `pad`, names and text at
    // `textX` after the icon column, and right-hand values end at `pad` from
    // the right edge. Meters split the text column in two.
    readonly property int pad: Theme.scaled(10)
    readonly property int textX: pad + Theme.iconMedium + Theme.scaled(8)
    readonly property int meterGap: Theme.scaled(16)
    readonly property int lineHeight: Theme.scaled(30)
    readonly property int gap: Theme.scaled(12)
    readonly property int preferredWidth: Theme.scaled(472)
    // The account whose details are open, and one awaiting a second click to
    // switch off: turning a circuit off moves its traffic elsewhere.
    property string expanded: ""
    property string confirmOff: ""

    implicitWidth: Math.min(preferredWidth, availableWidth > 0 ? availableWidth : preferredWidth)
    implicitHeight: Math.min(gutter * 2 + header.height + gap + body.implicitHeight + gap + footer.height,
        availableHeight > 0 ? availableHeight : 860)

    Claim {
        active: root.visible
        onClaimed: Fusebox.acquire()
        onReleased: Fusebox.release()
    }

    function tone(level) {
        return level === "critical" ? Theme.redText : level === "warn" ? Theme.amber
            : level === "idle" ? Theme.textDim : Theme.textHi;
    }
    function meterTone(level) {
        return level === "critical" ? Theme.red : level === "warn" ? Theme.amber : Theme.accent;
    }
    function statusTone(state) {
        return state.cls === "serving" || state.cls === "ready" ? Theme.ok : root.tone(state.level);
    }
    function toggle(id) {
        root.confirmOff = "";
        root.expanded = root.expanded === id ? "" : id;
        if (root.expanded !== "")
            Fusebox.loadActivity(id);
    }

    Rectangle {
        anchors.fill: parent
        visible: root.drawBackground
        radius: Theme.panelRadius
        color: root.surfaceColor
        border.width: Theme.surfaceBorderWidth
        border.color: root.surfaceBorderColor
    }

    Timer {
        // A turn-off confirmation lapses rather than lingering armed.
        interval: 4000
        running: root.confirmOff !== ""
        onTriggered: root.confirmOff = ""
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
    // A section's small-caps title on the grid's edges, with an optional detail
    // and link on the right.
    component SectionTitle: Item {
        id: section

        property string label: ""
        property string detail: ""
        property string action: ""
        property string actionName: section.action
        // Top-level sections align with the rows' padding; details sit flush.
        property int inset: root.pad
        signal acted()

        width: parent ? parent.width : 0
        height: sectionLabel.implicitHeight

        Text {
            id: sectionLabel
            x: section.inset
            text: section.label.toUpperCase()
            font.family: Theme.fontMenu
            font.pixelSize: Theme.typography.section
            font.weight: Theme.weightSemibold
            font.letterSpacing: 1
            color: Theme.textFaint
        }
        LinkText {
            id: sectionAction
            visible: section.action !== ""
            anchors.right: parent.right
            anchors.rightMargin: section.inset
            anchors.baseline: sectionLabel.baseline
            text: section.action
            font.pixelSize: Theme.typography.metadata
            accessibleName: section.actionName
            onClicked: section.acted()
        }
        Caption {
            anchors.right: sectionAction.visible ? sectionAction.left : parent.right
            anchors.rightMargin: sectionAction.visible ? Theme.scaled(8) : section.inset
            anchors.baseline: sectionLabel.baseline
            width: Math.max(0, Math.min(implicitWidth, parent.width - section.inset * 2 - sectionLabel.implicitWidth
                - (sectionAction.visible ? sectionAction.implicitWidth + Theme.scaled(8) : 0) - Theme.scaled(12)))
            horizontalAlignment: Text.AlignRight
            text: section.detail
            font.features: Theme.tabularNumberFeatures
            color: Theme.textFaint
        }
    }

    // One 8px state dot and its word, as Fusebox's own status column.
    component Status: Row {
        id: status

        property string word: ""
        property color tint: Theme.textDim

        spacing: Theme.scaled(6)

        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: 7
            height: 7
            radius: 3.5
            color: status.tint
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: status.word
            textFormat: Text.PlainText
            font.family: Theme.fontMenu
            font.pixelSize: Theme.typography.metadata
            font.weight: Theme.weightMedium
            font.features: Theme.tabularNumberFeatures
            color: Theme.textMid
        }
    }

    // A quota meter: 20 blocks of 5%, as wide as its column allows, filled and
    // labelled with the share used or left. Amber from 75% used and red from 95%,
    // either way. A thin mark stands where even pace would be by now; it turns
    // amber when this pace uses the window up before it resets.
    component MeterBar: Item {
        id: bar

        property string label: ""
        property var reading: null
        // 0 to 1 in the meter's own direction, or -1 without a reset time.
        property real pace: -1
        property bool early: false
        readonly property var share: Helpers.quotaShare(bar.reading, Fusebox.quotaDisplay)

        implicitHeight: barPercent.implicitHeight

        Text {
            id: barLabel
            anchors.verticalCenter: parent.verticalCenter
            width: Theme.scaled(24)
            text: bar.label
            font.family: Theme.fontMenu
            font.pixelSize: Theme.typography.section
            font.weight: Theme.weightSemibold
            font.letterSpacing: 0.5
            color: Theme.textFaint
        }
        Item {
            id: blocks

            readonly property int room: bar.width - barLabel.width - barPercent.width - Theme.scaled(12)
            readonly property int blockWidth: Math.max(2, Math.floor((blocks.room + 2) / 20) - 2)

            x: barLabel.width + Theme.scaled(6)
            anchors.verticalCenter: parent.verticalCenter
            // Exactly twenty blocks of five percent.
            width: 20 * (blocks.blockWidth + 2) - 2
            height: 7

            BlockMeter {
                anchors.fill: parent
                blockWidth: blocks.blockWidth
                gap: 2
                value: bar.reading ? bar.share / 100 : 0
                fillColor: root.meterTone(bar.reading ? bar.reading.level : "ok")
            }
            Rectangle {
                visible: bar.reading !== null && bar.pace >= 0
                x: Math.round(Math.max(0, bar.pace) * (parent.width - width))
                y: -2
                width: 2
                height: parent.height + 4
                radius: 1
                color: bar.early ? Theme.amber : Theme.textMid
            }
        }
        Text {
            id: barPercent
            anchors.left: blocks.right
            anchors.leftMargin: Theme.scaled(6)
            anchors.verticalCenter: parent.verticalCenter
            width: Theme.scaled(34)
            text: bar.reading ? Helpers.percent(bar.share) : "–"
            horizontalAlignment: Text.AlignRight
            font.family: Theme.fontNumeric
            font.pixelSize: Theme.typography.metadata
            font.weight: Theme.weightMedium
            font.features: Theme.tabularNumberFeatures
            color: bar.reading ? root.tone(bar.reading.level) : Theme.textFaint
        }
    }

    // An account's 5-hour or weekly meter.
    component QuotaMeter: MeterBar {
        id: meter

        required property var account
        property bool short: true
        readonly property var window: Helpers.windowOf(meter.account, meter.short, root.now)
        readonly property var mark: Helpers.paceMark(meter.window, root.now, Fusebox.quotaDisplay)
        readonly property var runsOut: Helpers.runsOutAt(meter.window, root.now)

        label: Helpers.windowLabel(meter.window, meter.short)
        reading: Helpers.quota(meter.window, root.now)
        pace: meter.mark === null ? -1 : meter.mark
        early: meter.runsOut !== null
        Accessible.role: Accessible.StaticText
        Accessible.name: Helpers.windowTitle(meter.window || { name: meter.short ? "5h" : "week" }) + " quota"
        Accessible.description: !meter.reading ? "not reported"
            : [Helpers.percent(meter.share) + " " + Helpers.quotaWord(Fusebox.quotaDisplay),
                meter.runsOut !== null ? "runs out in " + Helpers.span(meter.runsOut - root.now) + " at this pace"
                    : meter.window.resetsAt ? "resets in " + Helpers.span(meter.window.resetsAt - root.now) : "",
                Helpers.rateText(Helpers.burnRate(meter.window, root.now))].filter(part => part).join(", ")
    }

    // A row of choices with one picked: the Used / Left switch and an account's
    // priority. Arrow keys move the choice and the focus together.
    component Segmented: Rectangle {
        id: seg

        // [{ value, label, description }]
        property var options: []
        property var current
        property string accessibleName: ""
        signal picked(var value)

        width: segRow.implicitWidth + 4
        height: Theme.scaled(22)
        radius: Theme.chipRadius
        color: Theme.chip
        opacity: seg.enabled ? 1 : 0.5
        Accessible.role: Accessible.Grouping
        Accessible.name: seg.accessibleName

        Row {
            id: segRow
            anchors.centerIn: parent
            spacing: 2

            Repeater {
                id: segments
                model: seg.options

                Rectangle {
                    id: segment

                    required property var modelData
                    required property int index
                    readonly property bool chosen: seg.current === segment.modelData.value

                    function pick(at) {
                        const option = seg.options[at];
                        if (option && seg.enabled && option.value !== seg.current)
                            seg.picked(option.value);
                    }
                    function step(delta) {
                        const next = Math.max(0, Math.min(seg.options.length - 1, segment.index + delta));
                        segment.pick(next);
                        const item = segments.itemAt(next);
                        if (item)
                            item.forceActiveFocus();
                    }

                    width: segmentText.implicitWidth + Theme.scaled(14)
                    height: seg.height - 4
                    radius: Theme.chipRadius - 2
                    color: segment.chosen ? Theme.chipHover
                        : segmentMouse.containsMouse && seg.enabled ? Theme.hoverFill : "transparent"
                    border.width: segment.activeFocus ? 1 : 0
                    border.color: Theme.accentText
                    activeFocusOnTab: segment.chosen && seg.enabled
                    Accessible.role: Accessible.RadioButton
                    Accessible.name: segment.modelData.description || segment.modelData.label
                    Accessible.checked: segment.chosen
                    Accessible.onPressAction: segment.pick(segment.index)
                    Keys.onPressed: event => {
                        if (event.key === Qt.Key_Left || event.key === Qt.Key_Right) {
                            segment.step(event.key === Qt.Key_Left ? -1 : 1);
                            event.accepted = true;
                        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                                || event.key === Qt.Key_Space) {
                            segment.pick(segment.index);
                            event.accepted = true;
                        }
                    }

                    Behavior on color {
                        ColorAnimation { duration: Theme.chipFadeDuration }
                    }

                    Text {
                        id: segmentText
                        anchors.centerIn: parent
                        text: segment.modelData.label
                        font.family: Theme.fontMenu
                        font.pixelSize: Theme.typography.metadata
                        font.weight: segment.chosen ? Theme.weightSemibold : Theme.weightMedium
                        color: segment.chosen ? Theme.textHi : Theme.textDim
                    }
                    MouseArea {
                        id: segmentMouse
                        anchors.fill: parent
                        enabled: seg.enabled
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: segment.pick(segment.index)
                    }
                }
            }
        }
    }

    // Fusebox's Used / Left switch for every meter.
    component QuotaSwitch: Segmented {
        accessibleName: I18n.tr("Quota meters")
        options: [
            { value: "used", label: "Used", description: "Show quota used" },
            { value: "remaining", label: "Left", description: "Show quota remaining" }
        ]
        current: Fusebox.quotaDisplay
        onPicked: value => Fusebox.setQuotaDisplay(value)
    }

    // A labelled figure on the recessed strip below the faults.
    component Fact: Item {
        id: fact

        property string label: ""
        property string value: ""
        property string level: "ok"
        property bool divider: true

        height: parent ? parent.height : 0
        Accessible.role: Accessible.StaticText
        Accessible.name: fact.label
        Accessible.description: fact.value

        Rectangle {
            visible: fact.divider
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
            text: fact.label
        }
        Figure {
            anchors.left: factLabel.left
            anchors.top: factLabel.bottom
            anchors.topMargin: 1
            width: factLabel.width
            elide: Text.ElideRight
            text: fact.value
            color: root.tone(fact.level)
        }
    }

    // A run of labelled figures on one recessed strip. Keyed by count, so values
    // that move with the clock update in place instead of rebuilding.
    component FactStrip: Rectangle {
        id: strip

        property var facts: []
        property color fill: Theme.chip

        width: parent ? parent.width : 0
        height: Theme.scaled(46)
        radius: Theme.chipRadius
        color: strip.fill

        Row {
            anchors.fill: parent

            Repeater {
                model: strip.facts.length

                Fact {
                    required property int index
                    readonly property var fact: strip.facts[index] || ({})

                    width: strip.width / Math.max(1, strip.facts.length)
                    divider: index > 0
                    label: fact.label || ""
                    value: fact.value || ""
                    level: fact.level || "ok"
                }
            }
        }
    }

    // Requests per minute for the last hour: sixty fixed slots that read their
    // minute, so the bars persist while the clock moves them along. Failures
    // stack in red, and the current minute is lit.
    component LoadBars: Item {
        id: chart

        property var bars: []
        property real peak: 4

        Row {
            id: barRow
            readonly property real slot: width / 60
            anchors.fill: parent

            Repeater {
                model: 60

                Item {
                    id: barSlot
                    required property int index
                    readonly property var bucket: chart.bars[index] || ({ requests: 0, failed: 0, current: false })

                    width: barRow.slot
                    height: barRow.height

                    Rectangle {
                        anchors.bottom: parent.bottom
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: Math.max(1, barRow.slot - 2)
                        height: barSlot.bucket.requests > 0
                            ? Math.max(2, barSlot.bucket.requests / chart.peak * parent.height) : 1
                        radius: 1
                        color: barSlot.bucket.requests === 0 ? Theme.hairline
                            : barSlot.bucket.current ? Theme.accentText : Qt.alpha(Theme.accentText, 0.45)
                    }
                    Rectangle {
                        visible: barSlot.bucket.failed > 0
                        anchors.bottom: parent.bottom
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: Math.max(1, barRow.slot - 2)
                        height: Math.max(2, barSlot.bucket.failed / chart.peak * parent.height)
                        radius: 1
                        color: Theme.red
                    }
                }
            }
        }
    }

    // A small button with an icon: the breaker's switches and the links out.
    component PillButton: Rectangle {
        id: pill

        property string label: ""
        property string glyph: ""
        property bool danger: false
        property string accessibleName: label
        readonly property color ink: pill.danger ? Theme.redText : Theme.textMid
        signal activated()

        implicitWidth: pillRow.implicitWidth + Theme.scaled(18)
        width: implicitWidth
        height: Theme.scaled(26)
        radius: Theme.chipRadius
        opacity: pill.enabled ? 1 : 0.45
        color: pill.danger ? Theme.redBgSoft : pillMouse.containsMouse && pill.enabled ? Theme.chipHover : Theme.hoverFill
        border.width: 1
        border.color: pill.activeFocus ? Theme.accentText : pill.danger ? Theme.redBorder : Theme.hairline
        activeFocusOnTab: pill.enabled && pill.visible
        Accessible.role: Accessible.Button
        Accessible.name: pill.accessibleName
        Accessible.onPressAction: if (pill.enabled) pill.activated()
        Keys.onPressed: event => {
            if (pill.enabled && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                    || event.key === Qt.Key_Space)) {
                pill.activated();
                event.accepted = true;
            }
        }

        Behavior on color {
            ColorAnimation { duration: Theme.chipFadeDuration }
        }

        Row {
            id: pillRow
            anchors.centerIn: parent
            spacing: Theme.scaled(5)

            Sym {
                visible: pill.glyph !== ""
                anchors.verticalCenter: parent.verticalCenter
                name: pill.glyph
                size: Theme.iconSmall
                color: pill.ink
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: pill.label
                textFormat: Text.PlainText
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.metadata
                font.weight: Theme.weightSemibold
                color: pill.ink
            }
        }
        MouseArea {
            id: pillMouse
            anchors.fill: parent
            enabled: pill.enabled
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: pill.activated()
        }
    }

    // Something about an account worth a box of its own, with its action on
    // the right, as the dashboard's drawer shows cooldowns and errors.
    component Notice: Rectangle {
        id: notice

        property string tone: "info"
        property string glyph: "info"
        property string title: ""
        property string body: ""
        property bool mono: false
        default property alias actions: noticeActions.data
        readonly property color ink: tone === "error" ? Theme.redText : tone === "warn" ? Theme.amber : Theme.textMid

        width: parent ? parent.width : 0
        height: Math.max(noticeText.implicitHeight, noticeActions.height) + Theme.scaled(18)
        radius: Theme.chipRadius
        color: tone === "error" ? Theme.redBgSoft : tone === "warn" ? Theme.amberBgSoft : root.surfaceColor
        border.width: 1
        border.color: tone === "error" ? Theme.redBorder : tone === "warn" ? Theme.amberBorder : Theme.hairlineSoft
        Accessible.role: Accessible.StaticText
        Accessible.name: notice.title
        Accessible.description: notice.body

        Sym {
            x: Theme.scaled(10)
            y: Theme.scaled(10)
            name: notice.glyph
            size: Theme.iconSmall
            color: notice.ink
        }
        Column {
            id: noticeText
            x: Theme.scaled(32)
            y: Theme.scaled(9)
            width: parent.width - x - noticeActions.width - Theme.scaled(20)
            spacing: Theme.scaled(2)

            Text {
                width: parent.width
                elide: Text.ElideRight
                textFormat: Text.PlainText
                text: notice.title
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.metadata
                font.weight: Theme.weightSemibold
                color: notice.ink
            }
            Text {
                visible: text !== ""
                width: parent.width
                wrapMode: Text.Wrap
                maximumLineCount: 4
                elide: Text.ElideRight
                textFormat: Text.PlainText
                text: notice.body
                lineHeight: 1.15
                font.family: notice.mono ? Theme.fontMono : Theme.fontMenu
                font.pixelSize: Theme.typography.metadata
                font.features: Theme.tabularNumberFeatures
                color: Theme.textMid
            }
        }
        Row {
            id: noticeActions
            anchors.right: parent.right
            anchors.rightMargin: Theme.scaled(9)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.scaled(6)
        }
    }

    // Banked resets, natively: the grants, a confirmation for the one spend, what
    // came of it, and recovery when an earlier spend's outcome is unknown. Fusebox
    // enforces the rules; this keeps a spend to two deliberate clicks (Use 1
    // reset, then Apply reset) against the exact inventory that was shown.
    component ResetPanel: Rectangle {
        id: panel

        required property var account
        readonly property var resetInfo: Fusebox.resetState(account.id)
        // Always null rather than undefined, so every binding can test them plainly.
        readonly property var view: resetInfo && resetInfo.view ? resetInfo.view : null
        readonly property var dialog: resetInfo && resetInfo.dialog ? resetInfo.dialog : null
        readonly property bool busy: Fusebox.resetBusy
        readonly property bool mine: Fusebox.resetBusy && Fusebox.resetAccount === account.id
        readonly property bool review: Helpers.resetUnresolved(view) || (!view && account.bankedReview)
        readonly property string mode: dialog ? dialog.action : review ? "review" : view ? "inventory" : "summary"
        readonly property bool asking: mode === "redeem" || mode === "retry" || mode === "resolve"
        readonly property bool warn: review || mode === "retry" || mode === "resolve"
        readonly property string block: Helpers.resetBlock(view, account, root.now)
        readonly property var grants: view && view.inventory ? view.inventory.grants : []
        readonly property var choices: dialog && dialog.inventory ? dialog.inventory.grants.filter(g => g.usable) : []
        readonly property var chosen: dialog && dialog.inventory
            ? dialog.inventory.grants.find(g => g.id === dialog.grant) || null : null
        readonly property int available: view && view.inventory && view.inventory.available !== null
            ? view.inventory.available : account.banked
        readonly property var operation: view ? view.operation : null
        readonly property string settled: resetInfo && resetInfo.message ? resetInfo.message
            : operation && !Helpers.resetUnresolved(view) && operation.message ? operation.message : ""

        width: parent ? parent.width : 0
        height: panelBody.implicitHeight + Theme.scaled(20)
        radius: Theme.chipRadius
        color: panel.warn ? Theme.amberBgSoft : root.surfaceColor
        border.width: 1
        border.color: panel.warn || panel.mode === "redeem" ? Theme.amberBorder : Theme.hairlineSoft
        Accessible.role: Accessible.Grouping
        Accessible.name: "Banked resets for " + Fusebox.accountName(panel.account)

        // A question gets the keyboard on its safe answer.
        onModeChanged: if (panel.asking) Qt.callLater(() => backButton.forceActiveFocus())

        Behavior on color {
            ColorAnimation { duration: Theme.chipFadeDuration }
        }

        Column {
            id: panelBody
            x: Theme.scaled(12)
            y: Theme.scaled(10)
            width: parent.width - x * 2
            spacing: Theme.scaled(7)

            Item {
                width: parent.width
                height: Math.max(panelTitle.implicitHeight, Theme.iconSmall)

                Sym {
                    id: panelGlyph
                    anchors.verticalCenter: parent.verticalCenter
                    name: panel.warn ? "warning" : "restart_alt"
                    size: Theme.iconSmall
                    color: panel.warn || panel.mode === "redeem" ? Theme.amber : Theme.textMid
                }
                Text {
                    id: panelTitle
                    anchors.left: panelGlyph.right
                    anchors.leftMargin: Theme.scaled(8)
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.min(implicitWidth, parent.width - x - panelAside.implicitWidth - Theme.scaled(10))
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.metadata
                    font.weight: Theme.weightSemibold
                    color: panel.warn ? Theme.amber : Theme.textHi
                    text: {
                        switch (panel.mode) {
                        case "redeem": return "Use 1 reset on " + Fusebox.accountName(panel.account) + "?";
                        case "retry": return "Retry the reset request?";
                        case "resolve": return "Record the reset's outcome";
                        case "review": return "A reset may have been used";
                        default:
                            return Helpers.resetCountText(panel.available)
                                + (panel.account.provider === "claude" && panel.view && panel.view.inventory
                                    && panel.view.inventory.applicable !== null
                                    && panel.view.inventory.applicable !== panel.available
                                    ? " · " + panel.view.inventory.applicable + " usable now" : "");
                        }
                    }
                }
                Caption {
                    id: panelAside
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    font.features: Theme.tabularNumberFeatures
                    color: panel.mode === "redeem" ? Theme.amber : Theme.textFaint
                    text: {
                        if (panel.mode === "redeem")
                            return "Confirm within " + Helpers.countdown(Helpers.quoteLeft(panel.dialog.startedAt, root.now));
                        if (panel.mode === "retry" && panel.operation && panel.operation.retryUntil)
                            return "Possible for " + Helpers.span(panel.operation.retryUntil - root.now);
                        if (panel.view && panel.view.checkedAt && !panel.asking)
                            return "Checked " + Helpers.ago(root.now - panel.view.checkedAt);
                        return "";
                    }
                }
            }

            Caption {
                visible: text !== ""
                width: parent.width
                wrapMode: Text.Wrap
                elide: Text.ElideNone
                lineHeight: 1.15
                color: Theme.textMid
                text: {
                    switch (panel.mode) {
                    case "summary":
                        // With automatic redemption on, Fusebox may spend one itself.
                        return panel.account.bankedPlan && panel.account.bankedPlan.auto
                            ? "Clears a usage limit early. Using one here always asks first."
                            : "Clears a usage limit early. Always asks before spending.";
                    case "review":
                        return "New resets are blocked until it's resolved. Check the provider account, then record what happened"
                            + (Helpers.retryAllowed(panel.view, panel.account, root.now) ? ", or retry the saved request." : ".");
                    case "redeem":
                        return "This spends one saved reset and can't be undone."
                            + (panel.account.provider === "codex" ? " Codex chooses the reset and restores its subscription limits." : "");
                    case "retry":
                        return "A reset may already have been used. This sends the saved request again, with the same IDs.";
                    case "resolve":
                        return "Check your provider account first. This only records what happened; nothing is sent to the provider.";
                    default:
                        return "";
                    }
                }
            }

            // What Fusebox does about an expiring reset by itself.
            Caption {
                readonly property var plan: panel.account.bankedPlan || null
                visible: plan !== null && (panel.mode === "summary" || panel.mode === "inventory"
                    || (panel.mode === "redeem" && plan.auto && plan.due))
                width: parent.width
                wrapMode: Text.Wrap
                elide: Text.ElideNone
                lineHeight: 1.15
                color: plan && plan.auto && plan.due ? Theme.amber : Theme.textLow
                text: Helpers.bankedPlanText(plan, root.now)
            }

            // The grants, as the dashboard lists them.
            Repeater {
                model: panel.mode === "inventory" ? panel.grants : []

                Column {
                    id: grantRow
                    required property var modelData
                    width: parent ? parent.width : 0
                    spacing: Theme.scaled(1)

                    Item {
                        width: parent.width
                        height: grantLabel.implicitHeight

                        Text {
                            id: grantLabel
                            width: Math.min(implicitWidth, parent.width - grantLeft.implicitWidth - Theme.scaled(10))
                            elide: Text.ElideRight
                            textFormat: Text.PlainText
                            text: grantRow.modelData.label
                            font.family: Theme.fontMenu
                            font.pixelSize: Theme.typography.metadata
                            font.weight: Theme.weightMedium
                            color: grantRow.modelData.usable ? Theme.textHi : Theme.textLow
                        }
                        Caption {
                            id: grantLeft
                            anchors.right: parent.right
                            font.features: Theme.tabularNumberFeatures
                            color: Theme.textLow
                            text: grantRow.modelData.remaining + " left"
                        }
                    }
                    Caption {
                        width: parent.width
                        font.features: Theme.tabularNumberFeatures
                        color: Theme.textFaint
                        text: Helpers.grantDetail(grantRow.modelData, root.now)
                    }
                    Caption {
                        visible: !!grantRow.modelData.reason
                        width: parent.width
                        wrapMode: Text.Wrap
                        elide: Text.ElideNone
                        color: Theme.textLow
                        text: grantRow.modelData.reason || ""
                    }
                }
            }

            // Claude may offer more than one usable grant; Codex picks its own.
            Repeater {
                model: panel.mode === "redeem" && panel.account.provider === "claude" && panel.choices.length > 1
                    ? panel.choices : []

                Rectangle {
                    id: choice
                    required property var modelData
                    readonly property bool selected: panel.dialog && panel.dialog.grant === modelData.id

                    function pick() {
                        if (!panel.busy)
                            Fusebox.chooseResetGrant(panel.account.id, choice.modelData.id);
                    }

                    width: parent ? parent.width : 0
                    height: choiceText.implicitHeight + Theme.scaled(12)
                    radius: Theme.chipRadius
                    color: choice.selected ? Theme.chip : choiceMouse.containsMouse ? Theme.hoverFill : "transparent"
                    border.width: choice.selected || choice.activeFocus ? 1 : 0
                    border.color: choice.activeFocus ? Theme.accentText : Theme.amberBorder
                    activeFocusOnTab: true
                    Accessible.role: Accessible.RadioButton
                    Accessible.name: choice.modelData.label
                    Accessible.description: Helpers.grantDetail(choice.modelData, root.now)
                    Accessible.checked: choice.selected
                    Accessible.onPressAction: choice.pick()
                    Keys.onPressed: event => {
                        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                            choice.pick();
                            event.accepted = true;
                        }
                    }

                    Rectangle {
                        id: choiceDot
                        x: Theme.scaled(8)
                        anchors.verticalCenter: parent.verticalCenter
                        width: Theme.scaled(10)
                        height: width
                        radius: width / 2
                        color: "transparent"
                        border.width: 1
                        border.color: choice.selected ? Theme.amber : Theme.textFaint

                        Rectangle {
                            visible: choice.selected
                            anchors.centerIn: parent
                            width: parent.width - Theme.scaled(4)
                            height: width
                            radius: width / 2
                            color: Theme.amber
                        }
                    }
                    Column {
                        id: choiceText
                        anchors.left: choiceDot.right
                        anchors.leftMargin: Theme.scaled(8)
                        anchors.right: parent.right
                        anchors.rightMargin: Theme.scaled(8)
                        anchors.verticalCenter: parent.verticalCenter

                        Text {
                            width: parent.width
                            elide: Text.ElideRight
                            textFormat: Text.PlainText
                            text: choice.modelData.label + " · " + choice.modelData.remaining + " left"
                            font.family: Theme.fontMenu
                            font.pixelSize: Theme.typography.metadata
                            font.weight: Theme.weightMedium
                            color: Theme.textHi
                        }
                        Caption {
                            width: parent.width
                            color: Theme.textFaint
                            text: Helpers.grantDetail(choice.modelData, root.now)
                        }
                    }
                    MouseArea {
                        id: choiceMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: choice.pick()
                    }
                }
            }
            Caption {
                visible: panel.mode === "redeem" && panel.chosen !== null
                    && !(panel.account.provider === "claude" && panel.choices.length > 1)
                width: parent.width
                wrapMode: Text.Wrap
                elide: Text.ElideNone
                color: Theme.textLow
                text: panel.chosen ? panel.chosen.label + " · " + Helpers.grantDetail(panel.chosen, root.now) : ""
            }

            Caption {
                visible: panel.mode === "inventory" && panel.block !== "" && !panel.mine && panel.resetInfo !== null
                    && !panel.resetInfo.error
                width: parent.width
                wrapMode: Text.Wrap
                elide: Text.ElideNone
                color: Theme.textLow
                text: panel.block
            }
            Caption {
                visible: (panel.mode === "inventory" || panel.mode === "summary") && panel.settled !== ""
                width: parent.width
                wrapMode: Text.Wrap
                elide: Text.ElideNone
                color: Helpers.operationTone(panel.operation) === "ok" || (panel.resetInfo && panel.resetInfo.message)
                    ? Theme.ok : Theme.textLow
                text: panel.settled
            }
            Caption {
                visible: panel.resetInfo !== null && !!panel.resetInfo.error
                width: parent.width
                wrapMode: Text.Wrap
                elide: Text.ElideNone
                color: panel.resetInfo && panel.resetInfo.uncertain ? Theme.amber : Theme.redText
                text: panel.resetInfo ? panel.resetInfo.error || "" : ""
            }

            Row {
                spacing: Theme.scaled(6)

                PillButton {
                    id: backButton
                    visible: panel.asking
                    enabled: !panel.mine
                    label: I18n.tr("Back")
                    accessibleName: "Back, without changing anything"
                    onActivated: Fusebox.cancelReset(panel.account.id)
                }
                PillButton {
                    visible: panel.mode === "summary"
                    enabled: !panel.busy
                    glyph: "restart_alt"
                    label: panel.mine ? I18n.tr("Checking…") : I18n.tr("Details")
                    accessibleName: "Show banked resets for " + Fusebox.accountName(panel.account)
                    onActivated: Fusebox.loadReset(panel.account.id)
                }
                PillButton {
                    visible: panel.mode === "inventory" || panel.mode === "review"
                    enabled: !panel.busy
                    glyph: "refresh"
                    label: panel.mine && Fusebox.resetOperation !== "open" ? "Checking…" : "Recheck"
                    accessibleName: "Check reset status and usage again for " + Fusebox.accountName(panel.account)
                    onActivated: Fusebox.refreshReset(panel.account.id)
                }
                PillButton {
                    visible: panel.mode === "inventory"
                    enabled: !panel.busy && panel.block === ""
                    label: panel.mine && Fusebox.resetOperation === "open" ? "Checking…" : "Use 1 reset"
                    accessibleName: "Use one banked reset on " + Fusebox.accountName(panel.account) + ", after a confirmation"
                    onActivated: Fusebox.beginRedeem(panel.account.id)
                }
                PillButton {
                    visible: panel.mode === "review" && Helpers.retryAllowed(panel.view, panel.account, root.now)
                    enabled: !panel.busy
                    label: I18n.tr("Retry request")
                    onActivated: Fusebox.beginRecovery(panel.account.id, "retry")
                }
                PillButton {
                    visible: panel.mode === "review" && panel.operation !== null && !!panel.operation.requestId
                    enabled: !panel.busy
                    label: I18n.tr("Check outcome")
                    onActivated: Fusebox.beginRecovery(panel.account.id, "resolve")
                }
                PillButton {
                    visible: panel.mode === "review" && panel.view === null
                    enabled: !panel.busy
                    glyph: "warning"
                    label: panel.mine ? I18n.tr("Checking…") : I18n.tr("Review")
                    onActivated: Fusebox.loadReset(panel.account.id)
                }
                PillButton {
                    visible: panel.mode === "redeem"
                    // Hidden buttons still evaluate their bindings: guard the dialog.
                    enabled: !panel.busy && panel.dialog !== null
                        && (panel.account.provider === "codex" || panel.dialog.grant !== "")
                    danger: true
                    label: panel.mine ? I18n.tr("Applying…") : I18n.tr("Apply reset")
                    accessibleName: "Apply one banked reset to " + Fusebox.accountName(panel.account) + ". This can't be undone."
                    onActivated: Fusebox.confirmReset(panel.account.id)
                }
                PillButton {
                    visible: panel.mode === "retry"
                    enabled: !panel.busy
                    danger: true
                    label: panel.mine ? I18n.tr("Retrying…") : I18n.tr("Confirm retry")
                    onActivated: Fusebox.confirmReset(panel.account.id)
                }
                PillButton {
                    visible: panel.mode === "resolve"
                    enabled: !panel.busy
                    label: I18n.tr("Reset was used")
                    onActivated: Fusebox.confirmReset(panel.account.id, "resolve-used")
                }
                PillButton {
                    visible: panel.mode === "resolve"
                    enabled: !panel.busy
                    label: I18n.tr("No reset was used")
                    onActivated: Fusebox.confirmReset(panel.account.id, "resolve-unused")
                }
            }
        }
    }

    // One client's share of a window: its name, a bar across the whole window in
    // the meter's colour, and the points. Other use is greyed.
    component ShareRow: Item {
        id: shareRow

        property string name: ""
        property real points: 0
        property bool other: false
        property string level: "ok"

        width: parent ? parent.width : 0
        height: shareName.implicitHeight
        Accessible.role: Accessible.StaticText
        Accessible.name: shareRow.name
        Accessible.description: Helpers.percent(shareRow.points) + " of the window"

        Caption {
            id: shareName
            width: Math.round(parent.width * 0.4)
            text: shareRow.name
            color: shareRow.other ? Theme.textFaint : Theme.textMid
        }
        Rectangle {
            anchors.left: shareName.right
            anchors.leftMargin: Theme.scaled(8)
            anchors.right: sharePercent.left
            anchors.rightMargin: Theme.scaled(8)
            anchors.verticalCenter: parent.verticalCenter
            height: 4
            radius: 2
            color: Theme.hairline

            Rectangle {
                width: Math.max(2, parent.width * Math.min(100, shareRow.points) / 100)
                height: parent.height
                radius: 2
                color: shareRow.other ? Theme.textFaint : root.meterTone(shareRow.level)
            }
        }
        Caption {
            id: sharePercent
            anchors.right: parent.right
            width: Theme.scaled(34)
            horizontalAlignment: Text.AlignRight
            font.features: Theme.tabularNumberFeatures
            text: Helpers.percent(shareRow.points)
        }
    }

    // A coding session pinned to an account: its program and model, since when,
    // what it used of the account's windows and where it came from.
    component SessionRow: Column {
        id: sessionRow

        required property var modelData
        property var account: null
        readonly property var session: modelData
        readonly property string usage: Helpers.sessionQuota(sessionRow.account, sessionRow.session)
        readonly property string origin: Helpers.originText(sessionRow.session, Fusebox.hideEmails)

        width: parent ? parent.width : 0
        spacing: Theme.scaled(1)
        Accessible.role: Accessible.StaticText
        Accessible.name: (sessionRow.session.client || "Session") + (sessionRow.session.model ? ", " + sessionRow.session.model : "")
        Accessible.description: [sessionRow.session.active ? "a request in flight" : "", sessionRow.usage,
            sessionRow.origin].filter(part => part).join(", ")

        Item {
            width: parent.width
            height: sessionTitle.implicitHeight

            // The in-flight dot sits after the title, so every title starts at the same edge.
            Text {
                id: sessionTitle
                width: Math.min(implicitWidth, parent.width - sessionSince.implicitWidth - Theme.scaled(26))
                elide: Text.ElideRight
                textFormat: Text.PlainText
                text: [sessionRow.session.client || "Session", sessionRow.session.model || ""]
                    .filter(part => part).join(" · ")
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.metadata
                font.weight: Theme.weightMedium
                color: Theme.textHi
            }
            Rectangle {
                visible: sessionRow.session.active
                anchors.left: sessionTitle.right
                anchors.leftMargin: Theme.scaled(6)
                anchors.verticalCenter: sessionTitle.verticalCenter
                width: 6
                height: 6
                radius: 3
                color: Theme.ok
            }
            Caption {
                id: sessionSince
                anchors.right: parent.right
                font.features: Theme.tabularNumberFeatures
                color: Theme.textFaint
                text: sessionRow.session.since ? "since " + Helpers.when(sessionRow.session.since, root.now)
                    : sessionRow.session.lastSeen ? "seen " + Helpers.ago(root.now - sessionRow.session.lastSeen) : ""
            }
        }
        Caption {
            visible: text !== ""
            width: parent.width
            font.features: Theme.tabularNumberFeatures
            color: Theme.textLow
            text: [sessionRow.usage, sessionRow.origin].filter(part => part).join(" · ")
        }
    }

    // A provider's mark in the icon column: its brand, or a generic glyph.
    component ProviderMark: Item {
        id: providerMark

        property string provider: ""
        property bool keys: false
        property int size: Theme.iconMedium

        width: Theme.iconMedium
        height: Theme.iconMedium

        BrandIcon {
            id: providerIcon
            visible: providerIcon.available
            anchors.centerIn: parent
            width: providerMark.size
            height: providerMark.size
            name: Helpers.providerMark(providerMark.provider)
        }
        Sym {
            visible: !providerIcon.available
            anchors.centerIn: parent
            name: providerMark.keys ? "key" : "account_circle"
            size: providerMark.size
            color: Theme.textLow
        }
    }

    // A provider's accounts together: its mark, name and plan, and for two or
    // more subscriptions their combined weekly use, its meter in the accounts'
    // weekly column, and how far that is from even pace.
    component GroupHead: Item {
        id: groupHead

        property var group: ({ provider: "", name: "", keys: false, summary: "", accounts: [] })
        readonly property var pool: groupHead.group.keys ? null
            : root.pools.find(p => p.provider === groupHead.group.provider) || null
        readonly property var gap: groupHead.pool ? Helpers.poolGap(groupHead.pool) : null

        width: parent ? parent.width : 0
        height: groupLine.height + (groupHead.pool ? Theme.scaled(6) + poolLine.height : 0) + Theme.scaled(12)
        Accessible.role: Accessible.StaticText
        Accessible.name: groupHead.group.name + ", " + groupHead.group.summary
        Accessible.description: groupHead.pool ? [Helpers.percent(Helpers.quotaShare({ used: groupHead.pool.used },
            Fusebox.quotaDisplay)) + " of the combined weekly quota " + Helpers.quotaWord(Fusebox.quotaDisplay),
            Helpers.poolBasis([groupHead.pool]), groupHead.gap ? groupHead.gap.text : ""].filter(part => part).join(", ") : ""

        Item {
            id: groupLine
            y: Theme.scaled(8)
            width: parent.width
            height: Math.max(groupName.implicitHeight, Theme.iconMedium)

            ProviderMark {
                x: root.pad
                anchors.verticalCenter: parent.verticalCenter
                provider: groupHead.group.provider
                keys: groupHead.group.keys
            }
            Text {
                id: groupName
                x: root.textX
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: groupHead.group.name
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.secondary
                font.weight: Theme.weightSemibold
                color: Theme.textHi
            }
            Caption {
                anchors.left: groupName.right
                anchors.leftMargin: Theme.scaled(8)
                anchors.baseline: groupName.baseline
                width: Math.min(implicitWidth, parent.width - x - groupGap.implicitWidth - root.pad - Theme.scaled(12))
                color: Theme.textLow
                text: groupHead.group.summary
            }
            Caption {
                id: groupGap
                anchors.right: parent.right
                anchors.rightMargin: root.pad
                anchors.baseline: groupName.baseline
                font.features: Theme.tabularNumberFeatures
                color: groupHead.gap && groupHead.gap.level === "warn" ? Theme.amber : Theme.textLow
                text: groupHead.gap ? groupHead.gap.text : ""
            }
        }
        Item {
            id: poolLine
            visible: groupHead.pool !== null
            x: root.textX
            anchors.top: groupLine.bottom
            anchors.topMargin: Theme.scaled(6)
            width: parent.width - x - root.pad
            height: poolMeter.implicitHeight

            Caption {
                anchors.verticalCenter: parent.verticalCenter
                width: (parent.width - root.meterGap) / 2
                color: Theme.textFaint
                text: I18n.tr("Combined")
            }
            MeterBar {
                id: poolMeter
                x: (parent.width + root.meterGap) / 2
                width: (parent.width - root.meterGap) / 2
                label: "WK" // i18n: untranslated
                reading: groupHead.pool ? Helpers.quota({ name: "week", used: groupHead.pool.used }, root.now) : null
                pace: !groupHead.pool || groupHead.pool.pace === null ? -1
                    : Fusebox.quotaDisplay === "remaining" ? 1 - groupHead.pool.pace : groupHead.pool.pace
            }
        }
    }

    component FaultRow: Rectangle {
        id: faultRow

        required property var modelData
        readonly property var fault: modelData
        readonly property bool serious: fault.level === "err"
        readonly property var account: Fusebox.accountById(fault.accountId)
        readonly property string timing: Helpers.faultTiming(fault, root.now)
        readonly property color wash: serious ? Theme.redBgSoft : Theme.amberBgSoft

        width: parent ? parent.width : 0
        height: faultText.implicitHeight + Theme.scaled(18)
        radius: Theme.chipRadius
        color: faultMouse.containsMouse ? Qt.lighter(wash, 1.25) : wash
        border.width: faultRow.activeFocus ? 1 : 0
        border.color: Theme.accentText
        activeFocusOnTab: true
        Accessible.role: Accessible.Button
        Accessible.name: faultRow.fault.title
        Accessible.description: [faultRow.account ? Fusebox.accountName(faultRow.account) : faultRow.fault.providerName,
            Fusebox.privateText(faultRow.fault.detail), faultRow.timing, "opens the Fusebox dashboard"]
            .filter(part => part).join(", ")
        Accessible.onPressAction: Fusebox.openDashboard(faultRow.fault.path)
        Keys.onPressed: event => {
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                Fusebox.openDashboard(faultRow.fault.path);
                event.accepted = true;
            } else if (event.key === Qt.Key_Delete || event.key === Qt.Key_Backspace) {
                Fusebox.dismissFault(faultRow.fault);
                event.accepted = true;
            }
        }

        Sym {
            x: root.pad
            y: Theme.scaled(9) + (faultTitle.implicitHeight - height) / 2
            name: Helpers.faultGlyph(faultRow.fault)
            size: Theme.iconMedium
            color: faultRow.serious ? Theme.redText : Theme.amber
        }
        Column {
            id: faultText
            x: root.textX
            y: Theme.scaled(9)
            width: parent.width - x - dismissButton.width - Theme.scaled(36)
            spacing: Theme.scaled(2)

            Text {
                id: faultTitle
                width: parent.width
                elide: Text.ElideRight
                textFormat: Text.PlainText
                text: faultRow.fault.title + (faultRow.account
                    ? " · " + Fusebox.accountName(faultRow.account) : "")
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.secondary
                font.weight: Theme.weightSemibold
                color: faultRow.serious ? Theme.redText : Theme.amber
            }
            Text {
                visible: text !== ""
                width: parent.width
                wrapMode: Text.Wrap
                maximumLineCount: 2
                elide: Text.ElideRight
                textFormat: Text.PlainText
                text: [Fusebox.privateText(faultRow.fault.detail), faultRow.timing]
                    .filter(part => part).join(" ")
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.metadata
                font.features: Theme.tabularNumberFeatures
                color: Theme.textMid
            }
        }
        Sym {
            anchors.right: dismissButton.left
            anchors.rightMargin: Theme.scaled(6)
            anchors.verticalCenter: parent.verticalCenter
            name: "open_in_new"
            size: Theme.iconSmall
            color: Theme.textDim
        }
        MouseArea {
            id: faultMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: Fusebox.openDashboard(faultRow.fault.path)
        }
        // Above the row's own click area, so dismissing never opens the dashboard.
        Rectangle {
            id: dismissButton
            anchors.right: parent.right
            anchors.rightMargin: Theme.scaled(6)
            anchors.verticalCenter: parent.verticalCenter
            width: Theme.scaled(26)
            height: width
            radius: Theme.chipRadius
            color: dismissMouse.containsMouse || dismissButton.activeFocus ? Theme.hoverFill : "transparent"
            border.width: dismissButton.activeFocus ? 1 : 0
            border.color: Theme.accentText
            activeFocusOnTab: true
            Accessible.role: Accessible.Button
            Accessible.name: "Dismiss " + faultRow.fault.title
            Accessible.description: I18n.tr("Hidden until it clears or changes")
            Accessible.onPressAction: Fusebox.dismissFault(faultRow.fault)
            Keys.onPressed: event => {
                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                    Fusebox.dismissFault(faultRow.fault);
                    event.accepted = true;
                }
            }

            Sym {
                anchors.centerIn: parent
                name: "close"
                size: Theme.iconSmall
                color: dismissMouse.containsMouse ? Theme.textHi : Theme.textDim
            }
            MouseArea {
                id: dismissMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: Fusebox.dismissFault(faultRow.fault)
            }
        }
    }

    // An account on the shared grid: its name and status on the first line, its
    // 5-hour and weekly meters filling the second, in the same columns on every
    // row. The provider's mark is on its group's head, so the icon column is empty.
    component AccountRow: Rectangle {
        id: circuit

        required property var modelData
        // A group whose accounts share a plan names it once, on its head.
        property bool showPlan: true
        readonly property var account: modelData
        readonly property var circuitState: Helpers.accountState(account, Fusebox.load, root.now)
        readonly property bool open: root.expanded === account.id
        readonly property int sessionCount: Helpers.sessions(account, Fusebox.load)
        readonly property bool metered: account.windows.length > 0
        readonly property var detail: Fusebox.activity[account.id] || null
        readonly property bool acting: Fusebox.actionBusy && Fusebox.actionAccount === account.id
        readonly property var result: Fusebox.actionResult && Fusebox.actionResult.account === account.id
            ? Fusebox.actionResult : null
        readonly property string plan: circuit.showPlan ? Helpers.planName(circuit.account) : ""

        width: parent ? parent.width : 0
        height: circuitBody.implicitHeight + Theme.scaled(14)
        radius: Theme.chipRadius
        color: circuit.open ? Theme.chip : circuitMouse.containsMouse ? Theme.hoverFill : "transparent"
        opacity: account.disabled ? 0.7 : 1

        Behavior on color {
            ColorAnimation { duration: Theme.chipFadeDuration }
        }

        // The name and meters are the disclosure; the breaker buttons below sit
        // outside it so they never also toggle the row.
        MouseArea {
            id: circuitMouse
            width: parent.width
            height: circuitBody.y + head.height + (meters.visible ? circuitBody.spacing + meters.height : 0)
                + Theme.scaled(6)
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.toggle(circuit.account.id)
        }

        Column {
            id: circuitBody
            x: root.textX
            y: Theme.scaled(7)
            width: parent.width - x - root.pad
            spacing: Theme.scaled(5)

            Item {
                id: head
                width: parent.width
                height: Math.max(nameText.implicitHeight, statusRow.implicitHeight)
                activeFocusOnTab: true
                Accessible.role: Accessible.Button
                Accessible.name: Fusebox.accountName(circuit.account) + ", " + Helpers.providerName(circuit.account)
                    + (Helpers.planName(circuit.account) ? " " + Helpers.planName(circuit.account) : "")
                // The label shows sessions; a screen reader also hears requests in progress.
                Accessible.description: [circuit.circuitState.word,
                    circuit.sessionCount > 0 ? Helpers.statusText(circuit.circuitState, circuit.sessionCount, 0) : "",
                    circuit.open ? "details shown" : "show details"].filter(part => part).join(", ")
                Accessible.onPressAction: root.toggle(circuit.account.id)
                Keys.onPressed: event => {
                    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                        root.toggle(circuit.account.id);
                        event.accepted = true;
                    }
                }

                Rectangle {
                    anchors.fill: parent
                    anchors.margins: -3
                    visible: head.activeFocus
                    radius: Theme.chipRadius
                    color: "transparent"
                    border.width: 1
                    border.color: Theme.accentText
                }
                Text {
                    id: nameText
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.min(implicitWidth, parent.width - planTag.width - reviewTag.width
                        - statusRow.width - Theme.scaled(20))
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                    text: Fusebox.accountName(circuit.account)
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.secondary
                    font.weight: Theme.weightMedium
                    color: Theme.textHi
                }
                Rectangle {
                    id: planTag
                    visible: circuit.plan !== ""
                    anchors.left: nameText.right
                    anchors.leftMargin: visible ? Theme.scaled(6) : 0
                    anchors.verticalCenter: parent.verticalCenter
                    width: visible ? planText.implicitWidth + Theme.scaled(10) : 0
                    height: planText.implicitHeight + Theme.scaled(2)
                    radius: Theme.scaled(4)
                    color: Theme.hairlineSoft

                    Text {
                        id: planText
                        anchors.centerIn: parent
                        text: circuit.plan
                        font.family: Theme.fontMenu
                        font.pixelSize: Theme.typography.section
                        font.weight: Theme.weightSemibold
                        color: Theme.textLow
                    }
                }
                // An unresolved reset spend, as the dashboard's "Review reset".
                Rectangle {
                    id: reviewTag
                    visible: !!circuit.account.bankedReview
                    anchors.left: planTag.right
                    anchors.leftMargin: visible ? Theme.scaled(6) : 0
                    anchors.verticalCenter: parent.verticalCenter
                    width: visible ? reviewText.implicitWidth + Theme.scaled(10) : 0
                    height: reviewText.implicitHeight + Theme.scaled(2)
                    radius: Theme.scaled(4)
                    color: Theme.amberBgSoft

                    Text {
                        id: reviewText
                        anchors.centerIn: parent
                        text: I18n.tr("Review reset")
                        font.family: Theme.fontMenu
                        font.pixelSize: Theme.typography.section
                        font.weight: Theme.weightSemibold
                        color: Theme.amber
                    }
                }
                Status {
                    id: statusRow
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    word: Helpers.statusText(circuit.circuitState, circuit.sessionCount,
                        Helpers.inFlight(circuit.account, Fusebox.load))
                    tint: root.statusTone(circuit.circuitState)
                }
            }

            // The 5-hour and weekly meters, each filling half the row.
            Item {
                id: meters
                visible: circuit.metered
                width: parent.width
                height: shortMeter.implicitHeight

                QuotaMeter {
                    id: shortMeter
                    width: (parent.width - root.meterGap) / 2
                    account: circuit.account
                    short: true
                }
                QuotaMeter {
                    x: (parent.width + root.meterGap) / 2
                    width: (parent.width - root.meterGap) / 2
                    account: circuit.account
                    short: false
                }
            }

            // ---- details ----
            Column {
                id: details
                visible: circuit.open
                width: parent.width
                topPadding: Theme.scaled(6)
                spacing: Theme.scaled(10)

                readonly property var series: circuit.detail && circuit.detail.series ? circuit.detail.series : []
                readonly property var accountBars: Helpers.bars(details.series, root.now)
                readonly property int accountTotal: details.accountBars.reduce((sum, b) => sum + b.requests, 0)
                readonly property string pauses: Helpers.pauseText(circuit.account, root.now)
                readonly property var windows: Helpers.windowDetails(circuit.account, root.now, Fusebox.hideEmails)
                readonly property var sessions: Helpers.namedSessions(circuit.detail)
                readonly property int pinned: circuit.detail && !circuit.detail.error ? circuit.detail.sessions.length : 0

                Caption {
                    width: parent.width
                    font.features: Theme.tabularNumberFeatures
                    color: Theme.textLow
                    text: Helpers.accountSubtitle(circuit.account, root.now)
                }

                Notice {
                    visible: details.pauses !== ""
                    tone: "warn"
                    glyph: "schedule"
                    title: circuit.account.cooldowns.some(c => c.kind === "quota" && c.until > root.now)
                        ? "Usage limit used up" : "Paused"
                    body: details.pauses

                    PillButton {
                        enabled: !Fusebox.actionBusy
                        label: circuit.acting && Fusebox.actionName === "reset" ? "Clearing…" : "Clear"
                        accessibleName: "Clear cooldowns of " + Fusebox.accountName(circuit.account)
                        onActivated: Fusebox.runAction(circuit.account.id, "reset")
                    }
                }
                Notice {
                    visible: !!circuit.account.lastError
                    tone: "error"
                    glyph: "error"
                    mono: true
                    title: circuit.circuitState.signin ? I18n.tr("Sign-in expired") : I18n.tr("Last error")
                    body: Fusebox.privateText(circuit.account.lastError)

                    // Signing in again needs the dashboard: its redirects go to the server.
                    PillButton {
                        visible: !!circuit.circuitState.signin
                        label: I18n.tr("Sign in")
                        glyph: "open_in_new"
                        accessibleName: "Sign in to " + Fusebox.accountName(circuit.account) + " again in the Fusebox dashboard"
                        onActivated: Fusebox.openDashboard("#/accounts/" + encodeURIComponent(circuit.account.id))
                    }
                    PillButton {
                        visible: !circuit.circuitState.signin && details.pauses === ""
                        enabled: !Fusebox.actionBusy
                        label: circuit.acting && Fusebox.actionName === "reset" ? "Clearing…" : "Clear"
                        accessibleName: "Clear the error of " + Fusebox.accountName(circuit.account)
                        onActivated: Fusebox.runAction(circuit.account.id, "reset")
                    }
                }
                FactStrip {
                    fill: root.surfaceColor
                    facts: Helpers.accountFacts(circuit.account, circuit.detail, root.now)
                }

                // Each meter's window: its pace, when it resets or runs out, and
                // who used it. Keyed by count, as the clock moves the windows along.
                Repeater {
                    model: details.windows.length

                    Column {
                        id: windowBlock

                        required property int index
                        readonly property var entry: details.windows[index]
                            || ({ title: "", timing: "", level: "ok", rate: "", rows: [], meterLevel: "ok" })

                        width: details.width
                        spacing: Theme.scaled(4)

                        Item {
                            width: parent.width
                            height: windowName.implicitHeight

                            Text {
                                id: windowName
                                textFormat: Text.PlainText
                                text: windowBlock.entry.title
                                font.family: Theme.fontMenu
                                font.pixelSize: Theme.typography.metadata
                                font.weight: Theme.weightSemibold
                                color: Theme.textMid
                            }
                            Caption {
                                anchors.left: windowName.right
                                anchors.leftMargin: Theme.scaled(8)
                                anchors.baseline: windowName.baseline
                                width: Math.max(0, Math.min(implicitWidth, windowTiming.x - x - Theme.scaled(10)))
                                font.features: Theme.tabularNumberFeatures
                                color: Theme.textFaint
                                text: windowBlock.entry.rate
                            }
                            Caption {
                                id: windowTiming
                                anchors.right: parent.right
                                anchors.baseline: windowName.baseline
                                font.features: Theme.tabularNumberFeatures
                                color: windowBlock.entry.level === "warn" ? Theme.amber : Theme.textLow
                                text: windowBlock.entry.timing
                            }
                        }
                        Repeater {
                            model: windowBlock.entry.rows.length

                            ShareRow {
                                required property int index
                                readonly property var row: windowBlock.entry.rows[index] || ({})

                                name: row.name || ""
                                points: row.points || 0
                                other: !!row.other
                                level: windowBlock.entry.meterLevel
                            }
                        }
                    }
                }
                Caption {
                    visible: details.windows.some(w => w.rows.length > 0)
                    width: parent.width
                    wrapMode: Text.Wrap
                    elide: Text.ElideNone
                    color: Theme.textFaint
                    text: details.windows.some(w => w.byTokens)
                        ? "Shares are Fusebox's estimate from its quota readings, partly by tokens."
                        : "Shares are Fusebox's estimate from its quota readings."
                }

                // The account's own hour, from its activity.
                Column {
                    visible: details.series.length > 0
                    width: parent.width
                    spacing: Theme.scaled(5)

                    SectionTitle {
                        inset: 0
                        label: I18n.tr("Load · last 60 min")
                        detail: Helpers.number(details.accountTotal) + (details.accountTotal === 1 ? " request" : " requests")
                    }
                    LoadBars {
                        width: parent.width
                        height: Theme.scaled(26)
                        bars: details.accountBars
                        peak: Math.max(2, ...details.accountBars.map(b => b.requests))
                        Accessible.role: Accessible.Graphic
                        Accessible.name: I18n.tr("Requests per minute on this account, last 60 minutes")
                        Accessible.description: Helpers.number(details.accountTotal) + " requests"
                    }
                }

                Column {
                    visible: details.sessions.length > 0
                    width: parent.width
                    spacing: Theme.scaled(6)

                    SectionTitle {
                        inset: 0
                        readonly property int older: details.pinned - Math.min(4, details.sessions.length)
                        label: I18n.tr("Pinned sessions")
                        detail: older > 0 ? "+" + older + " older" : ""
                    }
                    Repeater {
                        model: details.sessions.slice(0, 4)

                        SessionRow { account: circuit.account }
                    }
                }

                ResetPanel {
                    account: circuit.account
                    visible: Fusebox.resetsEnabled && Helpers.resetsSupported(circuit.account, true)
                        && (circuit.account.banked > 0 || circuit.account.bankedReview
                            || Fusebox.resetState(circuit.account.id) !== null)
                }
                Caption {
                    visible: circuit.result !== null && !circuit.result.ok
                    width: parent.width
                    wrapMode: Text.Wrap
                    elide: Text.ElideNone
                    color: Theme.redText
                    text: circuit.result ? circuit.result.error : ""
                }

                // Which accounts take new sessions first.
                Item {
                    width: parent.width
                    height: Math.max(priorityText.implicitHeight, prioritySwitch.height)

                    Column {
                        id: priorityText
                        anchors.left: parent.left
                        anchors.right: prioritySwitch.left
                        anchors.rightMargin: Theme.scaled(10)
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Theme.scaled(1)

                        Text {
                            width: parent.width
                            elide: Text.ElideRight
                            textFormat: Text.PlainText
                            text: I18n.tr("New sessions")
                            font.family: Theme.fontMenu
                            font.pixelSize: Theme.typography.metadata
                            font.weight: Theme.weightSemibold
                            color: Theme.textMid
                        }
                        Caption {
                            width: parent.width
                            wrapMode: Text.Wrap
                            elide: Text.ElideNone
                            color: Theme.textFaint
                            text: circuit.acting && Fusebox.actionName === "priority" ? "Saving…"
                                : Helpers.priorityHelp(circuit.account.priority)
                        }
                    }
                    Segmented {
                        id: prioritySwitch
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        enabled: !Fusebox.actionBusy
                        accessibleName: "Priority for new sessions on " + Fusebox.accountName(circuit.account)
                        options: root.priorityOptions
                        current: Helpers.priorityChoice(circuit.account.priority)
                        onPicked: value => Fusebox.runAction(circuit.account.id, "priority", value)
                    }
                }

                // The breaker: reversible switches on the left, the dashboard on the right.
                Item {
                    width: parent.width
                    height: Theme.scaled(26)

                    Row {
                        spacing: Theme.scaled(6)

                        PillButton {
                            visible: circuit.account.kind === "oauth"
                            enabled: !Fusebox.actionBusy
                            glyph: "refresh"
                            label: circuit.acting && Fusebox.actionName === "refresh" ? "Refreshing…" : "Refresh"
                            accessibleName: "Refresh the sign-in and quota of " + Fusebox.accountName(circuit.account)
                            onActivated: Fusebox.runAction(circuit.account.id, "refresh")
                        }
                        PillButton {
                            readonly property bool confirming: root.confirmOff === circuit.account.id
                            enabled: !Fusebox.actionBusy
                            glyph: "power_settings_new"
                            danger: confirming
                            label: circuit.acting && Fusebox.actionName === "toggle" ? "Switching…"
                                : circuit.account.disabled ? "Turn on" : confirming ? "Confirm turn off" : "Turn off"
                            accessibleName: (circuit.account.disabled ? "Turn on " : "Turn off ")
                                + Fusebox.accountName(circuit.account)
                            onActivated: {
                                if (circuit.account.disabled) {
                                    Fusebox.runAction(circuit.account.id, "toggle", false);
                                } else if (confirming) {
                                    root.confirmOff = "";
                                    Fusebox.runAction(circuit.account.id, "toggle", true);
                                } else {
                                    root.confirmOff = circuit.account.id;
                                }
                            }
                        }
                    }
                    PillButton {
                        anchors.right: parent.right
                        glyph: "open_in_new"
                        label: I18n.tr("Open")
                        accessibleName: "Open " + Fusebox.accountName(circuit.account) + " in the Fusebox dashboard"
                        onActivated: Fusebox.openDashboard("#/accounts/" + encodeURIComponent(circuit.account.id))
                    }
                }
            }
        }
    }

    // A thin rule between the Activity card's blocks.
    component Divider: Item {
        width: parent ? parent.width : 0
        height: Theme.scaled(9)

        Rectangle {
            x: root.pad
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - root.pad * 2
            height: 1
            color: Theme.hairlineSoft
        }
    }

    // A key and address using Fusebox now: requests in flight, an open socket, or
    // a request in the last five minutes.
    component ClientLine: Item {
        id: clientLine

        required property var modelData
        readonly property var entry: modelData

        width: parent ? parent.width : 0
        height: root.lineHeight
        Accessible.role: Accessible.StaticText
        Accessible.name: clientLine.entry.name
        Accessible.description: [clientLine.entry.full, Helpers.connectedState(clientLine.entry, root.now)]
            .filter(part => part).join(", ")

        Rectangle {
            x: root.pad + (Theme.iconMedium - width) / 2
            anchors.verticalCenter: parent.verticalCenter
            width: 7
            height: 7
            radius: 3.5
            color: clientLine.entry.busy ? Theme.ok : Theme.textFaint
        }
        Text {
            id: clientName
            x: root.textX
            anchors.verticalCenter: parent.verticalCenter
            width: Math.min(implicitWidth, (parent.width - x - root.pad) * 0.45)
            elide: Text.ElideRight
            textFormat: Text.PlainText
            text: clientLine.entry.name
            font.family: Theme.fontMenu
            font.pixelSize: Theme.typography.metadata
            font.weight: Theme.weightMedium
            color: Theme.textHi
        }
        Caption {
            anchors.left: clientName.right
            anchors.leftMargin: Theme.scaled(8)
            anchors.baseline: clientName.baseline
            width: Math.max(0, clientState.x - x - Theme.scaled(10))
            font.features: Theme.tabularNumberFeatures
            color: Theme.textLow
            text: clientLine.entry.where
        }
        Caption {
            id: clientState
            anchors.right: parent.right
            anchors.rightMargin: root.pad
            anchors.baseline: clientName.baseline
            font.features: Theme.tabularNumberFeatures
            color: clientLine.entry.busy ? Theme.ok : Theme.textFaint
            text: Helpers.connectedState(clientLine.entry, root.now)
        }
    }

    // A named client's daily token or monthly spending limit, and how far through it is.
    component BudgetLine: Item {
        id: budgetLine

        required property var modelData
        readonly property var entry: modelData

        width: parent ? parent.width : 0
        height: root.lineHeight
        Accessible.role: Accessible.StaticText
        Accessible.name: budgetLine.entry.name
        Accessible.description: budgetLine.entry.text

        Sym {
            x: root.pad + (Theme.iconMedium - Theme.iconSmall) / 2
            anchors.verticalCenter: parent.verticalCenter
            name: "speed"
            size: Theme.iconSmall
            color: Theme.textFaint
        }
        Text {
            id: budgetName
            x: root.textX
            anchors.verticalCenter: parent.verticalCenter
            width: Math.min(implicitWidth, (parent.width - x - root.pad) * 0.3)
            elide: Text.ElideRight
            textFormat: Text.PlainText
            text: budgetLine.entry.name
            font.family: Theme.fontMenu
            font.pixelSize: Theme.typography.metadata
            font.weight: Theme.weightMedium
            color: Theme.textHi
        }
        BlockMeter {
            x: root.textX + (parent.width - root.textX - root.pad) * 0.3 + Theme.scaled(8)
            anchors.verticalCenter: parent.verticalCenter
            width: Math.max(0, budgetText.x - x - Theme.scaled(10))
            height: 5
            blockWidth: 3
            gap: 2
            value: budgetLine.entry.share
            fillColor: root.meterTone(budgetLine.entry.level)
        }
        Caption {
            id: budgetText
            anchors.right: parent.right
            anchors.rightMargin: root.pad
            anchors.verticalCenter: parent.verticalCenter
            font.features: Theme.tabularNumberFeatures
            color: budgetLine.entry.level === "ok" ? Theme.textLow : root.tone(budgetLine.entry.level)
            text: budgetLine.entry.text
        }
    }

    // One finished request on one line: the provider's mark, the model, its
    // account and client key, status and time. A failure's reason follows in
    // red; timing, tokens and tags are read to screen readers, and the typical
    // time to first token is on the load card.
    component RequestLine: Item {
        id: requestLine

        required property var modelData
        readonly property var request: modelData
        readonly property var account: Fusebox.accountById(request.accountId)
        readonly property string result: Helpers.outcome(request)
        readonly property bool showError: result === "failed" && !!request.error
        readonly property real room: Math.max(0, statusPill.x - Theme.scaled(10) - root.textX)

        width: parent ? parent.width : 0
        height: root.lineHeight + (requestLine.showError ? requestError.implicitHeight + Theme.scaled(4) : 0)
        Accessible.role: Accessible.StaticText
        Accessible.name: Helpers.clientLabel(request) + " to " + request.model
        Accessible.description: ["status " + request.status, Helpers.requestMetrics(request),
            Helpers.requestTags(request).join(", "), Helpers.originText(request, Fusebox.hideEmails),
            requestLine.showError ? Fusebox.privateText(request.error) : ""].filter(part => part).join(", ")

        Item {
            width: parent.width
            height: root.lineHeight

            ProviderMark {
                x: root.pad
                anchors.verticalCenter: parent.verticalCenter
                provider: requestLine.request.provider
                size: Theme.iconSmall
            }
            Text {
                id: requestModel
                x: root.textX
                anchors.verticalCenter: parent.verticalCenter
                width: Math.min(implicitWidth, requestLine.room * 0.42)
                elide: Text.ElideRight
                textFormat: Text.PlainText
                text: requestLine.request.model || "—"
                font.family: Theme.fontMono
                font.pixelSize: Theme.typography.metadata
                font.weight: Theme.weightMedium
                color: Theme.textHi
            }
            // The account, then the named client key it came with.
            Caption {
                x: root.textX + requestLine.room * 0.42 + Theme.scaled(8)
                anchors.baseline: requestModel.baseline
                width: Math.max(0, requestLine.room * 0.58 - Theme.scaled(8))
                color: Theme.textLow
                text: [requestLine.account ? Fusebox.accountName(requestLine.account)
                    : Fusebox.privateText(requestLine.request.account) || "No account",
                    requestLine.request.keyLabel ? (Fusebox.hideEmails ? Helpers.HIDDEN : requestLine.request.keyLabel) : ""]
                    .filter(part => part).join(" · ")
            }
            Rectangle {
                id: statusPill
                anchors.right: requestTime.left
                anchors.rightMargin: Theme.scaled(8)
                anchors.verticalCenter: parent.verticalCenter
                width: Theme.scaled(36)
                height: statusText.implicitHeight + Theme.scaled(4)
                radius: height / 2
                color: requestLine.result === "failed" ? Theme.redBgSoft
                    : requestLine.result === "cancelled" ? Theme.hairlineSoft : Theme.okBgSoft

                Text {
                    id: statusText
                    anchors.centerIn: parent
                    text: requestLine.request.status
                    font.family: Theme.fontNumeric
                    font.pixelSize: Theme.typography.metadata
                    font.weight: Theme.weightSemibold
                    font.features: Theme.tabularNumberFeatures
                    color: requestLine.result === "failed" ? Theme.redText
                        : requestLine.result === "cancelled" ? Theme.textDim : Theme.ok
                }
            }
            Caption {
                id: requestTime
                anchors.right: parent.right
                anchors.rightMargin: root.pad
                anchors.baseline: requestModel.baseline
                width: Theme.scaled(38)
                horizontalAlignment: Text.AlignRight
                font.features: Theme.tabularNumberFeatures
                color: Theme.textFaint
                text: Helpers.when(requestLine.request.at, root.now)
            }
        }
        Caption {
            id: requestError
            visible: requestLine.showError
            x: root.textX
            y: root.lineHeight - Theme.scaled(4)
            width: parent.width - x - root.pad
            font.family: Theme.fontMono
            color: Theme.redText
            text: requestLine.showError ? Fusebox.privateText(requestLine.request.error) : ""
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

            BrandIcon {
                anchors.centerIn: parent
                width: Theme.iconLarge
                height: Theme.iconLarge
                name: "fusebox"
                colorized: !root.configured
                tint: Theme.textDim
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
                text: I18n.tr("Fusebox")
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
                    if (!Fusebox.url)
                        return "All your AI subscriptions, one API";
                    const o = Fusebox.overview;
                    return [Fusebox.host, o && o.version ? o.version.replace(/\+.*/, "") : "",
                        o && o.startedAt ? "up " + Helpers.span(root.now - o.startedAt) : ""]
                        .filter(part => part !== "").join(" · ");
                }
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.secondary
                color: Theme.textLow
            }
        }
        Rectangle {
            id: pill

            readonly property string connection: Fusebox.connection
            readonly property color tint: connection === "live" ? Theme.ok
                : Fusebox.troubled ? Theme.redText : connection === "restarting" ? Theme.amber : Theme.textDim

            visible: root.configured
            anchors.right: privacy.left
            anchors.rightMargin: Theme.scaled(6)
            anchors.verticalCenter: parent.verticalCenter
            width: pillRow.implicitWidth + Theme.scaled(18)
            height: Theme.scaled(24)
            radius: height / 2
            color: connection === "live" ? Theme.okBgSoft
                : Fusebox.troubled ? Theme.redBgSoft : connection === "restarting" ? Theme.amberBgSoft : Theme.chip
            Accessible.role: Accessible.StaticText
            Accessible.name: I18n.tr("Connection")
            Accessible.description: Fusebox.status

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
                        running: (pill.connection === "connecting" || pill.connection === "restarting"
                            || (pill.connection === "offline" && !Fusebox.troubled)) && !Theme.reducedMotion
                        loops: Animation.Infinite
                        onRunningChanged: if (!running) pillDot.opacity = 1
                        NumberAnimation { from: 1; to: 0.3; duration: 700; easing.type: Easing.InOutSine }
                        NumberAnimation { from: 0.3; to: 1; duration: 700; easing.type: Easing.InOutSine }
                    }
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: ({ live: "Live", offline: Fusebox.hasData ? "Reconnecting" : "Offline",
                        auth: "Key rejected", locked: "Locked out", restarting: "Restarting",
                        connecting: "Connecting" })[pill.connection] || ""
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.metadata
                    font.weight: Theme.weightSemibold
                    color: pill.tint
                }
            }
        }
        // Account labels are usually emails: hide them before sharing a screen.
        Rectangle {
            id: privacy
            visible: root.configured
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: visible ? Theme.scaled(28) : 0
            height: Theme.scaled(28)
            radius: Theme.chipRadius
            color: privacyMouse.containsMouse || privacy.activeFocus ? Theme.hoverFill : "transparent"
            border.width: privacy.activeFocus ? 1 : 0
            border.color: Theme.accentText
            activeFocusOnTab: visible
            Accessible.role: Accessible.CheckBox
            Accessible.name: I18n.tr("Hide account emails")
            Accessible.checkable: true
            Accessible.checked: Fusebox.hideEmails
            Accessible.onPressAction: Settings.setModuleOption("fusebox", "hideEmails", !Fusebox.hideEmails)
            Keys.onPressed: event => {
                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                    Settings.setModuleOption("fusebox", "hideEmails", !Fusebox.hideEmails);
                    event.accepted = true;
                }
            }

            Sym {
                anchors.centerIn: parent
                name: Fusebox.hideEmails ? "visibility_off" : "visibility"
                size: Theme.iconMedium
                color: Theme.textLow
            }
            MouseArea {
                id: privacyMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: Settings.setModuleOption("fusebox", "hideEmails", !Fusebox.hideEmails)
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

            // Nothing to connect to yet.
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
                    text: Fusebox.url && Fusebox.error ? Fusebox.error
                        : "Enter your Fusebox server's address and management key. The key is kept in a private file on this computer and only ever sent to that server."
                    lineHeight: Theme.proseLineHeight
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.secondary
                    color: Theme.textLow
                }
                ActionButton {
                    anchors.horizontalCenter: parent.horizontalCenter
                    label: I18n.tr("Set up Fusebox")
                    tint: Theme.accentText
                    onTriggered: Fusebox.configure()
                }
            }

            // Why the readings are missing or old. A rejected key, a lockout or a
            // lost connection is red wherever it shows: here, the pill and the
            // badge. A restart is amber: Fusebox said it is coming back.
            Rectangle {
                id: problemBox

                readonly property bool restart: Fusebox.connection === "restarting"
                readonly property bool lockedOut: Fusebox.connection === "locked"
                readonly property bool needsKey: Fusebox.connection === "auth" || Fusebox.connection === "locked"

                visible: root.configured && Fusebox.problemShown
                width: parent.width
                height: problem.implicitHeight + Theme.scaled(22)
                radius: Theme.chipRadius
                color: problemBox.restart ? Theme.amberBgSoft : Theme.redBgSoft
                border.width: 1
                border.color: problemBox.restart ? Theme.amberBorder : Theme.redBorder

                Sym {
                    x: root.pad
                    y: Theme.scaled(11) + (problemTitle.implicitHeight - height) / 2
                    name: problemBox.restart ? "restart_alt" : problemBox.lockedOut ? "lock" : "error"
                    size: Theme.iconMedium
                    color: problemBox.restart ? Theme.amber : Theme.redText
                }
                Column {
                    id: problem
                    x: root.textX
                    y: Theme.scaled(11)
                    width: parent.width - x - (problemAction.visible ? problemAction.width : 0) - Theme.scaled(22)
                    spacing: Theme.scaled(3)

                    Text {
                        id: problemTitle
                        width: parent.width
                        wrapMode: Text.Wrap
                        textFormat: Text.PlainText
                        text: {
                            switch (Fusebox.connection) {
                            case "auth": return "Fusebox didn't accept the key";
                            case "locked": return "Locked out after wrong keys";
                            case "restarting": return "Fusebox is restarting";
                            default: return Fusebox.hasData ? "Connection lost · showing the last update"
                                : "Can't reach " + Fusebox.host;
                            }
                        }
                        font.family: Theme.fontMenu
                        font.pixelSize: Theme.typography.secondary
                        font.weight: Theme.weightSemibold
                        color: problemBox.restart ? Theme.amber : Theme.redText
                    }
                    Text {
                        width: parent.width
                        wrapMode: Text.Wrap
                        textFormat: Text.PlainText
                        text: {
                            switch (Fusebox.connection) {
                            case "auth":
                                return Fusebox.error + " The widget won't try this key again, so Fusebox doesn't lock this computer out. Enter the right key in Settings.";
                            case "locked":
                                return "Fusebox turns this computer away for "
                                    + (Fusebox.lockedUntil > root.now ? Helpers.span(Fusebox.lockedUntil - root.now) : "a moment")
                                    + " more, then the widget tries once. Each wrong key locks it out for longer.";
                            case "restarting":
                                return Fusebox.hasData ? "Showing the last update until it's back." : "Reconnecting as soon as it's back.";
                            default:
                                return Fusebox.error;
                            }
                        }
                        font.family: Theme.fontMenu
                        font.pixelSize: Theme.typography.metadata
                        color: Theme.textMid
                    }
                }
                ActionButton {
                    id: problemAction
                    visible: !problemBox.restart
                    anchors.right: parent.right
                    anchors.rightMargin: root.pad
                    anchors.verticalCenter: parent.verticalCenter
                    label: problemBox.needsKey ? "Settings" : "Retry"
                    tint: Theme.redText
                    onTriggered: problemBox.needsKey ? Fusebox.configure() : Fusebox.refresh()
                }
            }

            Rectangle {
                visible: root.configured && Fusebox.connection === "connecting" && !Fusebox.hasData
                width: parent.width
                height: Theme.scaled(64)
                radius: Theme.chipRadius
                color: Theme.chip

                Caption {
                    anchors.centerIn: parent
                    width: Math.min(implicitWidth, parent.width - Theme.scaled(24))
                    text: "Connecting to " + Fusebox.host + "…"
                    color: Theme.textLow
                }
            }

            Column {
                visible: root.configured && Fusebox.hasData
                width: parent.width
                spacing: Theme.panelSectionSpacing
                opacity: root.dimmed ? 0.6 : 1

                Behavior on opacity {
                    NumberAnimation { duration: Theme.chipFadeDuration }
                }

                // ---- what has tripped ----
                Column {
                    visible: Fusebox.faults.length > 0
                    width: parent.width
                    spacing: Theme.scaled(6)

                    // Dismissed faults are one click from coming back.
                    SectionTitle {
                        label: I18n.tr("Faults")
                        detail: Fusebox.dismissedCount > 0 ? Fusebox.dismissedCount + " dismissed" : ""
                        action: Fusebox.dismissedCount > 0 ? "Show" : ""
                        actionName: "Show dismissed faults again"
                        onActed: Fusebox.restoreFaults()
                    }
                    Repeater {
                        model: Fusebox.shownFaults
                        FaultRow {}
                    }
                    Caption {
                        visible: Fusebox.faultSource === "accounts" && Fusebox.shownFaults.length > 0
                        x: root.pad
                        width: parent.width - root.pad * 2
                        wrapMode: Text.Wrap
                        elide: Text.ElideNone
                        color: Theme.textFaint
                        text: I18n.tr("From account state. Update Fusebox to also see failed-request and provider faults.")
                    }
                }

                // ---- load: the figures over the hour's chart, on one card ----
                Rectangle {
                    width: parent.width
                    height: loadCard.implicitHeight + root.pad * 2
                    radius: Theme.chipRadius
                    color: Theme.chip

                    Column {
                        id: loadCard
                        x: root.pad
                        y: root.pad
                        width: parent.width - root.pad * 2
                        spacing: Theme.scaled(8)

                        // Keyed by count: the values move with every request.
                        Flow {
                            width: parent.width
                            spacing: Theme.scaled(14)

                            Repeater {
                                model: root.loadFigures.length

                                Item {
                                    id: loadFigure

                                    required property int index
                                    readonly property var fact: root.loadFigures[index] || ({ value: "", label: "" })

                                    width: figureValue.implicitWidth + Theme.scaled(4) + figureLabel.implicitWidth
                                    height: figureValue.implicitHeight
                                    Accessible.role: Accessible.StaticText
                                    Accessible.name: loadFigure.fact.value + " " + loadFigure.fact.label

                                    Figure {
                                        id: figureValue
                                        text: loadFigure.fact.value
                                        color: root.tone(loadFigure.fact.level || "ok")
                                    }
                                    Caption {
                                        id: figureLabel
                                        anchors.left: figureValue.right
                                        anchors.leftMargin: Theme.scaled(4)
                                        anchors.baseline: figureValue.baseline
                                        color: Theme.textLow
                                        text: loadFigure.fact.label
                                    }
                                }
                            }
                        }
                        LoadBars {
                            width: parent.width
                            height: Theme.scaled(40)
                            bars: root.loadBars
                            peak: root.loadPeak
                            Accessible.role: Accessible.Graphic
                            Accessible.name: I18n.tr("Requests per minute, last 60 minutes")
                            Accessible.description: Helpers.number(root.loadTotal) + " requests, at most "
                                + root.loadPeak + " in a minute"
                        }
                        Item {
                            width: parent.width
                            height: axisStart.implicitHeight

                            Caption {
                                id: axisStart
                                font.features: Theme.tabularNumberFeatures
                                color: Theme.textFaint
                                text: "Last 60 min · " + Helpers.number(root.loadTotal)
                                    + (root.loadTotal === 1 ? " request" : " requests")
                            }
                            Caption {
                                anchors.right: parent.right
                                text: "now"
                                color: Theme.textFaint
                            }
                        }
                    }
                }

                // ---- accounts, by provider ----
                Column {
                    width: parent.width
                    spacing: Theme.scaled(2)

                    Item {
                        width: parent.width
                        height: Math.max(accountsTitle.height, quotaSwitch.visible ? quotaSwitch.height : 0)

                        SectionTitle {
                            id: accountsTitle
                            anchors.verticalCenter: parent.verticalCenter
                            label: I18n.tr("Accounts")
                        }
                        QuotaSwitch {
                            id: quotaSwitch
                            visible: Fusebox.accounts.some(a => a.windows.length > 0)
                            anchors.right: parent.right
                            anchors.rightMargin: root.pad
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }
                    Caption {
                        visible: Fusebox.accounts.length === 0
                        x: root.pad
                        width: parent.width - root.pad * 2
                        color: Theme.textLow
                        text: I18n.tr("No accounts yet. Connect one in the Fusebox dashboard.")
                    }
                    Repeater {
                        model: root.groups

                        Column {
                            id: groupBlock

                            required property var modelData

                            width: parent ? parent.width : 0

                            GroupHead { group: groupBlock.modelData }
                            Repeater {
                                model: groupBlock.modelData.accounts
                                AccountRow { showPlan: !groupBlock.modelData.uniformPlan }
                            }
                        }
                    }
                }

                // ---- activity: who is connected, budgets and the latest requests ----
                Column {
                    width: parent.width
                    spacing: Theme.scaled(6)

                    SectionTitle {
                        label: I18n.tr("Activity")
                        detail: [Fusebox.clients !== null
                            ? root.connected.length + (root.connected.length === 1 ? " client" : " clients") : "",
                            Fusebox.totals ? Helpers.number(Fusebox.totals.requests) + " requests since start" : ""]
                            .filter(part => part).join(" · ")
                    }
                    Caption {
                        visible: !activityCard.visible
                        x: root.pad
                        width: parent.width - root.pad * 2
                        color: Theme.textLow
                        text: I18n.tr("Requests appear here as they finish.")
                    }
                    Rectangle {
                        id: activityCard
                        visible: root.latest.length > 0 || root.connected.length > 0 || root.budgets.length > 0
                        width: parent.width
                        height: activityRows.implicitHeight + Theme.scaled(8)
                        radius: Theme.chipRadius
                        color: Theme.chip

                        Column {
                            id: activityRows
                            y: Theme.scaled(4)
                            width: parent.width

                            Repeater {
                                model: root.connected
                                ClientLine {}
                            }
                            Divider { visible: root.connected.length > 0 && (root.budgets.length > 0 || root.latest.length > 0) }
                            Repeater {
                                model: root.budgets
                                BudgetLine {}
                            }
                            Divider { visible: root.budgets.length > 0 && root.latest.length > 0 }
                            Repeater {
                                model: root.latest
                                RequestLine {}
                            }
                        }
                    }
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
            anchors.leftMargin: root.pad
            anchors.right: actions.left
            anchors.rightMargin: Theme.scaled(10)
            anchors.verticalCenter: parent.verticalCenter
            anchors.verticalCenterOffset: 1
            text: {
                switch (Fusebox.connection) {
                case "setup": return "Not connected yet";
                case "connecting": return "Connecting…";
                case "live": return "Live · updated " + Helpers.ago(root.now - Fusebox.updatedAt);
                case "auth": return "Waiting for a new key";
                case "locked": return Fusebox.lockedUntil > 0 ? "Trying again at " + Helpers.when(Fusebox.lockedUntil, root.now)
                    : "Locked out";
                default: return Fusebox.hasData ? "Last update " + Helpers.ago(root.now - Fusebox.updatedAt)
                    : "Retrying automatically";
                }
            }
            color: Theme.textFaint
        }
        Row {
            id: actions
            anchors.right: parent.right
            anchors.rightMargin: root.pad
            anchors.verticalCenter: parent.verticalCenter
            anchors.verticalCenterOffset: 1
            spacing: Theme.scaled(16)

            LinkText {
                visible: Fusebox.url !== ""
                text: I18n.tr("Dashboard ↗")
                accessibleName: "Open the Fusebox dashboard"
                onClicked: Fusebox.openDashboard("")
            }
            LinkText {
                text: I18n.tr("Settings")
                accessibleName: "Fusebox settings"
                onClicked: Fusebox.configure()
            }
        }
    }
}
