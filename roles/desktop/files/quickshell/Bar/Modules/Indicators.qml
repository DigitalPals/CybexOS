pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import ".."
import "../../Common"
import "../../Common/SettingsHelpers.js" as SettingsHelpers

// Clock-side quick actions. Inactive and active actions live in distinct
// blocks: disclosure grows outward, while active actions stay pinned against
// the clock. Both blocks retain the user's configured relative ordering.
BarModule {
    id: root

    moduleId: "indicators"
    readonly property string panelName: "reminders"
    readonly property string ocrScript:
        Quickshell.env("HOME") + "/.local/bin/screen-ocr"
    spacing: 2
    property bool disclosureLatched: false
    property var actionButtons: []

    readonly property var actionCatalog: {
        const catalog = {};
        for (const action of SettingsHelpers.INDICATOR_ACTION_CHOICES)
            catalog[action.id] = action;
        return catalog;
    }
    // No Settings.revision here: it is bumped by every save (a wallpaper
    // shuffle included), and modOpts is reassigned — never mutated in place —
    // so reading Settings.modOpts.indicators already tracks every edit.
    readonly property var actions: SettingsHelpers.availableIndicatorIds(
            Settings.modOpts.indicators.order, Dictation.available)
        .map(id => actionCatalog[id]).filter(action => action !== undefined)
    readonly property string actionStateKey: [
        Dictation.state, Recorder.active, Reminders.count,
        SysInfo.nightLight, Notifs.dnd, SysInfo.idleInhibited
    ].join(":")
    readonly property bool reminderOpen: host !== null
        && host.popoutOpen("reminders")
    readonly property bool revealInactive: Settings.modOpts.indicators.mode === "always"
        || (Settings.modOpts.indicators.mode === "hover"
            && (disclosureLatched || reminderOpen))
    readonly property bool disclosureAnimating: inactiveRevealer.widthAnimating
    // The two Repeaters are fed id lists parsed back out of a string: the
    // string only notifies when membership or order really changes, so a
    // re-evaluation that lands on the same ids leaves the buttons (their
    // registered anchors, tooltips and spinners) alone. Each button
    // looks its catalog entry up by id.
    readonly property string inactiveActionsKey: {
        void actionStateKey;
        return JSON.stringify(actions
            .filter(action => actionEnabled(action.id) && !isActive(action.id))
            .map(action => action.id));
    }
    readonly property string activeActionsKey: {
        void actionStateKey;
        return JSON.stringify(actions.filter(action => isActive(action.id)
            && (actionEnabled(action.id) || mandatoryWhileActive(action.id)))
            .map(action => action.id));
    }
    readonly property var inactiveActions: JSON.parse(inactiveActionsKey)
    readonly property var activeActions: JSON.parse(activeActionsKey)

    function actionEnabled(id) {
        return Settings.modOpts.indicators.enabled.indexOf(id) !== -1;
    }

    function mandatoryWhileActive(id) {
        return id === "dictation" || id === "recording";
    }

    function isActive(id) {
        switch (id) {
        case "dictation": return Dictation.busy;
        case "recording": return Recorder.active;
        case "ocr": return false;
        case "reminder": return Reminders.count > 0;
        case "night-light": return SysInfo.nightLight;
        case "dnd": return Notifs.dnd;
        case "stay-awake": return SysInfo.idleInhibited;
        default: return false;
        }
    }

    function shortDuration(seconds) {
        const minutes = Math.max(1, Math.ceil(seconds / 60));
        if (minutes < 60)
            return minutes + "m";
        return Math.floor(minutes / 60) + "h"
            + (minutes % 60 === 0 ? "" : " " + (minutes % 60) + "m");
    }

    function labelFor(id) {
        if (id === "recording" && Recorder.active
                && Settings.modOpts.indicators.recordingShowElapsed)
            return Recorder.elapsedLabel;
        if (id === "reminder" && Reminders.count > 0
                && Settings.modOpts.indicators.reminderDisplay === "count")
            return String(Reminders.count);
        if (id === "stay-awake" && SysInfo.idleInhibited
                && SysInfo.idleInhibitUntilMs > 0
                && Settings.modOpts.indicators.idleShowRemaining)
            return shortDuration(SysInfo.idleInhibitRemainingSecs);
        return "";
    }

    function registerAction(button) {
        if (actionButtons.indexOf(button) === -1)
            actionButtons = actionButtons.concat([button]);
        if (host !== null && button.actionId === "reminder")
            host.registerPanel("reminders", button);
    }

    function unregisterAction(button) {
        actionButtons = actionButtons.filter(candidate => candidate !== button);
        if (host !== null && button.actionId === "reminder")
            host.unregisterPanel("reminders", button);
    }

    function tooltipFor(id) {
        switch (id) {
        case "dictation":
            return Dictation.recording ? "Stop dictation"
                : Dictation.transcribing ? "Cancel transcription"
                : "Dictate in " + Settings.modOpts.indicators.dictationPrimaryLanguage
                    + (Settings.modOpts.indicators.dictationSecondaryLanguage === "off"
                        ? "" : " · middle click "
                            + Settings.modOpts.indicators.dictationSecondaryLanguage);
        case "recording":
            return Recorder.active ? "Stop recording" + (Recorder.outputFile !== ""
                ? " · " + Recorder.outputFile.split("/").pop() : "")
                : "Record a " + Settings.modOpts.indicators.recordingMode;
        case "ocr":
            return "OCR a region · copies text · Super Shift O";
        case "reminder":
            return Reminders.tooltip + (Settings.modOpts.indicators.reminderClick === "quick-add"
                ? " · click adds " + Settings.modOpts.indicators.reminderMinutes + " min"
                : " · middle click adds " + Settings.modOpts.indicators.reminderMinutes + " min");
        case "night-light":
            return (SysInfo.nightLight ? "Turn off night light" : "Turn on night light")
                + " · middle click settings";
        case "dnd":
            return (Notifs.dnd ? "Turn off Do Not Disturb · " + Notifs.dndStatus
                : "Turn on Do Not Disturb") + " · middle click settings";
        case "stay-awake":
            return (SysInfo.idleInhibited ? "Allow idle and sleep · "
                + SysInfo.idleInhibitStatus : "Stay awake · "
                    + Settings.modOpts.indicators.idleDefaultMode)
                + " · middle click durations";
        default: return "";
        }
    }

    function trigger(id, button, mouseButton) {
        switch (id) {
        case "dictation":
            Dictation.toggle(mouseButton === Qt.MiddleButton
                ? Settings.modOpts.indicators.dictationSecondaryLanguage
                : Settings.modOpts.indicators.dictationPrimaryLanguage);
            break;
        case "recording":
            Recorder.toggle(Settings.modOpts.indicators.recordingMode);
            break;
        case "ocr":
            Quickshell.execDetached([root.ocrScript]);
            break;
        case "reminder": {
            const primaryAdds = Settings.modOpts.indicators.reminderClick === "quick-add";
            const add = mouseButton === Qt.MiddleButton ? !primaryAdds : primaryAdds;
            if (add)
                Reminders.add(Settings.modOpts.indicators.reminderMinutes, "");
            else
                host.togglePopout("reminders", isle, button);
            break;
        }
        case "night-light":
            if (mouseButton === Qt.MiddleButton)
                Settings.showPanel("system", host.outputName);
            else
                SysInfo.toggleNightLight();
            break;
        case "dnd":
            if (mouseButton === Qt.MiddleButton)
                Settings.showPanel("notifications", host.outputName);
            else
                Notifs.toggleDefaultDnd();
            break;
        case "stay-awake":
            if (mouseButton === Qt.MiddleButton)
                Settings.showPanel("system", host.outputName);
            else
                SysInfo.toggleIdleInhibited();
            break;
        }
    }

    onGroupHoveredChanged: {
        if (groupHovered && Settings.modOpts.indicators.mode === "hover") {
            collapseDelay.stop();
            disclosureLatched = true;
        }
    }

    onHostChanged: {
        if (host === null)
            return;
        host.indicatorDisclosureAnimating = disclosureAnimating;
        for (const button of actionButtons) {
            if (button.actionId === "reminder")
                host.registerPanel("reminders", button);
        }
    }

    onDisclosureAnimatingChanged: {
        if (host !== null)
            host.indicatorDisclosureAnimating = disclosureAnimating;
    }

    Connections {
        target: root.host
        enabled: root.host !== null

        function onTooltipPointerInsideChanged() {
            if (root.host.tooltipPointerInside || root.host.popoutActive) {
                collapseDelay.stop();
            } else if (Settings.modOpts.indicators.mode === "hover") {
                collapseDelay.restart();
            }
        }
    }
    Connections {
        target: Popouts
        function onChanged() {
            // A detached view can take hover away from the bar even with a
            // stationary pointer. Preserve disclosure for the whole menu
            // session so its targets cannot move underneath that pointer.
            // Only Reminders needs to reveal an otherwise collapsed strip.
            if (root.host !== null && root.host.popoutActive) {
                collapseDelay.stop();
                if (root.reminderOpen)
                    root.disclosureLatched = true;
            } else if (root.host !== null && !root.host.tooltipPointerInside
                    && Settings.modOpts.indicators.mode === "hover") {
                collapseDelay.restart();
            }
        }
    }

    Timer {
        id: collapseDelay
        interval: 180
        onTriggered: {
            if (root.host !== null && !root.host.tooltipPointerInside
                    && !root.host.popoutActive
                    && Settings.modOpts.indicators.mode === "hover")
                root.disclosureLatched = false;
        }
    }

    component IndicatorAction: Rectangle {
        id: button
        required property string modelData
        readonly property string actionId: modelData
        readonly property var action: root.actionCatalog[actionId] ?? ({})
        readonly property bool activeState: root.isActive(actionId)
        readonly property bool recording: actionId === "recording" && Recorder.active
        readonly property bool transcribing: actionId === "dictation" && Dictation.transcribing
        readonly property string actionLabel: root.labelFor(actionId)
        readonly property color ink: recording ? Theme.barRedFg
            : activeState ? Theme.barAccent
            : hovered ? Theme.barTextHi : Theme.barTextDim
        readonly property bool hovered: actionHover.over

        height: Theme.chipInnerHeight
        width: contents.implicitWidth + (actionLabel === "" ? 12 : 16)
        radius: Theme.chipRadius
        color: recording ? Theme.barRed : "transparent"
        scale: actionMouse.pressed ? 0.92 : 1
        Accessible.role: Accessible.Button
        Accessible.name: root.tooltipFor(actionId)
        Accessible.onPressAction: root.trigger(actionId, button, Qt.LeftButton)

        Behavior on width {
            NumberAnimation {
                duration: Theme.expandDuration
                easing.type: Easing.BezierSpline
                easing.bezierCurve: Theme.springCurve
            }
        }
        Behavior on color { ColorAnimation { duration: Theme.chipFadeDuration } }
        Behavior on scale {
            NumberAnimation {
                duration: Theme.pressDuration
                easing.type: Easing.BezierSpline
                easing.bezierCurve: Theme.springCurve
            }
        }

        BarHover {
            id: actionHover
            anchors.fill: parent
            host: root.host
            target: button
            radius: button.radius
            pressed: actionMouse.pressed
            tint: button.recording ? Theme.barRedFg : Theme.barTextHi
            pressPoint: Qt.point(actionMouse.mouseX, actionMouse.mouseY)
        }

        Row {
            id: contents
            anchors.centerIn: parent
            spacing: button.actionLabel === "" ? 0 : 5

            Sym {
                id: actionGlyph
                anchors.verticalCenter: parent.verticalCenter
                name: button.transcribing ? "progress_activity" : (button.action.glyph ?? "")
                size: Theme.iconSmall + 2
                symWeight: 550
                color: button.ink
                // A recording blinks on the elapsed timer's own 1 Hz tick,
                // stepped rather than eased. A continuous pulse repainted
                // every bar at display rate for the whole recording, and
                // handed the screen recorder a new frame to encode each time.
                opacity: button.recording && !Theme.reducedMotion
                    && Recorder.elapsed % 2 === 1 ? 0.45 : 1

                RotationAnimation on rotation {
                    running: button.transcribing && !Theme.reducedMotion
                    from: 0
                    to: 360
                    duration: 850
                    loops: Animation.Infinite
                }
            }

            Text {
                visible: button.actionLabel !== ""
                anchors.verticalCenter: parent.verticalCenter
                text: button.actionLabel
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.bar
                font.weight: Theme.weightSemibold
                font.features: Theme.tabularNumberFeatures
                color: button.ink
            }
        }

        MouseArea {
            id: actionMouse
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton | Qt.MiddleButton
            cursorShape: Qt.PointingHandCursor
            onEntered: {
                if (button.actionId === "reminder")
                    root.host.hoverPopout("reminders", root.isle, button);
            }
            onPositionChanged: {
                if (button.actionId === "reminder")
                    root.host.hoverPopout("reminders", root.isle, button);
            }
            onClicked: mouse => root.trigger(button.actionId, button, mouse.button)
        }

        BarTooltip {
            check: actionHover.check
            text: root.tooltipFor(button.actionId)
            align: -1
            y: button.height + 8
            x: 0
        }

        Component.onCompleted: root.registerAction(button)
        Component.onDestruction: root.unregisterAction(button)
    }

    Revealer {
        id: inactiveRevealer
        orientation: Qt.Horizontal
        reveal: root.revealInactive
        opacity: reveal ? 0.58 : 0

        Row {
            spacing: 2
            Repeater {
                model: root.inactiveActions
                delegate: IndicatorAction {}
            }
        }
    }

    Row {
        spacing: 2
        Repeater {
            model: root.activeActions
            delegate: IndicatorAction {}
        }
    }

    Component.onDestruction: {
        if (host !== null)
            host.indicatorDisclosureAnimating = false;
    }
}
