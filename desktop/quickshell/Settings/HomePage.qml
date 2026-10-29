pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import "../Common"
import "../Common/BackupHelpers.js" as BackupHelpers
import "../Common/Format.js" as Format
import "LocalTime.js" as LocalTime

// Home (2026-10 redesign): this computer at a glance, and what needs the
// person. It replaces About: the identity and update state sit at the top,
// storage, battery, backups and network in one strip under them, then
// anything waiting — unapplied changes, a system change to review or
// restart into, backups that are not set up, the read-only system check's
// findings — then the settings changed recently, each with Undo, and last
// what About held: shell health, the Welcome guide, the settings file and
// Reset all. Every row reads as label, value and action on the page's one
// control edge, as everywhere else in Settings.
SettingsPage {
    id: page
    objectName: "settingsHomePage"

    property string releaseVersion: ""
    property double nowMs: Date.now()

    // The shell's own status colours: green healthy, amber running with a
    // problem, red not running. The accent is a mark, not a verdict.
    readonly property color healthColor: !ShellHealth.serviceActive ? Theme.red
        : !ShellHealth.healthy || ShellHealth.issueCount > 0 ? Theme.amber
        : Theme.connected

    readonly property string versionLine: [
        page.releaseVersion !== "" ? "Cybex OS " + page.releaseVersion : "Cybex OS",
        [SysInfo.osName, SysInfo.osVersion].filter(Boolean).join(" ")
    ].filter(Boolean).join(" · ")
    readonly property string hardwareLine: {
        const vendor = SysInfo.deviceVendor, model = SysInfo.deviceModel;
        const device = model.toLowerCase().startsWith(vendor.toLowerCase()) ? model
            : [vendor, model].filter(Boolean).join(" ");
        const cpu = SysInfo.cpuModel.replace(/\((R|TM|tm|r)\)/g, "").replace(/\s+CPU\b.*$/, "")
            .replace(/\s+\d+-Core Processor$/, "").replace(/\s+/g, " ").trim();
        const memory = SysInfo.memTotalBytes > 0
            ? Math.round(SysInfo.memTotalBytes / 1073741824) + " GB" : "";
        return [device, cpu, memory].filter(Boolean).join(" · ");
    }

    // One short line for the update state, most urgent first.
    readonly property string updateLabel: Updates.rebootRecommended ? I18n.tr("Restart to finish")
        : Updates.ready ? (Updates.deployment.changeKind === "update" ? I18n.tr("Update ready to install")
            : I18n.tr("System change ready"))
        : Updates.runActive ? I18n.tr("Preparing…")
        : Updates.hasUpdates ? I18n.tr("Updates available")
        : Updates.sourcesLoaded ? I18n.tr("Up to date")
        : I18n.tr("Not checked yet")
    readonly property color updateColor: Updates.rebootRecommended || Updates.ready || Updates.hasUpdates
        ? Theme.accent : Updates.sourcesLoaded ? Theme.connected : Theme.textFaint

    // What Home lists under "Needs attention", most urgent first. Each entry
    // carries its words and the one action that settles it.
    readonly property var attention: {
        const list = [];
        const changes = SettingsChanges.count;
        if (SettingsChanges.deploymentState === "restart")
            list.push({ id: "restart", tone: "accent", title: I18n.tr("Restart to finish the system change"),
                detail: I18n.tr("It is built and checked. The previous system stays as a recovery point."),
                action: I18n.tr("Software Update…") });
        else if (SettingsChanges.deploymentState === "review")
            list.push({ id: "review", tone: "accent", title: I18n.tr("A system change is ready to review"),
                detail: I18n.tr("Review it in Software Update, then restart to use it."),
                action: I18n.tr("Review…") });
        else if (SettingsChanges.deploymentState === "preparing")
            list.push({ id: "preparing", tone: "amber", title: I18n.tr("Preparing a system change"),
                detail: Updates.runPhaseLabel || I18n.tr("You can keep working or close Settings."), action: "" });
        if (changes > 0)
            list.push({ id: "changes", tone: "accent",
                title: changes === 1 ? I18n.tr("1 change waiting to be applied")
                    : I18n.format("%1 changes waiting to be applied", [changes]),
                detail: SettingsChanges.pages.map(id => Settings.pageInfo(id).label).join(", "),
                action: I18n.tr("Review…") });
        if (Backup.status.valid && !Backup.configured)
            list.push({ id: "backup", tone: "amber", title: I18n.tr("Personal files aren’t backed up"),
                detail: I18n.tr("Back up to a drive or an SSH server, protected by a recovery key."),
                action: I18n.tr("Set up…") });
        for (const check of Doctor.attention)
            list.push({ id: "check:" + check.id, tone: check.state === "problem" ? "red" : "amber",
                title: Doctor.sentence(check), detail: I18n.tr("Found by the system check"),
                action: page.checkAction(check.id) });
        return list;
    }

    function toneColor(tone) {
        return tone === "red" ? Theme.red : tone === "amber" ? Theme.amber : Theme.accent;
    }

    function checkAction(id) {
        switch (id) {
        case "firmware-updates": return I18n.tr("Software Update…");
        case "storage": return I18n.tr("Disk space…");
        case "battery": return I18n.tr("Power…");
        case "audio": return I18n.tr("Sound…");
        case "time": return I18n.tr("Region…");
        }
        return Assistant.connected ? I18n.tr("Ask the assistant") : "";
    }

    function show(target, tab, key) {
        if (tab)
            Settings.setTab(target, tab);
        Settings.page = target;
        if (key) {
            Settings.highlightKey = "";
            Settings.highlightKey = key;
        }
    }

    function act(item) {
        switch (item.id) {
        case "restart":
        case "review":
            Updates.show();
            return;
        case "changes":
            SettingsChanges.reviewRequested();
            return;
        case "backup":
            page.show("backup", "backups");
            return;
        case "check:firmware-updates":
            Updates.show();
            return;
        case "check:storage":
            page.show("backup", "storage");
            return;
        case "check:battery":
            page.show("power");
            return;
        case "check:audio":
            page.show("sound");
            return;
        case "check:time":
            page.show("region");
            return;
        }
        if (item.id.startsWith("check:") && Assistant.connected)
            Assistant.checkSystem();
    }

    function openConfig() {
        Settings.saveNow();
        Qt.callLater(() => {
            Settings.closePanel();
            Quickshell.execDetached(["xdg-open", Settings.filePath]);
        });
    }

    Claim {
        active: page.visible && Settings.panelOpen
        onClaimed: SysInfo.acquire()
        onReleased: SysInfo.release()
    }
    Binding {
        target: Backup
        property: "watched"
        value: page.visible && Settings.panelOpen
    }
    // The page loads asynchronously, often already visible, so a visibility
    // edge alone would leave the first open showing a stale probe.
    Component.onCompleted: {
        ShellHealth.refresh();
        Doctor.refreshIfStale();
        Backup.refresh();
    }
    onVisibleChanged: {
        if (visible) {
            ShellHealth.refresh();
            Doctor.refreshIfStale();
        }
    }
    Timer {
        interval: 60000
        running: page.visible
        repeat: true
        onTriggered: page.nowMs = Date.now()
    }
    FileView {
        path: "/etc/cybexos/release.json"
        printErrors: false
        blockLoading: true
        onLoaded: {
            try {
                page.releaseVersion = String(JSON.parse(text()).version || "");
            } catch (error) {
                page.releaseVersion = "";
            }
        }
    }

    // One cell of the glance strip: a caption, a reading, a quieter line and,
    // for storage, a meter. A cell with a page to go to is a button.
    component GlanceCell: Item {
        id: cell
        property string caption: ""
        property string value: ""
        property string detail: ""
        property real meter: -1
        property bool warn: false
        property bool interactive: true
        signal activated()

        height: cellColumn.implicitHeight + Theme.scaled(24)
        activeFocusOnTab: interactive
        Accessible.role: interactive ? Accessible.Button : Accessible.StaticText
        Accessible.name: cell.caption + ", " + cell.value + (cell.detail !== "" ? ", " + cell.detail : "")
        Accessible.onPressAction: cell.activated()
        Keys.onPressed: event => {
            if (cell.interactive && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                    || event.key === Qt.Key_Space)) {
                cell.activated();
                event.accepted = true;
            }
        }

        StateLayer {
            anchors.fill: parent
            visible: cell.interactive
            hovered: cellMouse.containsMouse
            pressed: cellMouse.pressed
            focused: cell.activeFocus
            tint: Theme.textHi
            pressPoint: Qt.point(cellMouse.mouseX, cellMouse.mouseY)
        }

        Column {
            id: cellColumn
            x: Theme.settingsMarkInset
            y: Theme.scaled(12)
            width: parent.width - x - Theme.scaled(10)
            spacing: Theme.scaled(4)

            Text {
                width: parent.width
                text: cell.caption.toUpperCase()
                elide: Text.ElideRight
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.metadata
                font.weight: Theme.weightSemibold
                font.letterSpacing: 1
                color: Theme.textFaint
            }
            Text {
                width: parent.width
                text: cell.value
                elide: Text.ElideRight
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.title
                font.weight: Theme.weightSemibold
                color: cell.warn ? Theme.amber : Theme.textHi
            }
            Rectangle {
                visible: cell.meter >= 0
                width: parent.width
                height: Theme.scaled(4)
                radius: height / 2
                color: Theme.chipHover
                Rectangle {
                    width: parent.width * Format.clamp01(cell.meter)
                    height: parent.height
                    radius: parent.radius
                    color: cell.meter > 0.9 ? Theme.amber : Theme.textMid
                }
            }
            Text {
                width: parent.width
                visible: text !== ""
                text: cell.detail
                elide: Text.ElideRight
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.metadata
                color: Theme.textFaint
            }
        }

        MouseArea {
            id: cellMouse
            anchors.fill: parent
            enabled: cell.interactive
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: cell.activated()
        }
    }

    Column {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Theme.settingsGroupSpacing

        Column {
            width: parent.width
            spacing: Theme.scaled(18)

            Item {
                id: hero
                width: parent.width
                height: Math.max(logo.height, heroText.implicitHeight, heroSide.implicitHeight)

                // The mark is drawn for charcoal, so it keeps its own tile in
                // a light theme too, as an application icon does.
                Rectangle {
                    id: logo
                    x: Theme.settingsMarkInset
                    anchors.verticalCenter: parent.verticalCenter
                    width: Theme.scaled(50)
                    height: width
                    radius: Theme.scaled(12)
                    color: Theme.darkBackground
                    border.width: Theme.dark ? 1 : 0
                    border.color: Theme.hairlineSoft
                    BrandIcon {
                        anchors.centerIn: parent
                        width: parent.width * 0.74
                        height: width
                        name: "cybexos"
                    }
                }
                Column {
                    id: heroText
                    anchors.left: logo.right
                    anchors.leftMargin: Theme.scaled(16)
                    anchors.right: heroSide.left
                    anchors.rightMargin: Theme.controlSpacing
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.scaled(2)

                    Text {
                        width: parent.width
                        text: SysInfo.host !== "" ? SysInfo.host : I18n.tr("This computer")
                        elide: Text.ElideRight
                        font.family: Theme.fontMenu
                        font.pixelSize: Theme.typography.heading
                        font.weight: Theme.weightSemibold
                        color: Theme.textHi
                    }
                    Text {
                        width: parent.width
                        text: page.versionLine
                        elide: Text.ElideRight
                        font.family: Theme.fontMenu
                        font.pixelSize: Theme.typography.secondary
                        color: Theme.textFaint
                    }
                    Text {
                        width: parent.width
                        visible: text !== ""
                        text: page.hardwareLine
                        elide: Text.ElideRight
                        font.family: Theme.fontMenu
                        font.pixelSize: Theme.typography.secondary
                        color: Theme.textFaint
                    }
                }
                Column {
                    id: heroSide
                    anchors.right: parent.right
                    anchors.rightMargin: Theme.chipHeight
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.scaled(8)

                    Row {
                        anchors.right: parent.right
                        spacing: Theme.scaled(7)
                        Rectangle {
                            anchors.verticalCenter: parent.verticalCenter
                            width: 7; height: 7; radius: 3.5
                            color: page.updateColor
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: page.updateLabel
                            font.family: Theme.fontMenu
                            font.pixelSize: Theme.typography.secondary
                            color: Theme.textMid
                        }
                    }
                    SettingsAction {
                        anchors.right: parent.right
                        text: I18n.tr("Software Update…")
                        onTriggered: Updates.show()
                    }
                }
            }

            // The glance strip: four readings between two hairlines, each a
            // way into the page that holds it.
            Item {
                width: parent.width
                height: glance.height + 2

                Rectangle { width: parent.width; height: 1; color: Theme.hairlineSoft }
                Rectangle { y: parent.height - 1; width: parent.width; height: 1; color: Theme.hairlineSoft }

                Row {
                    id: glance
                    y: 1
                    width: parent.width
                    readonly property real cellWidth: (width - 3) / 4

                    GlanceCell {
                        width: glance.cellWidth
                        caption: I18n.tr("Storage")
                        value: SysInfo.rootFsKnown
                            ? BackupHelpers.formatBytes(SysInfo.rootFsAvailableBytes) + " " + I18n.tr("free") : "—"
                        meter: SysInfo.rootFsKnown ? SysInfo.rootFsUsage / 100 : -1
                        warn: SysInfo.rootFsKnown && SysInfo.rootFsUsage > 90
                        detail: SysInfo.rootFsKnown ? I18n.tr("of ") + BackupHelpers.formatBytes(SysInfo.rootFsTotalBytes) : ""
                        onActivated: page.show("backup", "storage")
                    }
                    Rectangle { width: 1; height: glance.height; color: Theme.hairlineSoft }
                    GlanceCell {
                        width: glance.cellWidth
                        caption: Battery.isLaptop ? I18n.tr("Battery") : I18n.tr("Memory")
                        value: Battery.isLaptop ? Math.round(Battery.percent) + " %"
                            : SysInfo.memTotalBytes > 0 ? Math.round(SysInfo.memTotalBytes / 1073741824) + " GB" : "—"
                        detail: Battery.isLaptop ? Battery.statusText
                            : SysInfo.memKnown ? Math.round(SysInfo.memUsage) + I18n.tr(" % in use") : ""
                        warn: Battery.isLaptop && Battery.percent < 15 && !Battery.pluggedIn
                        interactive: Battery.isLaptop
                        onActivated: page.show("power")
                    }
                    Rectangle { width: 1; height: glance.height; color: Theme.hairlineSoft }
                    GlanceCell {
                        width: glance.cellWidth
                        caption: I18n.tr("Backups")
                        value: !Backup.status.valid ? "—"
                            : !Backup.configured ? I18n.tr("Not set up")
                            : Backup.running ? I18n.tr("Backing up…")
                            : Backup.status.lastSuccess !== ""
                            ? LocalTime.fromText(Backup.status.lastSuccess, page.nowMs, Settings.clock24, I18n.tr("Done"))
                            : I18n.tr("None yet")
                        warn: Backup.status.valid && (!Backup.configured || Backup.status.stale)
                        detail: Backup.configured ? Backup.status.destination.display : I18n.tr("Personal files")
                        onActivated: page.show("backup", "backups")
                    }
                    Rectangle { width: 1; height: glance.height; color: Theme.hairlineSoft }
                    GlanceCell {
                        width: glance.cellWidth
                        caption: I18n.tr("Network")
                        value: WifiState.connected ? WifiState.name
                            : NetworkStatus.online ? I18n.tr("Online") : I18n.tr("Offline")
                        warn: NetworkStatus.known && !NetworkStatus.online
                        detail: WifiState.connected ? "Wi-Fi · " + WifiState.signal + " %"
                            : NetworkStatus.online ? I18n.tr("Wired") : ""
                        onActivated: page.show("network")
                    }
                }
            }
        }

        SettingsGroup {
            width: parent.width
            title: I18n.tr("Needs attention")

            Repeater {
                model: page.attention
                delegate: ValueRow {
                    id: attentionRow
                    required property var modelData
                    width: parent.width
                    label: modelData.title
                    hint: modelData.detail
                    dotColor: page.toneColor(modelData.tone)
                    SettingsAction {
                        visible: attentionRow.modelData.action !== ""
                        text: attentionRow.modelData.action
                        primary: attentionRow.modelData.id === "changes" || attentionRow.modelData.id === "restart"
                        onTriggered: page.act(attentionRow.modelData)
                    }
                }
            }
            ValueRow {
                width: parent.width
                property string searchAnchor: "home-checks"
                label: I18n.tr("System check")
                value: Doctor.running ? I18n.tr("Checking this computer…")
                    : Doctor.report === null ? (Doctor.error || I18n.tr("Not checked yet"))
                    : Doctor.attention.length === 0 ? I18n.tr("Everything looks good")
                    : Doctor.attention.length === 1 ? I18n.tr("1 thing to look at")
                    : I18n.format("%1 things to look at", [Doctor.attention.length])
                hint: Doctor.report !== null
                    ? I18n.tr("Read-only; nothing leaves this computer. Checked ")
                        + LocalTime.fromText(Doctor.report.checkedAt, page.nowMs, Settings.clock24, "")
                    : I18n.tr("Read-only; nothing leaves this computer.")
                dotColor: Doctor.report === null ? Theme.textFaint
                    : Doctor.attention.length > 0 ? Theme.amber : Theme.ok
                SettingsAction {
                    text: Doctor.running ? I18n.tr("Checking") : I18n.tr("Check again")
                    glyph: "refresh"
                    enabled: !Doctor.running
                    onTriggered: Doctor.refresh()
                }
            }
        }

        SettingsGroup {
            width: parent.width
            visible: SettingsRecent.rows.length > 0
            title: I18n.tr("Recently changed")

            Repeater {
                model: SettingsRecent.rows.slice(0, 5)
                delegate: ValueRow {
                    id: recentRow
                    required property var modelData
                    width: parent.width
                    label: modelData.label
                    value: modelData.values ? modelData.before + " → " + modelData.after : ""
                    hint: modelData.pageLabel + " · " + modelData.when
                    SettingsAction {
                        text: I18n.tr("Show")
                        Accessible.name: I18n.tr("Show ") + recentRow.modelData.label
                        onTriggered: {
                            if (recentRow.modelData.widget !== "")
                                Settings.openWidgetSettings(recentRow.modelData.widget);
                            page.show(recentRow.modelData.page, recentRow.modelData.tab, recentRow.modelData.anchor);
                        }
                    }
                    SettingsAction {
                        text: I18n.tr("Undo")
                        glyph: "undo"
                        Accessible.name: I18n.tr("Undo ") + recentRow.modelData.label
                        onTriggered: SettingsRecent.undo(recentRow.modelData)
                    }
                }
            }
        }

        SettingsGroup {
            width: parent.width
            title: I18n.tr("About this computer")

            ValueRow {
                width: parent.width
                label: I18n.tr("Desktop shell")
                dotColor: page.healthColor
                value: ShellHealth.busy ? I18n.tr("Checking…") : ShellHealth.statusLabel
                hint: ShellHealth.issueCount > 0
                    ? (ShellHealth.integrationIssues.concat(ShellHealth.recentWarnings))[0] || ""
                    : ShellHealth.serviceActive
                    ? "PID " + ShellHealth.servicePid + " · " + I18n.tr("up ") + ShellHealth.uptimeLabel()
                        + (ShellHealth.deploymentId !== ""
                            ? " · " + I18n.tr("deployment ") + ShellHealth.deploymentId.slice(0, 10) + " " + ShellHealth.deploymentStatus : "")
                        + (ShellHealth.deploymentCheckedAt
                            ? " · " + I18n.tr("checked ") + LocalTime.fromText(ShellHealth.deploymentCheckedAt,
                                page.nowMs, Settings.clock24, ShellHealth.deploymentCheckedAt) : "")
                    : (ShellHealth.refreshError || I18n.tr("Inactive"))
                hintTone: ShellHealth.issueCount > 0 ? "warning" : "info"
                SettingsAction {
                    text: ShellHealth.busy ? I18n.tr("Checking") : I18n.tr("Refresh")
                    glyph: "refresh"
                    Accessible.name: I18n.tr("Refresh shell health")
                    onTriggered: ShellHealth.refresh()
                }
            }
            ValueRow {
                width: parent.width
                label: I18n.tr("Welcome guide")
                hint: I18n.tr("Make yourself at home. Continue where you left off.")
                SettingsAction {
                    text: I18n.tr("Open")
                    Accessible.name: I18n.tr("Open the welcome guide")
                    onTriggered: Welcome.show("")
                }
            }
            ValueRow {
                width: parent.width
                label: I18n.tr("Settings file")
                hint: "~/.config/cybexos/shell.json"
                SettingsAction {
                    text: I18n.tr("Open")
                    glyph: "open_in_new"
                    Accessible.name: I18n.tr("Open the settings file")
                    onTriggered: page.openConfig()
                }
            }
        }

        // Reset all gets a group of its own rather than a place under Open,
        // where a slip lands on it; the header's Undo still covers it.
        SettingsGroup {
            width: parent.width
            title: I18n.tr("Reset")

            ValueRow {
                width: parent.width
                label: I18n.tr("Reset all settings")
                hint: I18n.tr("Every page back to its defaults. You can undo for 8 seconds.")
                SettingsAction {
                    text: I18n.tr("Reset all")
                    glyph: "restart_alt"
                    danger: true
                    onTriggered: Settings.resetAll()
                }
            }
        }
    }
}
