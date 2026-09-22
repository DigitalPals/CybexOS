pragma ComponentBehavior: Bound
import QtQuick
import "../Common"
import "../Common/GitHubHelpers.js" as GitHubHelpers

// The two parts of the GitHub module's settings that are not value rows: who
// the shell is reading GitHub as, and which repositories outside that account
// join the feed.
//
// A watch entry is canonicalised here, at the point of entry, so a pasted
// browser URL or an SSH remote becomes "owner/repo" before it is stored —
// which is why SettingsHelpers.repoListIn only has to recognise the canonical
// form.
Column {
    id: root

    readonly property var watch: Settings.modOpts.gh.watch
    readonly property int accountRepoCount: GitHub.repos.filter(row => row.account !== false).length
    readonly property var workflowFailedRepos: Object.keys(GitHub.workflowRepoErrors)
    readonly property var eventFailedRepos: Object.keys(GitHub.eventRepoErrors)

    property string addError: ""

    spacing: 8

    function addWatch(text) {
        const slug = GitHubHelpers.repoSlug(text);
        if (slug === "") {
            addError = "Not a repository — use owner/repo, or paste its GitHub URL";
            return false;
        }
        if (root.watch.some(entry => entry.toLowerCase() === slug.toLowerCase())) {
            addError = slug + " is already watched";
            return false;
        }
        if (root.watch.length >= GitHubHelpers.MAX_WATCH) {
            addError = "At most " + GitHubHelpers.MAX_WATCH + " watched repositories";
            return false;
        }
        addError = "";
        Settings.setModuleOption("gh", "watch", root.watch.concat([slug]));
        return true;
    }

    function removeWatch(slug) {
        addError = "";
        Settings.setModuleOption("gh", "watch",
            root.watch.filter(entry => entry !== slug));
    }

    // A 22px square beside a 28px row, the shape the Modules list already
    // uses for its per-row cog.
    component RowButton: Rectangle {
        id: button

        property string glyph: ""
        property string action: ""
        signal triggered()

        width: 22
        height: 22
        radius: 5
        color: buttonMouse.containsMouse || activeFocus ? Theme.hoverFill : "transparent"
        border.width: activeFocus ? 1 : 0
        border.color: Theme.accentText
        activeFocusOnTab: true
        Accessible.role: Accessible.Button
        Accessible.name: button.action
        Accessible.onPressAction: button.triggered()

        Keys.onPressed: event => {
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                    || event.key === Qt.Key_Space) {
                button.triggered();
                event.accepted = true;
            }
        }

        Sym {
            anchors.centerIn: parent
            name: button.glyph
            size: Theme.iconSmall
            symWeight: 450
            color: buttonMouse.containsMouse ? Theme.textMid : Theme.textDim
        }

        MouseArea {
            id: buttonMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
                button.forceActiveFocus();
                button.triggered();
            }
        }
    }

    // ---- account ----------------------------------------------------------
    SectionHeader {
        label: "ACCOUNT"
    }

    Rectangle {
        width: parent.width
        height: 52
        radius: Theme.rowRadius
        color: Theme.cardFill

        Sym {
            id: markGlyph
            anchors.left: parent.left
            anchors.leftMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            name: "code" // nf-fa-github
            size: Theme.iconMedium
            color: Theme.icon
        }

        Row {
            id: connectionState
            anchors.right: parent.right
            anchors.rightMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            spacing: 7

            readonly property bool failed: GitHub.error !== ""
            // This page is reachable from the module row's cog whether or not
            // the module is on, and with it off nothing polls — so the card
            // says that rather than spinning on a check that will never run.
            readonly property bool off: !GitHub.pollEnabled

            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: 6
                height: 6
                radius: 3
                color: connectionState.off ? Theme.dotDim
                    : connectionState.failed ? Theme.red
                    : GitHub.ready ? Theme.connected : Theme.amber
            }

            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: connectionState.off ? "Widget off"
                    : connectionState.failed ? "Unavailable"
                    : GitHub.ready ? "Connected" : "Checking…"
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.secondary
                color: Theme.textDim
            }
        }

        Column {
            anchors.left: markGlyph.right
            anchors.leftMargin: 10
            anchors.right: connectionState.left
            anchors.rightMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            spacing: 1

            Text {
                width: parent.width
                text: GitHub.login !== "" ? "@" + GitHub.login
                    : GitHub.pollEnabled ? "Not signed in" : "gh CLI"
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.primary
                font.weight: Theme.weightMedium
                color: Theme.textHi
                elide: Text.ElideRight
            }

            Text {
                width: parent.width
                text: {
                    if (!GitHub.pollEnabled)
                        return "Switch the widget on to read your repositories";
                    if (GitHub.error !== "")
                        return GitHub.error;
                    if (!GitHub.ready)
                        return "Reading the gh CLI's login…";
                    const orgs = GitHub.orgCount;
                    return "Authenticated via gh CLI · " + root.accountRepoCount
                        + " account repos"
                        + (orgs > 0 ? " across " + orgs + (orgs === 1 ? " org" : " orgs") : "");
                }
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.secondary
                color: GitHub.error !== "" ? Theme.redText : Theme.textLow
                elide: Text.ElideRight
            }
        }
    }

    Text {
        visible: GitHub.inboxError !== "" || GitHub.notificationError !== ""
            || root.workflowFailedRepos.length > 0 || root.eventFailedRepos.length > 0
        width: parent.width
        text: {
            const parts = [];
            if (GitHub.inboxError !== "")
                parts.push("Inbox paused: " + GitHub.inboxError);
            if (GitHub.notificationError !== "")
                parts.push("Notifications unavailable: " + GitHub.notificationError);
            if (root.workflowFailedRepos.length > 0)
                parts.push("Workflows unavailable for " + root.workflowFailedRepos.join(", "));
            if (root.eventFailedRepos.length > 0)
                parts.push("Repository events unavailable for "
                    + root.eventFailedRepos.join(", "));
            return parts.join("\n");
        }
        font.family: Theme.fontMenu
        font.pixelSize: Theme.typography.secondary
        color: GitHub.inboxError !== "" ? Theme.redText : Theme.amber
        wrapMode: Text.Wrap
    }

    // ---- watched repositories ---------------------------------------------
    SectionHeader {
        label: "WATCHED REPOS"
    }

    Item {
        width: parent.width
        height: Theme.settingsControlHeight

        SettingsAction {
            id: addAction
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: "Add"
            glyph: "add"
            onTriggered: {
                if (root.addWatch(addInput.text))
                    addInput.text = "";
                addInput.forceActiveFocus();
            }
        }

        Rectangle {
            anchors.left: parent.left
            anchors.right: addAction.left
            anchors.rightMargin: 6
            anchors.verticalCenter: parent.verticalCenter
            height: Theme.settingsControlHeight
            radius: 7
            color: addInput.activeFocus ? Theme.hoverFillStrong : Theme.cardFill
            border.width: addInput.activeFocus ? 1 : 0
            border.color: root.addError !== "" ? Theme.red : Theme.accentText

            TextInput {
                id: addInput
                anchors.left: parent.left
                anchors.leftMargin: 9
                anchors.right: parent.right
                anchors.rightMargin: 9
                anchors.verticalCenter: parent.verticalCenter
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.control
                color: Theme.textHi
                selectionColor: Theme.accentBg
                selectedTextColor: Theme.textHi
                clip: true
                activeFocusOnTab: true
                Accessible.role: Accessible.EditableText
                Accessible.name: "Repository to watch"
                onTextChanged: root.addError = ""
                onAccepted: {
                    if (root.addWatch(text))
                        text = "";
                }

                Keys.onPressed: event => {
                    if (event.key === Qt.Key_Escape) {
                        text = "";
                        focus = false;
                        event.accepted = true;
                    }
                }

                Text {
                    visible: addInput.text === ""
                    anchors.fill: parent
                    verticalAlignment: Text.AlignVCenter
                    text: "owner/repo"
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.control
                    color: Theme.textFaint
                    elide: Text.ElideRight
                }
            }

            MouseArea {
                anchors.fill: parent
                visible: !addInput.activeFocus
                cursorShape: Qt.IBeamCursor
                onClicked: addInput.forceActiveFocus()
            }
        }
    }

    Text {
        visible: root.addError !== ""
        width: parent.width
        text: root.addError
        font.family: Theme.fontMenu
        font.pixelSize: Theme.typography.secondary
        color: Theme.redText
        wrapMode: Text.Wrap
    }

    Column {
        width: parent.width
        spacing: 3

        Repeater {
            model: root.watch

            delegate: Rectangle {
                id: watchRow

                required property string modelData
                readonly property string errorText: GitHub.watchError(modelData)

                width: parent.width
                height: errorText !== "" ? 44 : Theme.settingsControlHeight
                radius: 7
                color: Theme.cardFill

                RowButton {
                    id: removeButton
                    anchors.right: parent.right
                    anchors.rightMargin: 3
                    anchors.verticalCenter: parent.verticalCenter
                    glyph: "close"
                    action: "Stop watching " + watchRow.modelData
                    onTriggered: root.removeWatch(watchRow.modelData)
                }

                Text {
                    id: watchedName
                    anchors.left: parent.left
                    anchors.leftMargin: 8
                    anchors.right: removeButton.left
                    anchors.rightMargin: 6
                    y: watchRow.errorText !== "" ? 5 : (parent.height - height) / 2
                    // The owner is dim and the name is not, the same split the
                    // popover's repository rows draw.
                    text: "<font color=\"" + Theme.textDim + "\">"
                        + watchRow.modelData.split("/")[0] + "/</font>"
                        + watchRow.modelData.split("/")[1]
                    textFormat: Text.StyledText
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.primary
                    color: Theme.textMid
                    elide: Text.ElideRight
                }

                Text {
                    visible: watchRow.errorText !== ""
                    anchors.left: parent.left
                    anchors.leftMargin: 8
                    anchors.right: removeButton.left
                    anchors.rightMargin: 6
                    y: 23
                    text: watchRow.errorText
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.secondary
                    color: Theme.amber
                    elide: Text.ElideRight
                }
            }
        }
    }

    Text {
        width: parent.width
        text: "The configured count applies to recent account and org repositories. "
            + "Every watched repository is additive to that list and, when enabled, "
            + "the workflow-report scope. Repository refresh uses the interval above; "
            + "the Inbox checks repository events and GitHub notifications every minute."
        font.family: Theme.fontMenu
        font.pixelSize: Theme.typography.secondary
        color: Theme.textFaint
        wrapMode: Text.Wrap
    }
}
