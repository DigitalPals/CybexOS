pragma ComponentBehavior: Bound
import QtQuick
import "../Common"
import "../Common/NotesHelpers.js" as NotesHelpers
import "../Common/PanelRegistryData.js" as PanelRegistry

// A compact two-state Markdown notebook. Draft text belongs to this view;
// canonical records, persistence, title jobs, and Undo live in Notes so the
// editor can be closed or its Loader destroyed without losing a commit.
Surface {
    id: root

    focus: visible
    padding: Theme.surfacePadding
    spacing: 0
    implicitWidth: availableWidth > 0
        ? Math.min(Theme.popWidth, availableWidth) : Theme.popWidth

    property bool editing: false
    property string editingId: ""
    property string observedTitle: ""
    property bool persistingTitle: false
    property double relativeNow: Date.now()

    readonly property real heightEnvelope: availableHeight > 0
        ? availableHeight : Theme.scaled(800)
    // The complete editor popover aims for 55% of the output, has useful
    // theme-scaled bounds, and can never ask the host for more than it owns.
    readonly property real editorPanelHeight: Math.max(1,
        Math.min(heightEnvelope,
            Math.max(Theme.scaled(320), Math.min(Theme.scaled(440),
                Math.round(heightEnvelope * 0.55)))))
    readonly property real editorContentHeight: Math.max(1,
        editorPanelHeight - padding * 2)
    readonly property bool editorTitlePending: editingId !== ""
        && Notes.titlePending(editingId)
    readonly property string editorTitleError: editingId === "" ? ""
        : Notes.titleError(editingId)
    readonly property bool editorTitleActionVisible: editingId !== ""
        && Settings.modOpts.notes.titleProvider !== "off"
    readonly property string statusText: Notes.error !== "" ? Notes.error
        : !Notes.ready ? "Loading…"
        : Notes.undoAvailable ? "Note deleted"
        : ""

    onActiveFocusChanged: {
        if (activeFocus && !editing)
            focusInitial();
    }

    function focusInitial() {
        Qt.callLater(() => {
            if (root.visible && !root.editing)
                addButton.forceActiveFocus();
        });
    }

    function parkFocus() {
        if (root.activeFocus)
            root.forceActiveFocus();
    }

    function setEditorText(body) {
        noteEdit.syncing = true;
        noteEdit.text = body;
        noteEdit.cursorPosition = noteEdit.text.length;
        noteEdit.syncing = false;
    }

    function setEditorTitle(title) {
        titleEdit.syncing = true;
        titleEdit.text = title;
        titleEdit.cursorPosition = titleEdit.text.length;
        titleEdit.syncing = false;
    }

    function syncEditorTitle() {
        if (editingId === "")
            return;
        const note = Notes.record(editingId);
        if (!note || note.title === observedTitle)
            return;
        observedTitle = note.title;
        if (!persistingTitle && titleEdit.text !== note.title)
            setEditorTitle(note.title);
    }

    function persistEditor() {
        if (!editing || noteEdit.syncing || NotesHelpers.isBlank(noteEdit.text))
            return;
        if (editingId === "") {
            editingId = Notes.add(noteEdit.text, titleEdit.text);
            const note = Notes.record(editingId);
            observedTitle = note ? note.title : "";
        } else {
            Notes.update(editingId, noteEdit.text);
        }
    }

    function persistTitle() {
        if (!editing || titleEdit.syncing || editingId === "")
            return;
        persistingTitle = true;
        Notes.updateTitle(editingId, titleEdit.text);
        const note = Notes.record(editingId);
        observedTitle = note ? note.title : "";
        persistingTitle = false;
    }

    function beginNew() {
        if (!Notes.ready)
            return;
        finishEditing(false);
        editingId = "";
        setEditorText("");
        setEditorTitle("");
        observedTitle = "";
        parkFocus();
        editing = true;
        Qt.callLater(noteEdit.forceActiveFocus);
    }

    function beginEdit(note) {
        if (!Notes.ready || !note || typeof note.id !== "string")
            return;
        if (editing && editingId === note.id) {
            noteEdit.forceActiveFocus();
            return;
        }
        finishEditing(false);
        editingId = note.id;
        setEditorText(note.body);
        setEditorTitle(note.title);
        observedTitle = note.title;
        parkFocus();
        editing = true;
        Qt.callLater(noteEdit.forceActiveFocus);
    }

    // Back, Done, Escape, Ctrl+Enter, switching panels, and destruction all
    // cross the same commit boundary. A blank existing body is deletion; a
    // never-materialized blank draft simply disappears.
    function finishEditing(restoreFocus) {
        if (!editing)
            return;
        // A draft typed inside the debounce window has not reached Notes
        // yet; materialize it first so a quick Done cannot drop it.
        persistTimer.stop();
        persistEditor();
        const id = editingId;
        const body = noteEdit.text;
        const autoGenerateTitle = NotesHelpers.shouldAutoGenerateTitle(
            titleEdit.text, Settings.modOpts.notes.titleProvider);
        parkFocus();
        editing = false;
        editingId = "";
        if (id !== "") {
            if (NotesHelpers.isBlank(body)) {
                Notes.remove(id);
            } else {
                Notes.update(id, body);
                if (autoGenerateTitle)
                    Notes.requestTitle(id);
            }
        }
        Notes.flush();
        relativeNow = Date.now();
        if (restoreFocus)
            focusInitial();
    }

    function deleteEditing() {
        persistTimer.stop();
        const id = editingId;
        parkFocus();
        editing = false;
        editingId = "";
        if (id !== "")
            Notes.remove(id);
        Notes.flush();
        relativeNow = Date.now();
        focusInitial();
    }

    function deleteCard(id) {
        Notes.remove(id);
        Notes.flush();
        relativeNow = Date.now();
        focusInitial();
    }

    function requestEditorTitle() {
        persistTimer.stop();
        persistEditor();
        if (editingId === "")
            return;
        noteEdit.forceActiveFocus();
        if (editorTitleError !== "")
            Notes.retryTitle(editingId);
        else
            Notes.requestTitle(editingId);
    }

    function applyFormat(action) {
        if (!editing)
            return;
        const transformed = NotesHelpers.transformMarkdown(noteEdit.text,
            noteEdit.selectionStart, noteEdit.selectionEnd, action);
        noteEdit.syncing = true;
        noteEdit.text = transformed.text;
        noteEdit.cursorPosition = transformed.cursorPosition;
        noteEdit.select(transformed.selectionStart, transformed.selectionEnd);
        noteEdit.syncing = false;
        persistEditor();
        noteEdit.forceActiveFocus();
    }

    function handleEditorControlKey(event, tabTarget, backtabTarget) {
        if (!editing)
            return false;
        const control = event.modifiers & Qt.ControlModifier;
        if (event.key === Qt.Key_Escape) {
            finishEditing(true);
            event.accepted = true;
            return true;
        }
        if (control && (event.key === Qt.Key_Return
                || event.key === Qt.Key_Enter)) {
            finishEditing(true);
            event.accepted = true;
            return true;
        }
        if (!control && (event.key === Qt.Key_Tab
                || event.key === Qt.Key_Backtab)) {
            const backwards = event.key === Qt.Key_Backtab
                || (event.modifiers & Qt.ShiftModifier);
            const target = backwards ? backtabTarget : tabTarget;
            if (target)
                target.forceActiveFocus();
            event.accepted = true;
            return true;
        }
        return false;
    }

    function modifiedDescription(updatedAt) {
        if (!NotesHelpers.validTimestamp(updatedAt))
            return "Modified time unavailable";
        return "Modified " + new Date(updatedAt).toLocaleString();
    }

    function handleEscape(): bool {
        if (!editing)
            return false;
        finishEditing(true);
        return true;
    }

    component NoteIconButton: Rectangle {
        id: button

        property string symbol: ""
        property string actionName: ""
        property color tint: Theme.textMid
        property int controlSize: Theme.scaled(30)
        property bool spinning: false
        property Item tabTarget: null
        property Item backtabTarget: null
        signal triggered

        width: controlSize
        height: controlSize
        radius: Theme.rowRadius
        color: buttonMouse.containsMouse || activeFocus
            ? Theme.hoverFillStrong : "transparent"
        opacity: enabled ? 1 : 0.4
        border.width: activeFocus ? 1 : 0
        border.color: Theme.accentText
        // Visibility is already enforced by the parent view. Keeping this
        // independent avoids changing the flag while a focused view exits.
        activeFocusOnTab: enabled
        Accessible.role: Accessible.Button
        Accessible.name: actionName
        Accessible.onPressAction: button.triggered()

        Keys.onPressed: event => {
            if (root.handleEditorControlKey(event,
                    button.tabTarget, button.backtabTarget))
                return;
            if (button.enabled && (event.key === Qt.Key_Return
                    || event.key === Qt.Key_Enter
                    || event.key === Qt.Key_Space)) {
                button.triggered();
                event.accepted = true;
            } else
                event.accepted = false;
        }

        Sym {
            id: buttonGlyph
            anchors.centerIn: parent
            name: button.symbol
            size: Theme.iconMedium
            color: button.tint

            RotationAnimation on rotation {
                running: button.spinning && button.visible && !Theme.reducedMotion
                from: 0
                to: 360
                duration: 950
                loops: Animation.Infinite
            }
        }

        MouseArea {
            id: buttonMouse
            anchors.fill: parent
            enabled: button.enabled
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: button.triggered()
        }
    }

    component StatusStrip: Item {
        id: strip

        visible: root.statusText !== "" || Notes.undoAvailable
        width: parent ? parent.width : 0
        height: visible ? Theme.scaled(28) : 0

        Text {
            anchors.left: parent.left
            anchors.right: statusActions.left
            anchors.rightMargin: 6
            anchors.verticalCenter: parent.verticalCenter
            text: root.statusText
            elide: Text.ElideRight
            font.family: Theme.fontMenu
            font.pixelSize: Theme.typography.secondary
            color: Notes.error !== "" ? Theme.redText : Theme.textLow
            Accessible.role: Notes.error !== ""
                ? Accessible.AlertMessage : Accessible.StaticText
            Accessible.name: root.statusText
        }

        Row {
            id: statusActions
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: 5

            ActionButton {
                visible: Notes.error !== ""
                activeFocusOnTab: true
                label: "Retry"
                hPadding: 14
                tint: Theme.redText
                fill: Theme.redBgSoft
                Accessible.role: Accessible.Button
                Accessible.name: "Retry saving notes"
                onTriggered: {
                    root.parkFocus();
                    Notes.retrySave();
                    root.focusInitial();
                }
            }

            ActionButton {
                visible: Notes.undoAvailable
                activeFocusOnTab: true
                label: "Undo"
                hPadding: 14
                tint: Theme.accent
                fill: Theme.accentBgSoft
                Accessible.role: Accessible.Button
                Accessible.name: "Undo note deletion"
                onTriggered: {
                    root.parkFocus();
                    Notes.undoDelete();
                    root.focusInitial();
                }
            }
        }
    }

    FocusScope {
        id: overviewView

        visible: !root.editing
        width: parent.width
        height: visible ? overviewColumn.implicitHeight : 0

        Column {
            id: overviewColumn
            width: parent.width
            spacing: Theme.scaled(10)

            Item {
                id: overviewHeader
                width: parent.width
                height: Theme.scaled(34)

                Row {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 8

                    Sym {
                        anchors.verticalCenter: parent.verticalCenter
                        name: "sticky_note_2"
                        size: Theme.iconMedium
                        color: Theme.accentText
                    }

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Notes"
                        font.family: Theme.fontMenu
                        font.pixelSize: Theme.typography.heading
                        font.weight: Theme.weightBold
                        color: Theme.textHi
                    }
                }

                ActionButton {
                    id: addButton
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    label: "Add"
                    hPadding: 18
                    tint: Theme.accent
                    fill: Theme.accentBgSoft
                    enabled: Notes.ready
                    activeFocusOnTab: enabled
                    Accessible.role: Accessible.Button
                    Accessible.name: "Add note"
                    onTriggered: root.beginNew()
                }
            }

            StatusStrip {
                id: overviewStatus
            }

            Item {
                id: emptyState
                visible: Notes.ready && Notes.count === 0
                width: parent.width
                height: visible ? Math.min(Theme.scaled(104),
                    Math.max(1, root.heightEnvelope - root.padding * 2
                        - overviewHeader.height - overviewColumn.spacing
                        - (overviewStatus.visible
                            ? overviewStatus.height + overviewColumn.spacing : 0))) : 0
                Accessible.role: Accessible.StaticText
                Accessible.name: "No notes yet"
                Accessible.description: "Use Add to start a note"

                Column {
                    anchors.centerIn: parent
                    width: parent.width
                    spacing: 5

                    Text {
                        width: parent.width
                        horizontalAlignment: Text.AlignHCenter
                        text: "No notes yet"
                        font.family: Theme.fontMenu
                        font.pixelSize: Theme.typography.primary
                        font.weight: Theme.weightSemibold
                        color: Theme.textMid
                    }

                    Text {
                        width: parent.width
                        horizontalAlignment: Text.AlignHCenter
                        text: "Use Add to start a note."
                        font.family: Theme.fontMenu
                        font.pixelSize: Theme.typography.secondary
                        color: Theme.textFaint
                    }
                }
            }

            Flickable {
                id: noteList

                visible: Notes.count > 0
                width: parent.width
                height: visible ? Math.min(noteColumn.implicitHeight,
                    Math.max(1, root.heightEnvelope - root.padding * 2
                        - overviewHeader.height - overviewColumn.spacing
                        - (overviewStatus.visible
                            ? overviewStatus.height + overviewColumn.spacing : 0))) : 0
                // Count is the canonical visibility gate; deriving it from
                // descendants creates a zero-height cycle on some Qt builds.
                contentWidth: width
                contentHeight: noteColumn.implicitHeight
                boundsBehavior: Flickable.StopAtBounds
                clip: true

                Column {
                    id: noteColumn
                    width: parent.width
                    spacing: Theme.scaled(3)

                    // Emptied while the list is hidden behind the editor, so
                    // a body commit does not rebuild every card unseen.
                    Repeater {
                        model: root.editing ? [] : Notes.records

                        delegate: Rectangle {
                            id: noteCard

                            required property var modelData
                            readonly property bool titleBusy:
                                Notes.titlePending(modelData.id)
                            readonly property string titleFailure:
                                Notes.titleError(modelData.id)
                            readonly property string compactTime:
                                NotesHelpers.relativeTimeLabel(
                                    modelData.updatedAt, root.relativeNow)
                            readonly property string rowStatus: titleBusy
                                ? "Generating…" : titleFailure !== ""
                                    ? "Title failed" : compactTime
                            readonly property bool actionsRevealed: noteHover.hovered
                                || activeFocus || cardActions.activeFocus
                            readonly property string exactModified:
                                root.modifiedDescription(modelData.updatedAt)

                            width: parent.width
                            height: Theme.scaled(44)
                            radius: Theme.rowRadius
                            color: noteHover.hovered || activeFocus
                                || cardActions.activeFocus
                                    ? Theme.hoverFillStrong : "transparent"
                            border.width: activeFocus ? 1 : 0
                            border.color: Theme.accentText
                            activeFocusOnTab: true
                            Accessible.role: Accessible.Button
                            Accessible.name: "Edit note: " + modelData.title
                            Accessible.description: exactModified
                                + (titleBusy ? ". Generating title"
                                    : titleFailure !== ""
                                        ? ". Title generation failed: " + titleFailure : "")
                            Accessible.onPressAction: root.beginEdit(modelData)

                            Keys.onPressed: event => {
                                if (event.key === Qt.Key_Return
                                        || event.key === Qt.Key_Enter
                                        || event.key === Qt.Key_Space) {
                                    root.beginEdit(noteCard.modelData);
                                    event.accepted = true;
                                } else if (event.key === Qt.Key_Delete) {
                                    root.deleteCard(noteCard.modelData.id);
                                    event.accepted = true;
                                }
                            }

                            HoverHandler { id: noteHover }

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    noteCard.forceActiveFocus();
                                    root.beginEdit(noteCard.modelData);
                                }
                            }

                            Item {
                                id: cardSide
                                anchors.right: parent.right
                                anchors.rightMargin: 8
                                anchors.verticalCenter: parent.verticalCenter
                                width: noteCard.actionsRevealed
                                    ? cardActions.implicitWidth : statusLabel.implicitWidth
                                height: Theme.scaled(30)

                                Text {
                                    id: statusLabel
                                    visible: !noteCard.actionsRevealed
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: noteCard.rowStatus
                                    font.family: Theme.fontMenu
                                    font.pixelSize: Theme.typography.metadata
                                    font.weight: Theme.weightMedium
                                    font.features: Theme.tabularNumberFeatures
                                    color: noteCard.titleFailure !== ""
                                        ? Theme.redText
                                        : noteCard.titleBusy ? Theme.accentText : Theme.textFaint
                                }

                                FocusScope {
                                    id: cardActions
                                    visible: noteCard.actionsRevealed
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    implicitWidth: cardActionRow.implicitWidth
                                    implicitHeight: cardActionRow.implicitHeight

                                    Row {
                                        id: cardActionRow
                                        spacing: 2

                                        NoteIconButton {
                                            visible: noteCard.titleFailure !== ""
                                            symbol: "refresh"
                                            actionName: "Retry title generation"
                                            tint: Theme.accent
                                            onTriggered:
                                                Notes.retryTitle(noteCard.modelData.id)
                                        }

                                        NoteIconButton {
                                            symbol: "delete"
                                            actionName: "Delete note"
                                            tint: Theme.redText
                                            onTriggered:
                                                root.deleteCard(noteCard.modelData.id)
                                        }
                                    }
                                }
                            }

                            Text {
                                anchors.left: parent.left
                                anchors.right: cardSide.left
                                anchors.leftMargin: 11
                                anchors.rightMargin: 10
                                anchors.verticalCenter: parent.verticalCenter
                                text: noteCard.modelData.title
                                maximumLineCount: 1
                                elide: Text.ElideRight
                                font.family: Theme.fontMenu
                                font.pixelSize: Theme.typography.primary
                                font.weight: Theme.weightSemibold
                                color: Theme.textHi
                            }
                        }
                    }
                }

                ScrollChrome {
                    anchors.fill: parent
                    target: noteList
                }
            }
        }
    }

    FocusScope {
        id: editorView

        visible: root.editing
        width: parent.width
        height: visible ? root.editorContentHeight : 0

        Keys.onPressed: event => {
            if (event.key === Qt.Key_Escape) {
                root.finishEditing(true);
                event.accepted = true;
            } else if ((event.modifiers & Qt.ControlModifier)
                    && (event.key === Qt.Key_Return
                        || event.key === Qt.Key_Enter)) {
                root.finishEditing(true);
                event.accepted = true;
            }
        }

        Column {
            id: editorColumn
            width: parent.width
            spacing: Theme.scaled(10)

            Item {
                id: editorHeader
                width: parent.width
                height: Theme.scaled(34)

                ActionButton {
                    id: backButton
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    label: "Back"
                    hPadding: 16
                    fill: "transparent"
                    tint: Theme.textMid
                    activeFocusOnTab: true
                    Accessible.role: Accessible.Button
                    Accessible.name: "Back to notes"
                    KeyNavigation.tab: doneButton
                    KeyNavigation.backtab: deleteButton
                    Keys.onPressed: event => {
                        if (root.handleEditorControlKey(event,
                                doneButton, deleteButton))
                            return;
                        if (event.key === Qt.Key_Return
                                || event.key === Qt.Key_Enter
                                || event.key === Qt.Key_Space) {
                            root.finishEditing(true);
                            event.accepted = true;
                        } else {
                            event.accepted = false;
                        }
                    }
                    onTriggered: root.finishEditing(true)
                }

                Text {
                    anchors.centerIn: parent
                    text: root.editingId === "" ? "New note" : "Edit note"
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.heading
                    font.weight: Theme.weightBold
                    color: Theme.textHi
                }

                ActionButton {
                    id: doneButton
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    label: "Done"
                    hPadding: 16
                    tint: Theme.accent
                    fill: Theme.accentBgSoft
                    activeFocusOnTab: true
                    Accessible.role: Accessible.Button
                    Accessible.name: "Done editing note"
                    KeyNavigation.tab: titleEdit
                    KeyNavigation.backtab: backButton
                    Keys.onPressed: event => {
                        if (root.handleEditorControlKey(event,
                                titleEdit, backButton))
                            return;
                        if (event.key === Qt.Key_Return
                                || event.key === Qt.Key_Enter
                                || event.key === Qt.Key_Space) {
                            root.finishEditing(true);
                            event.accepted = true;
                        } else {
                            event.accepted = false;
                        }
                    }
                    onTriggered: root.finishEditing(true)
                }
            }

            StatusStrip {
                id: editorStatus
            }

            Rectangle {
                id: documentSurface
                width: parent.width
                height: Math.max(1, editorView.height - editorHeader.height
                    - editorColumn.spacing
                    - (editorStatus.visible
                        ? editorStatus.height + editorColumn.spacing : 0))
                radius: Theme.cardRadius
                color: Theme.tile
                clip: true

                Item {
                    id: titleArea
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    height: titleRow.height + titleFeedback.height

                    Item {
                        id: titleRow
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        height: Theme.scaled(52)

                        TextInput {
                            id: titleEdit

                            property bool syncing: false

                            anchors.left: parent.left
                            anchors.right: titleAction.visible
                                ? titleAction.left : parent.right
                            anchors.top: parent.top
                            anchors.bottom: parent.bottom
                            anchors.leftMargin: Theme.scaled(14)
                            anchors.rightMargin: Theme.scaled(8)
                            maximumLength: NotesHelpers.MAX_TITLE_LENGTH
                            selectByMouse: true
                            activeFocusOnTab: true
                            verticalAlignment: TextInput.AlignVCenter
                            font.family: Theme.fontMenu
                            font.pixelSize: Theme.typography.title
                            font.weight: Theme.weightSemibold
                            color: Theme.textHi
                            selectionColor: Theme.accentBg
                            selectedTextColor: Theme.textHi
                            clip: true
                            Accessible.role: Accessible.EditableText
                            Accessible.name: "Note title"
                            Accessible.description: "Editable plain-text title"
                            KeyNavigation.tab: titleAction.visible
                                ? titleAction : noteEdit
                            KeyNavigation.backtab: doneButton
                            onTextEdited: root.persistTitle()

                            Keys.onPressed: event => {
                                if (!root.handleEditorControlKey(event,
                                        titleAction.visible ? titleAction : noteEdit,
                                        doneButton))
                                    event.accepted = false;
                            }

                            Text {
                                anchors.left: parent.left
                                anchors.verticalCenter: parent.verticalCenter
                                visible: titleEdit.text === ""
                                text: "Title"
                                font: titleEdit.font
                                color: Theme.textFaint
                            }
                        }

                        NoteIconButton {
                            id: titleAction
                            anchors.right: parent.right
                            anchors.rightMargin: Theme.scaled(10)
                            anchors.verticalCenter: parent.verticalCenter
                            visible: root.editorTitleActionVisible
                            symbol: root.editorTitlePending
                                ? "progress_activity" : "auto_awesome"
                            actionName: root.editorTitlePending
                                ? "Generating note title"
                                : root.editorTitleError !== ""
                                    ? "Retry title generation" : "Generate note title"
                            tint: root.editorTitleError !== ""
                                ? Theme.redText : Theme.accent
                            spinning: root.editorTitlePending
                            enabled: !root.editorTitlePending
                            KeyNavigation.tab: noteEdit
                            KeyNavigation.backtab: titleEdit
                            tabTarget: noteEdit
                            backtabTarget: titleEdit
                            onTriggered: root.requestEditorTitle()
                        }
                    }

                    Item {
                        id: titleFeedback
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: titleRow.bottom
                        visible: root.editorTitlePending
                            || root.editorTitleError !== ""
                        height: visible ? Theme.scaled(24) : 0

                        Text {
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.leftMargin: Theme.scaled(14)
                            anchors.rightMargin: Theme.scaled(14)
                            anchors.verticalCenter: parent.verticalCenter
                            text: root.editorTitlePending
                                ? "Generating title…" : root.editorTitleError
                            elide: Text.ElideRight
                            font.family: Theme.fontMenu
                            font.pixelSize: Theme.typography.metadata
                            color: root.editorTitleError !== ""
                                ? Theme.redText : Theme.textLow
                            Accessible.role: root.editorTitleError !== ""
                                ? Accessible.AlertMessage : Accessible.StaticText
                            Accessible.name: text
                            Accessible.description: root.editorTitleError !== ""
                                ? "Use the sparkle button to retry" : ""
                        }
                    }
                }

                Rectangle {
                    id: bodyRule
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: titleArea.bottom
                    anchors.leftMargin: Theme.scaled(12)
                    anchors.rightMargin: Theme.scaled(12)
                    height: 1
                    color: Theme.hairlineSoft
                }

                Flickable {
                    id: editorFlick
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: bodyRule.bottom
                    anchors.bottom: formatDivider.top
                    anchors.leftMargin: Theme.scaled(14)
                    anchors.rightMargin: Theme.scaled(14)
                    anchors.topMargin: Theme.scaled(10)
                    anchors.bottomMargin: Theme.scaled(5)
                    contentWidth: width
                    contentHeight: Math.max(height, noteEdit.contentHeight)
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds

                    TextEdit {
                        id: noteEdit

                        property bool syncing: false

                        width: editorFlick.width
                        height: Math.max(editorFlick.height, contentHeight)
                        wrapMode: TextEdit.Wrap
                        selectByMouse: true
                        persistentSelection: true
                        activeFocusOnTab: true
                        font.family: Theme.fontMenu
                        font.pixelSize: Theme.typography.control
                        color: Theme.textHi
                        selectionColor: Theme.accentBg
                        selectedTextColor: Theme.textHi
                        Accessible.role: Accessible.EditableText
                        Accessible.name: root.editingId === ""
                            ? "New note body" : "Edit note body"
                        Accessible.description: "Markdown note"
                        KeyNavigation.tab: boldButton
                        KeyNavigation.backtab: titleAction.visible
                            ? titleAction : titleEdit
                        onTextChanged: {
                            if (!noteEdit.syncing)
                                persistTimer.restart();
                        }
                        onCursorRectangleChanged: {
                            if (cursorRectangle.y + cursorRectangle.height
                                    > editorFlick.contentY + editorFlick.height) {
                                editorFlick.contentY = cursorRectangle.y
                                    + cursorRectangle.height - editorFlick.height;
                            } else if (cursorRectangle.y < editorFlick.contentY) {
                                editorFlick.contentY = cursorRectangle.y;
                            }
                        }

                        Keys.onPressed: event => {
                            const control = event.modifiers & Qt.ControlModifier;
                            if (root.handleEditorControlKey(event,
                                    boldButton, titleAction.visible
                                        ? titleAction : titleEdit)) {
                                return;
                            } else if (control && event.key === Qt.Key_B) {
                                root.applyFormat("bold");
                                event.accepted = true;
                            } else if (control && event.key === Qt.Key_I) {
                                root.applyFormat("italic");
                                event.accepted = true;
                            } else if (control && event.key === Qt.Key_K) {
                                root.applyFormat("link");
                                event.accepted = true;
                            } else
                                event.accepted = false;
                        }

                        Text {
                            anchors.left: parent.left
                            anchors.top: parent.top
                            visible: noteEdit.text === ""
                            text: "Write a Markdown note…"
                            font: noteEdit.font
                            color: Theme.textFaint
                        }
                    }

                    ScrollChrome {
                        anchors.fill: parent
                        target: editorFlick
                    }
                }

                HDivider {
                    id: formatDivider
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: formatRail.top
                }

                Item {
                    id: formatRail
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    height: Theme.scaled(42)

                    Row {
                        anchors.left: parent.left
                        anchors.leftMargin: Theme.scaled(8)
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 3

                        NoteIconButton {
                            id: boldButton
                            symbol: "format_bold"
                            actionName: "Bold, Ctrl+B"
                            KeyNavigation.tab: italicButton
                            KeyNavigation.backtab: noteEdit
                            tabTarget: italicButton
                            backtabTarget: noteEdit
                            onTriggered: root.applyFormat("bold")
                        }
                        NoteIconButton {
                            id: italicButton
                            symbol: "format_italic"
                            actionName: "Italic, Ctrl+I"
                            KeyNavigation.tab: bulletButton
                            KeyNavigation.backtab: boldButton
                            tabTarget: bulletButton
                            backtabTarget: boldButton
                            onTriggered: root.applyFormat("italic")
                        }
                        NoteIconButton {
                            id: bulletButton
                            symbol: "format_list_bulleted"
                            actionName: "Bulleted list"
                            KeyNavigation.tab: checklistButton
                            KeyNavigation.backtab: italicButton
                            tabTarget: checklistButton
                            backtabTarget: italicButton
                            onTriggered: root.applyFormat("bullet")
                        }
                        NoteIconButton {
                            id: checklistButton
                            symbol: "checklist"
                            actionName: "Checklist"
                            KeyNavigation.tab: linkButton
                            KeyNavigation.backtab: bulletButton
                            tabTarget: linkButton
                            backtabTarget: bulletButton
                            onTriggered: root.applyFormat("checklist")
                        }
                        NoteIconButton {
                            id: linkButton
                            symbol: "link"
                            actionName: "Link, Ctrl+K"
                            KeyNavigation.tab: codeButton
                            KeyNavigation.backtab: checklistButton
                            tabTarget: codeButton
                            backtabTarget: checklistButton
                            onTriggered: root.applyFormat("link")
                        }
                        NoteIconButton {
                            id: codeButton
                            symbol: "code"
                            actionName: "Inline code"
                            KeyNavigation.tab: deleteButton
                            KeyNavigation.backtab: linkButton
                            tabTarget: deleteButton
                            backtabTarget: linkButton
                            onTriggered: root.applyFormat("code")
                        }
                    }

                    NoteIconButton {
                        id: deleteButton
                        anchors.right: parent.right
                        anchors.rightMargin: Theme.scaled(8)
                        anchors.verticalCenter: parent.verticalCenter
                        symbol: "delete"
                        actionName: "Delete note"
                        tint: Theme.redText
                        KeyNavigation.tab: backButton
                        KeyNavigation.backtab: codeButton
                        tabTarget: backButton
                        backtabTarget: codeButton
                        onTriggered: root.deleteEditing()
                    }
                }
            }
        }
    }

    // Body edits reach Notes after a pause in typing rather than per
    // keystroke: each commit copies and re-sorts every record. Every path
    // out of the editor stops this and commits the live text itself.
    Timer {
        id: persistTimer
        interval: 250
        onTriggered: root.persistEditor()
    }

    Timer {
        id: relativeTimeTimer
        interval: 60000
        repeat: true
        running: root.visible && !root.editing
        onRunningChanged: {
            if (running)
                root.relativeNow = Date.now();
        }
        onTriggered: root.relativeNow = Date.now()
    }

    Connections {
        target: Popouts

        function onChanged() {
            if (!Popouts.open || Popouts.currentName !== PanelRegistry.NOTES)
                root.finishEditing(false);
        }
    }

    Connections {
        target: Notes

        function onRecordsChanged() {
            if (root.editing)
                root.syncEditorTitle();
        }
    }

    Component.onCompleted: focusInitial()
    Component.onDestruction: finishEditing(false)
}
