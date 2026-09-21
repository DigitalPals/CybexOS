pragma ComponentBehavior: Bound
import QtQuick
import "../Common"

// Blocking Hermes interaction: approvals, clarification, sudo and secret
// prompts share one compact, non-persistent drawer. Sensitive values never
// leave this component except in the explicit response RPC.
Rectangle {
    id: root

    required property string conversationId
    required property var request
    property int maxHeight: 280
    property string typedValue: ""
    property var selectedValue: null
    property var selectedValues: []
    property var answerDrafts: ({})
    property int questionIndex: 0
    property bool detailExpanded: false
    property string confirmDecision: ""
    signal responseStarted(string requestId)

    readonly property string requestKey: conversationId + "|" + request.id
    readonly property bool pending: Hermes.actionPending(request.kind,
        conversationId, request.id)
    readonly property string failure: Hermes.actionError(request.kind,
        conversationId, request.id)
    readonly property bool needsValue: request.kind === "clarify"
        || request.kind === "sudo" || request.kind === "secret"
    readonly property bool hasAnswer: !needsValue || typedValue.trim() !== ""
        || selectedValue !== null || selectedValues.length > 0
    readonly property var questions: request.kind === "clarify"
        && Array.isArray(request.questions) ? request.questions : []
    readonly property var question: questions.length > 0
        ? questions[Math.min(questionIndex, questions.length - 1)] : null
    readonly property var currentOptions: question !== null
        ? question.options : request.options
    readonly property bool multiSelect: question !== null
        ? question.multiSelect === true : request.multiSelect === true
    readonly property string currentPrompt: question !== null
        ? question.prompt : (request.prompt || request.detail)
    // Text.truncated observes wrapped visual lines, unlike character counts.
    // Keep the disclosure visible while expanded so it can always be collapsed.
    readonly property bool longPrompt: detailExpanded
        || requestDetailText.truncated
    readonly property bool hasApprovalDescriptions: approvalChoices.some(choice =>
        choice.description !== "")
    readonly property var approvalChoices: {
        if (request.kind !== "approval")
            return [];
        const source = Array.isArray(request.options) && request.options.length > 0
            ? request.options : [
                { value: "deny", label: "Deny", description: "" },
                { value: "allow_once", label: "Allow once", description: "" }
            ];
        return source.map(choice => {
            const raw = String(choice.value ?? choice.id ?? choice.label ?? "")
                .toLowerCase().replace(/[ -]+/g, "_");
            let value = raw;
            if (["allow", "approve", "yes", "once"].indexOf(raw) >= 0)
                value = "allow_once";
            else if (["session", "allow_for_session"].indexOf(raw) >= 0)
                value = "allow_session";
            else if (["always", "permanent"].indexOf(raw) >= 0)
                value = "allow_always";
            else if (["reject", "no"].indexOf(raw) >= 0)
                value = "deny";
            if (["deny", "allow_once", "allow_session", "allow_always"]
                    .indexOf(value) < 0)
                return null;
            const label = value === "deny" ? "Deny"
                : value === "allow_once" ? "Allow once"
                    : value === "allow_session" ? "This session" : "Always allow";
            return {
                value: value,
                label: label,
                description: String(choice.description ?? choice.detail ?? "").trim()
            };
        }).filter(choice => choice !== null);
    }

    width: parent ? parent.width : 0
    height: Math.min(maxHeight, content.implicitHeight + 16)
    radius: HermesTheme.panelRadius
    color: HermesTheme.surfaceRaised
    border.width: 1
    border.color: requestFlick.activeFocus ? HermesTheme.focus
        : HermesTheme.amberBorder
    clip: true

    onRequestKeyChanged: {
        typedValue = "";
        selectedValue = null;
        selectedValues = [];
        answerDrafts = ({});
        questionIndex = 0;
        detailExpanded = false;
        confirmDecision = "";
        Qt.callLater(() => requestFlick.contentY = 0);
    }

    function allow(decision) {
        if (decision === "allow_always" && confirmDecision !== decision) {
            confirmDecision = decision;
            return;
        }
        confirmDecision = "";
        responseStarted(String(request.id ?? ""));
        Hermes.respondRequest(conversationId, request, {
            decision: decision,
            choice: decision
        });
    }

    function cancelRequest() {
        responseStarted(String(request.id ?? ""));
        Hermes.respondRequest(conversationId, request, {
            decision: "deny",
            choice: "deny",
            cancelled: true
        });
    }

    function submitValue() {
        const value = typedValue.trim() !== "" ? typedValue
            : multiSelect ? selectedValues : selectedValue;
        if (request.kind === "clarify") {
            const wireValue = Array.isArray(value) ? JSON.stringify(value) : value;
            if (questions.length === 0) {
                responseStarted(String(request.id ?? ""));
                Hermes.respondRequest(conversationId, request,
                    { answer: wireValue });
                return;
            }
            saveCurrent(value);
            if (questionIndex < questions.length - 1) {
                questionIndex++;
                detailExpanded = false;
                requestFlick.contentY = 0;
                restoreCurrent();
                focusQuestionStart();
                return;
            }
            const answers = questions.map(question => ({
                questionId: question.id,
                answer: Array.isArray(answerDrafts[question.id])
                    ? JSON.stringify(answerDrafts[question.id])
                    : answerDrafts[question.id]
            }));
            responseStarted(String(request.id ?? ""));
            Hermes.respondClarifyBatch(conversationId, request, answers);
        }
        else if (request.kind === "sudo") {
            responseStarted(String(request.id ?? ""));
            Hermes.respondRequest(conversationId, request, { decision: "allow", password: value });
        }
        else if (request.kind === "secret") {
            responseStarted(String(request.id ?? ""));
            Hermes.respondRequest(conversationId, request, { decision: "provide", value: value,
                secret: value });
        }
    }

    function saveCurrent(value) {
        if (!question)
            return;
        const next = Object.assign({}, answerDrafts);
        next[question.id] = value;
        answerDrafts = next;
    }

    function restoreCurrent() {
        const saved = question ? answerDrafts[question.id] : undefined;
        typedValue = typeof saved === "string" && !currentOptions.some(option =>
            option.value === saved) ? saved : "";
        if (multiSelect) {
            selectedValues = Array.isArray(saved) ? saved : [];
            selectedValue = null;
        } else {
            selectedValues = [];
            selectedValue = currentOptions.some(option => option.value === saved)
                ? saved : null;
        }
    }

    function backQuestion() {
        if (questionIndex <= 0)
            return;
        const value = typedValue.trim() !== "" ? typedValue
            : multiSelect ? selectedValues : selectedValue;
        if (value !== null)
            saveCurrent(value);
        questionIndex--;
        detailExpanded = false;
        requestFlick.contentY = 0;
        restoreCurrent();
        focusQuestionStart();
    }

    function chooseOption(value) {
        typedValue = "";
        if (!multiSelect) {
            selectedValue = value;
            selectedValues = [];
            return;
        }
        const next = selectedValues.slice();
        const at = next.indexOf(value);
        if (at >= 0)
            next.splice(at, 1);
        else
            next.push(value);
        selectedValues = next;
        selectedValue = null;
    }

    function ensureVisible(item) {
        if (!item || !requestFlick.interactive)
            return;
        Qt.callLater(() => {
            if (!item || !item.visible)
                return;
            const point = item.mapToItem(requestFlick, 0, 0);
            const margin = 8;
            let next = requestFlick.contentY;
            if (point.y < margin)
                next += point.y - margin;
            else if (point.y + item.height > requestFlick.height - margin)
                next += point.y + item.height - requestFlick.height + margin;
            requestFlick.contentY = Math.max(0, Math.min(next,
                requestFlick.contentHeight - requestFlick.height));
        });
    }

    function focusQuestionStart() {
        Qt.callLater(() => {
            requestFlick.contentY = 0;
            requestFlick.forceActiveFocus();
        });
    }

    component Action: ActionButton {
        id: action
        hPadding: 16
        fontFamily: HermesTheme.fontUi
        focusColor: HermesTheme.focus
        buttonRadius: HermesTheme.controlRadius
        tint: HermesTheme.textMuted
        fill: HermesTheme.hover
        onActiveFocusChanged: if (activeFocus) root.ensureVisible(action)
    }

    Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        height: 2
        radius: 1
        color: HermesTheme.amber
        z: 2
    }

    Flickable {
        id: requestFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: content.implicitHeight + 16
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height
        activeFocusOnTab: interactive
        clip: true
        Accessible.role: Accessible.StaticText
        Accessible.name: "Scrollable " + String(root.request.title ?? "Hermes request")

        Keys.onPressed: event => {
            const page = Math.max(40, requestFlick.height - 36);
            if (event.key === Qt.Key_Down) {
                requestFlick.contentY = Math.min(requestFlick.contentHeight
                    - requestFlick.height, requestFlick.contentY + 32);
                event.accepted = true;
            } else if (event.key === Qt.Key_Up) {
                requestFlick.contentY = Math.max(0, requestFlick.contentY - 32);
                event.accepted = true;
            } else if (event.key === Qt.Key_PageDown) {
                requestFlick.contentY = Math.min(requestFlick.contentHeight
                    - requestFlick.height, requestFlick.contentY + page);
                event.accepted = true;
            } else if (event.key === Qt.Key_PageUp) {
                requestFlick.contentY = Math.max(0, requestFlick.contentY - page);
                event.accepted = true;
            } else if (event.key === Qt.Key_Home) {
                requestFlick.contentY = 0;
                event.accepted = true;
            } else if (event.key === Qt.Key_End) {
                requestFlick.contentY = Math.max(0,
                    requestFlick.contentHeight - requestFlick.height);
                event.accepted = true;
            }
        }

        Column {
            id: content
            x: 8
            y: 8
            width: requestFlick.width - 16
            spacing: 7

        Item {
            width: parent.width
            height: 20

            Sym {
                id: requestIcon
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                name: root.request.kind === "clarify" ? "help"
                    : root.request.kind === "sudo" ? "admin_panel_settings"
                        : root.request.kind === "secret" ? "key" : "approval"
                size: Theme.iconSmall
                symWeight: 500
                color: HermesTheme.amber
            }

            Text {
                anchors.left: requestIcon.right
                anchors.leftMargin: 7
                anchors.right: waitingLabel.left
                anchors.rightMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                text: root.request.title
                elide: Text.ElideRight
                font.family: HermesTheme.fontUi
                font.pixelSize: Theme.typography.secondary
                font.weight: Theme.weightSemibold
                color: HermesTheme.amber
            }

            Text {
                id: waitingLabel
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: root.pending ? "sending…"
                    : root.questions.length > 1 ? (root.questionIndex + 1) + "/"
                        + root.questions.length : "needs you"
                font.family: HermesTheme.fontUi
                font.pixelSize: Theme.typography.metadata
                color: HermesTheme.textFaint
            }
        }

        Text {
            id: requestDetailText
            visible: root.currentPrompt !== ""
            width: parent.width
            height: visible ? implicitHeight : 0
            text: root.currentPrompt
            textFormat: Text.PlainText
            wrapMode: Text.WrapAtWordBoundaryOrAnywhere
            maximumLineCount: root.detailExpanded ? 100000 : 7
            elide: root.detailExpanded ? Text.ElideNone : Text.ElideRight
            lineHeight: Theme.proseLineHeight
            font.family: root.request.kind === "approval"
                ? HermesTheme.fontMono : HermesTheme.fontUi
            font.pixelSize: Theme.typography.primary
            color: HermesTheme.textSecondary
        }

        Action {
            visible: root.longPrompt
            label: root.detailExpanded ? "Show less" : "Show full request"
            enabled: !root.pending
            onTriggered: {
                root.detailExpanded = !root.detailExpanded;
                if (root.detailExpanded)
                    Qt.callLater(() => requestFlick.forceActiveFocus());
            }
        }

        Column {
            visible: root.request.kind === "approval"
                && root.hasApprovalDescriptions
            width: parent.width
            spacing: 4

            Repeater {
                model: root.approvalChoices.filter(choice =>
                    choice.description !== "")

                delegate: Rectangle {
                    id: approvalDetail
                    required property var modelData

                    width: parent.width
                    height: approvalDetailText.implicitHeight + 10
                    radius: HermesTheme.controlRadius
                    color: HermesTheme.hover
                    border.width: 1
                    border.color: HermesTheme.border

                    Text {
                        id: approvalDetailText
                        x: 7
                        y: 5
                        width: parent.width - 14
                        text: approvalDetail.modelData.label + " — "
                            + approvalDetail.modelData.description
                        textFormat: Text.PlainText
                        wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                        lineHeight: Theme.proseLineHeight
                        font.family: HermesTheme.fontUi
                        font.pixelSize: Theme.typography.secondary
                        color: HermesTheme.textSecondary
                    }
                }
            }
        }

        Column {
            visible: root.request.kind === "clarify" && root.currentOptions.length > 0
            width: parent.width
            spacing: 4

            Repeater {
                model: root.currentOptions

                delegate: Rectangle {
                    id: option
                    required property var modelData
                    required property int index
                    readonly property bool selected: root.multiSelect
                        ? root.selectedValues.indexOf(modelData.value) >= 0
                        : root.selectedValue === modelData.value

                    width: parent.width
                    height: optionColumn.implicitHeight + 10
                    radius: HermesTheme.controlRadius
                    color: selected ? Theme.chipHover
                        : optionMouse.containsMouse ? HermesTheme.hoverStrong : "transparent"
                    border.width: activeFocus ? 1 : 0
                    border.color: HermesTheme.focus
                    activeFocusOnTab: !root.pending
                    opacity: root.pending ? 0.5 : 1
                    Accessible.role: root.multiSelect
                        ? Accessible.CheckBox : Accessible.RadioButton
                    Accessible.name: modelData.label
                    Accessible.checked: selected
                    Accessible.onPressAction: if (!root.pending)
                        root.chooseOption(modelData.value)
                    onActiveFocusChanged: if (activeFocus)
                        root.ensureVisible(option)

                    Keys.onPressed: event => {
                        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                                || event.key === Qt.Key_Space) {
                            root.chooseOption(option.modelData.value);
                            event.accepted = true;
                        }
                    }

                    Sym {
                        id: radio
                        x: 7
                        anchors.verticalCenter: parent.verticalCenter
                        name: root.multiSelect
                            ? (option.selected ? "check_box" : "check_box_outline_blank")
                            : option.selected ? "radio_button_checked"
                                : "radio_button_unchecked"
                        size: Theme.iconSmall
                        symWeight: 500
                        color: option.selected ? HermesTheme.accent : HermesTheme.textFaint
                    }

                    Column {
                        id: optionColumn
                        x: 29
                        y: 5
                        width: parent.width - 36
                        spacing: 1

                        Text {
                            width: parent.width
                            text: option.modelData.label
                            wrapMode: Text.WordWrap
                            font.family: HermesTheme.fontUi
                            font.pixelSize: Theme.typography.secondary
                            color: HermesTheme.textPrimary
                        }

                        Text {
                            visible: text !== ""
                            width: parent.width
                            text: option.modelData.description
                            wrapMode: Text.WordWrap
                            maximumLineCount: 2
                            elide: Text.ElideRight
                            font.family: HermesTheme.fontUi
                            font.pixelSize: Theme.typography.secondary
                            color: HermesTheme.textFaint
                        }
                    }

                    MouseArea {
                        id: optionMouse
                        anchors.fill: parent
                        enabled: !root.pending
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            root.chooseOption(option.modelData.value);
                        }
                    }
                }
            }
        }

        Rectangle {
            visible: root.needsValue
            width: parent.width
            height: Theme.controlHeight
            radius: HermesTheme.controlRadius
            color: HermesTheme.surface
            border.width: 1
            border.color: valueInput.activeFocus ? HermesTheme.focus : HermesTheme.border

            TextInput {
                id: valueInput
                anchors.fill: parent
                anchors.leftMargin: 9
                anchors.rightMargin: 9
                enabled: !root.pending
                verticalAlignment: TextInput.AlignVCenter
                clip: true
                echoMode: root.request.kind === "sudo" || root.request.kind === "secret"
                    ? TextInput.Password : TextInput.Normal
                text: root.typedValue
                font.family: HermesTheme.fontUi
                font.pixelSize: Theme.typography.control
                color: HermesTheme.textPrimary
                selectionColor: HermesTheme.accentSoft
                onActiveFocusChanged: if (activeFocus)
                    root.ensureVisible(valueInput)
                onTextEdited: {
                    root.typedValue = text;
                    if (text !== "") {
                        root.selectedValue = null;
                        root.selectedValues = [];
                    }
                }
                Keys.onReturnPressed: {
                    if (!root.pending && root.hasAnswer)
                        root.submitValue();
                }

                Text {
                    visible: valueInput.text === "" && !valueInput.activeFocus
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.request.kind === "sudo" ? "Administrator password…"
                        : root.request.kind === "secret" ? "Secret value…"
                            : "Type an answer…"
                    font.family: HermesTheme.fontUi
                    font.pixelSize: Theme.typography.control
                    color: HermesTheme.textFaint
                }
            }
        }

        Flow {
            width: parent.width
            spacing: 5

            Repeater {
                model: root.approvalChoices
                delegate: Action {
                    required property var modelData
                    visible: root.request.kind === "approval"
                    label: modelData.value === "allow_always"
                            && root.confirmDecision === modelData.value
                        ? "Confirm always" : modelData.label
                    enabled: !root.pending
                    tint: modelData.value === "deny" ? HermesTheme.red
                        : modelData.value === "allow_once"
                            ? HermesTheme.accentForeground : HermesTheme.textMuted
                    fill: modelData.value === "allow_once"
                        ? HermesTheme.accent : HermesTheme.hover
                    onTriggered: {
                        if (modelData.value !== "allow_always")
                            root.confirmDecision = "";
                        root.allow(modelData.value);
                    }
                }
            }

            Action {
                visible: root.request.kind === "clarify" && root.questionIndex > 0
                label: "Back"
                enabled: !root.pending
                onTriggered: root.backQuestion()
            }

            Action {
                visible: root.request.kind !== "approval"
                label: "Cancel"
                enabled: !root.pending
                tint: HermesTheme.red
                onTriggered: root.cancelRequest()
            }

            Action {
                visible: root.request.kind !== "approval"
                label: root.pending ? "Sending…"
                    : root.request.kind === "clarify"
                        && root.questionIndex < root.questions.length - 1
                            ? "Next" : "Submit"
                enabled: !root.pending && root.hasAnswer
                tint: HermesTheme.accentForeground
                fill: HermesTheme.accent
                onTriggered: root.submitValue()
            }
        }

        Text {
            visible: root.confirmDecision === "allow_always"
            width: parent.width
            text: "Always allow persists beyond this one request. Select Confirm always to continue."
            wrapMode: Text.WordWrap
            lineHeight: Theme.proseLineHeight
            font.family: HermesTheme.fontUi
            font.pixelSize: Theme.typography.secondary
            color: HermesTheme.amber
        }

        Text {
            visible: root.failure !== ""
            width: parent.width
            text: root.failure
            wrapMode: Text.WordWrap
            font.family: HermesTheme.fontUi
            font.pixelSize: Theme.typography.secondary
            color: HermesTheme.red
        }
    }

    }

    ScrollChrome {
        visible: requestFlick.interactive
        anchors.fill: requestFlick
        target: requestFlick
        edgeColor: HermesTheme.surfaceRaised
        thumbColor: HermesTheme.accent
    }
}
