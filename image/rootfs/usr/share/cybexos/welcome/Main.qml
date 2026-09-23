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
    color: "#101719"
    font.family: "Figtree"
    font.pixelSize: 16
    palette.windowText: "#edf5f2"
    palette.text: "#edf5f2"
    palette.buttonText: "#edf5f2"
    palette.button: "#243431"
    palette.highlight: "#a9e7cf"
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
            color: button.primary ? (button.down ? "#80c9af" : "#a9e7cf")
                : (button.hovered ? "#334943" : "#243431")
            opacity: button.enabled ? 1 : 0.5
            border.width: button.activeFocus ? 2 : 0
            border.color: "#ffffff"
        }
        contentItem: Text {
            text: button.text
            color: button.primary ? "#142c24" : "#edf5f2"
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
            color: "#192a25"
            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 32
                spacing: 22
                Text { text: "CybexOS"; color: "#b4c8bf"; font.pixelSize: 13; font.letterSpacing: 2 }
                Item { Layout.fillHeight: true }
                Rectangle {
                    width: 94; height: 94; radius: 26; color: "#a9e7cf"
                    Text { anchors.centerIn: parent; text: "Cx"; color: "#183c2d"; font.pixelSize: 48; font.weight: Font.DemiBold }
                }
                Text {
                    Layout.fillWidth: true
                    text: "A little less friction.\nA lot more you."
                    wrapMode: Text.WordWrap
                    color: "#edf5f2"; font.pixelSize: 28; font.weight: Font.DemiBold
                }
                Text {
                    Layout.fillWidth: true
                    text: "Cybex Opinionated System.\nA focused desktop, built on Fedora."
                    wrapMode: Text.WordWrap; color: "#afc7bb"; lineHeight: 1.3
                }
                Item { Layout.fillHeight: true }
                Text { text: welcome.isLive ? "LIVE PREVIEW  /  ALPHA" : "YOUR DESKTOP"; color: "#a3b9ae"; font.pixelSize: 11; font.letterSpacing: 1 }
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
                color: "#edf5f2"; font.pixelSize: 34; font.weight: Font.DemiBold; wrapMode: Text.WordWrap
            }
            Text {
                Layout.fillWidth: true
                text: welcome.isLive
                    ? "Explore the desktop from your USB drive, or install it when you’re ready."
                    : "Start with a few personal touches. You can return to this window from the app launcher."
                color: "#a9bbb4"; wrapMode: Text.WordWrap; lineHeight: 1.4
            }
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: details.implicitHeight + 40
                radius: 16; color: "#1b2724"
                ColumnLayout {
                    id: details
                    anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
                    anchors.margins: 20; spacing: 14
                    Text {
                        text: welcome.isLive ? "A guided installation" : "Make it yours"
                        color: "#dcebe4"; font.weight: Font.DemiBold
                    }
                    Text {
                        Layout.fillWidth: true
                        text: welcome.isLive
                            ? "Choose your language and disk, then review your storage and encryption options in the installer."
                            : "Choose your colors and wallpaper, then discover the keyboard shortcuts that keep everything within reach."
                        color: "#a9bbb4"; wrapMode: Text.WordWrap; lineHeight: 1.3
                    }
                    Text {
                        visible: welcome.isLive; Layout.fillWidth: true
                        text: "The desktop and all included applications install without an internet connection."
                        color: "#a9e7cf"; wrapMode: Text.WordWrap; font.pixelSize: 14
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
            RowLayout {
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
