import QtQuick
import QtTest
import "../../roles/desktop/files/quickshell/Common/Location" as Location

TestCase {
    id: testCase
    name: "LocationSearch"
    property var search: null
    property var requests: []
    property var selected: []

    Component {
        id: searchComponent
        Location.LocationSearch { }
    }

    function fakeRequest() {
        const request = {
            readyState: 0, status: 0, responseText: "", onreadystatechange: null,
            aborted: false, url: "",
            open: function(method, url) { this.url = url; },
            send: function() {},
            abort: function() { this.aborted = true; },
            respond: function(body, status) {
                this.responseText = JSON.stringify(body);
                this.status = status === undefined ? 200 : status;
                this.readyState = 4;
                if (this.onreadystatechange)
                    this.onreadystatechange();
            }
        };
        requests.push(request);
        return request;
    }

    function city(name, lat) {
        return { name: name, latitude: lat, longitude: 4.89, country: "Netherlands" };
    }

    function init() {
        requests = [];
        selected = [];
        search = searchComponent.createObject(testCase);
        verify(search !== null);
        search.createRequest = fakeRequest;
        search.chosen.connect(function(location) { testCase.selected.push(location); });
    }

    function cleanup() {
        search.destroy();
        search = null;
    }

    function test_typing_previews_and_submit_applies_one_complete_city() {
        search.edit("Amsterdam");
        search.debounce.triggered();
        compare(requests.length, 1);
        requests[0].respond({ results: [city("Amsterdam", 52.374)] });
        compare(selected.length, 0);
        compare(search.results.length, 1);
        search.submit();
        compare(selected.length, 1);
        compare(selected[0].name, "Amsterdam");
        compare(selected[0].lat, 52.374);
        compare(selected[0].lon, 4.89);
        compare(search.results.length, 0);
    }

    function test_submit_during_lookup_accepts_only_a_single_match() {
        search.edit("Amsterdam");
        search.debounce.triggered();
        search.submit();
        compare(requests.length, 1);
        requests[0].respond({ results: [city("Amsterdam", 52.374), city("Amsterdam", 42.939)] });
        compare(selected.length, 0);
        search.submit();
        compare(selected.length, 0);
        search.choose(1);
        compare(selected[0].lat, 42.939);
    }

    function test_enter_without_waiting_for_debounce_applies_single_result() {
        search.edit("Utrecht");
        search.submit();
        verify(!search.debounce.running);
        requests[0].respond({ results: [city("Utrecht", 52.09)] });
        compare(selected[0].name, "Utrecht");
    }

    function test_stale_responses_cannot_overwrite_new_query() {
        search.edit("Paris");
        search.submit();
        const stale = requests[0].onreadystatechange;
        search.edit("Amsterdam");
        verify(requests[0].aborted);
        search.submit();
        requests[0].respond({ results: [city("Paris", 48.8)] });
        stale();
        compare(selected.length, 0);
        verify(search.busy);
        requests[1].respond({ results: [city("Amsterdam", 52.374)] });
        compare(selected[0].name, "Amsterdam");
    }

    function test_empty_error_timeout_retry_and_cancel() {
        search.edit("X");
        search.submit();
        compare(requests.length, 0);
        search.edit("Unknown city");
        search.submit();
        requests[0].respond({});
        verify(search.searched);
        compare(search.results.length, 0);
        compare(search.error, "");
        search.submit();
        requests[1].respond({}, 503);
        verify(search.error !== "");
        verify(!search.busy);
        search.submit();
        search.deadline.triggered();
        verify(requests[2].aborted);
        verify(search.error.indexOf("timed out") !== -1);
        search.submit();
        requests[3].respond({ results: [{ name: "Missing coordinates" }] });
        verify(search.error.indexOf("unreadable") !== -1);
        search.edit("Utrecht");
        search.submit();
        search.edit("");
        verify(requests[4].aborted);
        verify(!search.busy);
        verify(!search.debounce.running);
        compare(search.error, "");
        compare(selected.length, 0);
    }

    function test_destroy_aborts_in_flight_request() {
        search.edit("Utrecht");
        search.submit();
        search.destroy();
        search = searchComponent.createObject(testCase);
        wait(1);
        verify(requests[0].aborted);
    }
}
