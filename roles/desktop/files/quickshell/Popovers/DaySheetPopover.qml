pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import "../Common"

// The Day sheet: the surface the clock (and the weather pill) unrolls under
// the bar — big time, today's sky, the week at a glance with each day's
// forecast and event dots, and the next few events. Attached flush under the
// bar and centred on the bar regardless of which trigger opened it
// (PanelRegistryData `attached` + `centerAnchored`).
Surface {
    id: root

    padding: Theme.scaled(20)
    spacing: Theme.scaled(16)
    implicitWidth: Theme.daySheetWidth

    SystemClock {
        id: clock
        precision: SystemClock.Minutes
    }

    // Monday-first week around today, each day carrying its date, its slice
    // of the five-day forecast when there is one, and its event dots.
    readonly property var week: {
        void clock.date;
        void Calendar.events;
        void Weather.days;
        const today = new Date();
        today.setHours(0, 0, 0, 0);
        // Monday-first: today's position in the strip is also the offset of
        // every other cell from it, so no date arithmetic in milliseconds.
        const todayAt = (today.getDay() + 6) % 7;
        const days = [];
        for (let i = 0; i < 7; i++) {
            const date = new Date(today);
            date.setDate(today.getDate() + (i - todayAt));
            const offset = i - todayAt;
            const forecast = offset >= 0 && offset < Weather.days.length
                ? Weather.days[offset] : null;
            const dots = Calendar.eventsForDay(date, 3).map(event => event.color);
            days.push({
                date: date,
                dow: Qt.formatDateTime(date, "ddd").toUpperCase(),
                day: date.getDate(),
                today: offset === 0,
                forecast: forecast,
                dots: dots
            });
        }
        return days;
    }

    readonly property var events: Calendar.upcoming(3)

    // Keyed on visibility, not construction, so a latched sheet still asks
    // for a fresh window and sky on every open and polls only while shown.
    Claim {
        active: root.visible
        onClaimed: {
            Calendar.acquire();
            Weather.acquire();
        }
        onReleased: {
            Calendar.release();
            Weather.release();
        }
    }

    Row {
        width: parent.width
        spacing: Theme.scaled(24)

        // ---- clock and sky ------------------------------------------------
        Column {
            id: clockColumn
            width: Math.max(Theme.scaled(190), clockText.implicitWidth)
            spacing: 6

            Text {
                id: clockText
                text: Qt.formatDateTime(clock.date,
                    Settings.clock24 ? "HH:mm" : "h:mm AP")
                font.family: Theme.fontNumeric
                font.pixelSize: Theme.typography.clock
                font.weight: Theme.weightSemibold
                font.letterSpacing: -2
                font.features: Theme.tabularNumberFeatures
                color: Theme.textHi
            }

            Text {
                text: Qt.formatDateTime(clock.date, "dddd d MMMM")
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.secondary
                color: Theme.textFaint
            }

            Row {
                topPadding: 8
                spacing: 8

                Sym {
                    anchors.verticalCenter: parent.verticalCenter
                    name: Weather.symbol(Weather.code, Weather.isDay)
                    size: 22
                    fill: 1
                    color: Weather.ready
                        ? Weather.glyphColor(Weather.code, Weather.isDay)
                        : Theme.textMid
                }

                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: Weather.ready ? Weather.temp + "°" : "--"
                    font.family: Theme.fontNumeric
                    font.pixelSize: Theme.typography.title
                    font.weight: Theme.weightSemibold
                    font.features: Theme.tabularNumberFeatures
                    color: Theme.textHi
                }

                // Without coordinates there is no sky to describe, only where
                // to set them: the weather widget's own options.
                LinkText {
                    visible: !Weather.locationSet
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Set a location in Settings"
                    font.pixelSize: Theme.typography.secondary
                    onClicked: {
                        Settings.openWidgetSettings("weather");
                        Settings.showPanel("modules", Popouts.hostScreenName);
                    }
                }

                Text {
                    visible: Weather.locationSet
                    anchors.verticalCenter: parent.verticalCenter
                    text: {
                        if (!Weather.ready)
                            return Weather.offline ? "offline" : "loading…";
                        const today = Weather.days.length > 0
                            ? Weather.days[0] : null;
                        return Weather.condition + (today
                            ? " · " + today.hi + "° / " + today.lo + "°" : "");
                    }
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.secondary
                    color: Theme.textFaint
                }
            }
        }

        // ---- the week -----------------------------------------------------
        Grid {
            id: weekGrid
            width: parent.width - clockColumn.width - parent.spacing
            columns: 7
            columnSpacing: 4

            readonly property real cellWidth: (width - columnSpacing * 6) / 7

            Repeater {
                model: root.week

                delegate: Rectangle {
                    id: dayCell

                    required property var modelData

                    width: weekGrid.cellWidth
                    height: Theme.scaled(96)
                    radius: 10
                    color: modelData.today ? Theme.chipHover : Theme.chip

                    Column {
                        anchors.centerIn: parent
                        spacing: 5

                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: dayCell.modelData.dow
                            font.family: Theme.fontMenu
                            font.pixelSize: Theme.typography.metadata
                            font.weight: Theme.weightSemibold
                            font.letterSpacing: 0.5
                            color: dayCell.modelData.today
                                ? Theme.accentText : Theme.textFaint
                        }

                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: dayCell.modelData.day
                            font.family: Theme.fontNumeric
                            font.pixelSize: Theme.typography.heading
                            font.weight: Theme.weightSemibold
                            font.features: Theme.tabularNumberFeatures
                            color: dayCell.modelData.today
                                ? Theme.accentText : Theme.textHi
                        }

                        Item {
                            anchors.horizontalCenter: parent.horizontalCenter
                            width: 14
                            height: 14

                            Sym {
                                anchors.centerIn: parent
                                visible: dayCell.modelData.forecast !== null
                                name: dayCell.modelData.forecast
                                    ? Weather.symbol(
                                        dayCell.modelData.forecast.code, true)
                                    : "circle"
                                size: 14
                                fill: 1
                                color: dayCell.modelData.forecast
                                    ? Weather.glyphColor(
                                        dayCell.modelData.forecast.code, true)
                                    : Theme.textFaint
                            }
                        }

                        Row {
                            anchors.horizontalCenter: parent.horizontalCenter
                            height: 4
                            spacing: 2

                            Repeater {
                                model: dayCell.modelData.dots

                                delegate: Rectangle {
                                    required property var modelData
                                    width: 4
                                    height: 4
                                    radius: 2
                                    color: modelData
                                }
                            }
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            Popouts.close();
                            Calendar.openCalendar(dayCell.modelData.date);
                        }
                    }

                    Accessible.role: Accessible.Button
                    Accessible.name: Qt.formatDateTime(
                        dayCell.modelData.date, "dddd d MMMM")
                }
            }
        }
    }

    // ---- next events -----------------------------------------------------
    Grid {
        id: eventsGrid
        visible: root.events.length > 0
        width: parent.width
        columns: 3
        columnSpacing: 8

        readonly property real cellWidth: (width - columnSpacing * 2) / 3

        Repeater {
            model: root.events

            delegate: Rectangle {
                id: eventCard

                required property var modelData
                readonly property bool ongoing: {
                    void clock.date;
                    const now = Date.now();
                    return modelData.startMs <= now && now < modelData.endMs;
                }

                width: eventsGrid.cellWidth
                height: 56
                radius: 10
                color: Theme.chip

                Rectangle {
                    id: eventBar
                    anchors.left: parent.left
                    anchors.leftMargin: 12
                    anchors.verticalCenter: parent.verticalCenter
                    width: 3
                    height: 28
                    radius: 2
                    color: eventCard.modelData.color
                }

                Column {
                    anchors.left: eventBar.right
                    anchors.leftMargin: 10
                    anchors.right: eventTime.left
                    anchors.rightMargin: 8
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 2

                    Text {
                        width: parent.width
                        text: eventCard.modelData.summary
                        font.family: Theme.fontMenu
                        font.pixelSize: Theme.typography.primary
                        font.weight: Theme.weightMedium
                        color: Theme.textHi
                        elide: Text.ElideRight
                    }

                    Text {
                        width: parent.width
                        text: {
                            void clock.date;
                            const start = new Date(eventCard.modelData.startMs);
                            const today = new Date();
                            today.setHours(0, 0, 0, 0);
                            const tomorrow = new Date(today);
                            tomorrow.setDate(today.getDate() + 1);
                            const startDay = Calendar.dayStart(start);
                            const day = eventCard.ongoing ? "Now"
                                : startDay === today.getTime() ? "Today"
                                : startDay === tomorrow.getTime() ? "Tomorrow"
                                : Qt.formatDateTime(start, "ddd d MMM");
                            return day + " · " + eventCard.modelData.calendar;
                        }
                        font.family: Theme.fontMenu
                        font.pixelSize: Theme.typography.secondary
                        color: Theme.textFaint
                        elide: Text.ElideRight
                    }
                }

                Text {
                    id: eventTime
                    anchors.right: parent.right
                    anchors.rightMargin: 12
                    anchors.verticalCenter: parent.verticalCenter
                    text: eventCard.modelData.allDay ? "all day"
                        : Qt.formatDateTime(new Date(eventCard.modelData.startMs),
                            Settings.clock24 ? "HH:mm" : "h:mm AP")
                    font.family: Theme.fontNumeric
                    font.pixelSize: Theme.typography.secondary
                    font.weight: Theme.weightSemibold
                    font.features: Theme.tabularNumberFeatures
                    color: eventCard.ongoing ? Theme.accentText : Theme.textHi
                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        Popouts.close();
                        Calendar.openCalendar(eventCard.modelData.startMs);
                    }
                }

                Accessible.role: Accessible.Button
                Accessible.name: eventCard.modelData.summary
            }
        }
    }

    // A calendar that timed out still leaves the others' events here; say
    // that some are missing rather than let the week look complete.
    Text {
        visible: Calendar.partialWarning !== "" && Calendar.ready
        width: parent.width
        text: Calendar.partialWarning
        elide: Text.ElideRight
        font.family: Theme.fontMenu
        font.pixelSize: Theme.typography.secondary
        color: Theme.textFaint
    }
}
