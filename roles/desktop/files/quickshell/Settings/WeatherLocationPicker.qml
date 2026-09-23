pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls as Controls
import "../Common"
import "../Common/Location"

Column {
    id: root
    spacing: Theme.settingsContentSpacing

    readonly property var saved: Settings.modOpts.weather
    property int highlighted: -1
    property string confirmation: ""
    property bool manual: false

    function acceptSearch() {
        if (highlighted >= 0)
            lookup.choose(highlighted);
        else
            lookup.submit();
    }

    function dismiss() {
        lookup.edit("");
        city.text = "";
        highlighted = -1;
    }

    onVisibleChanged: {
        if (!visible)
            dismiss();
    }

    LocationSearch {
        id: lookup
        onResultsChanged: root.highlighted = -1
        onChosen: location => {
            // One settings transaction, one forecast request; never fetch with
            // a new latitude paired with the previous city's longitude.
            Settings.setModuleOptions("weather", {
                place: location.name, lat: location.lat, lon: location.lon
            });
            root.confirmation = "Location set to " + location.name
                + (location.detail ? " · " + location.detail : "");
            city.text = "";
            lookup.query = "";
        }
    }

    SettingsSubsection {
        width: parent.width
        title: "Weather location"
        spacing: Theme.settingsContentSpacing
        insetContent: true

        Row {
            width: parent.width
            spacing: Theme.controlSpacing

            SettingsField {
                id: city
                objectName: "weatherCitySearch"
                width: Math.max(0, parent.width - searchButton.width - parent.spacing)
                placeholderText: "City name, e.g. Amsterdam"
                Accessible.name: "Search weather location by city"
                Accessible.description: "Use Up and Down to choose a result, then Enter to apply it."
                maximumLength: 160
                invalid: lookup.error !== ""
                onTextEdited: {
                    root.confirmation = "";
                    lookup.edit(text);
                }
                onAccepted: root.acceptSearch()
                Keys.onPressed: event => {
                    if ((event.key === Qt.Key_Down || event.key === Qt.Key_Up)
                            && lookup.results.length) {
                        const count = lookup.results.length;
                        root.highlighted = event.key === Qt.Key_Down
                            ? (root.highlighted + 1) % count
                            : (root.highlighted < 0 ? count - 1 : (root.highlighted + count - 1) % count);
                        matches.positionViewAtIndex(root.highlighted, ListView.Contain);
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Escape && city.text !== "") {
                        root.dismiss();
                        event.accepted = true;
                    }
                }
            }

            SettingsAction {
                id: searchButton
                text: lookup.error !== "" ? "Retry" : "Search"
                glyph: "search"
                enabled: city.text.trim().length >= 2
                onTriggered: root.acceptSearch()
            }
        }

        SettingsHint {
            width: parent.width
            inset: false
            tone: lookup.error !== "" ? "error" : root.confirmation !== "" ? "active" : "info"
            text: lookup.busy ? "Searching cities…"
                : lookup.error !== "" ? lookup.error
                : lookup.searched && !lookup.results.length
                    ? "No cities found. Check the spelling or try a nearby city."
                : lookup.results.length > 1 ? "Choose your city below. Add a country or region after a comma to narrow the search."
                : lookup.results.length === 1 ? "Press Enter or select the city below to use it."
                : root.confirmation !== "" ? root.confirmation
                : "Type a city to find its coordinates. Press Enter to apply a single match."
        }

        ListView {
            id: matches
            width: parent.width
            visible: lookup.results.length > 0
            height: visible ? Math.min(contentHeight, Theme.scaled(240)) : 0
            clip: true
            spacing: Theme.settingsRowSpacing
            model: lookup.results
            boundsBehavior: Flickable.StopAtBounds
            Controls.ScrollBar.vertical: Controls.ScrollBar { }

            delegate: Controls.ItemDelegate {
                id: match
                required property var modelData
                required property int index
                width: matches.width
                height: labels.implicitHeight + Theme.controlSpacing * 2
                hoverEnabled: true
                activeFocusOnTab: true
                highlighted: root.highlighted === index
                Accessible.role: Accessible.Button
                Accessible.name: modelData.name + ", " + modelData.detail
                onClicked: lookup.choose(index)
                Keys.onReturnPressed: lookup.choose(index)
                Keys.onEnterPressed: lookup.choose(index)
                background: Rectangle {
                    radius: Theme.chipRadius
                    color: match.highlighted || match.hovered || match.activeFocus
                        ? Theme.hoverFillStrong : Theme.cardFill
                    border.width: match.activeFocus || match.highlighted ? 1 : 0
                    border.color: Theme.accentText
                }
                contentItem: Column {
                    id: labels
                    spacing: 2
                    Text {
                        width: parent.width
                        text: match.modelData.name
                        textFormat: Text.PlainText
                        font.family: Theme.fontMenu
                        font.pixelSize: Theme.typography.control
                        font.weight: Theme.weightSemibold
                        color: Theme.textHi
                        elide: Text.ElideRight
                    }
                    Text {
                        width: parent.width
                        text: match.modelData.detail
                            + (match.modelData.detail ? " · " : "")
                            + match.modelData.lat.toFixed(4) + ", " + match.modelData.lon.toFixed(4)
                        textFormat: Text.PlainText
                        font.family: Theme.fontMenu
                        font.pixelSize: Theme.typography.secondary
                        color: Theme.textMid
                        wrapMode: Text.Wrap
                    }
                }
            }
        }

        SettingsHint {
            width: parent.width
            inset: false
            text: Number(root.saved.lat) !== 0 || Number(root.saved.lon) !== 0
                ? "Current: " + (root.saved.place || "Custom location") + " · "
                    + Number(root.saved.lat).toFixed(4) + ", " + Number(root.saved.lon).toFixed(4)
                : "No location selected yet."
        }

        Flow {
            width: parent.width
            spacing: Theme.controlSpacing
            SettingsAction {
                text: root.manual ? "Hide coordinates" : "Edit coordinates"
                onTriggered: root.manual = !root.manual
            }
            SettingsAction {
                text: "Open-Meteo / GeoNames"
                onTriggered: Qt.openUrlExternally("https://open-meteo.com/en/docs/geocoding-api")
            }
        }
    }

    Column {
        visible: root.manual
        width: parent.width
        spacing: Theme.settingsContentSpacing

        SettingsTextRow {
            width: parent.width
            label: "Place label"
            value: root.saved.place
            dirty: root.saved.place !== Settings.defaults.modOpts.weather.place
            onCommitted: text => Settings.setModuleOption("weather", "place", text)
            onResetRequested: Settings.setModuleOption("weather", "place", Settings.defaults.modOpts.weather.place)
        }
        SettingsTextRow {
            width: parent.width
            label: "Latitude"
            numeric: true
            value: String(root.saved.lat)
            dirty: root.saved.lat !== Settings.defaults.modOpts.weather.lat
            onResetRequested: Settings.setModuleOption("weather", "lat", Settings.defaults.modOpts.weather.lat)
            onCommitted: text => {
                if (text.trim() !== "" && Number.isFinite(Number(text)))
                    Settings.setModuleOption("weather", "lat", Number(text));
            }
        }
        SettingsTextRow {
            width: parent.width
            label: "Longitude"
            numeric: true
            value: String(root.saved.lon)
            dirty: root.saved.lon !== Settings.defaults.modOpts.weather.lon
            onResetRequested: Settings.setModuleOption("weather", "lon", Settings.defaults.modOpts.weather.lon)
            onCommitted: text => {
                if (text.trim() !== "" && Number.isFinite(Number(text)))
                    Settings.setModuleOption("weather", "lon", Number(text));
            }
        }
    }
}
