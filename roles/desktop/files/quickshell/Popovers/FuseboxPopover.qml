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
                    width: Math.min(implicitWidth, parent.width - x - planTag.width - statusRow.width
                        - Theme.scaled(20))
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
                visible: circuit.open
                x: providerMark.width + Theme.scaled(8)
                width: parent.width - x
                spacing: Theme.scaled(4)

                Caption {
                    width: parent.width
                    wrapMode: Text.Wrap
                    elide: Text.ElideNone
                    font.features: Theme.tabularNumberFeatures
                    color: Theme.textLow
                    text: {
                        const a = circuit.account;
                        const parts = [Helpers.providerName(a) + (a.kind === "api-key" ? " API key" : "")];
                        if (a.kind === "oauth" && a.expiresAt)
                            parts.push(a.expiresAt > root.now ? "token valid " + Helpers.span(a.expiresAt - root.now)
                                : "token expired");
                        parts.push(a.lastUsed ? "last used " + Helpers.ago(root.now - a.lastUsed) : "not used yet");
                        parts.push(Helpers.number(a.requests) + " requests"
                            + (a.failures ? ", " + Helpers.number(a.failures) + " failed" : ""));
                        return parts.join(" · ");
                    }
                }
                // These models change only with the account, not every second, so
                // rows are not rebuilt by the clock; an expired one just hides.
                Repeater {
                    model: circuit.account.windows.filter(w => !w.model && w.resetsAt)

                    Caption {
                        required property var modelData
                        visible: modelData.resetsAt > root.now
                        width: parent ? parent.width : 0
                        font.features: Theme.tabularNumberFeatures
                        color: Theme.textLow
                        text: Helpers.windowTitle(modelData) + " window resets " + Helpers.when(modelData.resetsAt, root.now)
                            + ", in " + Helpers.span(modelData.resetsAt - root.now)
                    }
                }
                Repeater {
                    model: circuit.account.cooldowns

                    Caption {
                        required property var modelData
                        visible: modelData.until > root.now
                        width: parent ? parent.width : 0
                        font.features: Theme.tabularNumberFeatures
                        color: Theme.amber
                        text: (modelData.model === "*" ? "Every model" : modelData.model) + " paused ("
                            + modelData.kind.replace("_", " ") + ") for " + Helpers.span(modelData.until - root.now)
                    }
                }
                Caption {
                    visible: circuit.account.lastError !== null && circuit.account.lastError !== undefined
                    width: parent.width
                    wrapMode: Text.Wrap
                    maximumLineCount: 3
                    color: Theme.redText
                    text: Fusebox.privateText(circuit.account.lastError)
                }
                Caption {
                    visible: circuit.account.banked > 0
                    width: parent.width
                    color: Theme.textLow
                    text: "↻ " + circuit.account.banked + (circuit.account.banked === 1 ? " reset" : " resets")
                        + " banked · spend in the dashboard"
                }
                Caption {
                    width: parent.width
                    wrapMode: Text.Wrap
                    elide: Text.ElideNone
                    color: Theme.textLow
                    text: {
                        const d = circuit.detail;
                        if (!d)
                            return "Loading pinned sessions…";
                        if (d.error)
                            return d.error;
                        const pinned = d.sessions.length;
                        if (!pinned)
                            return "No coding sessions pinned";
                        const busy = d.sessions.filter(s => s.active).length;
                        const clients = [...new Set(d.sessions.map(s => s.client).filter(c => c))];
                        return pinned + (pinned === 1 ? " session pinned" : " sessions pinned")
                            + (busy ? ", " + busy + " active now" : "")
                            + (clients.length ? " · " + clients.slice(0, 3).join(", ") : "");
                    }
                }
                Caption {
                    visible: circuit.result !== null && !circuit.result.ok
                    width: parent.width
                    wrapMode: Text.Wrap
                    elide: Text.ElideNone
                    color: Theme.redText
                    text: circuit.result ? circuit.result.error : ""
                }

                // The breaker: reversible actions only.
                Row {
                    topPadding: Theme.scaled(4)
                    spacing: Theme.scaled(16)

                    LinkText {
                        visible: circuit.account.kind === "oauth"
                        enabled: !Fusebox.actionBusy
                        text: circuit.acting && Fusebox.actionName === "refresh" ? "Refreshing…" : "Refresh"
                        accessibleName: "Refresh the sign-in and quota of " + Fusebox.accountName(circuit.account)
                        onClicked: Fusebox.runAction(circuit.account.id, "refresh")
                    }
                    LinkText {
                        visible: circuit.circuitState.cls === "cooling" || circuit.circuitState.cls === "error"
                        enabled: !Fusebox.actionBusy
                        text: circuit.acting && Fusebox.actionName === "reset" ? "Clearing…" : "Clear cooldowns"
                        accessibleName: "Clear cooldowns and errors of " + Fusebox.accountName(circuit.account)
                        onClicked: Fusebox.runAction(circuit.account.id, "reset")
                    }
                    LinkText {
                        enabled: !Fusebox.actionBusy
                        text: circuit.acting && Fusebox.actionName === "toggle" ? "Switching…"
                            : circuit.account.disabled ? "Turn on"
                            : root.confirmOff === circuit.account.id ? "Confirm turn off" : "Turn off"
                        accessibleName: (circuit.account.disabled ? "Turn on " : "Turn off ")
                            + Fusebox.accountName(circuit.account)
                        onClicked: {
                            if (circuit.account.disabled) {
                                Fusebox.runAction(circuit.account.id, "toggle", false);
                            } else if (root.confirmOff === circuit.account.id) {
                                root.confirmOff = "";
                                Fusebox.runAction(circuit.account.id, "toggle", true);
                            } else {
                                root.confirmOff = circuit.account.id;
                            }
                        }
                    }
                    LinkText {
                        text: "Open ↗"
                        accessibleName: "Open " + Fusebox.accountName(circuit.account) + " in the Fusebox dashboard"
                        onClicked: Fusebox.openDashboard("#/accounts/" + encodeURIComponent(circuit.account.id))
                    }
                }
            }
        }
    }

    component RequestRow: Item {
        id: requestRow

        required property var modelData
        readonly property var request: modelData
        readonly property var account: Fusebox.accountById(request.accountId)
        readonly property string result: Helpers.outcome(request)

        width: parent ? parent.width : 0
        height: Theme.scaled(34)
        Accessible.role: Accessible.StaticText
        Accessible.name: (request.clientApp || request.client) + " to " + request.model
        Accessible.description: "status " + request.status + ", first token " + Helpers.seconds(request.ttft)

        Text {
            id: requestTime
            y: Theme.scaled(2)
            text: Helpers.when(requestRow.request.at, root.now)
            font.family: Theme.fontNumeric
            font.pixelSize: Theme.typography.metadata
            font.features: Theme.tabularNumberFeatures
            color: Theme.textFaint
        }
        Text {
            anchors.left: requestTime.right
            anchors.leftMargin: Theme.scaled(10)
            anchors.right: requestStatus.left
            anchors.rightMargin: Theme.scaled(8)
            anchors.baseline: requestTime.baseline
            elide: Text.ElideRight
            textFormat: Text.PlainText
            text: (requestRow.request.clientApp || requestRow.request.client) + " · " + requestRow.request.model
            font.family: Theme.fontMenu
            font.pixelSize: Theme.typography.secondary
            color: Theme.textMid
        }
        Text {
            id: requestStatus
            anchors.right: parent.right
            anchors.baseline: requestTime.baseline
            text: requestRow.request.status
            font.family: Theme.fontNumeric
            font.pixelSize: Theme.typography.metadata
            font.weight: Theme.weightSemibold
            font.features: Theme.tabularNumberFeatures
            color: requestRow.result === "failed" ? Theme.redText
                : requestRow.result === "cancelled" ? Theme.textDim : Theme.ok
        }
        Caption {
            anchors.left: parent.left
            anchors.leftMargin: requestTime.width + Theme.scaled(10)
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.bottomMargin: Theme.scaled(2)
            font.features: Theme.tabularNumberFeatures
            color: Theme.textFaint
            text: {
                const r = requestRow.request;
                const parts = [requestRow.account ? Fusebox.accountName(requestRow.account)
                    : Fusebox.privateText(r.account)];
                if (r.ttft !== null)
                    parts.push("first token " + Helpers.seconds(r.ttft));
                if (r.usage !== "missing")
                    parts.push(Helpers.number(r.input + r.cached) + " in / " + Helpers.number(r.output) + " out");
                if (r.error && requestRow.result === "failed")
                    parts.push(Fusebox.privateText(r.error));
                return parts.filter(part => part).join(" · ");
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
                Rectangle {
                    id: strip
                    readonly property var f: Fusebox.figures
                    width: parent.width
                    height: Theme.scaled(46)
                    radius: Theme.chipRadius
                    color: Theme.chip

                    Row {
                        anchors.fill: parent

                        Fact {
                            width: strip.width / 4
                            divider: false
                            label: "In progress"
                            value: String(strip.f.serving)
                        }
                        Fact {
                            width: strip.width / 4
                            label: "Last minute"
                            value: strip.f.rpm + " req"
                        }
                        Fact {
                            width: strip.width / 4
                            label: "Failed · hour"
                            value: String(strip.f.failed)
                            level: strip.f.failed > 0 ? "critical" : "ok"
                        }
                        Fact {
                            width: strip.width / 4
                            label: "First token"
                            value: Helpers.seconds(strip.f.ttft)
                        }
                    }
                }

                // ---- load ----
                Column {
                    width: parent.width
                    spacing: Theme.scaled(6)

                    SectionTitle {
                        label: "Load · last 60 min"
                        detail: Helpers.number(root.loadTotal) + (root.loadTotal === 1 ? " request" : " requests")
                    }
                    Item {
                        width: parent.width
                        height: Theme.scaled(44)
                        Accessible.role: Accessible.Graphic
                        Accessible.name: "Requests per minute, last 60 minutes"
                        Accessible.description: Helpers.number(root.loadTotal) + " requests, at most "
                            + root.loadPeak + " in a minute"

                        Row {
                            id: loadRow
                            readonly property real slot: width / 60
                            anchors.fill: parent
                            spacing: 0

                            Repeater {
                                // Sixty fixed slots that read their minute, so the bars
                                // persist while the clock moves them along.
                                model: 60

                                Item {
                                    id: loadSlot
                                    required property int index
                                    readonly property var modelData: root.loadBars[index]
                                    readonly property real share: modelData.requests / root.loadPeak
                                    width: loadRow.slot
                                    height: loadRow.height

                                    Rectangle {
                                        anchors.bottom: parent.bottom
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        width: Math.max(1, loadRow.slot - 2)
                                        height: loadSlot.modelData.requests > 0
                                            ? Math.max(2, loadSlot.share * parent.height) : 1
                                        radius: 1
                                        color: loadSlot.modelData.requests === 0 ? Theme.hairline
                                            : loadSlot.modelData.current ? Theme.accentText
                                            : Qt.alpha(Theme.accentText, 0.45)
                                    }
                                    Rectangle {
                                        visible: loadSlot.modelData.failed > 0
                                        anchors.bottom: parent.bottom
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        width: Math.max(1, loadRow.slot - 2)
                                        height: Math.max(2, loadSlot.modelData.failed / root.loadPeak * parent.height)
                                        radius: 1
                                        color: Theme.red
                                    }
                                }
                            }
                        }
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
                    spacing: Theme.scaled(2)

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
                    Repeater {
                        model: root.latest
                        RequestRow {}
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
