import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

ApplicationWindow {
    id: window
    width: 920
    height: 620
    minimumWidth: 740
    minimumHeight: 560
    visible: true
    title: "Welcome to CybexOS"
    color: "#0d0d0d"
    font.family: "Figtree"
    font.pixelSize: 16
    palette.windowText: "#e8e7df"
    palette.text: "#e8e7df"
    palette.buttonText: "#e8e7df"
    palette.button: "#333122"
    palette.highlight: "#d3d283"
    onClosing: close => { if (welcome.busy) close.accepted = false; }

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
        implicitHeight: 50
        leftPadding: 22
        rightPadding: 22
        font.weight: Font.DemiBold
        background: Rectangle {
            radius: 12
            color: button.primary ? (button.down ? "#bbb96e" : "#d3d283")
                : (button.hovered ? "#44412b" : "#333122")
            opacity: button.enabled ? 1 : 0.5
            border.width: button.activeFocus ? 2 : 0
            border.color: "#ffffff"
        }
        contentItem: Text {
            text: button.text
            color: button.primary ? "#27260c" : "#e8e7df"
            font: button.font
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
        }
    }

    RowLayout {
        anchors.fill: parent
        spacing: 0
        Rectangle {
            Layout.preferredWidth: window.width * 0.32
            Layout.fillHeight: true
            color: "#232217"
            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 32
                spacing: 22
                Text { text: "CybexOS"; color: "#c5c2ac"; font.pixelSize: 13; font.letterSpacing: 2 }
                Item { Layout.fillHeight: true }
                Rectangle {
                    width: 94; height: 94; radius: 26; color: "#d3d283"
                    Text { anchors.centerIn: parent; text: "Cx"; color: "#34320d"; font.pixelSize: 48; font.weight: Font.DemiBold }
                }
                Text {
                    Layout.fillWidth: true
                    text: "A little less friction.\nA lot more you."
                    wrapMode: Text.WordWrap
                    color: "#e8e7df"; font.pixelSize: 28; font.weight: Font.DemiBold
                }
                Text {
                    Layout.fillWidth: true
                    text: "Cybex Opinionated System.\nA focused desktop, built on Fedora."
                    wrapMode: Text.WordWrap; color: "#b7b5a7"; lineHeight: 1.3
                }
                Item { Layout.fillHeight: true }
                Text { text: welcome.isLive ? "LIVE PREVIEW  /  ALPHA" : "YOUR DESKTOP"; color: "#aaa790"; font.pixelSize: 11; font.letterSpacing: 1 }
            }
        }
        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.margins: 38
            spacing: 18
            Item { Layout.preferredHeight: 12 }
            Text {
                Layout.fillWidth: true
                text: welcome.isLive ? "Make yourself at home." : "Welcome to your new desktop."
                color: "#e8e7df"; font.pixelSize: 34; font.weight: Font.DemiBold; wrapMode: Text.WordWrap
            }
            Text {
                Layout.fillWidth: true
                text: welcome.isLive
                    ? "Explore the desktop from your USB drive, or install it when you’re ready."
                    : "Start with a few personal touches. You can return to this window from the app launcher."
                color: "#b7b5a7"; wrapMode: Text.WordWrap; lineHeight: 1.4
            }
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: details.implicitHeight + 40
                radius: 16; color: "#232217"
                ColumnLayout {
                    id: details
                    anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
                    anchors.margins: 20; spacing: 14
                    Text {
                        text: welcome.isLive ? "A guided installation" : "Make it yours"
                        color: "#e8e7df"; font.weight: Font.DemiBold
                    }
                    Text {
                        Layout.fillWidth: true
                        text: welcome.isLive
                            ? "Create your account, choose a disk, and review. Encryption and automatic login are selected by default."
                            : "Choose your colors and wallpaper, then discover the keyboard shortcuts. Your app keyring stays encrypted and unlocks with the disk password when they match; otherwise an app will ask for its password."
                        color: "#b7b5a7"; wrapMode: Text.WordWrap; lineHeight: 1.3
                    }
                    Text {
                        visible: welcome.isLive; Layout.fillWidth: true
                        text: "Your disk and account passwords start out the same. Changing the account password later does not update the disk password."
                        color: "#d3d283"; wrapMode: Text.WordWrap; font.pixelSize: 14
                    }
                }
            }
            Text {
                Layout.fillWidth: true
                visible: welcome.status.length > 0
                text: welcome.status
                color: "#d9d4af"; wrapMode: Text.WordWrap; font.pixelSize: 14
                Accessible.role: Accessible.AlertMessage
            }
            Item { Layout.fillHeight: true }
            // Wraps at the minimum window width rather than letting the
            // third button run past the edge.
            Flow {
                Layout.fillWidth: true
                spacing: 12
                ActionButton {
                    primary: true
                    text: welcome.isLive ? (welcome.busy ? "Installer is open…" : "Install CybexOS") : "Personalize"
                    enabled: !welcome.busy
                    onClicked: welcome.isLive ? welcome.install() : welcome.openSettings("appearance")
                }
                ActionButton {
                    visible: !welcome.isLive
                    text: "Find a wallpaper"
                    onClicked: welcome.openSettings("wallpaper")
                }
                ActionButton {
                    visible: !welcome.isLive
                    text: "Shortcuts"
                    onClicked: welcome.openSettings("shortcuts")
                }
            }
            Button {
                text: welcome.isLive ? "Try the desktop first →" : "Start using my desktop →"
                enabled: !welcome.busy
                flat: true
                onClicked: welcome.finish()
            }
        }
    }
}
