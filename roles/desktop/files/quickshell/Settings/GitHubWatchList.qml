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

    // The options above are rows at row spacing; this block is a group of
    // its own below them.
    topPadding: Theme.settingsGroupSpacing - Theme.settingsRowSpacing
    spacing: Theme.settingsContentSpacing

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

    // ---- account ----------------------------------------------------------
    // Who the shell reads GitHub as, on the row grid rather than in a card:
    // the mark in the label lane, the login beside it, the connection state
    // on the control edge.
    SectionHeader {
        label: "ACCOUNT"
    }

    Item {
        width: parent.width
        height: Math.max(Theme.settingsControlHeight, accountLines.implicitHeight)

        Sym {
            id: markGlyph
            x: Theme.settingsMarkInset
            anchors.verticalCenter: parent.verticalCenter
            name: "code" // nf-fa-github
            size: Theme.iconMedium
            color: Theme.icon
        }

        Row {
            id: connectionState
            anchors.right: parent.right
            anchors.rightMargin: Theme.chipHeight
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.iconTextSpacing

            readonly property bool failed: GitHub.error !== ""
            // This page is reachable from the widget's options whether or not
            // the widget is on, and with it off nothing polls — so the row
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
            id: accountLines
            anchors.left: markGlyph.right
            anchors.leftMargin: Theme.controlSpacing
            anchors.right: connectionState.left
            anchors.rightMargin: Theme.controlSpacing
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

    SettingsHint {
        width: parent.width
        maximumLines: 6
        tone: GitHub.inboxError !== "" ? "error" : "warning"
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
    }

    // ---- watched repositories ---------------------------------------------
    SectionHeader {
        label: "WATCHED REPOS"
    }

    Item {
        width: parent.width
        height: Theme.settingsControlHeight

        SettingsField {
            id: addInput
            x: Theme.settingsMarkInset
            width: Math.max(0, addAction.x - Theme.controlSpacing - x)
            anchors.verticalCenter: parent.verticalCenter
            placeholderText: "owner/repo"
            invalid: root.addError !== ""
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
        }

        SettingsAction {
            id: addAction
            anchors.right: parent.right
            anchors.rightMargin: Theme.chipHeight
            anchors.verticalCenter: parent.verticalCenter
            text: "Add"
            glyph: "add"
            onTriggered: {
                if (root.addWatch(addInput.text))
                    addInput.text = "";
                addInput.forceActiveFocus();
            }
        }
    }

    SettingsHint {
        width: parent.width
        tone: "error"
        text: root.addError
    }

    // One hairline-separated row per watched repository.
    Column {
        width: parent.width
        spacing: Theme.settingsRowSpacing

        Repeater {
            model: root.watch

            delegate: Item {
                id: watchRow

                required property string modelData
                required property int index
                readonly property string errorText: GitHub.watchError(modelData)

                width: parent.width
                height: Theme.settingsControlHeight + (errorText !== "" ? errorLine.height : 0)

                Rectangle {
                    visible: watchRow.index > 0
                    x: Theme.settingsMarkInset
                    y: -Math.ceil(Theme.settingsRowSpacing / 2) - 1
                    width: Math.max(0, parent.width - x)
                    height: 1
                    color: Theme.hairlineSoft
                }

                Text {
                    id: watchedName
                    x: Theme.settingsMarkInset
                    width: Math.max(0, removeAction.x - Theme.controlSpacing - x)
                    height: Theme.settingsControlHeight
                    verticalAlignment: Text.AlignVCenter
                    // The owner is dim and the name is not, the same split the
                    // popover's repository rows draw.
                    text: "<font color=\"" + Theme.textDim + "\">"
                        + watchRow.modelData.split("/")[0] + "/</font>"
                        + watchRow.modelData.split("/")[1]
                    textFormat: Text.StyledText
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.control
                    color: Theme.textMid
                    elide: Text.ElideRight
                }

                SettingsAction {
                    id: removeAction
                    anchors.right: parent.right
                    anchors.rightMargin: Theme.chipHeight
                    y: (Theme.settingsControlHeight - height) / 2
                    text: "Stop watching " + watchRow.modelData
                    tooltip: "Stop watching"
                    glyph: "close"
                    compact: true
                    onTriggered: root.removeWatch(watchRow.modelData)
                }

                SettingsHint {
                    id: errorLine
                    y: Theme.settingsControlHeight
                    width: removeAction.x
                    tone: "warning"
                    maximumLines: 2
                    text: watchRow.errorText
                }
            }
        }
    }

    SettingsHint {
        width: parent.width
        maximumLines: 5
        text: "The configured count applies to recent account and org repositories. "
            + "Every watched repository is additive to that list and, when enabled, "
            + "the workflow-report scope. Repository refresh uses the interval above; "
            + "the Inbox checks repository events and GitHub notifications every minute."
    }
}
