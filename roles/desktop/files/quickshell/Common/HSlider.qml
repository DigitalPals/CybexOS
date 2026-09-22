pragma ComponentBehavior: Bound
import QtQuick
import "Format.js" as Format

// The one slider: 4px track, 10px knob. Continuous while `step` is 0 (the
// media seek bar), stepped otherwise (settings rows, all of which set one).
// `gradientTrack` renders the night-light warmth ramp, `hueTrack` the accent
// wheel, and `colorTrack` a caller-provided three-stop ramp; all omit the
// ordinary progress fill.
//
// Merged from the popover and settings copies for the same reason as
// Common/Toggle.qml: the popover one had no Accessible or Keys handling at
// all, inside a surface that does take keyboard focus.
Item {
    id: root

    property real value: 0
    property real min: 0
    property real max: 1
    property real step: 0
    property bool dimmed: false
    property bool gradientTrack: false
    property bool hueTrack: false
    property bool colorTrack: false
    property color trackStart: "#000000"
    property color trackMiddle: "#808080"
    property color trackEnd: "#ffffff"
    // Recommended values, drawn as ticks under the track. A pointer drag
    // that passes within a step of one settles on it, so a preset is easy
    // to land on without taking over the rest of the range.
    property var marks: []
    property string accessibleName: "Slider"
    signal moved(real value)

    readonly property real ratio: Format.clamp01((value - min) / (max - min))
    // Arrow keys and assistive increments move by `step`. A continuous slider
    // has no grain of its own, so it moves by a twentieth of its range —
    // without this a focusable seek bar would ignore the keyboard entirely.
    readonly property real nudge: step > 0 ? step : (max - min) / 20
    readonly property real pageNudge: step > 0 ? step * 10 : (max - min) / 5

    height: Theme.controlHeight
    activeFocusOnTab: !dimmed
    Accessible.role: Accessible.Slider
    Accessible.name: accessibleName
    Accessible.description: String(value)
    Accessible.onIncreaseAction: applyValue(value + nudge)
    Accessible.onDecreaseAction: applyValue(value - nudge)

    function quantize(v) {
        const stepped = root.step > 0 ? Math.round(v / root.step) * root.step : v;
        return Math.max(root.min, Math.min(root.max, stepped));
    }

    function snapToMark(v) {
        const reach = Math.max(root.step, (root.max - root.min) / 60);
        for (const mark of root.marks) {
            if (Math.abs(v - mark) <= reach)
                return mark;
        }
        return v;
    }

    function apply(x) {
        applyValue(snapToMark(root.min + (x / root.width) * (root.max - root.min)));
    }

    function applyValue(next) {
        const clamped = quantize(next);
        if (clamped !== root.value)
            moved(clamped);
    }

    Keys.onPressed: event => {
        if (event.key === Qt.Key_Left || event.key === Qt.Key_Down)
            applyValue(value - nudge);
        else if (event.key === Qt.Key_Right || event.key === Qt.Key_Up)
            applyValue(value + nudge);
        else if (event.key === Qt.Key_PageDown)
            applyValue(value - pageNudge);
        else if (event.key === Qt.Key_PageUp)
            applyValue(value + pageNudge);
        else if (event.key === Qt.Key_Home)
            applyValue(min);
        else if (event.key === Qt.Key_End)
            applyValue(max);
        else
            return;
        event.accepted = true;
    }

    Rectangle {
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width
        height: 4
        radius: 2
        color: root.gradientTrack || root.hueTrack || root.colorTrack
            ? "transparent" : Theme.hairline
        opacity: root.dimmed ? 0.45 : 1
        gradient: root.hueTrack ? hueGradient
            : root.gradientTrack ? warmGradient
            : root.colorTrack ? colorGradient : null

        Gradient {
            id: warmGradient
            orientation: Gradient.Horizontal
            GradientStop { position: 0; color: "#ff8c3c" }
            GradientStop { position: 1; color: Theme.hairline }
        }

        Gradient {
            id: hueGradient
            orientation: Gradient.Horizontal
            GradientStop { position: 0.0; color: "#df9f9f" }
            GradientStop { position: 0.167; color: "#dfdf9f" }
            GradientStop { position: 0.333; color: "#9fdf9f" }
            GradientStop { position: 0.5; color: "#9fdfdf" }
            GradientStop { position: 0.667; color: "#9f9fdf" }
            GradientStop { position: 0.833; color: "#df9fdf" }
            GradientStop { position: 1.0; color: "#df9f9f" }
        }

        Gradient {
            id: colorGradient
            orientation: Gradient.Horizontal
            GradientStop { position: 0; color: root.trackStart }
            GradientStop { position: 0.5; color: root.trackMiddle }
            GradientStop { position: 1; color: root.trackEnd }
        }

        Rectangle {
            visible: !root.gradientTrack && !root.hueTrack && !root.colorTrack
            width: root.ratio * parent.width
            height: parent.height
            radius: 2
            color: root.dimmed ? Theme.textLow : Theme.accent
        }
    }

    Repeater {
        model: root.marks

        delegate: Rectangle {
            id: tick
            required property real modelData
            x: Math.round(Format.clamp01((tick.modelData - root.min) / (root.max - root.min))
                * (root.width - 10) + 5 - width / 2)
            y: root.height / 2 + 5
            width: 2
            height: 4
            radius: 1
            color: tick.modelData === root.value ? Theme.accentText : Theme.textFaint
            opacity: root.dimmed ? 0.45 : 1
        }
    }

    Rectangle {
        id: handle

        visible: !root.dimmed
        x: Math.round(root.ratio * (parent.width - width))
        anchors.verticalCenter: parent.verticalCenter
        width: sliderMouse.pressed ? 4 : 10
        height: sliderMouse.pressed ? 18 : 10
        radius: width / 2
        color: Theme.textHi
        border.width: root.activeFocus ? 2 : 0
        border.color: Theme.accentText

        Behavior on width {
            NumberAnimation {
                duration: Theme.pressDuration
                easing.type: Easing.BezierSpline
                easing.bezierCurve: Theme.springCurve
            }
        }

        Behavior on height {
            NumberAnimation {
                duration: Theme.pressDuration
                easing.type: Easing.BezierSpline
                easing.bezierCurve: Theme.springCurve
            }
        }
    }

    MouseArea {
        id: sliderMouse
        anchors.fill: parent
        enabled: !root.dimmed
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onPressed: mouse => {
            root.forceActiveFocus();
            root.apply(mouse.x);
        }
        onPositionChanged: mouse => {
            if (pressed)
                root.apply(mouse.x);
        }
    }
}
