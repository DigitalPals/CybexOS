pragma ComponentBehavior: Bound
import QtQuick
import "../Common"
import "../Common/SettingsHelpers.js" as SettingsHelpers
import "../Common/Format.js" as Format

// Built-in options shared by the bar editor and standalone detail view.
// The detail policy control lives here (storage stays in Settings.mods);
// everything else reads and writes Settings.modOpts through setModuleOption.
SettingsPage {
    id: view

    required property string moduleId
    required property string moduleName
    property bool hasDetail: false
    // The editor supplies the heading and scroll container when embedded.
    property bool inlineMode: false
    signal backRequested()

    readonly property var indicatorMeta: {
        const out = {};
        for (const action of SettingsHelpers.INDICATOR_ACTION_CHOICES)
            out[action.id] = action;
        return out;
    }
    property int indicatorDragIndex: -1
    property int indicatorDropIndex: -1
    readonly property bool indicatorDragActive: indicatorDragIndex !== -1
    readonly property int indicatorRowPitch: 36

    readonly property var opts: Settings.modOpts[moduleId] ?? ({})
    // The old options component can survive one binding update while switching widgets.
    // Actions this installation cannot run are not shown (and cannot be
    // dragged), but keep their saved place; see mergeIndicatorOrder.
    readonly property var indicatorOrder: SettingsHelpers.availableIndicatorIds(
        opts.order || [], Dictation.available)
    readonly property var indicatorEnabledIds: opts.enabled || []
    onModuleIdChanged: {
        cancelIndicatorDrag();
        flushSettling();
    }
    readonly property var optDefaults: Settings.defaults.modOpts[moduleId] ?? ({})
    readonly property var modEntry: {
        const mods = Settings.mods;
        for (const col of ["left", "center", "right"]) {
            const hit = mods[col].find(m => m.id === view.moduleId);
            if (hit)
                return hit;
        }
        return { detail: "auto" };
    }

    function focusFirst() {
        if (!view.inlineMode)
            backAction.forceActiveFocus();
    }

    function optDirty(key) {
        return view.optValue(key) !== view.optDefaults[key];
    }

    function setOpt(key, value) {
        Settings.setModuleOption(view.moduleId, key, value);
    }

    function resetOpt(key) {
        view.dropSettling(key);
        Settings.setModuleOption(view.moduleId, key, view.optDefaults[key]);
    }

    // Sliders report every step of a drag, and each modOpts write clones and
    // normalizes every option and notifies every consumer (the calendar's
    // look-ahead respawns its event helper). Hold the dragged value here and
    // store it where the drag rests.
    property var settlingOpts: ({})
    property string settlingModule: ""

    function optValue(key) {
        return Object.prototype.hasOwnProperty.call(view.settlingOpts, key)
            ? view.settlingOpts[key] : view.opts[key];
    }

    function settleOpt(key, value) {
        if (view.settlingModule !== view.moduleId)
            view.flushSettling();
        const next = Object.assign({}, view.settlingOpts);
        next[key] = value;
        view.settlingModule = view.moduleId;
        view.settlingOpts = next;
        optSettle.restart();
    }

    function dropSettling(key) {
        if (!Object.prototype.hasOwnProperty.call(view.settlingOpts, key))
            return;
        const next = Object.assign({}, view.settlingOpts);
        delete next[key];
        view.settlingOpts = next;
    }

    function flushSettling() {
        optSettle.stop();
        const changes = view.settlingOpts;
        const id = view.settlingModule;
        view.settlingOpts = {};
        view.settlingModule = "";
        if (id !== "" && Object.keys(changes).length > 0)
            Settings.setModuleOptions(id, changes);
    }

    Timer {
        id: optSettle
        interval: 300
        onTriggered: view.flushSettling()
    }

    Component.onDestruction: flushSettling()

    function indicatorEnabled(id) {
        return view.indicatorEnabledIds.indexOf(id) !== -1;
    }

    function setIndicatorEnabled(id, enabled) {
        let next = view.indicatorEnabledIds.filter(candidate => candidate !== id);
        if (enabled)
            next.push(id);
        // Store enablement in the saved order, hidden actions included, so
        // hand-edited settings remain readable and deterministic.
        next = (view.opts.order || []).filter(candidate => next.indexOf(candidate) !== -1);
        view.setOpt("enabled", next);
    }

    function beginIndicatorDrag(index) {
        indicatorDragIndex = index;
        indicatorDropIndex = index;
        const id = view.indicatorOrder[index];
        Settings.announcement = view.indicatorMeta[id].label
            + " picked up. Use arrow keys to move.";
    }

    function moveIndicatorDrop(delta) {
        if (!indicatorDragActive)
            return;
        indicatorDropIndex = Math.max(0, Math.min(view.indicatorOrder.length - 1,
            indicatorDropIndex + delta));
    }

    function cancelIndicatorDrag() {
        indicatorDragIndex = -1;
        indicatorDropIndex = -1;
    }

    function commitIndicatorDrag() {
        if (!indicatorDragActive)
            return;
        const from = indicatorDragIndex;
        const to = indicatorDropIndex;
        const ids = view.indicatorOrder.slice();
        const moved = ids[from];
        cancelIndicatorDrag();
        if (from === to)
            return;
        ids.splice(from, 1);
        ids.splice(to, 0, moved);
        view.setOpt("order", SettingsHelpers.mergeIndicatorOrder(ids, view.opts.order || []));
        Settings.announcement = view.indicatorMeta[moved].label
            + " moved to position " + (to + 1) + ".";
    }

    function setNumericOpt(key, text) {
        if (text.trim() !== "")
            setOpt(key, Number(text));
    }

    Column {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Theme.settingsContentSpacing

        Row {
            visible: !view.inlineMode
            height: visible ? implicitHeight : 0
            spacing: Theme.settingsContentSpacing

            SettingsAction {
                id: backAction
                text: "Widgets"
                glyph: "arrow_back"
                Accessible.name: "Back to widgets"
                onTriggered: view.backRequested()
            }

            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: view.moduleName
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.title
                font.weight: Theme.weightSemibold
                color: Theme.textHi
            }
        }

        SectionHeader {
            visible: !view.inlineMode
            label: "OPTIONS"
        }

        PickerRow {
            visible: view.hasDetail
            width: parent.width
            label: "Detail"
            model: [
                { value: "auto", label: "Auto" },
                { value: "prefer", label: "Prefer detail" },
                { value: "compact", label: "Always compact" }
            ]
            current: view.modEntry.detail
            dirty: view.modEntry.detail !== "auto"
            onPicked: value => Settings.setModuleDetail(view.moduleId, value)
            onResetRequested: Settings.setModuleDetail(view.moduleId, "auto")
        }

        Loader {
            width: parent.width
            sourceComponent: {
                switch (view.moduleId) {
                case "ws": return wsOptions;
                case "control": return controlOptions;
                case "media": return mediaOptions;
                case "indicators": return indicatorsOptions;
                case "clock": return clockOptions;
                case "weather": return weatherOptions;
                case "notes": return notesOptions;
                case "t3": return t3Options;
                case "hermes": return hermesOptions;
                case "usage": return usageOptions;
                case "gh": return ghOptions;
                case "notifications": return notificationsOptions;
                case "vol": return volOptions;
                case "batt": return battOptions;
                case "updates": return updatesOptions;
                case "tray": return trayOptions;
                default: return null;
                }
            }
        }
    }

    Component {
        id: indicatorsOptions

        Column {
            spacing: Theme.settingsGroupSpacing

            SettingsGroup {
                width: parent.width
                title: "Behavior"

                PickerRow {
                    width: parent.width
                    label: "Visibility"
                    model: [
                        { value: "hover", label: "Clock hover" },
                        { value: "always", label: "Always show" },
                        { value: "active", label: "Active only" }
                    ]
                    current: view.opts.mode
                    dirty: view.optDirty("mode")
                    onPicked: value => view.setOpt("mode", value)
                    onResetRequested: view.resetOpt("mode")
                }
            }

            SettingsGroup {
                width: parent.width
                title: "Actions"

                Text {
                    width: parent.width
                    leftPadding: Theme.settingsMarkInset
                    bottomPadding: 4
                    text: "Drag to reorder. Hidden recording"
                        + (Dictation.available ? " and dictation" : "")
                        + " controls still return while active so they can be stopped."
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.secondary
                    color: Theme.textDim
                    wrapMode: Text.Wrap
                }

                Item {
                    width: parent.width
                    height: view.indicatorOrder.length * view.indicatorRowPitch

                    Column {
                        width: parent.width
                        spacing: 2

                        Repeater {
                            id: indicatorActionRepeater
                            model: view.indicatorOrder

                            delegate: Rectangle {
                                id: indicatorRow

                                required property string modelData
                                required property int index
                                readonly property var meta: view.indicatorMeta[modelData]
                                readonly property bool shown: view.indicatorEnabled(modelData)
                                readonly property bool dragged: view.indicatorDragIndex === index

                                width: parent.width
                                height: view.indicatorRowPitch - 2
                                radius: Theme.rowRadius
                                color: "transparent"
                                opacity: dragged ? 0.35 : 1
                                border.width: activeFocus ? 1 : 0
                                border.color: Theme.accentText
                                activeFocusOnTab: index === 0
                                Accessible.role: Accessible.ListItem
                                Accessible.name: meta.label + " indicator"
                                Accessible.description: view.indicatorDragActive
                                    ? "Drag in progress" : "Press Space to pick up"
                                Accessible.selected: dragged
                                Accessible.onPressAction: {
                                    if (view.indicatorDragActive)
                                        view.commitIndicatorDrag();
                                    else
                                        view.beginIndicatorDrag(index);
                                }

                                Keys.onPressed: event => {
                                    if (event.key === Qt.Key_Space) {
                                        if (view.indicatorDragActive)
                                            view.commitIndicatorDrag();
                                        else
                                            view.beginIndicatorDrag(index);
                                        event.accepted = true;
                                    } else if (event.key === Qt.Key_Escape
                                            && view.indicatorDragActive) {
                                        view.cancelIndicatorDrag();
                                        event.accepted = true;
                                    } else if (view.indicatorDragActive
                                            && (event.key === Qt.Key_Up
                                                || event.key === Qt.Key_Down)) {
                                        view.moveIndicatorDrop(event.key === Qt.Key_Up ? -1 : 1);
                                        event.accepted = true;
                                    } else if (!view.indicatorDragActive
                                            && (event.key === Qt.Key_Up
                                                || event.key === Qt.Key_Down)) {
                                        const next = indicatorActionRepeater.itemAt(index
                                            + (event.key === Qt.Key_Up ? -1 : 1));
                                        if (next)
                                            next.forceActiveFocus();
                                        event.accepted = true;
                                    }
                                }

                                MouseArea {
                                    id: indicatorDragArea
                                    anchors.left: parent.left
                                    anchors.top: parent.top
                                    anchors.bottom: parent.bottom
                                    anchors.right: indicatorToggle.left
                                    cursorShape: view.indicatorDragActive
                                        ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                                    preventStealing: true
                                    property real pressY

                                    onPressed: mouse => pressY = mouse.y
                                    onPositionChanged: mouse => {
                                        if (!view.indicatorDragActive) {
                                            if (Math.abs(mouse.y - pressY) < 4)
                                                return;
                                            view.beginIndicatorDrag(indicatorRow.index);
                                        }
                                        const local = indicatorDragArea.mapToItem(
                                            indicatorRow.parent, mouse.x, mouse.y);
                                        view.indicatorDropIndex = Math.max(0, Math.min(
                                            view.indicatorOrder.length - 1,
                                            Math.floor(local.y / view.indicatorRowPitch)));
                                    }
                                    onReleased: {
                                        if (view.indicatorDragActive)
                                            view.commitIndicatorDrag();
                                    }
                                    onCanceled: view.cancelIndicatorDrag()
                                    onClicked: indicatorRow.forceActiveFocus()
                                }

                                Text {
                                    id: indicatorHandle
                                    anchors.left: parent.left
                                    anchors.leftMargin: 4
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: "⠿"
                                    font.family: Theme.fontMono
                                    font.pixelSize: Theme.typography.metadata
                                    color: Theme.textDim
                                }

                                Sym {
                                    id: indicatorGlyph
                                    anchors.left: indicatorHandle.right
                                    anchors.leftMargin: 10
                                    anchors.verticalCenter: parent.verticalCenter
                                    name: indicatorRow.meta.glyph
                                    size: Theme.iconMedium
                                    color: indicatorRow.shown ? Theme.icon : Theme.textFaint
                                }

                                Text {
                                    id: indicatorLabel
                                    anchors.left: indicatorGlyph.right
                                    anchors.leftMargin: 10
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 130
                                    text: indicatorRow.meta.label
                                    font.family: Theme.fontMenu
                                    font.pixelSize: Theme.typography.control
                                    font.weight: Theme.weightMedium
                                    color: indicatorRow.shown ? Theme.textHi : Theme.textLow
                                    elide: Text.ElideRight
                                }

                                Text {
                                    anchors.left: indicatorLabel.right
                                    anchors.leftMargin: 8
                                    anchors.right: indicatorToggle.left
                                    anchors.rightMargin: 10
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: indicatorRow.shown ? "available"
                                        : (indicatorRow.modelData === "dictation"
                                            || indicatorRow.modelData === "recording")
                                            ? "hidden at rest · shown while active" : "hidden"
                                    font.family: Theme.fontMenu
                                    font.pixelSize: Theme.typography.secondary
                                    color: Theme.textDim
                                    elide: Text.ElideRight
                                }

                                Toggle {
                                    id: indicatorToggle
                                    anchors.right: parent.right
                                    anchors.rightMargin: 8
                                    anchors.verticalCenter: parent.verticalCenter
                                    metrics: Theme.switchCompact
                                    checked: indicatorRow.shown
                                    accessibleName: "Show " + indicatorRow.meta.label
                                    onToggled: value => view.setIndicatorEnabled(
                                        indicatorRow.modelData, value)
                                }
                            }
                        }
                    }

                    Rectangle {
                        visible: view.indicatorDragActive
                        x: 2
                        width: parent.width - 4
                        height: 2
                        radius: 1
                        y: Math.max(0, view.indicatorDropIndex) * view.indicatorRowPitch - 1
                            + (view.indicatorDropIndex > view.indicatorDragIndex
                                ? view.indicatorRowPitch - 2 : 0)
                        color: Theme.accent
                        z: 10
                    }
                }
            }

            SettingsGroup {
                visible: Dictation.available
                width: parent.width
                title: "Dictation"

                SettingsTextRow {
                    width: parent.width
                    label: "Primary language"
                    value: view.opts.dictationPrimaryLanguage
                    placeholder: "en, nl, auto, or a comma-separated list"
                    dirty: view.optDirty("dictationPrimaryLanguage")
                    onCommitted: text => view.setOpt("dictationPrimaryLanguage", text)
                    onResetRequested: view.resetOpt("dictationPrimaryLanguage")
                }

                SettingsTextRow {
                    width: parent.width
                    label: "Alternate language"
                    value: view.opts.dictationSecondaryLanguage
                    placeholder: "Middle click · use off to disable"
                    dirty: view.optDirty("dictationSecondaryLanguage")
                    onCommitted: text => view.setOpt("dictationSecondaryLanguage", text)
                    onResetRequested: view.resetOpt("dictationSecondaryLanguage")
                }

                PickerRow {
                    width: parent.width
                    label: "Model"
                    model: SettingsHelpers.DICTATION_MODEL_CHOICES
                    current: view.opts.dictationModel
                    dirty: view.optDirty("dictationModel")
                    onPicked: value => view.setOpt("dictationModel", value)
                    onResetRequested: view.resetOpt("dictationModel")
                }
            }

            SettingsGroup {
                width: parent.width
                title: "Screen recording"

                PickerRow {
                    width: parent.width
                    label: "Capture"
                    model: [
                        { value: "region", label: "Region" },
                        { value: "window", label: "Window" },
                        { value: "screen", label: "Screen" }
                    ]
                    current: view.opts.recordingMode
                    dirty: view.optDirty("recordingMode")
                    onPicked: value => view.setOpt("recordingMode", value)
                    onResetRequested: view.resetOpt("recordingMode")
                }

                SwitchRow {
                    width: parent.width
                    label: "Elapsed time"
                    description: "Show the running duration beside the recording icon"
                    checked: view.opts.recordingShowElapsed
                    dirty: view.optDirty("recordingShowElapsed")
                    onToggled: value => view.setOpt("recordingShowElapsed", value)
                    onResetRequested: view.resetOpt("recordingShowElapsed")
                }
            }

            SettingsGroup {
                width: parent.width
                title: "Reminders"

                PickerRow {
                    width: parent.width
                    label: "Active display"
                    model: [
                        { value: "icon", label: "Icon" },
                        { value: "count", label: "Count" }
                    ]
                    current: view.opts.reminderDisplay
                    dirty: view.optDirty("reminderDisplay")
                    onPicked: value => view.setOpt("reminderDisplay", value)
                    onResetRequested: view.resetOpt("reminderDisplay")
                }

                PickerRow {
                    width: parent.width
                    label: "Primary click"
                    model: [
                        { value: "list", label: "Open list" },
                        { value: "quick-add", label: "Quick add" }
                    ]
                    current: view.opts.reminderClick
                    dirty: view.optDirty("reminderClick")
                    onPicked: value => view.setOpt("reminderClick", value)
                    onResetRequested: view.resetOpt("reminderClick")
                }

                PickerRow {
                    width: parent.width
                    label: "Quick add"
                    model: [5, 15, 30, 60].map(minutes =>
                        ({ value: minutes, label: minutes + " min" }))
                    current: view.opts.reminderMinutes
                    dirty: view.optDirty("reminderMinutes")
                    onPicked: value => view.setOpt("reminderMinutes", value)
                    onResetRequested: view.resetOpt("reminderMinutes")
                }
            }

            SettingsGroup {
                width: parent.width
                title: "Night light"

                PickerRow {
                    width: parent.width
                    label: "At sign-in"
                    model: [
                        { value: "remember", label: "Remember" },
                        { value: "off", label: "Off" },
                        { value: "on", label: "On" }
                    ]
                    current: view.opts.nightLightStartup
                    dirty: view.optDirty("nightLightStartup")
                    onPicked: value => view.setOpt("nightLightStartup", value)
                    onResetRequested: view.resetOpt("nightLightStartup")
                }

                ResponsiveActionRow {
                    width: parent.width
                    description: "Temperature and schedule live on the System page"

                    SettingsAction {
                        text: "Temperature settings"
                        glyph: "arrow_forward"
                        onTriggered: Settings.page = "system"
                    }
                }
            }

            SettingsGroup {
                width: parent.width
                title: "Do Not Disturb"

                PickerRow {
                    width: parent.width
                    label: "At sign-in"
                    model: [
                        { value: "remember", label: "Remember" },
                        { value: "off", label: "Off" },
                        { value: "on", label: "On" }
                    ]
                    current: view.opts.dndStartup
                    dirty: view.optDirty("dndStartup")
                    onPicked: value => view.setOpt("dndStartup", value)
                    onResetRequested: view.resetOpt("dndStartup")
                }

                PickerRow {
                    width: parent.width
                    label: "Primary click"
                    model: [
                        { value: "always", label: "Until off" },
                        { value: "1h", label: "1 hour" },
                        { value: "quiet-boundary", label: "Quiet boundary" }
                    ]
                    current: view.opts.dndDefaultMode
                    dirty: view.optDirty("dndDefaultMode")
                    onPicked: value => view.setOpt("dndDefaultMode", value)
                    onResetRequested: view.resetOpt("dndDefaultMode")
                }

                ResponsiveActionRow {
                    width: parent.width
                    description: "Quiet hours live on the Notifications page"

                    SettingsAction {
                        text: "Quiet-hours settings"
                        glyph: "arrow_forward"
                        onTriggered: Settings.page = "notifications"
                    }
                }
            }

            SettingsGroup {
                width: parent.width
                title: "Stay awake"

                PickerRow {
                    width: parent.width
                    label: "At sign-in"
                    model: [
                        { value: "remember", label: "Remember" },
                        { value: "off", label: "Off" },
                        { value: "on", label: "On" }
                    ]
                    current: view.opts.idleStartup
                    dirty: view.optDirty("idleStartup")
                    onPicked: value => view.setOpt("idleStartup", value)
                    onResetRequested: view.resetOpt("idleStartup")
                }

                PickerRow {
                    width: parent.width
                    label: "Primary click"
                    model: [
                        { value: "30m", label: "30 min" },
                        { value: "1h", label: "1 hour" },
                        { value: "unplugged", label: "Until unplugged" },
                        { value: "always", label: "Until off" }
                    ]
                    current: view.opts.idleDefaultMode
                    dirty: view.optDirty("idleDefaultMode")
                    onPicked: value => view.setOpt("idleDefaultMode", value)
                    onResetRequested: view.resetOpt("idleDefaultMode")
                }

                SwitchRow {
                    width: parent.width
                    label: "Time remaining"
                    description: "Show the remaining time directly beside a timed icon"
                    checked: view.opts.idleShowRemaining
                    dirty: view.optDirty("idleShowRemaining")
                    onToggled: value => view.setOpt("idleShowRemaining", value)
                    onResetRequested: view.resetOpt("idleShowRemaining")
                }

                Text {
                    width: parent.width
                    leftPadding: Theme.settingsMarkInset + Theme.settingsLabelWidth
                    text: "Sign-in policy applies after login or reboot. Restarting only the menubar resumes its current state and original deadline."
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.secondary
                    color: Theme.textDim
                    wrapMode: Text.Wrap
                }
            }
        }
    }

    Component {
        id: wsOptions

        Column {
            spacing: Theme.settingsContentSpacing

            SliderRow {
                width: parent.width
                label: "Min slots"
                min: 1
                max: 10
                step: 1
                value: view.optValue("minSlots")
                unit: ""
                dirty: view.optDirty("minSlots")
                onMoved: value => view.settleOpt("minSlots", value)
                onResetRequested: view.resetOpt("minSlots")
            }

            SwitchRow {
                width: parent.width
                label: "Hide empty"
                description: "Only show workspaces that have windows"
                checked: view.opts.hideEmpty
                dirty: view.optDirty("hideEmpty")
                onToggled: value => view.setOpt("hideEmpty", value)
                onResetRequested: view.resetOpt("hideEmpty")
            }

            PickerRow {
                width: parent.width
                label: "Style"
                model: [
                    { value: "numbers", label: "Numbers" },
                    { value: "dots", label: "Dots" }
                ]
                current: view.opts.style
                dirty: view.optDirty("style")
                onPicked: value => view.setOpt("style", value)
                onResetRequested: view.resetOpt("style")
            }
        }
    }

    Component {
        id: mediaOptions

        Column {
            spacing: Theme.settingsContentSpacing

            PickerRow {
                width: parent.width
                label: "Title"
                model: [
                    { value: "title-artist", label: "Title — Artist" },
                    { value: "title", label: "Title" },
                    { value: "artist-title", label: "Artist — Title" }
                ]
                current: view.opts.titleFormat
                dirty: view.optDirty("titleFormat")
                onPicked: value => view.setOpt("titleFormat", value)
                onResetRequested: view.resetOpt("titleFormat")
            }

            SliderRow {
                width: parent.width
                label: "Max width"
                min: 120
                max: 360
                step: 20
                value: view.optValue("maxWidth")
                dirty: view.optDirty("maxWidth")
                onMoved: value => view.settleOpt("maxWidth", value)
                onResetRequested: view.resetOpt("maxWidth")
            }
        }
    }

    Component {
        id: clockOptions

        Column {
            spacing: Theme.settingsContentSpacing

            SwitchRow {
                width: parent.width
                label: "Seconds"
                description: "Tick every second instead of every minute"
                checked: view.opts.seconds
                dirty: view.optDirty("seconds")
                onToggled: value => view.setOpt("seconds", value)
                onResetRequested: view.resetOpt("seconds")
            }

            SwitchRow {
                width: parent.width
                label: "Date"
                description: "Show the date next to the time"
                checked: view.opts.showDate
                dirty: view.optDirty("showDate")
                onToggled: value => view.setOpt("showDate", value)
                onResetRequested: view.resetOpt("showDate")
            }

            PickerRow {
                width: parent.width
                label: "Date format"
                model: ["ddd dd", "ddd d MMM", "dd MMM", "dd-MM"].map(fmt =>
                    ({ value: fmt, label: Qt.formatDateTime(new Date(), fmt) }))
                current: view.opts.dateFormat
                dirty: view.optDirty("dateFormat")
                onPicked: value => view.setOpt("dateFormat", value)
                onResetRequested: view.resetOpt("dateFormat")
            }

            SwitchRow {
                width: parent.width
                label: "Events"
                description: "Show upcoming system-calendar events in the popover"
                checked: view.opts.showEvents
                dirty: view.optDirty("showEvents")
                onToggled: value => view.setOpt("showEvents", value)
                onResetRequested: view.resetOpt("showEvents")
            }

            SliderRow {
                visible: view.opts.showEvents
                width: parent.width
                label: "Look ahead"
                min: 1
                max: 31
                step: 1
                value: view.optValue("daysAhead")
                unit: value === 1 ? "day" : "days"
                valueWidth: 62
                dirty: view.optDirty("daysAhead")
                onMoved: value => view.settleOpt("daysAhead", value)
                onResetRequested: view.resetOpt("daysAhead")
            }

            SliderRow {
                visible: view.opts.showEvents
                width: parent.width
                label: "Refresh"
                min: 5
                max: 60
                step: 5
                value: view.optValue("pollMins")
                unit: "min"
                // Match Look ahead so both tracks end at the same edge.
                valueWidth: 62
                dirty: view.optDirty("pollMins")
                onMoved: value => view.settleOpt("pollMins", value)
                onResetRequested: view.resetOpt("pollMins")
            }

            ResponsiveActionRow {
                visible: view.opts.showEvents
                width: parent.width
                description: "Add or remove calendar accounts"

                SettingsAction {
                    text: "Online accounts"
                    glyph: "manage_accounts"
                    onTriggered: Calendar.manageAccounts()
                }
            }

            Text {
                width: parent.width
                leftPadding: Theme.settingsMarkInset + Theme.settingsLabelWidth
                text: "12/24-hour time is set on the System page. Google sign-in is handled by GNOME Online Accounts; credentials never enter Quickshell."
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.secondary
                color: Theme.textDim
                wrapMode: Text.Wrap
            }
        }
    }

    Component {
        id: weatherOptions

        Column {
            spacing: Theme.settingsContentSpacing

            SettingsTextRow {
                width: parent.width
                label: "Place"
                value: view.opts.place
                placeholder: "Shown on the chip and popover"
                dirty: view.optDirty("place")
                onCommitted: text => view.setOpt("place", text)
                onResetRequested: view.resetOpt("place")
            }

            SettingsTextRow {
                width: parent.width
                label: "Latitude"
                numeric: true
                value: String(view.opts.lat)
                dirty: view.optDirty("lat")
                onCommitted: text => view.setNumericOpt("lat", text)
                onResetRequested: view.resetOpt("lat")
            }

            SettingsTextRow {
                width: parent.width
                label: "Longitude"
                numeric: true
                value: String(view.opts.lon)
                dirty: view.optDirty("lon")
                onCommitted: text => view.setNumericOpt("lon", text)
                onResetRequested: view.resetOpt("lon")
            }

            SliderRow {
                width: parent.width
                label: "Update every"
                min: 5
                max: 60
                step: 5
                value: view.optValue("pollMins")
                unit: "min"
                dirty: view.optDirty("pollMins")
                onMoved: value => view.settleOpt("pollMins", value)
                onResetRequested: view.resetOpt("pollMins")
            }
        }
    }

    Component {
        id: notesOptions

        Column {
            spacing: Theme.settingsContentSpacing

            PickerRow {
                width: parent.width
                label: "Title provider"
                model: [
                    { value: "off", label: "Off" },
                    { value: "codex", label: "Codex CLI" },
                    { value: "claude", label: "Claude Code CLI" }
                ]
                current: view.opts.titleProvider
                dirty: view.optDirty("titleProvider")
                onPicked: value => view.setOpt("titleProvider", value)
                onResetRequested: view.resetOpt("titleProvider")
            }

            PickerRow {
                visible: view.opts.titleProvider === "codex"
                width: parent.width
                label: "Codex model"
                model: SettingsHelpers.NOTE_CODEX_MODEL_CHOICES
                current: view.opts.codexModel
                dirty: view.optDirty("codexModel")
                onPicked: value => view.setOpt("codexModel", value)
                onResetRequested: view.resetOpt("codexModel")
            }

            PickerRow {
                visible: view.opts.titleProvider === "codex"
                width: parent.width
                label: "Effort"
                model: SettingsHelpers.NOTE_CODEX_EFFORT_CHOICES
                current: view.opts.codexEffort
                dirty: view.optDirty("codexEffort")
                onPicked: value => view.setOpt("codexEffort", value)
                onResetRequested: view.resetOpt("codexEffort")
            }

            PickerRow {
                visible: view.opts.titleProvider === "claude"
                width: parent.width
                label: "Claude model"
                model: SettingsHelpers.NOTE_CLAUDE_MODEL_CHOICES
                current: view.opts.claudeModel
                dirty: view.optDirty("claudeModel")
                onPicked: value => view.setOpt("claudeModel", value)
                onResetRequested: view.resetOpt("claudeModel")
            }

            PickerRow {
                visible: view.opts.titleProvider === "claude"
                width: parent.width
                label: "Effort"
                model: SettingsHelpers.NOTE_CLAUDE_EFFORT_CHOICES
                current: view.opts.claudeEffort
                dirty: view.optDirty("claudeEffort")
                onPicked: value => view.setOpt("claudeEffort", value)
                onResetRequested: view.resetOpt("claudeEffort")
            }

            Text {
                width: parent.width
                leftPadding: Theme.settingsMarkInset + Theme.settingsLabelWidth
                text: view.opts.titleProvider === "off"
                    ? "Titles stay local. Choose a CLI to enable Generate in the note editor."
                    : "Uses your existing CLI sign-in. Text is sent when you click Generate or leave a note untitled, up to 12,000 characters."
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.secondary
                color: Theme.textDim
                wrapMode: Text.Wrap
            }
        }
    }

    Component {
        id: t3Options

        Column {
            spacing: Theme.settingsContentSpacing

            SwitchRow {
                width: parent.width
                label: "Status label"
                description: "Show the waiting/running word on the chip"
                checked: view.opts.showLabel
                dirty: view.optDirty("showLabel")
                onToggled: value => view.setOpt("showLabel", value)
                onResetRequested: view.resetOpt("showLabel")
            }
        }
    }

    Component {
        id: controlOptions
        DrawerPage {
            height: contentHeight
            interactive: false
        }
    }

    Component {
        id: usageOptions

        Column {
            spacing: Theme.settingsContentSpacing

            PickerRow {
                width: parent.width
                label: "Usage source"
                model: [
                    { value: "direct", label: "Provider CLIs" },
                    { value: "cliproxy", label: "CLIProxyAPI" },
                    { value: "sub2api", label: "Sub2API" }
                ]
                current: view.opts.source
                dirty: view.optDirty("source")
                onPicked: value => view.setOpt("source", value)
                onResetRequested: view.resetOpt("source")
            }

            SettingsTextRow {
                visible: view.opts.source === "cliproxy"
                width: parent.width
                minimumLabelWidth: 126
                label: "Management URL"
                value: view.opts.cliproxyUrl
                placeholder: "https://host:8317/management.html"
                dirty: view.optDirty("cliproxyUrl")
                onCommitted: text => view.setOpt("cliproxyUrl", text)
                onResetRequested: view.resetOpt("cliproxyUrl")
            }

            SwitchRow {
                visible: view.opts.source === "cliproxy"
                width: parent.width
                label: "Verify TLS"
                description: "Require a certificate trusted by this computer"
                checked: view.opts.cliproxyTlsVerify
                dirty: view.optDirty("cliproxyTlsVerify")
                onToggled: value => view.setOpt("cliproxyTlsVerify", value)
                onResetRequested: view.resetOpt("cliproxyTlsVerify")
            }

            SettingsTextRow {
                visible: view.opts.source === "cliproxy"
                width: parent.width
                minimumLabelWidth: 126
                enabled: !Usage.credentialBusy
                label: "Management key"
                value: ""
                placeholder: Usage.cliproxyKeyConfigured
                    ? "Configured — enter to replace" : "Required"
                secret: true
                dirty: Usage.cliproxyKeyConfigured
                onCommitted: text => Usage.saveManagementKey(text)
                onResetRequested: Usage.clearManagementKey()
            }

            Text {
                visible: view.opts.source === "cliproxy"
                width: parent.width
                text: Usage.credentialBusy ? "Checking private key…"
                    : Usage.credentialError ? Usage.credentialError
                    : Usage.cliproxyKeyConfigured
                        ? "Key stored privately; it is not saved in shell settings."
                        : "A CLIProxyAPI management key is required."
                leftPadding: Theme.settingsMarkInset
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.secondary
                color: Usage.credentialError ? Theme.redText : Theme.textFaint
                wrapMode: Text.Wrap
            }

            SettingsTextRow {
                visible: view.opts.source === "sub2api"
                width: parent.width
                minimumLabelWidth: 126
                label: "Server URL"
                value: view.opts.sub2apiUrl
                placeholder: "https://sub2api.example.com"
                dirty: view.optDirty("sub2apiUrl")
                onCommitted: text => view.setOpt("sub2apiUrl", text)
                onResetRequested: view.resetOpt("sub2apiUrl")
            }

            SwitchRow {
                visible: view.opts.source === "sub2api"
                width: parent.width
                label: "Verify TLS"
                description: "Require a certificate trusted by this computer"
                checked: view.opts.sub2apiTlsVerify
                dirty: view.optDirty("sub2apiTlsVerify")
                onToggled: value => view.setOpt("sub2apiTlsVerify", value)
                onResetRequested: view.resetOpt("sub2apiTlsVerify")
            }

            SettingsTextRow {
                visible: view.opts.source === "sub2api"
                width: parent.width
                minimumLabelWidth: 126
                enabled: !Usage.credentialBusy
                label: "Admin API key"
                value: ""
                placeholder: Usage.sub2apiKeyConfigured
                    ? "Configured — enter to replace" : "Required"
                secret: true
                dirty: Usage.sub2apiKeyConfigured
                onCommitted: text => Usage.saveManagementKey(text, "sub2api")
                onResetRequested: Usage.clearManagementKey("sub2api")
            }

            Text {
                visible: view.opts.source === "sub2api"
                width: parent.width
                text: Usage.credentialBusy ? "Checking private key…"
                    : Usage.credentialError ? Usage.credentialError
                    : Usage.sub2apiKeyConfigured
                        ? "Key stored privately; it is not saved in shell settings."
                        : "A Sub2API admin API key is required."
                leftPadding: Theme.settingsMarkInset
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.secondary
                color: Usage.credentialError ? Theme.redText : Theme.textFaint
                wrapMode: Text.Wrap
            }

            ResponsiveActionRow {
                visible: view.opts.source !== "direct"
                width: parent.width
                description: "Check the server and saved key"

                SettingsAction {
                    text: Usage.connectionTestBusy ? "Testing…" : "Test connection"
                    glyph: "refresh"
                    enabled: !Usage.connectionTestBusy
                    onTriggered: Usage.testConnection()
                }
            }

            Text {
                visible: view.opts.source !== "direct" && Usage.connectionTestMessage !== ""
                width: parent.width
                leftPadding: Theme.settingsMarkInset
                text: Usage.connectionTestMessage
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.secondary
                color: Usage.connectionTestSucceeded ? Theme.textMid : Theme.redText
                wrapMode: Text.Wrap
            }

            SwitchRow {
                width: parent.width
                label: "Claude"
                checked: view.opts.claude
                dirty: view.optDirty("claude")
                onToggled: value => view.setOpt("claude", value)
                onResetRequested: view.resetOpt("claude")
            }

            SwitchRow {
                visible: view.opts.source === "direct"
                width: parent.width
                label: "Keep Claude signed in"
                description: "Let Claude Code refresh its saved login for usage checks"
                checked: view.opts.claudeAutoRefresh
                dirty: view.optDirty("claudeAutoRefresh")
                onToggled: value => view.setOpt("claudeAutoRefresh", value)
                onResetRequested: view.resetOpt("claudeAutoRefresh")
            }

            SwitchRow {
                width: parent.width
                label: "Codex"
                checked: view.opts.codex
                dirty: view.optDirty("codex")
                onToggled: value => view.setOpt("codex", value)
                onResetRequested: view.resetOpt("codex")
            }

            SwitchRow {
                visible: view.opts.source === "sub2api"
                width: parent.width
                label: "Gemini / Antigravity"
                checked: view.opts.gemini
                dirty: view.optDirty("gemini")
                onToggled: value => view.setOpt("gemini", value)
                onResetRequested: view.resetOpt("gemini")
            }

            SwitchRow {
                width: parent.width
                visible: view.opts.source !== "sub2api"
                label: "Kimi"
                checked: view.opts.kimi
                dirty: view.optDirty("kimi")
                onToggled: value => view.setOpt("kimi", value)
                onResetRequested: view.resetOpt("kimi")
            }

            SwitchRow {
                width: parent.width
                label: "xAI / Grok"
                description: view.opts.source !== "direct"
                    ? "Show Grok quota when the server exposes a percentage"
                    : "Grok usage requires CLIProxyAPI or Sub2API"
                checked: view.opts.xai
                dirty: view.optDirty("xai")
                onToggled: value => view.setOpt("xai", value)
                onResetRequested: view.resetOpt("xai")
            }

            SliderRow {
                width: parent.width
                label: "Warn below"
                min: 10
                max: 50
                step: 5
                value: view.optValue("warnAt")
                unit: "%"
                dirty: view.optDirty("warnAt")
                onMoved: value => view.settleOpt("warnAt", value)
                onResetRequested: view.resetOpt("warnAt")
            }

            SliderRow {
                width: parent.width
                label: "Critical below"
                min: 5
                max: 25
                step: 5
                value: view.optValue("critAt")
                unit: "%"
                dirty: view.optDirty("critAt")
                onMoved: value => view.settleOpt("critAt", value)
                onResetRequested: view.resetOpt("critAt")
            }

            PickerRow {
                id: usagePollRow
                width: parent.width
                label: "Refresh every"
                settingKey: "pollMax"
                resetLabel: "Usage refresh interval"
                model: [
                    { value: 60, label: "1 min" },
                    { value: 300, label: "5 min" },
                    { value: 600, label: "10 min" }
                ]
                caption: "next " + Format.mmss(Usage.nextPollSecs)

                Claim {
                    active: usagePollRow.visible
                    onClaimed: Usage.acquireCountdown()
                    onReleased: Usage.releaseCountdown()
                }
            }
        }
    }

    Component {
        id: hermesOptions

        Column {
            spacing: Theme.settingsContentSpacing

            SwitchRow {
                width: parent.width
                label: "Status label"
                description: "Show Hermes activity beside its icon"
                checked: view.opts.showLabel
                dirty: view.optDirty("showLabel")
                onToggled: value => view.setOpt("showLabel", value)
                onResetRequested: view.resetOpt("showLabel")
            }

            PickerRow {
                width: parent.width
                label: "Activity detail"
                model: [
                    { value: "full", label: "Full detail" },
                    { value: "verb", label: "Verb only" },
                    { value: "generic", label: "Working only" }
                ]
                current: view.opts.activityDetail
                dirty: view.optDirty("activityDetail")
                onPicked: value => view.setOpt("activityDetail", value)
                onResetRequested: view.resetOpt("activityDetail")
            }
        }
    }

    Component {
        id: ghOptions

        Column {
            id: githubRows

            // "Recent account repos" is intentionally descriptive and wider
            // than the shared compact label column. Keep this group aligned
            // while reserving enough room that the label cannot cover a track.
            readonly property int optionLabelWidth: 156

            spacing: Theme.settingsContentSpacing

            PickerRow {
                width: parent.width
                minimumLabelWidth: githubRows.optionLabelWidth
                label: "Badge"
                model: [
                    { value: "dot", label: "Dot" },
                    { value: "count", label: "Count" },
                    { value: "off", label: "Off" }
                ]
                current: view.opts.badge
                dirty: view.optDirty("badge")
                onPicked: value => view.setOpt("badge", value)
                onResetRequested: view.resetOpt("badge")
            }

            SliderRow {
                width: parent.width
                minimumLabelWidth: githubRows.optionLabelWidth
                label: "Recent account repos"
                min: 3
                max: 15
                step: 1
                value: view.optValue("repos")
                unit: ""
                dirty: view.optDirty("repos")
                onMoved: value => view.settleOpt("repos", value)
                onResetRequested: view.resetOpt("repos")
            }

            SliderRow {
                width: parent.width
                minimumLabelWidth: githubRows.optionLabelWidth
                label: "Repo refresh"
                // Helpers.runPollDue: a repository with a running workflow or
                // a fresh push, pull request, branch or release is read on
                // every one-minute Inbox sweep; the rest wait this long.
                hint: "Also how often quiet repos' workflow runs are read; busy ones every minute"
                min: 1
                max: 30
                step: 1
                value: view.optValue("pollMins")
                unit: "min"
                dirty: view.optDirty("pollMins")
                onMoved: value => view.settleOpt("pollMins", value)
                onResetRequested: view.resetOpt("pollMins")
            }

            SwitchRow {
                width: parent.width
                minimumLabelWidth: githubRows.optionLabelWidth
                label: "CI reports"
                description: "Workflow rows in the Inbox for recent and watched repositories"
                checked: view.opts.ciActivity
                dirty: view.optDirty("ciActivity")
                onToggled: value => view.setOpt("ciActivity", value)
                onResetRequested: view.resetOpt("ciActivity")
            }

            SwitchRow {
                width: parent.width
                minimumLabelWidth: githubRows.optionLabelWidth
                label: "Toasts"
                description: "Watched pushes and failed/action-required workflows"
                checked: view.opts.toasts
                dirty: view.optDirty("toasts")
                onToggled: value => view.setOpt("toasts", value)
                onResetRequested: view.resetOpt("toasts")
            }

            // The account card and the watch list: the one block of module
            // options that is not a value row.
            GitHubWatchList {
                width: parent.width
            }
        }
    }

    Component {
        id: notificationsOptions

        Column {
            spacing: Theme.settingsContentSpacing

            PickerRow {
                width: parent.width
                label: "Grouping"
                model: [
                    { value: "solo", label: "Separate" },
                    { value: "status", label: "Status group" }
                ]
                current: view.opts.group
                dirty: view.optDirty("group")
                onPicked: value => view.setOpt("group", value)
                onResetRequested: view.resetOpt("group")
            }

            Text {
                width: parent.width
                leftPadding: Theme.settingsMarkInset + Theme.settingsLabelWidth
                rightPadding: Theme.chipHeight
                text: "Groups only with adjacent Volume, Network, Bluetooth, or Battery widgets."
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.secondary
                color: Theme.textDim
                wrapMode: Text.Wrap
            }
        }
    }

    Component {
        id: volOptions

        Column {
            spacing: Theme.settingsContentSpacing

            SliderRow {
                width: parent.width
                label: "Scroll step"
                min: 1
                max: 10
                step: 1
                value: view.optValue("step")
                unit: "%"
                dirty: view.optDirty("step")
                onMoved: value => view.settleOpt("step", value)
                onResetRequested: view.resetOpt("step")
            }

            SwitchRow {
                width: parent.width
                label: "Percentage"
                description: "Show the volume number next to the icon"
                checked: view.opts.showPct
                dirty: view.optDirty("showPct")
                onToggled: value => view.setOpt("showPct", value)
                onResetRequested: view.resetOpt("showPct")
            }

            PickerRow {
                width: parent.width
                label: "Middle click"
                model: [
                    { value: "mute", label: "Mute" },
                    { value: "none", label: "Nothing" }
                ]
                current: view.opts.middleClick
                dirty: view.optDirty("middleClick")
                onPicked: value => view.setOpt("middleClick", value)
                onResetRequested: view.resetOpt("middleClick")
            }
        }
    }

    Component {
        id: battOptions

        Column {
            spacing: Theme.settingsContentSpacing

            SwitchRow {
                width: parent.width
                label: "Percentage"
                description: "Show the charge number next to the icon"
                checked: view.opts.showPct
                dirty: view.optDirty("showPct")
                onToggled: value => view.setOpt("showPct", value)
                onResetRequested: view.resetOpt("showPct")
            }

            SliderRow {
                width: parent.width
                label: "Amber below"
                min: 10
                max: 40
                step: 5
                value: view.optValue("warnAt")
                unit: "%"
                dirty: view.optDirty("warnAt")
                onMoved: value => view.settleOpt("warnAt", value)
                onResetRequested: view.resetOpt("warnAt")
            }

            SliderRow {
                width: parent.width
                label: "Alert below"
                min: 5
                max: 20
                step: 5
                value: view.optValue("critAt")
                unit: "%"
                dirty: view.optDirty("critAt")
                onMoved: value => view.settleOpt("critAt", value)
                onResetRequested: view.resetOpt("critAt")
            }
        }
    }

    Component {
        id: updatesOptions

        Column {
            spacing: Theme.settingsContentSpacing

            SliderRow {
                width: parent.width
                label: "Check every"
                min: 10
                max: 240
                step: 10
                value: view.optValue("pollMins")
                unit: "min"
                dirty: view.optDirty("pollMins")
                onMoved: value => view.settleOpt("pollMins", value)
                onResetRequested: view.resetOpt("pollMins")
            }

            SwitchRow {
                width: parent.width
                label: "Include Flatpak"
                checked: view.opts.flatpak
                dirty: view.optDirty("flatpak")
                onToggled: value => view.setOpt("flatpak", value)
                onResetRequested: view.resetOpt("flatpak")
            }

            SwitchRow {
                width: parent.width
                label: "Notify when updates appear"
                checked: view.opts.notify
                dirty: view.optDirty("notify")
                onToggled: value => view.setOpt("notify", value)
                onResetRequested: view.resetOpt("notify")
            }
        }
    }

    Component {
        id: trayOptions

        Column {
            spacing: Theme.settingsContentSpacing

            SwitchRow {
                width: parent.width
                label: "Start expanded"
                checked: view.opts.expanded
                dirty: view.optDirty("expanded")
                onToggled: value => view.setOpt("expanded", value)
                onResetRequested: view.resetOpt("expanded")
            }
        }
    }
}
