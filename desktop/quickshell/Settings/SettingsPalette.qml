pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import "../Common"
import "../Common/SettingsSearchData.js" as SearchData

// The settings palette (2026-10 redesign; "/", Ctrl+K or Ctrl+F): one field
// over the window that finds pages, settings — showing each one's current
// value — and things to do, such as changing the password or running the
// system check. Enter goes to the row and highlights it, as the rail search
// it replaces did; Ctrl+Enter flips a switch where it stands. The index is
// SettingsSearchData: rows, their hidden terms ("dnd", "vrr") and actions.
Item {
    id: root

    property bool open: false
    property int selection: 0
    readonly property string query: field.text.trim()
    readonly property var entries: number(build(query))
    readonly property var choices: entries.filter(entry => entry.kind !== "heading")
    signal finished()

    visible: open
    Accessible.role: Accessible.Dialog
    Accessible.name: I18n.tr("Search settings")

    function show(text) {
        field.text = text || "";
        selection = 0;
        open = true;
        field.forceActiveFocus();
        field.cursorPosition = field.text.length;
    }

    function hide() {
        open = false;
        field.text = "";
        finished();
    }

    function pageEntry(page) {
        return { kind: "page", title: page.label, crumb: page.group ? I18n.tr(page.group) : "",
            glyph: page.glyph, page: page.id, tab: "", key: "", anchor: "" };
    }

    // Each choice carries its position, so a delegate (which holds a copy
    // of its entry) can tell whether it is the selected one.
    function number(list) {
        let next = 0;
        return list.map(entry => entry.kind === "heading" ? entry
            : Object.assign({}, entry, { choice: next++ }));
    }

    function build(text) {
        const q = text.toLowerCase();
        const out = [];
        if (q === "") {
            out.push({ kind: "heading", title: I18n.tr("Pages") });
            for (const page of Settings.pages)
                out.push(pageEntry(page));
            return out;
        }
        const pages = [];
        for (const page of Settings.pages) {
            const words = [page.label, page.description].concat((page.tabs || []).map(tab => tab.label));
            if (words.join(" ").toLowerCase().indexOf(q) !== -1)
                pages.push(pageEntry(page));
        }
        const rows = SearchData.search(q, I18n.tr).slice(0, 8).map(row => ({
            kind: "row", title: I18n.tr(row.label),
            crumb: I18n.tr(row.pageLabel) + " › " + I18n.tr(row.group),
            glyph: Settings.pageInfo(row.page).glyph, page: row.page, tab: row.tab || "",
            key: row.key, anchor: row.anchor || row.key, widget: row.widget || "" }));
        const actions = SearchData.searchActions(q, I18n.tr).slice(0, 4).map(entry => ({
            kind: "action", title: I18n.tr(entry.label), crumb: I18n.tr(entry.crumb), glyph: "bolt",
            action: entry.action, page: entry.page || "", tab: entry.tab || "", anchor: entry.anchor || "" }));
        if (pages.length) {
            out.push({ kind: "heading", title: I18n.tr("Pages") });
            out.push(...pages.slice(0, 3));
        }
        if (rows.length) {
            out.push({ kind: "heading", title: I18n.tr("Settings") });
            out.push(...rows);
        }
        if (actions.length) {
            out.push({ kind: "heading", title: I18n.tr("Actions") });
            out.push(...actions);
        }
        return out;
    }

    // A keyed row's current value as a phrase: booleans by a switch, short
    // values as text, anything structured left unsaid.
    function valueOf(entry) {
        void Settings.revision;
        if (entry.kind !== "row" || !entry.key)
            return undefined;
        return Settings[entry.key];
    }

    function valueText(value) {
        if (value === undefined || value === null || typeof value === "boolean" || typeof value === "object")
            return "";
        const text = String(value);
        if (text.length > 22 || text.startsWith("#"))
            return "";
        return text.charAt(0).toUpperCase() + text.slice(1);
    }

    function go(page, tab) {
        if (tab)
            Settings.setTab(page, tab);
        Settings.page = page;
    }

    function highlight(key) {
        Settings.highlightKey = "";
        Settings.highlightKey = key;
    }

    function activate(entry, toggle) {
        if (!entry)
            return;
        if (toggle) {
            if (entry.kind === "row" && typeof valueOf(entry) === "boolean")
                Settings.set(entry.key, !Settings[entry.key]);
            return;
        }
        hide();
        if (entry.kind === "page") {
            go(entry.page, entry.tab);
            Settings.announcement = entry.title + " page.";
            return;
        }
        if (entry.kind === "row") {
            if (entry.widget)
                Settings.openWidgetSettings(entry.widget);
            else
                go(entry.page, entry.tab);
            highlight(entry.anchor);
            Settings.announcement = entry.crumb + ", " + entry.title + " row.";
            return;
        }
        run(entry);
    }

    function run(entry) {
        if (entry.page)
            go(entry.page, entry.tab);
        if (entry.anchor)
            highlight(entry.anchor);
        switch (entry.action) {
        case "software-update":
            Updates.show();
            break;
        case "system-check":
            Doctor.refresh();
            break;
        case "shuffle-wallpaper":
            Wallpaper.shuffle();
            Settings.announcement = I18n.tr("Shuffled the wallpaper.");
            break;
        case "back-up-now":
            if (Backup.configured && !Backup.running)
                Backup.backupNow();
            break;
        case "welcome":
            Welcome.show("");
            break;
        case "settings-file":
            Settings.saveNow();
            Qt.callLater(() => {
                Settings.closePanel();
                Quickshell.execDetached(["xdg-open", Settings.filePath]);
            });
            break;
        }
    }

    function move(delta) {
        if (choices.length === 0)
            return;
        selection = Math.max(0, Math.min(choices.length - 1, selection + delta));
        const item = results.itemFor(choices[selection]);
        if (item)
            resultsFlick.revealItem(item);
    }

    // Click outside to dismiss: the scrim is not a button, so no hand.
    Rectangle {
        anchors.fill: parent
        color: Theme.scrim
        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.ArrowCursor
            onClicked: root.hide()
        }
    }

    Rectangle {
        id: panel
        x: Math.round((root.width - width) / 2)
        y: Theme.scaled(54)
        width: Math.min(Theme.scaled(600, Theme.typeScale), root.width - Theme.scaled(32))
        height: Math.min(header.height + resultsFlick.contentHeight + footer.height + 2,
            root.height - y - Theme.scaled(24))
        radius: Theme.popRadius
        color: Theme.surfaceMenu
        border.width: 1
        border.color: Theme.hairline
        clip: true
        MouseArea { anchors.fill: parent }

        Item {
            id: header
            width: parent.width
            height: Theme.scaled(50)

            Sym {
                id: glass
                x: Theme.scaled(16)
                anchors.verticalCenter: parent.verticalCenter
                name: "search"
                size: Theme.iconMedium
                color: Theme.textFaint
            }
            TextInput {
                id: field
                anchors.left: glass.right
                anchors.leftMargin: Theme.scaled(10)
                anchors.right: escHint.left
                anchors.rightMargin: Theme.controlSpacing
                anchors.verticalCenter: parent.verticalCenter
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.title
                color: Theme.textHi
                selectionColor: Theme.accentAlpha(0.4)
                selectedTextColor: Theme.textHi
                clip: true
                Accessible.role: Accessible.EditableText
                Accessible.name: I18n.tr("Search settings")
                onTextChanged: root.selection = 0
                Keys.onPressed: event => {
                    if (event.key === Qt.Key_Down) {
                        root.move(1);
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Up) {
                        root.move(-1);
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                        root.activate(root.choices[root.selection], (event.modifiers & Qt.ControlModifier) !== 0);
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Escape) {
                        root.hide();
                        event.accepted = true;
                    }
                }

                Text {
                    visible: field.text === ""
                    anchors.fill: parent
                    verticalAlignment: Text.AlignVCenter
                    text: I18n.tr("Search settings, pages and actions")
                    font: field.font
                    color: Theme.textFaint
                }
            }
            KeyHint {
                id: escHint
                anchors.right: parent.right
                anchors.rightMargin: Theme.scaled(14)
                anchors.verticalCenter: parent.verticalCenter
                text: "Esc" // i18n: untranslated (key name)
            }
            Rectangle {
                anchors.bottom: parent.bottom
                width: parent.width
                height: 1
                color: Theme.hairlineSoft
            }
        }

        Flickable {
            id: resultsFlick
            y: header.height
            width: parent.width
            height: panel.height - header.height - footer.height
            contentHeight: results.implicitHeight + Theme.scaled(12)
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            interactive: contentHeight > height

            function revealItem(item) {
                const top = item.y + results.y;
                if (top < contentY)
                    contentY = top - Theme.scaled(6);
                else if (top + item.height > contentY + height)
                    contentY = top + item.height - height + Theme.scaled(6);
            }

            Column {
                id: results
                x: Theme.scaled(6)
                y: Theme.scaled(6)
                width: parent.width - Theme.scaled(12)

                function itemFor(entry) {
                    const index = root.entries.indexOf(entry);
                    return index < 0 ? null : resultRepeater.itemAt(index);
                }

                Repeater {
                    id: resultRepeater
                    model: root.entries

                    delegate: Item {
                        id: result
                        required property var modelData
                        readonly property bool heading: modelData.kind === "heading"
                        readonly property bool selected: !heading && modelData.choice === root.selection
                        readonly property var value: root.valueOf(modelData)

                        width: results.width
                        height: heading ? Theme.scaled(28) : Theme.scaled(44)
                        Accessible.role: heading ? Accessible.Heading : Accessible.ListItem
                        Accessible.name: heading ? modelData.title : modelData.title + ", " + modelData.crumb
                        Accessible.selected: selected

                        Text {
                            visible: result.heading
                            x: Theme.scaled(10)
                            anchors.bottom: parent.bottom
                            anchors.bottomMargin: Theme.scaled(4)
                            text: result.modelData.title.toUpperCase()
                            font.family: Theme.fontMenu
                            font.pixelSize: Theme.typography.metadata
                            font.weight: Theme.weightSemibold
                            font.letterSpacing: 1
                            color: Theme.textFaint
                        }

                        Rectangle {
                            visible: !result.heading
                            anchors.fill: parent
                            radius: Theme.chipRadius + 1
                            color: result.selected ? Theme.chip
                                : resultMouse.containsMouse ? Theme.hoverFill : "transparent"

                            Rectangle {
                                id: glyphTile
                                x: Theme.scaled(8)
                                anchors.verticalCenter: parent.verticalCenter
                                width: Theme.scaled(28)
                                height: width
                                radius: Theme.chipRadius
                                color: Theme.chip
                                Sym {
                                    anchors.centerIn: parent
                                    name: result.modelData.glyph || "search"
                                    size: Theme.iconSmall
                                    color: result.selected ? Theme.accentText : Theme.icon
                                }
                            }
                            Column {
                                anchors.left: glyphTile.right
                                anchors.leftMargin: Theme.scaled(11)
                                anchors.right: trailing.left
                                anchors.rightMargin: Theme.controlSpacing
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 1
                                Text {
                                    width: parent.width
                                    text: result.modelData.title || ""
                                    elide: Text.ElideRight
                                    font.family: Theme.fontMenu
                                    font.pixelSize: Theme.typography.primary
                                    font.weight: Theme.weightMedium
                                    color: Theme.textHi
                                }
                                Text {
                                    width: parent.width
                                    visible: text !== ""
                                    text: result.modelData.crumb || ""
                                    elide: Text.ElideRight
                                    font.family: Theme.fontMenu
                                    font.pixelSize: Theme.typography.metadata
                                    color: Theme.textFaint
                                }
                            }
                            Item {
                                id: trailing
                                anchors.right: parent.right
                                anchors.rightMargin: Theme.scaled(10)
                                anchors.verticalCenter: parent.verticalCenter
                                width: typeof result.value === "boolean" ? toggle.width : valueLabel.implicitWidth
                                height: parent.height

                                Toggle {
                                    id: toggle
                                    visible: typeof result.value === "boolean"
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    checked: result.value === true
                                    accessibleName: result.modelData.title
                                    onToggled: root.activate(result.modelData, true)
                                }
                                Text {
                                    id: valueLabel
                                    visible: typeof result.value !== "boolean"
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: result.modelData.kind === "action" ? I18n.tr("Run")
                                        : result.modelData.kind === "page" ? "›"
                                        : root.valueText(result.value)
                                    font.family: result.modelData.kind === "row" ? Theme.fontNumeric : Theme.fontMenu
                                    font.pixelSize: result.modelData.kind === "page" ? Theme.typography.title
                                        : Theme.typography.secondary
                                    color: Theme.textFaint
                                }
                            }
                            MouseArea {
                                id: resultMouse
                                anchors.fill: parent
                                anchors.rightMargin: typeof result.value === "boolean" ? trailing.width + Theme.scaled(14) : 0
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.activate(result.modelData, false)
                            }
                        }
                    }
                }

                Text {
                    visible: root.query !== "" && root.choices.length === 0
                    width: parent.width
                    topPadding: Theme.scaled(12)
                    bottomPadding: Theme.scaled(12)
                    leftPadding: Theme.scaled(10)
                    text: I18n.format("Nothing matches “%1”. Try a setting’s name, its group, or a page.", [root.query])
                    wrapMode: Text.Wrap
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.primary
                    color: Theme.textDim
                }
            }
        }

        Item {
            id: footer
            anchors.bottom: parent.bottom
            width: parent.width
            height: Theme.scaled(36)
            Rectangle { width: parent.width; height: 1; color: Theme.hairlineSoft }
            Row {
                x: Theme.scaled(16)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.scaled(16)
                Repeater {
                    model: [
                        { keys: "↑↓", verb: I18n.tr("move") },
                        { keys: "⏎", verb: I18n.tr("go to it") },
                        { keys: "Ctrl ⏎", verb: I18n.tr("switch on or off") },
                        { keys: "Esc", verb: I18n.tr("close") }
                    ]
                    delegate: Row {
                        required property var modelData
                        spacing: Theme.scaled(5)
                        Text {
                            text: parent.modelData.keys
                            font.family: Theme.fontMono
                            font.pixelSize: Theme.typography.metadata
                            color: Theme.textDim
                        }
                        Text {
                            text: parent.modelData.verb
                            font.family: Theme.fontMenu
                            font.pixelSize: Theme.typography.metadata
                            color: Theme.textFaint
                        }
                    }
                }
            }
        }
    }

    component KeyHint: Rectangle {
        property alias text: hintLabel.text
        width: hintLabel.implicitWidth + Theme.scaled(10)
        height: Theme.scaled(18)
        radius: 4
        color: "transparent"
        border.width: 1
        border.color: Theme.hairline
        Text {
            id: hintLabel
            anchors.centerIn: parent
            font.family: Theme.fontMono
            font.pixelSize: Theme.typography.metadata
            color: Theme.textFaint
        }
    }
}
