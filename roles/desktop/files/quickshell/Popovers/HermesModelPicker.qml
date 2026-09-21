pragma ComponentBehavior: Bound
import QtQuick
import "../Common"

// Searchable model list for the single provider configured in Hermes. Provider
// selection belongs in Hermes' model setup, not in this conversation control.
Item {
    id: root

    property string conversationId: ""
    property string provider: ""
    property string model: ""
    property string label: ""
    property bool expanded: false
    property bool openUpward: true
    property real maxWidth: 1000
    signal selected(string provider, string model)

    property string query: ""
    property int highlighted: 0
    readonly property var groups: Hermes.modelGroups
    readonly property var configuredGroup: configuredModelGroup()
    readonly property var rows: modelRows()
    readonly property int panelWidth: 292
    readonly property int panelHeight: 290
    readonly property int popupHeight: panelHeight
    readonly property Item popupItem: panel

    implicitWidth: trigger.implicitWidth
    implicitHeight: trigger.implicitHeight
    z: expanded ? 100 : 0

    function configuredModelGroup() {
        const source = Array.isArray(groups) ? groups : [];
        const configured = String(Hermes.defaultModelProvider ?? "");
        return source.find(group =>
            String(group.providerId ?? "") === configured) ?? source[0] ?? null;
    }

    function modelRows() {
        const result = [];
        const needle = query.trim().toLowerCase();
        const group = configuredGroup;
        if (!group)
            return result;
        const providerId = String(group.providerId ?? "");
        for (const candidate of (Array.isArray(group.models) ? group.models : [])) {
            const id = String(candidate.id ?? "");
            const name = String(candidate.label ?? id);
            if (needle !== "" && (id + " " + name).toLowerCase()
                    .indexOf(needle) < 0)
                continue;
            result.push({ providerId: providerId,
                provider: String(group.provider ?? providerId),
                id: id, label: name });
        }
        return result;
    }

    function open() {
        query = "";
        highlighted = Math.max(0, rows.findIndex(candidate =>
            String(candidate.id) === model));
        expanded = true;
        Qt.callLater(() => {
            root.revealHighlighted();
            searchInput.forceActiveFocus();
        });
    }

    function close(restoreFocus, restoreIfHidden) {
        expanded = false;
        query = "";
        if (restoreFocus === true)
            Qt.callLater(() => trigger.forceActiveFocus());
        else if (restoreIfHidden === true)
            restoreTriggerIfFocusHidden();
    }

    function activate(row) {
        if (!row)
            return;
        selected(String(row.providerId), String(row.id));
        close(true);
    }

    function moveHighlight(delta) {
        if (rows.length === 0)
            return;
        highlighted = (highlighted + delta + rows.length) % rows.length;
        revealHighlighted();
    }

    function revealHighlighted() {
        if (rows.length === 0)
            return;
        const rowTop = highlighted * 44;
        if (rowTop < modelFlick.contentY)
            modelFlick.contentY = rowTop;
        else if (rowTop + 44 > modelFlick.contentY + modelFlick.height)
            modelFlick.contentY = Math.max(0, rowTop + 44 - modelFlick.height);
    }

    function focusModelRow(index) {
        if (rows.length === 0)
            return;
        highlighted = Math.max(0, Math.min(index, rows.length - 1));
        revealHighlighted();
        const item = modelRepeater.itemAt(highlighted);
        if (item)
            item.forceActiveFocus();
    }

    function containsPickerPoint(item, x, y) {
        if (!item)
            return false;
        const point = root.mapFromItem(item, x, y);
        const inButton = point.x >= 0 && point.x <= root.width
            && point.y >= 0 && point.y <= root.height;
        const inPanel = panel.visible && point.x >= panel.x
            && point.x <= panel.x + panel.width && point.y >= panel.y
            && point.y <= panel.y + panel.height;
        return inButton || inPanel;
    }

    function itemBelongsTo(item, ancestor) {
        let current = item;
        while (current) {
            if (current === ancestor)
                return true;
            current = current.parent;
        }
        return false;
    }

    function restoreTriggerIfFocusHidden() {
        Qt.callLater(() => {
            const focused = root.Window.window?.activeFocusItem ?? null;
            if (!focused || root.itemBelongsTo(focused, panel))
                trigger.forceActiveFocus();
        });
    }

    onEnabledChanged: if (!enabled) close(false)
    onVisibleChanged: if (!visible) close(false)
    onRowsChanged: {
        if (highlighted >= rows.length)
            highlighted = Math.max(0, rows.length - 1);
    }

    TapHandler {
        enabled: root.expanded && root.enabled && root.visible
        margin: root.Window.window
            ? Math.max(root.Window.window.width, root.Window.window.height) : 0
        onTapped: eventPoint => {
            if (!root.containsPickerPoint(root, eventPoint.position.x,
                    eventPoint.position.y))
                root.close(false, true);
        }
    }

    HermesBarControl {
        id: trigger
        anchors.fill: parent
        text: root.label
        accessibleDescription: "Hermes model"
        brand: Hermes.providerIcon(root.provider)
        tint: HermesTheme.textPrimary
        active: root.expanded
        maxWidth: root.maxWidth
        enabled: root.enabled
        onTriggered: root.expanded ? root.close(true) : root.open()
    }

    Rectangle {
        id: panel
        z: 1000
        visible: root.expanded && root.enabled
        x: 0
        y: root.openUpward ? -height - 6 : root.height + 6
        width: root.panelWidth
        height: root.panelHeight
        radius: HermesTheme.panelRadius
        color: HermesTheme.overlay
        border.width: 1
        border.color: HermesTheme.borderStrong
        clip: true

        Rectangle {
            id: searchBox
            anchors.left: parent.left
            anchors.leftMargin: 8
            anchors.right: parent.right
            anchors.rightMargin: 8
            anchors.top: parent.top
            anchors.topMargin: 8
            height: 34
            radius: HermesTheme.controlRadius
            color: HermesTheme.surfaceRaised
            border.width: searchInput.activeFocus ? 1 : 0
            border.color: HermesTheme.focus

            Sym {
                id: searchIcon
                anchors.left: parent.left
                anchors.leftMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                name: "search"
                size: Theme.iconSmall
                color: HermesTheme.textFaint
            }

            TextInput {
                id: searchInput
                anchors.left: searchIcon.right
                anchors.leftMargin: 6
                anchors.right: parent.right
                anchors.rightMargin: 7
                anchors.verticalCenter: parent.verticalCenter
                text: root.query
                onTextEdited: {
                    root.query = text;
                    root.highlighted = 0;
                    modelFlick.contentY = 0;
                }
                selectByMouse: true
                font.family: HermesTheme.fontUi
                font.pixelSize: Theme.typography.control
                color: HermesTheme.textPrimary
                selectionColor: HermesTheme.accentSoft
                selectedTextColor: HermesTheme.textPrimary
                Accessible.role: Accessible.EditableText
                Accessible.name: "Search Hermes models"

                Keys.onPressed: event => {
                    if (event.key === Qt.Key_Escape) {
                        root.close(true);
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Down) {
                        root.moveHighlight(1);
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Up) {
                        root.moveHighlight(-1);
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Return
                            || event.key === Qt.Key_Enter) {
                        root.activate(root.rows[root.highlighted]);
                        event.accepted = true;
                    }
                }

                Text {
                    visible: searchInput.text === ""
                    text: "Search models…"
                    font: searchInput.font
                    color: HermesTheme.textFaint
                }
            }
        }

        Flickable {
            id: modelFlick
            anchors.left: parent.left
            anchors.leftMargin: 4
            anchors.right: parent.right
            anchors.rightMargin: 4
            anchors.top: searchBox.bottom
            anchors.topMargin: 5
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 4
            contentWidth: width
            contentHeight: modelColumn.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            interactive: contentHeight > height

            Column {
                id: modelColumn
                width: modelFlick.width

                Text {
                    visible: root.rows.length === 0
                    width: parent.width
                    height: 44
                    verticalAlignment: Text.AlignVCenter
                    horizontalAlignment: Text.AlignHCenter
                    text: "No models found"
                    font.family: HermesTheme.fontUi
                    font.pixelSize: Theme.typography.secondary
                    color: HermesTheme.textFaint
                }

                Repeater {
                    id: modelRepeater
                    model: root.rows

                    delegate: Rectangle {
                        id: modelRow
                        required property var modelData
                        required property int index
                        readonly property bool selectedModel:
                            String(modelData.id) === root.model
                            && String(modelData.providerId) === root.provider
                        width: parent.width
                        height: 44
                        radius: HermesTheme.controlRadius
                        color: selectedModel ? Theme.chip
                            : modelMouse.containsMouse || activeFocus
                                || root.highlighted === index
                                ? HermesTheme.hoverStrong
                                : "transparent"
                        border.width: activeFocus ? 1 : 0
                        border.color: HermesTheme.focus
                        activeFocusOnTab: true
                        Accessible.role: Accessible.ListItem
                        Accessible.name: String(modelData.label ?? modelData.id ?? "")
                            + ", " + String(modelData.provider ?? modelData.providerId ?? "")
                        Accessible.selected: selectedModel
                        Accessible.onPressAction: root.activate(modelData)
                        onActiveFocusChanged: if (activeFocus) {
                            root.highlighted = index;
                            root.revealHighlighted();
                        }

                        Keys.onPressed: event => {
                            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                                    || event.key === Qt.Key_Space) {
                                root.activate(modelRow.modelData);
                                event.accepted = true;
                            } else if (event.key === Qt.Key_Down) {
                                root.focusModelRow(modelRow.index + 1);
                                event.accepted = true;
                            } else if (event.key === Qt.Key_Up) {
                                if (modelRow.index === 0)
                                    searchInput.forceActiveFocus();
                                else
                                    root.focusModelRow(modelRow.index - 1);
                                event.accepted = true;
                            } else if (event.key === Qt.Key_Escape) {
                                root.close(true);
                                event.accepted = true;
                            }
                        }

                        Column {
                            anchors.left: parent.left
                            anchors.leftMargin: 8
                            anchors.right: checkMark.left
                            anchors.rightMargin: 6
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 1

                            Text {
                                width: parent.width
                                text: String(modelRow.modelData.label ?? "")
                                elide: Text.ElideRight
                                font.family: HermesTheme.fontUi
                                font.pixelSize: Theme.typography.secondary
                                font.weight: Theme.weightMedium
                                color: HermesTheme.textPrimary
                            }

                            Text {
                                width: parent.width
                                text: String(modelRow.modelData.id ?? "")
                                elide: Text.ElideRight
                                font.family: HermesTheme.fontUi
                                font.pixelSize: Theme.typography.metadata
                                color: HermesTheme.textFaint
                            }
                        }

                        Sym {
                            id: checkMark
                            visible: modelRow.selectedModel
                            anchors.right: parent.right
                            anchors.rightMargin: 8
                            anchors.verticalCenter: parent.verticalCenter
                            name: "check"
                            size: Theme.iconSmall
                            color: HermesTheme.accent
                        }

                        MouseArea {
                            id: modelMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.activate(modelRow.modelData)
                        }
                    }
                }
            }
        }

        ScrollChrome {
            anchors.fill: modelFlick
            target: modelFlick
            fadeSize: 16
            edgeColor: HermesTheme.overlay
            thumbColor: HermesTheme.accent
        }
    }
}
