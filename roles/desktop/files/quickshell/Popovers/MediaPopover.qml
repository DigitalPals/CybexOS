pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Effects
import QtQuick.Shapes
import Quickshell.Services.Mpris
import "../Common"
import "../Common/Format.js" as Format

// Media view: the sleeve lights the whole panel, the track sets left beside
// it, and the transport is anchored to the left edge with the two modifiers
// held out at the right. Volume lives in the audio popout; this view is
// playback only.
//
// The wash is the deliberate full-bleed exception — it reaches the panel's
// corner, where every text and control section keeps its own fourteen-pixel
// inset. Copy never sits on artwork: the wash is scrimmed to near-solid from
// the sleeve's right edge onward, so the semantic colour ladder keeps the
// contrast it was calibrated for.
Surface {
    id: root

    padding: 0
    spacing: 0
    focus: visible

    readonly property var players: Media.players
    property int sourceIdx: -1
    property string announcement: ""

    // The source switcher's manual pick wins; without one this falls back to
    // Media.player, which is literally what the bar chip shows.
    readonly property var player: {
        if (sourceIdx >= 0 && sourceIdx < players.length)
            return players[sourceIdx];
        return Media.player;
    }

    property real pos: 0
    readonly property real len: player && player.lengthSupported ? player.length : 0
    readonly property bool hasArt: player !== null && player.trackArtUrl !== ""
    readonly property bool playing: player !== null && player.isPlaying
    readonly property bool multiSource: players.length > 1

    Keys.onEscapePressed: Popouts.close()

    function selectSource(delta) {
        if (!multiSource)
            return;
        const current = players.indexOf(player);
        sourceIdx = (current + delta + players.length) % players.length;
        announceMedia();
    }

    function announceMedia() {
        if (!player) {
            announcement = "No media player";
            return;
        }
        const title = player.trackTitle || "Unknown track";
        announcement = (player.identity || "Media") + ": " + title
            + (playing ? ", playing" : ", paused");
    }

    function focusInitial() {
        if (!visible)
            return;
        Qt.callLater(() => {
            const target = multiSource ? sourceButton : playButton;
            if (target && target.visible && target.enabled)
                target.forceActiveFocus();
        });
    }

    onVisibleChanged: focusInitial()
    onPlayerChanged: {
        announceMedia();
        focusInitial();
    }
    onPlayingChanged: announceMedia()

    Connections {
        target: root.player
        ignoreUnknownSignals: true

        function onTrackTitleChanged() { root.announceMedia(); }
        function onTrackArtistChanged() { root.announceMedia(); }
    }

    // The sleeve, and how far down the panel its light reaches. The wash ends
    // inside the seek block, so nothing below it has to know about artwork.
    readonly property int sleeveSize: 132
    readonly property int washHeight: Theme.listRowHeight + sleeveSize + 24
    // How much of the artwork survives the scrim at its strongest point. One
    // number, because it is the only thing to turn when the wash reads too
    // loud over a bright cover or too faint over a dark one.
    readonly property real washStrength: 0.52
    // The mask spans the whole panel while the wash spans its top band, so the
    // falloff is expressed in panel fractions: one mask does the corner and
    // the ending together.
    readonly property real washFadeStart: root.height > 0
        ? Math.max(0, (root.washHeight - 110) / root.height) : 0
    readonly property real washFadeEnd: root.height > 0
        ? Math.min(1, root.washHeight / root.height) : 1

    Timer {
        interval: 1000
        running: root.visible && root.player !== null
        repeat: true
        triggeredOnStart: true
        onTriggered: root.pos = root.player && root.player.positionSupported ? root.player.position : 0
    }

    // ---- Artwork, clipped to a corner -----------------------------------
    // Image has no radius of its own and Rectangle's clip is rectangular, so
    // rounding artwork means the shell's masking idiom — see
    // Common/StateLayer.qml, which rounds its ripple the same way.
    component Artwork: Item {
        id: art

        property url source
        property int corner: Theme.cardRadius
        // Cover art arrives at whatever size the player publishes. The wash
        // asks for a deliberately tiny one: upscaling twenty pixels across the
        // panel is the blur, at no cost.
        property int resolution: 320
        // Only the wash sets these. A cover is lit for a sleeve, not for use
        // as a background: dropping its brightness and pushing its chroma is
        // what turns a white album front into colour instead of glare.
        property real dim: 0
        property real vividness: 0
        readonly property Item maskItem: artMask

        Item {
            id: artLayer
            anchors.fill: parent
            layer.enabled: true
            layer.effect: MultiEffect {
                maskEnabled: true
                maskSource: art.maskItem
                brightness: art.dim
                saturation: art.vividness
            }

            Image {
                anchors.fill: parent
                source: art.source
                fillMode: Image.PreserveAspectCrop
                sourceSize: Qt.size(art.resolution, art.resolution)
                asynchronous: true
                smooth: true
            }
        }

        Rectangle {
            id: artMask
            anchors.fill: parent
            radius: art.corner
            color: "white"
            visible: false
            layer.enabled: true
        }
    }

    // ---- The transport marks ---------------------------------------------
    // Drawn rather than set in the icon face. Common/Sym.qml renders through
    // Qt's distance-field text path, which does not apply the Material
    // Symbols FILL axis — every glyph comes out as an outline, and Qt gives
    // that outline subpixel antialiasing on top. On a large mark over the
    // accent, four fringed edges per shape read as a bevel: a button
    // pretending to be three-dimensional. These are the same shapes, solid.
    //
    // Only playback uses them. Shuffle and repeat stay on Sym, because they
    // are line marks in the icon set to begin with and read correctly there.
    component TransportMark: Item {
        id: mark

        // "play" | "pause" | "previous" | "next"
        property string kind: "play"
        property color tone: Theme.icon
        property int size: Theme.iconLarge

        // The marks are described on the icon set's own 24-unit grid, so they
        // keep Material's proportions at any size.
        readonly property real u: size / 24
        // Stroked with the fill colour and a round join: that is what rounds
        // the triangle's points without a corner radius on a path.
        readonly property real soften: Math.max(1.5, 2.1 * u)

        implicitWidth: size
        implicitHeight: size

        Row {
            anchors.centerIn: parent
            visible: mark.kind === "pause"
            spacing: 3.6 * mark.u

            Rectangle {
                width: 4.4 * mark.u
                height: 15 * mark.u
                radius: 1.7 * mark.u
                color: mark.tone
            }

            Rectangle {
                width: 4.4 * mark.u
                height: 15 * mark.u
                radius: 1.7 * mark.u
                color: mark.tone
            }
        }

        Rectangle {
            visible: mark.kind === "previous" || mark.kind === "next"
            x: mark.kind === "previous" ? 4.8 * mark.u : mark.width - 8.4 * mark.u
            anchors.verticalCenter: parent.verticalCenter
            width: 3.6 * mark.u
            height: 14 * mark.u
            radius: 1.5 * mark.u
            color: mark.tone
        }

        Shape {
            anchors.fill: parent
            visible: mark.kind !== "pause"
            preferredRendererType: Shape.CurveRenderer
            // The skip marks point back at their own bar; play points right
            // from the centre of the box.
            transform: Scale {
                origin.x: mark.width / 2
                xScale: mark.kind === "previous" ? -1 : 1
            }

            ShapePath {
                fillColor: mark.tone
                strokeColor: mark.tone
                strokeWidth: mark.soften
                joinStyle: ShapePath.RoundJoin
                capStyle: ShapePath.RoundCap

                startX: mark.kind === "play" ? 8.4 * mark.u : 8.6 * mark.u
                startY: mark.kind === "play" ? 5.9 * mark.u : 6.9 * mark.u

                PathLine {
                    x: mark.kind === "play" ? 17.4 * mark.u : 15.6 * mark.u
                    y: 12 * mark.u
                }

                PathLine {
                    x: mark.kind === "play" ? 8.4 * mark.u : 8.6 * mark.u
                    y: mark.kind === "play" ? 18.1 * mark.u : 17.1 * mark.u
                }

                PathLine {
                    x: mark.kind === "play" ? 8.4 * mark.u : 8.6 * mark.u
                    y: mark.kind === "play" ? 5.9 * mark.u : 6.9 * mark.u
                }
            }
        }
    }

    // ---- One transport control -------------------------------------------
    // `primary` is the single filled control on the panel; `recessed` is the
    // resting chip fill the two skip buttons sit on; the modifiers rest on
    // nothing until they are hovered or on.
    component TransportButton: Rectangle {
        id: button

        property string glyph
        // Playback marks are drawn; shuffle and repeat stay glyphs.
        property string mark: ""
        property int diameter: 38
        property int glyphSize: Theme.iconLarge
        property bool primary: false
        property bool recessed: false
        property bool active: false
        property bool toggle: false
        property bool available: true
        property string accessibleName: ""
        property string accessibleDescription: ""
        signal triggered

        width: diameter
        height: diameter
        radius: diameter / 2
        opacity: available ? 1 : 0.4
        scale: buttonMouse.pressed ? 0.9 : 1
        activeFocusOnTab: available
        border.width: activeFocus ? 2 : 0
        border.color: primary ? Theme.accentFg : Theme.accent
        Accessible.role: toggle ? Accessible.CheckBox : Accessible.Button
        Accessible.name: button.accessibleName
        Accessible.description: button.accessibleDescription
        Accessible.checked: toggle && active
        Accessible.onPressAction: {
            if (button.available)
                button.triggered();
        }
        color: {
            if (button.primary)
                return buttonMouse.containsMouse || button.activeFocus
                    ? Theme.accentHover : Theme.accent;
            if (buttonMouse.containsMouse || button.activeFocus)
                return Theme.chipHover;
            if (button.active)
                return Theme.accentBgSoft;
            return button.recessed ? Theme.chip : "transparent";
        }

        Keys.onPressed: event => {
            if (button.available && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                    || event.key === Qt.Key_Space)) {
                button.triggered();
                event.accepted = true;
            } else if (event.key === Qt.Key_Right || event.key === Qt.Key_Down) {
                const next = button.nextItemInFocusChain(true);
                if (next)
                    next.forceActiveFocus();
                event.accepted = true;
            } else if (event.key === Qt.Key_Left || event.key === Qt.Key_Up) {
                const previous = button.nextItemInFocusChain(false);
                if (previous)
                    previous.forceActiveFocus();
                event.accepted = true;
            }
        }

        Behavior on color {
            ColorAnimation { duration: Theme.chipFadeDuration }
        }

        Behavior on scale {
            NumberAnimation {
                duration: Theme.pressDuration
                easing.type: Easing.BezierSpline
                easing.bezierCurve: Theme.springCurve
            }
        }

        readonly property color inkColor: {
            if (button.primary)
                return Theme.accentFg;
            if (button.active)
                return Theme.accent;
            return buttonMouse.containsMouse ? Theme.textHi : Theme.icon;
        }

        TransportMark {
            anchors.centerIn: parent
            visible: button.mark !== ""
            kind: button.mark
            size: button.glyphSize
            tone: button.inkColor

            Behavior on tone {
                ColorAnimation { duration: Theme.chipFadeDuration }
            }
        }

        Sym {
            anchors.centerIn: parent
            visible: button.mark === ""
            name: button.glyph
            size: button.glyphSize
            color: button.inkColor
        }

        MouseArea {
            id: buttonMouse
            anchors.fill: parent
            hoverEnabled: true
            enabled: button.available
            cursorShape: Qt.PointingHandCursor
            onClicked: {
                button.forceActiveFocus();
                button.triggered();
            }
        }
    }

    // ---- The wash --------------------------------------------------------
    // One layer, clipped and faded by the panel's own backdrop mask: the
    // artwork bleeds from behind the sleeve up into the header and out to the
    // left edge, then ends before the seek bar rather than on an edge.
    backdropMaskGradient: Gradient {
        GradientStop {
            position: 0
            color: "#ffffff"
        }

        GradientStop {
            position: root.washFadeStart
            color: "#ffffff"
        }

        GradientStop {
            position: root.washFadeEnd
            color: "#00ffffff"
        }

        GradientStop {
            position: 1
            color: "#00ffffff"
        }
    }

    backdrop: Item {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        height: root.washHeight
        visible: root.hasArt
        // A paused panel keeps its colour, a step quieter. Losing the field
        // entirely would restyle the whole panel on every pause.
        opacity: root.playing ? 1 : 0.66

        Behavior on opacity {
            NumberAnimation { duration: Theme.surfaceDuration }
        }

        Artwork {
            anchors.fill: parent
            source: root.player ? root.player.trackArtUrl : ""
            corner: 0
            resolution: 24
            dim: -0.5
            vividness: 0.6
        }

        // Knocked back to near-solid from the sleeve's right edge onward,
        // which is where every line of copy is. The artwork keeps its colour
        // to the left of that, where there is nothing to read.
        Rectangle {
            id: sourceButton
            anchors.fill: parent
            gradient: Gradient {
                orientation: Gradient.Horizontal

                GradientStop {
                    position: 0
                    color: Qt.rgba(Theme.popBg.r, Theme.popBg.g, Theme.popBg.b,
                        1 - root.washStrength)
                }

                GradientStop {
                    position: 0.22
                    color: Qt.rgba(Theme.popBg.r, Theme.popBg.g, Theme.popBg.b,
                        1 - root.washStrength * 0.62)
                }

                GradientStop {
                    position: 0.40
                    color: Qt.rgba(Theme.popBg.r, Theme.popBg.g, Theme.popBg.b, 0.975)
                }

                GradientStop {
                    position: 1
                    color: Qt.rgba(Theme.popBg.r, Theme.popBg.g, Theme.popBg.b, 0.98)
                }
            }
        }
    }

    // ---- Header: what the panel is doing, and which player ----------------
    Item {
        width: parent.width
        height: Theme.listRowHeight

        Row {
            x: Theme.panelPadding
            anchors.verticalCenter: parent.verticalCenter
            spacing: 8

            Sym {
                visible: root.player !== null
                anchors.verticalCenter: parent.verticalCenter
                name: root.playing ? "graphic_eq" : "pause"
                size: Theme.iconSmall
                fill: 1
                color: root.playing ? Theme.accent : Theme.textDim
            }

            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: root.player === null ? "MEDIA"
                    : root.playing ? "NOW PLAYING" : "PAUSED"
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.metadata
                font.weight: Theme.weightSemibold
                font.letterSpacing: 1
                color: Theme.textFaint
            }
        }

        Rectangle {
            anchors.right: parent.right
            anchors.rightMargin: Theme.panelPadding - 4
            anchors.verticalCenter: parent.verticalCenter
            width: srcRow.implicitWidth + 16
            height: Theme.chipHeight
            radius: Theme.chipRadius
            color: !root.multiSource ? "transparent"
                : srcMouse.containsMouse || activeFocus ? Theme.chipHover : Theme.chip
            enabled: root.multiSource
            activeFocusOnTab: enabled
            border.width: activeFocus ? 1 : 0
            border.color: Theme.accent
            Accessible.role: Accessible.Button
            Accessible.name: "Choose media player"
            Accessible.description: root.player ? root.player.identity : "No player"
            Accessible.onPressAction: root.selectSource(1)

            Keys.onPressed: event => {
                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                        || event.key === Qt.Key_Space || event.key === Qt.Key_Right
                        || event.key === Qt.Key_Down) {
                    root.selectSource(1);
                    event.accepted = true;
                } else if (event.key === Qt.Key_Left || event.key === Qt.Key_Up) {
                    root.selectSource(-1);
                    event.accepted = true;
                }
            }

            Behavior on color {
                ColorAnimation { duration: Theme.chipFadeDuration }
            }

            Row {
                id: srcRow
                anchors.centerIn: parent
                spacing: 5

                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.player ? root.player.identity : "No player"
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.secondary
                    font.weight: Theme.weightSemibold
                    color: srcMouse.containsMouse ? Theme.textHi : Theme.textMid
                }

                Sym {
                    visible: root.multiSource
                    anchors.verticalCenter: parent.verticalCenter
                    name: "expand_more"
                    size: Theme.iconSmall
                    color: srcMouse.containsMouse ? Theme.textHi : Theme.textLow
                }
            }

            MouseArea {
                id: srcMouse
                anchors.fill: parent
                hoverEnabled: true
                enabled: root.multiSource
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    sourceButton.forceActiveFocus();
                    root.selectSource(1);
                }
            }
        }
    }

    // ---- Sleeve and track -------------------------------------------------
    // Set left rather than centred: three centred lines of wildly different
    // length gave a ragged block no matter what was playing.
    Item {
        width: parent.width
        height: root.sleeveSize
        visible: root.player !== null

        Rectangle {
            id: sleeve
            x: Theme.panelPadding
            width: root.sleeveSize
            height: root.sleeveSize
            radius: Theme.cardRadius
            color: Theme.tile
            border.width: 1
            border.color: Theme.hairline

            Sym {
                anchors.centerIn: parent
                visible: !root.hasArt
                name: "music_note"
                size: Theme.iconHero
                color: Theme.textDim
            }

            Artwork {
                anchors.fill: parent
                anchors.margins: 1
                visible: root.hasArt
                source: root.player ? root.player.trackArtUrl : ""
                corner: Theme.cardRadius - 1
            }
        }

        Column {
            anchors.left: sleeve.right
            anchors.leftMargin: 14
            anchors.right: parent.right
            anchors.rightMargin: Theme.panelPadding
            anchors.bottom: sleeve.bottom
            anchors.bottomMargin: 2
            spacing: 3

            Text {
                width: parent.width
                text: root.player && root.player.trackTitle !== ""
                    ? root.player.trackTitle : "Nothing playing"
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.title
                font.weight: Theme.weightBold
                font.letterSpacing: -0.4
                color: Theme.textHi
                wrapMode: Text.Wrap
                maximumLineCount: 2
                elide: Text.ElideRight
                lineHeight: 1.2
            }

            Text {
                width: parent.width
                topPadding: 4
                visible: text !== ""
                text: root.player ? root.player.trackArtist : ""
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.primary
                font.weight: Theme.weightSemibold
                color: Theme.textMid
                elide: Text.ElideRight
            }

            Text {
                width: parent.width
                visible: text !== ""
                text: root.player ? root.player.trackAlbum : ""
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.secondary
                font.weight: Theme.weightMedium
                color: Theme.textDim
                elide: Text.ElideRight
            }
        }
    }

    // ---- Seek -------------------------------------------------------------
    Column {
        width: parent.width - Theme.panelPadding * 2
        anchors.horizontalCenter: parent.horizontalCenter
        visible: root.player !== null

        HSlider {
            width: parent.width
            value: root.len > 0 ? root.pos / root.len : 0
            dimmed: !root.player || !root.player.canSeek || root.len <= 0
            accessibleName: "Seek"
            onMoved: v => {
                if (root.player && root.player.canSeek && root.len > 0) {
                    root.player.position = v * root.len;
                    root.pos = v * root.len;
                }
            }
        }

        Item {
            width: parent.width
            height: Math.max(positionText.implicitHeight, durationText.implicitHeight)

            Text {
                id: positionText
                anchors.verticalCenter: parent.verticalCenter
                text: Format.mmss(root.pos)
                font.family: Theme.fontMono
                font.pixelSize: Theme.typography.secondary
                font.weight: Theme.weightMedium
                font.features: Theme.tabularNumberFeatures
                color: Theme.textMid
            }

            Text {
                id: durationText
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: root.len > 0 ? Format.mmss(root.len) : "--:--"
                font.family: Theme.fontMono
                font.pixelSize: Theme.typography.secondary
                font.weight: Theme.weightMedium
                font.features: Theme.tabularNumberFeatures
                color: Theme.textDim
            }
        }
    }

    // ---- Transport --------------------------------------------------------
    // Play is the only filled control in the panel and it sits at the left
    // margin, where the eye already is after reading the title. Shuffle and
    // repeat are held out at the far edge: they are settings, not playback.
    Item {
        width: parent.width
        height: 84
        visible: root.player !== null

        Row {
            x: Theme.panelPadding
            anchors.verticalCenter: parent.verticalCenter
            spacing: 8

            TransportButton {
                id: previousButton
                anchors.verticalCenter: parent.verticalCenter
                mark: "previous"
                recessed: true
                accessibleName: "Previous track"
                available: root.player !== null && root.player.canGoPrevious
                onTriggered: root.player.previous()
            }

            TransportButton {
                id: playButton
                anchors.verticalCenter: parent.verticalCenter
                mark: root.playing ? "pause" : "play"
                diameter: 52
                glyphSize: Theme.iconHero
                primary: true
                accessibleName: root.playing ? "Pause" : "Play"
                available: root.player !== null
                onTriggered: root.player.togglePlaying()
            }

            TransportButton {
                id: nextButton
                anchors.verticalCenter: parent.verticalCenter
                mark: "next"
                recessed: true
                accessibleName: "Next track"
                available: root.player !== null && root.player.canGoNext
                onTriggered: root.player.next()
            }
        }

        Row {
            anchors.right: parent.right
            anchors.rightMargin: Theme.panelPadding - 3
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2

            TransportButton {
                anchors.verticalCenter: parent.verticalCenter
                glyph: "shuffle"
                diameter: 34
                glyphSize: Theme.iconMedium
                accessibleName: "Shuffle"
                accessibleDescription: active ? "On" : "Off"
                toggle: true
                active: root.player !== null && root.player.shuffle
                available: root.player !== null && root.player.shuffleSupported
                onTriggered: root.player.shuffle = !root.player.shuffle
            }

            TransportButton {
                anchors.verticalCenter: parent.verticalCenter
                // The design lights a toggle by filling its glyph, but repeat
                // has two on-states, so the track mode takes its own mark.
                glyph: root.player && root.player.loopState === MprisLoopState.Track
                    ? "repeat_one" : "repeat"
                diameter: 34
                glyphSize: Theme.iconMedium
                accessibleName: "Repeat"
                accessibleDescription: !root.player
                    || root.player.loopState === MprisLoopState.None ? "Off"
                    : root.player.loopState === MprisLoopState.Track ? "One track" : "Playlist"
                toggle: true
                active: root.player !== null
                    && root.player.loopState !== MprisLoopState.None
                available: root.player !== null && root.player.loopSupported
                onTriggered: {
                    const s = root.player.loopState;
                    root.player.loopState = s === MprisLoopState.None ? MprisLoopState.Playlist
                        : s === MprisLoopState.Playlist ? MprisLoopState.Track
                        : MprisLoopState.None;
                }
            }
        }
    }

    // ---- Nothing playing ---------------------------------------------------
    // The panel shrinks to the shape of what it has to say. The old view held
    // a full-height frame here and filled the artwork band with a fixed
    // purple-to-rust gradient, which read as a cover that failed to load.
    Item {
        width: parent.width
        height: 186
        visible: root.player === null

        Column {
            anchors.centerIn: parent
            width: parent.width - Theme.panelPadding * 4
            spacing: 0

            Rectangle {
                anchors.horizontalCenter: parent.horizontalCenter
                width: 64
                height: 64
                radius: 32
                color: Theme.chip

                Sym {
                    anchors.centerIn: parent
                    name: "music_note"
                    size: Theme.iconHero
                    color: Theme.textDim
                }
            }

            Text {
                width: parent.width
                topPadding: 16
                horizontalAlignment: Text.AlignHCenter
                text: "Nothing playing"
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.primary
                font.weight: Theme.weightSemibold
                color: Theme.textMid
            }

            Text {
                width: parent.width
                topPadding: 5
                horizontalAlignment: Text.AlignHCenter
                text: "Controls appear as soon as a player starts."
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.secondary
                font.weight: Theme.weightRegular
                color: Theme.textDim
                wrapMode: Text.Wrap
            }
        }
    }

    Item {
        width: 1
        height: 1
        opacity: 0
        Accessible.role: Accessible.AlertMessage
        Accessible.name: root.announcement
    }

    Component.onCompleted: {
        announceMedia();
        focusInitial();
    }
}
