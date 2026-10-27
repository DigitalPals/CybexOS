pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls as Controls
import "../Common"
import "../Common/UpdatesHelpers.js" as Helpers

// The review of a prepared update: what people recognise first, the rest
// counted, and every detail one disclosure away. Installing stays explicit.
Item {
    id: root

    property var service: Updates
    property bool details: false
    readonly property var review: service.review
    readonly property bool update: service.deployment.changeKind === "update"
    readonly property var cybexos: review.components.find(row => row.id === "cybexos") || null
    readonly property var nixos: review.components.find(row => row.id === "nixos") || null
    readonly property string nixosRelease: nixos ? Helpers.versionParts("nixos", nixos.after).text : ""
    readonly property var notes: Helpers.noteItems(service.deployment.notes || "", 6)
    readonly property string size: Helpers.sizeChange(review.sizeChange)
    readonly property bool onlyTools: review.components.length === 0 && review.apps.length === 0

    function subtitle() {
        if (cybexos && nixosRelease !== "")
            return I18n.format("Cybex OS %1 with the latest NixOS %2 updates", [cybexos.after, nixosRelease]);
        if (cybexos)
            return I18n.format("Cybex OS %1", [cybexos.after]);
        if (nixosRelease !== "")
            return I18n.format("The latest NixOS %1 updates", [nixosRelease]);
        return update ? I18n.tr("Updated apps and system components") : I18n.tr("Changes to your system configuration");
    }

    component SectionTitle: Text {
        width: parent ? parent.width : 0
        topPadding: Theme.scaled(10)
        color: Theme.textDim
        font.family: Theme.fontMenu
        font.pixelSize: Theme.typography.metadata
        font.weight: Theme.weightSemibold
        font.capitalization: Font.AllUppercase
        font.letterSpacing: 0.6
        textFormat: Text.PlainText
    }
    component Chip: Rectangle {
        id: chip
        property string text: ""
        property color ink: Theme.textMid
        property color fill: Theme.chip
        width: chipText.implicitWidth + Theme.scaled(16)
        height: chipText.implicitHeight + Theme.scaled(6)
        radius: height / 2
        color: fill
        Text {
            id: chipText
            anchors.centerIn: parent
            text: chip.text
            color: chip.ink
            font.family: Theme.fontMenu
            font.pixelSize: Theme.typography.metadata
            font.weight: Theme.weightSemibold
            textFormat: Text.PlainText
        }
    }

    Flickable {
        id: flick
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: footer.top
        contentWidth: width
        contentHeight: column.implicitHeight + Theme.scaled(40)
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        Controls.ScrollBar.vertical: Controls.ScrollBar {}

        Column {
            id: column
            x: Theme.scaled(28)
            y: Theme.scaled(24)
            width: flick.width - Theme.scaled(56)
            spacing: Theme.scaled(10)

            Row {
                width: parent.width
                spacing: Theme.scaled(16)
                Rectangle {
                    width: Theme.scaled(56)
                    height: width
                    radius: Theme.scaled(16)
                    color: Theme.chip
                    Sym {
                        anchors.centerIn: parent
                        name: "download"
                        size: Theme.scaled(28)
                        color: Theme.accentText
                    }
                }
                Column {
                    width: parent.width - Theme.scaled(72)
                    spacing: Theme.scaled(4)
                    Text {
                        objectName: "updateTitle"
                        width: parent.width
                        text: root.update ? I18n.tr("An update is ready to install") : I18n.tr("A system change is ready to apply")
                        color: Theme.textHi
                        font.family: Theme.fontMenu
                        font.pixelSize: Theme.typography.heading
                        font.weight: Theme.weightSemibold
                        wrapMode: Text.Wrap
                        textFormat: Text.PlainText
                        Accessible.role: Accessible.Heading
                        Accessible.name: text
                    }
                    Text {
                        width: parent.width
                        text: root.subtitle()
                        color: Theme.textMid
                        font.family: Theme.fontMenu
                        font.pixelSize: Theme.typography.primary
                        wrapMode: Text.Wrap
                        textFormat: Text.PlainText
                    }
                    Flow {
                        width: parent.width
                        topPadding: Theme.scaled(6)
                        spacing: Theme.scaled(6)
                        Chip { text: I18n.tr("Downloaded and checked"); ink: Theme.ok; fill: Theme.okBg }
                        Chip { text: I18n.tr("Restart required"); ink: Theme.amber; fill: Theme.amberBg }
                        Chip { visible: root.size !== ""; text: I18n.format("%1 on disk", [root.size]) }
                    }
                }
            }

            SectionTitle {
                visible: root.review.components.length > 0
                text: I18n.tr("Important changes")
            }
            Rectangle {
                visible: root.review.components.length > 0
                width: parent.width
                height: components.implicitHeight
                radius: Theme.chipRadius + 3
                color: Theme.cardFill
                border.width: 1
                border.color: Theme.hairlineSoft
                Column {
                    id: components
                    width: parent.width
                    Repeater {
                        model: root.review.components
                        delegate: ChangeRow {
                            id: componentRow
                            required property var modelData
                            required property int index
                            readonly property var info: Helpers.component(modelData.id)
                            // Within one NixOS release only the build date moves; the
                            // title names the release and the versions read as dates.
                            readonly property bool sameRelease: modelData.id === "nixos"
                                && Helpers.versionParts("nixos", modelData.before).text === root.nixosRelease
                            objectName: "updateComponent"
                            width: components.width
                            divider: index > 0
                            glyph: info.glyph
                            title: sameRelease ? I18n.format("NixOS %1", [root.nixosRelease]) : I18n.tr(info.label)
                            detail: I18n.tr(info.detail)
                            component: sameRelease ? "date" : modelData.id
                            before: sameRelease ? Helpers.versionParts("nixos", modelData.before).date.replace(/-/g, "") : modelData.before
                            after: sameRelease ? Helpers.versionParts("nixos", modelData.after).date.replace(/-/g, "") : modelData.after
                        }
                    }
                }
            }

            SectionTitle {
                visible: root.review.apps.length > 0
                text: I18n.format("Apps · %1", [root.review.apps.length])
            }
            Grid {
                id: apps
                visible: root.review.apps.length > 0
                width: parent.width
                columns: width > Theme.scaled(560) ? 2 : 1
                columnSpacing: Theme.scaled(8)
                rowSpacing: Theme.scaled(8)
                Repeater {
                    model: root.review.apps
                    delegate: AppTile {
                        required property var modelData
                        objectName: "updateApp"
                        width: (apps.width - apps.columnSpacing * (apps.columns - 1)) / apps.columns
                        app: modelData
                    }
                }
            }

            // A change without recognisable components or apps (a personal
            // command-line package) is listed here rather than hidden.
            SectionTitle {
                visible: root.onlyTools && root.review.tools.length > 0
                text: I18n.format("Programs · %1", [root.review.tools.length])
            }
            Rectangle {
                visible: root.onlyTools && root.review.tools.length > 0
                width: parent.width
                height: tools.implicitHeight
                radius: Theme.chipRadius + 3
                color: Theme.cardFill
                border.width: 1
                border.color: Theme.hairlineSoft
                Column {
                    id: tools
                    width: parent.width
                    Repeater {
                        model: root.onlyTools ? root.review.tools.slice(0, 20) : []
                        delegate: ChangeRow {
                            required property var modelData
                            required property int index
                            objectName: "updatePackageChange"
                            width: tools.width
                            divider: index > 0
                            glyph: "terminal-2"
                            title: modelData.name
                            before: modelData.before
                            after: modelData.after
                            kind: modelData.kind
                        }
                    }
                }
            }

            SectionTitle {
                visible: root.notes.items.length > 0
                text: root.cybexos ? I18n.format("What's new in Cybex OS %1", [root.cybexos.after]) : I18n.tr("What's new")
            }
            Rectangle {
                visible: root.notes.items.length > 0
                width: parent.width
                height: notesColumn.implicitHeight + Theme.scaled(24)
                radius: Theme.chipRadius + 3
                color: Theme.cardFill
                border.width: 1
                border.color: Theme.hairlineSoft
                Column {
                    id: notesColumn
                    x: Theme.scaled(14)
                    y: Theme.scaled(12)
                    width: parent.width - Theme.scaled(28)
                    spacing: Theme.scaled(4)
                    Repeater {
                        model: root.notes.items
                        delegate: Text {
                            required property string modelData
                            width: notesColumn.width
                            text: "•  " + modelData
                            color: Theme.textMid
                            font.family: Theme.fontMenu
                            font.pixelSize: Theme.typography.secondary
                            wrapMode: Text.Wrap
                            textFormat: Text.PlainText
                        }
                    }
                    Text {
                        visible: root.notes.more
                        text: I18n.tr("More changes are listed in the full release notes.")
                        color: Theme.textDim
                        font.family: Theme.fontMenu
                        font.pixelSize: Theme.typography.secondary
                        textFormat: Text.PlainText
                    }
                }
            }

            Item { width: 1; height: Theme.scaled(4) }

            Rectangle {
                id: disclosure
                objectName: "updateDetailsToggle"
                width: parent.width
                height: disclosureText.implicitHeight + Theme.scaled(22)
                radius: Theme.chipRadius + 3
                color: "transparent"
                border.width: 1
                border.color: Theme.hairline
                activeFocusOnTab: true
                Accessible.role: Accessible.Button
                Accessible.name: disclosureText.text
                Keys.onPressed: event => {
                    if ([Qt.Key_Return, Qt.Key_Enter, Qt.Key_Space].includes(event.key)) {
                        root.details = !root.details;
                        event.accepted = true;
                    }
                }
                StateLayer {
                    anchors.fill: parent
                    radius: parent.radius
                    hovered: disclosureMouse.containsMouse
                    pressed: disclosureMouse.pressed
                    focused: disclosure.activeFocus
                }
                Sym {
                    id: disclosureGlyph
                    anchors.left: parent.left
                    anchors.leftMargin: Theme.scaled(14)
                    anchors.verticalCenter: parent.verticalCenter
                    name: "list-details"
                    size: Theme.iconMedium
                    color: Theme.textMid
                }
                Text {
                    id: disclosureText
                    anchors.left: disclosureGlyph.right
                    anchors.leftMargin: Theme.scaled(10)
                    anchors.right: chevron.left
                    anchors.rightMargin: Theme.scaled(10)
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.review.background > 0
                        ? I18n.format("%1 background components are also updated", [root.review.background])
                        : I18n.tr("Technical details")
                    color: Theme.textMid
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.primary
                    wrapMode: Text.Wrap
                    textFormat: Text.PlainText
                }
                Sym {
                    id: chevron
                    anchors.right: parent.right
                    anchors.rightMargin: Theme.scaled(14)
                    anchors.verticalCenter: parent.verticalCenter
                    name: root.details ? "chevron-down" : "chevron-right"
                    size: Theme.iconMedium
                    color: Theme.textDim
                }
                MouseArea {
                    id: disclosureMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.details = !root.details
                }
            }

            TechnicalDetails {
                visible: root.details
                width: parent.width
                service: root.service
            }
        }
    }

    Rectangle {
        id: footer
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: footerRow.implicitHeight + Theme.scaled(28)
        color: Theme.surfaceMenu

        Rectangle {
            anchors.top: parent.top
            width: parent.width
            height: 1
            color: Theme.hairlineSoft
        }

        Row {
            id: footerRow
            x: Theme.scaled(28)
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - Theme.scaled(56)
            spacing: Theme.scaled(12)

            Sym {
                id: keepGlyph
                anchors.verticalCenter: parent.verticalCenter
                name: "arrow-back-up"
                size: Theme.iconMedium
                color: Theme.ok
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - keepGlyph.width - later.width - install.width - parent.spacing * 3
                objectName: "updateRequestError"
                text: root.service.requestFailure !== "" ? root.service.requestFailure
                    : I18n.tr("Your current version is kept. If the update doesn't start properly, your computer returns to it.")
                color: root.service.requestFailure !== "" ? Theme.redText : Theme.textDim
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.secondary
                wrapMode: Text.Wrap
                maximumLineCount: 3
                elide: Text.ElideRight
                textFormat: Text.PlainText
            }
            UpdateButton {
                id: later
                anchors.verticalCenter: parent.verticalCenter
                text: I18n.tr("Later")
                onTriggered: root.service.close()
            }
            UpdateButton {
                id: install
                objectName: "updatePrimary"
                anchors.verticalCenter: parent.verticalCenter
                primary: true
                glyph: "lock"
                enabled: root.service.actions.apply && !root.service.requestPending
                text: root.service.requestPending ? I18n.tr("Waiting for authorization…")
                    : root.update ? I18n.tr("Install Update") : I18n.tr("Apply Change")
                onTriggered: root.service.apply()
            }
        }
    }
}
