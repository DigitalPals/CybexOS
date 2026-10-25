pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Window
import "../Common"
import "../Common/WelcomeHelpers.js" as Helpers
import "../Settings" as SettingsUi
Rectangle {
    id: root
    property bool peeking: false
    // Small windows and large text give the step rail's room to the step:
    // the eyebrow still names the step, and Back/Continue and
    // Ctrl+PageUp/PageDown still move between steps. A short window also
    // drops the lead line and tightens the margins, so the step itself keeps
    // the space. Nothing is clipped: a step taller than its viewport scrolls.
    readonly property bool railShown: width - Theme.scaled(176) - Theme.scaled(64) >= Theme.scaled(560)
        && rail.stepsHeight <= rail.height
    readonly property bool shortHeight: main.height < Theme.scaled(520)
    readonly property int stepIndex: Helpers.STEPS.indexOf(Welcome.step)
    readonly property var titles: [I18n.format("Welcome, %1", [Welcome.firstName]), I18n.tr("Find your view."),
        I18n.tr("Make it feel like home."), I18n.tr("A little practice goes a long way."),
        I18n.tr("Your keyboard has superpowers."), I18n.tr("You are all set.")]
    readonly property var leads: [I18n.tr("Let’s make Cybex OS yours. Start with what is already in place."),
        I18n.tr("Pick something you love looking at. Hold Space to peek at your desktop."),
        I18n.tr("Choose your colours and comfort. This is your desktop, live."),
        I18n.tr("Try five small moves. We will notice each one as you do it."),
        I18n.tr("A few familiar shortcuts, and room to make your own."),
        I18n.tr("The essentials are ready. The rest can happen whenever you like.")]
    readonly property var labels: [I18n.tr("Hello"), I18n.tr("Wallpaper"), I18n.tr("Style"), I18n.tr("Practice"), I18n.tr("Shortcuts")]
    readonly property var optionalLabels: ({webapps: I18n.tr("Web apps"), assistant: I18n.tr("AI assistant"),
        fingerprint: I18n.tr("Fingerprint"), security: I18n.tr("Security keys"), backup: I18n.tr("Backups"), accounts: I18n.tr("Online accounts")})
    color: Theme.panelSurface
    radius: Theme.panelRadius
    border.width: Settings.highContrast ? 2 : 1
    border.color: Theme.stroke
    focus: true
    opacity: peeking ? 0 : 1
    Behavior on opacity { NumberAnimation { duration: Theme.popoutContentFadeDuration } }
    function focusInitial() { root.forceActiveFocus(); }
    Keys.onPressed: event => {
        if (event.key === Qt.Key_Escape) {
            peeking = false; Welcome.dismiss(); event.accepted = true;
        } else if (event.modifiers & Qt.ControlModifier) {
            if (event.key === Qt.Key_PageDown || event.key === Qt.Key_PageUp) {
                Welcome.move(event.key === Qt.Key_PageDown ? 1 : -1); event.accepted = true;
            }
        } else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) {
            if (Welcome.step === "finish") Welcome.finish(); else Welcome.move(1);
            event.accepted = true;
        }
    }
    // Holding Space peeks from anywhere on the wallpaper step, also with a
    // thumbnail or button focused (Enter activates those), except in a text
    // field such as Wallhaven search, where Space types. Qt Wayland repeats a
    // held key as release/press pairs: the non-repeating shortcut swallows
    // the repeated presses, and only the physical release ends the peek.
    readonly property Item focusedItem: root.Window.window ? root.Window.window.activeFocusItem : null
    readonly property bool typing: focusedItem instanceof TextInput || focusedItem instanceof TextEdit
    Keys.onReleased: event => {
        if (event.key === Qt.Key_Space && !event.isAutoRepeat && peeking) { peeking = false; event.accepted = true; }
    }
    Shortcut {
        sequence: "Space"; context: Qt.WindowShortcut; autoRepeat: false
        enabled: Welcome.open && Welcome.step === "wallpaper" && !root.typing
        onActivated: root.peeking = true
    }
    Connections {
        target: root.Window.window
        function onActiveChanged() { if (!root.Window.window.active) root.peeking = false; }
    }
    Connections {
        target: Welcome
        function onStepChanged() {
            root.peeking = false;
            scroller.contentY = 0;
            Qt.callLater(root.focusInitial);
            transition.restart();
        }
        function onOpenChanged() { root.peeking = false; }
    }
    Rectangle {
        id: rail
        anchors.left: parent.left; anchors.top: parent.top; anchors.bottom: footer.top
        anchors.margins: 1
        width: Theme.scaled(176); radius: Theme.panelRadius
        color: Theme.cardFill
        visible: root.railShown
        readonly property real stepsHeight: Theme.scaled(16) * 2 + brand.height + railColumn.spacing + stepList.height
        Column {
            id: railColumn
            anchors.fill: parent; anchors.margins: Theme.scaled(16); spacing: Theme.scaled(22)
            Row {
                id: brand
                spacing: Theme.controlSpacing
                Image { width: Theme.scaled(28); height: width; source: "../assets/cybexos.svg"; fillMode: Image.PreserveAspectFit }
                GuideText { anchors.verticalCenter: parent.verticalCenter; text: "Cybex OS"; font.weight: Theme.weightSemibold } // i18n: untranslated (brand)
            }
            Column {
                id: stepList
                width: parent.width; spacing: Theme.controlSpacing
                Repeater {
                    model: root.labels
                    delegate: Rectangle {
                        id: stepButton
                        required property int index
                        required property string modelData
                        readonly property bool current: root.stepIndex === index
                        readonly property bool done: !current && Welcome.document.seen.includes(Helpers.STEPS[index])
                        width: parent.width; height: Theme.scaled(44); radius: Theme.chipRadius
                        color: current ? Theme.accentBg : activeFocus ? Theme.hoverFill : "transparent"
                        border.width: activeFocus ? 1 : 0; border.color: Theme.accentText
                        activeFocusOnTab: true
                        Accessible.role: Accessible.Button
                        Accessible.name: I18n.format("Step %1: %2", [index + 1, modelData])
                        Accessible.selected: current
                        Accessible.onPressAction: Welcome.go(Helpers.STEPS[index])
                        Keys.onPressed: event => {
                            if ([Qt.Key_Return, Qt.Key_Enter, Qt.Key_Space].includes(event.key)) {
                                Welcome.go(Helpers.STEPS[index]); event.accepted = true;
                            }
                        }
                        Row {
                            anchors.verticalCenter: parent.verticalCenter; x: Theme.controlSpacing; spacing: Theme.controlSpacing
                            Rectangle {
                                width: Theme.scaled(24); height: width; radius: width / 2
                                color: stepButton.current ? Theme.accent : "transparent"
                                border.width: stepButton.current || stepButton.done ? 0 : 1; border.color: Theme.stroke
                                GuideText { anchors.centerIn: parent; text: String(stepButton.index + 1); visible: !stepButton.done; font.pixelSize: Theme.typography.secondary; color: stepButton.current ? Theme.textOnAccent : Theme.textMid }
                                Sym { anchors.centerIn: parent; visible: stepButton.done; name: "check"; size: Theme.iconMedium; color: Theme.connected }
                            }
                            GuideText { anchors.verticalCenter: parent.verticalCenter; text: stepButton.modelData; font.pixelSize: Theme.typography.secondary; color: stepButton.current ? Theme.accentText : Theme.textMid }
                        }
                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: Welcome.go(Helpers.STEPS[stepButton.index]) }
                    }
                }
            }
            Column {
                id: optionalList
                width: parent.width; spacing: Theme.controlSpacing
                // The same items stay on the finish step when the rail is short.
                visible: rail.stepsHeight + railColumn.spacing + implicitHeight
                    + footnote.implicitHeight + Theme.scaled(16) <= rail.height
                GuideText { width: parent.width; leftPadding: Theme.controlSpacing; text: I18n.tr("Optional · any time").toUpperCase(); tone: "muted"; font.pixelSize: Theme.typography.metadata; font.letterSpacing: 0.8 }
                // Rows like the steps above: the same inset and type, with
                // the item's own glyph (a tick once its real state is done)
                // in the step number's column.
                Repeater {
                    model: Welcome.checklist
                    delegate: Rectangle {
                        id: optional
                        required property var modelData
                        readonly property bool done: modelData.done === true
                        readonly property string label: root.optionalLabels[modelData.id] || modelData.id
                        // Denser than the steps: secondary, and the rail is short.
                        width: parent.width; height: Math.max(Theme.settingsControlHeight, optionalText.implicitHeight + Theme.scaled(8))
                        radius: Theme.chipRadius
                        color: activeFocus || optionalMouse.containsMouse ? Theme.hoverFill : "transparent"
                        border.width: activeFocus ? 1 : 0; border.color: Theme.accentText
                        activeFocusOnTab: true
                        Accessible.role: Accessible.Button
                        Accessible.name: optional.done ? I18n.format("%1: %2", [optional.label, I18n.tr("Done")]) : optional.label
                        Accessible.onPressAction: optional.open()
                        function open() {
                            Welcome.go("finish");
                            Qt.callLater(() => {
                                const finish = content.item as FinishStep;
                                if (finish) scroller.contentY = Math.max(0, Math.min(scroller.contentHeight - scroller.height, finish.itemY(optional.modelData.id)));
                            });
                        }
                        Keys.onPressed: event => {
                            if ([Qt.Key_Return, Qt.Key_Enter, Qt.Key_Space].includes(event.key)) {
                                optional.open(); event.accepted = true;
                            }
                        }
                        Row {
                            anchors.verticalCenter: parent.verticalCenter; x: Theme.controlSpacing; spacing: Theme.controlSpacing
                            width: parent.width - x
                            Item {
                                anchors.verticalCenter: parent.verticalCenter
                                width: Theme.scaled(24); height: Theme.iconSmall
                                Sym {
                                    anchors.centerIn: parent
                                    name: optional.done ? "check" : ({webapps: "web", assistant: "assistant", fingerprint: "passkey",
                                        security: "key", backup: "archive", accounts: "account_circle"})[optional.modelData.id] || "circle"
                                    size: Theme.iconSmall
                                    color: optional.done ? Theme.connected : Theme.textFaint
                                }
                            }
                            GuideText {
                                id: optionalText
                                anchors.verticalCenter: parent.verticalCenter
                                width: parent.width - Theme.scaled(24) - parent.spacing
                                text: optional.label; font.pixelSize: Theme.typography.secondary; color: Theme.textMid
                                maximumLineCount: 2; elide: Text.ElideRight
                            }
                        }
                        MouseArea { id: optionalMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: optional.open() }
                    }
                }
            }
        }
        GuideText {
            id: footnote
            anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
            anchors.margins: Theme.scaled(16)
            visible: railColumn.implicitHeight + implicitHeight + Theme.scaled(48) <= rail.height
            text: I18n.tr("About 3 minutes. Everything here is also in Settings.")
            tone: "muted"; font.pixelSize: Theme.typography.metadata
        }
    }
    Item {
        id: main
        anchors.left: root.railShown ? rail.right : parent.left; anchors.right: parent.right
        anchors.top: parent.top; anchors.bottom: footer.top
        anchors.leftMargin: Theme.scaled(root.railShown ? 32 : 24); anchors.rightMargin: Theme.scaled(root.railShown ? 32 : 24)
        anchors.topMargin: Theme.scaled(root.shortHeight ? 16 : 28)
        Column {
            id: heading
            width: parent.width - closeAction.width; spacing: Theme.scaled(10)
            GuideText {
                width: parent.width
                text: root.stepIndex < 5 ? I18n.format("Step %1 of 5 · Make it yours", [root.stepIndex + 1]).toUpperCase() : I18n.tr("Ready when you are").toUpperCase()
                tone: "accent"; font.pixelSize: Theme.typography.metadata; font.weight: Theme.weightSemibold; font.letterSpacing: 1
            }
            GuideText { width: parent.width; text: root.titles[root.stepIndex]; font.pixelSize: Theme.typography.display; font.weight: Theme.weightSemibold }
            GuideText { width: parent.width; text: root.leads[root.stepIndex]; tone: "muted"; visible: !root.shortHeight }
        }
        SettingsUi.SettingsAction {
            id: closeAction
            anchors.right: parent.right; anchors.top: parent.top
            text: I18n.tr("Close welcome guide"); compact: true; glyph: "close"
            onTriggered: Welcome.dismiss()
        }
        Flickable {
            id: scroller
            anchors.top: heading.bottom; anchors.topMargin: Theme.scaled(root.shortHeight ? 12 : 24)
            anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
            anchors.bottomMargin: Theme.scaled(root.shortHeight ? 8 : 20)
            clip: true; contentHeight: content.height
            boundsBehavior: Flickable.StopAtBounds
            Loader {
                id: content
                width: scroller.width
                readonly property Item stepItem: item as Item
                height: !stepItem ? 0 : Welcome.step === "wallpaper"
                    ? Math.max(scroller.height, stepItem.implicitHeight) : stepItem.implicitHeight
                source: ({hello: "HelloStep.qml", wallpaper: "WallpaperStep.qml", style: "StyleStep.qml",
                    keys: "KeysStep.qml", shortcuts: "ShortcutsStep.qml", finish: "FinishStep.qml"})[Welcome.step]
            }
            NumberAnimation { id: transition; target: content; property: "opacity"; from: 0; to: 1; duration: Theme.popoutContentFadeDuration }

        }
        ScrollChrome { anchors.fill: scroller; target: scroller }
    }
    // Tab focus scrolls with the control, including controls inside the
    // embedded Settings rows. Focus never lands behind a clipped viewport.
    Connections {
        target: root.Window.window
        function onActiveFocusItemChanged() {
            const focused = root.Window.window ? root.Window.window.activeFocusItem : null;
            if (!focused || !content.stepItem) return;
            let ancestor = focused;
            while (ancestor && ancestor !== content.stepItem) ancestor = ancestor.parent;
            if (!ancestor) return;
            const point = focused.mapToItem(scroller.contentItem, 0, 0);
            const maxY = Math.max(0, scroller.contentHeight - scroller.height);
            if (point.y < scroller.contentY) scroller.contentY = Math.max(0, point.y);
            else if (point.y + focused.height > scroller.contentY + scroller.height)
                scroller.contentY = Math.min(maxY, point.y + focused.height - scroller.height);
        }
    }
    Rectangle {
        id: footer
        anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
        height: Theme.scaled(76); color: "transparent"
        Rectangle { width: parent.width; height: 1; color: Theme.stroke }
        SettingsUi.SettingsAction { id: skip; x: Theme.scaled(24); anchors.verticalCenter: parent.verticalCenter; text: I18n.tr("Skip for now"); onTriggered: Welcome.dismiss() }
        GuideText {
            // Aligned with the step's column, never under Skip or the actions.
            x: Math.max(skip.x + skip.width + Theme.scaled(16), root.railShown ? rail.width + Theme.scaled(32) : 0)
            width: Math.max(0, actions.x - Theme.scaled(12) - x)
            anchors.verticalCenter: parent.verticalCenter
            visible: width >= Theme.scaled(64)
            wrapMode: Text.WordWrap; maximumLineCount: 2; elide: Text.ElideRight
            text: Welcome.error !== "" ? Welcome.error : Welcome.step === "wallpaper" ? I18n.tr("Hold Space to peek") : ""
            tone: "muted"; font.pixelSize: Theme.typography.secondary
        }
        Row {
            id: actions
            anchors.right: parent.right; anchors.rightMargin: Theme.scaled(24); anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.controlSpacing
            SettingsUi.SettingsAction { text: I18n.tr("Back"); enabled: root.stepIndex > 0; onTriggered: Welcome.move(-1) }
            SettingsUi.SettingsAction { text: Welcome.step === "finish" ? I18n.tr("Finish") : I18n.tr("Continue"); primary: true; onTriggered: { if (Welcome.step === "finish") Welcome.finish(); else Welcome.move(1); } }
        }
    }
}
