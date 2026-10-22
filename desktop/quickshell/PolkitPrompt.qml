pragma ComponentBehavior: Bound
import QtQuick
import "Common"
import "Common/PolkitHelpers.js" as PolkitHelpers
import "Settings" as SettingsUi

// Only the active conversation owns an input. The window destroys this view
// when it closes; responses go directly to Polkit, never through IPC or a
// command line. Keeping the view separate also permits real-engine fixtures.
FocusScope {
    id: root

    required property var flow
    property bool detailsOpen: false
    property bool revealed: false
    property bool attemptFailed: false
    property string feedback: ""
    property bool feedbackError: false
    readonly property bool finished: !flow || flow.isCompleted || flow.isCancelled
    readonly property bool responseRequired: !finished && flow.isResponseRequired
    readonly property bool secret: !flow || !flow.responseVisible
    readonly property string prompt: flow && flow.inputPrompt
        ? flow.inputPrompt.trim() : secret ? "Password" : "Response"
    readonly property string account: PolkitHelpers.identityLabel(flow ? flow.selectedIdentity : null)
    readonly property bool hasError: attemptFailed || feedbackError
    // A fingerprint or security-key step that PAM announced (docs/security.md).
    // Its message stays the flow's feedback after the step hands over to the
    // password, so it only speaks while no response is requested.
    readonly property string feedbackCue: PolkitHelpers.authenticationCue(feedback)
    readonly property bool cueActive: feedbackCue !== "" && !feedbackError
        && !responseRequired && !finished
    property bool cueRetry: false

    function statusText() {
        if (attemptFailed && !feedbackError)
            return "Authentication failed. Please try again.";
        if (feedbackCue !== "" && !feedbackError)
            return cueActive ? PolkitHelpers.cueText(feedbackCue, cueRetry) : "";
        if (feedback)
            return feedback;
        if (attemptFailed)
            return "Authentication failed. Please try again.";
        return !responseRequired && !finished ? "Waiting for authentication…" : "";
    }

    function noteFeedback() {
        // pam_fprintd reports a mismatch as an error, then asks again.
        if (feedbackError && feedbackCue === "fingerprint")
            cueRetry = true;
    }

    implicitHeight: content.implicitHeight
    focus: true
    Accessible.role: Accessible.Dialog
    Accessible.name: I18n.tr("Authentication required")

    function clearResponse() {
        response.clear();
        revealed = false;
    }

    function focusResponse() {
        if (responseRequired)
            response.forceActiveFocus();
        else
            cancelButton.forceActiveFocus();
    }

    function submit() {
        // Empty responses are valid for some PAM conversations. Polkit, not
        // presentation code, decides whether a response is acceptable.
        if (!responseRequired)
            return;
        feedback = "";
        feedbackError = false;
        attemptFailed = false;
        flow.submit(response.text);
        clearResponse();
    }

    function cancel() {
        clearResponse();
        if (!finished)
            flow.cancelAuthenticationRequest();
    }

    onFlowChanged: {
        clearResponse();
        detailsOpen = false;
        attemptFailed = false;
        cueRetry = false;
        feedback = flow ? flow.supplementaryMessage : "";
        feedbackError = !!(flow && flow.supplementaryIsError);
        Qt.callLater(focusResponse);
    }
    onResponseRequiredChanged: {
        clearResponse();
        if (responseRequired)
            cueRetry = false;
        Qt.callLater(focusResponse);
    }
    onFinishedChanged: if (finished) clearResponse()
    Component.onCompleted: Qt.callLater(focusResponse)
    Component.onDestruction: clearResponse()
    Keys.onEscapePressed: cancel()

    Connections {
        target: root.flow
        function onAuthenticationFailed() {
            root.attemptFailed = true;
            root.clearResponse();
            Qt.callLater(root.focusResponse);
        }
        function onSelectedIdentityChanged() {
            root.clearResponse();
            root.attemptFailed = false;
            root.cueRetry = false;
            root.feedback = "";
            root.feedbackError = false;
            Qt.callLater(root.focusResponse);
        }
        function onInputPromptChanged() { root.clearResponse(); }
        function onResponseVisibleChanged() { root.clearResponse(); }
        function onSupplementaryMessageChanged() {
            root.feedback = root.flow.supplementaryMessage;
            root.feedbackError = root.flow.supplementaryIsError;
            if (!root.feedbackError)
                root.attemptFailed = false;
            root.noteFeedback();
        }
        function onSupplementaryIsErrorChanged() {
            root.feedbackError = root.flow.supplementaryIsError;
            root.noteFeedback();
        }
    }

    Column {
        id: content
        width: root.width
        spacing: Theme.scaled(18)

        Row {
            width: parent.width
            spacing: Theme.scaled(12)

            Rectangle {
                width: Theme.scaled(40)
                height: width
                radius: Theme.chipRadius + 3
                color: Theme.chip
                Sym {
                    anchors.centerIn: parent
                    name: root.cueActive && root.feedbackCue === "securityKey" ? "passkey" : "lock"
                    size: Theme.iconLarge
                    color: Theme.accentText
                }
            }

            Column {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - Theme.scaled(52)
                spacing: 3
                Text {
                    width: parent.width
                    text: I18n.tr("Authentication required")
                    textFormat: Text.PlainText
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.heading
                    font.weight: Theme.weightSemibold
                    color: Theme.textHi
                    wrapMode: Text.Wrap
                }
                Text {
                    width: parent.width
                    text: root.account
                    textFormat: Text.PlainText
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.secondary
                    color: Theme.textMid
                    wrapMode: Text.Wrap
                }
            }
        }

        Text {
            width: parent.width
            text: root.flow && root.flow.message ? root.flow.message : "Authenticate to continue."
            textFormat: Text.PlainText
            font.family: Theme.fontMenu
            font.pixelSize: Theme.typography.primary
            color: Theme.textHi
            wrapMode: Text.Wrap
        }

        SettingsUi.SettingsSelect {
            id: accountSelect
            objectName: "polkitAccount"
            visible: model.length > 1
            width: parent.width
            maximumWidth: width
            accessibleName: "Authenticate as"
            model: PolkitHelpers.identityOptions(root.flow ? root.flow.identities : [])
            current: root.flow ? root.flow.identities.indexOf(root.flow.selectedIdentity) : -1
            enabled: !root.finished
            KeyNavigation.priority: KeyNavigation.BeforeItem
            KeyNavigation.tab: root.responseRequired ? response : cancelButton
            KeyNavigation.backtab: detailsButton
            onPicked: value => {
                root.clearResponse();
                root.flow.selectedIdentity = root.flow.identities[value];
            }
        }

        Column {
            visible: root.responseRequired
            width: parent.width
            spacing: Theme.scaled(7)

            Text {
                width: parent.width
                text: root.prompt
                textFormat: Text.PlainText
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.secondary
                color: Theme.textMid
                wrapMode: Text.Wrap
            }

            SettingsUi.SettingsField {
                id: response
                objectName: "polkitResponse"
                width: parent.width
                implicitHeight: Theme.scaled(42)
                enabled: root.responseRequired
                invalid: root.hasError
                rightPadding: root.secret ? revealButton.width + Theme.controlSpacing * 2 : Theme.controlSpacing
                echoMode: root.secret && !root.revealed ? TextInput.Password : TextInput.Normal
                passwordMaskDelay: 0
                // Revealing the password must not enable IME learning/prediction.
                inputMethodHints: root.secret
                    ? Qt.ImhHiddenText | Qt.ImhSensitiveData | Qt.ImhNoPredictiveText | Qt.ImhNoAutoUppercase
                    : Qt.ImhNoPredictiveText | Qt.ImhNoAutoUppercase
                Accessible.name: root.prompt
                KeyNavigation.priority: KeyNavigation.BeforeItem
                KeyNavigation.tab: root.secret ? revealButton : authenticateButton
                KeyNavigation.backtab: accountSelect.visible ? accountSelect : detailsButton
                onAccepted: root.submit()

                SettingsUi.SettingsAction {
                    id: revealButton
                    objectName: "polkitReveal"
                    anchors.right: parent.right
                    anchors.rightMargin: Theme.controlSpacing
                    anchors.verticalCenter: parent.verticalCenter
                    visible: root.secret
                    compact: true
                    text: root.revealed ? I18n.tr("Hide password") : I18n.tr("Show password")
                    glyph: root.revealed ? "visibility_off" : "visibility"
                    KeyNavigation.priority: KeyNavigation.BeforeItem
                    KeyNavigation.tab: authenticateButton
                    KeyNavigation.backtab: response
                    onTriggered: {
                        root.revealed = !root.revealed;
                        response.forceActiveFocus();
                    }
                }
            }
        }

        Text {
            objectName: "polkitStatus"
            width: parent.width
            visible: text !== ""
            text: root.statusText()
            textFormat: Text.PlainText
            font.family: Theme.fontMenu
            font.pixelSize: Theme.typography.secondary
            color: root.hasError ? Theme.redText : Theme.textMid
            wrapMode: Text.Wrap
        }

        Flow {
            width: parent.width
            spacing: Theme.controlSpacing
            layoutDirection: Qt.RightToLeft

            SettingsUi.SettingsAction {
                id: authenticateButton
                objectName: "polkitSubmit"
                text: root.responseRequired ? I18n.tr("Authenticate") : I18n.tr("Authenticating…")
                height: Theme.scaled(36)
                primary: true
                enabled: root.responseRequired
                KeyNavigation.priority: KeyNavigation.BeforeItem
                KeyNavigation.tab: cancelButton
                KeyNavigation.backtab: root.secret ? revealButton : response
                onTriggered: root.submit()
            }

            SettingsUi.SettingsAction {
                id: cancelButton
                objectName: "polkitCancel"
                text: I18n.tr("Cancel")
                height: Theme.scaled(36)
                enabled: !root.finished
                KeyNavigation.priority: KeyNavigation.BeforeItem
                KeyNavigation.tab: detailsButton
                KeyNavigation.backtab: root.responseRequired ? authenticateButton
                    : accountSelect.visible ? accountSelect : detailsButton
                onTriggered: root.cancel()
            }
        }

        Column {
            width: parent.width
            spacing: Theme.controlSpacing

            SettingsUi.SettingsAction {
                id: detailsButton
                objectName: "polkitDetails"
                text: root.detailsOpen ? I18n.tr("Hide details") : I18n.tr("Show details")
                glyph: root.detailsOpen ? "expand_less" : "expand_more"
                KeyNavigation.priority: KeyNavigation.BeforeItem
                KeyNavigation.tab: accountSelect.visible ? accountSelect
                    : root.responseRequired ? response : cancelButton
                KeyNavigation.backtab: cancelButton
                onTriggered: root.detailsOpen = !root.detailsOpen
            }

            Text {
                visible: root.detailsOpen
                width: parent.width
                text: "Action: " + (root.flow ? root.flow.actionId : "")
                textFormat: Text.PlainText
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.secondary
                color: Theme.textMid
                wrapMode: Text.WrapAnywhere
            }
        }
    }
}
