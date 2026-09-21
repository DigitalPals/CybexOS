pragma ComponentBehavior: Bound
import QtQuick
import "../Common"

// Primary setup connects this client to an existing Hermes WebUI session.
// The optional local-provider section is capability-gated and therefore absent
// from this workstation's remote-only deployment. Neither password/API-key
// field is persisted by QML; both are cleared as soon as an attempt starts.
Item {
    id: root

    property int maxHeight: 650
    property bool advancedOpen: false
    property string remoteErrorText: ""
    property string remoteNoticeText: ""
    property string localErrorText: ""
    property string localNoticeText: ""
    signal configured()
    signal closeRequested()

    readonly property bool remoteSigningIn: Hermes.actionPending(
        "remote-login", "", "")
    readonly property bool remoteSigningOut: Hermes.actionPending(
        "remote-logout", "", "")
    readonly property bool remoteBusy: remoteSigningIn || remoteSigningOut
        || Hermes.remoteLoading
    readonly property bool localValidating: Hermes.actionPending(
        "provider-validate", "", "")
    readonly property bool localConfiguring: Hermes.actionPending(
        "provider-configure", "", "")
    readonly property bool localBusy: localValidating || localConfiguring
    readonly property int contentHeight: form.implicitHeight + 28

    width: parent ? parent.width : 0
    implicitHeight: Math.min(maxHeight, contentHeight)
    height: implicitHeight

    function clearSecret() {
        remotePasswordField.text = "";
        providerSecretField.text = "";
    }

    function focusFirstField() {
        authFlick.contentY = 0;
        if (remoteUrlField.visible)
            remoteUrlField.forceInputFocus();
        else if (backToChat.visible && backToChat.enabled)
            backToChat.forceActiveFocus();
        else if (advancedToggle.visible)
            advancedToggle.forceActiveFocus();
        else
            authFlick.forceActiveFocus();
    }

    function ensureVisible(item) {
        if (!item || !authFlick.interactive)
            return;
        Qt.callLater(() => {
            if (!item || !item.visible)
                return;
            const point = item.mapToItem(authFlick.contentItem, 0, 0);
            const margin = 10;
            let next = authFlick.contentY;
            if (point.y < authFlick.contentY + margin)
                next = point.y - margin;
            else if (point.y + item.height
                    > authFlick.contentY + authFlick.height - margin)
                next = point.y + item.height - authFlick.height + margin;
            authFlick.contentY = Math.max(0, Math.min(next,
                authFlick.contentHeight - authFlick.height));
        });
    }

    function syncRemoteUrl() {
        if (remoteUrlField.text.trim() === "" && Hermes.remoteOrigin !== "")
            remoteUrlField.text = Hermes.remoteOrigin;
    }

    function loginRemote() {
        const url = remoteUrlField.text.trim();
        if (url === "") {
            remoteErrorText = "Enter the Hermes WebUI URL.";
            remoteUrlField.forceInputFocus();
            return;
        }
        if (remotePasswordField.text === "") {
            remoteErrorText = "Enter the WebUI password.";
            remotePasswordField.forceInputFocus();
            return;
        }
        remoteErrorText = "";
        remoteNoticeText = "";
        // HermesRpc serializes this argument synchronously. Clear the only UI
        // copy immediately; callbacks never capture or display it.
        const request = Hermes.loginRemote(url, remotePasswordField.text, () => {
            root.remoteNoticeText = "Remote Hermes session connected.";
            root.configured();
        }, reason => root.remoteErrorText = reason);
        remotePasswordField.text = "";
        if (request === "" && remoteErrorText === "")
            remoteErrorText = "Could not start remote sign-in.";
    }

    function logoutRemote() {
        remoteErrorText = "";
        remoteNoticeText = "";
        clearSecret();
        Hermes.logoutRemote(() => {
            root.remoteNoticeText = Hermes.remoteConfigured
                ? "The saved session was cleared, but this remote URL remains configured and still requires sign-in."
                : Hermes.localBackendAvailable
                    ? "Remote session removed. The advanced local provider can now be used."
                    : "Remote session removed. Enter a remote WebUI URL to reconnect.";
            root.syncRemoteUrl();
            Qt.callLater(() => root.focusFirstField());
        }, reason => root.remoteErrorText = reason);
    }

    function configureLocalProvider() {
        const url = providerUrlField.text.trim();
        let model = providerModelField.text.trim();
        if (url === "") {
            localErrorText = "Enter the local provider API URL.";
            providerUrlField.forceInputFocus();
            return;
        }
        localErrorText = "";
        localNoticeText = "";
        // The key lives only in this short asynchronous validation/configure
        // chain. The masked field is cleared before either response arrives.
        const secret = providerSecretField.text;
        providerSecretField.text = "";
        Hermes.validateCustomProvider(url, secret, result => {
            const value = result && typeof result === "object" ? result : {};
            if (value.ok !== true) {
                root.localErrorText = "The local provider rejected the connection.";
                return;
            }
            if (model === "" && Array.isArray(value.models) && value.models.length > 0)
                model = String(value.models[0]);
            if (model === "") {
                root.localErrorText = "Enter the model ID exposed by this provider.";
                providerModelField.forceInputFocus();
                return;
            }
            Hermes.configureCustomProvider(url, secret, model, () => {
                root.localNoticeText = "Local model provider configured.";
                root.configured();
            }, () => root.localErrorText =
                "Could not configure the local model provider.");
        }, () => root.localErrorText =
            "Could not validate the local model provider.");
    }

    onVisibleChanged: {
        if (!visible)
            clearSecret();
        else {
            authFlick.contentY = 0;
            syncRemoteUrl();
        }
    }

    Connections {
        target: Hermes
        function onRemoteOriginChanged() { root.syncRemoteUrl(); }
    }

    component EntryField: Column {
        id: field
        property alias text: input.text
        property alias echoMode: input.echoMode
        property string label: ""
        property string placeholder: ""
        property int inputHints: Qt.ImhNone
        signal accepted()

        function forceInputFocus() { input.forceActiveFocus(); }

        width: parent ? parent.width : 0
        spacing: 5

        Text {
            width: parent.width
            text: field.label
            font.family: HermesTheme.fontUi
            font.pixelSize: Theme.typography.control
            font.weight: Theme.weightSemibold
            color: HermesTheme.textSecondary
        }

        Rectangle {
            width: parent.width
            height: 38
            radius: HermesTheme.controlRadius
            color: HermesTheme.canvas
            border.width: 1
            border.color: input.activeFocus ? HermesTheme.focus
                : HermesTheme.borderStrong

            TextInput {
                id: input
                anchors.fill: parent
                anchors.leftMargin: 10
                anchors.rightMargin: 10
                verticalAlignment: TextInput.AlignVCenter
                activeFocusOnTab: true
                Accessible.role: Accessible.EditableText
                Accessible.name: field.label
                clip: true
                selectByMouse: true
                inputMethodHints: field.inputHints
                font.family: field.echoMode === TextInput.Password
                    ? HermesTheme.fontUi : HermesTheme.fontMono
                font.pixelSize: Theme.typography.control
                color: HermesTheme.textPrimary
                onAccepted: field.accepted()
                onActiveFocusChanged: if (activeFocus) root.ensureVisible(input)

                Text {
                    visible: input.text === "" && !input.activeFocus
                    anchors.verticalCenter: parent.verticalCenter
                    text: field.placeholder
                    font.family: HermesTheme.fontUi
                    font.pixelSize: Theme.typography.control
                    color: HermesTheme.textFaint
                }
            }
        }
    }

    component AuthAction: ActionButton {
        id: action
        onActiveFocusChanged: if (activeFocus) root.ensureVisible(action)
    }

    component SectionRule: Rectangle {
        width: parent ? parent.width : 0
        height: 1
        color: HermesTheme.border
    }

    Rectangle {
        anchors.fill: parent
        radius: HermesTheme.panelRadius
        color: HermesTheme.surface
        border.width: 1
        border.color: HermesTheme.border
    }

    Flickable {
        id: authFlick
        anchors.fill: parent
        anchors.margins: 1
        contentWidth: width
        contentHeight: root.contentHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Column {
            id: form
            x: 14
            y: 14
            width: parent.width - 28
            spacing: 12

            Row {
                width: parent.width
                spacing: 10

                Rectangle {
                    width: 38
                    height: 38
                    radius: 19
                    color: Theme.chip
                    Text {
                        anchors.centerIn: parent
                        text: "⚕"
                        font.family: HermesTheme.fontUi
                        font.pixelSize: Theme.iconLarge
                        font.weight: Theme.weightSemibold
                        color: Hermes.remoteConnected ? HermesTheme.success
                            : Hermes.remoteSessionExpired ? HermesTheme.amber
                                : HermesTheme.accent
                    }
                }

                Column {
                    width: parent.width - 48
                    spacing: 3
                    Text {
                        width: parent.width
                        text: Hermes.remoteConnected ? "Remote Hermes connected"
                            : Hermes.remoteSessionExpired ? "Remote session expired"
                                : "Connect to Hermes WebUI"
                        font.family: HermesTheme.fontUi
                        font.pixelSize: Theme.typography.heading
                        font.weight: Theme.weightSemibold
                        color: HermesTheme.textPrimary
                    }
                    Text {
                        width: parent.width
                        text: Hermes.remoteConnected
                            ? Hermes.remoteOrigin
                            : "Use the URL and password from the Hermes WebUI you want this menubar to control."
                        wrapMode: Text.WordWrap
                        font.family: Hermes.remoteConnected
                            ? HermesTheme.fontMono : HermesTheme.fontUi
                        font.pixelSize: Theme.typography.secondary
                        color: Hermes.remoteConnected ? HermesTheme.success
                            : HermesTheme.textMuted
                    }
                }
            }

            Rectangle {
                visible: Hermes.remoteSessionExpired
                width: parent.width
                height: expiredCopy.implicitHeight + 20
                radius: HermesTheme.controlRadius
                color: HermesTheme.amberSoft
                border.width: 1
                border.color: HermesTheme.amberBorder

                Text {
                    id: expiredCopy
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.margins: 10
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Session sign-in required. An HTTP 302 from Hermes WebUI means its browser session has expired or requires sign-in; it is not a usable API response. Enter the password again to renew this client session."
                    wrapMode: Text.WordWrap
                    font.family: HermesTheme.fontUi
                    font.pixelSize: Theme.typography.secondary
                    color: HermesTheme.textSecondary
                }
            }

            Rectangle {
                visible: !Hermes.remoteConnected && !Hermes.remoteSessionExpired
                width: parent.width
                height: remoteExplanation.implicitHeight + 20
                radius: HermesTheme.controlRadius
                color: Theme.chip
                border.width: 1
                border.color: HermesTheme.border

                Text {
                    id: remoteExplanation
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.margins: 10
                    anchors.verticalCenter: parent.verticalCenter
                    text: "This signs in to a remote Hermes WebUI session. The password is sent once to the local bridge, is never retained or displayed by Quickshell, and is cleared from this form immediately."
                    wrapMode: Text.WordWrap
                    font.family: HermesTheme.fontUi
                    font.pixelSize: Theme.typography.secondary
                    color: HermesTheme.textSecondary
                }
            }

            EntryField {
                id: remoteUrlField
                visible: !Hermes.remoteConnected
                label: "Hermes WebUI URL"
                placeholder: "https://hermes.example.com"
                inputHints: Qt.ImhUrlCharactersOnly
                onTextChanged: {
                    root.remoteErrorText = "";
                    root.remoteNoticeText = "";
                }
                onAccepted: remotePasswordField.forceInputFocus()
            }

            EntryField {
                id: remotePasswordField
                visible: !Hermes.remoteConnected
                label: "WebUI password"
                placeholder: "Not stored by the menubar"
                echoMode: TextInput.Password
                inputHints: Qt.ImhSensitiveData | Qt.ImhNoPredictiveText
                onAccepted: root.loginRemote()
            }

            Text {
                visible: root.remoteErrorText !== "" || Hermes.remoteError !== ""
                width: parent.width
                text: root.remoteErrorText !== ""
                    ? root.remoteErrorText : Hermes.remoteError
                wrapMode: Text.WordWrap
                font.family: HermesTheme.fontUi
                font.pixelSize: Theme.typography.secondary
                color: HermesTheme.red
            }

            Text {
                visible: root.remoteNoticeText !== ""
                width: parent.width
                text: root.remoteNoticeText
                wrapMode: Text.WordWrap
                font.family: HermesTheme.fontUi
                font.pixelSize: Theme.typography.secondary
                color: HermesTheme.success
            }

            Row {
                width: parent.width
                spacing: 8

                AuthAction {
                    visible: !Hermes.remoteConnected
                    label: root.remoteSigningIn ? "Signing in…" : "Sign in to WebUI"
                    enabled: remoteUrlField.text.trim() !== ""
                        && remotePasswordField.text !== "" && !root.remoteBusy
                    hPadding: 22
                    fontFamily: HermesTheme.fontUi
                    focusColor: HermesTheme.focus
                    buttonRadius: HermesTheme.controlRadius
                    tint: HermesTheme.accentForeground
                    fill: HermesTheme.accent
                    onTriggered: root.loginRemote()
                }

                AuthAction {
                    id: backToChat
                    visible: Hermes.remoteConnected
                    label: "Back to chat"
                    enabled: !root.remoteBusy
                    hPadding: 20
                    fontFamily: HermesTheme.fontUi
                    focusColor: HermesTheme.focus
                    buttonRadius: HermesTheme.controlRadius
                    tint: HermesTheme.accentForeground
                    fill: HermesTheme.accent
                    onTriggered: root.closeRequested()
                }

                AuthAction {
                    visible: Hermes.remoteConfigured
                    label: root.remoteSigningOut ? "Clearing…"
                        : Hermes.remoteConnected ? "Sign out" : "Forget remote"
                    enabled: !root.remoteBusy
                    hPadding: 18
                    fontFamily: HermesTheme.fontUi
                    focusColor: HermesTheme.focus
                    buttonRadius: HermesTheme.controlRadius
                    tint: HermesTheme.red
                    fill: HermesTheme.hover
                    onTriggered: root.logoutRemote()
                }
            }

            SectionRule {
                visible: Hermes.localBackendAvailable
            }

            Rectangle {
                id: advancedToggle
                visible: Hermes.localBackendAvailable
                width: parent.width
                height: advancedRow.implicitHeight + 16
                radius: HermesTheme.controlRadius
                color: activeFocus || advancedMouse.containsMouse
                    ? HermesTheme.hoverStrong : "transparent"
                border.width: activeFocus || root.advancedOpen ? 1 : 0
                border.color: activeFocus ? HermesTheme.focus : HermesTheme.border
                activeFocusOnTab: true
                Accessible.role: Accessible.Button
                Accessible.name: "Advanced local model-provider setup"
                Accessible.onPressAction: root.advancedOpen = !root.advancedOpen
                onActiveFocusChanged: if (activeFocus)
                    root.ensureVisible(advancedToggle)
                Keys.onPressed: event => {
                    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                            || event.key === Qt.Key_Space) {
                        root.advancedOpen = !root.advancedOpen;
                        event.accepted = true;
                    }
                }

                Row {
                    id: advancedRow
                    x: 8
                    y: 8
                    width: parent.width - 16
                    spacing: 8

                    Sym {
                        anchors.verticalCenter: parent.verticalCenter
                        name: root.advancedOpen ? "expand_less" : "expand_more"
                        size: Theme.iconSmall
                        symWeight: 480
                        color: HermesTheme.textMuted
                    }

                    Column {
                        width: parent.width - 24
                        spacing: 2
                        Text {
                            width: parent.width
                            text: "ADVANCED · LOCAL MODEL PROVIDER"
                            font.family: HermesTheme.fontUi
                            font.pixelSize: Theme.typography.metadata
                            font.weight: Theme.weightSemibold
                            font.letterSpacing: 1
                            color: HermesTheme.textMuted
                        }
                        Text {
                            width: parent.width
                            text: "Separate from remote WebUI sign-in. Use this only when Hermes runs on this machine."
                            wrapMode: Text.WordWrap
                            font.family: HermesTheme.fontUi
                            font.pixelSize: Theme.typography.secondary
                            color: HermesTheme.textFaint
                        }
                    }
                }

                MouseArea {
                    id: advancedMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.advancedOpen = !root.advancedOpen
                }
            }

            Column {
                visible: Hermes.localBackendAvailable && root.advancedOpen
                width: parent.width
                spacing: 10

                Text {
                    width: parent.width
                    text: Hermes.localProviderReady
                        ? "Local provider ready · " + Hermes.providerName + " · "
                            + Hermes.providerModel
                            + (Hermes.remoteConfigured
                                ? ". Remote mode remains selected until the remote is forgotten above."
                                : ".")
                        : "Configure an OpenAI-compatible inference endpoint for the local Hermes backend."
                    wrapMode: Text.WordWrap
                    font.family: HermesTheme.fontUi
                    font.pixelSize: Theme.typography.secondary
                    color: Hermes.localProviderReady ? HermesTheme.success
                        : HermesTheme.textSecondary
                }

                EntryField {
                    id: providerUrlField
                    label: "OpenAI-compatible API URL"
                    placeholder: "http://127.0.0.1:8000/v1"
                    inputHints: Qt.ImhUrlCharactersOnly
                    onTextChanged: root.localErrorText = ""
                    onAccepted: providerModelField.forceInputFocus()
                }

                EntryField {
                    id: providerModelField
                    label: "Model ID"
                    placeholder: "provider/model-id (optional when discoverable)"
                    onAccepted: providerSecretField.forceInputFocus()
                }

                EntryField {
                    id: providerSecretField
                    label: "Provider API key (optional for local endpoints)"
                    placeholder: "Cleared after this attempt"
                    echoMode: TextInput.Password
                    inputHints: Qt.ImhSensitiveData | Qt.ImhNoPredictiveText
                    onAccepted: root.configureLocalProvider()
                }

                Text {
                    visible: root.localErrorText !== ""
                    width: parent.width
                    text: root.localErrorText
                    wrapMode: Text.WordWrap
                    font.family: HermesTheme.fontUi
                    font.pixelSize: Theme.typography.secondary
                    color: HermesTheme.red
                }

                Text {
                    visible: root.localNoticeText !== ""
                    width: parent.width
                    text: root.localNoticeText
                    wrapMode: Text.WordWrap
                    font.family: HermesTheme.fontUi
                    font.pixelSize: Theme.typography.secondary
                    color: HermesTheme.success
                }

                Row {
                    width: parent.width
                    spacing: 8

                    AuthAction {
                        label: root.localBusy ? "Connecting…" : "Configure local provider"
                        enabled: providerUrlField.text.trim() !== "" && !root.localBusy
                        hPadding: 20
                        fontFamily: HermesTheme.fontUi
                        focusColor: HermesTheme.focus
                        buttonRadius: HermesTheme.controlRadius
                        tint: HermesTheme.textSecondary
                        fill: HermesTheme.hover
                        onTriggered: root.configureLocalProvider()
                    }

                    AuthAction {
                        label: "Open full local setup"
                        enabled: !root.localBusy
                        hPadding: 18
                        fontFamily: HermesTheme.fontUi
                        focusColor: HermesTheme.focus
                        buttonRadius: HermesTheme.controlRadius
                        tint: HermesTheme.textSecondary
                        fill: HermesTheme.hover
                        onTriggered: Hermes.configureModel()
                    }
                }

                Text {
                    width: parent.width
                    text: "Local provider credentials are stored by Hermes in ~/.hermes/.env. Remote WebUI passwords are never retained by the menubar."
                    wrapMode: Text.WordWrap
                    font.family: HermesTheme.fontMono
                    font.pixelSize: Theme.typography.metadata
                    color: HermesTheme.textFaint
                }
            }
        }
    }
}
