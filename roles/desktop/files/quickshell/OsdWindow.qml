import QtQuick
import Quickshell
import Quickshell.Wayland
import "Common"
import "Popovers"
import "Common/Format.js" as Format

// Volume / brightness OSD (design t3, shape 3a): a bottom-center pill —
// icon · blocked meter · mono % — on the overlay layer, no focus steal.
// The meter is the shared BlockMeter and fills block-by-block; mute goes
// red; the scroll wheel on the pill adjusts the value directly.
PanelWindow {
    id: root

    // Stay mapped through the fade-out; unmap once the pill is gone.
    visible: Osd.active || pill.opacity > 0.001
    screen: Screens.focused
    // Placement follows Shell settings; when pill and bar share an edge the
    // margin clears the bar zone instead of hugging the screen edge.
    readonly property bool atTop: Settings.osd === "top"
    readonly property int barClearance: Theme.barTopMargin + Theme.barHeight + 12
    readonly property bool sharesBarScreen: Screens.hasBar(root.screen)
    anchors {
        top: atTop
        bottom: !atTop
    }
    // PanelWindow.margins is a Quickshell group qmllint cannot resolve.
    // qmllint disable unqualified
    margins {
        top: atTop && Settings.position === "top" && sharesBarScreen ? barClearance : 12
        bottom: !atTop && Settings.position === "bottom" && sharesBarScreen ? barClearance : 12
    }
    // qmllint enable unqualified
    // Breathing room around the pill for the drop shadow and exit slide.
    readonly property int pad: 48
    implicitWidth: pill.implicitWidth + pad * 2
    implicitHeight: pill.implicitHeight + pad * 2
    exclusionMode: ExclusionMode.Ignore
    color: "transparent"

    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "qs-osd"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    // Pointer input only over the pill; everything else falls through.
    mask: Region {
        item: pill
    }

    readonly property var audio: Osd.sink && Osd.sink.audio ? Osd.sink.audio : null
    readonly property bool volumeKind: Osd.kind === "volume"
    readonly property bool muted: volumeKind && audio !== null && audio.muted
    readonly property real value: volumeKind
        ? (audio ? audio.volume : 0)
        : Math.max(0, SysInfo.brightness) / 100

    // Smooth the level, then snap the meter to whole blocks below so the
    // fill advances block-by-block rather than sliding.
    property real shown: value

    Behavior on shown {
        NumberAnimation {
            duration: Theme.reducedMotion ? 0 : 140
            easing.type: Easing.OutCubic
        }
    }

    Rectangle {
        id: pill

        x: root.pad
        y: root.pad + (Osd.active ? 0 : root.atTop ? -16 : 16)
        opacity: Osd.active ? 1 : 0
        implicitWidth: row.implicitWidth + Theme.panelPadding * 2
        implicitHeight: Math.max(Theme.controlHeight, row.implicitHeight + Theme.scaled(20))
        radius: height / 2
        color: Theme.panelSurface
        border.width: 1
        border.color: root.muted ? Theme.redBorder : Theme.popBorder

        Behavior on opacity {
            NumberAnimation {
                duration: Theme.panelFadeDuration
                easing.type: Easing.OutCubic
            }
        }

        // Springs in from the screen edge it sits against, like every other
        // surface the shell raises.
        Behavior on y {
            NumberAnimation {
                duration: Theme.panelMotionDuration
                easing.type: Easing.BezierSpline
                easing.bezierCurve: Theme.springCurve
            }
        }

        Row {
            id: row
            x: Theme.panelPadding
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.controlSpacing

            Sym {
                anchors.verticalCenter: parent.verticalCenter
                width: Theme.iconMedium
                horizontalAlignment: Text.AlignHCenter
                name: root.volumeKind
                    ? (root.muted || root.value === 0 ? "volume_off" : root.value < 0.5 ? "volume_down" : "volume_up")
                    : "light_mode"
                size: Theme.iconMedium
                color: root.muted ? Theme.redText : Theme.textHi
            }

            BlockMeter {
                anchors.verticalCenter: parent.verticalCenter
                width: Theme.scaled(160)
                height: Theme.scaled(8)
                fillColor: root.muted ? Qt.rgba(232 / 255, 131 / 255, 122 / 255, 0.45) : Theme.accent
                value: Math.round(root.shown * width / (blockWidth + gap)) * (blockWidth + gap) / width
            }

            Item {
                anchors.verticalCenter: parent.verticalCenter
                width: Math.max(Theme.scaled(48), pct.implicitWidth + unit.implicitWidth, muteLabel.implicitWidth)
                height: Math.max(pct.implicitHeight, muteLabel.implicitHeight)

                Text {
                    id: pct
                    visible: !root.muted
                    anchors.right: unit.left
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.volumeKind
                        ? Math.round(root.value * 100)
                        : (SysInfo.brightness >= 0 ? SysInfo.brightness : "--")
                    font.family: Theme.fontMono
                    font.pixelSize: Theme.typography.osd
                    font.weight: Theme.weightSemibold
                    color: Theme.textHi
                }

                Text {
                    id: unit
                    visible: !root.muted
                    anchors.right: parent.right
                    anchors.baseline: pct.baseline
                    text: "%"
                    font.family: Theme.fontMono
                    font.pixelSize: Theme.typography.osd
                    color: Theme.textLow
                }

                Text {
                    id: muteLabel
                    visible: root.muted
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: "MUTE"
                    font.family: Theme.fontMono
                    font.pixelSize: Theme.typography.osd
                    font.weight: Theme.weightSemibold
                    color: Theme.redText
                }
            }
        }

        MouseArea {
            anchors.fill: parent
            onWheel: wheel => {
                const steps = wheel.angleDelta.y / 120;
                if (root.volumeKind) {
                    if (root.audio)
                        root.audio.volume = Format.clamp01(root.audio.volume + steps * 0.05);
                } else if (SysInfo.brightness < 0) {
                    // Nothing has read the display yet (brightness is -1
                    // until something asks), and a step from there would
                    // land near zero. Ask now; the next notch acts on it.
                    SysInfo.refreshBrightness();
                    Osd.show("brightness");
                } else {
                    SysInfo.setBrightness(SysInfo.brightness + steps * 5);
                    Osd.show("brightness");
                }
            }
        }
    }
}
