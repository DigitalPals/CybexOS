pragma ComponentBehavior: Bound
import QtQuick
import "../Common"
import "../Common/Format.js" as Format
import "../Common/UpdatesHelpers.js" as UpdatesHelpers

// The dedicated Updates drawer. PanelRegistryData attaches this surface to the
// right edge; using the shared drawer width keeps it on the current
// edge-drawer template without folding it into Control Dashboard.
//
// One layout for every state, so the panel never rearranges itself under the
// person using it: a header that says what is happening in one line, the
// categories being updated as fixed rows whose right-hand side moves from a
// count to progress to a result, one primary action, and a Details
// disclosure for everything else — package names, the live transaction, the
// raw error. All state lives in Common/Updates.qml; closing this panel
// mid-run interrupts nothing, and the bar chip carries the progress.
Surface {
    id: root

    readonly property string mode: Updates.runState
    readonly property bool idle: mode === "idle"
    readonly property bool running: mode === "running"
    readonly property bool finished: mode === "done"
    readonly property bool failed: mode === "failed"
    // The first check of a session, before there is anything to show.
    readonly property bool checking: idle && Updates.busy
    readonly property bool spinning: running || checking
    readonly property bool rebootNeeded: Updates.rebootRecommended
    // Pending updates lead while there are any; a restart owns the mark
    // once nothing else is waiting.
    readonly property bool rebootMark: rebootNeeded && !running && !failed
        && (finished || Updates.total === 0)
    readonly property bool finishedWithIssues: finished
        && (Updates.fpWarning !== "" || Updates.fwFailMessage !== "")
    readonly property var plan: Updates.runPlan
    // The run's phase before any package work: the rows are still waiting.
    readonly property bool preparing: running && (Updates.backendPhase === ""
        || Updates.backendPhase === "queued" || Updates.backendPhase === "snapshot")
    readonly property int updateCategories: (Updates.dnfCount > 0 ? 1 : 0)
        + (Updates.flatpakCount > 0 ? 1 : 0) + (Updates.firmwareInRun ? 1 : 0)
        + (Updates.projectAvailable ? 1 : 0)
    readonly property bool canUpdate: updateCategories > 0

    // Which rows show. Decided here rather than read back from the rows:
    // a container whose visibility follows its children's `visible` hides
    // them too, and then can never become visible again.
    //
    // Every run upgrades the system (`dnf upgrade --refresh` can find more
    // than the cached check did), so outside idle that row always shows.
    readonly property bool showSystem: idle ? Updates.dnfCount > 0 : true
    readonly property bool showApps: idle ? Updates.flatpakCount > 0
        : Updates.runIncludedFlatpak && (plan === null || plan.flatpak > 0
            || Updates.appCount > 0 || Updates.fpWarning !== "")
    readonly property bool showFirmware: idle ? Updates.firmwareCount > 0
        : Updates.runIncludedFirmware
    readonly property bool showProject: idle && Updates.projectAvailable
    readonly property bool hasDetails: !idle || Updates.total > 0
        || Updates.error !== ""

    // idle: "update" | "restart" | ""; done: "restart" | ""; failed: "retry".
    readonly property string primaryAction: failed ? "retry"
        : idle && canUpdate ? "update"
        : (idle || finished) && rebootNeeded ? "restart" : ""

    // Match the current edge-drawer template in every state. Keeping one width
    // also prevents the surface shifting when a check turns into a live run.
    implicitWidth: Theme.drawerWidth
    spacing: 14

    function clock(stamp) {
        return Qt.formatTime(new Date(stamp), Settings.clock24 ? "HH:mm" : "h:mm ap");
    }

    // Only icon-name literals may appear in here: the icon-name test reads
    // every string in a *glyph* helper as a Tabler icons name.
    function headerGlyph(spin, issues, reboot, broken, cancelled, pending, trouble) {
        return spin ? "progress_activity"
            : broken ? (cancelled ? "cancel" : "error")
            : reboot ? "restart_alt"
            : issues || trouble ? "warning"
            : pending ? "deployed_code_update"
            : "check_circle";
    }

    function verbIcon(verb, failed) {
        return failed ? "error" : verb === "add" ? "add" : verb === "del" ? "remove"
            : verb === "down" ? "arrow_downward" : "arrow_upward";
    }

    function rowGlyph(active, done, failed, attention) {
        return active ? "progress_activity" : done ? "check_circle"
            : failed ? "error" : attention ? "warning" : "radio_button_unchecked";
    }

    function verbColor(verb, failed) {
        return failed ? Theme.redText : verb === "add" ? Theme.accent
            : verb === "del" ? Theme.redText
            : verb === "down" ? Theme.amber : Theme.ok;
    }

    readonly property string title: {
        if (running)
            return "Updating" + (Updates.runPercent >= 0
                ? " · " + Updates.runPercent + "%" : "");
        if (finished)
            return finishedWithIssues ? "Updated with issues" : "Updates installed";
        if (failed)
            return Updates.runCancelled ? "Update cancelled" : "Update didn’t finish";
        if (Updates.total > 0)
            return Updates.total + (Updates.total === 1 ? " update" : " updates");
        if (rebootNeeded)
            return "Restart required";
        if (checking)
            return "Checking for updates";
        return Updates.checkError !== "" || Updates.projectStatus === "desktop-channel-disabled"
            || Updates.projectStatus === "desktop-channel-invalid" ? "Updates need attention" : "Up to date";
    }

    readonly property string status: {
        if (running)
            return Updates.runPhaseLabel + " · " + Format.mmss(Updates.runElapsed);
        if (finished)
            return rebootNeeded ? "Restart to finish updating"
                : "Finished at " + clock(Updates.runFinishedAt);
        if (failed)
            return Updates.failMessage;
        if (Updates.busy)
            return "Checking…";
        if (Updates.checkError !== "")
            return Updates.checkError;
        if (rebootNeeded && Updates.total === 0)
            return "Restart to finish updating";
        // Neutral, like the checked time: nothing to install from CybexOS yet.
        return Updates.checkedLabel()
            + (Updates.projectNote !== "" ? " · " + Updates.projectNote : "");
    }

    readonly property color statusColor: failed && !Updates.runCancelled ? Theme.redText
        : idle && !Updates.busy && Updates.checkError !== "" ? Theme.amber
        : Theme.textLow

    // ---- header -----------------------------------------------------------
    Item {
        id: header

        width: parent.width
        height: Math.max(Theme.iconLarge + 8, headerText.implicitHeight)

        Item {
            id: markBox
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            width: Theme.iconLarge
            height: Theme.iconLarge

            Sym {
                id: headerMark
                anchors.centerIn: parent
                name: root.headerGlyph(root.spinning, root.finishedWithIssues,
                    root.rebootMark, root.failed, Updates.runCancelled,
                    Updates.total > 0, Updates.checkError !== "")
                size: Theme.iconLarge
                symWeight: 450
                color: root.failed ? (Updates.runCancelled ? Theme.textMid : Theme.redText)
                    : root.rebootMark || root.finishedWithIssues ? Theme.amber
                    : root.finished ? Theme.ok
                    : root.idle && !Updates.busy && Updates.checkError !== ""
                        && Updates.total === 0 ? Theme.amber
                    : Theme.accentText

                // Gated on visibility too: the popout keeps an outgoing
                // panel alive, hidden, until it closes. Stopping a value
                // source leaves the angle where it landed, which would tilt
                // the mark that replaces the arc.
                RotationAnimation on rotation {
                    running: root.spinning && headerMark.visible
                        && !Theme.reducedMotion
                    from: 0
                    to: 360
                    duration: 1400
                    loops: Animation.Infinite
                    onRunningChanged: if (!running) headerMark.rotation = 0
                }
            }
        }

        Column {
            id: headerText
            anchors.left: markBox.right
            anchors.leftMargin: 11
            anchors.right: headerAction.left
            anchors.rightMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2

            Text {
                width: parent.width
                text: root.title
                elide: Text.ElideRight
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.heading
                font.weight: Theme.weightSemibold
                font.features: Theme.tabularNumberFeatures
                color: Theme.textHi
            }

            Text {
                width: parent.width
                visible: text !== ""
                text: root.status
                wrapMode: root.failed ? Text.Wrap : Text.NoWrap
                elide: root.failed ? Text.ElideNone : Text.ElideRight
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.secondary
                font.weight: Theme.weightMedium
                font.features: Theme.tabularNumberFeatures
                color: root.statusColor
            }
        }

        // One control on the right, whichever this state has: a refresh, the
        // run's Cancel, or the failure's dismiss.
        Item {
            id: headerAction
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: cancelButton.visible ? cancelButton.width
                : refreshButton.visible || dismissButton.visible ? 32 : 0
            height: 32

            // The worker stops at its next safe boundary, so a requested
            // cancel stays pending while dnf or flatpak finish; once firmware
            // is being written or Ansible applies a release there is no
            // boundary left and the button goes.
            ActionButton {
                id: cancelButton
                visible: root.mode === "running" && Updates.cancelAllowed
                enabled: !Updates.cancelPending
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                label: "Cancel"
                hPadding: 22
                revealed: visible
                onTriggered: Updates.cancelRun()
            }

            HeaderIcon {
                id: refreshButton
                visible: root.idle || root.finished
                enabled: !Updates.busy
                glyph: "refresh"
                accessibleName: Updates.busy ? "Checking for updates" : "Check for updates"
                onTriggered: Updates.check()
            }

            HeaderIcon {
                id: dismissButton
                visible: root.failed
                glyph: "close"
                accessibleName: "Dismiss"
                onTriggered: Updates.dismissRun()
            }
        }
    }

    // 32 px square header control, shared by refresh and dismiss.
    component HeaderIcon: Rectangle {
        id: headerIcon

        property string glyph: ""
        property string accessibleName: ""

        signal triggered()

        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        width: 32
        height: 32
        radius: 10
        opacity: enabled ? 1 : 0.45
        color: headerIconMouse.containsMouse && enabled ? Theme.hoverFillStrong : Theme.chip
        border.width: activeFocus ? 1 : 0
        border.color: Theme.accentText
        activeFocusOnTab: visible && enabled
        Accessible.role: Accessible.Button
        Accessible.name: headerIcon.accessibleName
        Accessible.onPressAction: {
            if (headerIcon.enabled)
                headerIcon.triggered();
        }

        Keys.onPressed: event => {
            if (headerIcon.enabled && (event.key === Qt.Key_Return
                    || event.key === Qt.Key_Enter || event.key === Qt.Key_Space)) {
                headerIcon.triggered();
                event.accepted = true;
            }
        }

        Sym {
            anchors.centerIn: parent
            name: headerIcon.glyph
            size: Theme.iconSmall + 1
            color: Theme.textMid
        }

        MouseArea {
            id: headerIconMouse
            anchors.fill: parent
            enabled: headerIcon.enabled
            hoverEnabled: true
            cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
            onClicked: {
                headerIcon.forceActiveFocus();
                headerIcon.triggered();
            }
        }
    }

    // ---- the rows -----------------------------------------------------------
    // One row per kind of update. Four fixed rows rather than a Repeater over
    // a computed array: that array would re-evaluate on every transcript line
    // and rebuild its delegates, restarting their spinners mid-turn.
    //
    // rowState: "pending" (a count) | "waiting" | "active" | "done"
    //           | "attention" | "failed" | "skipped"
    component UpdateRow: Item {
        id: updateRow

        property string glyph: ""
        property string label: ""
        property string detail: ""
        property color detailColor: Theme.textLow
        property string rowState: "pending"
        property string count: ""
        // 0–1 while active; below zero hides the bar.
        property real progress: -1

        readonly property bool showBar: rowState === "active" && progress >= 0

        width: parent ? parent.width : 0
        height: Math.max(40, rowText.implicitHeight + 8) + (showBar ? 8 : 0)
        Accessible.role: Accessible.StaticText
        Accessible.name: updateRow.label + (updateRow.detail !== ""
            ? ", " + updateRow.detail : "")
            + (updateRow.count !== "" ? ", " + updateRow.count : "")

        Rectangle {
            id: rowMark
            x: 0
            y: (updateRow.height - (updateRow.showBar ? 8 : 0) - height) / 2
            width: 30
            height: 30
            radius: 9
            color: Theme.chip

            Sym {
                anchors.centerIn: parent
                name: updateRow.glyph
                size: Theme.iconSmall + 1
                color: updateRow.rowState === "skipped" ? Theme.textFaint : Theme.textMid
            }
        }

        Column {
            id: rowText
            anchors.left: rowMark.right
            anchors.leftMargin: 11
            anchors.right: rowEnd.left
            anchors.rightMargin: 8
            y: (updateRow.height - (updateRow.showBar ? 8 : 0) - implicitHeight) / 2
            spacing: 1

            Text {
                width: parent.width
                text: updateRow.label
                elide: Text.ElideRight
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.primary
                font.weight: Theme.weightMedium
                color: updateRow.rowState === "skipped" ? Theme.textLow : Theme.textHi
            }

            Text {
                width: parent.width
                visible: text !== ""
                text: updateRow.detail
                elide: Text.ElideRight
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.secondary
                font.weight: Theme.weightMedium
                font.features: Theme.tabularNumberFeatures
                color: updateRow.detailColor
            }
        }

        // The right-hand end: a count before the run, a result after it.
        Item {
            id: rowEnd
            anchors.right: parent.right
            y: (updateRow.height - (updateRow.showBar ? 8 : 0) - height) / 2
            width: Math.max(18, countText.visible ? countText.implicitWidth : 18)
            height: 18

            Text {
                id: countText
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                visible: updateRow.rowState === "pending" && updateRow.count !== ""
                text: updateRow.count
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.primary
                font.weight: Theme.weightSemibold
                font.features: Theme.tabularNumberFeatures
                color: Theme.accentText
            }

            Sym {
                id: stepMark
                anchors.centerIn: parent
                visible: updateRow.rowState !== "pending"
                name: root.rowGlyph(updateRow.rowState === "active",
                    updateRow.rowState === "done", updateRow.rowState === "failed",
                    updateRow.rowState === "attention")
                size: Theme.iconSmall + 2
                symWeight: 600
                color: updateRow.rowState === "active" ? Theme.accentText
                    : updateRow.rowState === "done" ? Theme.ok
                    : updateRow.rowState === "failed" ? Theme.redText
                    : updateRow.rowState === "attention" ? Theme.amber
                    : Theme.textFaint

                RotationAnimation on rotation {
                    running: updateRow.rowState === "active" && root.mode === "running"
                        && stepMark.visible && !Theme.reducedMotion
                    from: 0
                    to: 360
                    duration: 1400
                    loops: Animation.Infinite
                    onRunningChanged: if (!running) stepMark.rotation = 0
                }
            }
        }

        Rectangle {
            visible: updateRow.showBar
            anchors.left: rowText.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 2
            height: 3
            radius: 1.5
            color: Theme.hairlineSoft

            Rectangle {
                width: parent.width * Format.clamp01(updateRow.progress)
                height: parent.height
                radius: parent.radius
                color: Theme.accent

                Behavior on width {
                    NumberAnimation {
                        duration: Theme.chipFadeDuration
                        easing.type: Easing.OutCubic
                    }
                }
            }
        }
    }

    Column {
        id: rows

        visible: root.showSystem || root.showApps || root.showFirmware
            || root.showProject
        width: parent.width
        spacing: 4

        UpdateRow {
            id: systemRow

            visible: root.showSystem
            glyph: "computer"
            label: "System"
            count: String(Updates.dnfCount)
            rowState: root.idle ? "pending"
                : root.preparing ? "waiting"
                : !Updates.runDnfDone ? "active"
                : Updates.runDnfRc === 0 ? "done"
                : Updates.runCancelled ? "skipped" : "failed"
            progress: UpdatesHelpers.dnfFraction({ dnfDone: Updates.runDnfDone,
                dnfPhase: Updates.dnfPhase, dnfCur: Updates.dnfCur,
                dnfTotal: Updates.dnfTotal })
            detail: {
                if (root.idle)
                    return Updates.systemDetail;
                if (rowState === "waiting")
                    return "Waiting";
                if (rowState === "active")
                    return Updates.dnfPhase === "installing" && Updates.dnfTotal > 0
                        ? "Installing " + Updates.dnfCur + " of " + Updates.dnfTotal
                        : Updates.dnfPhase === "downloading" && Updates.dnfTotal > 0
                        ? "Downloading " + Updates.dnfCur + " of " + Updates.dnfTotal
                        : "Preparing…";
                if (rowState === "done")
                    return Updates.runPkgCount > 0
                        ? Updates.runPkgCount + " updated" : "Already up to date";
                if (rowState === "skipped")
                    return "Cancelled";
                return Updates.dnfPhase === "installing" && Updates.dnfCur > 0
                    ? "Stopped partway" : "Nothing was changed";
            }
            detailColor: rowState === "failed" ? Theme.redText : Theme.textLow
        }

        UpdateRow {
            id: appsRow

            visible: root.showApps
            glyph: "apps"
            label: "Apps"
            count: String(Updates.flatpakCount)
            rowState: root.idle ? "pending"
                : root.preparing ? "waiting"
                : !Updates.runFpDone ? (root.failed ? "skipped" : "active")
                : Updates.runFpRc !== 0 ? (root.failed ? "failed" : "attention")
                : "done"
            progress: Updates.fpTotal > 0 ? Updates.fpCur / Updates.fpTotal : -1
            detail: {
                if (root.idle)
                    return Updates.namesLabel(Updates.flatpakNames, Updates.flatpakCount);
                if (rowState === "waiting")
                    return "Waiting";
                if (rowState === "active")
                    return Updates.fpTotal > 0
                        ? "Updating " + Math.min(Updates.fpCur + 1, Updates.fpTotal)
                            + " of " + Updates.fpTotal
                        : "Checking…";
                if (rowState === "attention" || rowState === "failed")
                    return "Couldn’t update apps";
                if (rowState === "skipped")
                    return "Not started";
                return Updates.appCount > 0 ? Updates.appCount + " updated" : "Up to date";
            }
            detailColor: rowState === "attention" ? Theme.amber
                : rowState === "failed" ? Theme.redText : Theme.textLow
        }

        UpdateRow {
            id: firmwareRow

            visible: root.showFirmware
            glyph: "memory"
            label: "Firmware"
            count: String(Updates.firmwareCount)
            rowState: {
                if (root.idle)
                    return "pending";
                if (!Updates.runFwDone)
                    return Updates.backendPhase === "firmware" ? "active"
                        : root.failed ? "skipped" : "waiting";
                if (Updates.fwFailed > 0 || Updates.runFwRc !== 0)
                    return "attention";
                return Updates.fwInstalled > 0 || Updates.fwTotal > 0
                    || root.finished ? "done" : "skipped";
            }
            progress: Updates.fwTotal > 0
                ? (Updates.fwCur + Updates.fwFraction) / Updates.fwTotal : -1
            detail: {
                if (root.idle) {
                    if (Updates.firmwareNeedsPower)
                        return "Connect power to install";
                    return UpdatesHelpers.firmwareLabel(Updates.firmwareDevices)
                        + (Updates.firmwareDevices.some(device => device.needsReboot)
                            ? " · installs on restart" : "");
                }
                if (rowState === "waiting")
                    return "Waiting";
                if (rowState === "active")
                    return Updates.fwRequest !== "" ? "Waiting for you"
                        : UpdatesHelpers.firmwareStatusLabel(Updates.fwStatus,
                            Updates.fwPercent)
                            + (Updates.fwTotal > 1 ? " · " + Math.min(Updates.fwCur + 1,
                                Updates.fwTotal) + " of " + Updates.fwTotal : "");
                if (rowState === "attention")
                    return Updates.fwFailMessage;
                if (rowState === "skipped")
                    return root.failed ? "Not started" : "Up to date";
                return Updates.fwNeedsReboot ? "Installs when you restart"
                    : Updates.fwInstalled > 0 ? "Updated" : "Up to date";
            }
            detailColor: rowState === "attention" || root.idle && Updates.firmwareNeedsPower
                ? Theme.amber : Theme.textLow
        }

        // What fwupd needs the person to do right now — replug a dock, press
        // a button — in place of the terminal prompt it would otherwise use.
        Rectangle {
            visible: root.running && Updates.fwRequest !== ""
            width: parent.width
            height: requestText.implicitHeight + 20
            radius: Theme.tileRadius
            color: Theme.amberBgSoft
            border.width: 1
            border.color: Theme.amberBorder

            Sym {
                id: requestMark
                x: 12
                y: 10
                name: "info"
                size: Theme.iconSmall + 1
                color: Theme.amber
            }

            Text {
                id: requestText
                anchors.left: requestMark.right
                anchors.leftMargin: 9
                anchors.right: parent.right
                anchors.rightMargin: 12
                y: 10
                text: Updates.fwRequest
                wrapMode: Text.Wrap
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.secondary
                font.weight: Theme.weightSemibold
                color: Theme.textHi
            }
        }

        // fwupd's advice for after an update ("Unplug the dock to finish").
        Repeater {
            model: root.finished ? Updates.fwNotes : []

            delegate: Text {
                required property var modelData

                x: 41
                width: parent.width - 41
                text: modelData
                wrapMode: Text.Wrap
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.secondary
                font.weight: Theme.weightMedium
                color: Theme.textMid
            }
        }

        UpdateRow {
            id: projectRow

            visible: root.showProject
            glyph: "deployed_code_update"
            label: "CybexOS"
            count: Updates.projectVersion
            detail: Updates.projectApplyNote !== ""
                ? "To apply CybexOS " + Updates.projectVersion + ": "
                    + Updates.projectApplyNote : ""
            detailColor: Theme.amber
        }
    }

    // A release apply that stopped after Ansible began: the one failure
    // detail that belongs outside Details, because it needs an action.
    Text {
        visible: Updates.mixedState && root.failed
        width: parent.width
        text: UpdatesHelpers.mixedStateAdvice(Updates.mixedState)
        wrapMode: Text.Wrap
        font.family: Theme.fontMenu
        font.pixelSize: Theme.typography.secondary
        color: Theme.amber
    }

    // An earlier run's restart advice while more updates are waiting: the
    // primary action is the update, so the restart stays one step quieter.
    Row {
        visible: root.idle && root.rebootNeeded && root.primaryAction === "update"
        width: parent.width
        spacing: 9

        Sym {
            anchors.verticalCenter: parent.verticalCenter
            name: "restart_alt"
            size: Theme.iconSmall + 1
            color: Theme.amber
        }

        Text {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - Theme.iconSmall - 1 - restartLater.width
                - parent.spacing * 2
            text: UpdatesHelpers.rebootLabel(Updates.rebootRecommendation,
                Updates.kernelPending)
            elide: Text.ElideRight
            font.family: Theme.fontMenu
            font.pixelSize: Theme.typography.secondary
            font.weight: Theme.weightMedium
            color: Theme.amber
        }

        ActionButton {
            id: restartLater
            visible: Updates.rebootRecommended
            anchors.verticalCenter: parent.verticalCenter
            label: "Restart"
            tint: Theme.amber
            fill: Theme.amberBg
            hPadding: 14
            revealed: parent.visible
            onTriggered: Session.reboot()
        }
    }

    // ---- the one action -------------------------------------------------------
    Rectangle {
        id: primaryButton

        readonly property string label: root.primaryAction === "update"
            ? (root.updateCategories > 1 ? "Update all" : "Update")
            : root.primaryAction === "restart" ? "Restart now"
            : root.primaryAction === "retry" ? "Try again" : ""
        readonly property bool restarts: root.primaryAction === "restart"
        readonly property bool retries: root.primaryAction === "retry"
        readonly property string glyph: restarts ? "restart_alt"
            : retries ? "refresh" : "arrow_circle_up"

        function activate() {
            if (!enabled)
                return;
            // Restart is gated on Fedora's own needs-restarting result and
            // fwupd's staged capsules, never on the parsed kernel name.
            if (root.primaryAction === "restart")
                Session.reboot();
            else
                Updates.run(Updates.packagesOnly);
        }

        visible: root.primaryAction !== ""
        enabled: root.primaryAction !== "update" || !Updates.busy
        width: parent.width
        height: 40
        radius: 14
        opacity: enabled ? 1 : 0.45
        color: primaryMouse.containsMouse && enabled ? Theme.accent : Theme.accentSoft
        border.width: activeFocus ? 1 : 0
        border.color: Theme.accentText
        activeFocusOnTab: visible && enabled
        Accessible.role: Accessible.Button
        Accessible.name: primaryButton.label
        Accessible.onPressAction: primaryButton.activate()

        Keys.onPressed: event => {
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                    || event.key === Qt.Key_Space) {
                primaryButton.activate();
                event.accepted = true;
            }
        }

        Behavior on color {
            ColorAnimation { duration: Theme.chipFadeDuration }
        }

        scale: primaryMouse.pressed ? 0.98 : 1

        Behavior on scale {
            NumberAnimation {
                duration: Theme.pressDuration
                easing.type: Easing.BezierSpline
                easing.bezierCurve: Theme.springCurve
            }
        }

        Row {
            anchors.centerIn: parent
            spacing: 7

            Sym {
                anchors.verticalCenter: parent.verticalCenter
                name: primaryButton.glyph
                size: Theme.iconSmall + 1
                symWeight: 600
                color: primaryMouse.containsMouse && primaryButton.enabled
                    ? Theme.textOnAccent : Theme.accentText
            }

            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: primaryButton.label
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.control
                font.weight: Theme.weightMedium
                color: primaryMouse.containsMouse && primaryButton.enabled
                    ? Theme.textOnAccent : Theme.accentText
            }
        }

        MouseArea {
            id: primaryMouse
            anchors.fill: parent
            enabled: primaryButton.enabled
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
                primaryButton.forceActiveFocus();
                primaryButton.activate();
            }
        }
    }

    // ---- details --------------------------------------------------------------
    // Everything a person does not need to decide what to do next: the names
    // behind the counts, the live transaction, dnf's own error, the log.
    Item {
        id: detailsToggle

        visible: root.hasDetails
        width: parent.width
        height: 22

        Row {
            id: toggleRow
            anchors.left: parent.left
            anchors.leftMargin: 2
            anchors.verticalCenter: parent.verticalCenter
            spacing: 4

            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "Details"
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.secondary
                font.weight: Theme.weightSemibold
                font.underline: toggleFocus.activeFocus
                color: toggleMouse.containsMouse ? Theme.textHi : Theme.textLow
            }

            Sym {
                anchors.verticalCenter: parent.verticalCenter
                name: "expand_more"
                size: Theme.iconSmall
                color: toggleMouse.containsMouse ? Theme.textHi : Theme.textLow
                rotation: Updates.detailsOpen ? 180 : 0

                Behavior on rotation {
                    NumberAnimation {
                        duration: Theme.reducedMotion ? 0 : Theme.chipFadeDuration
                        easing.type: Easing.OutCubic
                    }
                }
            }
        }

        Item {
            id: toggleFocus
            anchors.fill: toggleRow
            activeFocusOnTab: root.hasDetails
            Accessible.role: Accessible.Button
            Accessible.name: Updates.detailsOpen ? "Hide details" : "Show details"
            Accessible.onPressAction: Updates.detailsOpen = !Updates.detailsOpen

            Keys.onPressed: event => {
                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                        || event.key === Qt.Key_Space) {
                    Updates.detailsOpen = !Updates.detailsOpen;
                    event.accepted = true;
                }
            }
        }

        MouseArea {
            id: toggleMouse
            anchors.fill: toggleRow
            anchors.margins: -4
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
                toggleFocus.forceActiveFocus();
                Updates.detailsOpen = !Updates.detailsOpen;
            }
        }

        LinkText {
            anchors.right: parent.right
            anchors.rightMargin: 2
            anchors.verticalCenter: parent.verticalCenter
            visible: Updates.detailsOpen && !root.idle && Updates.runStamp !== ""
            text: "Open full log"
            font.pixelSize: Theme.typography.secondary
            onClicked: Updates.openLog()
        }
    }

    component DetailBlock: Column {
        id: detailBlock

        property string heading: ""
        property string body: ""
        property color bodyColor: Theme.textMid
        property bool mono: false
        property int lines: 6

        width: parent ? parent.width : 0
        spacing: 3
        visible: body !== ""

        Text {
            width: parent.width
            visible: detailBlock.heading !== ""
            text: detailBlock.heading
            elide: Text.ElideRight
            font.family: Theme.fontMenu
            font.pixelSize: Theme.typography.metadata
            font.weight: Theme.weightSemibold
            font.letterSpacing: 0.4
            color: Theme.textFaint
        }

        Text {
            width: parent.width
            text: detailBlock.body
            wrapMode: Text.Wrap
            maximumLineCount: detailBlock.lines
            elide: Text.ElideRight
            font.family: detailBlock.mono ? Theme.fontMono : Theme.fontMenu
            font.pixelSize: Theme.typography.secondary
            font.weight: Theme.weightMedium
            color: detailBlock.bodyColor
        }
    }

    Column {
        id: details

        visible: root.hasDetails && Updates.detailsOpen
        width: parent.width
        spacing: 12

        // Before a run: the names behind each count.
        DetailBlock {
            visible: root.idle && body !== ""
            heading: "SYSTEM · " + Updates.dnfCount
            body: root.idle ? Updates.uniqueNames(Updates.dnfNames).join(", ") : ""
            lines: 8
        }

        DetailBlock {
            visible: root.idle && body !== ""
            heading: "APPS · " + Updates.flatpakCount
            body: root.idle ? Updates.uniqueNames(Updates.flatpakNames).join(", ") : ""
        }

        DetailBlock {
            visible: root.idle && body !== ""
            heading: "FIRMWARE · " + Updates.firmwareCount
            body: root.idle ? Updates.firmwareDevices.map(device => device.name
                + (device.from !== "" && device.to !== ""
                    ? "  " + device.from + " → " + device.to : "")).join("\n") : ""
        }

        DetailBlock {
            visible: root.idle && body !== ""
            heading: "COULDN’T CHECK"
            body: root.idle ? Updates.error : ""
            bodyColor: Theme.amber
        }

        // The run: the transaction, planned rows at half strength until the
        // worker reaches them, kept after it finishes as the transcript.
        Rectangle {
            id: feedTile

            visible: !root.idle && Updates.feed.count > 0
            width: parent.width
            height: Math.min(236, Updates.feed.count * 21 + 16)
            radius: Theme.tileRadius
            color: Theme.well
            border.width: 1
            border.color: Theme.hairlineSoft

            ListView {
                id: feedView

                // Tracks the row the transaction is working through; scrolling
                // away parks it until the view is back at its end.
                property bool following: true

                x: 12
                y: 8
                width: parent.width - 24
                height: parent.height - 16
                clip: true
                model: Updates.feed
                boundsBehavior: Flickable.StopAtBounds

                onMovementStarted: following = false
                onMovementEnded: {
                    if (atYEnd)
                        following = true;
                }

                Connections {
                    target: Updates

                    function onLastDoneIndexChanged() {
                        if (feedView.following && root.running
                                && Updates.lastDoneIndex >= 0)
                            feedView.positionViewAtIndex(Updates.lastDoneIndex,
                                ListView.Contain);
                    }
                }

                delegate: Row {
                    id: feedRow

                    required property var model
                    required property int index

                    // Widths come from TextMetrics, never from an elided
                    // Text's own implicitWidth — binding width to that loops,
                    // because eliding re-lays the text out. The name is the
                    // identity, so it is never the part that gives way.
                    readonly property real textBudget: width - 12 - spacing * 2
                    readonly property real nameWidth: Math.min(
                        nameMetrics.advanceWidth + 2, textBudget)
                    readonly property real verWidth: model.ver === "" ? 0
                        : Math.max(0, Math.min(verMetrics.advanceWidth + 2,
                            textBudget - nameWidth))

                    width: feedView.width
                    height: 21
                    spacing: 8
                    // Rows the transaction has not reached wait at half
                    // strength — while it runs, and after a failure, where
                    // they are exactly what was not installed.
                    opacity: (root.running || root.failed) && !model.done ? 0.45 : 1

                    Behavior on opacity {
                        NumberAnimation { duration: Theme.chipFadeDuration }
                    }

                    TextMetrics {
                        id: nameMetrics
                        font.family: Theme.fontMono
                        font.pixelSize: Theme.typography.secondary
                        font.weight: Theme.weightMedium
                        text: feedRow.model.name
                    }

                    TextMetrics {
                        id: verMetrics
                        font.family: Theme.fontMono
                        font.pixelSize: Theme.typography.secondary
                        font.weight: Theme.weightMedium
                        text: feedRow.model.ver
                    }

                    Sym {
                        anchors.verticalCenter: parent.verticalCenter
                        width: 12
                        name: root.verbIcon(feedRow.model.verb, feedRow.model.failed)
                        size: Theme.iconTiny
                        symWeight: 700
                        color: root.verbColor(feedRow.model.verb, feedRow.model.failed)
                    }

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        width: feedRow.nameWidth
                        text: feedRow.model.name
                        elide: Text.ElideRight
                        font.family: Theme.fontMono
                        font.pixelSize: Theme.typography.secondary
                        font.weight: Theme.weightMedium
                        color: Theme.textMid
                    }

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        width: feedRow.verWidth
                        visible: feedRow.model.ver !== "" && feedRow.verWidth > 24
                        text: feedRow.model.ver
                        elide: Text.ElideRight
                        font.family: Theme.fontMono
                        font.pixelSize: Theme.typography.secondary
                        font.weight: Theme.weightMedium
                        color: Theme.textFaint
                    }
                }
            }

            ScrollChrome {
                anchors.fill: parent
                anchors.topMargin: 2
                anchors.bottomMargin: 2
                target: feedView
                edgeColor: Qt.rgba(Theme.background.r, Theme.background.g,
                    Theme.background.b, 0.9)
            }
        }

        Text {
            visible: root.running && Updates.feed.count === 0
            width: parent.width
            text: "Waiting for the transaction…"
            font.family: Theme.fontMenu
            font.pixelSize: Theme.typography.secondary
            font.weight: Theme.weightMedium
            color: Theme.textFaint
        }

        // A failure: dnf's own last words, one line each so the final lines
        // (where the error is) are never the ones cut off.
        Column {
            visible: root.failed && Updates.failTail.length > 0
            width: parent.width
            spacing: 3

            Text {
                width: parent.width
                text: "WHAT DNF SAID"
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.metadata
                font.weight: Theme.weightSemibold
                font.letterSpacing: 0.4
                color: Theme.textFaint
            }

            Repeater {
                model: root.failed ? Updates.failTail.slice(-6) : []

                delegate: Text {
                    required property var modelData

                    readonly property bool problem: /error|failed|cannot|no space/i
                        .test(modelData)

                    width: parent.width
                    text: String(modelData).trim()
                    elide: Text.ElideRight
                    font.family: Theme.fontMono
                    font.pixelSize: Theme.typography.secondary
                    font.weight: problem ? Theme.weightSemibold : Theme.weightMedium
                    color: problem ? Theme.redText : Theme.textLow
                }
            }
        }

        // A failure before dnf wrote anything (the restore point, the start
        // itself): the worker's own message is all there is.
        DetailBlock {
            visible: root.failed && Updates.failTail.length === 0 && body !== ""
            heading: "WHAT HAPPENED"
            body: root.failed ? Updates.failHeadline : ""
            bodyColor: Theme.textLow
        }

        // The release step failed and the package run went ahead without it.
        DetailBlock {
            visible: !root.idle && body !== ""
            body: UpdatesHelpers.projectSkippedLabel(Updates.runProjectSkipped,
                root.mode !== "running")
            bodyColor: Theme.amber
        }

        DetailBlock {
            visible: !root.idle && body !== ""
            heading: "RECOVERY POINT"
            body: Updates.recoveryPointId
            bodyColor: Theme.textLow
            mono: true
            lines: 1
        }
    }
}
