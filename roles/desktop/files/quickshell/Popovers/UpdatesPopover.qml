pragma ComponentBehavior: Bound
import QtQuick
import "../Common"
import "../Common/Format.js" as Format
import "../Common/UpdatesHelpers.js" as UpdatesHelpers

// The dedicated Updates drawer: pending updates, the native run that installs
// them, and the transcript it leaves behind. PanelRegistryData attaches this
// surface to the right edge; using the shared drawer width keeps it on the
// current edge-drawer template without folding it into Control Dashboard.
//
// Four faces of one surface, keyed by Updates.runState: the pending list with
// the one button that starts the run; the live view — two step rows over a
// scrolling typeset transaction feed, the popover translation of ./update's
// terminal dashboard; the finished summary with the full transcript kept
// scrollable; and the failure, led by what went wrong with the log tail
// inline. All state lives in Common/Updates.qml — closing this panel mid-run
// interrupts nothing, which is what the footnote tells the user.
Surface {
    id: root

    readonly property string mode: Updates.runState

    // Match the current edge-drawer template in every state. Keeping one width
    // also prevents the surface shifting when a check turns into a live run.
    implicitWidth: Theme.drawerWidth
    spacing: 10

    readonly property var rows: {
        const out = [];
        if (Updates.dnfCount > 0)
            out.push({
                key: "dnf",
                glyph: "terminal",
                name: "System · dnf",
                sub: Updates.namesLabel(Updates.dnfNames, Updates.dnfCount),
                count: Updates.dnfCount
            });
        if (Updates.flatpakCount > 0)
            out.push({
                key: "flatpak",
                glyph: "widgets",
                name: "Flatpak",
                sub: Updates.namesLabel(Updates.flatpakNames, Updates.flatpakCount),
                count: Updates.flatpakCount
            });
        if (Updates.firmwareCount > 0)
            out.push({
                key: "firmware",
                glyph: "memory",
                name: "Firmware",
                sub: Updates.namesLabel(Updates.firmwareNames, Updates.firmwareCount),
                count: Updates.firmwareCount
            });
        if (Updates.projectAvailable)
            out.push({
                key: "cybexos",
                glyph: "deployed_code_update",
                name: "CybexOS",
                sub: "Release " + Updates.projectVersion,
                count: 1
            });
        return out;
    }

    function clock(stamp) {
        return Qt.formatTime(new Date(stamp), Settings.clock24 ? "HH:mm" : "h:mm ap");
    }

    function verbIcon(verb) {
        return verb === "add" ? "add" : verb === "del" ? "remove"
            : verb === "down" ? "arrow_downward" : "arrow_upward";
    }

    function verbColor(verb) {
        return verb === "add" ? Theme.accent : verb === "del" ? Theme.redText
            : verb === "down" ? Theme.amber : Theme.ok;
    }

    // Only ligature literals may appear in here: the icon-name test reads
    // every string in a *glyph* helper as a Material Symbols name.
    function headerGlyph(running, done, failed) {
        return running ? "progress_activity" : done ? "check_circle"
            : failed ? "error" : "deployed_code_update";
    }

    // ---- header ----------------------------------------------------------
    Row {
        width: parent.width
        spacing: 9

        readonly property real rightWidth: root.mode === "running"
            ? cancelButton.width + hideButton.width + parent.spacing
            : Theme.chipHeight

        // The state is in the mark, not in a filled square behind it: the bar
        // says "T3 • 1 running" the same way.
        Item {
            anchors.verticalCenter: parent.verticalCenter
            width: Theme.iconLarge
            height: Theme.iconLarge

            Sym {
                anchors.centerIn: parent
                name: root.headerGlyph(root.mode === "running",
                    root.mode === "done", root.mode === "failed")
                size: Theme.iconLarge
                symWeight: 450
                fill: root.mode === "done" || root.mode === "failed" ? 1 : 0
                color: root.mode === "done" ? Theme.ok
                    : root.mode === "failed" ? Theme.redText : Theme.accentText

                RotationAnimation on rotation {
                    running: root.mode === "running" && !Theme.reducedMotion
                    from: 0
                    to: 360
                    duration: 1400
                    loops: Animation.Infinite
                }
            }
        }

        Column {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - Theme.iconLarge - parent.rightWidth - parent.spacing * 2
            spacing: 1

            Text {
                width: parent.width
                text: root.mode === "running" ? "Updating"
                    : root.mode === "done"
                    ? (Updates.fpWarning !== "" ? "Updated with warnings" : "Up to date")
                    : root.mode === "failed" ? "Update failed" : "Updates"
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.secondary
                font.weight: Theme.weightSemibold
                color: Theme.textHi
            }

            Text {
                width: parent.width
                text: root.mode === "running"
                    ? Format.mmss(Updates.runElapsed) + " · "
                        + (Updates.flatpakEnabled ? "dnf and flatpak in parallel" : "dnf")
                    : root.mode === "done"
                    ? "finished " + root.clock(Updates.runFinishedAt)
                        + " · took " + Format.mmss(Updates.runDuration)
                    : root.mode === "failed"
                    ? "dnf gave up " + Format.mmss(Updates.runDuration) + " in"
                    : Updates.busy ? "Checking…"
                    : Updates.packageError !== "" ? Updates.packageError
                    : Updates.checkedLabel() + " · every "
                        + Settings.modOpts.updates.pollMins + " m"
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.metadata
                font.weight: Theme.weightSemibold
                font.features: Theme.tabularNumberFeatures
                color: root.mode === "idle" && Updates.packageError !== ""
                    ? Theme.redText : Theme.textFaint
                elide: Text.ElideRight
            }
        }

        Rectangle {
            id: refreshButton

            visible: root.mode === "idle" || root.mode === "done"
            anchors.verticalCenter: parent.verticalCenter
            width: 32
            height: 32
            radius: 10
            enabled: !Updates.busy && !Updates.firmwareInstalling
            opacity: enabled ? 1 : 0.45
            color: refreshMouse.containsMouse && enabled
                ? Theme.hoverFillStrong : Theme.chip
            activeFocusOnTab: visible
            Accessible.role: Accessible.Button
            Accessible.name: Updates.busy ? "Checking for updates" : "Check for updates"
            Accessible.onPressAction: {
                if (enabled)
                    Updates.check();
            }

            Keys.onPressed: event => {
                if (enabled && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                        || event.key === Qt.Key_Space)) {
                    Updates.check();
                    event.accepted = true;
                }
            }

            Sym {
                anchors.centerIn: parent
                name: "refresh"
                size: Theme.iconSmall + 1
                color: Updates.busy ? Theme.accentText : Theme.textMid
            }

            MouseArea {
                id: refreshMouse
                anchors.fill: parent
                enabled: parent.enabled
                hoverEnabled: true
                cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: {
                    refreshButton.forceActiveFocus();
                    Updates.check();
                }
            }
        }

        ActionButton {
            id: cancelButton
            visible: root.mode === "running"
            anchors.verticalCenter: parent.verticalCenter
            label: "Cancel"
            revealed: visible
            onTriggered: Updates.cancelRun()
        }

        ActionButton {
            id: hideButton
            visible: root.mode === "running"
            anchors.verticalCenter: parent.verticalCenter
            label: "Hide"
            revealed: visible
            onTriggered: Popouts.close()
        }

        Rectangle {
            id: dismissButton

            visible: root.mode === "failed"
            anchors.verticalCenter: parent.verticalCenter
            width: 32
            height: 32
            radius: 10
            color: dismissMouse.containsMouse ? Theme.hoverFillStrong : Theme.chip
            activeFocusOnTab: visible
            Accessible.role: Accessible.Button
            Accessible.name: "Dismiss failed update"
            Accessible.onPressAction: Updates.dismissRun()

            Keys.onPressed: event => {
                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                        || event.key === Qt.Key_Space) {
                    Updates.dismissRun();
                    event.accepted = true;
                }
            }

            Sym {
                anchors.centerIn: parent
                name: "close"
                size: Theme.iconSmall + 1
                color: Theme.textMid
            }

            MouseArea {
                id: dismissMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: Updates.dismissRun()
            }
        }
    }

    // ---- what is pending --------------------------------------------------
    Column {
        visible: root.mode === "idle"
        width: parent.width
        spacing: 6

        Repeater {
            model: root.mode === "idle" ? root.rows : []

            delegate: Rectangle {
                id: row

                required property var modelData

                width: parent.width
                height: 50
                radius: Theme.tileRadius
                color: Theme.tile

                Behavior on color {
                    ColorAnimation { duration: Theme.surfaceDuration }
                }

                Row {
                    anchors.fill: parent
                    anchors.leftMargin: 12
                    anchors.rightMargin: 12
                    spacing: 10

                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: 28
                        height: 28
                        radius: 9
                        color: Theme.chip

                        Sym {
                            anchors.centerIn: parent
                            name: row.modelData.glyph
                            size: Theme.iconSmall + 1
                            color: Theme.textMid
                        }
                    }

                    Column {
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width - 28 - countText.implicitWidth - parent.spacing * 2
                        spacing: 1

                        Text {
                            width: parent.width
                            text: row.modelData.name
                            font.family: Theme.fontMenu
                            font.pixelSize: Theme.typography.primary
                            font.weight: Theme.weightMedium
                            color: Theme.textHi
                            elide: Text.ElideRight
                        }

                        Text {
                            width: parent.width
                            text: row.modelData.sub
                            font.family: Theme.fontMenu
                            font.pixelSize: Theme.typography.secondary
                            font.weight: Theme.weightSemibold
                            color: Theme.textFaint
                            elide: Text.ElideRight
                        }
                    }

                    Text {
                        id: countText
                        anchors.verticalCenter: parent.verticalCenter
                        text: row.modelData.count
                        font.family: Theme.fontMenu
                        font.pixelSize: Theme.typography.secondary
                        font.weight: Theme.weightSemibold
                        font.features: Theme.tabularNumberFeatures
                        color: Theme.accentText
                    }
                }
            }
        }

        Item {
            visible: root.rows.length === 0
            width: parent.width
            height: 74

            Column {
                anchors.centerIn: parent
                spacing: 7

                Sym {
                    anchors.horizontalCenter: parent.horizontalCenter
                    name: Updates.busy ? "refresh"
                        : Updates.packageError !== "" ? "cloud_off" : "check_circle"
                    size: Theme.iconLarge
                    fill: Updates.busy || Updates.packageError !== "" ? 0 : 1
                    color: Updates.busy ? Theme.accentText
                        : Updates.packageError !== "" ? Theme.textFaint : Theme.accentText
                    opacity: 0.9
                }

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: Updates.busy ? "Checking for updates…"
                        : Updates.packageError !== "" || Updates.firmwareError !== "" ? "Could not check"
                        : Updates.packagesOnly ? "Packages up to date"
                        : Updates.wasPending ? "Updated · nothing pending" : "All up to date"
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.secondary
                    font.weight: Theme.weightBold
                    color: Theme.textMid
                }
            }
        }
    }

    Text {
        visible: root.mode === "idle" && Updates.projectError !== ""
        width: parent.width
        text: Updates.projectError + "\nPackage and firmware updates remain available."
        wrapMode: Text.Wrap
        font.family: Theme.fontMenu
        font.pixelSize: Theme.typography.metadata
        color: Theme.amber
    }

    Text {
        visible: root.mode === "idle" && Updates.firmwareError !== ""
        width: parent.width
        text: Updates.firmwareError
        wrapMode: Text.Wrap
        font.family: Theme.fontMenu
        font.pixelSize: Theme.typography.metadata
        color: Theme.amber
    }

    ActionButton {
        visible: root.mode === "idle" && (Updates.firmwareCount > 0 || Updates.firmwareInstalling)
        enabled: !Updates.busy && !Updates.firmwareInstalling
        revealed: visible
        label: Updates.firmwareInstalling ? "Firmware updater open…" : "Install firmware in terminal…"
        onTriggered: Updates.installFirmware()
    }

    // ---- act --------------------------------------------------------------
    Rectangle {
        id: goButton

        visible: root.mode === "idle" && (Updates.dnfCount > 0 || Updates.flatpakCount > 0
            || Updates.projectAvailable || Updates.packagesOnly)
        width: parent.width
        height: 38
        radius: 14
        enabled: !Updates.busy && !Updates.firmwareInstalling
        opacity: enabled ? 1 : 0.45
        color: goMouse.containsMouse ? Theme.accent : Theme.accentSoft

        Behavior on color {
            ColorAnimation { duration: Theme.chipFadeDuration }
        }

        scale: goMouse.pressed ? 0.98 : 1

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
                name: "arrow_circle_up"
                size: Theme.iconSmall + 1
                symWeight: 600
                color: goMouse.containsMouse ? Theme.textOnAccent : Theme.accentText
            }

            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: Updates.packagesOnly ? "Update packages only" : "Update now"
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.control
                font.weight: Theme.weightMedium
                color: goMouse.containsMouse ? Theme.textOnAccent : Theme.accentText
            }
        }

        MouseArea {
            id: goMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: Updates.run(Updates.packagesOnly)
        }
    }

    // ---- the run, live ----------------------------------------------------
    // Two fixed step rows rather than a Repeater over a computed array: the
    // array literal would re-evaluate on every feed line and rebuild both
    // delegates, restarting their spinners mid-turn.
    component StepLine: Column {
        id: stepLine

        property string label
        property color tint
        property int cur: 0
        property int total: 0
        property bool finished: false
        property int rc: 0
        property string idleText
        property string doneText
        // "downloading" / "installing" beside the dnf counter — the two
        // counters count different things, so the word is load-bearing.
        property string phaseWord: ""

        width: parent.width
        spacing: 7

        Row {
            width: parent.width
            spacing: 8

            Item {
                anchors.verticalCenter: parent.verticalCenter
                width: 14
                height: 14

                Sym {
                    anchors.centerIn: parent
                    name: !stepLine.finished ? "progress_activity"
                        : stepLine.rc === 0 ? "check_circle" : "error"
                    size: 13
                    symWeight: 600
                    fill: stepLine.finished ? 1 : 0
                    color: !stepLine.finished ? stepLine.tint
                        : stepLine.rc === 0 ? Theme.ok : Theme.redText

                    RotationAnimation on rotation {
                        running: !stepLine.finished && root.mode === "running"
                            && !Theme.reducedMotion
                        from: 0
                        to: 360
                        duration: 1400
                        loops: Animation.Infinite
                    }
                }
            }

            Text {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - 14 - stepMeta.implicitWidth
                    - parent.spacing * 2
                text: stepLine.label
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.primary
                font.weight: Theme.weightMedium
                color: Theme.textHi
                elide: Text.ElideRight
            }

            Text {
                id: stepMeta
                anchors.verticalCenter: parent.verticalCenter
                text: stepLine.finished
                    ? (stepLine.rc === 0 ? stepLine.doneText : "failed")
                    : stepLine.total > 0
                    ? (stepLine.phaseWord !== "" ? stepLine.phaseWord + " " : "")
                        + stepLine.cur + " / " + stepLine.total + " · "
                        + Math.floor(stepLine.cur * 100 / stepLine.total) + "%"
                    : stepLine.idleText
                font.family: Theme.fontMono
                font.pixelSize: Theme.typography.secondary
                font.weight: Theme.weightSemibold
                font.features: Theme.tabularNumberFeatures
                color: stepLine.finished && stepLine.rc !== 0
                    ? Theme.redText : Theme.textMid
            }
        }

        Rectangle {
            width: parent.width
            height: 4
            radius: 2
            color: Theme.hairlineSoft

            Rectangle {
                width: stepLine.finished && stepLine.rc === 0 ? parent.width
                    : stepLine.total > 0
                    ? parent.width * Math.min(1, stepLine.cur / stepLine.total)
                    : 0
                height: 4
                radius: 2
                color: stepLine.tint

                Behavior on width {
                    NumberAnimation {
                        duration: Theme.chipFadeDuration
                        easing.type: Easing.OutCubic
                    }
                }
            }
        }
    }

    Rectangle {
        visible: root.mode === "running"
        width: parent.width
        height: stepsColumn.implicitHeight + 24
        radius: Theme.tileRadius
        color: Theme.tile

        Column {
            id: stepsColumn
            x: 12
            y: 12
            width: parent.width - 24
            spacing: 11

            StepLine {
                label: "Recovery point"
                tint: Theme.amber
                finished: Updates.backendPhase !== "snapshot"
                rc: 0
                idleText: "snapshotting root & /boot…"
                doneText: Updates.recoveryPointId !== ""
                    ? Updates.recoveryPointId.slice(0, 16) : "not required"
            }

            StepLine {
                label: "System packages"
                tint: Theme.accent
                cur: Updates.dnfCur
                total: Updates.dnfTotal
                finished: Updates.runDnfDone
                rc: Updates.runDnfRc
                phaseWord: Updates.dnfPhase === "installing"
                    ? "installing" : "downloading"
                idleText: Updates.dnfPhase === "installing"
                    ? "preparing…" : "downloading & resolving…"
                doneText: Updates.runPkgCount > 0
                    ? Updates.runPkgCount + " packages" : "completed"
            }

            StepLine {
                visible: Updates.flatpakEnabled
                label: "Flatpaks"
                tint: Theme.feedFlatpak
                cur: Updates.fpCur
                total: Updates.fpTotal
                finished: Updates.runFpDone
                rc: Updates.runFpRc
                idleText: "looking for updates…"
                doneText: Updates.appCount > 0
                    ? Updates.appCount + " apps" : "up to date"
            }
        }
    }

    // ---- finished ---------------------------------------------------------
    Rectangle {
        visible: root.mode === "done"
        width: parent.width
        height: doneColumn.implicitHeight + 24
        radius: Theme.tileRadius
        color: Theme.okBgSoft
        border.width: 1
        border.color: Theme.okBorder

        Column {
            id: doneColumn
            x: 12
            y: 12
            width: parent.width - 24
            spacing: 4

            Text {
                width: parent.width
                text: {
                    const parts = [];
                    if (Updates.runPkgCount > 0)
                        parts.push(Updates.runPkgCount + " packages");
                    if (Updates.appCount > 0)
                        parts.push(Updates.appCount
                            + (Updates.appCount === 1 ? " app" : " apps"));
                    return parts.length > 0
                        ? parts.join(" · ") + " updated" : "Already up to date";
                }
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.secondary
                font.weight: Theme.weightSemibold
                color: Theme.ok
                elide: Text.ElideRight
            }

            Text {
                visible: text !== ""
                width: parent.width
                text: {
                    if (Updates.fpWarning !== "")
                        return Updates.fpWarning;
                    if (Updates.topNames.length === 0)
                        return "";
                    const extra = Updates.upCount + Updates.addCount
                        - Updates.topNames.length;
                    return Updates.topNames.join(" · ")
                        + (extra > 0 ? "  +" + extra + " more" : "");
                }
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.secondary
                font.weight: Theme.weightSemibold
                color: Updates.fpWarning !== "" ? Theme.amber : Theme.textFaint
                elide: Text.ElideRight
            }

            Text {
                visible: Updates.recoveryPointId !== ""
                width: parent.width
                text: "Recovery point · " + Updates.recoveryPointId
                font.family: Theme.fontMono
                font.pixelSize: Theme.typography.secondary
                color: Theme.textDim
                elide: Text.ElideRight
            }
        }
    }

    Rectangle {
        id: rebootOutcome

        readonly property bool recommended: Updates.rebootRecommendation
            === "recommended"
        readonly property bool notNeeded: Updates.rebootRecommendation
            === "not-needed"

        // Negative and unavailable confirmations retire with the completed
        // transcript. A positive remains actionable after that transcript is
        // dismissed, until the backend observes a different boot ID.
        visible: root.mode === "done"
            || (root.mode === "idle" && recommended)
        width: parent.width
        height: 40
        radius: Theme.tileRadius
        color: notNeeded ? Theme.okBgSoft : Theme.amberBgSoft
        border.width: 1
        border.color: notNeeded ? Theme.okBorder : Theme.amberBorder

        Row {
            anchors.fill: parent
            anchors.leftMargin: 12
            anchors.rightMargin: 6
            spacing: 9

            Sym {
                id: rebootIcon
                anchors.verticalCenter: parent.verticalCenter
                name: rebootOutcome.recommended ? "restart_alt"
                    : rebootOutcome.notNeeded ? "check_circle" : "warning"
                size: Theme.iconSmall + 2
                symWeight: 600
                fill: 1
                color: rebootOutcome.notNeeded ? Theme.ok : Theme.amber
            }

            Text {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - 15
                    - (restartButton.visible ? restartButton.width
                        + parent.spacing * 2 : parent.spacing)
                text: UpdatesHelpers.rebootLabel(
                    Updates.rebootRecommendation, Updates.kernelPending)
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.control
                font.weight: Theme.weightBold
                color: rebootOutcome.notNeeded ? Theme.ok : Theme.amber
                elide: Text.ElideRight
            }

            ActionButton {
                id: restartButton
                visible: rebootOutcome.recommended
                anchors.verticalCenter: parent.verticalCenter
                label: "Restart"
                tint: Theme.amber
                fill: Theme.amberBg
                hPadding: 12
                revealed: visible
                onTriggered: Session.reboot()
            }
        }
    }

    // ---- transaction feed -------------------------------------------------
    // One console for the live run and the finished transcript, so the scroll
    // position survives the moment the run completes — which is the whole
    // point of keeping the feed around.
    Rectangle {
        id: consoleTile

        visible: root.mode === "running" || root.mode === "done"
        width: parent.width
        // The live view holds a steady frame; the finished transcript takes
        // only the height its rows need, up to the same scrollback window.
        height: root.mode === "running" ? 300
            : Math.min(252, Updates.feed.count * 21 + 48)
        radius: Theme.tileRadius
        color: Theme.well
        border.width: 1
        border.color: Theme.hairlineSoft

        Behavior on height {
            NumberAnimation {
                duration: Theme.popoutMorphDuration
                easing.type: Easing.BezierSpline
                easing.bezierCurve: Theme.easeOutCurve
            }
        }

        Column {
            x: 14
            y: 12
            width: parent.width - 28
            spacing: 8

            Row {
                width: parent.width
                height: 16
                spacing: 10

                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width
                        - (liveBadge.visible ? liveBadge.width + parent.spacing : 0)
                        - (verbChips.visible ? verbChips.width + parent.spacing : 0)
                    text: "TRANSACTION" + (root.mode === "done"
                        ? " · " + root.clock(Updates.runStartedAt) : "")
                    font.family: Theme.fontMono
                    font.pixelSize: Theme.typography.metadata
                    font.weight: Theme.weightBold
                    font.letterSpacing: 1.1
                    color: Theme.textDim
                    elide: Text.ElideRight
                }

                Row {
                    id: liveBadge
                    visible: root.mode === "running"
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 5

                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: 6
                        height: 6
                        radius: 3
                        color: Theme.ok

                        SequentialAnimation on opacity {
                            running: liveBadge.visible && !Theme.reducedMotion
                            loops: Animation.Infinite
                            alwaysRunToEnd: false

                            NumberAnimation { to: 0.3; duration: 700; easing.type: Easing.InOutSine }
                            NumberAnimation { to: 1.0; duration: 700; easing.type: Easing.InOutSine }
                        }
                    }

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "LIVE"
                        font.family: Theme.fontMono
                        font.pixelSize: Theme.typography.metadata
                        font.weight: Theme.weightBold
                        font.letterSpacing: 0.5
                        color: Theme.ok
                    }
                }

                Row {
                    id: verbChips
                    visible: root.mode === "done"
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 10

                    Row {
                        visible: Updates.upCount > 0
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 3

                        Sym {
                            anchors.verticalCenter: parent.verticalCenter
                            name: "arrow_upward"
                            size: Theme.iconTiny
                            symWeight: 700
                            color: Theme.ok
                        }

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: Updates.upCount
                            font.family: Theme.fontMono
                            font.pixelSize: Theme.typography.metadata
                            font.weight: Theme.weightBold
                            font.features: Theme.tabularNumberFeatures
                            color: Theme.ok
                        }
                    }

                    Row {
                        visible: Updates.addCount > 0
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 3

                        Sym {
                            anchors.verticalCenter: parent.verticalCenter
                            name: "add"
                            size: Theme.iconTiny
                            symWeight: 700
                            color: Theme.accentText
                        }

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: Updates.addCount
                            font.family: Theme.fontMono
                            font.pixelSize: Theme.typography.metadata
                            font.weight: Theme.weightBold
                            font.features: Theme.tabularNumberFeatures
                            color: Theme.accentText
                        }
                    }

                    Row {
                        visible: Updates.delCount > 0
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 3

                        Sym {
                            anchors.verticalCenter: parent.verticalCenter
                            name: "remove"
                            size: Theme.iconTiny
                            symWeight: 700
                            color: Theme.redText
                        }

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: Updates.delCount
                            font.family: Theme.fontMono
                            font.pixelSize: Theme.typography.metadata
                            font.weight: Theme.weightBold
                            font.features: Theme.tabularNumberFeatures
                            color: Theme.redText
                        }
                    }
                }
            }

            ListView {
                id: feedView

                // Tracks the row the transaction is working through; scrolling
                // away parks it and the pill below offers the way back. The
                // plan itself lands top-down, so appends never scroll.
                property bool following: true

                width: parent.width
                height: consoleTile.height - 24 - 16 - parent.spacing
                clip: true
                model: Updates.feed
                interactive: true
                boundsBehavior: Flickable.StopAtBounds

                onMovementStarted: following = false
                onMovementEnded: {
                    if (atYEnd)
                        following = true;
                }

                Connections {
                    target: Updates

                    function onLastDoneIndexChanged() {
                        if (feedView.following && root.mode === "running"
                                && Updates.lastDoneIndex >= 0)
                            feedView.positionViewAtIndex(Updates.lastDoneIndex,
                                ListView.Contain);
                    }
                }

                delegate: Row {
                    id: feedRow

                    required property var model
                    required property int index

                    readonly property bool newest: root.mode === "running"
                        && index === Updates.lastDoneIndex

                    // Planned rows wait at half strength and light up as the
                    // transaction reaches them — the whole plan is readable
                    // from the start, nothing truncated to make it "stream".
                    opacity: root.mode === "running" && !model.done ? 0.45 : 1

                    Behavior on opacity {
                        NumberAnimation { duration: Theme.chipFadeDuration }
                    }

                    // Widths come from TextMetrics, never from an elided
                    // Text's own implicitWidth — binding width to that loops,
                    // because eliding re-lays the text out. The name is the
                    // identity, so it is never the part that gives way: the
                    // version yields, down to hiding entirely on the rare row
                    // where the name alone fills the line.
                    readonly property real textBudget: width - 26 - 11
                        - spacing * 3
                    readonly property real nameWidth: Math.min(
                        nameMetrics.advanceWidth + 2, textBudget)
                    readonly property real verWidth: model.ver === "" ? 0
                        : Math.max(0, Math.min(verMetrics.advanceWidth + 2,
                            textBudget - nameWidth))

                    width: feedView.width
                    height: 21
                    spacing: 8

                    TextMetrics {
                        id: nameMetrics
                        font.family: Theme.fontMono
                        font.pixelSize: Theme.typography.secondary
                        font.weight: Theme.weightSemibold
                        text: feedRow.model.name
                    }

                    TextMetrics {
                        id: verMetrics
                        font.family: Theme.fontMono
                        font.pixelSize: Theme.typography.secondary
                        font.weight: Theme.weightMedium
                        text: feedRow.model.ver
                    }

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        width: 26
                        text: feedRow.model.tag
                        font.family: Theme.fontMono
                        font.pixelSize: Theme.typography.secondary
                        font.weight: Theme.weightBold
                        color: feedRow.model.tag === "dnf"
                            ? Theme.feedDnf : Theme.feedFlatpak
                    }

                    Sym {
                        anchors.verticalCenter: parent.verticalCenter
                        width: 11
                        name: root.verbIcon(feedRow.model.verb)
                        size: Theme.iconTiny
                        symWeight: 700
                        color: root.verbColor(feedRow.model.verb)
                    }

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        width: feedRow.nameWidth
                        text: feedRow.model.name
                        font.family: Theme.fontMono
                        font.pixelSize: Theme.typography.primary
                        font.weight: feedRow.newest
                            ? Theme.weightSemibold : Theme.weightMedium
                        color: feedRow.newest ? Theme.textHi : Theme.textMid
                        elide: Text.ElideRight
                    }

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        width: feedRow.verWidth
                        visible: feedRow.model.ver !== "" && feedRow.verWidth > 24
                        text: feedRow.model.ver
                        font.family: Theme.fontMono
                        font.pixelSize: Theme.typography.secondary
                        font.weight: Theme.weightMedium
                        color: feedRow.newest ? Theme.textMid : Theme.textFaint
                        elide: Text.ElideRight
                    }
                }

                Text {
                    visible: feedView.count === 0
                    anchors.centerIn: parent
                    text: "waiting for the transaction…"
                    font.family: Theme.fontMono
                    font.pixelSize: Theme.typography.secondary
                    font.weight: Theme.weightMedium
                    color: Theme.textFaint
                }
            }
        }

        ScrollChrome {
            anchors.fill: parent
            anchors.topMargin: 36
            anchors.bottomMargin: 2
            target: feedView
            edgeColor: Qt.rgba(Theme.background.r, Theme.background.g,
                Theme.background.b, 0.9)
        }

        // The way back to the tail after scrolling into the history mid-run.
        Rectangle {
            visible: root.mode === "running" && !feedView.following
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 10
            width: jumpRow.implicitWidth + 22
            height: 26
            radius: 13
            color: jumpMouse.containsMouse ? Theme.accent : Theme.accentSoft

            Behavior on color {
                ColorAnimation { duration: Theme.chipFadeDuration }
            }

            Row {
                id: jumpRow
                anchors.centerIn: parent
                spacing: 5

                Sym {
                    anchors.verticalCenter: parent.verticalCenter
                    name: "arrow_downward"
                    size: Theme.iconTiny + 1
                    symWeight: 600
                    color: jumpMouse.containsMouse ? Theme.textOnAccent : Theme.accentText
                }

                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Live"
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.secondary
                    font.weight: Theme.weightMedium
                    color: jumpMouse.containsMouse ? Theme.textOnAccent : Theme.accentText
                }
            }

            MouseArea {
                id: jumpMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    feedView.following = true;
                    feedView.positionViewAtEnd();
                }
            }
        }
    }

    // ---- failed -----------------------------------------------------------
    Rectangle {
        visible: root.mode === "failed"
        width: parent.width
        height: failColumn.implicitHeight + 24
        radius: Theme.tileRadius
        color: Theme.redBgSoft
        border.width: 1
        border.color: Theme.redBorder

        Column {
            id: failColumn
            x: 12
            y: 12
            width: parent.width - 24
            spacing: 4

            Text {
                width: parent.width
                text: Updates.failHeadline
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.secondary
                font.weight: Theme.weightSemibold
                color: Theme.redText
                elide: Text.ElideRight
            }

            Text {
                width: parent.width
                text: {
                    const parts = [];
                    parts.push(Updates.dnfCur > 0
                        ? "transaction interrupted — check the log"
                        : "system packages unchanged");
                    if (Updates.flatpakEnabled && Updates.runFpDone
                            && Updates.runFpRc === 0)
                        parts.push(Updates.appCount > 0
                            ? "flatpaks finished (" + Updates.appCount + " apps)"
                            : "flatpaks up to date");
                    return parts.join(" · ");
                }
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.secondary
                font.weight: Theme.weightSemibold
                color: Theme.textFaint
                elide: Text.ElideRight
            }
        }
    }

    Rectangle {
        visible: root.mode === "failed" && Updates.failTail.length > 0
        width: parent.width
        height: tailColumn.implicitHeight + 24
        radius: Theme.tileRadius
        color: Theme.well
        border.width: 1
        border.color: Theme.hairlineSoft

        Column {
            id: tailColumn
            x: 14
            y: 12
            width: parent.width - 28
            spacing: 8

            Text {
                width: parent.width
                text: "DNF.LOG · LAST LINES"
                font.family: Theme.fontMono
                font.pixelSize: Theme.typography.metadata
                font.weight: Theme.weightBold
                font.letterSpacing: 1.1
                color: Theme.textDim
                elide: Text.ElideRight
            }

            Repeater {
                model: Updates.failTail

                delegate: Text {
                    required property var modelData

                    width: parent.width
                    text: modelData
                    font.family: Theme.fontMono
                    font.pixelSize: Theme.typography.secondary
                    font.weight: /error|failed/i.test(modelData)
                        ? Theme.weightBold : Theme.weightMedium
                    color: /error|failed/i.test(modelData)
                        ? Theme.redText : Theme.textLow
                    elide: Text.ElideRight
                }
            }
        }
    }

    Rectangle {
        id: retryButton

        visible: root.mode === "failed"
        width: parent.width
        height: 38
        radius: 14
        color: retryMouse.containsMouse ? Theme.accent : Theme.accentSoft

        Behavior on color {
            ColorAnimation { duration: Theme.chipFadeDuration }
        }

        scale: retryMouse.pressed ? 0.98 : 1

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
                name: "arrow_circle_up"
                size: Theme.iconSmall + 1
                symWeight: 600
                color: retryMouse.containsMouse ? Theme.textOnAccent : Theme.accentText
            }

            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: Updates.packagesOnly ? "Retry packages only" : "Retry update"
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.control
                font.weight: Theme.weightMedium
                color: retryMouse.containsMouse ? Theme.textOnAccent : Theme.accentText
            }
        }

        MouseArea {
            id: retryMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: Updates.run(Updates.packagesOnly)
        }
    }

    // ---- footer -----------------------------------------------------------
    Row {
        visible: root.mode === "done" || root.mode === "failed"
        width: parent.width
        spacing: 10

        LinkText {
            id: logLink
            anchors.verticalCenter: parent.verticalCenter
            text: "Open full log"
            onClicked: Updates.openLog("dnf.log")
        }

        Text {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - logLink.width - parent.spacing
            horizontalAlignment: Text.AlignRight
            text: Updates.runLogLabel
            font.family: Theme.fontMono
            font.pixelSize: Theme.typography.secondary
            font.weight: Theme.weightMedium
            font.features: Theme.tabularNumberFeatures
            color: Theme.textFaint
            elide: Text.ElideLeft
        }
    }

    Item {
        visible: root.mode === "idle" || root.mode === "running"
        width: parent.width
        height: footnote.implicitHeight + 2

        Text {
            id: footnote
            x: 4
            width: parent.width - 8
            text: root.mode === "running"
                ? "keeps running if you close this panel — the bar chip tracks progress"
                : Updates.busy ? "checking packages and firmware"
                : Updates.firmwareInstalling ? "Follow the firmware updater’s instructions in the terminal"
                : Updates.firmwareCount > 0 ? "Firmware installs separately with device and reboot prompts"
                : root.rows.length > 0
                ? "sudo dnf upgrade" + (Settings.modOpts.updates.flatpak
                    ? " · flatpak update" : "") + " — streams live here"
                : "Package and firmware metadata are refreshed by system timers"
            font.family: Theme.fontMenu
            font.pixelSize: Theme.typography.secondary
            font.weight: Theme.weightSemibold
            color: Theme.textFaint
            elide: Text.ElideRight
        }
    }
}
