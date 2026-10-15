import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// The new owner's first-start setup, shown in cage before the login screen.
// Four steps with one primary action each: language and keyboard, account,
// time zone, finishing. The window only asks: `setup` sends the answers to
// the root service, which checks them again and does the work. The window's
// text follows the chosen language (Dutch or English).
ApplicationWindow {
    id: window

    // The welcome window's and installer's palette.
    readonly property color ink: "#f4f4f5"
    readonly property color inkMid: "#b4b4bb"
    readonly property color inkFaint: "#80808a"
    readonly property color surface: "#17171a"
    readonly property color surfaceHover: "#202024"
    readonly property color stroke: "#2a2a30"
    readonly property color accent: "#dd0034"
    readonly property color accentHover: "#f0164a"
    readonly property color accentDown: "#b8002b"
    readonly property color accentText: "#ff6b86"

    // cage shows the window on the whole screen at scale 1. One unit grows
    // with the screen, so text stays readable on high-density panels.
    readonly property real u: Math.max(1, Math.min(3, Math.min(width / 1440, height / 900)))
    readonly property real rowHeight: Math.round(42 * u)

    readonly property var pages: ["welcome", "account", "timezone", "finish"]
    readonly property var steps: ["Welcome", "Your account", "Time zone", "Finishing"]
    property int page: 0
    property bool showErrors: false
    property bool usernameEdited: false
    property string timezone: setup.timezone
    property int countdown: 15

    width: 1280
    height: 800
    visible: true
    title: tr("Set up CybexOS")
    color: "#0e0e10"
    font.family: "Figtree"
    font.pixelSize: Math.round(16 * u)
    palette.windowText: ink
    palette.text: ink
    palette.buttonText: ink
    palette.button: surface
    palette.base: surface
    palette.highlight: accent
    palette.highlightedText: "#ffffff"

    // ---- language -----------------------------------------------------------

    function tr(text) {
        return setup.language === "nl" && dutch[text] !== undefined ? dutch[text] : text;
    }

    readonly property var dutch: ({
        "Set up CybexOS": "CybexOS instellen",
        "Make it yours.": "Maak hem van jou.",
        "A few choices and your desktop is ready.": "Een paar keuzes en je bureaublad is klaar.",
        "Welcome": "Welkom",
        "Your account": "Je account",
        "Time zone": "Tijdzone",
        "Finishing": "Afronden",
        "Welcome.": "Welkom.",
        "Let's set up this computer for you. First, choose your language and keyboard.":
            "We stellen deze computer voor je in. Kies eerst je taal en toetsenbord.",
        "Language": "Taal",
        "Keyboard layout": "Toetsenbordindeling",
        "Search": "Zoeken",
        "No matches": "Geen resultaten",
        "Try your keyboard": "Probeer je toetsenbord",
        "Type here to test your keyboard": "Typ hier om je toetsenbord te testen",
        "Switching keyboard layout…": "Toetsenbordindeling wisselen…",
        "Continue": "Doorgaan",
        "Back": "Terug",
        "Your account.": "Je account.",
        "You use it to sign in and to approve administrator tasks.":
            "Hiermee meld je je aan en keur je beheerderstaken goed.",
        "Full name": "Volledige naam",
        "Username": "Gebruikersnaam",
        "Lowercase letters, numbers, dashes and underscores.": "Kleine letters, cijfers, streepjes en underscores.",
        "Password": "Wachtwoord",
        "Confirm password": "Bevestig wachtwoord",
        "Use at least 12 characters.": "Gebruik minstens 12 tekens.",
        "This password also unlocks the disk when the computer starts.":
            "Dit wachtwoord ontgrendelt ook de schijf als de computer start.",
        "Temporary disk passphrase": "Tijdelijk schijfwachtwoord",
        "The passphrase you typed to start this computer. It stops working once setup is done.":
            "Het wachtwoord dat je typte om deze computer te starten. Het werkt niet meer zodra het instellen klaar is.",
        "Your time zone.": "Je tijdzone.",
        "Choose where you are, so the clock is right.": "Kies waar je bent, zodat de klok klopt.",
        "Search for a city": "Zoek een stad",
        "Set up": "Instellen",
        "Setting up…": "Bezig met instellen…",
        "This takes a few minutes. Keep the computer on.": "Dit duurt een paar minuten. Laat de computer aan.",
        "Creating your account": "Je account aanmaken",
        "Preparing your desktop": "Je bureaublad voorbereiden",
        "Securing the disk": "De schijf beveiligen",
        "Finishing up": "Afronden",
        "Setup did not finish.": "Het instellen is niet gelukt.",
        "Nothing was kept. You can try again.": "Er is niets bewaard. Je kunt het opnieuw proberen.",
        "Try again": "Opnieuw proberen",
        "Ready.": "Klaar.",
        "Your account is ready. The computer restarts to finish setting up.":
            "Je account is klaar. De computer start opnieuw om het instellen af te ronden.",
        "When it starts, unlock the disk with your new password.":
            "Ontgrendel de schijf daarna met je nieuwe wachtwoord.",
        "Restart now": "Nu opnieuw starten",
        "Restarting in %1 seconds": "Opnieuw starten over %1 seconden",
        "Use at most 128 characters, without colons.": "Gebruik maximaal 128 tekens, zonder dubbele punt.",
        "Choose a username.": "Kies een gebruikersnaam.",
        "Use lowercase letters, numbers, dashes or underscores, starting with a letter.":
            "Gebruik kleine letters, cijfers, streepjes of underscores, en begin met een letter.",
        "That name is reserved for the system.": "Die naam is gereserveerd voor het systeem.",
        "That name is already in use.": "Die naam is al in gebruik.",
        "Use a password of 12–512 characters.": "Gebruik een wachtwoord van 12 tot 512 tekens.",
        "The password cannot contain control characters.": "Het wachtwoord mag geen besturingstekens bevatten.",
        "The passwords do not match.": "De wachtwoorden komen niet overeen.",
        "Type the passphrase you used at startup.": "Typ het wachtwoord dat je bij het starten gebruikte.",
        "That passphrase does not unlock this disk.": "Dit wachtwoord ontgrendelt de schijf niet.",
        "This layout cannot be used at the disk unlock screen. Choose another layout.":
            "Deze indeling werkt niet op het ontgrendelscherm van de schijf. Kies een andere indeling.",
        "Choose an item from the list.": "Kies een item uit de lijst.",
        "Something went wrong. Try again.": "Er ging iets mis. Probeer het opnieuw."
    })

    // Problem codes from the shared rules and the root service.
    readonly property var problems: ({
        "full-name": "Use at most 128 characters, without colons.",
        "username-empty": "Choose a username.",
        "username-format": "Use lowercase letters, numbers, dashes or underscores, starting with a letter.",
        "username-reserved": "That name is reserved for the system.",
        "username-taken": "That name is already in use.",
        "password-length": "Use a password of 12–512 characters.",
        "password-control": "The password cannot contain control characters.",
        "password-mismatch": "The passwords do not match.",
        "startup-missing": "Type the passphrase you used at startup.",
        "startup-wrong": "That passphrase does not unlock this disk.",
        "boot-keymap": "This layout cannot be used at the disk unlock screen. Choose another layout.",
        "choice": "Choose an item from the list.",
        "failed": "Something went wrong. Try again."
    })

    readonly property var stageLabels: ({
        "account": "Creating your account",
        "desktop": "Preparing your desktop",
        "disk": "Securing the disk",
        "finish": "Finishing up"
    })

    function problemText(code) {
        return code === "" ? "" : tr(problems[code] !== undefined ? problems[code] : problems.failed);
    }

    // The service's answer about one field, until that field is edited.
    function serviceProblem(field) {
        return setup.errorField === field ? setup.errorCode : "";
    }

    // ---- the account rules (shared with the service) ------------------------

    function fullNameProblem() {
        return setup.fullNameProblem(fullNameField.text);
    }
    function usernameProblem() {
        return usernameField.text.trim() === "" ? "username-empty" : setup.usernameProblem(usernameField.text);
    }
    function passwordProblem() {
        const code = setup.passwordProblem(passwordField.text, confirmField.text);
        return code === "password-mismatch" ? "" : code;
    }
    function confirmProblem() {
        return setup.passwordProblem(passwordField.text, confirmField.text) === "password-mismatch"
            ? "password-mismatch" : "";
    }
    function startupProblem() {
        return setup.encrypted && startupField.text === "" ? "startup-missing" : "";
    }

    function firstInvalid() {
        const checks = [[fullNameField, fullNameProblem()], [usernameField, usernameProblem()],
                        [passwordField, passwordProblem()], [confirmField, confirmProblem()],
                        [startupField, startupProblem()]];
        for (const check of checks) {
            if (check[1] !== "")
                return check[0];
        }
        return null;
    }

    // ---- navigation ---------------------------------------------------------

    function next() {
        if (page === 0) {
            if (setup.state !== "idle")
                return;
            page = 1;
            fullNameField.input.forceActiveFocus();
        } else if (page === 1) {
            showErrors = true;
            const invalid = firstInvalid();
            if (invalid !== null) {
                invalid.input.forceActiveFocus();
                return;
            }
            page = 2;
            timezoneList.field.forceActiveFocus();
        } else if (page === 2 || (page === 3 && setup.state === "failed")) {
            submit();
        } else if (page === 3 && setup.state === "done") {
            setup.restartNow();
        }
    }

    function back() {
        if (page === 3 && setup.state === "failed") {
            setup.clearError("");
            page = 1;
        } else if (page === 1 || page === 2) {
            page -= 1;
        }
    }

    function submit() {
        page = 3;
        setup.submit(fullNameField.text, usernameField.text, passwordField.text, confirmField.text,
                     startupField.text, timezone);
    }

    Component.onCompleted: {
        if (setup.focus === "keyboard-test")
            keyboardTest.forceActiveFocus();
        else
            languageList.field.forceActiveFocus();
    }

    Connections {
        target: setup
        function onChanged() {
            const field = setup.errorField;
            if (field === "")
                return;
            // Back to the question the service asks again.
            if (["full_name", "username", "password", "confirm", "startup"].indexOf(field) >= 0) {
                window.page = 1;
                window.showErrors = true;
                const inputs = { full_name: fullNameField, username: usernameField, password: passwordField,
                                 confirm: confirmField, startup: startupField };
                inputs[field].input.forceActiveFocus();
            } else if (field === "timezone") {
                window.page = 2;
            } else {
                window.page = 0;
            }
        }
    }

    Timer {
        running: setup.state === "done"
        interval: 1000
        repeat: true
        onTriggered: {
            window.countdown -= 1;
            if (window.countdown <= 0) {
                stop();
                setup.restartNow();
            }
        }
    }

    // ---- building blocks ----------------------------------------------------

    component ActionButton: Button {
        id: button
        property bool primary: false
        implicitHeight: Math.round(48 * window.u)
        leftPadding: Math.round(26 * window.u)
        rightPadding: Math.round(26 * window.u)
        font.weight: Font.DemiBold
        font.pixelSize: Math.round(16 * window.u)
        Accessible.name: text
        // Return and Enter press a focused button too, not only Space.
        Keys.onReturnPressed: clicked()
        Keys.onEnterPressed: clicked()
        background: Rectangle {
            radius: Math.round(12 * window.u)
            color: button.primary
                ? (button.down ? window.accentDown : button.hovered ? window.accentHover : window.accent)
                : (button.hovered ? window.surfaceHover : window.surface)
            opacity: button.enabled ? 1 : 0.5
            border.width: button.visualFocus ? Math.round(2 * window.u) : 0
            border.color: "#ffffff"
        }
        contentItem: Text {
            text: button.text
            color: button.primary ? "#ffffff" : window.ink
            font: button.font
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
        }
    }

    component Input: TextField {
        id: input
        Layout.fillWidth: true
        implicitHeight: Math.round(48 * window.u)
        leftPadding: Math.round(12 * window.u)
        rightPadding: Math.round(12 * window.u)
        color: window.ink
        placeholderTextColor: window.inkFaint
        selectionColor: window.accent
        selectedTextColor: "#ffffff"
        font.pixelSize: Math.round(16 * window.u)
        background: Rectangle {
            radius: Math.round(12 * window.u)
            color: window.surface
            border.width: input.activeFocus ? Math.round(2 * window.u) : 1
            border.color: input.activeFocus ? window.ink : input.hovered ? window.inkFaint : window.stroke
        }
    }

    component Caption: Text {
        Layout.fillWidth: true
        color: window.ink
        font.pixelSize: Math.round(14 * window.u)
        wrapMode: Text.WordWrap
    }

    component Hint: Text {
        Layout.fillWidth: true
        color: window.inkMid
        font.pixelSize: Math.round(13 * window.u)
        wrapMode: Text.WordWrap
        lineHeight: 1.3
    }

    component Problem: Text {
        Layout.fillWidth: true
        visible: text !== ""
        color: window.accentText
        font.pixelSize: Math.round(13 * window.u)
        wrapMode: Text.WordWrap
        Accessible.role: Accessible.AlertMessage
        Accessible.name: text
    }

    // A labelled field with its hint or problem below it.
    component Field: ColumnLayout {
        id: field
        property string label: ""
        property string hint: ""
        property string problem: ""
        property alias text: entry.text
        property alias input: entry
        property alias echoMode: entry.echoMode
        property alias maximumLength: entry.maximumLength
        property alias inputMethodHints: entry.inputMethodHints
        signal edited()
        Layout.fillWidth: true
        spacing: Math.round(8 * window.u)
        Caption { text: field.label }
        Input {
            id: entry
            objectName: field.objectName + "Input"
            Accessible.name: field.label
            Accessible.description: field.problem !== "" ? field.problem : field.hint
            onTextEdited: field.edited()
            Keys.onReturnPressed: window.next()
            Keys.onEnterPressed: window.next()
        }
        Problem { text: field.problem }
        Hint { visible: field.problem === "" && field.hint !== ""; text: field.hint }
    }

    // A search box over a list; Enter or a click chooses. Long lists
    // (languages, layouts, time zones) stay usable from the keyboard alone.
    component SearchList: ColumnLayout {
        id: list
        property string label: ""
        property string placeholder: ""
        property var entries: []
        property string current: ""
        property alias field: search
        property alias view: view
        readonly property var shown: {
            const words = search.text.trim().toLowerCase().split(/\s+/).filter(word => word !== "");
            return words.length === 0 ? entries
                : entries.filter(entry => words.every(word => entry.search.indexOf(word) >= 0));
        }
        signal chosen(string id)
        spacing: Math.round(8 * window.u)

        function choose(index) {
            if (index >= 0 && index < shown.length)
                chosen(shown[index].id);
        }
        function reveal() {
            const index = shown.findIndex(entry => entry.id === current);
            view.currentIndex = index >= 0 ? index : 0;
            if (view.count > 0)
                view.positionViewAtIndex(view.currentIndex, ListView.Center);
        }
        onShownChanged: reveal()
        Component.onCompleted: reveal()

        Caption { text: list.label }
        Input {
            id: search
            placeholderText: list.placeholder
            inputMethodHints: Qt.ImhNoPredictiveText
            Accessible.name: list.label
            Keys.onDownPressed: view.forceActiveFocus()
            Keys.onReturnPressed: list.choose(view.currentIndex)
            Keys.onEnterPressed: list.choose(view.currentIndex)
        }
        Rectangle {
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.minimumHeight: 4 * window.rowHeight + Math.round(12 * window.u)
            radius: Math.round(12 * window.u)
            color: window.surface
            border.width: view.activeFocus ? Math.round(2 * window.u) : 1
            border.color: view.activeFocus ? window.ink : window.stroke

            ListView {
                id: view
                anchors.fill: parent
                anchors.margins: Math.round(6 * window.u)
                clip: true
                model: list.shown
                boundsBehavior: Flickable.StopAtBounds
                keyNavigationEnabled: true
                activeFocusOnTab: true
                highlightMoveDuration: 0
                Accessible.role: Accessible.List
                Accessible.name: list.label
                ScrollBar.vertical: ScrollBar {}
                Keys.onReturnPressed: list.choose(currentIndex)
                Keys.onEnterPressed: list.choose(currentIndex)
                Keys.onSpacePressed: list.choose(currentIndex)
                Keys.onUpPressed: event => {
                    if (currentIndex <= 0)
                        search.forceActiveFocus();
                    else
                        decrementCurrentIndex();
                }

                delegate: Rectangle {
                    id: row
                    required property var modelData
                    required property int index
                    readonly property bool selected: modelData.id === list.current
                    readonly property bool focused: view.activeFocus && view.currentIndex === index
                    width: view.width
                    height: window.rowHeight
                    radius: Math.round(8 * window.u)
                    color: selected ? Qt.rgba(0.867, 0, 0.204, 0.24)
                        : rowMouse.containsMouse || focused ? window.surfaceHover : "transparent"
                    border.width: focused ? Math.round(2 * window.u) : 0
                    border.color: window.ink
                    Accessible.role: Accessible.ListItem
                    Accessible.name: modelData.label
                    Accessible.selected: selected

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: Math.round(12 * window.u)
                        anchors.rightMargin: Math.round(12 * window.u)
                        spacing: Math.round(12 * window.u)
                        Text {
                            Layout.fillWidth: true
                            text: row.modelData.label
                            color: window.ink
                            font.pixelSize: Math.round(15 * window.u)
                            font.weight: row.selected ? Font.DemiBold : Font.Normal
                            elide: Text.ElideRight
                        }
                        Text {
                            Layout.maximumWidth: row.width * 0.45
                            text: row.modelData.detail
                            color: window.inkFaint
                            font.pixelSize: Math.round(13 * window.u)
                            elide: Text.ElideRight
                        }
                    }
                    MouseArea {
                        id: rowMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            view.currentIndex = row.index;
                            view.forceActiveFocus();
                            list.chosen(row.modelData.id);
                        }
                    }
                }
            }

            Text {
                anchors.centerIn: parent
                visible: list.shown.length === 0
                text: window.tr("No matches")
                color: window.inkFaint
                font.pixelSize: Math.round(15 * window.u)
            }
        }
    }

    // ---- the window -----------------------------------------------------------

    RowLayout {
        anchors.fill: parent
        spacing: 0

        Rectangle {
            Layout.fillHeight: true
            Layout.preferredWidth: Math.round(Math.max(280 * window.u, window.width * 0.3))
            color: window.surface

            Rectangle {
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                width: 1
                color: window.stroke
            }

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: Math.round(40 * window.u)
                spacing: 0

                Image {
                    source: "../welcome/cybex-wordmark.svg"
                    Layout.preferredHeight: Math.round(30 * window.u)
                    Layout.preferredWidth: Math.round(30 * window.u * 198 / 46.6)
                    sourceSize.height: Math.round(90 * window.u)
                    fillMode: Image.PreserveAspectFit
                    smooth: true
                    Accessible.role: Accessible.Graphic
                    Accessible.name: "Cybex"
                }
                Item { Layout.preferredHeight: Math.round(64 * window.u) }
                Text {
                    Layout.fillWidth: true
                    text: window.tr("Make it yours.")
                    color: window.ink
                    font.pixelSize: Math.round(44 * window.u)
                    font.weight: Font.DemiBold
                    font.letterSpacing: -1
                    wrapMode: Text.WordWrap
                }
                Item { Layout.preferredHeight: Math.round(18 * window.u) }
                Text {
                    Layout.fillWidth: true
                    text: window.tr("A few choices and your desktop is ready.")
                    color: window.inkMid
                    font.pixelSize: Math.round(16 * window.u)
                    wrapMode: Text.WordWrap
                    lineHeight: 1.5
                }
                Item { Layout.preferredHeight: Math.round(30 * window.u) }
                Repeater {
                    model: window.steps
                    delegate: RowLayout {
                        id: step
                        required property string modelData
                        required property int index
                        Layout.topMargin: Math.round(17 * window.u)
                        spacing: Math.round(12 * window.u)
                        Text {
                            text: "0" + (step.index + 1)
                            color: step.index === window.page ? window.accentText : window.inkMid
                            font.pixelSize: Math.round(12 * window.u)
                            font.letterSpacing: 1
                        }
                        Text {
                            text: window.tr(step.modelData)
                            color: step.index === window.page ? window.accentText : window.inkMid
                            font.pixelSize: Math.round(15 * window.u)
                        }
                    }
                }
                Item { Layout.fillHeight: true }
                Text {
                    text: "CYBEX OPINIONATED SYSTEM"
                    color: window.inkFaint
                    font.pixelSize: Math.round(10 * window.u)
                    font.letterSpacing: 1.6
                }
            }
        }

        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true

            ColumnLayout {
                id: main
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.topMargin: Math.round(44 * window.u)
                anchors.bottomMargin: Math.round(32 * window.u)
                width: Math.min(parent.width - Math.round(2 * 56 * window.u), Math.round(860 * window.u))
                spacing: 0

                Text {
                    text: "0" + (window.page + 1) + " / " + window.tr(window.steps[window.page])
                    color: window.inkFaint
                    font.pixelSize: Math.round(12 * window.u)
                    font.weight: Font.DemiBold
                    font.letterSpacing: 1.2
                    font.capitalization: Font.AllUppercase
                }
                Text {
                    objectName: "heading"
                    Layout.fillWidth: true
                    Layout.topMargin: Math.round(12 * window.u)
                    text: window.tr(window.page === 0 ? "Welcome."
                        : window.page === 1 ? "Your account."
                        : window.page === 2 ? "Your time zone."
                        : setup.state === "done" ? "Ready."
                        : setup.state === "failed" ? "Setup did not finish." : "Setting up…")
                    color: window.ink
                    font.pixelSize: Math.round(38 * window.u)
                    font.weight: Font.DemiBold
                    font.letterSpacing: -1
                    wrapMode: Text.WordWrap
                    Accessible.role: Accessible.Heading
                    Accessible.name: text
                }
                Text {
                    Layout.fillWidth: true
                    Layout.topMargin: Math.round(10 * window.u)
                    text: window.tr(window.page === 0
                        ? "Let's set up this computer for you. First, choose your language and keyboard."
                        : window.page === 1 ? "You use it to sign in and to approve administrator tasks."
                        : window.page === 2 ? "Choose where you are, so the clock is right."
                        : setup.state === "done" ? "Your account is ready. The computer restarts to finish setting up."
                        : setup.state === "failed" ? "Nothing was kept. You can try again."
                        : "This takes a few minutes. Keep the computer on.")
                    color: window.inkMid
                    font.pixelSize: Math.round(16 * window.u)
                    wrapMode: Text.WordWrap
                    lineHeight: 1.45
                }
                Item { Layout.preferredHeight: Math.round(22 * window.u) }

                // One page at a time, each sized to this area. (A StackLayout
                // would take its height from the hidden pages' wrapped text.)
                Item {
                    Layout.fillWidth: true
                    Layout.fillHeight: true

                    // ---- 01 welcome: language and keyboard ----------------
                    ColumnLayout {
                        anchors.fill: parent
                        visible: window.page === 0
                        spacing: Math.round(16 * window.u)
                        RowLayout {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            spacing: Math.round(24 * window.u)
                            SearchList {
                                id: languageList
                                objectName: "languageList"
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                Layout.preferredWidth: 1
                                label: window.tr("Language")
                                placeholder: window.tr("Search")
                                entries: setup.locales
                                current: setup.locale
                                onChosen: id => setup.locale = id
                            }
                            SearchList {
                                id: keyboardList
                                objectName: "keyboardList"
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                Layout.preferredWidth: 1
                                enabled: setup.state === "idle"
                                label: window.tr("Keyboard layout")
                                placeholder: window.tr("Search")
                                entries: setup.keyboards
                                current: setup.keyboard
                                onChosen: id => setup.chooseKeyboard(id)
                            }
                        }
                        Problem {
                            objectName: "keyboardProblem"
                            text: setup.state === "switching" ? ""
                                : window.problemText(window.serviceProblem("keyboard"))
                        }
                        Hint {
                            visible: setup.state === "switching"
                            text: window.tr("Switching keyboard layout…")
                            Accessible.role: Accessible.StaticText
                        }
                        Caption { text: window.tr("Try your keyboard") }
                        Input {
                            id: keyboardTest
                            objectName: "keyboardTest"
                            placeholderText: window.tr("Type here to test your keyboard")
                            inputMethodHints: Qt.ImhNoPredictiveText
                            Accessible.name: window.tr("Try your keyboard")
                        }
                    }

                    // ---- 02 account ---------------------------------------
                    ColumnLayout {
                        anchors.fill: parent
                        visible: window.page === 1
                        spacing: Math.round(16 * window.u)
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Math.round(16 * window.u)
                            Field {
                                id: fullNameField
                                objectName: "fullName"
                                Layout.preferredWidth: 1
                                Layout.alignment: Qt.AlignTop
                                label: window.tr("Full name")
                                maximumLength: 128
                                problem: window.problemText((window.showErrors ? window.fullNameProblem() : "")
                                                            || window.serviceProblem("full_name"))
                                onTextChanged: {
                                    if (!window.usernameEdited)
                                        usernameField.text = setup.deriveUsername(text);
                                }
                                onEdited: setup.clearError("full_name")
                            }
                            Field {
                                id: usernameField
                                objectName: "username"
                                Layout.preferredWidth: 1
                                Layout.alignment: Qt.AlignTop
                                label: window.tr("Username")
                                hint: window.tr("Lowercase letters, numbers, dashes and underscores.")
                                maximumLength: 31
                                inputMethodHints: Qt.ImhNoAutoUppercase | Qt.ImhNoPredictiveText | Qt.ImhPreferLowercase
                                problem: window.problemText((window.showErrors ? window.usernameProblem() : "")
                                                            || window.serviceProblem("username"))
                                onEdited: {
                                    window.usernameEdited = text !== "";
                                    setup.clearError("username");
                                }
                            }
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Math.round(16 * window.u)
                            Field {
                                id: passwordField
                                objectName: "password"
                                Layout.preferredWidth: 1
                                Layout.alignment: Qt.AlignTop
                                label: window.tr("Password")
                                echoMode: TextInput.Password
                                maximumLength: 512
                                inputMethodHints: Qt.ImhSensitiveData | Qt.ImhNoPredictiveText
                                hint: window.tr("Use at least 12 characters.")
                                problem: window.problemText((window.showErrors ? window.passwordProblem() : "")
                                                            || window.serviceProblem("password"))
                                onEdited: setup.clearError("password")
                            }
                            Field {
                                id: confirmField
                                objectName: "confirm"
                                Layout.preferredWidth: 1
                                Layout.alignment: Qt.AlignTop
                                label: window.tr("Confirm password")
                                echoMode: TextInput.Password
                                maximumLength: 512
                                inputMethodHints: Qt.ImhSensitiveData | Qt.ImhNoPredictiveText
                                problem: window.problemText((window.showErrors ? window.confirmProblem() : "")
                                                            || window.serviceProblem("confirm"))
                                onEdited: setup.clearError("confirm")
                            }
                        }
                        // On an encrypted disk the account password replaces the
                        // temporary passphrase, which authorizes the change.
                        Rectangle {
                            visible: setup.encrypted
                            Layout.fillWidth: true
                            Layout.topMargin: Math.round(4 * window.u)
                            Layout.preferredHeight: diskColumn.implicitHeight + Math.round(32 * window.u)
                            radius: Math.round(16 * window.u)
                            color: window.surface
                            border.width: 1
                            border.color: window.stroke
                            ColumnLayout {
                                id: diskColumn
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.top: parent.top
                                anchors.margins: Math.round(16 * window.u)
                                spacing: Math.round(10 * window.u)
                                Text {
                                    Layout.fillWidth: true
                                    text: window.tr("This password also unlocks the disk when the computer starts.")
                                    color: window.ink
                                    font.pixelSize: Math.round(15 * window.u)
                                    font.weight: Font.DemiBold
                                    wrapMode: Text.WordWrap
                                }
                                Field {
                                    id: startupField
                                    objectName: "startup"
                                    label: window.tr("Temporary disk passphrase")
                                    echoMode: TextInput.Password
                                    maximumLength: 512
                                    inputMethodHints: Qt.ImhSensitiveData | Qt.ImhNoPredictiveText
                                    hint: window.tr("The passphrase you typed to start this computer. It stops working once setup is done.")
                                    problem: window.problemText((window.showErrors ? window.startupProblem() : "")
                                                                || window.serviceProblem("startup"))
                                    onEdited: setup.clearError("startup")
                                }
                            }
                        }
                        Item { Layout.fillHeight: true }
                    }

                    // ---- 03 time zone -------------------------------------
                    ColumnLayout {
                        anchors.fill: parent
                        visible: window.page === 2
                        spacing: Math.round(12 * window.u)
                        SearchList {
                            id: timezoneList
                            objectName: "timezoneList"
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            label: window.tr("Time zone")
                            placeholder: window.tr("Search for a city")
                            entries: setup.timezones
                            current: window.timezone
                            onChosen: id => window.timezone = id
                        }
                        Problem { text: window.problemText(window.serviceProblem("timezone")) }
                    }

                    // ---- 04 finishing -------------------------------------
                    ColumnLayout {
                        anchors.fill: parent
                        visible: window.page === 3
                        objectName: "finishing"
                        spacing: Math.round(14 * window.u)
                        Repeater {
                            model: setup.state === "working" ? setup.stages : []
                            delegate: RowLayout {
                                id: stageRow
                                required property string modelData
                                required property int index
                                readonly property int reached: setup.stages.indexOf(setup.stage)
                                spacing: Math.round(14 * window.u)
                                Rectangle {
                                    implicitWidth: Math.round(14 * window.u)
                                    implicitHeight: implicitWidth
                                    radius: implicitWidth / 2
                                    color: stageRow.index < stageRow.reached ? window.accent : "transparent"
                                    border.width: Math.round(2 * window.u)
                                    border.color: stageRow.index <= stageRow.reached ? window.accent : window.stroke
                                }
                                Text {
                                    text: window.tr(window.stageLabels[stageRow.modelData])
                                    color: stageRow.index === stageRow.reached ? window.ink : window.inkMid
                                    font.pixelSize: Math.round(16 * window.u)
                                    font.weight: stageRow.index === stageRow.reached ? Font.DemiBold : Font.Normal
                                }
                            }
                        }
                        ProgressBar {
                            id: progressBar
                            visible: setup.state === "working"
                            Layout.fillWidth: true
                            Layout.topMargin: Math.round(10 * window.u)
                            indeterminate: true
                            background: Rectangle {
                                implicitHeight: Math.round(4 * window.u)
                                radius: height / 2
                                color: window.stroke
                            }
                            contentItem: Item {
                                implicitHeight: Math.round(4 * window.u)
                                clip: true
                                Rectangle {
                                    id: runner
                                    width: parent.width * 0.3
                                    height: parent.height
                                    radius: height / 2
                                    color: window.accent
                                    NumberAnimation on x {
                                        from: -runner.width
                                        to: progressBar.width
                                        duration: 1600
                                        loops: Animation.Infinite
                                        running: progressBar.visible
                                    }
                                }
                            }
                        }
                        Problem {
                            objectName: "failure"
                            text: setup.state === "failed" ? window.problemText("failed")
                                + (setup.errorDetail !== "" ? "\n" + setup.errorDetail : "") : ""
                        }
                        Hint {
                            visible: setup.state === "done" && setup.encrypted
                            text: window.tr("When it starts, unlock the disk with your new password.")
                            font.pixelSize: Math.round(16 * window.u)
                            color: window.ink
                        }
                        Hint {
                            visible: setup.state === "done"
                            text: window.tr("Restarting in %1 seconds").arg(window.countdown)
                            Accessible.role: Accessible.StaticText
                        }
                        Item { Layout.fillHeight: true }
                    }
                }

                Rectangle {
                    Layout.fillWidth: true
                    Layout.topMargin: Math.round(20 * window.u)
                    Layout.preferredHeight: 1
                    color: window.stroke
                    visible: primaryButton.visible
                }
                RowLayout {
                    Layout.fillWidth: true
                    Layout.topMargin: Math.round(16 * window.u)
                    spacing: Math.round(16 * window.u)
                    Item { Layout.fillWidth: true }
                    ActionButton {
                        objectName: "backButton"
                        visible: window.page === 1 || window.page === 2
                            || (window.page === 3 && setup.state === "failed")
                        text: window.tr("Back")
                        onClicked: window.back()
                    }
                    ActionButton {
                        id: primaryButton
                        objectName: "primaryButton"
                        primary: true
                        visible: window.page < 3 || setup.state === "failed" || setup.state === "done"
                        enabled: window.page !== 0 || setup.state === "idle"
                        text: window.tr(window.page === 2 ? "Set up"
                            : window.page === 3 && setup.state === "failed" ? "Try again"
                            : window.page === 3 ? "Restart now" : "Continue")
                        onClicked: window.next()
                    }
                }
            }
        }
    }
}
