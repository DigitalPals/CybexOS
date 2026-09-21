pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import "../Common"
import "../Common/CalendarHelpers.js" as CalendarHelpers

Surface {
    id: root

    property int monthOffset: 0
    property var selectedDate: new Date(clock.date.getFullYear(),
        clock.date.getMonth(), clock.date.getDate())
    property bool upcomingMode: true

    readonly property var now: clock.date
    readonly property var shownMonth: new Date(now.getFullYear(),
        now.getMonth() + monthOffset, 1)
    readonly property var serviceEvents: Calendar.events
    readonly property bool eventsEnabled: Calendar.enabled

    implicitWidth: availableWidth > 0
        ? Math.min(Theme.popWideWidth, availableWidth) : Theme.popWideWidth
    spacing: 6

    function sameDay(left, right) {
        return left.getFullYear() === right.getFullYear()
            && left.getMonth() === right.getMonth()
            && left.getDate() === right.getDate();
    }

    function selectDay(value) {
        selectedDate = new Date(value.getFullYear(), value.getMonth(), value.getDate());
        upcomingMode = false;
        monthOffset = (value.getFullYear() - now.getFullYear()) * 12
            + value.getMonth() - now.getMonth();
    }

    function showToday() {
        monthOffset = 0;
        selectedDate = new Date(now.getFullYear(), now.getMonth(), now.getDate());
        upcomingMode = true;
        if (eventsEnabled)
            Calendar.ensureMonth(shownMonth, false);
    }

    function dayStart(value) {
        return new Date(value.getFullYear(), value.getMonth(), value.getDate()).getTime();
    }

    function dayEnd(value) {
        return new Date(value.getFullYear(), value.getMonth(), value.getDate() + 1).getTime();
    }

    function eventTime(event) {
        if (event.allDay)
            return "All day";
        const format = Settings.clock24 ? "HH:mm" : "h:mm AP";
        const start = new Date(event.startMs);
        const end = new Date(event.endMs);
        if (event.startMs <= now.getTime() && event.endMs > now.getTime())
            return "Now–" + Qt.formatDateTime(end, format);
        if (sameDay(start, end))
            return Qt.formatDateTime(start, format) + "–" + Qt.formatDateTime(end, format);
        return Qt.formatDateTime(start, "ddd " + format) + "–"
            + Qt.formatDateTime(end, "ddd " + format);
    }

    function eventMeta(event) {
        const parts = [];
        if (upcomingMode)
            parts.push(Qt.formatDateTime(new Date(event.startMs), "ddd, d MMM"));
        parts.push(eventTime(event));
        if (event.calendar !== "")
            parts.push(event.calendar);
        if (event.location !== "")
            parts.push(event.location);
        return parts.join("  ·  ");
    }

    onShownMonthChanged: {
        if (eventsEnabled)
            Calendar.ensureMonth(shownMonth, false);
    }

    SystemClock {
        id: clock
        precision: SystemClock.Minutes
    }

    Component.onCompleted: {
        if (eventsEnabled)
            Calendar.ensureMonth(shownMonth, false);
    }

    // Big time + date header.
    Item {
        width: parent.width
        height: 42

        Text {
            id: timeText
            anchors.left: parent.left
            anchors.leftMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            text: Qt.formatDateTime(root.now, Settings.clock24 ? "HH:mm" : "h:mm AP")
            font.family: Theme.fontMono
            font.pixelSize: Theme.typography.display
            font.weight: Theme.weightSemibold
            font.features: Theme.tabularNumberFeatures
            color: Theme.textHi
        }

        Text {
            anchors.left: timeText.right
            anchors.leftMargin: 10
            anchors.right: parent.right
            anchors.baseline: timeText.baseline
            text: Qt.formatDateTime(root.now, "dddd, MMMM d")
            elide: Text.ElideRight
            font.family: Theme.fontMenu
            font.pixelSize: Theme.typography.primary
            color: Theme.textLow
        }
    }

    // Month navigation. Today also restores the default upcoming agenda.
    Item {
        width: parent.width
        height: Theme.listRowHeight

        Text {
            anchors.left: parent.left
            anchors.leftMargin: 10
            anchors.right: monthActions.left
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            text: Qt.formatDateTime(root.shownMonth, "MMMM yyyy")
            elide: Text.ElideRight
            font.family: Theme.fontMenu
            font.pixelSize: Theme.typography.primary
            font.weight: Theme.weightSemibold
            color: Theme.textMid
        }

        Row {
            id: monthActions
            anchors.right: parent.right
            anchors.rightMargin: 4
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2

            IconButton {
                symbol: "today"
                tint: Theme.textLow
                controlSize: Theme.chipHeight
                accessibleName: "Show today and upcoming events"
                onTriggered: root.showToday()
            }

            IconButton {
                symbol: "chevron_left"
                tint: Theme.textLow
                controlSize: Theme.chipHeight
                accessibleName: "Previous month"
                onTriggered: root.monthOffset--
            }

            IconButton {
                symbol: "chevron_right"
                tint: Theme.textLow
                controlSize: Theme.chipHeight
                accessibleName: "Next month"
                onTriggered: root.monthOffset++
            }
        }
    }

    // Monday-first month grid. EDS calendar colors become small event marks;
    // only three are drawn so a busy date stays a date rather than a chart.
    Grid {
        id: calendarGrid
        columns: 7
        rowSpacing: 1
        width: parent.width - 8
        x: 4

        Repeater {
            model: ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"]

            delegate: Text {
                required property string modelData
                width: calendarGrid.width / 7
                height: 20
                text: modelData
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                font.family: Theme.fontMono
                font.pixelSize: Theme.typography.secondary
                font.weight: Theme.weightMedium
                color: Theme.textFaint
            }
        }

        Repeater {
            model: 42

            delegate: Rectangle {
                id: day

                required property int index
                readonly property var cell: {
                    const first = root.shownMonth;
                    const startOffset = (first.getDay() + 6) % 7;
                    return new Date(first.getFullYear(), first.getMonth(),
                        1 - startOffset + index);
                }
                readonly property bool inMonth: cell.getMonth() === root.shownMonth.getMonth()
                    && cell.getFullYear() === root.shownMonth.getFullYear()
                readonly property bool isToday: root.sameDay(cell, root.now)
                readonly property bool selected: !root.upcomingMode
                    && root.sameDay(cell, root.selectedDate)
                readonly property var matches: root.eventsEnabled
                    ? CalendarHelpers.eventsInRange(root.serviceEvents,
                        root.dayStart(cell), root.dayEnd(cell), 3) : []

                width: calendarGrid.width / 7
                height: 28
                radius: Theme.chipRadius
                color: isToday ? Theme.accent
                    : selected ? Theme.accentBgSoft
                    : dayMouse.containsMouse ? Theme.hoverFillStrong : "transparent"
                border.width: selected && !isToday ? 1 : 0
                border.color: Theme.accent
                activeFocusOnTab: true
                Accessible.role: Accessible.Button
                Accessible.name: Qt.formatDateTime(cell, "dddd, MMMM d")
                    + (matches.length > 0 ? ", " + matches.length + " events" : "")
                Accessible.onPressAction: root.selectDay(day.cell)

                Keys.onPressed: event => {
                    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                            || event.key === Qt.Key_Space) {
                        root.selectDay(day.cell);
                        event.accepted = true;
                    }
                }

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: day.matches.length > 0 ? 2 : 5
                    text: day.cell.getDate()
                    font.family: Theme.fontMono
                    font.pixelSize: Theme.typography.primary
                    font.weight: day.isToday || day.selected
                        ? Theme.weightSemibold : Theme.weightRegular
                    color: day.isToday ? Theme.accentFg
                        : day.inMonth ? Theme.textMid : Theme.textFaint
                }

                Row {
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: 3
                    spacing: 2

                    Repeater {
                        model: day.matches

                        delegate: Rectangle {
                            required property var modelData
                            width: 3
                            height: 3
                            radius: 2
                            color: day.isToday ? Theme.accentFg : modelData.color
                        }
                    }
                }

                MouseArea {
                    id: dayMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        day.forceActiveFocus();
                        root.selectDay(day.cell);
                    }
                }
            }
        }
    }

    Rectangle {
        visible: root.eventsEnabled
        width: parent.width
        height: 1
        color: Theme.hairlineSoft
    }

    Column {
        id: agenda
        visible: root.eventsEnabled
        width: parent.width
        spacing: 6

        readonly property double selectedStart: root.dayStart(root.selectedDate)
        readonly property double selectedEnd: root.dayEnd(root.selectedDate)
        readonly property double upcomingEnd: {
            const value = root.now;
            return new Date(value.getFullYear(), value.getMonth(),
                value.getDate() + Calendar.daysAhead + 1).getTime();
        }
        readonly property var rows: root.upcomingMode
            ? CalendarHelpers.upcoming(root.serviceEvents, root.now.getTime(), upcomingEnd, 30)
            : CalendarHelpers.eventsInRange(root.serviceEvents,
                selectedStart, selectedEnd, 30)
        readonly property bool showFirstLoad: Calendar.loading && !Calendar.ready
        readonly property bool showFailure: Calendar.fetchError !== ""
            && (!Calendar.ready || !Calendar.available)
        readonly property bool needsGoogle: !Calendar.googleConnected
        readonly property bool calendarOff: Calendar.googleConnected
            && !Calendar.googleCalendarEnabled

        Item {
            width: parent.width
            height: 32

            Text {
                anchors.left: parent.left
                anchors.leftMargin: 8
                anchors.right: accountButton.left
                anchors.rightMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                text: root.upcomingMode ? "UPCOMING"
                    : Qt.formatDateTime(root.selectedDate, "dddd, d MMMM").toUpperCase()
                elide: Text.ElideRight
                font.family: Theme.fontMono
                font.pixelSize: Theme.typography.section
                font.weight: Theme.weightSemibold
                color: Theme.textFaint
            }

            ActionButton {
                id: accountButton
                anchors.right: refreshButton.left
                anchors.rightMargin: 4
                anchors.verticalCenter: parent.verticalCenter
                label: agenda.needsGoogle ? "Connect Google" : "Accounts"
                hPadding: 14
                tint: Theme.textLow
                fill: "transparent"
                onTriggered: Calendar.manageAccounts()
            }

            IconButton {
                id: refreshButton
                anchors.right: parent.right
                anchors.rightMargin: 4
                anchors.verticalCenter: parent.verticalCenter
                symbol: "refresh"
                tint: Calendar.fetchError !== "" ? Theme.redText : Theme.textLow
                controlSize: Theme.chipHeight
                enabled: !Calendar.loading
                accessibleName: Calendar.loading ? "Refreshing calendars"
                    : "Refresh calendars"
                onTriggered: Calendar.refresh()
            }
        }

        StatusPlaceholder {
            width: parent.width
            shown: agenda.rows.length === 0
            kind: agenda.showFirstLoad ? "loading" : agenda.showFailure ? "error" : "empty"
            glyph: agenda.showFirstLoad ? "progress_activity"
                : agenda.showFailure ? "event_busy"
                : agenda.needsGoogle ? "account_circle"
                : agenda.calendarOff ? "sync_disabled" : "event_available"
            title: agenda.showFirstLoad ? "Checking calendars"
                : agenda.showFailure ? "Calendar unavailable"
                : agenda.needsGoogle ? "Connect Google Calendar"
                : agenda.calendarOff ? "Calendar sync is off"
                : root.upcomingMode ? "No upcoming events" : "Nothing on this date"
            detail: agenda.showFirstLoad
                ? "Reading the Evolution Data Server cache"
                : agenda.showFailure ? Calendar.fetchError
                : agenda.needsGoogle
                    ? "Add a Google account in Online Accounts; GNOME keeps the sign-in and sync credentials."
                : agenda.calendarOff
                    ? "Enable Calendar for the Google account in Online Accounts."
                : root.upcomingMode
                    ? "Nothing scheduled in the next " + Calendar.daysAhead + " days."
                : "Choose another date or return to Upcoming."
        }

        Row {
            visible: agenda.rows.length === 0
                && (agenda.needsGoogle || agenda.calendarOff || agenda.showFailure)
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: 6

            ActionButton {
                label: agenda.needsGoogle ? "Open Online Accounts"
                    : agenda.calendarOff ? "Manage account" : "Try again"
                tint: agenda.showFailure ? Theme.redText : Theme.accent
                fill: agenda.showFailure ? Theme.redBgSoft : Theme.accentBgSoft
                onTriggered: {
                    if (agenda.showFailure && !agenda.needsGoogle && !agenda.calendarOff)
                        Calendar.refresh();
                    else
                        Calendar.manageAccounts();
                }
            }
        }

        Item {
            width: parent.width
            implicitHeight: agenda.rows.length > 0
                ? Math.min(eventRows.implicitHeight, Math.max(110,
                    Math.min(230, root.availableHeight > 0
                        ? root.availableHeight - 300 : 230))) : 0
            height: implicitHeight
            visible: agenda.rows.length > 0
            clip: true

            Flickable {
                id: eventFlick
                anchors.fill: parent
                contentWidth: width
                contentHeight: eventRows.implicitHeight
                boundsBehavior: Flickable.StopAtBounds
                flickableDirection: Flickable.VerticalFlick

                Column {
                    id: eventRows
                    width: eventFlick.width
                    spacing: 2

                    Repeater {
                        model: agenda.rows

                        delegate: Rectangle {
                            id: eventRow

                            required property var modelData
                            width: eventRows.width
                            height: 46
                            radius: Theme.rowRadius
                            color: eventMouse.containsMouse ? Theme.hoverFillStrong : "transparent"
                            activeFocusOnTab: true
                            Accessible.role: Accessible.Button
                            Accessible.name: modelData.summary + ", " + root.eventMeta(modelData)
                            Accessible.onPressAction: Calendar.openCalendar(modelData.startMs)

                            Keys.onPressed: event => {
                                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                                        || event.key === Qt.Key_Space) {
                                    Calendar.openCalendar(eventRow.modelData.startMs);
                                    event.accepted = true;
                                }
                            }

                            Rectangle {
                                anchors.left: parent.left
                                anchors.leftMargin: 4
                                anchors.verticalCenter: parent.verticalCenter
                                width: 3
                                height: 28
                                radius: 2
                                color: eventRow.modelData.color
                            }

                            Text {
                                anchors.left: parent.left
                                anchors.leftMargin: 14
                                anchors.right: parent.right
                                anchors.rightMargin: 10
                                y: 6
                                text: eventRow.modelData.summary
                                elide: Text.ElideRight
                                font.family: Theme.fontMenu
                                font.pixelSize: Theme.typography.primary
                                font.weight: Theme.weightMedium
                                color: Theme.textHi
                            }

                            Text {
                                anchors.left: parent.left
                                anchors.leftMargin: 14
                                anchors.right: parent.right
                                anchors.rightMargin: 10
                                y: 25
                                text: root.eventMeta(eventRow.modelData)
                                elide: Text.ElideRight
                                font.family: Theme.fontMenu
                                font.pixelSize: Theme.typography.secondary
                                color: Theme.textDim
                            }

                            MouseArea {
                                id: eventMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    eventRow.forceActiveFocus();
                                    Calendar.openCalendar(eventRow.modelData.startMs);
                                }
                            }
                        }
                    }
                }
            }

            ScrollChrome {
                anchors.fill: parent
                target: eventFlick
            }
        }

        Text {
            visible: Calendar.partialWarning !== "" && Calendar.ready
            width: parent.width
            leftPadding: 8
            rightPadding: 8
            text: Calendar.partialWarning
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
            font.family: Theme.fontMenu
            font.pixelSize: Theme.typography.secondary
            color: Theme.redText
        }
    }

    Item {
        width: 1
        height: 2
    }
}
