pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Window
import Quickshell
import Quickshell.Wayland
import "../Common"
import "../Common/KeybindEditor.js" as Editor
import "../Common/ShortcutEditor.js" as Helpers

// The shortcut recorder: a modal card over its host window. While it
// listens, a ShortcutInhibitor asks the compositor to pass bound keys
// through, so Super+L is recorded instead of locking the screen. Listening
// stops — and the inhibitor is released — when a combination is complete,
// on cancel, on accept, when the window loses focus or is hidden, and when
// the recorder is destroyed.
//
// The host calls start(); `accepted(combo, mode)` follows once a
// combination is chosen. Conflicts are checked against Keybindings: a
// protected action's reserved default, user.lua or a non-editable holder (a
// hidden hardware key) blocks the key, any other holder is offered as
// "Replace", which unbinds that key from it in the draft first. A holder that only might share the physical key (`uncertain`) is a
// warning: "Use anyway" keeps it bound.
//
// A protected action's reserved defaults (`lockedKeys`) always stay bound.
// They show as locked caps, and "Replace" replaces only the keys beyond them.
FocusScope {
    id: root

    property string actionId: ""
    property string actionLabel: ""
    property var currentKeys: []
    property var lockedKeys: []
    readonly property var extraKeys: currentKeys.filter(key => !lockedKeys.some(other => Editor.same(key, other)))
    property bool allowAdd: true
    property string mode: "replace"
    property bool shown: false
    property bool listening: false
    property bool paused: false
    property string combo: ""
    property bool complete: false
    property string reserved: ""
    property var verdict: ({ kind: "", reason: "", blockers: [], replace: [], maybe: [] })
    readonly property bool inhibiting: inhibitor.active
    readonly property bool inhibitorEnabled: inhibitor.enabled
    signal accepted(string combo, string mode)
    signal canceled()

    function start(id, label, keys, add, locked) {
        actionId = id || "";
        actionLabel = label || "";
        currentKeys = keys || [];
        lockedKeys = locked || [];
        allowAdd = add !== false && extraKeys.length > 0 && extraKeys.length < 4;
        mode = "replace";
        shown = true;
        listen();
    }
    function listen() {
        // Focus first: Record again hides itself once the state resets.
        if (shown) {
            capture.forceActiveFocus();
            Qt.callLater(() => reveal(capture));
        }
        combo = "";
        complete = false;
        reserved = "";
        paused = false;
        verdict = { kind: "", reason: "", blockers: [], replace: [], maybe: [] };
        listening = true;
    }
    function stop() { listening = false; }
    // Scrolls a part of the card into view when the card has to scroll.
    function reveal(item) {
        if (!item || !cardScroll.interactive)
            return;
        const top = item.mapToItem(cardScroll.contentItem, 0, 0).y;
        const limit = cardScroll.contentHeight - cardScroll.height;
        if (top < cardScroll.contentY)
            cardScroll.contentY = Math.max(0, top - Theme.panelPadding);
        else if (top + item.height > cardScroll.contentY + cardScroll.height)
            cardScroll.contentY = Math.min(limit, top + item.height + Theme.panelPadding - cardScroll.height);
    }
    // Focus leaves the buttons before the card hides: a focused item's
    // activeFocusOnTab cannot follow its visibility to false.
    function hide() {
        // The card has no tab binding; the scope itself would hand focus
        // straight back to the focused button.
        card.forceActiveFocus();
        listening = false;
        shown = false;
    }
    function cancel() {
        if (!shown)
            return;
        hide();
        canceled();
    }
    function finish(value) {
        const decision = Helpers.decide(value, Keybindings.conflicts(value, actionId), id => Keybindings.action(id));
        if (decision.kind === "reserved") {
            // Keep listening: the reason replaces the hint until the next key.
            reserved = decision.reason;
            return;
        }
        listening = false;
        complete = true;
        verdict = decision;
        Qt.callLater(() => {
            const next = decision.kind === "blocked" ? againButton : useButton;
            next.forceActiveFocus();
            reveal(next);
        });
    }
    function accept() {
        if (!complete || verdict.kind === "blocked" || verdict.kind === "")
            return;
        // All the holders lose the key, or none does: a refused step must not
        // leave the draft half changed with the new key unassigned.
        const changes = verdict.replace.filter(other => other.id.indexOf("user.") !== 0)
            .map(other => ({ id: other.id, keys: Helpers.withoutKey(Keybindings.keysFor(other.id), combo) }));
        if (changes.length && !Keybindings.setManyKeys(changes))
            return;
        const chosen = combo;
        hide();
        accepted(chosen, allowAdd ? mode : "replace");
    }
    // Two names at most, then a count: a Shift guess can name ten holders.
    function nameList(names) {
        return names.length > 3 ? I18n.format("%1 and %2 more", [names.slice(0, 2).join(", "), names.length - 2])
            : names.join(", ");
    }
    function owners(list) { return nameList(list.map(row => I18n.actionLabel(row.label))); }
    // "Group: Label" for hardware keys, whose label alone ("Volume up") says little.
    function holders(list) { return nameList(list.map(row => I18n.tr(row.group) + ": " + I18n.actionLabel(row.label))); }
    readonly property string status: {
        if (paused)
            return I18n.tr("Recording paused because the window lost focus. Record again to continue.");
        if (reserved === "modifier")
            return I18n.tr("Add Super, Ctrl or Alt: a key on its own would stop you typing it.");
        if (reserved === "mouse")
            return I18n.tr("Mouse buttons cannot be recorded here.");
        if (reserved === "power")
            return I18n.tr("Power and sleep keys stay with the system.");
        if (reserved !== "")
            return I18n.tr("This combination is kept for system recovery.");
        if (verdict.kind === "blocked" && verdict.reason === "protected")
            return I18n.format("%1 needs this key and it cannot be taken.", [owners(verdict.blockers)]);
        if (verdict.kind === "blocked" && verdict.reason === "hardware")
            return I18n.format("Used by a hardware key (%1). Choose another key.", [holders(verdict.blockers)]);
        if (verdict.kind === "blocked" && verdict.reason === "fixed")
            return I18n.format("%1 cannot be changed. Choose another key.", [owners(verdict.blockers)]);
        if (verdict.kind === "blocked")
            return I18n.format("Your user.lua binds this key to %1. Change it there; user.lua loads last.", [owners(verdict.blockers)]);
        if (verdict.kind === "replace" && verdict.maybe.length)
            return I18n.format("Already used by %1. Replace removes it there. %2 may also use it and keeps its key.",
                [owners(verdict.replace), owners(verdict.maybe)]);
        if (verdict.kind === "replace")
            return I18n.format("Already used by %1. Replace removes it there.", [owners(verdict.replace)]);
        if (verdict.kind === "maybe")
            return I18n.format("May conflict with %1; the keyboard layout is unknown. They keep their keys.",
                [owners(verdict.maybe)]);
        if (verdict.kind === "free")
            return I18n.tr("This combination is free.");
        return "";
    }
    readonly property string statusTone: reserved !== "" || paused ? "warning"
        : verdict.kind === "blocked" ? "error" : verdict.kind === "replace" || verdict.kind === "maybe" ? "warning"
        : verdict.kind === "free" ? "active" : "info"

    // Geometry, not anchors: the welcome guide reparents the recorder to its
    // window's content item from inside a positioner.
    x: 0
    y: 0
    width: parent ? parent.width : 0
    height: parent ? parent.height : 0
    visible: shown
    z: 10
    // Keys that reach the card (from its buttons) never fall through to the
    // page behind it; Escape cancels from anywhere inside.
    Keys.onPressed: event => {
        if (event.key === Qt.Key_Escape)
            root.cancel();
        if (event.key !== Qt.Key_Tab && event.key !== Qt.Key_Backtab)
            event.accepted = true;
    }
    onVisibleChanged: if (!visible) cancel()
    Component.onDestruction: {
        listening = false;
        inhibitor.enabled = false;
    }

    // `enabled` is assigned, not bound: when the compositor cancels an
    // inhibitor, Quickshell writes enabled = false itself, which would
    // silently break a binding for every later recording.
    ShortcutInhibitor {
        id: inhibitor
        window: root.QsWindow.window
        onCancelled: {
            if (root.listening) {
                root.listening = false;
                root.paused = true;
            }
        }
    }
    onListeningChanged: inhibitor.enabled = listening

    // Focus loss ends listening: the compositor stops inhibiting anyway, and
    // keys typed elsewhere must not land here when the window returns.
    Connections {
        target: root.Window.window
        enabled: root.listening
        function onActiveChanged() {
            if (root.Window.window && !root.Window.window.active) {
                root.listening = false;
                root.paused = true;
            }
        }
    }

    Rectangle {
        anchors.fill: parent
        color: Theme.scrim
        // Clicking outside the card cancels, like Escape.
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.AllButtons
            cursorShape: Qt.ArrowCursor
            onClicked: root.cancel()
        }
    }

    Rectangle {
        id: card
        anchors.centerIn: parent
        width: Math.min(Theme.scaled(480, Theme.typeScale), root.width - Theme.panelPadding * 2)
        height: Math.min(body.implicitHeight + Theme.panelPadding * 2, root.height - Theme.scaled(16))
        radius: Theme.popRadius
        color: Theme.surfaceMenu
        border.width: 1
        border.color: Theme.popBorder
        Accessible.role: Accessible.Dialog
        Accessible.name: I18n.format("Change shortcut for %1", [I18n.actionLabel(root.actionLabel)])

        MouseArea { anchors.fill: parent }

        // A host shorter than the card (Settings at its minimum size) scrolls
        // the card rather than cutting off its title and buttons.
        Flickable {
            id: cardScroll
            anchors.fill: parent
            clip: true
            contentHeight: body.implicitHeight + Theme.panelPadding * 2
            interactive: contentHeight > height
            boundsBehavior: Flickable.StopAtBounds
            Column {
                id: body
                x: Theme.panelPadding
                y: Theme.panelPadding
                width: parent.width - Theme.panelPadding * 2
                spacing: Theme.settingsContentSpacing

                Text {
                    width: parent.width
                    text: root.actionId === "" ? I18n.tr("Record a shortcut")
                        : I18n.format("Change shortcut for %1", [I18n.actionLabel(root.actionLabel)])
                    wrapMode: Text.Wrap
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.title
                    font.weight: Theme.weightSemibold
                    color: Theme.textHi
                }
                Row {
                    visible: root.currentKeys.length > 0
                    spacing: Theme.controlSpacing
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: I18n.tr("Now")
                        font.family: Theme.fontMenu
                        font.pixelSize: Theme.typography.secondary
                        color: Theme.textFaint
                    }
                    ShortcutKeycaps { keys: root.currentKeys; lockedKeys: root.lockedKeys }
                }
                Text {
                    width: parent.width
                    visible: root.lockedKeys.length > 0
                    wrapMode: Text.Wrap
                    text: I18n.format("%1 always stays as well: a protected shortcut keeps its default keys.",
                        [root.lockedKeys.map(key => Editor.display(key).join(" + ")).join(", ")])
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.secondary
                    color: Theme.textFaint
                }

                // The capture surface: it holds focus while listening and shows
                // the combination as it is pressed.
                Rectangle {
                    id: capture
                    objectName: "shortcutCapture"
                    width: parent.width
                    height: Theme.settingsControlHeight * 2 + Theme.scaled(24)
                    radius: Theme.chipRadius
                    color: Theme.cardFill
                    border.width: activeFocus || root.listening ? 2 : 1
                    border.color: root.listening ? Theme.accentText : Theme.stroke
                    activeFocusOnTab: root.shown
                    Accessible.role: Accessible.EditableText
                    Accessible.name: I18n.tr("Shortcut keys")
                    Accessible.description: root.listening ? I18n.tr("Press the new keys. Escape cancels, Backspace clears.") : root.status

                    Keys.onPressed: event => {
                        event.accepted = true;
                        if (event.isAutoRepeat)
                            return;
                        const command = Helpers.recorderCommand(event, root.complete);
                        if (command === "cancel") {
                            root.cancel();
                        } else if (command === "clear") {
                            root.listen();
                        } else if (command === "accept") {
                            root.accept();
                        } else if (!root.listening) {
                            // A finished or paused recording starts over on a
                            // new key, so the press is not lost.
                            if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
                                event.accepted = false;
                                return;
                            }
                            root.listen();
                            root.record(event);
                        } else {
                            root.record(event);
                        }
                    }
                    Keys.onReleased: event => {
                        event.accepted = true;
                        if (root.listening && !event.isAutoRepeat)
                            root.combo = Helpers.releaseCombo(event, root.combo);
                    }

                    Column {
                        anchors.centerIn: parent
                        width: parent.width - Theme.controlSpacing * 2
                        spacing: Theme.iconTextSpacing

                        ShortcutKeycaps {
                            anchors.horizontalCenter: parent.horizontalCenter
                            visible: root.combo !== ""
                            large: true
                            caps: root.combo === "" ? [] : [Helpers.liveCaps(root.combo)]
                        }
                        // A lone modifier has no keycap form yet: draw its names.
                        Text {
                            width: parent.width
                            visible: root.combo === ""
                            horizontalAlignment: Text.AlignHCenter
                            wrapMode: Text.Wrap
                            text: root.listening ? I18n.tr("Press the new keys…") : I18n.tr("Press a key to record again")
                            font.family: Theme.fontMenu
                            font.pixelSize: Theme.typography.title
                            color: root.listening ? Theme.textMid : Theme.textFaint
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            capture.forceActiveFocus();
                            if (!root.listening && !root.complete)
                                root.listen();
                        }
                    }
                }

                SettingsHint {
                    width: parent.width
                    inset: false
                    text: root.status !== "" ? root.status
                        : root.listening && root.inhibiting ? I18n.tr("Desktop shortcuts are paused while you record.")
                        : root.listening ? I18n.tr("Some keys may still reach the desktop while you record.") : ""
                    tone: root.status !== "" ? root.statusTone : "info"
                }

                PillRow {
                    visible: root.allowAdd
                    width: Math.min(parent.width, naturalWidth)
                    model: [{ value: "replace", label: root.lockedKeys.length ? I18n.tr("Replace added keys") : I18n.tr("Replace current keys") },
                        { value: "add", label: I18n.tr("Add as another key") }]
                    current: root.mode
                    onPicked: value => root.mode = value
                }

                Text {
                    width: parent.width
                    wrapMode: Text.Wrap
                    text: I18n.tr("Escape cancels · Backspace clears")
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.metadata
                    color: Theme.textFaint
                }

                Row {
                    anchors.right: parent.right
                    spacing: Theme.controlSpacing

                    SettingsAction {
                        text: I18n.tr("Cancel")
                        onTriggered: root.cancel()
                    }
                    SettingsAction {
                        id: againButton
                        visible: root.complete || root.paused
                        text: I18n.tr("Record again")
                        glyph: "refresh"
                        onTriggered: root.listen()
                    }
                    SettingsAction {
                        id: useButton
                        objectName: "shortcutUse"
                        primary: true
                        visible: root.complete && root.verdict.kind !== "blocked"
                        text: root.verdict.kind === "replace" ? I18n.tr("Replace")
                            : root.verdict.kind === "maybe" ? I18n.tr("Use anyway") : I18n.tr("Use shortcut")
                        onTriggered: root.accept()
                    }
                }
            }
        }
    }

    function record(event) {
        // The layout's keymap names Shift combinations as Hyprland binds them.
        const result = Editor.fromKeyEvent({ key: event.key, modifiers: event.modifiers,
            nativeScanCode: event.nativeScanCode, text: event.text }, Keybindings.keymap);
        combo = result.keys;
        reserved = "";
        if (result.complete)
            finish(result.keys);
    }
}
