pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Effects
import Quickshell.Services.Mpris
import ".."
import "../../Common"

// Now-playing chip: the player's app icon, the track, and a transport that
// unfolds under the pointer.
//
// The controls are not a second chip beside the title — they grow out of the
// same pill, from zero width, which is why the chip's width springs. Hidden,
// they take no space and no clicks; the fold is the whole affordance.
BarModule {
    id: root

    moduleId: "media"
    detailSaving: trackTitle.implicitWidth > 0
        ? Math.min(trackTitle.implicitWidth, Settings.modOpts.media.maxWidth) + 9 : 0

    readonly property var player: Media.player
    readonly property bool playing: player !== null
        && player.playbackState === MprisPlaybackState.Playing

    // A borderless round button inside the chip. It swallows the click so the
    // chip underneath does not also open the media panel.
    component TransportButton: Item {
        id: button

        // Taken rather than reached for: an inline component has its own
        // scope, and the bar's pointer state has to arrive through it.
        required property Bar host
        property string glyph
        property color tone: Theme.barTextMid
        property color hoverTone: Theme.barTextHi
        signal triggered

        // A MouseArea on a layer surface can miss its exit, and a tint bound
        // to that stale state has nothing left to clear it.
        readonly property bool hovered: buttonPointer.over

        width: 24
        height: 24
        anchors.verticalCenter: parent ? parent.verticalCenter : undefined
        opacity: enabled ? 1 : 0.35
        scale: buttonMouse.pressed ? 0.84 : 1

        Behavior on scale {
            NumberAnimation {
                duration: Theme.pressDuration
                easing.type: Easing.BezierSpline
                easing.bezierCurve: Theme.springCurve
            }
        }

        Sym {
            anchors.centerIn: parent
            name: button.glyph
            size: Theme.iconMedium
            color: button.hovered ? button.hoverTone : button.tone
        }

        PointerCheck {
            id: buttonPointer
            host: button.host
            target: button
            hovered: buttonMouse.containsMouse
        }

        MouseArea {
            id: buttonMouse
            anchors.fill: parent
            hoverEnabled: true
            enabled: button.enabled
            cursorShape: Qt.PointingHandCursor
            onClicked: button.triggered()
        }
    }

    BarChip {
        id: mediaChip

        readonly property bool showControls: hovered || held

        host: root.host
        panelName: "media"
        isle: root.isle
        anchorItem: root.groupAnchor ?? mediaChip
        leftPadding: 5
        rightPadding: showControls ? 5 : 12
        spacing: 9
        tooltip: root.player
            ? root.player.trackTitle + (root.player.trackArtist !== ""
                ? " · " + root.player.trackArtist : "")
            : "Media"
        tooltipAlign: -1

        // The player's app icon rests directly on the shared menubar slab.
        // A symbol remains underneath while the image loads and for players
        // that do not expose a usable desktop entry.
        Item {
            anchors.verticalCenter: parent.verticalCenter
            width: 24
            height: 24

            BrandIcon {
                id: playerBrand
                anchors.centerIn: parent
                width: 18
                height: 18
                name: Media.brandIcon
                highlighted: mediaChip.held || mediaChip.hovered
                visible: available && status === Image.Ready
            }

            Image {
                id: playerIcon
                anchors.centerIn: parent
                width: 18
                height: 18
                source: Media.iconSource
                sourceSize: Qt.size(36, 36)
                fillMode: Image.PreserveAspectFit
                asynchronous: true
                visible: !playerBrand.visible && status === Image.Ready
                // The tint animates here rather than inside the effect so the
                // offscreen layer exists only while it is non-zero, as in
                // BrandIcon; at rest the icon takes the plain image path.
                property real tintAmount: mediaChip.held || mediaChip.hovered ? 1 : 0
                Behavior on tintAmount {
                    NumberAnimation { duration: Theme.chipFadeDuration }
                }
                layer.enabled: visible && tintAmount > 0.001
                layer.effect: MultiEffect {
                    colorization: playerIcon.tintAmount
                    colorizationColor: mediaChip.hoverColor
                }
            }

            Sym {
                anchors.centerIn: parent
                visible: !playerBrand.visible && !playerIcon.visible
                name: root.playing ? "graphic_eq" : "music_note"
                size: Theme.iconSmall + 1
                color: mediaChip.fg
            }
        }

        Text {
            id: trackTitle
            visible: !root.compact
            anchors.verticalCenter: parent.verticalCenter
            text: {
                if (!root.player)
                    return "";
                const format = Settings.modOpts.media.titleFormat;
                const artist = root.player.trackArtist;
                const title = root.player.trackTitle;
                if (format === "title" || !artist)
                    return title;
                return format === "artist-title"
                    ? artist + " · " + title : title + " · " + artist;
            }
            font.family: Theme.fontMenu
            font.pixelSize: Theme.typography.bar
            font.weight: Theme.weightSemibold
            color: mediaChip.held || mediaChip.hovered ? Theme.barTextHi : Theme.barTextMid
            elide: Text.ElideRight
            width: Math.min(implicitWidth, Settings.modOpts.media.maxWidth)

            Behavior on color {
                ColorAnimation { duration: Theme.chipFadeDuration }
            }
        }

        // The transport. Clipped to a width that springs from zero, so the
        // buttons slide out of the chip rather than popping into it.
        Item {
            anchors.verticalCenter: parent.verticalCenter
            width: mediaChip.showControls ? controls.implicitWidth : 0
            height: 24
            clip: true
            opacity: mediaChip.showControls ? 1 : 0

            Behavior on width {
                NumberAnimation {
                    duration: Theme.expandDuration
                    easing.type: Easing.BezierSpline
                    easing.bezierCurve: Theme.springCurve
                }
            }

            Behavior on opacity {
                NumberAnimation { duration: Theme.chipFadeDuration }
            }

            Row {
                id: controls
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: 2

                TransportButton {
                    host: root.host
                    glyph: "skip_previous"
                    tone: Theme.barTextMid
                    enabled: root.player !== null && root.player.canGoPrevious
                    onTriggered: root.player.previous()
                }

                TransportButton {
                    host: root.host
                    glyph: root.playing ? "pause" : "play_arrow"
                    tone: Theme.barTextHi
                    hoverTone: Theme.barAccent
                    enabled: root.player !== null && root.player.canTogglePlaying
                    onTriggered: root.player.togglePlaying()
                }

                TransportButton {
                    host: root.host
                    glyph: "skip_next"
                    tone: Theme.barTextMid
                    enabled: root.player !== null && root.player.canGoNext
                    onTriggered: root.player.next()
                }
            }
        }
    }
}
