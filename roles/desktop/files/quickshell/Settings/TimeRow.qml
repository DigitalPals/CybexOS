import QtQuick
import "../Common"
import "../Common/SettingsHelpers.js" as SettingsHelpers

// [label][− HH:MM +][undo]: a clock time stored as minutes since midnight.
// A time is typed or stepped, never dragged — a 24-hour slider made landing
// on 07:30 a matter of pixels. The field takes "7:30", "0730" or "19.45";
// the buttons, arrow keys and the wheel step by `step` minutes, Page Up and
// Page Down by an hour, and the day wraps at midnight.
SettingsRow {
    id: root

    property int minutes: root.stored !== undefined ? root.stored : 0
    property int step: 15
    // The row's own note; a typing error takes its place while it lasts.
    property string note: ""
    signal changed(int minutes)

    readonly property bool inputValid: SettingsHelpers.parseClockMinutes(field.text, root.step) !== -1

    hint: !inputValid && field.activeFocus ? "Enter a time such as 07:30" : note
    hintTone: !inputValid ? "error" : "info"

    function apply(next) {
        const wrapped = ((next % 1440) + 1440) % 1440;
        if (wrapped === root.minutes)
            return;
        root.commit(wrapped);
        root.changed(wrapped);
    }

    function shift(delta) {
        apply(root.minutes + delta);
    }

    onMinutesChanged: {
        if (!field.activeFocus)
            field.text = SettingsHelpers.formatMinutes(root.minutes);
    }

    Row {
        id: stepper
        x: root.narrow ? root.markInset : root.labelWidth
        y: root.narrow ? Theme.settingsStackOffset : (root.lineHeight - height) / 2
        height: Theme.settingsControlHeight
        spacing: 2
        opacity: root.controlOpacity

        SettingsAction {
            anchors.verticalCenter: parent.verticalCenter
            compact: true
            glyph: "remove"
            text: root.label + " " + root.step + " minutes earlier"
            onTriggered: root.shift(-root.step)
        }

        SettingsField {
            id: field
            width: Theme.scaled(64, Theme.typeScale)
            height: Theme.settingsControlHeight
            horizontalAlignment: TextInput.AlignHCenter
            font.family: Theme.fontMono
            inputMethodHints: Qt.ImhTime
            invalid: !root.inputValid
            Accessible.name: root.label
            Accessible.description: "Type a time, or use the arrow keys to step by "
                + root.step + " minutes"
            Component.onCompleted: text = SettingsHelpers.formatMinutes(root.minutes)
            onEditingFinished: {
                const parsed = SettingsHelpers.parseClockMinutes(text, root.step);
                if (parsed !== -1)
                    root.apply(parsed);
                Qt.callLater(() => text = SettingsHelpers.formatMinutes(root.minutes));
            }
            Keys.onPressed: event => {
                const deltas = {};
                deltas[Qt.Key_Up] = root.step;
                deltas[Qt.Key_Down] = -root.step;
                deltas[Qt.Key_PageUp] = 60;
                deltas[Qt.Key_PageDown] = -60;
                if (event.key === Qt.Key_Escape) {
                    text = SettingsHelpers.formatMinutes(root.minutes);
                    focus = false;
                    event.accepted = true;
                } else if (deltas[event.key] !== undefined) {
                    root.shift(deltas[event.key]);
                    text = SettingsHelpers.formatMinutes(root.minutes);
                    selectAll();
                    event.accepted = true;
                }
            }

            WheelHandler {
                // A touchpad reports many small deltas per gesture; step once
                // per wheel notch's worth of travel.
                property real travel: 0
                acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                onWheel: event => {
                    travel += event.angleDelta.y;
                    while (Math.abs(travel) >= 120) {
                        root.shift(travel > 0 ? root.step : -root.step);
                        travel -= travel > 0 ? 120 : -120;
                    }
                    field.text = SettingsHelpers.formatMinutes(root.minutes);
                }
            }
        }

        SettingsAction {
            anchors.verticalCenter: parent.verticalCenter
            compact: true
            glyph: "add"
            text: root.label + " " + root.step + " minutes later"
            onTriggered: root.shift(root.step)
        }
    }
}
