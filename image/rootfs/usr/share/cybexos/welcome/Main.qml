import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import QtQuick.Layouts
import QtQuick.Shapes

// The first-login welcome. An installed system opens on a row of popular
// Wallhaven wallpapers (the shell searches, downloads and applies them; this
// window only asks over IPC) and one way onward, Settings. Closing the window
// finishes the welcome. A live session keeps its install-or-explore choice.
ApplicationWindow {
    id: window

    readonly property color ink: "#f4f4f5"
    readonly property color inkMid: "#b4b4bb"
    readonly property color inkFaint: "#80808a"
    readonly property color surface: "#17171a"
    readonly property color surfaceHover: "#202024"
    readonly property color stroke: "#2a2a30"
    // Cybex red, from the wordmark.
    readonly property color accent: "#dd0034"
    readonly property color accentHover: "#f0164a"
    readonly property color accentDown: "#b8002b"
    readonly property color accentText: "#ff6b86"

    // Hyprland's window rule (looknfeel.lua) floats and centres the window
    // and sizes it from the monitor it opens on: half its width, 48% of its
    // height, never below the minimum. Before mapping, Qt only knows its
    // primary screen, so this same share of it is just the fallback for a
    // session without that rule.
    width: Math.max(minimumWidth, Math.round(Screen.width * 0.5))
    height: Math.max(minimumHeight, Math.round(Screen.height * 0.48))
    minimumWidth: 760
    minimumHeight: 580
    visible: true
    title: "Welcome to CybexOS"
    color: "#0e0e10"
    font.family: "Figtree"
    font.pixelSize: 16
    palette.windowText: ink
    palette.text: ink
    palette.buttonText: ink
    palette.button: surface
    palette.highlight: accent

    onClosing: close => {
        if (welcome.busy) {
            close.accepted = false;
            return;
        }
        welcome.markComplete();
    }

    // A wallpaper picked elsewhere (Settings, rotation) while this window
    // was in the background shows up as current when it comes back.
    onActiveChanged: {
        if (active && !welcome.isLive)
            welcome.refreshWallpapers()
    }

    Component.onCompleted: {
        if (!welcome.isLive)
            welcome.loadWallpapers();
    }

    Shortcut {
        sequence: "Escape"
        onActivated: window.close()
    }

    Connections {
        target: welcome
        function onChanged() {
            // Keep the process alive to report failures, while giving the
            // installer the full desktop instead of tiling two windows.
            if (welcome.busy) window.hide();
            else window.show();
        }
        function onActivate() {
            window.show();
            window.raise();
            window.requestActivate();
        }
    }

    component ActionButton: Button {
        id: button
        property bool primary: false
        implicitHeight: 48
        leftPadding: 26
        rightPadding: 26
        font.weight: Font.DemiBold
        background: Rectangle {
            radius: 12
            color: button.primary
                ? (button.down ? window.accentDown : button.hovered ? window.accentHover : window.accent)
                : (button.hovered ? window.surfaceHover : window.surface)
            opacity: button.enabled ? 1 : 0.5
            border.width: button.visualFocus ? 2 : 0
            border.color: "#ffffff"
        }
        contentItem: Text {
            text: button.text
            color: button.primary ? "#ffffff" : window.ink
            font: button.font
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
        }
    }

    component SectionLabel: Text {
        color: window.inkFaint
        font.pixelSize: 12
        font.weight: Font.DemiBold
        font.letterSpacing: 1.6
        font.capitalization: Font.AllUppercase
    }

    // A wallpaper card: the thumbnail with rounded corners, a red ring and
    // check on the current one, and a scrim with progress while it downloads.
    component WallpaperCard: Item {
        id: card
        property string thumb: ""
        property bool current: false
        property bool downloading: false
        property int progress: 0
        // Keyboard focus lives on the row; the row says which card has it.
        property bool focused: false
        property bool hovered: cardMouse.containsMouse
        signal picked()

        width: 256
        height: 144
        readonly property real radius: Math.round(height / 12)

        Rectangle {
            anchors.fill: parent
            radius: card.radius
            color: window.surface
            Text {
                anchors.centerIn: parent
                visible: thumbImage.status !== Image.Ready
                text: thumbImage.status === Image.Error ? "Could not load" : "Loading…"
                color: window.inkFaint
                font.pixelSize: 13
            }
        }

        Image {
            id: thumbImage
            anchors.fill: parent
            source: card.thumb
            sourceSize.width: 512
            sourceSize.height: 288
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            cache: true
            visible: false
            layer.enabled: true
        }

        Rectangle {
            id: cardMask
            anchors.fill: parent
            radius: card.radius
            visible: false
            layer.enabled: true
        }

        MultiEffect {
            anchors.fill: parent
            source: thumbImage
            maskEnabled: true
            maskSource: cardMask
            visible: thumbImage.status === Image.Ready
            // A little lift on hover, without moving the card.
            brightness: card.hovered && !card.downloading ? 0.06 : 0
        }

        Rectangle {
            anchors.fill: parent
            radius: card.radius
            visible: card.downloading
            color: Qt.rgba(0, 0, 0, 0.55)
            Text {
                anchors.centerIn: parent
                text: "Downloading " + card.progress + "%"
                color: "#ffffff"
                font.pixelSize: 14
                font.weight: Font.DemiBold
            }
            Rectangle {
                anchors.left: parent.left
                anchors.bottom: parent.bottom
                anchors.margins: 10
                height: 4
                radius: 2
                width: (parent.width - 20) * card.progress / 100
                color: window.accent
            }
        }

        Rectangle {
            anchors.fill: parent
            radius: card.radius
            color: "transparent"
            border.width: card.current ? 3 : card.focused ? 2 : card.hovered ? 1 : 0
            border.color: card.current ? window.accent : "#ffffff"
        }

        Rectangle {
            visible: card.current
            anchors.top: parent.top
            anchors.right: parent.right
            anchors.margins: 10
            width: 26
            height: 26
            radius: 13
            color: window.accent
            // Drawn rather than typed: Figtree has no check mark, and the
            // fallback font drew a "V".
            Shape {
                anchors.fill: parent
                preferredRendererType: Shape.CurveRenderer
                ShapePath {
                    strokeColor: "#ffffff"
                    strokeWidth: 2.4
                    fillColor: "transparent"
                    capStyle: ShapePath.RoundCap
                    joinStyle: ShapePath.RoundJoin
                    startX: 7.5; startY: 13.5
                    PathLine { x: 11.2; y: 17.2 }
                    PathLine { x: 18.5; y: 9.2 }
                }
            }
        }

        MouseArea {
            id: cardMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: card.picked()
        }
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 40
        spacing: 0

        RowLayout {
            Layout.fillWidth: true
            Image {
                source: "cybex-wordmark.svg"
                Layout.preferredHeight: 30
                Layout.preferredWidth: 30 * 198 / 46.6
                sourceSize.height: 90
                fillMode: Image.PreserveAspectFit
                smooth: true
                Accessible.role: Accessible.Graphic
                Accessible.name: "Cybex"
            }
            Item { Layout.fillWidth: true }
            SectionLabel {
                text: welcome.isLive ? "Live preview · Alpha" : "Your desktop"
            }
        }

        Item { Layout.preferredHeight: 44 }

        Text {
            Layout.fillWidth: true
            text: welcome.isLive ? "Make yourself at home." : "Welcome to your new desktop."
            color: window.ink
            font.pixelSize: 38
            font.weight: Font.DemiBold
            wrapMode: Text.WordWrap
        }

        Item { Layout.preferredHeight: 10 }

        Text {
            Layout.fillWidth: true
            text: welcome.isLive
                ? "Explore the desktop from your USB drive, or install it when you’re ready."
                : "Pick a wallpaper to start: the desktop’s colors follow it. You can come back here any time from the app launcher."
            color: window.inkMid
            wrapMode: Text.WordWrap
            lineHeight: 1.35
        }

        Item { Layout.preferredHeight: 34 }

        // ---- installed: make it yours ---------------------------------
        ColumnLayout {
            visible: !welcome.isLive
            Layout.fillWidth: true
            // The row takes the free height (up to its largest cards).
            Layout.fillHeight: true
            spacing: 14

            RowLayout {
                Layout.fillWidth: true
                SectionLabel { text: "Make it yours" }
                Item { Layout.fillWidth: true }
                Text {
                    text: welcome.wallpaperSource === "online" ? "Popular on wallhaven.cc"
                        : welcome.wallpaperSource === "local" ? "On this computer" : ""
                    color: window.inkFaint
                    font.pixelSize: 13
                }
            }

            Item {
                id: rowArea
                // Cards grow into the window's free height, from 144 to 234
                // pixels tall, so a large window shows larger previews rather
                // than an empty band above the footer.
                readonly property real cardHeight: Math.max(144, Math.min(234, height - 18))
                readonly property real cardWidth: Math.round(cardHeight * 16 / 9)
                Layout.fillWidth: true
                Layout.fillHeight: true
                // Takes the free height before the spacer below does.
                Layout.verticalStretchFactor: 1000
                Layout.minimumHeight: 144 + 18
                Layout.maximumHeight: 234 + 18

                ListView {
                    id: wallpaperRow
                    anchors.fill: parent
                    orientation: ListView.Horizontal
                    spacing: 14
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    model: welcome.wallpapers
                    activeFocusOnTab: count > 0
                    keyNavigationEnabled: true
                    highlightFollowsCurrentItem: false
                    Accessible.role: Accessible.List
                    Accessible.name: "Wallpapers"
                    // Shown whenever there is more to the side, so the row
                    // reads as scrollable before anyone tries.
                    ScrollBar.horizontal: ScrollBar {
                        policy: wallpaperRow.contentWidth > wallpaperRow.width
                            ? ScrollBar.AlwaysOn : ScrollBar.AlwaysOff
                    }

                    Keys.onReturnPressed: currentItem && currentItem.picked()
                    Keys.onEnterPressed: currentItem && currentItem.picked()
                    Keys.onSpacePressed: currentItem && currentItem.picked()

                    delegate: WallpaperCard {
                        required property var modelData
                        required property int index
                        width: rowArea.cardWidth
                        height: rowArea.cardHeight
                        thumb: modelData.thumb
                        current: modelData.fileName === welcome.currentFile
                        downloading: modelData.key === welcome.downloadingKey
                        progress: welcome.downloadProgress
                        focused: wallpaperRow.activeFocus && wallpaperRow.currentIndex === index
                        Accessible.role: Accessible.Button
                        Accessible.name: "Use wallpaper " + modelData.label
                        onPicked: {
                            wallpaperRow.currentIndex = index;
                            welcome.pickWallpaper(modelData.key);
                        }
                    }

                    // The rest of Wallhaven lives in Settings → Wallpaper → Online.
                    footer: Item {
                        width: moreCard.width + 14
                        height: rowArea.cardHeight
                        Rectangle {
                            id: moreCard
                            x: 14
                            width: Math.round(rowArea.cardWidth * 0.7)
                            height: rowArea.cardHeight
                            radius: Math.round(height / 12)
                            color: moreMouse.containsMouse ? window.surfaceHover : window.surface
                            border.width: 1
                            border.color: window.stroke
                            Column {
                                anchors.centerIn: parent
                                spacing: 6
                                Text {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    text: "More online →"
                                    color: window.ink
                                    font.weight: Font.DemiBold
                                }
                                Text {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    text: "Search in Settings"
                                    color: window.inkFaint
                                    font.pixelSize: 13
                                }
                            }
                            MouseArea {
                                id: moreMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: welcome.openSettings("wallpaper")
                            }
                        }
                    }
                }

                // A vertical wheel scrolls the row sideways; clicks and
                // hovers still reach the cards beneath.
                MouseArea {
                    anchors.fill: wallpaperRow
                    acceptedButtons: Qt.NoButton
                    onWheel: wheel => {
                        const delta = wheel.pixelDelta.x !== 0 || wheel.pixelDelta.y !== 0
                            ? (wheel.pixelDelta.x !== 0 ? wheel.pixelDelta.x : wheel.pixelDelta.y)
                            : (wheel.angleDelta.x !== 0 ? wheel.angleDelta.x : wheel.angleDelta.y) / 120 * rowArea.cardWidth / 2;
                        const start = wallpaperRow.originX;
                        const end = start + Math.max(0, wallpaperRow.contentWidth - wallpaperRow.width);
                        wallpaperRow.contentX = Math.max(start, Math.min(end, wallpaperRow.contentX - delta));
                    }
                }

                // Loading and waiting states stand in for the row until it
                // has something to show.
                Rectangle {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    height: rowArea.cardHeight
                    radius: 12
                    visible: wallpaperRow.count === 0
                    color: window.surface
                    Text {
                        anchors.centerIn: parent
                        width: parent.width - 48
                        horizontalAlignment: Text.AlignHCenter
                        wrapMode: Text.WordWrap
                        text: welcome.wallpaperSource === "waiting" ? "Waiting for the desktop to start…"
                            : welcome.wallpaperSource === "unavailable" ? welcome.wallpaperNote
                            : "Finding popular wallpapers…"
                        color: window.inkMid
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                visible: welcome.wallpaperNote !== "" && wallpaperRow.count > 0
                    || welcome.wallpaperSource === "local" || welcome.wallpaperSource === "unavailable"
                spacing: 12
                Text {
                    Layout.fillWidth: true
                    visible: wallpaperRow.count > 0
                    text: welcome.wallpaperNote
                    color: window.inkMid
                    font.pixelSize: 14
                    wrapMode: Text.WordWrap
                    Accessible.role: Accessible.AlertMessage
                }
                Item { Layout.fillWidth: wallpaperRow.count === 0 }
                Button {
                    visible: welcome.wallpaperSource === "local" || welcome.wallpaperSource === "unavailable"
                    text: "Try again"
                    flat: true
                    onClicked: welcome.loadWallpapers()
                }
            }

            // Height the largest cards cannot use collects here, under the
            // row, instead of spreading gaps between the heading and the row.
            Item {
                Layout.fillHeight: true
                Layout.verticalStretchFactor: 1
            }
        }

        // ---- live: guided installation --------------------------------
        Rectangle {
            visible: welcome.isLive
            Layout.fillWidth: true
            Layout.preferredHeight: details.implicitHeight + 40
            radius: 16
            color: window.surface
            ColumnLayout {
                id: details
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: 20
                spacing: 14
                Text {
                    text: "A guided installation"
                    color: window.ink
                    font.weight: Font.DemiBold
                }
                Text {
                    Layout.fillWidth: true
                    text: "Create your account, choose a disk, and review. Encryption and automatic login are selected by default."
                    color: window.inkMid
                    wrapMode: Text.WordWrap
                    lineHeight: 1.3
                }
                Text {
                    Layout.fillWidth: true
                    text: "Your disk and account passwords start out the same. Changing the account password later does not update the disk password."
                    color: window.accentText
                    wrapMode: Text.WordWrap
                    font.pixelSize: 14
                }
            }
        }

        Text {
            Layout.fillWidth: true
            Layout.topMargin: 14
            visible: welcome.status.length > 0
            text: welcome.status
            color: window.accentText
            wrapMode: Text.WordWrap
            font.pixelSize: 14
            Accessible.role: Accessible.AlertMessage
        }

        Item { Layout.fillHeight: welcome.isLive }

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 1
            color: window.stroke
        }

        Item { Layout.preferredHeight: 20 }

        RowLayout {
            Layout.fillWidth: true
            spacing: 16

            ColumnLayout {
                visible: !welcome.isLive
                Layout.fillWidth: true
                spacing: 4
                Text {
                    Layout.fillWidth: true
                    text: "Press Super + K to see every keyboard shortcut."
                    color: window.inkMid
                    font.pixelSize: 14
                    wrapMode: Text.WordWrap
                }
                Text {
                    Layout.fillWidth: true
                    text: "Your app keyring stays encrypted and unlocks with the disk password when they match."
                    color: window.inkFaint
                    font.pixelSize: 13
                    wrapMode: Text.WordWrap
                }
            }

            Button {
                visible: welcome.isLive
                text: "Try the desktop first →"
                enabled: !welcome.busy
                flat: true
                onClicked: welcome.finish()
            }

            Item {
                visible: welcome.isLive
                Layout.fillWidth: true
            }

            ActionButton {
                primary: true
                text: welcome.isLive ? (welcome.busy ? "Installer is open…" : "Install CybexOS") : "Settings"
                enabled: !welcome.busy
                onClicked: welcome.isLive ? welcome.install() : welcome.openSettings("appearance")
            }
        }
    }
}
