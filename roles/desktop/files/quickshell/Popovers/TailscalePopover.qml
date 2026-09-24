pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import "../Common"

// Tailscale detail view: tailnet status, this machine, and the peer
// list from `tailscale status --json`. Clicking a peer copies its
// Tailscale IP.
Surface {
    id: root

    property string copiedIp: ""

    // Keep IPC-opened details fresh even when the Network bar module is
    // disabled and therefore holds no long-lived polling claim of its own.
    Claim {
        active: root.visible
        onClaimed: Tailscale.acquireLive()
        onReleased: Tailscale.releaseLive()
    }

    function copyIp(ip) {
        if (ip === "")
            return;
        Quickshell.execDetached(["wl-copy", ip]);
        copiedIp = ip;
        copiedReset.restart();
    }

    Timer {
        id: copiedReset
        interval: 1600
        onTriggered: root.copiedIp = ""
    }

    // Header + toggle
    Item {
        width: parent.width
        height: Theme.listRowHeight

        Text {
            x: 2
            anchors.verticalCenter: parent.verticalCenter
            text: "Tailscale"
            font.family: Theme.fontMenu
            font.pixelSize: Theme.typography.primary
            font.weight: Theme.weightSemibold
            color: Theme.textHi
        }

        Rectangle {
            anchors.bottom: parent.bottom
            width: parent.width
            height: 1
            color: Theme.hairlineSoft
        }

        Toggle {
            anchors.right: parent.right
            anchors.rightMargin: 0
            anchors.verticalCenter: parent.verticalCenter
            checked: Tailscale.running
            enabled: !Tailscale.busy
            accessibleName: "Tailscale"
            onToggled: value => Tailscale.setRunning(value)
        }
    }

    // This machine
    Rectangle {
        visible: Tailscale.running
        width: parent.width - 4
        x: 2
        height: Theme.panelTileHeight
        radius: Theme.rowRadius
        color: Theme.chip

        Row {
            anchors.verticalCenter: parent.verticalCenter
            x: 10
            spacing: 10

            Item {
                anchors.verticalCenter: parent.verticalCenter
                width: 18
                height: 18

                BrandIcon {
                    anchors.centerIn: parent
                    width: 13
                    height: 13
                    name: "tailscale"
                }
            }

            Column {
                anchors.verticalCenter: parent.verticalCenter
                width: root.width - 90
                spacing: 1

                Text {
                    width: parent.width
                    text: Tailscale.host + (Tailscale.net !== "" ? " · " + Tailscale.net : "")
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.primary
                    font.weight: Theme.weightMedium
                    color: Theme.textHi
                    elide: Text.ElideRight
                }

                Text {
                    width: parent.width
                    text: root.copiedIp === Tailscale.ip && Tailscale.ip !== ""
                        ? "Copied " + Tailscale.ip
                        : "Connected · " + Tailscale.ip + (Tailscale.exitNode ? " · exit node active" : "")
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.secondary
                    color: root.copiedIp === Tailscale.ip && Tailscale.ip !== "" ? Theme.accentText : Theme.textLow
                    elide: Text.ElideRight
                }
            }
        }

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: root.copyIp(Tailscale.ip)
        }
    }

    // Off / loading states
    Text {
        visible: !Tailscale.running
        width: parent.width
        topPadding: 14
        bottomPadding: 14
        text: Tailscale.statusText
        wrapMode: Text.WordWrap
        textFormat: Text.PlainText
        horizontalAlignment: Text.AlignHCenter
        font.family: Theme.fontMenu
        font.pixelSize: Theme.typography.secondary
        color: Theme.textDim
    }

    ActionButton {
        visible: !Tailscale.connected
        width: parent.width
        label: Tailscale.needsApproval ? "View approval status"
            : Tailscale.authPending ? "Continue sign-in"
            : Tailscale.needsLogin ? "Sign in" : "Connection details"
        onTriggered: Tailscale.showSetup()
    }

    Text {
        visible: Tailscale.running && !Tailscale.statusKnown
        width: parent.width
        topPadding: 10
        bottomPadding: 10
        text: "Loading peers…"
        horizontalAlignment: Text.AlignHCenter
        font.family: Theme.fontMenu
        font.pixelSize: Theme.typography.secondary
        color: Theme.textDim
    }

    Text {
        visible: Tailscale.running && Tailscale.statusError !== ""
        width: parent.width
        topPadding: 10
        bottomPadding: 10
        text: "Peer list unavailable\n" + Tailscale.statusError
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
        font.family: Theme.fontMenu
        font.pixelSize: Theme.typography.secondary
        color: Theme.redText
    }

    // Peers
    Repeater {
        model: Tailscale.running ? Tailscale.peers.slice(0, 8) : []

        delegate: Rectangle {
            id: peerRow

            required property var modelData

            width: parent.width - 4
            x: 2
            height: Theme.listRowHeight
            radius: Theme.rowRadius
            color: peerMouse.containsMouse ? Theme.hoverFill : "transparent"
            opacity: modelData.online || peerMouse.containsMouse ? 1 : 0.55

            Row {
                anchors.verticalCenter: parent.verticalCenter
                x: 10
                spacing: 10

                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: 7
                    height: 7
                    radius: 4
                    color: peerRow.modelData.online ? Theme.accent : Theme.dotDim
                }

                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: peerRow.modelData.name
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.primary
                    font.weight: peerRow.modelData.online ? Theme.weightMedium : Theme.weightRegular
                    color: peerRow.modelData.online ? Theme.textHi : Theme.textMid
                }

                Text {
                    visible: peerRow.modelData.os !== ""
                    anchors.verticalCenter: parent.verticalCenter
                    text: peerRow.modelData.os
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.secondary
                    color: Theme.textDim
                }

                Rectangle {
                    visible: peerRow.modelData.exit || peerRow.modelData.exitOption
                    anchors.verticalCenter: parent.verticalCenter
                    width: exitText.implicitWidth + 10
                    height: exitText.implicitHeight + 4
                    radius: 4
                    color: Theme.chip

                    Text {
                        id: exitText
                        anchors.centerIn: parent
                        text: peerRow.modelData.exit ? "EXIT" : "exit node"
                        font.family: Theme.fontMenu
                        font.pixelSize: Theme.typography.secondary
                        font.weight: Theme.weightSemibold
                        font.letterSpacing: 0.5
                        color: peerRow.modelData.exit ? Theme.accentText : Theme.textDim
                    }
                }
            }

            Text {
                anchors.right: parent.right
                anchors.rightMargin: 12
                anchors.verticalCenter: parent.verticalCenter
                text: root.copiedIp !== "" && root.copiedIp === peerRow.modelData.ip ? "copied" : peerRow.modelData.ip
                font.family: Theme.fontMono
                font.pixelSize: Theme.typography.secondary
                color: root.copiedIp !== "" && root.copiedIp === peerRow.modelData.ip ? Theme.accentText : Theme.textDim
            }

            MouseArea {
                id: peerMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.copyIp(peerRow.modelData.ip)
            }
        }
    }

    HDivider {
        visible: Tailscale.running
    }

    // Footer
    Item {
        width: parent.width
        height: Theme.listRowHeight

        Text {
            x: 2
            anchors.verticalCenter: parent.verticalCenter
            // Bound against the link rather than left to run under it: the two
            // used to overlap as soon as the face got wider than the one this
            // was measured in.
            width: parent.width - 4 - adminLink.width - 10
            elide: Text.ElideRight
            text: {
                if (!Tailscale.running || !Tailscale.statusKnown)
                    return "click a device to copy its IP";
                // Never count to zero on a failed status run: that is the
                // one thing an empty tailnet is allowed to say.
                if (Tailscale.statusError !== "")
                    return "peer status unavailable";
                const online = Tailscale.peers.filter(p => p.online).length;
                return online + " of " + Tailscale.peers.length + " devices online · click to copy IP";
            }
            font.family: Theme.fontMenu
            font.pixelSize: Theme.typography.metadata
            color: Theme.textFaint
        }

        LinkText {
            id: adminLink
            anchors.right: parent.right
            anchors.rightMargin: 2
            anchors.verticalCenter: parent.verticalCenter
            text: "Admin console"
            onClicked: {
                Quickshell.execDetached(["xdg-open", "https://login.tailscale.com/admin/machines"]);
                Popouts.close();
            }
        }
    }
}
