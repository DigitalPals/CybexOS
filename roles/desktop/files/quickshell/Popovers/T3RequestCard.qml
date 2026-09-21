pragma ComponentBehavior: Bound
import QtQuick
import "../Common"

// Composer-attached approval or structured-question drawer. Question answers
// and paging live in T3Code, so rejected requests remain intact across navigation.
Rectangle {
    id: root

    required property string threadId
    required property string kind // "approval" | "input"
    required property var request
    property int queuedCount: 0

    readonly property bool isInput: kind === "input"
    readonly property var questions: isInput && Array.isArray(request.questions)
        ? request.questions : []
    readonly property int storedIndex: isInput
        ? T3Code.inputQuestionIndex(threadId, request.requestId) : 0
    readonly property int questionIndex: questions.length > 0
        ? Math.max(0, Math.min(storedIndex, questions.length - 1)) : 0
    readonly property var question: questions.length > 0 ? questions[questionIndex] : null
    readonly property bool pending: T3Code.actionPending(kind, threadId, request.requestId)
    readonly property bool actionable: T3Code.canDispatch && !pending
    readonly property string failure: T3Code.actionError(kind, threadId, request.requestId)
    readonly property bool answered: question !== null
        && T3Code.inputQuestionAnswered(threadId, request.requestId, question)
    readonly property var answers: isInput ? T3Code.buildInputAnswers(threadId, request) : null

    width: parent ? parent.width : 0
    height: content.implicitHeight + 14
    radius: T3Theme.panelRadius
    color: T3Theme.surfaceRaised
    border.width: 1
    border.color: T3Theme.borderStrong

    // Tighter pill, and a brighter default tint than the other pages.
    component Action: ActionButton {
        hPadding: 16
        fontFamily: T3Theme.fontUi
        focusColor: T3Theme.focus
        buttonRadius: T3Theme.controlRadius
        tint: T3Theme.textMuted
        fill: T3Theme.hover
    }

    Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        height: 2
        radius: 1
        color: T3Theme.amber
    }

    Column {
        id: content
        x: 7
        y: 7
        width: parent.width - 14
        spacing: 7

        Item {
            width: parent.width
            height: Math.max(requestHeading.implicitHeight, requestStatus.implicitHeight)

            Text {
                id: requestHeading
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: root.isInput && root.question
                    ? root.question.header
                    : root.request.kind === "file-change" ? "Edit approval"
                    : root.request.kind === "file-read" ? "Read approval" : "Command approval"
                font.family: T3Theme.fontUi
                font.pixelSize: Theme.typography.secondary
                font.weight: Theme.weightSemibold
                color: T3Theme.amber
            }

            Text {
                id: requestStatus
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: root.isInput ? (root.questionIndex + 1) + "/" + root.questions.length
                    + (root.queuedCount > 0 ? "  ·  +" + root.queuedCount + " queued" : "")
                    : "needs you"
                font.family: T3Theme.fontUi
                font.pixelSize: Theme.typography.secondary
                font.features: T3Theme.tabularNumberFeatures
                color: T3Theme.textFaint
            }
        }

        Text {
            width: parent.width
            text: root.isInput && root.question ? root.question.question
                : typeof root.request.detail === "string" && root.request.detail !== ""
                    ? root.request.detail : "Approval requested"
            wrapMode: Text.WrapAtWordBoundaryOrAnywhere
            lineHeight: Theme.proseLineHeight
            maximumLineCount: root.isInput ? 5 : 6
            elide: Text.ElideRight
            font.family: root.isInput ? T3Theme.fontUi : T3Theme.fontMono
            font.pixelSize: Theme.typography.primary
            color: T3Theme.textSecondary
        }

        Text {
            visible: root.isInput && root.question !== null
                && root.question.multiSelect === true
            width: parent.width
            text: "Select one or more options."
            font.family: T3Theme.fontUi
            font.pixelSize: Theme.typography.secondary
            color: T3Theme.textFaint
        }

        Column {
            visible: root.isInput && root.question !== null
            width: parent.width
            spacing: 4

            Repeater {
                model: root.question ? root.question.options : []

                delegate: Rectangle {
                    id: option
                    required property var modelData
                    required property int index

                    readonly property bool chosen: root.question
                        && T3Code.inputCustomAnswer(root.threadId,
                            root.request.requestId, root.question.id).trim() === ""
                        && T3Code.inputSelectedLabels(root.threadId,
                            root.request.requestId, root.question.id)
                            .indexOf(modelData.label) >= 0

                    width: parent.width
                    height: optionText.implicitHeight + 10
                    radius: T3Theme.controlRadius
                    color: chosen ? T3Theme.accentSoft
                        : optionMouse.containsMouse ? T3Theme.hoverStrong : "transparent"
                    opacity: root.actionable ? 1 : 0.5
                    activeFocusOnTab: root.actionable
                    Accessible.role: root.question && root.question.multiSelect
                        ? Accessible.CheckBox : Accessible.RadioButton
                    Accessible.name: option.modelData.label
                    Accessible.checked: option.chosen

                    Keys.onPressed: event => {
                        if (!root.actionable)
                            return;
                        if (event.key >= Qt.Key_1 && event.key <= Qt.Key_9) {
                            const at = event.key - Qt.Key_1;
                            if (root.question && at < root.question.options.length) {
                                const selectedOption = root.question.options[at];
                                T3Code.toggleInputOption(root.threadId, root.request.requestId,
                                    root.question.id, selectedOption.label,
                                    root.question.multiSelect);
                                event.accepted = true;
                            }
                        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                                || event.key === Qt.Key_Space) {
                            T3Code.toggleInputOption(root.threadId, root.request.requestId,
                                root.question.id, option.modelData.label,
                                root.question.multiSelect);
                            event.accepted = true;
                        }
                    }

                    Sym {
                        id: marker
                        x: 7
                        anchors.verticalCenter: parent.verticalCenter
                        name: root.question && root.question.multiSelect
                            ? (option.chosen ? "check_box" : "check_box_outline_blank")
                            : (option.chosen ? "radio_button_checked" : "radio_button_unchecked")
                        size: Theme.iconSmall
                        symWeight: 500
                        color: option.chosen ? T3Theme.accent : T3Theme.textFaint
                    }

                    Column {
                        id: optionText
                        x: 23
                        y: 5
                        width: parent.width - 52
                        spacing: 1

                        Text {
                            width: parent.width
                            text: option.modelData.label
                            wrapMode: Text.WordWrap
                            lineHeight: Theme.proseLineHeight
                            font.family: T3Theme.fontUi
                            font.pixelSize: Theme.typography.secondary
                            color: option.chosen ? T3Theme.textPrimary : T3Theme.textSecondary
                        }

                        Text {
                            visible: text !== ""
                            width: parent.width
                            text: option.modelData.description ?? ""
                            maximumLineCount: 2
                            elide: Text.ElideRight
                            wrapMode: Text.WordWrap
                            lineHeight: Theme.proseLineHeight
                            font.family: T3Theme.fontUi
                            font.pixelSize: Theme.typography.secondary
                            color: T3Theme.textFaint
                        }
                    }

                    Text {
                        anchors.right: parent.right
                        anchors.rightMargin: 8
                        anchors.verticalCenter: parent.verticalCenter
                        text: option.index < 9 ? String(option.index + 1) : ""
                        font.family: T3Theme.fontUi
                        font.pixelSize: Theme.typography.metadata
                        font.features: T3Theme.tabularNumberFeatures
                        color: T3Theme.textFaint
                    }

                    MouseArea {
                        id: optionMouse
                        anchors.fill: parent
                        enabled: root.actionable
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: T3Code.toggleInputOption(root.threadId,
                            root.request.requestId, root.question.id,
                            option.modelData.label, root.question.multiSelect)
                    }
                }
            }
        }

        Rectangle {
            visible: root.isInput && root.question !== null
            width: parent.width
            height: Theme.controlHeight
            radius: T3Theme.controlRadius
            color: T3Theme.surface
            border.width: 1
            border.color: custom.activeFocus ? T3Theme.focus : T3Theme.border

            TextInput {
                id: custom
                property bool syncing: false
                // Not dead: onDraftKeyChanged below re-syncs the field when
                // the card moves to another thread, request or question.
                property string draftKey: root.question
                    ? root.threadId + "|" + root.request.requestId + "|" + root.question.id : ""

                function syncDraft() {
                    if (!root.question)
                        return;
                    const next = T3Code.inputCustomAnswer(root.threadId,
                        root.request.requestId, root.question.id);
                    if (text === next)
                        return;
                    syncing = true;
                    text = next;
                    cursorPosition = text.length;
                    syncing = false;
                }

                anchors.fill: parent
                anchors.leftMargin: 8
                anchors.rightMargin: 8
                verticalAlignment: TextInput.AlignVCenter
                enabled: root.actionable
                clip: true
                font.family: T3Theme.fontUi
                font.pixelSize: Theme.typography.control
                color: T3Theme.textPrimary
                onDraftKeyChanged: syncDraft()
                onTextChanged: {
                    if (!syncing && activeFocus && root.question)
                        T3Code.setInputCustomAnswer(root.threadId, root.request.requestId,
                            root.question.id, text);
                }
                Component.onCompleted: syncDraft()

                Text {
                    visible: custom.text === "" && !custom.activeFocus
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Or type a custom answer…"
                    font.family: T3Theme.fontUi
                    font.pixelSize: Theme.typography.control
                    color: T3Theme.textFaint
                }

                Connections {
                    target: T3Code
                    function onUserInputDraftsChanged() { custom.syncDraft(); }
                }
            }
        }

        Row {
            visible: root.isInput
            spacing: 5

            Action {
                label: "Back"
                enabled: root.actionable && root.questionIndex > 0
                onTriggered: T3Code.setInputQuestionIndex(root.threadId,
                    root.request.requestId, root.questionIndex - 1)
            }

            Action {
                visible: root.questionIndex < root.questions.length - 1
                label: "Next"
                enabled: root.actionable && root.answered
                tint: T3Theme.accentForeground
                fill: T3Theme.accent
                onTriggered: T3Code.setInputQuestionIndex(root.threadId,
                    root.request.requestId, root.questionIndex + 1)
            }

            Action {
                visible: root.questionIndex >= root.questions.length - 1
                label: root.pending ? "Sending…" : "Submit"
                enabled: root.actionable && root.answers !== null
                tint: T3Theme.accentForeground
                fill: T3Theme.accent
                onTriggered: {
                    const answers = T3Code.buildInputAnswers(root.threadId, root.request);
                    if (answers !== null)
                        T3Code.respondUserInput(root.threadId, root.request.requestId, answers);
                }
            }
        }

        // The reference client's four decisions, in its order and wording:
        // quietest on the left, the primary approval on the right. Flow lets
        // the long "Always allow" pill wrap in this narrow card.
        Flow {
            visible: !root.isInput
            width: parent.width
            spacing: 5

            Action {
                label: "Cancel"
                enabled: !root.pending && T3Code.canDispatch
                onTriggered: T3Code.respondApproval(root.threadId,
                    root.request.requestId, "cancel")
            }

            Action {
                label: "Decline"
                enabled: !root.pending && T3Code.canDispatch
                tint: T3Theme.red
                fill: T3Theme.redSoft
                onTriggered: T3Code.respondApproval(root.threadId,
                    root.request.requestId, "decline")
            }

            Action {
                label: "Always allow this session"
                enabled: !root.pending && T3Code.canDispatch
                tint: T3Theme.accent
                fill: T3Theme.accentSoft
                onTriggered: T3Code.respondApproval(root.threadId,
                    root.request.requestId, "acceptForSession")
            }

            Action {
                label: root.pending ? "Sending…" : "Approve"
                enabled: !root.pending && T3Code.canDispatch
                tint: T3Theme.accentForeground
                fill: T3Theme.accent
                onTriggered: T3Code.respondApproval(root.threadId,
                    root.request.requestId, "accept")
            }
        }

        Text {
            visible: root.failure !== ""
            width: parent.width
            text: root.failure
            wrapMode: Text.WordWrap
            lineHeight: Theme.proseLineHeight
            maximumLineCount: 3
            elide: Text.ElideRight
            font.family: T3Theme.fontUi
            font.pixelSize: Theme.typography.secondary
            color: T3Theme.red
        }
    }
}
