pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Services.Mpris
import "../../Common"
import "../../Common/UpdatesHelpers.js" as UpdatesHelpers
import ".."

// The drawer's Overview tab: system identity and health, now playing, the two
// sliders, quick-toggle tiles, updates, and the session footer.
// Everything here is a summary — each row's own tab or panel carries the
// detail.
Column {
    id: root

    property bool highlightUpdates: false

    width: parent ? parent.width : 0
    spacing: Theme.scaled(14)

    // The hero's live metrics and brightness share one watcher claim. Keyed
    // on visibility, not construction: the drawer's `control` instance stays
    // latched by the popout host.
    Claim {
        active: root.visible
        onClaimed: SysInfo.acquire()
        onReleased: SysInfo.release()
    }

    DrawerSystemHero {
        width: parent.width
    }

    // ---- now playing ---------------------------------------------------
    Rectangle {
        visible: Media.hasTrack && Settings.drawerOverview.media === true
        width: parent.width
        height: 64
        radius: 10
        color: Theme.chip

        Item {
            id: art
            anchors.left: parent.left
            anchors.leftMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            width: 44
            height: 44

            Rectangle {
                anchors.fill: parent
                radius: 8
                color: Theme.chipHover

                Sym {
                    anchors.centerIn: parent
                    name: Media.glyph
                    size: 20
                    color: Theme.textMid
                    visible: artImage.status !== Image.Ready
                }
            }

            Image {
                id: artImage
                anchors.fill: parent
                source: Media.player ? Media.player.trackArtUrl : ""
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                sourceSize: Qt.size(88, 88)
                visible: status === Image.Ready
            }
        }

        Column {
            anchors.left: art.right
            anchors.leftMargin: 12
            anchors.right: transport.left
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2

            Text {
                width: parent.width
                text: Media.player ? Media.player.trackTitle : ""
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.primary
                font.weight: Theme.weightSemibold
                color: Theme.textHi
                elide: Text.ElideRight
            }

            Text {
                width: parent.width
                text: {
                    if (!Media.player)
                        return "";
                    const artist = Media.player.trackArtist;
                    const app = Media.player.identity;
                    return artist !== "" && app !== ""
                        ? artist + " · " + app : (artist || app);
                }
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.secondary
                color: Theme.textFaint
                elide: Text.ElideRight
            }
        }

        Row {
            id: transport
            anchors.right: parent.right
            anchors.rightMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2

            DrawerIconButton {
                anchors.verticalCenter: parent.verticalCenter
                glyph: "skip_previous"
                fill: 1
                width: 30
                height: 30
                enabled: Media.player !== null && Media.player.canGoPrevious
                accessibleName: "Previous track"
                onClicked: Media.player.previous()
            }

            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: 30
                height: 30
                radius: 15
                color: Theme.accent

                Sym {
                    anchors.centerIn: parent
                    name: Media.player
                        && Media.player.playbackState === MprisPlaybackState.Playing
                        ? "pause" : "play_arrow"
                    size: 18
                    fill: 1
                    color: Theme.accentFg
                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        if (Media.player)
                            Media.player.togglePlaying();
                    }
                }

                Accessible.role: Accessible.Button
                Accessible.name: "Play or pause"
            }

            DrawerIconButton {
                anchors.verticalCenter: parent.verticalCenter
                glyph: "skip_next"
                fill: 1
                width: 30
                height: 30
                enabled: Media.player !== null && Media.player.canGoNext
                accessibleName: "Next track"
                onClicked: Media.player.next()
            }
        }
    }

    // ---- sliders --------------------------------------------------------
    Column {
        visible: Settings.drawerOverview.sliders === true
        width: parent.width
        spacing: 8

        DrawerSliderRow {
            glyph: "sunny"
            visible: SysInfo.brightness >= 0
            value: Math.max(0, SysInfo.brightness) / 100
            showValue: true
            accessibleName: "Screen brightness"
            onMoved: v => SysInfo.setBrightness(v * 100)
        }

        DrawerSliderRow {
            glyph: Audio.muted || Audio.volume === 0 ? "volume_off"
                : Audio.volume < 50 ? "volume_down" : "volume_up"
            value: Audio.level
            ready: Audio.ready
            showValue: true
            accessibleName: "Output volume"
            onMoved: v => Audio.setVolume(v)
        }
    }

    // ---- quick toggles ---------------------------------------------------
    Grid {
        visible: Settings.drawerOverview.tiles === true
        width: parent.width
        columns: 4
        columnSpacing: 6
        rowSpacing: 6

        readonly property real tileWidth: (width - columnSpacing * 3) / 4

        DrawerTile {
            width: parent.tileWidth
            glyph: "dark_mode"
            label: "Dark"
            on: Settings.themeMode === "dark"
            onToggled: Settings.set("themeMode",
                Settings.themeMode === "dark" ? "light" : "dark")
        }

        DrawerTile {
            width: parent.tileWidth
            glyph: "do_not_disturb_on"
            label: "Focus"
            on: Notifs.dnd
            onToggled: Notifs.setDnd(!Notifs.dnd)
        }

        DrawerTile {
            width: parent.tileWidth
            glyph: "nightlight"
            label: "Night"
            on: SysInfo.nightLight
            onToggled: SysInfo.toggleNightLight()
        }

        DrawerTile {
            width: parent.tileWidth
            glyph: "coffee"
            label: "Awake"
            on: SysInfo.idleInhibited
            onToggled: SysInfo.toggleIdleInhibited()
        }
    }

    // ---- updates ---------------------------------------------------------
    Column {
        visible: Settings.drawerOverview.updates === true
        width: parent.width
        spacing: 6

        SectionLabel {
            width: parent.width
            text: "UPDATES"
            detail: Updates.checkedLabel()
        }

        Rectangle {
            width: parent.width
            height: 48
            radius: Theme.rowRadius
            color: root.highlightUpdates ? Theme.chip : "transparent"

            Sym {
                id: updatesGlyph
                anchors.left: parent.left
                anchors.leftMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                name: Updates.total === 0 && Updates.error === ""
                    && Updates.runState === "idle" && !Updates.rebootRecommended
                    ? "check_circle" : "deployed_code_update"
                size: 18
                fill: Updates.total === 0 && Updates.runState === "idle" ? 1 : 0
                color: Updates.total === 0 && Updates.error === ""
                    && Updates.runState === "idle" && !Updates.rebootRecommended
                    ? Theme.ok : Theme.textMid
            }

            Column {
                anchors.left: updatesGlyph.right
                anchors.leftMargin: 12
                anchors.right: updateAction.left
                anchors.rightMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                spacing: 1

                Text {
                    width: parent.width
                    text: Updates.runActive
                        ? "Updating · " + (Updates.runPercent >= 0
                            ? Updates.runPercent + "%" : "…")
                        : Updates.runState === "failed"
                        ? "Update failed"
                        : Updates.rebootRecommended
                        ? UpdatesHelpers.rebootLabel(Updates.rebootRecommendation,
                            Updates.kernelPending)
                        : Updates.error !== "" ? "Updates unavailable"
                        : Updates.total === 0 ? "Up to date"
                        : Updates.total + (Updates.total === 1
                            ? " update" : " updates")
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.primary
                    font.weight: Theme.weightMedium
                    color: Updates.runState === "failed" ? Theme.redText : Theme.textHi
                    elide: Text.ElideRight
                }

                Text {
                    width: parent.width
                    text: Updates.total > 0
                        ? Updates.namesLabel(Updates.dnfNames, Updates.dnfCount)
                            + (Updates.flatpakCount > 0
                                ? " · " + Updates.flatpakCount + " flatpaks" : "")
                        : Updates.summary
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.metadata
                    color: Theme.textFaint
                    elide: Text.ElideRight
                }
            }

            ActionButton {
                id: updateAction
                anchors.right: parent.right
                anchors.rightMargin: 4
                anchors.verticalCenter: parent.verticalCenter
                visible: Updates.total > 0 && !Updates.runActive
                label: "Update"
                // The one primary action this panel carries.
                fill: Theme.accent
                tint: Theme.accentFg
                hPadding: 20
                onTriggered: Updates.run()
            }

            DrawerIconButton {
                visible: Updates.total === 0 && !Updates.runActive && !Updates.busy
                anchors.right: parent.right
                anchors.rightMargin: 4
                anchors.verticalCenter: parent.verticalCenter
                glyph: "refresh"
                glyphSize: 16
                tint: Theme.textFaint
                accessibleName: "Check for updates"
                onClicked: Updates.check()
            }
        }
    }

    // ---- session ---------------------------------------------------------
    Item {
        width: parent.width
        height: 42

        Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            height: 1
            color: Theme.hairlineSoft
        }

        Row {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            anchors.verticalCenterOffset: 5
            spacing: 2

            DrawerIconButton {
                glyph: "lock"
                accessibleName: "Lock"
                onClicked: { Popouts.close(); Session.lock(); }
            }

            DrawerIconButton {
                glyph: "bedtime"
                accessibleName: "Suspend"
                onClicked: { Popouts.close(); Session.suspend(); }
            }

            DrawerIconButton {
                glyph: "logout"
                accessibleName: "Log out"
                onClicked: { Popouts.close(); Session.logout(); }
            }

            DrawerIconButton {
                glyph: "restart_alt"
                accessibleName: "Restart"
                onClicked: { Popouts.close(); Session.reboot(); }
            }

            DrawerIconButton {
                glyph: "power_settings_new"
                accessibleName: "Shut down"
                onClicked: { Popouts.close(); Session.shutdown(); }
            }
        }

        Row {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.verticalCenterOffset: 5
            spacing: 2

            DrawerIconButton {
                glyph: "photo_camera"
                accessibleName: "Screenshot"
                onClicked: {
                    Popouts.close();
                    Quickshell.execDetached(["sh", "-c",
                        Quickshell.env("HOME") + "/.local/bin/screenshot region"]);
                }
            }

            DrawerIconButton {
                glyph: "keyboard"
                accessibleName: "Keyboard shortcuts"
                onClicked: Session.toggleKeys()
            }

            DrawerIconButton {
                glyph: "settings"
                accessibleName: "Shell settings"
                onClicked: {
                    Popouts.close();
                    Settings.showPanel(undefined, Popouts.hostScreenName);
                }
            }
        }
    }
}
