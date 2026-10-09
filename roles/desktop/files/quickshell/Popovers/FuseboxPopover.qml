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
    readonly property bool dimmed: Fusebox.stale
    readonly property double now: Fusebox.now
    readonly property var circuits: Helpers.groupAccounts(Fusebox.accounts)
    readonly property var latest: Fusebox.requests.slice(0, 6)
    readonly property var loadBars: Helpers.bars(Fusebox.series, now)
    readonly property int loadPeak: Math.max(4, ...loadBars.map(b => b.requests))
    readonly property int loadTotal: loadBars.reduce((sum, b) => sum + b.requests, 0)
    readonly property int gutter: Theme.panelPadding
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
    component SectionTitle: Item {
        id: section

        property string label: ""
        property string detail: ""

        width: parent ? parent.width : 0
        height: sectionLabel.implicitHeight

        Text {
            id: sectionLabel
            text: section.label.toUpperCase()
            font.family: Theme.fontMenu
            font.pixelSize: Theme.typography.section
            font.weight: Theme.weightSemibold
            font.letterSpacing: 1
            color: Theme.textFaint
        }
        Caption {
            anchors.right: parent.right
            anchors.baseline: sectionLabel.baseline
            width: Math.min(implicitWidth, parent.width - sectionLabel.implicitWidth - Theme.scaled(12))
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

    // A 5-hour or weekly quota meter: 20 blocks of 5%, filled and labelled with
    // the share used or left. Amber from 75% used and red from 95%, either way.
    component QuotaMeter: Row {
        id: meter

        required property var account
        property bool short: true
        readonly property var window: Helpers.windowOf(meter.account, meter.short, root.now)
        readonly property var reading: Helpers.quota(meter.window, root.now)
        readonly property var share: Helpers.quotaShare(meter.reading, Fusebox.quotaDisplay)

        spacing: Theme.scaled(6)
        Accessible.role: Accessible.StaticText
        Accessible.name: Helpers.windowTitle(meter.window || { name: meter.short ? "5h" : "week" }) + " quota"
        Accessible.description: meter.reading ? Helpers.percent(meter.share) + " " + Helpers.quotaWord(Fusebox.quotaDisplay)
            + (meter.window.resetsAt ? ", resets in " + Helpers.span(meter.window.resetsAt - root.now) : "")
            : "not reported"

        Text {
            anchors.verticalCenter: parent.verticalCenter
            width: Theme.scaled(22)
            text: Helpers.windowLabel(meter.window, meter.short)
            font.family: Theme.fontMenu
            font.pixelSize: Theme.typography.section
            font.weight: Theme.weightSemibold
            font.letterSpacing: 0.5
            color: Theme.textFaint
        }
        BlockMeter {
            anchors.verticalCenter: parent.verticalCenter
            // Exactly twenty blocks of five percent.
            width: 20 * 5 - 2
            height: 7
            blockWidth: 3
            gap: 2
            value: meter.reading ? meter.share / 100 : 0
            fillColor: root.meterTone(meter.reading ? meter.reading.level : "ok")
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            width: Theme.scaled(30)
            text: meter.reading ? Helpers.percent(meter.share) : "–"
            horizontalAlignment: Text.AlignRight
            font.family: Theme.fontNumeric
            font.pixelSize: Theme.typography.metadata
            font.weight: Theme.weightMedium
            font.features: Theme.tabularNumberFeatures
            color: meter.reading ? root.tone(meter.reading.level) : Theme.textFaint
        }
    }

    // Fusebox's Used / Left switch for every meter, as a two-segment radio.
    component QuotaSwitch: Rectangle {
        id: quotaSwitch

        width: quotaRow.implicitWidth + 4
        height: Theme.scaled(22)
        radius: Theme.chipRadius
        color: Theme.chip
        Accessible.role: Accessible.Grouping
        Accessible.name: "Quota meters"

        Row {
            id: quotaRow
            anchors.centerIn: parent
            spacing: 2

            Repeater {
                id: quotaSegments
                model: Helpers.QUOTA_DISPLAYS

                Rectangle {
                    id: segment

                    required property var modelData
                    required property int index
                    readonly property bool current: Fusebox.quotaDisplay === modelData.value
                    readonly property string word: segment.modelData.value === "remaining" ? "Left" : segment.modelData.label

                    function pick(value) {
                        Fusebox.setQuotaDisplay(value);
                    }
                    // Arrow keys move the choice and the focus together.
                    function step(value) {
                        segment.pick(value);
                        const next = quotaSegments.itemAt(value === "remaining" ? 1 : 0);
                        if (next)
                            next.forceActiveFocus();
                    }

                    width: segmentText.implicitWidth + Theme.scaled(14)
                    height: quotaSwitch.height - 4
                    radius: Theme.chipRadius - 2
                    color: segment.current ? Theme.chipHover
                        : segmentMouse.containsMouse ? Theme.hoverFill : "transparent"
                    border.width: segment.activeFocus ? 1 : 0
                    border.color: Theme.accentText
                    activeFocusOnTab: segment.current
                    Accessible.role: Accessible.RadioButton
                    Accessible.name: "Show quota " + (segment.modelData.value === "remaining" ? "remaining" : "used")
                    Accessible.checked: segment.current
                    Accessible.onPressAction: segment.pick(segment.modelData.value)
                    Keys.onPressed: event => {
                        if (event.key === Qt.Key_Left || event.key === Qt.Key_Right) {
                            segment.step(event.key === Qt.Key_Left ? "used" : "remaining");
                            event.accepted = true;
                        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                                || event.key === Qt.Key_Space) {
                            segment.pick(segment.modelData.value);
                            event.accepted = true;
                        }
                    }

                    Behavior on color {
                        ColorAnimation { duration: Theme.chipFadeDuration }
                    }

                    Text {
                        id: segmentText
                        anchors.centerIn: parent
                        text: segment.word
                        font.family: Theme.fontMenu
                        font.pixelSize: Theme.typography.metadata
                        font.weight: segment.current ? Theme.weightSemibold : Theme.weightMedium
                        color: segment.current ? Theme.textHi : Theme.textDim
                    }
                    MouseArea {
                        id: segmentMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: segment.pick(segment.modelData.value)
                    }
                }
            }
        }
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
                        return "Clears a usage limit early. Always asks before spending.";
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
                    label: "Back"
                    accessibleName: "Back, without changing anything"
                    onActivated: Fusebox.cancelReset(panel.account.id)
                }
                PillButton {
                    visible: panel.mode === "summary"
                    enabled: !panel.busy
                    glyph: "restart_alt"
                    label: panel.mine ? "Checking…" : "Details"
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
                    label: "Retry request"
                    onActivated: Fusebox.beginRecovery(panel.account.id, "retry")
                }
                PillButton {
                    visible: panel.mode === "review" && panel.operation !== null && !!panel.operation.requestId
                    enabled: !panel.busy
                    label: "Check outcome"
                    onActivated: Fusebox.beginRecovery(panel.account.id, "resolve")
                }
                PillButton {
                    visible: panel.mode === "review" && panel.view === null
                    enabled: !panel.busy
                    glyph: "warning"
                    label: panel.mine ? "Checking…" : "Review"
                    onActivated: Fusebox.loadReset(panel.account.id)
                }
                PillButton {
                    visible: panel.mode === "redeem"
                    // Hidden buttons still evaluate their bindings: guard the dialog.
                    enabled: !panel.busy && panel.dialog !== null
                        && (panel.account.provider === "codex" || panel.dialog.grant !== "")
                    danger: true
                    label: panel.mine ? "Applying…" : "Apply reset"
                    accessibleName: "Apply one banked reset to " + Fusebox.accountName(panel.account) + ". This can't be undone."
                    onActivated: Fusebox.confirmReset(panel.account.id)
                }
                PillButton {
                    visible: panel.mode === "retry"
                    enabled: !panel.busy
                    danger: true
                    label: panel.mine ? "Retrying…" : "Confirm retry"
                    onActivated: Fusebox.confirmReset(panel.account.id)
                }
                PillButton {
                    visible: panel.mode === "resolve"
                    enabled: !panel.busy
                    label: "Reset was used"
                    onActivated: Fusebox.confirmReset(panel.account.id, "resolve-used")
                }
                PillButton {
                    visible: panel.mode === "resolve"
                    enabled: !panel.busy
                    label: "No reset was used"
                    onActivated: Fusebox.confirmReset(panel.account.id, "resolve-unused")
                }
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
            }
        }

        Sym {
            x: Theme.scaled(11)
            y: Theme.scaled(10)
            name: faultRow.serious ? "error" : "warning"
            size: Theme.iconMedium
            color: faultRow.serious ? Theme.redText : Theme.amber
        }
        Column {
            id: faultText
            x: Theme.scaled(36)
            y: Theme.scaled(9)
            width: parent.width - x - Theme.scaled(30)
            spacing: Theme.scaled(2)

            Text {
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
            anchors.right: parent.right
            anchors.rightMargin: Theme.scaled(10)
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
    }

    component AccountRow: Rectangle {
        id: circuit

        required property var modelData
        readonly property var account: modelData
        readonly property var circuitState: Helpers.accountState(account, Fusebox.load, root.now)
        readonly property bool open: root.expanded === account.id
        readonly property int sessionCount: Helpers.sessions(account, Fusebox.load)
        readonly property bool metered: account.windows.length > 0
        readonly property var detail: Fusebox.activity[account.id] || null
        readonly property bool acting: Fusebox.actionBusy && Fusebox.actionAccount === account.id
        readonly property var result: Fusebox.actionResult && Fusebox.actionResult.account === account.id
            ? Fusebox.actionResult : null

        width: parent ? parent.width : 0
        height: circuitBody.implicitHeight + Theme.scaled(16)
        radius: Theme.chipRadius
        color: circuit.open ? Theme.chip : circuitMouse.containsMouse ? Theme.hoverFill : "transparent"
        opacity: account.disabled ? 0.7 : 1

        Behavior on color {
            ColorAnimation { duration: Theme.chipFadeDuration }
        }

        // The whole head is the disclosure; the breaker buttons below sit
        // outside it so they never also toggle the row.
        MouseArea {
            id: circuitMouse
            x: 0
            y: 0
            width: parent.width
            height: circuitBody.y + head.height + (meters.visible ? circuitBody.spacing + meters.height : 0)
                + Theme.scaled(6)
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.toggle(circuit.account.id)
        }

        Column {
            id: circuitBody
            x: Theme.scaled(10)
            y: Theme.scaled(8)
            width: parent.width - x * 2
            spacing: Theme.scaled(6)

            Item {
                id: head
                width: parent.width
                height: Math.max(nameText.implicitHeight, Theme.iconMedium)
                activeFocusOnTab: true
                Accessible.role: Accessible.Button
                Accessible.name: Fusebox.accountName(circuit.account) + ", " + Helpers.providerName(circuit.account)
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
                Item {
                    id: providerMark
                    anchors.verticalCenter: parent.verticalCenter
                    width: Theme.iconMedium
                    height: Theme.iconMedium

                    BrandIcon {
                        id: providerIcon
                        visible: providerIcon.available
                        anchors.fill: parent
                        name: Helpers.providerMark(circuit.account.provider)
                    }
                    Sym {
                        visible: Helpers.providerMark(circuit.account.provider) === ""
                        anchors.centerIn: parent
                        name: circuit.account.kind === "api-key" ? "key" : "account_circle"
                        size: Theme.iconMedium
                        color: Theme.textLow
                    }
                }
                Text {
                    id: nameText
                    anchors.left: providerMark.right
                    anchors.leftMargin: Theme.scaled(8)
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.min(implicitWidth, parent.width - x - planTag.width - reviewTag.width
                        - statusRow.width - Theme.scaled(26))
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                    text: Fusebox.accountName(circuit.account)
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.secondary
                    font.weight: Theme.weightSemibold
                    color: Theme.textHi
                }
                Rectangle {
                    id: planTag
                    readonly property string plan: Helpers.planName(circuit.account)
                    visible: plan !== ""
                    anchors.left: nameText.right
                    anchors.leftMargin: Theme.scaled(6)
                    anchors.verticalCenter: parent.verticalCenter
                    width: visible ? planText.implicitWidth + Theme.scaled(10) : 0
                    height: planText.implicitHeight + Theme.scaled(2)
                    radius: Theme.scaled(4)
                    color: Theme.hairlineSoft

                    Text {
                        id: planText
                        anchors.centerIn: parent
                        text: planTag.plan
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
                        text: "Review reset"
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

            Row {
                id: meters
                visible: circuit.metered
                x: providerMark.width + Theme.scaled(8)
                spacing: Theme.scaled(14)

                QuotaMeter { account: circuit.account; short: true }
                QuotaMeter { account: circuit.account; short: false }
            }

            // ---- details ----
            Column {
                id: details
                visible: circuit.open
                x: providerMark.width + Theme.scaled(8)
                width: parent.width - x
                topPadding: Theme.scaled(4)
                spacing: Theme.scaled(8)

                readonly property var series: circuit.detail && circuit.detail.series ? circuit.detail.series : []
                readonly property var accountBars: Helpers.bars(details.series, root.now)
                readonly property int accountTotal: details.accountBars.reduce((sum, b) => sum + b.requests, 0)
                readonly property string pauses: Helpers.pauseText(circuit.account, root.now)
                readonly property var resets: Helpers.resetFacts(circuit.account, root.now)

                Caption {
                    width: parent.width
                    font.features: Theme.tabularNumberFeatures
                    color: Theme.textLow
                    text: Helpers.accountSubtitle(circuit.account, root.now)
                }
                FactStrip {
                    fill: root.surfaceColor
                    facts: Helpers.accountFacts(circuit.account, circuit.detail, root.now)
                }
                FactStrip {
                    visible: details.resets.length > 0
                    fill: root.surfaceColor
                    facts: details.resets
                }

                // The account's own hour, from its activity.
                Column {
                    visible: details.series.length > 0
                    width: parent.width
                    spacing: Theme.scaled(5)

                    SectionTitle {
                        label: "Load · last 60 min"
                        detail: Helpers.number(details.accountTotal) + (details.accountTotal === 1 ? " request" : " requests")
                    }
                    LoadBars {
                        width: parent.width
                        height: Theme.scaled(26)
                        bars: details.accountBars
                        peak: Math.max(2, ...details.accountBars.map(b => b.requests))
                        Accessible.role: Accessible.Graphic
                        Accessible.name: "Requests per minute on this account, last 60 minutes"
                        Accessible.description: Helpers.number(details.accountTotal) + " requests"
                    }
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
                    title: circuit.circuitState.signin ? "Sign-in expired" : "Last error"
                    body: Fusebox.privateText(circuit.account.lastError)

                    // Signing in again needs the dashboard: its redirects go to the server.
                    PillButton {
                        visible: !!circuit.circuitState.signin
                        label: "Sign in"
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
                        label: "Open"
                        accessibleName: "Open " + Fusebox.accountName(circuit.account) + " in the Fusebox dashboard"
                        onActivated: Fusebox.openDashboard("#/accounts/" + encodeURIComponent(circuit.account.id))
                    }
                }
            }
        }
    }

    // One finished request, as the dashboard's latest requests show it: who served
    // it, the model and client, its status and time; the account and its timing
    // and tokens beneath; a failure's reason in red.
    component RequestRow: Item {
        id: requestRow

        required property var modelData
        required property int index
        readonly property var request: modelData
        readonly property var account: Fusebox.accountById(request.accountId)
        readonly property string result: Helpers.outcome(request)
        readonly property bool showError: result === "failed" && !!request.error
        readonly property var tags: [Helpers.clientLabel(request)].concat(Helpers.requestTags(request))
        readonly property string mark: Helpers.providerMark(request.provider)

        width: parent ? parent.width : 0
        height: requestBody.implicitHeight + Theme.scaled(18)
        Accessible.role: Accessible.StaticText
        Accessible.name: Helpers.clientLabel(request) + " to " + request.model
        Accessible.description: ["status " + request.status, Helpers.requestMetrics(request),
            requestRow.showError ? Fusebox.privateText(request.error) : ""].filter(part => part).join(", ")

        Rectangle {
            visible: requestRow.index > 0
            x: Theme.scaled(12)
            width: parent.width - x * 2
            height: 1
            color: Theme.hairlineSoft
        }
        Item {
            id: requestMark
            x: Theme.scaled(12)
            y: Theme.scaled(10)
            width: Theme.iconMedium
            height: Theme.iconMedium

            BrandIcon {
                visible: requestRow.mark !== ""
                anchors.fill: parent
                name: requestRow.mark
            }
            Sym {
                visible: requestRow.mark === ""
                anchors.centerIn: parent
                name: "api"
                size: Theme.iconMedium
                color: Theme.textLow
            }
        }
        Column {
            id: requestBody
            x: requestMark.x + requestMark.width + Theme.scaled(10)
            y: Theme.scaled(9)
            width: parent.width - x - Theme.scaled(12)
            spacing: Theme.scaled(3)

            Item {
                width: parent.width
                height: Math.max(modelText.implicitHeight, statusPill.height)

                Text {
                    id: modelText
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.min(implicitWidth, parent.width - tagRow.implicitWidth - lineEnd.width - Theme.scaled(16))
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                    text: requestRow.request.model || "—"
                    font.family: Theme.fontMono
                    font.pixelSize: Theme.typography.secondary
                    font.weight: Theme.weightMedium
                    color: Theme.textHi
                }
                Row {
                    id: tagRow
                    anchors.left: modelText.right
                    anchors.leftMargin: Theme.scaled(7)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.scaled(4)

                    Repeater {
                        model: requestRow.tags

                        Rectangle {
                            id: tag
                            required property var modelData
                            width: tagText.implicitWidth + Theme.scaled(10)
                            height: tagText.implicitHeight + Theme.scaled(3)
                            radius: Theme.scaled(4)
                            color: Theme.hairlineSoft

                            Text {
                                id: tagText
                                anchors.centerIn: parent
                                text: tag.modelData
                                textFormat: Text.PlainText
                                font.family: Theme.fontMenu
                                font.pixelSize: Theme.typography.section
                                font.weight: Theme.weightSemibold
                                color: Theme.textLow
                            }
                        }
                    }
                }
                Row {
                    id: lineEnd
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.scaled(8)

                    Rectangle {
                        id: statusPill
                        anchors.verticalCenter: parent.verticalCenter
                        width: statusText.implicitWidth + Theme.scaled(12)
                        height: statusText.implicitHeight + Theme.scaled(4)
                        radius: height / 2
                        color: requestRow.result === "failed" ? Theme.redBgSoft
                            : requestRow.result === "cancelled" ? Theme.hairlineSoft : Theme.okBgSoft

                        Text {
                            id: statusText
                            anchors.centerIn: parent
                            text: requestRow.request.status
                            font.family: Theme.fontNumeric
                            font.pixelSize: Theme.typography.metadata
                            font.weight: Theme.weightSemibold
                            font.features: Theme.tabularNumberFeatures
                            color: requestRow.result === "failed" ? Theme.redText
                                : requestRow.result === "cancelled" ? Theme.textDim : Theme.ok
                        }
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: Helpers.when(requestRow.request.at, root.now)
                        font.family: Theme.fontNumeric
                        font.pixelSize: Theme.typography.metadata
                        font.features: Theme.tabularNumberFeatures
                        color: Theme.textFaint
                    }
                }
            }
            Item {
                width: parent.width
                height: requestAccount.implicitHeight

                Caption {
                    id: requestAccount
                    width: Math.min(implicitWidth, parent.width - requestMetrics.implicitWidth - Theme.scaled(12))
                    color: Theme.textLow
                    text: requestRow.account ? Fusebox.accountName(requestRow.account)
                        : Fusebox.privateText(requestRow.request.account) || "No account"
                }
                Caption {
                    id: requestMetrics
                    anchors.right: parent.right
                    font.features: Theme.tabularNumberFeatures
                    color: Theme.textFaint
                    text: Helpers.requestMetrics(requestRow.request)
                }
            }
            Caption {
                visible: requestRow.showError
                width: parent.width
                font.family: Theme.fontMono
                color: Theme.redText
                text: requestRow.showError ? Fusebox.privateText(requestRow.request.error) : ""
            }
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
                text: "Fusebox"
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
                : connection === "offline" || connection === "auth" ? Theme.redText : Theme.textDim

            visible: root.configured
            anchors.right: privacy.left
            anchors.rightMargin: Theme.scaled(6)
            anchors.verticalCenter: parent.verticalCenter
            width: pillRow.implicitWidth + Theme.scaled(18)
            height: Theme.scaled(24)
            radius: height / 2
            color: connection === "live" ? Theme.okBgSoft
                : connection === "offline" || connection === "auth" ? Theme.redBgSoft : Theme.chip
            Accessible.role: Accessible.StaticText
            Accessible.name: "Connection"
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
                        running: pill.connection === "connecting" && !Theme.reducedMotion
                        loops: Animation.Infinite
                        onRunningChanged: if (!running) pillDot.opacity = 1
                        NumberAnimation { from: 1; to: 0.3; duration: 700; easing.type: Easing.InOutSine }
                        NumberAnimation { from: 0.3; to: 1; duration: 700; easing.type: Easing.InOutSine }
                    }
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: ({ live: "Live", offline: Fusebox.hasData ? "Reconnecting" : "Offline",
                        auth: "Key rejected", connecting: "Connecting" })[pill.connection] || ""
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
            Accessible.name: "Hide account emails"
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
                    label: "Set up Fusebox"
                    tint: Theme.accentText
                    onTriggered: Fusebox.configure()
                }
            }

            // Why the readings are missing or old. A rejected key or a lost
            // connection is red wherever it shows: here, the pill and the badge.
            Rectangle {
                visible: root.configured && Fusebox.error !== "" && Fusebox.connection !== "live"
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
                    width: parent.width - x - problemAction.width - Theme.scaled(22)
                    spacing: Theme.scaled(3)

                    Text {
                        width: parent.width
                        wrapMode: Text.Wrap
                        textFormat: Text.PlainText
                        text: Fusebox.connection === "auth" ? "Fusebox didn't accept the key"
                            : Fusebox.hasData ? "Connection lost · showing the last update"
                            : "Can't reach " + Fusebox.host
                        font.family: Theme.fontMenu
                        font.pixelSize: Theme.typography.secondary
                        font.weight: Theme.weightSemibold
                        color: Theme.redText
                    }
                    Text {
                        width: parent.width
                        wrapMode: Text.Wrap
                        textFormat: Text.PlainText
                        text: Fusebox.error
                        font.family: Theme.fontMenu
                        font.pixelSize: Theme.typography.metadata
                        color: Theme.textMid
                    }
                }
                ActionButton {
                    id: problemAction
                    anchors.right: parent.right
                    anchors.rightMargin: Theme.scaled(10)
                    anchors.verticalCenter: parent.verticalCenter
                    label: Fusebox.connection === "auth" ? "Settings" : "Retry"
                    tint: Theme.redText
                    onTriggered: Fusebox.connection === "auth" ? Fusebox.configure() : Fusebox.refresh()
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

                    Repeater {
                        model: Fusebox.faults
                        FaultRow {}
                    }
                    Caption {
                        visible: Fusebox.faultSource === "accounts"
                        width: parent.width
                        wrapMode: Text.Wrap
                        elide: Text.ElideNone
                        color: Theme.textFaint
                        text: "From account state. Update Fusebox to also see failed-request and provider faults."
                    }
                }

                // ---- the main line ----
                FactStrip {
                    readonly property var f: Fusebox.figures
                    facts: [
                        { label: "In progress", value: String(f.serving) },
                        { label: "Last minute", value: f.rpm + " req" },
                        { label: "Failed · hour", value: String(f.failed), level: f.failed > 0 ? "critical" : "ok" },
                        { label: "First token", value: Helpers.seconds(f.ttft) }
                    ]
                }

                // ---- load ----
                Column {
                    width: parent.width
                    spacing: Theme.scaled(6)

                    SectionTitle {
                        label: "Load · last 60 min"
                        detail: Helpers.number(root.loadTotal) + (root.loadTotal === 1 ? " request" : " requests")
                    }
                    LoadBars {
                        width: parent.width
                        height: Theme.scaled(44)
                        bars: root.loadBars
                        peak: root.loadPeak
                        Accessible.role: Accessible.Graphic
                        Accessible.name: "Requests per minute, last 60 minutes"
                        Accessible.description: Helpers.number(root.loadTotal) + " requests, at most "
                            + root.loadPeak + " in a minute"
                    }
                    Item {
                        width: parent.width
                        height: axisStart.implicitHeight

                        Caption {
                            id: axisStart
                            text: "60 min ago"
                            color: Theme.textFaint
                        }
                        Caption {
                            anchors.right: parent.right
                            text: "now"
                            color: Theme.textFaint
                        }
                    }
                }

                // ---- accounts ----
                Column {
                    width: parent.width
                    spacing: Theme.scaled(4)

                    Item {
                        width: parent.width
                        height: Math.max(accountsTitle.height, quotaSwitch.visible ? quotaSwitch.height : 0)

                        SectionTitle {
                            id: accountsTitle
                            anchors.verticalCenter: parent.verticalCenter
                            width: parent.width - (quotaSwitch.visible ? quotaSwitch.width + Theme.scaled(12) : 0)
                            label: "Accounts"
                            detail: {
                                const on = Fusebox.accounts.filter(a => !a.disabled).length;
                                return on + " of " + Fusebox.accounts.length + " on";
                            }
                        }
                        QuotaSwitch {
                            id: quotaSwitch
                            visible: Fusebox.accounts.some(a => a.windows.length > 0)
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }
                    Caption {
                        visible: Fusebox.accounts.length === 0
                        width: parent.width
                        color: Theme.textLow
                        text: "No accounts yet. Connect one in the Fusebox dashboard."
                    }
                    Repeater {
                        model: root.circuits
                        AccountRow {}
                    }
                }

                // ---- latest requests ----
                Column {
                    width: parent.width
                    spacing: Theme.scaled(6)

                    SectionTitle {
                        label: "Latest requests"
                        detail: Fusebox.totals ? Helpers.number(Fusebox.totals.requests) + " since start" : ""
                    }
                    Caption {
                        visible: root.latest.length === 0
                        width: parent.width
                        color: Theme.textLow
                        text: "Requests appear here as they finish."
                    }
                    Rectangle {
                        visible: root.latest.length > 0
                        width: parent.width
                        height: latestRows.implicitHeight
                        radius: Theme.chipRadius
                        color: Theme.chip

                        Column {
                            id: latestRows
                            width: parent.width

                            Repeater {
                                model: root.latest
                                RequestRow {}
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
            anchors.leftMargin: 2
            anchors.right: actions.left
            anchors.rightMargin: Theme.scaled(10)
            anchors.verticalCenter: parent.verticalCenter
            anchors.verticalCenterOffset: 1
            text: {
                switch (Fusebox.connection) {
                case "setup": return "Not connected yet";
                case "connecting": return "Connecting…";
                case "live": return "Live · updated " + Helpers.ago(root.now - Fusebox.updatedAt);
                default: return Fusebox.hasData ? "Last update " + Helpers.ago(root.now - Fusebox.updatedAt)
                    : "Retrying automatically";
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
                visible: Fusebox.url !== ""
                text: "Dashboard ↗"
                accessibleName: "Open the Fusebox dashboard"
                onClicked: Fusebox.openDashboard("")
            }
            LinkText {
                text: "Settings"
                accessibleName: "Fusebox settings"
                onClicked: Fusebox.configure()
            }
        }
    }
}
