pragma ComponentBehavior: Bound
import QtQuick
import "../Common"
import "../Common/UpdatesHelpers.js" as Helpers
import "../Popovers" as Popovers

// The Software Update app's content: the prepared-update review, or one
// centred status with the next step. Technical wording stays behind
// "Show Details"; the updater's own messages are never the headline.
Item {
    id: root

    property var service: Updates
    property bool problemDetails: false
    property bool chooseSources: false
    readonly property string page: service.page
    readonly property string problem: service.problem
    readonly property var deployment: service.deployment
    readonly property var firmware: deployment.firmware || ({})
    readonly property var preparation: Helpers.preparation(deployment)
    readonly property bool update: (deployment.changeKind || "update") === "update"
    readonly property var installed: service.installedComponents
    readonly property var vendor: service.sourcesLoaded ? service.sources.cybexos : ({})
    readonly property var notes: Helpers.noteItems(vendor.notes || "", 5)
    readonly property bool bothAvailable: service.sourcesLoaded && service.sources.upstream.state === "available"
        && vendor.state === "available"

    onPageChanged: problemDetails = false

    function checked() {
        if (!service.checkedAt)
            return I18n.tr("Not checked yet");
        const time = Qt.formatTime(service.checkedAt, Qt.locale().timeFormat(Locale.ShortFormat));
        return new Date().toDateString() === service.checkedAt.toDateString()
            ? I18n.format("Last checked today at %1", [time])
            : I18n.format("Last checked %1", [service.checkedAt.toLocaleDateString(Qt.locale(), Locale.ShortFormat)]);
    }

    function availableBody() {
        const upstream = service.sources.upstream.state === "available";
        const lead = vendor.state === "available" && upstream
            ? I18n.format("Cybex OS %1 and new NixOS packages are available.", [vendor.available])
            : vendor.state === "available" ? I18n.format("Cybex OS %1 is available.", [vendor.available])
            : upstream ? I18n.tr("New NixOS packages are available.") : I18n.tr("Device firmware updates are available.");
        return lead + " " + I18n.tr("Prepare the update to see exactly what changes. Nothing is installed until you choose to.");
    }

    function info() {
        switch (page) {
        case "checking":
            return { tone: "neutral", busy: true, title: I18n.tr("Checking for updates…"), body: "" };
        case "current":
            return { tone: "ok", busy: false, title: I18n.tr("Your system is up to date"),
                body: (deployment.state === "done" && deployment.changeKind === "update"
                    ? I18n.tr("The last update was installed and passed its checks.") + "\n" : "") + checked() };
        case "available":
            return { tone: "accent", busy: false, title: I18n.tr("Updates are available"),
                body: availableBody() };
        case "preparing":
            return { tone: "accent", busy: true, title: I18n.tr("Getting the update ready"),
                body: I18n.tr("Downloading packages, building components when needed, and checking compatibility. Nothing changes until you choose Install.") };
        case "installing":
            return { tone: "accent", busy: true, title: I18n.tr("Installing the update"),
                body: deployment.state === "firmware"
                    ? I18n.tr("Installing device firmware. Keep your computer on and external power connected. Follow any device instructions below.")
                    : I18n.tr("This takes a few minutes. Keep your computer on. The desktop may restart briefly; this window opens again by itself.") };
        case "restart":
            if (firmware.needsShutdown)
                return { tone: "warn", busy: false, title: I18n.tr("Shut down to finish updating"),
                    body: I18n.tr("This device firmware requires a full shutdown. Save your work, shut down, then turn your computer on again.") };
            return { tone: "warn", busy: false, title: I18n.tr("Restart to finish updating"),
                body: I18n.tr("The update is installed and starts the next time you restart. Save your work first.") };
        case "finishing":
            return { tone: "accent", busy: true, title: I18n.tr("Finishing the update"),
                body: I18n.tr("Checking that everything works after the restart…") };
        case "confirm":
            return Helpers.confirmFailed(deployment.state, deployment.request)
                ? { tone: "warn", busy: false, title: I18n.tr("The restart couldn't be confirmed"),
                    body: I18n.tr("Cybex OS couldn't confirm that everything works after the restart. Keep this version if it works for you, or go back to the previous one.") }
                : { tone: "accent", busy: false, title: I18n.tr("Does everything work?"),
                    body: I18n.tr("Keep this version if everything works. If you restart without keeping it, your computer returns to the previous version.") };
        case "recovering":
            return { tone: "warn", busy: true, title: I18n.tr("Restoring the previous version"),
                body: I18n.tr("Please wait. Your files and settings are kept.") };
        case "unavailable":
            return { tone: "neutral", busy: false, title: I18n.tr("Updates are available after installation"),
                body: I18n.tr("Install Cybex OS to receive system updates.") };
        }
        switch (problem) {
        case "status":
            return { tone: "error", busy: false, title: I18n.tr("The update status is unavailable"),
                body: I18n.tr("The updater didn't respond. Try again in a moment.") };
        case "failed":
            if (firmware.state === "failed")
                return { tone: "error", busy: false, title: I18n.tr("Some firmware updates did not finish"), body: I18n.tr(firmware.error || "Check the device and try again.") };
            return { tone: "error", busy: false,
                title: update ? I18n.tr("The update couldn't be prepared") : I18n.tr("The system change couldn't be prepared"),
                body: I18n.tr("Nothing on your computer was changed.") };
        case "interrupted":
            if (["installing", "failed"].includes(firmware.state))
                return { tone: "warn", busy: false, title: I18n.tr("Firmware installation was interrupted"), body: I18n.tr("Check the device before retrying. Firmware changes cannot be undone by restoring the previous OS version.") };
            return { tone: "warn", busy: false, title: I18n.tr("Preparing the update was interrupted"),
                body: I18n.tr("Nothing on your computer was changed.") };
        case "stale":
            return { tone: "warn", busy: false, title: I18n.tr("Your system changed after the update was prepared"),
                body: I18n.tr("Prepare the update again so that it includes those changes.") };
        case "rolled-back":
            return { tone: "warn", busy: false, title: I18n.tr("Your computer went back to the previous version"),
                body: I18n.tr("The update didn't pass its checks, so Cybex OS restored the version you had before. Your files and settings are not affected.") };
        case "recovery-failed":
            return { tone: "error", busy: false, title: I18n.tr("Restoring the previous version needs attention"),
                body: I18n.tr("Cybex OS couldn't finish returning to the previous version. Try again, or restart your computer to start the previous version.") };
        }
        return { tone: "warn", busy: false, title: I18n.tr("Couldn't check for updates"),
            body: service.sourcesLoaded ? I18n.tr("Some update sources could not be checked. Try again later.")
                : I18n.tr("Check your internet connection and try again.") };
    }

    readonly property var current: info()
    // Icons by page, then by problem; kept apart from the copy above.
    readonly property var pageIcons: ({
        checking: "refresh", current: "circle-check", available: "download", preparing: "download",
        installing: "loader-2", restart: "refresh", finishing: "rosette-discount-check",
        recovering: "arrow-back-up", unavailable: "info-circle"
    })
    readonly property var problemIcons: ({
        status: "alert-triangle", failed: "alert-triangle", interrupted: "alert-triangle", stale: "refresh",
        "rolled-back": "arrow-back-up", "recovery-failed": "alert-triangle", check: "cloud-off"
    })
    readonly property var actionIcons: ({ available: "download" })
    readonly property string icon: page === "confirm"
        ? (Helpers.confirmFailed(deployment.state, deployment.request) ? "alert-triangle" : "rosette-discount-check")
        : page === "problem" ? problemIcons[problem] || "alert-triangle" : pageIcons[page] || "info-circle"

    ReadyPage {
        anchors.fill: parent
        visible: root.page === "ready"
        service: root.service
    }

    StatusPage {
        id: status
        anchors.fill: parent
        visible: root.page !== "ready"
        glyph: root.icon
        tone: root.current.tone
        busy: root.current.busy
        title: root.current.title
        body: root.current.body
        progress: root.page === "preparing" ? root.preparation.fraction
            : root.deployment.state === "firmware" && typeof root.firmware.percent === "number" ? root.firmware.percent / 100 : -1
        progressLabel: root.page !== "preparing" ? root.current.title : root.preparation.fraction >= 0
            ? I18n.tr("Download progress") : I18n.tr("Update preparation progress")

        Column {
            width: parent.width
            spacing: Theme.scaled(8)
            visible: ["installing", "restart", "current", "problem", "confirm", "finishing"].includes(root.page)
                && (root.firmware.state === "installing" || !!root.firmware.error || (root.firmware.requests || []).length > 0)
            Text {
                width: parent.width
                text: (root.firmware.devices || []).find(device => device.id === root.firmware.current)?.name || ""
                visible: root.deployment.state === "firmware"
                color: Theme.textHi
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.primary
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
                textFormat: Text.PlainText
            }
            Repeater {
                model: root.firmware.requests || []
                delegate: Text {
                    required property var modelData
                    objectName: "updateFirmwareRequest"
                    width: parent.width
                    text: modelData.message || ""
                    color: Theme.amber
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.primary
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.Wrap
                    textFormat: Text.PlainText
                }
            }
            Text {
                width: parent.width
                text: I18n.tr(root.firmware.error || "")
                visible: text !== ""
                color: Theme.redText
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.secondary
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
                textFormat: Text.PlainText
            }
        }

        // Preparation steps follow the worker's phases.
        Row {
            visible: root.page === "preparing"
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Theme.scaled(18)
            Repeater {
                model: [
                    { label: I18n.tr("Download and build"), done: root.deployment.state === "validating", active: root.deployment.state !== "validating" },
                    { label: I18n.tr("Check compatibility"), done: false, active: root.deployment.state === "validating" },
                    { label: I18n.tr("Ready to review"), done: false, active: false }
                ]
                delegate: Row {
                    id: step
                    required property var modelData
                    spacing: Theme.scaled(6)
                    Sym {
                        anchors.verticalCenter: parent.verticalCenter
                        name: step.modelData.done ? "check" : "circle-dot"
                        size: Theme.iconSmall
                        color: step.modelData.done ? Theme.ok : step.modelData.active ? Theme.accentText : Theme.textFaint
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: step.modelData.label
                        color: step.modelData.active ? Theme.textHi : Theme.textDim
                        font.family: Theme.fontMenu
                        font.pixelSize: Theme.typography.secondary
                        font.weight: step.modelData.active ? Theme.weightSemibold : Theme.weightMedium
                    }
                }
            }
        }

        Column {
            visible: root.page === "preparing"
            width: parent.width
            spacing: Theme.scaled(6)
            Text {
                objectName: "updateActivity"
                width: parent.width
                text: I18n.tr(root.preparation.label)
                color: Theme.textHi
                horizontalAlignment: Text.AlignHCenter
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.primary
                font.weight: Theme.weightSemibold
                wrapMode: Text.Wrap
            }
            Text {
                objectName: "updateDownloadProgress"
                visible: !!root.preparation.downloads
                width: parent.width
                text: {
                    const value = root.preparation.downloads;
                    if (!value) return "";
                    return value.expected > value.done
                        ? I18n.format("Downloaded %1 of %2", [Helpers.downloadSize(value.done), Helpers.downloadSize(value.expected)])
                        : I18n.format("Downloaded %1", [Helpers.downloadSize(value.done)]);
                }
                color: Theme.textDim
                horizontalAlignment: Text.AlignHCenter
                font.family: Theme.fontNumeric
                font.pixelSize: Theme.typography.secondary
                wrapMode: Text.Wrap
            }
            Text {
                objectName: "updateBuildProgress"
                visible: !!root.preparation.builds
                width: parent.width
                text: {
                    const value = root.preparation.builds;
                    if (!value) return "";
                    return value.expected > 0
                        ? I18n.format("Builds: %1 of %2 complete · %3 running", [value.done, value.expected, value.active])
                        : I18n.format("Builds: %1 running", [value.active]);
                }
                color: Theme.textDim
                horizontalAlignment: Text.AlignHCenter
                font.family: Theme.fontNumeric
                font.pixelSize: Theme.typography.secondary
                wrapMode: Text.Wrap
            }
            Text {
                objectName: "updateElapsed"
                width: parent.width
                text: I18n.format("Elapsed: %1", [Helpers.elapsed(root.deployment.elapsedSeconds)])
                color: Theme.textDim
                horizontalAlignment: Text.AlignHCenter
                font.family: Theme.fontNumeric
                font.pixelSize: Theme.typography.secondary
            }
        }

        // Installed versions, from the running system's own manifest.
        Row {
            visible: root.page === "current" && Object.keys(root.installed).length > 0
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Theme.scaled(8)
            Repeater {
                model: ["cybexos", "nixos", "kernel"].filter(id => !!root.installed[id])
                delegate: Rectangle {
                    id: fact
                    required property string modelData
                    width: factColumn.implicitWidth + Theme.scaled(28)
                    height: factColumn.implicitHeight + Theme.scaled(16)
                    radius: Theme.chipRadius + 3
                    color: Theme.cardFill
                    border.width: 1
                    border.color: Theme.hairlineSoft
                    Column {
                        id: factColumn
                        anchors.centerIn: parent
                        spacing: Theme.scaled(2)
                        Text {
                            text: I18n.tr(Helpers.component(fact.modelData).label)
                            color: Theme.textDim
                            font.family: Theme.fontMenu
                            font.pixelSize: Theme.typography.metadata
                            font.weight: Theme.weightSemibold
                        }
                        Text {
                            text: Helpers.versionParts(fact.modelData, root.installed[fact.modelData]).text
                                || root.installed[fact.modelData]
                            color: Theme.textHi
                            font.family: Theme.fontNumeric
                            font.pixelSize: Theme.typography.secondary
                            textFormat: Text.PlainText
                        }
                    }
                }
            }
        }

        // Release notes for an available Cybex OS version.
        Rectangle {
            visible: root.page === "available" && root.notes.items.length > 0
            width: parent.width
            height: notesColumn.implicitHeight + Theme.scaled(24)
            radius: Theme.chipRadius + 3
            color: Theme.cardFill
            border.width: 1
            border.color: Theme.hairlineSoft
            Column {
                id: notesColumn
                x: Theme.scaled(14)
                y: Theme.scaled(12)
                width: parent.width - Theme.scaled(28)
                spacing: Theme.scaled(4)
                Text {
                    text: I18n.format("What's new in Cybex OS %1", [root.vendor.available || ""])
                    color: Theme.textHi
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.secondary
                    font.weight: Theme.weightSemibold
                    textFormat: Text.PlainText
                }
                Repeater {
                    model: root.notes.items
                    delegate: Text {
                        required property string modelData
                        width: notesColumn.width
                        text: "•  " + modelData
                        color: Theme.textMid
                        font.family: Theme.fontMenu
                        font.pixelSize: Theme.typography.secondary
                        wrapMode: Text.Wrap
                        textFormat: Text.PlainText
                    }
                }
            }
        }

        // After a failed combined preview, NixOS updates can go ahead alone.
        Rectangle {
            visible: root.page === "problem" && root.service.upstreamOnlyAvailable
            width: parent.width
            height: Math.max(upstreamOnly.implicitHeight, upstreamOnlyButton.height) + Theme.scaled(24)
            radius: Theme.chipRadius + 3
            color: Theme.cardFill
            border.width: 1
            border.color: Theme.hairlineSoft
            Column {
                id: upstreamOnly
                x: Theme.scaled(14)
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - upstreamOnlyButton.width - Theme.scaled(40)
                spacing: Theme.scaled(2)
                Text {
                    width: parent.width
                    text: I18n.tr("Install the NixOS updates on their own")
                    color: Theme.textHi
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.primary
                    font.weight: Theme.weightSemibold
                    wrapMode: Text.Wrap
                }
                Text {
                    width: parent.width
                    text: I18n.format("Linux, apps and system fixes. Cybex OS stays at %1.", [root.vendor.installed || ""])
                    color: Theme.textDim
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.secondary
                    wrapMode: Text.Wrap
                    textFormat: Text.PlainText
                }
            }
            UpdateButton {
                id: upstreamOnlyButton
                objectName: "updateUpstreamOnly"
                anchors.right: parent.right
                anchors.rightMargin: Theme.scaled(12)
                anchors.verticalCenter: parent.verticalCenter
                primary: true
                text: I18n.tr("Prepare")
                enabled: !root.service.runActive && !root.service.requestPending
                onTriggered: root.service.prepareUpstream()
            }
        }

        // Source choice before a manual download, when both have updates.
        Column {
            visible: root.page === "available" && root.bothAvailable && root.chooseSources
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Theme.scaled(8)
            Repeater {
                model: ["upstream", "cybexos"]
                delegate: Row {
                    id: source
                    required property string modelData
                    readonly property string name: modelData === "upstream" ? I18n.tr("NixOS packages") : I18n.tr("Cybex OS")
                    spacing: Theme.scaled(10)
                    Toggle {
                        objectName: source.modelData === "upstream" ? "updateSelectUpstream" : "updateSelectCybexOS"
                        metrics: Theme.switchCompact
                        checked: root.service.selectedSources.includes(source.modelData)
                        enabled: !root.service.runActive
                        accessibleName: I18n.format("Include %1", [source.name])
                        onToggled: value => root.service.selectSource(source.modelData, value)
                    }
                    Text {
                        objectName: source.modelData === "upstream" ? "updateUpstreamLabel" : "updateCybexOSLabel"
                        anchors.verticalCenter: parent.verticalCenter
                        text: source.name
                        color: Theme.textHi
                        font.family: Theme.fontMenu
                        font.pixelSize: Theme.typography.primary
                    }
                }
            }
        }

        Row {
            id: actions
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Theme.scaled(10)

            UpdateButton {
                visible: root.page === "available" && root.bothAvailable
                text: root.chooseSources ? I18n.tr("Hide Sources") : I18n.tr("Choose Sources")
                onTriggered: root.chooseSources = !root.chooseSources
            }
            UpdateButton {
                visible: root.page === "problem" || (root.page === "confirm" && root.service.error !== "")
                text: root.problemDetails ? I18n.tr("Hide Details") : I18n.tr("Show Details")
                onTriggered: root.problemDetails = !root.problemDetails
            }
            UpdateButton {
                objectName: "updateDismiss"
                visible: root.page === "problem" && root.service.actions.discard && root.problem !== "rolled-back"
                text: root.problem === "stale" ? I18n.tr("Discard") : I18n.tr("Dismiss")
                onTriggered: root.service.discard()
            }
            UpdateButton {
                objectName: "updateBuildLog"
                visible: root.page === "preparing" && !!root.deployment.transaction
                text: I18n.tr("Build Log")
                onTriggered: root.service.openLog()
            }
            UpdateButton {
                visible: ["restart", "preparing"].includes(root.page)
                text: root.page === "restart" ? I18n.tr("Later") : I18n.tr("Close")
                onTriggered: root.service.close()
            }
            UpdateButton {
                visible: root.page === "confirm"
                text: I18n.tr("Go Back to Previous Version")
                enabled: root.service.actions.rollback && !root.service.requestPending
                onTriggered: root.service.rollback()
            }
            UpdateButton {
                objectName: "updateCheck"
                visible: root.page === "current" || (root.page === "problem" && root.problem === "check")
                primary: root.page === "problem"
                text: root.page === "current" ? I18n.tr("Check Now") : I18n.tr("Try Again")
                enabled: !root.service.busy
                onTriggered: { root.service.refreshStatus(); root.service.check(true); }
            }
            UpdateButton {
                objectName: "updatePrimary"
                visible: ["available", "restart", "confirm"].includes(root.page)
                    || (root.page === "problem" && ["failed", "interrupted", "stale", "rolled-back", "recovery-failed", "status"].includes(root.problem))
                primary: true
                glyph: root.actionIcons[root.page] || ""
                enabled: !root.service.requestPending && (root.page === "restart" ? !root.service.runActive
                    : root.page === "confirm" ? root.service.actions.confirm
                    : root.problem === "rolled-back" ? root.service.actions.discard
                    : root.problem === "recovery-failed" ? root.service.actions.rollback
                    : root.problem === "status" ? true
                    : root.service.actions.prepare)
                text: root.service.requestPending && !root.service.runActive ? I18n.tr("Waiting for authorization…")
                    : root.page === "available" ? I18n.tr("Prepare Update")
                    : root.page === "restart" ? (root.firmware.needsShutdown ? I18n.tr("Shut Down Now") : I18n.tr("Restart Now"))
                    : root.page === "confirm" ? I18n.tr("Keep This Version")
                    : root.problem === "rolled-back" ? I18n.tr("OK")
                    : root.problem === "recovery-failed" ? I18n.tr("Try Restoring Again")
                    : root.problem === "stale" ? I18n.tr("Prepare Again")
                    : I18n.tr("Try Again")
                onTriggered: {
                    if (root.page === "restart") {
                        if (root.firmware.needsShutdown) Session.shutdown();
                        else Session.reboot();
                    }
                    else if (root.page === "confirm") root.service.confirm();
                    else if (root.problem === "rolled-back") root.service.discard();
                    else if (root.problem === "recovery-failed") root.service.rollback();
                    else if (root.problem === "status") root.service.refreshStatus();
                    else root.service.prepare();
                }
            }
        }

        Text {
            objectName: "updateRequestError"
            visible: root.service.requestFailure !== "" && !["problem", "confirm"].includes(root.page)
            width: parent.width
            text: root.service.requestFailure
            color: Theme.redText
            horizontalAlignment: Text.AlignHCenter
            font.family: Theme.fontMenu
            font.pixelSize: Theme.typography.secondary
            wrapMode: Text.Wrap
            textFormat: Text.PlainText
            Accessible.role: Accessible.AlertMessage
            Accessible.name: text
        }

        Text {
            visible: ["preparing", "restart", "available"].includes(root.page)
            width: parent.width
            text: root.page === "preparing"
                ? I18n.tr("You can close this window and keep working. The menubar shows when the update is ready.")
                : root.page === "restart"
                ? I18n.tr("After you sign in, Cybex OS checks that everything works before it keeps the new version. If your computer can't start it, the next restart uses the previous version.")
                : root.service.automatic.prepare
                ? I18n.tr("Updates are also prepared automatically while your computer is plugged in and on an unmetered network.") : ""
            color: Theme.textDim
            horizontalAlignment: Text.AlignHCenter
            font.family: Theme.fontMenu
            font.pixelSize: Theme.typography.secondary
            wrapMode: Text.Wrap
            textFormat: Text.PlainText
        }

        // The updater's own explanation, for those who want it.
        Rectangle {
            visible: root.problemDetails
            width: parent.width
            height: detailsColumn.implicitHeight + Theme.scaled(24)
            radius: Theme.chipRadius + 3
            color: Theme.insetSurface
            border.width: 1
            border.color: Theme.hairlineSoft
            Column {
                id: detailsColumn
                x: Theme.scaled(14)
                y: Theme.scaled(12)
                width: parent.width - Theme.scaled(28)
                spacing: Theme.scaled(10)
                Text {
                    objectName: "updateError"
                    width: parent.width
                    text: root.service.error || root.deployment.phase || I18n.tr("No further details were reported.")
                    color: Theme.textMid
                    font.family: Theme.fontMono
                    font.pixelSize: Theme.typography.metadata
                    wrapMode: Text.Wrap
                    textFormat: Text.PlainText
                }
                Flow {
                    width: parent.width
                    spacing: Theme.scaled(8)
                    UpdateButton {
                        visible: !!root.deployment.transaction
                        text: I18n.tr("Build Log")
                        onTriggered: root.service.openLog()
                    }
                    UpdateButton {
                        text: I18n.tr("Update History")
                        onTriggered: root.service.openRecoveryPoints()
                    }
                }
            }
        }

        // Machine policy; changing it asks for administrator authorization.
        Rectangle {
            visible: root.page === "current"
            anchors.horizontalCenter: parent.horizontalCenter
            width: Math.min(parent.width, Theme.scaled(480))
            height: automaticCopy.implicitHeight + Theme.scaled(24)
            radius: Theme.chipRadius + 3
            color: Theme.cardFill
            border.width: 1
            border.color: Theme.hairlineSoft
            Column {
                id: automaticCopy
                x: Theme.scaled(14)
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - automaticToggle.width - Theme.scaled(40)
                spacing: Theme.scaled(2)
                Text {
                    width: parent.width
                    text: I18n.tr("Prepare updates automatically")
                    color: Theme.textHi
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.primary
                    font.weight: Theme.weightSemibold
                    wrapMode: Text.Wrap
                }
                Text {
                    width: parent.width
                    text: I18n.tr("Prepared in the background while plugged in. You still choose when to install.")
                    color: Theme.textDim
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.secondary
                    wrapMode: Text.Wrap
                }
            }
            Toggle {
                id: automaticToggle
                objectName: "updateAutomatic"
                anchors.right: parent.right
                anchors.rightMargin: Theme.scaled(14)
                anchors.verticalCenter: parent.verticalCenter
                checked: root.service.automatic.prepare === true
                enabled: !root.service.choosingAutomatic && root.service.statusLoaded
                accessibleName: I18n.tr("Prepare updates automatically")
                onToggled: value => root.service.setAutomatic("prepare", value)
            }
        }

        Row {
            visible: root.page === "current"
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Theme.scaled(16)
            Popovers.LinkText {
                text: I18n.tr("Update history")
                onClicked: root.service.openRecoveryPoints()
            }
        }
    }
}
