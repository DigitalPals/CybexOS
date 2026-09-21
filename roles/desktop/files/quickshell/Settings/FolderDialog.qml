pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls as Controls
import Qt.labs.folderlistmodel
import Quickshell
import "../Common"

// An in-surface folder picker. Popup.Item keeps it inside the layer-shell
// window, avoiding a native dialog that cannot reliably take focus there.
Controls.Dialog {
    id: root

    signal folderChosen(string path)
    property string selectedPath: ""

    parent: Controls.Overlay.overlay
    anchors.centerIn: parent
    width: Math.min(520, parent ? parent.width - 24 : 520)
    height: Math.min(430, parent ? parent.height - 24 : 430)
    modal: true
    focus: true
    popupType: Controls.Popup.Item
    title: "Choose wallpaper folder"
    standardButtons: Controls.Dialog.Cancel | Controls.Dialog.Open
    closePolicy: Controls.Popup.CloseOnEscape

    function localPath(url) {
        let text = url.toString();
        if (text.indexOf("file://") === 0)
            text = decodeURIComponent(text.slice(7));
        return text;
    }

    function openAt(path) {
        selectedPath = "";
        const expanded = path === "~" ? Quickshell.env("HOME")
            : path.indexOf("~/") === 0 ? Quickshell.env("HOME") + path.slice(1) : path;
        folderModel.folder = "file://" + expanded;
        open();
    }

    function focusFolder(index) {
        const clamped = Math.max(0, Math.min(folderList.count - 1, index));
        folderList.currentIndex = clamped;
        folderList.positionViewAtIndex(clamped, ListView.Contain);
        Qt.callLater(() => {
            if (folderList.currentItem)
                folderList.currentItem.forceActiveFocus();
        });
    }

    onAccepted: {
        const chosen = selectedPath !== "" ? selectedPath : localPath(folderModel.folder);
        folderChosen(chosen.indexOf(Quickshell.env("HOME") + "/") === 0
            ? "~" + chosen.slice(Quickshell.env("HOME").length) : chosen);
    }

    background: Rectangle {
        radius: Theme.popRadius
        color: Theme.surfaceMenu
        border.width: 1
        border.color: Theme.popBorder
    }

    header: Item {
        implicitHeight: 54

        Text {
            anchors.left: parent.left
            anchors.leftMargin: 14
            anchors.right: parent.right
            anchors.rightMargin: 14
            anchors.verticalCenter: parent.verticalCenter
            text: root.localPath(folderModel.folder)
            elide: Text.ElideMiddle
            font.family: Theme.fontMono
            font.pixelSize: Theme.typography.navigation
            color: Theme.textMid
        }
    }

    contentItem: Column {
        spacing: 6

        Rectangle {
            width: parent.width
            height: 34
            radius: Theme.rowRadius
            color: upMouse.containsMouse || activeFocus ? Theme.hoverFill : "transparent"
            activeFocusOnTab: true
            Accessible.role: Accessible.Button
            Accessible.name: "Parent folder"
            Accessible.onPressAction: folderModel.folder = folderModel.parentFolder

            Keys.onPressed: event => {
                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                        || event.key === Qt.Key_Space) {
                    folderModel.folder = folderModel.parentFolder;
                    event.accepted = true;
                }
            }

            Text {
                anchors.left: parent.left
                anchors.leftMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                text: "arrow_upward  Parent folder"
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.navigation
                color: Theme.textMid
            }

            MouseArea {
                id: upMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: folderModel.folder = folderModel.parentFolder
            }
        }

        Item {
            width: parent.width
            height: parent.height - 40

            ListView {
                id: folderList
                anchors.fill: parent
                clip: true
                spacing: 2
                currentIndex: 0
                model: FolderListModel {
                    id: folderModel
                    showDirs: true
                    showFiles: false
                    showDirsFirst: true
                    sortField: FolderListModel.Name
                }

                delegate: Rectangle {
                    id: folderRow
                    required property string fileName
                    required property url fileUrl
                    required property int index
                    readonly property string path: root.localPath(fileUrl)
                    readonly property bool selected: root.selectedPath === path

                    width: folderList.width
                    height: 34
                    radius: Theme.rowRadius
                    color: selected ? Theme.chipHover
                        : rowMouse.containsMouse || activeFocus ? Theme.hoverFill : "transparent"
                    activeFocusOnTab: index === folderList.currentIndex
                    Accessible.role: Accessible.ListItem
                    Accessible.name: fileName
                    Accessible.selected: selected
                    Accessible.onPressAction: {
                        root.selectedPath = path;
                        folderList.currentIndex = index;
                    }

                    Keys.onPressed: event => {
                        if (event.key === Qt.Key_Up) {
                            root.focusFolder(index - 1);
                            event.accepted = true;
                        } else if (event.key === Qt.Key_Down) {
                            root.focusFolder(index + 1);
                            event.accepted = true;
                        } else if (event.key === Qt.Key_Home) {
                            root.focusFolder(0);
                            event.accepted = true;
                        } else if (event.key === Qt.Key_End) {
                            root.focusFolder(folderList.count - 1);
                            event.accepted = true;
                        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                            folderModel.folder = fileUrl;
                            root.selectedPath = "";
                            event.accepted = true;
                        } else if (event.key === Qt.Key_Space) {
                            root.selectedPath = path;
                            event.accepted = true;
                        }
                    }

                    Text {
                        anchors.left: parent.left
                        anchors.leftMargin: 10
                        anchors.verticalCenter: parent.verticalCenter
                        text: "folder  " + folderRow.fileName
                        font.family: Theme.fontMenu
                        font.pixelSize: Theme.typography.navigation
                        color: folderRow.selected ? Theme.textHi : Theme.textMid
                    }

                    MouseArea {
                        id: rowMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            root.selectedPath = folderRow.path;
                            folderList.currentIndex = folderRow.index;
                            folderRow.forceActiveFocus();
                        }
                        onDoubleClicked: {
                            folderModel.folder = folderRow.fileUrl;
                            root.selectedPath = "";
                        }
                    }
                }
            }

            ScrollChrome {
                anchors.fill: parent
                target: folderList
                edgeColor: Theme.surfaceMenu
            }
        }
    }
}
