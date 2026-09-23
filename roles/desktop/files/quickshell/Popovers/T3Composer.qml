pragma ComponentBehavior: Bound
import QtQuick
import "../Common"

// T3's composer is one recognisable glass surface: prompt above, contextual
// controls and a round send action below. Detailed run settings unfold as a
// compact drawer attached to that surface instead of becoming another form.
Column {
    id: root

    property string threadId: ""
    property bool newThread: false
    property bool editable: true
    property bool sendEnabled: true
    property string sendLabel: "Send"
    // Every floating picker is clamped to this page-sized item. Thread pages
    // overlay the transcript; New Thread reserves equivalent room inside its
    // scrolling form, but neither may escape the drawer body.
    property Item popupBoundsItem: null
    // While the thread is working the prompt is locked, so the round action
    // has nothing to send. That is exactly when the user wants to stop the
    // turn, and the slot they are already reaching for is this one.
    property bool stoppable: false
    signal sendRequested()
    signal stopRequested()

    readonly property var draft: newThread ? T3Code.newThreadDraft : T3Code.threadDraft(threadId)
    readonly property var traits: T3Code.draftTraitDescriptors(draft)
    // Provider and model are one control on the bar, so the picker compares
    // against one joined value: "<instanceId>::<slug>".
    readonly property string selectionValue: T3Code.selectionId(draft.instanceId ?? "",
        draft.model ?? "")
    readonly property string providerGlyph: T3Code.providerIcon(draft.instanceId ?? "")
    readonly property bool showInteraction: draft.modeFixed !== true
        && T3Code.providerShowsInteraction(draft.instanceId)
    readonly property bool overLimit: promptEdit.text.length > T3Code.maxPromptChars
    readonly property bool ultrathink: /\bultrathink\b/i.test(promptEdit.text)
    readonly property string actionKind: newThread ? "new" : "prompt"
    readonly property string actionThreadId: newThread ? "" : threadId
    readonly property bool sending: T3Code.actionPending(actionKind, actionThreadId, "")
    readonly property bool stopping: T3Code.actionPending("interrupt", actionThreadId, "")
    readonly property bool stopMode: stoppable && !newThread
    // New Thread menus open below the composer and reserve their height in the
    // page's scrolling form. Thread pages already have a transcript above the
    // composer and overlay that space instead.
    readonly property real barPickerReserve: !newThread ? 0
        : modelSelect.expanded ? modelSelect.popupHeight
        : effortSelect.expanded ? effortSelect.popupHeight
        : accessSelect.expanded ? accessSelect.popupHeight : 0

    // One primary action, two meanings. Both the pointer and the keyboard
    // path route through here so they cannot drift apart.
    function activatePrimary() {
        if (stopMode)
            root.stopRequested();
        else
            root.sendRequested();
    }

    spacing: 4
    z: settingsPresentation.activePicker !== null || settingsPresentation.expanded ? 100 : 0

    QtObject {
        id: settingsPresentation

        property bool expanded: false
        property Item activePicker: null
        property string activePickerGroup: ""
        readonly property bool narrow: root.width < 360
        readonly property var accessOptions: [
            { id: "approval-required", label: "Ask first" },
            { id: "auto-accept-edits", label: "Auto edits" },
            { id: "auto", label: "Auto" },
            { id: "full-access", label: "Full access" }
        ]
        readonly property var interactionOptions: [
            { id: "default", label: "Default" },
            { id: "plan", label: "Plan" }
        ]

        // Reasoning earns a place on the bar; every other trait the model
        // declares stays in the drawer, which now exists only for what the
        // bar cannot hold.
        readonly property var reasoningDescriptor:
            (Array.isArray(root.traits) ? root.traits : [])
                .find(candidate => root.traitLabel(candidate) === "Reasoning") ?? null
        readonly property var extraTraits: (Array.isArray(root.traits) ? root.traits : [])
            .filter(candidate => root.traitLabel(candidate) !== "Reasoning")
        readonly property bool reasoningInDrawer: narrow && reasoningDescriptor !== null
        readonly property bool hasDrawer: root.showInteraction || extraTraits.length > 0
            || reasoningInDrawer
        readonly property var reasoningOptions: {
            if (!reasoningDescriptor)
                return [];
            if (reasoningDescriptor.type === "boolean")
                return [{ id: "true", label: "On" }, { id: "false", label: "Off" }];
            return (Array.isArray(reasoningDescriptor.options)
                ? reasoningDescriptor.options : [])
                .map(option => ({ id: settingId(option), label: settingLabel(option) }));
        }
        readonly property string reasoningValue: {
            if (!reasoningDescriptor)
                return "";
            return reasoningDescriptor.type === "boolean"
                ? (reasoningDescriptor.currentValue === true ? "true" : "false")
                : String(reasoningDescriptor.currentValue ?? "");
        }

        function trackPicker(picker, group) {
            if (picker.expanded) {
                if (activePicker !== null && activePicker !== picker)
                    activePicker.expanded = false;
                activePicker = picker;
                activePickerGroup = group;
            } else if (activePicker === picker) {
                activePicker = null;
                activePickerGroup = "";
            }
        }

        onExpandedChanged: {
            if (!expanded && activePicker !== null)
                activePicker.expanded = false;
        }

        // Its trigger disappears with its contents, so the sheet must not be
        // left open behind a button that is no longer there.
        onHasDrawerChanged: {
            if (!hasDrawer)
                expanded = false;
        }

        function settingId(option) {
            if (!option)
                return "";
            return String(option.id ?? option.instanceId ?? option.slug ?? option.value ?? "");
        }

        function settingLabel(option) {
            if (!option)
                return "";
            return String(option.label ?? option.displayName ?? option.name ?? option.shortName
                ?? settingId(option));
        }

        function displaySettingValue(value, fallback) {
            const text = String(value ?? "").trim();
            if (text === "")
                return fallback;
            return text.replace(/[-_]+/g, " ").replace(/\b\w/g,
                character => character.toUpperCase());
        }

        function selectedSettingLabel(options, value, fallback) {
            const found = (Array.isArray(options) ? options : [])
                .find(option => settingId(option) === value);
            return found ? settingLabel(found) : displaySettingValue(value, fallback);
        }

        function reasoningSummary() {
            if (!reasoningDescriptor)
                return "";
            if (reasoningDescriptor.type === "boolean")
                return reasoningDescriptor.currentValue === true
                    ? "Reasoning on" : "Reasoning off";
            return selectedSettingLabel(reasoningDescriptor.options,
                String(reasoningDescriptor.currentValue ?? ""), "");
        }

        function accessSummary() {
            return selectedSettingLabel(accessOptions,
                String(root.draft?.runtimeMode ?? "full-access"), "Unavailable");
        }

        // An open padlock is the whole point of "Full access": the one mode
        // that is not gated should not be wearing a closed lock.
        function accessSymbol() {
            return String(root.draft?.runtimeMode ?? "full-access") === "full-access"
                ? "lock_open" : "lock";
        }

        // The bar shows the model and lets the provider travel as its brand
        // mark. These are the words-only forms, and the accessible summary
        // that puts the provider back into the sentence.
        function modelSummary() {
            const model = T3Code.modelConfiguration(root.draft?.instanceId ?? "",
                root.draft?.model ?? "");
            if (!model)
                return displaySettingValue(root.draft?.model, "Unavailable");
            return model.shortName !== "" ? model.shortName : model.name;
        }

        function providerModelSummary() {
            const provider = T3Code.providerConfiguration(root.draft?.instanceId ?? "");
            const model = modelSummary();
            return provider ? provider.displayName + " · " + model : model;
        }

        function modeSummary() {
            if (!root.showInteraction)
                return "";
            return String(root.draft?.interactionMode ?? "default") === "plan"
                ? "Plan" : "Default";
        }

        function compactSummary() {
            const parts = [providerModelSummary(), modeSummary(), reasoningSummary()]
                .filter(value => value !== "");
            return parts.join(" · ");
        }

        function accessibleSummary() {
            return compactSummary() + " · Access: " + accessSummary();
        }
    }

    // The hairline between bar controls. The gap lives in the wrapper so the
    // Row's own spacing stays small and the rule sits centred inside it.
    component BarDivider: Item {
        width: 11
        height: 26

        Rectangle {
            anchors.centerIn: parent
            width: 1
            height: 14
            color: T3Theme.border
        }
    }

    function focusPrompt() {
        promptEdit.forceActiveFocus();
        promptEdit.cursorPosition = promptEdit.text.length;
    }

    function persistPrompt(value) {
        if (newThread)
            T3Code.setNewPrompt(value);
        else
            T3Code.setThreadPrompt(threadId, value);
    }

    // Provider and model land in one draft update: routing through the
    // provider's *default* model on the way can trip a per-thread guard the
    // requested model would have passed.
    function chooseSelection(instanceId, model) {
        if (newThread)
            T3Code.setNewSelection(instanceId, model);
        else
            T3Code.setThreadSelection(threadId, instanceId, model);
    }

    function chooseReasoning(value) {
        const descriptor = settingsPresentation.reasoningDescriptor;
        if (!descriptor)
            return;
        chooseTrait(descriptor.id,
            descriptor.type === "boolean" ? value === "true" : value);
    }

    function chooseRuntime(value) {
        if (newThread)
            T3Code.setNewRuntime(value);
        else
            T3Code.setThreadRuntime(threadId, value);
    }

    function chooseInteraction(value) {
        if (newThread)
            T3Code.setNewInteraction(value);
        else
            T3Code.setThreadInteraction(threadId, value);
    }

    function chooseTrait(id, value) {
        if (newThread)
            T3Code.updateNewTrait(id, value);
        else
            T3Code.updateThreadTrait(threadId, id, value);
    }

    function traitLabel(descriptor) {
        const id = String(descriptor?.id ?? "").toLowerCase();
        if (id === "effort" || id === "reasoningeffort" || id === "reasoning")
            return "Reasoning";
        return descriptor?.label ?? "Option";
    }

    function syncPrompt() {
        const next = draft && typeof draft.prompt === "string" ? draft.prompt : "";
        if (promptEdit.text === next)
            return;
        promptEdit.syncing = true;
        promptEdit.text = next;
        promptEdit.cursorPosition = next.length;
        promptEdit.syncing = false;
    }

    function insertNewline() {
        const start = promptEdit.selectionStart;
        const end = promptEdit.selectionEnd;
        if (start !== end) {
            promptEdit.remove(start, end);
            promptEdit.cursorPosition = start;
        }
        const position = promptEdit.cursorPosition;
        promptEdit.insert(position, "\n");
        promptEdit.cursorPosition = position + 1;
    }

    function closeOpenLayer(): bool {
        if (settingsPresentation.activePicker !== null) {
            settingsPresentation.activePicker.expanded = false;
            return true;
        }
        if (settingsPresentation.expanded) {
            settingsPresentation.expanded = false;
            return true;
        }
        return false;
    }

    Rectangle {
        id: settingsDrawer
        visible: settingsPresentation.expanded
        width: parent.width
        height: settingsDrawerColumn.implicitHeight + 16
        z: settingsPresentation.activePicker !== null ? 200 : 1
        radius: T3Theme.panelRadius
        color: T3Theme.overlay
        border.width: 1
        border.color: T3Theme.borderStrong

        Column {
            id: settingsDrawerColumn
            x: 8
            y: 8
            width: parent.width - 16
            spacing: 6

            Item {
                width: parent.width
                height: 28

                Row {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 7

                    Sym {
                        anchors.verticalCenter: parent.verticalCenter
                        name: "tune"
                        size: Theme.iconSmall
                        color: T3Theme.accent
                    }

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Run settings"
                        font.family: T3Theme.fontUi
                        font.pixelSize: Theme.typography.secondary
                        font.weight: Theme.weightSemibold
                        color: T3Theme.textPrimary
                    }
                }

                IconButton {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    controlSize: 28
                    symbol: "close"
                    accessibleName: "Close run settings"
                    onTriggered: settingsPresentation.expanded = false
                }
            }

            Flow {
                id: runtimeFields
                width: parent.width
                spacing: 5
                z: settingsPresentation.activePickerGroup === "runtime" ? 100 : 0

                T3Picker {
                    id: interactionPicker
                    visible: root.showInteraction
                    width: parent.width
                    label: "Mode"
                    value: root.draft.interactionMode ?? "default"
                    options: settingsPresentation.interactionOptions
                    openUpward: !root.newThread
                    popupBoundsItem: root.popupBoundsItem
                    enabled: root.editable && !root.sending
                    onSelected: value => root.chooseInteraction(value)
                    onExpandedChanged: settingsPresentation.trackPicker(
                        interactionPicker, "runtime")
                }

                T3Picker {
                    id: reasoningPicker
                    visible: settingsPresentation.reasoningInDrawer
                        && settingsPresentation.reasoningOptions.length > 0
                    width: parent.width
                    label: "Reasoning"
                    value: settingsPresentation.reasoningValue
                    options: settingsPresentation.reasoningOptions
                    openUpward: !root.newThread
                    popupBoundsItem: root.popupBoundsItem
                    enabled: root.editable && !root.sending
                    onSelected: value => root.chooseReasoning(value)
                    onExpandedChanged: settingsPresentation.trackPicker(
                        reasoningPicker, "runtime")
                }
            }

            Flow {
                id: traitFields
                visible: settingsPresentation.extraTraits.length > 0
                width: parent.width
                spacing: 5
                z: settingsPresentation.activePickerGroup === "traits" ? 100 : 0

                Repeater {
                    model: settingsPresentation.extraTraits

                    delegate: Item {
                        id: traitRow
                        required property var modelData
                        width: settingsPresentation.narrow ? parent.width : (parent.width - 5) / 2
                        height: modelData.type === "select" ? 34 : 30
                        z: traitPicker.expanded ? 100 : 0

                        T3Picker {
                            id: traitPicker
                            visible: traitRow.modelData.type === "select"
                            anchors.fill: parent
                            label: root.traitLabel(traitRow.modelData)
                            value: traitRow.modelData.currentValue ?? ""
                            options: traitRow.modelData.options ?? []
                            popupBoundsItem: root.popupBoundsItem
                            enabled: root.editable && !root.sending
                            onSelected: value => root.chooseTrait(traitRow.modelData.id, value)
                            onExpandedChanged: settingsPresentation.trackPicker(
                                traitPicker, "traits")
                        }

                        Rectangle {
                            id: traitToggle
                            visible: traitRow.modelData.type === "boolean"
                            anchors.fill: parent
                            radius: T3Theme.controlRadius
                            color: traitMouse.containsMouse && root.editable
                                ? T3Theme.hoverStrong : T3Theme.surfaceRaised
                            Accessible.role: Accessible.CheckBox
                            Accessible.name: root.traitLabel(traitRow.modelData)
                            Accessible.checked: traitRow.modelData.currentValue === true
                            opacity: root.editable && !root.sending ? 1 : 0.48
                            activeFocusOnTab: root.editable && !root.sending
                            border.width: activeFocus ? 1 : 0
                            border.color: T3Theme.focus

                            Keys.onPressed: event => {
                                if (!root.editable || root.sending)
                                    return;
                                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                                        || event.key === Qt.Key_Space) {
                                    root.chooseTrait(traitRow.modelData.id,
                                        traitRow.modelData.currentValue !== true);
                                    event.accepted = true;
                                }
                            }

                            Text {
                                anchors.left: parent.left
                                anchors.leftMargin: 8
                                anchors.verticalCenter: parent.verticalCenter
                                text: root.traitLabel(traitRow.modelData)
                                font.family: T3Theme.fontUi
                                font.pixelSize: Theme.typography.secondary
                                color: T3Theme.textSecondary
                            }

                            Rectangle {
                                anchors.right: parent.right
                                anchors.rightMargin: 7
                                anchors.verticalCenter: parent.verticalCenter
                                width: 28
                                height: 16
                                radius: 8
                                color: traitRow.modelData.currentValue === true
                                    ? T3Theme.accent : T3Theme.borderStrong

                                Rectangle {
                                    anchors.verticalCenter: parent.verticalCenter
                                    x: traitRow.modelData.currentValue === true ? parent.width - width - 3 : 3
                                    width: 10
                                    height: 10
                                    radius: 5
                                    color: T3Theme.accentForeground

                                    Behavior on x {
                                        NumberAnimation {
                                            duration: T3Theme.fastDuration
                                            easing.type: Easing.OutCubic
                                        }
                                    }
                                }
                            }

                            MouseArea {
                                id: traitMouse
                                anchors.fill: parent
                                enabled: root.editable && !root.sending
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    traitToggle.forceActiveFocus();
                                    root.chooseTrait(traitRow.modelData.id,
                                        traitRow.modelData.currentValue !== true);
                                }
                            }
                        }
                    }
                }
            }

            Text {
                visible: root.draft.traitError !== ""
                width: parent.width
                text: root.draft.traitError ?? ""
                wrapMode: Text.WordWrap
                font.family: T3Theme.fontUi
                font.pixelSize: Theme.typography.secondary
                color: T3Theme.amber
            }
        }
    }

    Rectangle {
        id: composerShell
        width: parent.width
        height: composerContent.implicitHeight + 20
        radius: T3Theme.composerRadius
        color: T3Theme.composerGlass
        border.width: 1
        border.color: root.overLimit ? T3Theme.redBorder
            : promptEdit.activeFocus ? T3Theme.focus : T3Theme.borderStrong

        Behavior on border.color {
            ColorAnimation { duration: T3Theme.fastDuration }
        }

        Rectangle {
            visible: root.ultrathink
            anchors.fill: parent
            radius: parent.radius
            color: T3Theme.accentSubtle
        }

        Column {
            id: composerContent
            x: 10
            y: 10
            width: parent.width - 20
            spacing: 7

            Item {
                id: promptBox
                width: parent.width
                height: Math.max(58, Math.min(118, promptEdit.contentHeight + 8))

                Flickable {
                    id: promptFlick
                    anchors.fill: parent
                    contentWidth: width
                    contentHeight: Math.max(height, promptEdit.contentHeight)
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds

                    TextEdit {
                        id: promptEdit
                        property bool syncing: false

                        width: promptFlick.width
                        height: Math.max(promptFlick.height, contentHeight)
                        enabled: root.editable && !root.sending
                        wrapMode: TextEdit.Wrap
                        selectByMouse: true
                        Accessible.description: "Enter to send. Control Enter inserts a newline."
                        font.family: T3Theme.fontUi
                        font.pixelSize: Theme.typography.control
                        color: T3Theme.textPrimary
                        selectionColor: T3Theme.accentSoft
                        selectedTextColor: T3Theme.textPrimary
                        onTextChanged: {
                            if (!syncing && activeFocus)
                                root.persistPrompt(text);
                        }
                        onCursorRectangleChanged: {
                            if (cursorRectangle.y + cursorRectangle.height > promptFlick.contentY
                                    + promptFlick.height)
                                promptFlick.contentY = cursorRectangle.y + cursorRectangle.height
                                    - promptFlick.height;
                            else if (cursorRectangle.y < promptFlick.contentY)
                                promptFlick.contentY = cursorRectangle.y;
                        }

                        Keys.onPressed: event => {
                            if (event.key !== Qt.Key_Return && event.key !== Qt.Key_Enter)
                                return;
                            if (event.modifiers & Qt.ControlModifier)
                                root.insertNewline();
                            else if (root.sendEnabled && !root.sending && !root.overLimit
                                    && promptEdit.text.trim() !== "")
                                root.sendRequested();
                            event.accepted = true;
                        }

                        Text {
                            visible: promptEdit.text === ""
                            text: "Ask anything…"
                            font.family: T3Theme.fontUi
                            font.pixelSize: Theme.typography.primary
                            color: T3Theme.textFaint
                        }
                    }
                }
            }

            // The reference client's bar: the run's identity on the left as
            // plain words with marks, the turn's control on the right. No rule
            // separates it from the prompt — the shell is one field, not a
            // text box stacked on a toolbar.
            Item {
                id: actionRow
                width: parent.width
                height: Theme.inlineActionHeight
                z: settingsPresentation.activePicker !== null ? 50 : 0

                // What the labels may occupy before they start eliding. The
                // send action never yields; the model name is the first to.
                readonly property real inlineRoom: width - sendButton.width - 8
                    - (workingIndicator.visible ? workingIndicator.width + 8 : 0)
                    - (settingsButton.visible ? settingsButton.width + 2 : 0)
                readonly property real selectorChrome: accessDivider.width
                    + inlineSettings.spacing * 2
                    + (effortSelect.visible ? effortDivider.width
                        + effortSelect.implicitWidth + inlineSettings.spacing * 2 : 0)
                readonly property real selectorRoom: Math.max(96,
                    inlineRoom - selectorChrome)
                // Model text yields first. Once it reaches an icon-safe 48px,
                // access begins eliding too; the tune and primary action sit
                // outside inlineRoom and therefore never enter this tradeoff.
                readonly property real accessRoom: Math.min(accessSelect.naturalWidth,
                    Math.max(48, selectorRoom - 48))
                readonly property real modelRoom: Math.max(48,
                    selectorRoom - accessRoom)

                Row {
                    id: inlineSettings
                    // The trigger carries its own 6px of padding, so pulling
                    // the row back by that much lines the provider mark up
                    // with the prompt's first character.
                    anchors.left: parent.left
                    anchors.leftMargin: -6
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 3

                    T3ModelPicker {
                        id: modelSelect
                        threadId: root.threadId
                        newThread: root.newThread
                        brand: root.providerGlyph
                        label: settingsPresentation.modelSummary()
                        value: root.selectionValue
                        openUpward: !root.newThread
                        maxWidth: actionRow.modelRoom
                        popupBoundsItem: root.popupBoundsItem
                        enabled: root.editable && !root.sending
                        onSelected: (instanceId, model) =>
                            root.chooseSelection(instanceId, model)
                        onExpandedChanged: settingsPresentation.trackPicker(
                            modelSelect, "bar")
                    }

                    BarDivider {
                        id: effortDivider
                        visible: effortSelect.visible
                    }

                    T3InlineSelect {
                        id: effortSelect
                        visible: !settingsPresentation.narrow
                            && settingsPresentation.reasoningOptions.length > 0
                        text: root.traitLabel(settingsPresentation.reasoningDescriptor)
                        value: settingsPresentation.reasoningValue
                        options: settingsPresentation.reasoningOptions
                        openUpward: !root.newThread
                        menuWidth: 168
                        alignRight: true
                        popupBoundsItem: root.popupBoundsItem
                        enabled: root.editable && !root.sending
                        onSelected: value => root.chooseReasoning(value)
                        onExpandedChanged: settingsPresentation.trackPicker(
                            effortSelect, "bar")
                    }

                    BarDivider { id: accessDivider }

                    T3InlineSelect {
                        id: accessSelect
                        symbol: settingsPresentation.accessSymbol()
                        text: settingsPresentation.accessSummary()
                        value: root.draft.runtimeMode ?? "full-access"
                        options: settingsPresentation.accessOptions
                        openUpward: !root.newThread
                        menuWidth: 190
                        maxWidth: actionRow.accessRoom
                        alignRight: true
                        popupBoundsItem: root.popupBoundsItem
                        // Full access is the one mode with nothing standing
                        // between the agent and the machine. It says so.
                        tint: root.draft?.runtimeMode === "full-access"
                            ? T3Theme.amber : T3Theme.textSecondary
                        iconTint: root.draft?.runtimeMode === "full-access"
                            ? T3Theme.amber : T3Theme.textFaint
                        enabled: root.editable && !root.sending
                        onSelected: value => root.chooseRuntime(value)
                        onExpandedChanged: settingsPresentation.trackPicker(
                            accessSelect, "bar")
                    }
                }

                // Only what the bar could not hold: the interaction mode and
                // any traits beyond reasoning. With neither, it is not there.
                IconButton {
                    id: settingsButton
                    visible: settingsPresentation.hasDrawer
                    anchors.right: workingIndicator.visible
                        ? workingIndicator.left : sendButton.left
                    anchors.rightMargin: 4
                    anchors.verticalCenter: parent.verticalCenter
                    controlSize: 28
                    symbol: "tune"
                    accessibleName: "Run settings"
                    accessibleDescription: settingsPresentation.accessibleSummary()
                    tint: settingsPresentation.expanded
                        ? T3Theme.accent : T3Theme.textFaint
                    onTriggered: settingsPresentation.expanded = !settingsPresentation.expanded
                }

                Sym {
                    id: workingIndicator
                    visible: root.stopMode || root.sending
                    anchors.right: sendButton.left
                    anchors.rightMargin: 10
                    anchors.verticalCenter: parent.verticalCenter
                    name: "progress_activity"
                    size: Theme.iconLarge
                    symWeight: 400
                    color: T3Theme.textFaint

                    RotationAnimation on rotation {
                        running: workingIndicator.visible && !Theme.reducedMotion
                        from: 0
                        to: 360
                        duration: 1100
                        loops: Animation.Infinite
                    }
                }

                Rectangle {
                    id: sendButton
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    width: Theme.inlineActionHeight
                    height: Theme.inlineActionHeight
                    radius: width / 2
                    // Stopping is not the same act as sending, and a red
                    // circle is how the reference client says so.
                    color: root.stopMode
                        ? (sendMouse.containsMouse && sendMouse.enabled
                            ? T3Theme.dangerHover : T3Theme.danger)
                        : (sendMouse.containsMouse && sendMouse.enabled
                            ? T3Theme.accentHover : T3Theme.accent)
                    opacity: sendMouse.enabled ? 1 : 0.32
                    activeFocusOnTab: sendMouse.enabled
                    Accessible.role: Accessible.Button
                    Accessible.name: root.stopMode ? "Stop" : root.sendLabel
                    Accessible.onPressAction: root.activatePrimary()
                    border.width: activeFocus ? 2 : 0
                    border.color: root.stopMode
                        ? T3Theme.dangerForeground : T3Theme.accentForeground

                    Behavior on color {
                        ColorAnimation { duration: T3Theme.fastDuration }
                    }

                    Keys.onPressed: event => {
                        if (!sendMouse.enabled)
                            return;
                        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                                || event.key === Qt.Key_Space) {
                            root.activatePrimary();
                            event.accepted = true;
                        }
                    }

                    Sym {
                        visible: !root.stopMode
                        anchors.centerIn: parent
                        name: root.sending ? "more_horiz" : "arrow_upward"
                        size: Theme.iconMedium
                        symWeight: 600
                        color: T3Theme.accentForeground
                    }

                    Sym {
                        visible: root.stopMode
                        anchors.centerIn: parent
                        name: "stop"
                        size: Theme.iconMedium
                        color: T3Theme.dangerForeground
                    }

                    MouseArea {
                        id: sendMouse
                        anchors.fill: parent
                        // A stop has no prompt to validate: it is available on
                        // the strength of the running turn alone.
                        enabled: root.stopMode
                            ? T3Code.canDispatch && !root.stopping
                            : root.sendEnabled && !root.sending && !root.overLimit
                                && promptEdit.text.trim() !== ""
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.activatePrimary()
                    }
                }
            }

            Text {
                visible: root.overLimit
                width: parent.width
                text: "Prompt too long — open T3 Code"
                font.family: T3Theme.fontUi
                font.pixelSize: Theme.typography.secondary
                color: T3Theme.red
            }
        }
    }

    // Floating menus do not contribute to a positioner's implicit size. New
    // Thread keeps this reserve inside its scrolling viewport; it no longer
    // extends the host surface beyond the full-height drawer.
    Item {
        id: barPickerSpace
        visible: root.barPickerReserve > 0
        width: parent.width
        height: root.barPickerReserve
    }

    // Updating a draft replaces the singleton's map and emits its change
    // signal before every dependent binding is guaranteed to have observed
    // the replacement. Resync on the next event-loop turn: an edit originating
    // here then compares equal and leaves the cursor alone, while an external
    // clear/restore still reaches the editor.
    Timer {
        id: promptSyncTimer
        interval: 0
        onTriggered: root.syncPrompt()
    }

    Connections {
        target: T3Code
        function onThreadDraftsChanged() {
            if (!root.newThread)
                promptSyncTimer.restart();
        }
        function onNewThreadDraftChanged() {
            if (root.newThread)
                promptSyncTimer.restart();
        }
    }

    Component.onCompleted: {
        settingsPresentation.expanded = false;
        syncPrompt();
    }
}
