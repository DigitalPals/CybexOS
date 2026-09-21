pragma ComponentBehavior: Bound
import QtQuick
import "../Common"

Item {
    id: root

    property int maxHeight: 560
    property int spacing: 5
    property bool snoozedExpanded: false
    property bool settledExpanded: false
    property string searchText: ""
    signal threadRequested(string threadId)

    readonly property int totalThreadCount: T3Code.threads.length
        + T3Code.pinnedThreads.length + T3Code.snoozedThreads.length
        + T3Code.settledThreads.length
    readonly property var pinnedThreads: filtered(T3Code.pinnedThreads)
    readonly property var snoozedThreads: filtered(T3Code.snoozedThreads)
    readonly property var settledThreads: filtered(T3Code.settledThreads)
    readonly property var needsYou: filtered(T3Code.threads).filter(thread =>
        thread.cls === "attention" || thread.cls === "error")
    readonly property var readyPlans: filtered(T3Code.threads).filter(thread =>
        thread.planReady && thread.cls !== "attention" && thread.cls !== "error")
    readonly property var runningThreads: filtered(T3Code.threads).filter(thread =>
        (thread.cls === "running" || thread.cls === "monitoring") && !thread.planReady)
    readonly property var quietThreads: filtered(T3Code.threads).filter(thread =>
        (thread.cls === "done" || thread.cls === "idle") && !thread.planReady)
    // The configured drawer reaches 320px. Below a 360px effective content
    // measure, preserve both context and state by stacking them under the
    // title instead of squeezing all three lanes onto one line.
    readonly property bool narrowRows: width < 360

    readonly property real naturalHeight:
        (searchBox.visible ? searchBox.height + spacing : 0) + body.implicitHeight

    implicitHeight: Math.min(maxHeight, Math.max(1, naturalHeight))

    function filtered(threads) {
        const query = searchText.trim().toLowerCase();
        if (query === "")
            return Array.isArray(threads) ? threads : [];
        return (Array.isArray(threads) ? threads : []).filter(thread =>
            [thread.title, thread.project, thread.branch, thread.sessionStatus]
                .some(value => String(value ?? "").toLowerCase().includes(query)));
    }

    // The row's hover actions. Icons rather than word pills, matching the
    // reference client: four words do not fit beside a title, project, and
    // status even when the narrow layout gives them a second line, so the
    // shared 32px control height would leave no margin.
    component RowAction: IconButton {
        controlSize: Theme.chipInnerHeight
    }

    // The page's own T3 defaults over the shell's shared action primitive.
    component Action: ActionButton {
        fontFamily: T3Theme.fontUi
        focusColor: T3Theme.focus
        buttonRadius: T3Theme.controlRadius
        tint: T3Theme.textMuted
        fill: T3Theme.hover
    }

    component T3Status: StatusPlaceholder {
        fontFamily: T3Theme.fontUi
        accentColor: T3Theme.accent
        accentFill: T3Theme.accentSubtle
        outlineColor: T3Theme.border
        primaryTextColor: T3Theme.textSecondary
        secondaryTextColor: T3Theme.textFaint
        errorColor: T3Theme.red
        errorFill: T3Theme.redSoft
        errorOutline: T3Theme.redBorder
        transitionDuration: T3Theme.normalDuration
        fadeDuration: T3Theme.fastDuration
    }

    component GroupHeader: SectionLabel {
        property string label: ""
        property int count: 0
        text: label.toUpperCase()
        detail: String(count)
        tint: T3Theme.textMuted
        detailColor: T3Theme.textFaint
        rule: T3Theme.border
    }

    component ThreadRow: Column {
        id: entry
        required property var thread

        readonly property bool active: thread.lifecycle === "active"
        readonly property bool settled: thread.lifecycle === "settled"
        readonly property bool snoozed: thread.lifecycle === "snoozed"
        readonly property bool pinned: thread.pinned === true
        readonly property bool quiet: settled || snoozed
            || thread.cls === "done" || thread.cls === "idle"
        readonly property bool subdued: quiet && !pinned
        readonly property bool narrow: root.narrowRows
        readonly property bool flagged: thread.cls === "error" || thread.cls === "attention"
        readonly property bool revealed: rowHover.hovered || row.activeFocus
            || actionsScope.activeFocus
        readonly property string glyph: T3Code.threadProviderIcon(thread.id)
        readonly property string statusSymbol: thread.cls === "error" ? "error"
            : thread.cls === "attention" ? "help"
            : thread.planReady ? "description"
            : thread.cls === "running" ? "sync"
            : thread.cls === "monitoring" ? "visibility"
            : snoozed ? "snooze" : settled ? "archive" : "check_circle"
        readonly property string statusWord: {
            if (entry.snoozed)
                return thread.snoozedUntil
                    ? "wakes in " + T3Code.snoozeWakeLabel(thread.snoozedUntil) : "snoozed";
            if (entry.settled)
                return T3Code.relTime(thread.settledAt || thread.updatedAt);
            if (thread.cls === "attention") {
                const kind = thread.pendingApprovals ? "approval"
                    : thread.pendingInput ? "input" : "waiting";
                const when = T3Code.relTime(thread.updatedAt);
                return when !== "" ? kind + " · " + when : kind;
            }
            if (thread.cls === "error") {
                const when = T3Code.relTime(thread.updatedAt);
                return when !== "" ? "error · " + when : "error";
            }
            if (thread.planReady)
                return "plan ready";
            if (thread.cls === "monitoring")
                return "monitoring";
            if (thread.cls === "running") {
                const timer = T3Code.workingTimerLabel(thread.workingStartedAt);
                return timer !== "" ? "working " + timer : "working…";
            }
            if (thread.cls === "done") {
                const when = T3Code.relTime(thread.updatedAt);
                return when !== "" ? "done · " + when : "done";
            }
            return T3Code.relTime(thread.updatedAt);
        }
        readonly property color statusColor: thread.cls === "error" ? T3Theme.red
            : thread.cls === "attention" ? T3Theme.amber
            : entry.quiet ? T3Theme.textFaint : T3Theme.accent

        width: parent.width
        spacing: 3

        Rectangle {
            id: row
            width: parent.width
            height: entry.narrow ? 54 : T3Theme.quietRowHeight
            radius: T3Theme.rowRadius
            // Only a thread that wants something paints a fill. The neutral
            // card the working rows used to carry split the list in two down
            // the middle and crowded a narrow surface; amber and red stay,
            // because those are a signal rather than chrome.
            color: entry.flagged ? (entry.thread.cls === "error"
                    ? T3Theme.redSoft : T3Theme.amberSoft) : "transparent"
            border.width: activeFocus || entry.flagged ? 1 : 0
            border.color: activeFocus ? T3Theme.focus
                : entry.thread.cls === "error" ? T3Theme.redBorder
                : entry.thread.cls === "attention" ? T3Theme.amberBorder : T3Theme.border
            activeFocusOnTab: true
            Accessible.role: Accessible.Button
            Accessible.name: entry.thread.title + ", " + entry.statusWord
            Accessible.onPressAction: root.threadRequested(entry.thread.id)

            HoverHandler { id: rowHover }

            Keys.onPressed: event => {
                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                        || event.key === Qt.Key_Space) {
                    root.threadRequested(entry.thread.id);
                    event.accepted = true;
                }
            }

            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.threadRequested(entry.thread.id)
            }

            Rectangle {
                anchors.fill: parent
                radius: parent.radius
                color: rowHover.hovered ? T3Theme.hoverStrong : "transparent"

                Behavior on color {
                    ColorAnimation { duration: T3Theme.fastDuration }
                }
            }

            Item {
                id: glyphSlot
                x: 10
                anchors.verticalCenter: parent.verticalCenter
                width: 16
                height: width

                BrandIcon {
                    visible: entry.glyph !== ""
                    anchors.fill: parent
                    name: entry.glyph
                    opacity: entry.subdued ? 0.58 : 0.92
                }

                Sym {
                    visible: entry.glyph === ""
                    anchors.centerIn: parent
                    name: "terminal"
                    size: entry.subdued ? Theme.iconTiny : Theme.iconSmall
                    symWeight: 450
                    color: entry.subdued ? T3Theme.textFaint : T3Theme.textMuted
                }

                Rectangle {
                    visible: entry.flagged || entry.thread.cls === "running"
                        || entry.thread.cls === "monitoring" || entry.thread.planReady
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    anchors.margins: -2
                    width: 9
                    height: 9
                    radius: 5
                    color: entry.flagged ? row.color : T3Theme.canvas

                    Rectangle {
                        anchors.centerIn: parent
                        width: 6
                        height: 6
                        radius: 3
                        color: entry.statusColor
                    }
                }
            }

            Item {
                id: line
                anchors.left: glyphSlot.right
                anchors.leftMargin: 10
                anchors.right: parent.right
                anchors.rightMargin: 9
                anchors.verticalCenter: parent.verticalCenter
                height: parent.height

                Text {
                    id: threadTitle
                    x: 0
                    y: entry.narrow ? 6 : (parent.height - height) / 2
                    width: Math.max(0, (entry.narrow ? side.x : meta.x) - 8)
                    text: entry.thread.title
                    elide: Text.ElideRight
                    font.family: T3Theme.fontUi
                    font.pixelSize: Theme.typography.secondary
                    font.weight: entry.subdued ? Theme.weightRegular : Theme.weightMedium
                    color: entry.subdued ? T3Theme.textSecondary : T3Theme.textPrimary
                }

                // Wide drawers keep context trailing the title. Narrow ones
                // turn the row into a two-line tile: title first, then project
                // and status, with hover actions still occupying the status
                // lane rather than covering the primary action target.
                TextMetrics {
                    id: metaMetrics
                    text: meta.text
                    font.family: T3Theme.fontUi
                    font.pixelSize: Theme.typography.metadata
                }

                Text {
                    id: meta
                    x: entry.narrow ? 0 : Math.max(0, side.x - width - 8)
                    y: entry.narrow ? parent.height - height - 6
                        : (parent.height - height) / 2
                    leftPadding: !entry.narrow && text !== "" ? 8 : 0
                    width: text === "" ? 0 : entry.narrow
                        ? Math.max(0, side.x - 6)
                        : Math.min(metaMetrics.advanceWidth + leftPadding,
                            parent.width * 0.38)
                    text: {
                        const parts = [];
                        if (entry.thread.project !== "")
                            parts.push(entry.thread.project);
                        if (entry.thread.cls === "error")
                            parts.push("session error");
                        // Why a thread settled is worth a phrase only where
                        // the row is not already subdued — on a quiet row the
                        // archive mark and its time have said it, and the
                        // phrase only eats the project's room. That was the old
                        // second line's rule too: it drew for the full-height
                        // rows and never for the parked ones.
                        else if (entry.settled && !entry.subdued)
                            parts.push(entry.thread.settledOverride === "settled"
                                ? "settled by you" : "settled by inactivity");
                        else if (entry.thread.cls === "attention"
                                && entry.thread.sessionStatus !== ""
                                && entry.thread.sessionStatus !== "running")
                            parts.push(entry.thread.sessionStatus);
                        return parts.join(" · ");
                    }
                    elide: Text.ElideRight
                    font.family: T3Theme.fontUi
                    font.pixelSize: Theme.typography.metadata
                    color: entry.thread.cls === "error" ? T3Theme.red
                        : T3Theme.textFaint
                }

                Item {
                    id: side
                    anchors.right: parent.right
                    y: entry.narrow ? parent.height - height - 5 : 0
                    width: entry.revealed ? actionsScope.implicitWidth
                        : statusRow.implicitWidth
                    height: entry.narrow
                        ? Math.max(statusRow.implicitHeight, actionsScope.implicitHeight)
                        : parent.height

                    Row {
                        id: statusRow
                        visible: !entry.revealed
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 4

                        Sym {
                            anchors.verticalCenter: parent.verticalCenter
                            name: entry.statusSymbol
                            size: Theme.iconTiny
                            symWeight: 500
                            color: entry.statusColor
                        }

                        Text {
                            id: statusText
                            anchors.verticalCenter: parent.verticalCenter
                            text: entry.statusWord
                            font.family: T3Theme.fontUi
                            font.pixelSize: Theme.typography.metadata
                            font.weight: Theme.weightMedium
                            font.features: T3Theme.tabularNumberFeatures
                            color: entry.statusColor
                        }
                    }
                }
            }

            FocusScope {
                id: actionsScope
                visible: entry.revealed
                anchors.right: row.right
                anchors.rightMargin: 9
                y: entry.narrow ? row.height - height - 5
                    : (row.height - height) / 2
                implicitWidth: actions.implicitWidth
                implicitHeight: actions.implicitHeight

                Row {
                    id: actions
                    spacing: 2

                    RowAction {
                        readonly property string kind: entry.thread.pinned
                            ? "unpin" : "pin"
                        readonly property bool pending:
                            T3Code.actionPending(kind, entry.thread.id, "")

                        visible: T3Code.supportsPinning
                        symbol: pending ? "more_horiz" : "keep"
                        symbolFill: entry.thread.pinned ? 1 : 0
                        accessibleName: entry.thread.pinned ? "Unpin" : "Pin"
                        enabled: T3Code.canDispatch && !pending
                        onTriggered: entry.thread.pinned
                            ? T3Code.unpin(entry.thread.id) : T3Code.pin(entry.thread.id)
                    }

                    RowAction {
                        readonly property bool pending:
                            T3Code.actionPending("settle", entry.thread.id, "")

                        visible: entry.active && T3Code.supportsSettlement
                        symbol: pending ? "more_horiz" : "check"
                        accessibleName: "Settle"
                        tint: T3Theme.accent
                        enabled: T3Code.canDispatch && entry.thread.canLifecycle
                            && !pending
                        onTriggered: T3Code.settle(entry.thread.id)
                    }

                    RowAction {
                        readonly property bool pending:
                            T3Code.actionPending("unsettle", entry.thread.id, "")

                        visible: entry.settled && T3Code.supportsSettlement
                        symbol: pending ? "more_horiz" : "close"
                        accessibleName: "Unsettle"
                        tint: T3Theme.accent
                        enabled: T3Code.canDispatch && !pending
                        onTriggered: T3Code.unsettle(entry.thread.id)
                    }

                    RowAction {
                        readonly property bool pending:
                            T3Code.actionPending("unsnooze", entry.thread.id, "")

                        visible: entry.snoozed && T3Code.supportsSnooze
                        symbol: pending ? "more_horiz" : "alarm"
                        accessibleName: "Wake"
                        tint: T3Theme.accent
                        enabled: T3Code.canDispatch && !pending
                        onTriggered: T3Code.unsnooze(entry.thread.id)
                    }
                }
            }
        }

        Text {
            visible: text !== ""
            x: 38
            width: parent.width - 46
            text: {
                for (const kind of ["pin", "unpin", "settle", "unsettle", "snooze", "unsnooze"]) {
                    const error = T3Code.actionError(kind, entry.thread.id, "");
                    if (error !== "")
                        return error;
                }
                return "";
            }
            wrapMode: Text.WordWrap
            lineHeight: Theme.proseLineHeight
            maximumLineCount: 2
            elide: Text.ElideRight
            font.family: T3Theme.fontUi
            font.pixelSize: Theme.typography.secondary
            color: T3Theme.red
        }
    }

    component DrawerHeader: Rectangle {
        id: drawer
        property string label: ""
        property int count: 0
        property bool expanded: false
        property bool subdued: false
        signal toggled()

        // A collapsed drawer is a section that happens to be openable, so it
        // reads as one: the same uppercase mark and rule as every other group,
        // with the chevron at the end. Only the pointer lights a fill.
        height: Theme.sectionHeaderHeight + 8
        radius: T3Theme.controlRadius
        color: drawerMouse.containsMouse ? T3Theme.hover : "transparent"
        activeFocusOnTab: true
        Accessible.role: Accessible.Button
        Accessible.name: drawer.label + ", " + drawer.count
        Accessible.onPressAction: drawer.toggled()
        border.width: activeFocus ? 1 : 0
        border.color: T3Theme.focus

        Keys.onPressed: event => {
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                    || event.key === Qt.Key_Space) {
                drawer.toggled();
                event.accepted = true;
            }
        }

        Text {
            id: drawerLabel
            anchors.left: parent.left
            anchors.leftMargin: 2
            anchors.verticalCenter: parent.verticalCenter
            text: drawer.label.toUpperCase()
            font.family: T3Theme.fontUi
            font.pixelSize: Theme.typography.metadata
            font.weight: Theme.weightSemibold
            font.letterSpacing: 1
            color: drawer.subdued ? T3Theme.textFaint : T3Theme.textMuted
        }

        Text {
            id: drawerCount
            anchors.left: drawerLabel.right
            anchors.leftMargin: 7
            anchors.verticalCenter: parent.verticalCenter
            text: drawer.count
            font.family: T3Theme.fontUi
            font.pixelSize: Theme.typography.metadata
            font.weight: Theme.weightMedium
            font.features: T3Theme.tabularNumberFeatures
            color: T3Theme.textFaint
        }

        Rectangle {
            anchors.left: drawerCount.right
            anchors.leftMargin: 10
            anchors.right: drawerChevron.left
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            height: 1
            color: T3Theme.border
        }

        Sym {
            id: drawerChevron
            anchors.right: parent.right
            anchors.rightMargin: 2
            anchors.verticalCenter: parent.verticalCenter
            name: drawer.expanded ? "expand_less" : "expand_more"
            size: Theme.iconSmall
            symWeight: 450
            color: T3Theme.textFaint
        }

        MouseArea {
            id: drawerMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: drawer.toggled()
        }
    }

    Rectangle {
        id: searchBox
        visible: root.totalThreadCount > 0 || root.searchText !== ""
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        height: 36
        radius: T3Theme.controlRadius
        color: T3Theme.surface
        border.width: searchInput.activeFocus ? 1 : 0
        border.color: T3Theme.focus

        Sym {
            anchors.left: parent.left
            anchors.leftMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            name: "search"
            size: Theme.iconSmall
            symWeight: 450
            color: T3Theme.textFaint
        }

        TextInput {
            id: searchInput
            anchors.left: parent.left
            anchors.leftMargin: 32
            anchors.right: clearSearch.visible ? clearSearch.left : parent.right
            anchors.rightMargin: clearSearch.visible ? 4 : 10
            anchors.verticalCenter: parent.verticalCenter
            text: root.searchText
            onTextEdited: root.searchText = text
            clip: true
            selectByMouse: true
            font.family: T3Theme.fontUi
            font.pixelSize: Theme.typography.control
            color: T3Theme.textPrimary

            Text {
                visible: searchInput.text === ""
                anchors.verticalCenter: parent.verticalCenter
                text: "Search threads"
                font.family: T3Theme.fontUi
                font.pixelSize: Theme.typography.control
                color: T3Theme.textFaint
            }
        }

        IconButton {
            id: clearSearch
            visible: searchInput.text !== ""
            anchors.right: parent.right
            anchors.rightMargin: 5
            anchors.verticalCenter: parent.verticalCenter
            controlSize: 26
            symbol: "close"
            accessibleName: "Clear thread search"
            tint: T3Theme.textFaint
            onTriggered: {
                root.searchText = "";
                searchInput.text = "";
                searchInput.forceActiveFocus();
            }
        }
    }

    Item {
        id: viewport
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: searchBox.visible ? searchBox.bottom : parent.top
        anchors.topMargin: searchBox.visible ? root.spacing : 0
        anchors.bottom: parent.bottom

        Flickable {
            id: flick
            anchors.fill: parent
            contentWidth: width
            contentHeight: body.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            interactive: contentHeight > height
            activeFocusOnTab: interactive

            Column {
                id: body
                width: flick.width - (flick.contentHeight > flick.height ? 5 : 0)
                spacing: 4

                Text {
                    visible: T3Code.readOnly
                    width: parent.width
                    leftPadding: 7
                    rightPadding: 7
                    topPadding: 5
                    bottomPadding: 5
                    text: "Read-only access · actions are disabled"
                    font.family: T3Theme.fontUi
                    font.pixelSize: Theme.typography.secondary
                    color: T3Theme.amber
                }

                T3Status {
                    shown: T3Code.state !== "connected"
                    width: parent.width
                    kind: T3Code.cloudLoginRunning || T3Code.state === "connecting" ? "loading"
                        : T3Code.state === "signed-out" || T3Code.state === "cloud-empty"
                            ? "empty" : "error"
                    glyph: {
                        if (T3Code.state === "signed-out")
                            return "cloud";
                        if (T3Code.state === "cloud-empty")
                            return "cloud_off";
                        if (kind === "error")
                            return "cloud_off";
                        return "progress_activity";
                    }
                    title: T3Code.cloudLoginRunning ? "Finish in your browser"
                        : T3Code.state === "signed-out"
                            ? "T3 Connect"
                        : T3Code.state === "cloud-empty" ? "No linked T3 environments"
                        : T3Code.state === "connecting" ? "Connecting through T3 Connect…"
                        : "Server unreachable — drafts are safe"
                    detail: T3Code.cloudLoginRunning
                        ? "Choose Google or GitHub in the browser to continue."
                        : T3Code.state === "signed-out"
                            ? "Sign in with Google or GitHub to access your linked environments."
                        : T3Code.state === "cloud-empty"
                            ? "You're signed in, but this account has no linked environments."
                        : ""
                }

                Action {
                    visible: T3Code.state === "signed-out" || T3Code.state === "cloud-empty"
                        || T3Code.cloudLoginRunning
                    anchors.horizontalCenter: parent.horizontalCenter
                    label: T3Code.cloudLoginRunning ? "Waiting for browser…"
                        : T3Code.state === "cloud-empty" ? "Refresh"
                        : "Sign in"
                    hPadding: 22
                    enabled: !T3Code.cloudLoginRunning
                    tint: T3Theme.accent
                    fill: T3Theme.accentSubtle
                    onTriggered: T3Code.loginCloud()
                }

                Text {
                    visible: T3Code.cloudLoginRunning
                    width: Math.min(parent.width - 24, 390)
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: T3Code.cloudLoginRunning
                        ? "This panel will reconnect automatically."
                        : ""
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                    lineHeight: Theme.proseLineHeight
                    font.family: T3Theme.fontUi
                    font.pixelSize: Theme.typography.secondary
                    color: T3Theme.textFaint
                }

                Text {
                    visible: T3Code.state === "cloud-empty"
                    width: Math.min(parent.width - 24, 390)
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "Link an environment in T3 Code Nightly, then refresh."
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                    lineHeight: Theme.proseLineHeight
                    font.family: T3Theme.fontUi
                    font.pixelSize: Theme.typography.secondary
                    color: T3Theme.textFaint
                }

                Text {
                    visible: T3Code.cloudLoginError !== ""
                    width: Math.min(parent.width - 24, 390)
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: T3Code.cloudLoginError
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                    font.family: T3Theme.fontUi
                    font.pixelSize: Theme.typography.secondary
                    color: T3Theme.red
                }

                T3Status {
                    shown: T3Code.state === "connected" && T3Code.shellReady
                        && T3Code.threads.length === 0 && T3Code.pinnedThreads.length === 0
                        && T3Code.snoozedThreads.length === 0
                        && T3Code.settledThreads.length === 0
                    width: parent.width
                    glyph: "forum"
                    title: "No sessions"
                }

                Text {
                    visible: root.searchText !== "" && root.pinnedThreads.length === 0
                        && root.needsYou.length === 0 && root.readyPlans.length === 0
                        && root.runningThreads.length === 0 && root.quietThreads.length === 0
                        && root.snoozedThreads.length === 0 && root.settledThreads.length === 0
                    width: parent.width
                    topPadding: 24
                    bottomPadding: 24
                    text: "No threads match “" + root.searchText + "”"
                    horizontalAlignment: Text.AlignHCenter
                    elide: Text.ElideRight
                    font.family: T3Theme.fontUi
                    font.pixelSize: Theme.typography.secondary
                    color: T3Theme.textFaint
                }

                // Pinned first, like the reference sidebar. Rows keep their
                // live status word, so a pinned thread that needs you still
                // reads amber — it is just anchored here instead of sorted.
                GroupHeader {
                    visible: root.pinnedThreads.length > 0
                    label: "Pinned"
                    count: root.pinnedThreads.length
                }
                Repeater {
                    model: root.pinnedThreads
                    delegate: ThreadRow { required property var modelData; thread: modelData }
                }

                GroupHeader {
                    visible: root.needsYou.length > 0
                    label: "Needs you"
                    count: root.needsYou.length
                    tint: T3Theme.amber
                    rule: T3Theme.amberBorder
                }
                Repeater {
                    model: root.needsYou
                    delegate: ThreadRow { required property var modelData; thread: modelData }
                }

                GroupHeader {
                    visible: root.readyPlans.length > 0
                    label: "Ready to review"
                    count: root.readyPlans.length
                    tint: T3Theme.accent
                    rule: T3Theme.accentSoft
                }
                Repeater {
                    model: root.readyPlans
                    delegate: ThreadRow { required property var modelData; thread: modelData }
                }

                GroupHeader {
                    visible: root.runningThreads.length > 0
                    label: "Working"
                    count: root.runningThreads.length
                }
                Repeater {
                    model: root.runningThreads
                    delegate: ThreadRow { required property var modelData; thread: modelData }
                }

                Repeater {
                    model: root.quietThreads
                    delegate: ThreadRow { required property var modelData; thread: modelData }
                }

                Row {
                    id: drawerRow
                    visible: root.snoozedThreads.length > 0 || root.settledThreads.length > 0
                    width: parent.width
                    spacing: 6

                    readonly property bool both: root.snoozedThreads.length > 0
                        && root.settledThreads.length > 0

                    DrawerHeader {
                        visible: root.snoozedThreads.length > 0
                        width: drawerRow.both ? (drawerRow.width - drawerRow.spacing) / 2
                            : drawerRow.width
                        label: "Snoozed"
                        count: root.snoozedThreads.length
                        expanded: root.snoozedExpanded
                        onToggled: root.snoozedExpanded = !root.snoozedExpanded
                    }

                    DrawerHeader {
                        visible: root.settledThreads.length > 0
                        width: drawerRow.both ? (drawerRow.width - drawerRow.spacing) / 2
                            : drawerRow.width
                        label: "Settled"
                        count: root.settledThreads.length
                        expanded: root.settledExpanded
                        subdued: true
                        onToggled: root.settledExpanded = !root.settledExpanded
                    }
                }

                Repeater {
                    model: root.snoozedExpanded ? root.snoozedThreads.slice(0, 5) : []
                    delegate: ThreadRow { required property var modelData; thread: modelData }
                }

                Text {
                    visible: root.snoozedExpanded && root.snoozedThreads.length > 5
                    width: parent.width
                    leftPadding: 9
                    text: "+" + (root.snoozedThreads.length - 5) + " more in T3 Code"
                    font.family: T3Theme.fontUi
                    font.pixelSize: Theme.typography.secondary
                    color: T3Theme.textFaint
                }

                Repeater {
                    model: root.settledExpanded ? root.settledThreads.slice(0, 5) : []
                    delegate: ThreadRow { required property var modelData; thread: modelData }
                }

                Text {
                    visible: root.settledExpanded && root.settledThreads.length > 5
                    width: parent.width
                    leftPadding: 9
                    text: "+" + (root.settledThreads.length - 5) + " more in T3 Code"
                    font.family: T3Theme.fontUi
                    font.pixelSize: Theme.typography.secondary
                    color: T3Theme.textFaint
                }
            }
        }

        ScrollChrome {
            anchors.fill: parent
            target: flick
            edgeColor: T3Theme.canvas
            thumbColor: T3Theme.accent
        }
    }
}
