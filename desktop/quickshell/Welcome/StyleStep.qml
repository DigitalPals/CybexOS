pragma ComponentBehavior: Bound
import QtQuick
import "../Common"

// Style, laid out like the installer's account screen: the choices as
// installer cards and rows on the left, and on the right a preview drawn
// with the desktop's live theme, so every choice shows as it is made.
Item {
    id: root
    readonly property var accents: [Settings.defaults.accent, "#9ecbeb", "#a992e0", "#79b88b", "#d3b47e", "#e8837a"]
    // Where the accent comes from: the wallpaper, an unmodified theme, or
    // a colour of the person's own.
    readonly property string source: Settings.paletteMode === "wallpaper" ? "wallpaper"
        : Themes.current.value !== "" && !Themes.current.modified ? "theme" : "accent"
    // One name per family ("Catppuccin", not each flavour).
    readonly property var themeNames: Themes.entries.filter(entry => entry.id !== "cybexos")
        .map(entry => String(entry.name).split(" ")[0])
        .filter((name, index, names) => names.indexOf(name) === index)
    Component.onCompleted: { if (!Themes.loaded) Themes.refresh(); }

    component Option: Item {
        id: option
        property string value: ""
        property string glyph: ""
        property string title: ""
        default property alias body: bodySlot.data
        signal chosen()
        width: parent ? parent.width : 0
        height: Math.max(Kiosk.px(64), texts.implicitHeight + Kiosk.px(28))
        activeFocusOnTab: true
        Accessible.role: Accessible.RadioButton
        Accessible.name: title
        Accessible.checkable: true
        Accessible.checked: root.source === value
        Accessible.onPressAction: option.chosen()
        Keys.onPressed: event => {
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                if (!event.isAutoRepeat) option.chosen();
                event.accepted = true;
            }
        }
        Rectangle {
            anchors.fill: parent
            anchors.margins: Kiosk.px(2)
            radius: Kiosk.px(14)
            color: "transparent"
            border.width: Math.max(1, Kiosk.px(2))
            border.color: Kiosk.accent
            visible: option.activeFocus
        }
        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: option.chosen() }
        KioskIcon {
            id: glyphIcon
            x: Kiosk.px(20)
            anchors.verticalCenter: parent.verticalCenter
            name: option.glyph
            designSize: 22
        }
        Column {
            id: texts
            anchors.left: glyphIcon.right
            anchors.leftMargin: Kiosk.px(16)
            anchors.right: radio.left
            anchors.rightMargin: Kiosk.px(12)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Kiosk.px(2)
            KioskText {
                width: parent.width
                text: option.title
                size: 17
                font.weight: Font.DemiBold
                elide: Text.ElideRight
            }
            Item {
                id: bodySlot
                width: parent.width
                height: childrenRect.height
            }
        }
        KioskRadio {
            id: radio
            anchors.right: parent.right
            anchors.rightMargin: Kiosk.px(20)
            anchors.verticalCenter: parent.verticalCenter
            checked: root.source === option.value
        }
    }

    Column {
        id: heading
        x: Kiosk.px(64)
        y: Kiosk.px(34)
        width: parent.width - Kiosk.px(128)
        spacing: Kiosk.px(8)
        KioskText {
            width: parent.width
            text: I18n.tr("Make it feel like home.")
            size: 40
            font.weight: Font.Bold
            font.letterSpacing: -Kiosk.px(1)
            elide: Text.ElideRight
            Accessible.role: Accessible.Heading
        }
        KioskText {
            width: parent.width
            text: I18n.tr("Light or dark, your colours and comfortable text. Your desktop changes as you choose.")
            size: 19
            tone: "fog"
            elide: Text.ElideRight
        }
    }

    Column {
        id: controls
        x: Kiosk.px(64)
        anchors.top: heading.bottom
        anchors.topMargin: Kiosk.px(22)
        width: parent.width - Kiosk.px(128) - preview.width - Kiosk.px(44)
        KioskKicker { text: I18n.tr("Appearance"); bottomPadding: Kiosk.px(8) }
        Row {
            width: parent.width
            spacing: Kiosk.px(12)
            Repeater {
                model: [{value: "dark", label: I18n.tr("Dark")}, {value: "light", label: I18n.tr("Light")}]
                delegate: Rectangle {
                    id: mode
                    required property var modelData
                    readonly property bool chosen: Settings.themeMode === modelData.value
                    width: (controls.width - Kiosk.px(12)) / 2
                    height: Kiosk.px(72)
                    radius: Kiosk.px(16)
                    color: Kiosk.card
                    border.width: Math.max(1, Kiosk.px(1.5))
                    border.color: chosen ? Kiosk.accent : modeMouse.containsMouse ? Kiosk.line2 : Kiosk.line
                    activeFocusOnTab: true
                    Accessible.role: Accessible.RadioButton
                    Accessible.name: modelData.label
                    Accessible.checkable: true
                    Accessible.checked: chosen
                    Accessible.onPressAction: Settings.set("themeMode", modelData.value)
                    Keys.onPressed: event => {
                        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                            Settings.set("themeMode", mode.modelData.value);
                            event.accepted = true;
                        }
                    }
                    Rectangle {
                        visible: mode.chosen
                        anchors.fill: parent
                        anchors.margins: -Kiosk.px(3)
                        radius: parent.radius + Kiosk.px(3)
                        color: "transparent"
                        border.width: Kiosk.px(3)
                        border.color: Kiosk.accentRing
                    }
                    KioskFocusRing { visible: mode.activeFocus; baseRadius: mode.radius }
                    Rectangle {
                        id: swatch
                        x: Kiosk.px(16)
                        anchors.verticalCenter: parent.verticalCenter
                        width: Kiosk.px(56)
                        height: Kiosk.px(38)
                        radius: Kiosk.px(8)
                        clip: true
                        color: mode.modelData.value === "dark" ? "#1a1b1e" : "#f3f2ec"
                        border.width: Math.max(1, Kiosk.px(1))
                        border.color: Kiosk.line2
                        Rectangle { width: parent.width; height: Kiosk.px(7); color: "#597f7f7f" }
                        Rectangle { x: Kiosk.px(8); y: Kiosk.px(13); width: Kiosk.px(28); height: Kiosk.px(18); radius: Kiosk.px(4); color: "#597f7f7f" }
                    }
                    KioskText {
                        anchors.left: swatch.right
                        anchors.leftMargin: Kiosk.px(14)
                        anchors.right: modeRadio.left
                        anchors.verticalCenter: parent.verticalCenter
                        text: mode.modelData.label
                        size: 17
                        font.weight: Font.DemiBold
                        elide: Text.ElideRight
                    }
                    KioskRadio {
                        id: modeRadio
                        anchors.right: parent.right
                        anchors.rightMargin: Kiosk.px(16)
                        anchors.verticalCenter: parent.verticalCenter
                        checked: mode.chosen
                    }
                    MouseArea {
                        id: modeMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: Settings.set("themeMode", mode.modelData.value)
                    }
                }
            }
        }
        KioskKicker { text: I18n.tr("Colours"); topPadding: Kiosk.px(20); bottomPadding: Kiosk.px(8) }
        KioskCard {
            width: parent.width
            height: options.implicitHeight
            Column {
                id: options
                width: parent.width
                Option {
                    value: "wallpaper"
                    glyph: "image"
                    title: I18n.tr("From your wallpaper")
                    onChosen: Settings.set("paletteMode", "wallpaper")
                    WallpaperSwatches {
                        visible: Settings.paletteMode === "wallpaper"
                        size: 22
                    }
                    KioskText {
                        visible: Settings.paletteMode !== "wallpaper"
                        width: parent.width
                        text: I18n.tr("Colours picked from the picture you chose")
                        size: 14
                        tone: "fog"
                        elide: Text.ElideRight
                    }
                }
                Rectangle { width: parent.width; height: Math.max(1, Kiosk.px(1)); color: Kiosk.line }
                Option {
                    value: "theme"
                    glyph: "palette"
                    title: I18n.tr("A Cybex OS theme")
                    onChosen: Welcome.openSheet("theme")
                    KioskText {
                        width: parent.width
                        text: root.source === "theme" ? Themes.current.label
                            : root.themeNames.length > 3 ? I18n.format("%1 and more", [root.themeNames.slice(0, 3).join(", ")])
                            : root.themeNames.join(", ")
                        size: 14
                        tone: "fog"
                        elide: Text.ElideRight
                    }
                }
                Rectangle { width: parent.width; height: Math.max(1, Kiosk.px(1)); color: Kiosk.line }
                Option {
                    value: "accent"
                    glyph: "circle-dot"
                    title: I18n.tr("One accent colour")
                    onChosen: Settings.set("paletteMode", "fixed")
                    Row {
                        spacing: Kiosk.px(8)
                        topPadding: Kiosk.px(4)
                        Repeater {
                            model: root.accents
                            delegate: Rectangle {
                                id: accent
                                required property string modelData
                                readonly property bool chosen: root.source === "accent" && Settings.accent === modelData
                                width: Kiosk.px(22)
                                height: width
                                radius: width / 2
                                color: modelData
                                border.width: chosen ? Kiosk.px(2) : Math.max(1, Kiosk.px(1))
                                border.color: chosen ? Kiosk.card : "#24ffffff"
                                activeFocusOnTab: true
                                Accessible.role: Accessible.RadioButton
                                Accessible.name: I18n.format("Use accent %1", [modelData])
                                Accessible.checkable: true
                                Accessible.checked: chosen
                                Accessible.onPressAction: accent.use()
                                function use() {
                                    Settings.set("paletteMode", "fixed");
                                    Settings.set("accent", accent.modelData);
                                }
                                Keys.onPressed: event => {
                                    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                                        accent.use();
                                        event.accepted = true;
                                    }
                                }
                                Rectangle {
                                    visible: accent.chosen || accent.activeFocus
                                    anchors.fill: parent
                                    anchors.margins: -Kiosk.px(2)
                                    radius: width / 2
                                    color: "transparent"
                                    border.width: Math.max(1, Kiosk.px(2))
                                    border.color: accent.activeFocus ? Kiosk.accent : Kiosk.ink
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    anchors.margins: -Kiosk.px(3)
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: accent.use()
                                }
                            }
                        }
                    }
                }
            }
        }
        Row {
            topPadding: Kiosk.px(20)
            spacing: Kiosk.px(24)
            Column {
                KioskKicker { text: I18n.tr("Text size"); bottomPadding: Kiosk.px(8) }
                KioskSegmented {
                    label: I18n.tr("Text size")
                    model: [{value: "default", label: I18n.tr("Default")}, {value: "large", label: I18n.tr("Large")},
                        {value: "larger", label: I18n.tr("Larger")}]
                    current: Settings.textScale
                    onPicked: value => Settings.set("textScale", value)
                }
            }
            Column {
                KioskKicker { text: I18n.tr("Glass"); bottomPadding: Kiosk.px(8) }
                Item {
                    width: glass.width
                    height: Kiosk.px(46)
                    KioskToggle {
                        id: glass
                        anchors.verticalCenter: parent.verticalCenter
                        label: I18n.tr("Glass effect")
                        checked: Settings.glassEnabled && !Settings.highContrast
                        enabled: !Settings.highContrast
                        onToggled: Settings.set("glassEnabled", !Settings.glassEnabled)
                    }
                }
            }
        }
    }

    Column {
        id: preview
        anchors.right: parent.right
        anchors.rightMargin: Kiosk.px(64)
        anchors.top: controls.top
        width: Kiosk.px(554)
        Item {
            width: parent.width
            height: Kiosk.px(26)
            KioskKicker { anchors.left: parent.left; text: I18n.tr("Preview") }
            KioskText { anchors.right: parent.right; text: I18n.tr("live · your real settings"); mono: true; size: 12; tone: "faint" }
        }
        DesktopPreview {
            width: parent.width
            height: Math.round(width * 10 / 16)
            detailed: true
        }
        Row {
            topPadding: Kiosk.px(14)
            spacing: Kiosk.px(8)
            KioskKeycap { anchors.verticalCenter: parent.verticalCenter; small: true; text: I18n.tr("Spacebar") }
            KioskText { anchors.verticalCenter: parent.verticalCenter; text: I18n.tr("Hold to look at your desktop"); size: 14; tone: "faint" }
        }
        KioskText {
            width: parent.width
            topPadding: Kiosk.px(8)
            visible: text !== ""
            wrapMode: Text.WordWrap
            text: Settings.highContrast ? I18n.tr("Glass is off while High contrast is on.") : Themes.error
            size: 13.5
            tone: Settings.highContrast ? "faint" : "red"
        }
    }

    KioskFooter {
        anchors.bottom: parent.bottom
        width: parent.width
        onNext: Welcome.move(1)
        KioskText {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width
            text: Welcome.error !== "" ? Welcome.error : I18n.tr("You will find all of this again in Settings, under Appearance.")
            size: 14
            tone: Welcome.error !== "" ? "red" : "faint"
            elide: Text.ElideRight
        }
    }
}
