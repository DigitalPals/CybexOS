const test = require("node:test");
const assert = require("node:assert/strict");
const { load } = require("./shell.cjs");
const H = load("LocationHelpers.js");

test("city search safely encodes Unicode, qualifiers and URL punctuation", () => {
    const url = new URL(H.searchUrl("  São Paulo, Brazil & x=1  "));
    assert.equal(url.hostname, "geocoding-api.open-meteo.com");
    assert.equal(url.searchParams.get("name"), "São Paulo, Brazil & x=1");
    assert.equal(url.searchParams.has("x"), false);
});

test("ambiguous cities retain region, country and distinct coordinates", () => {
    const places = H.parseResults(JSON.stringify({ results: [
        { name: "Amsterdam", admin1: "North Holland", country: "The Netherlands", latitude: 52.37403, longitude: 4.88969 },
        { name: "Amsterdam", admin1: "New York", admin2: "Montgomery", country: "United States", latitude: 42.93869, longitude: -74.18819 }
    ] }));
    assert.equal(places.length, 2);
    assert.equal(places[0].detail, "North Holland · The Netherlands");
    assert.equal(places[1].detail, "New York · Montgomery · United States");
    assert.equal(places[1].lon, -74.18819);
});

test("empty results differ from invalid responses; invalid coordinates cannot be saved", () => {
    assert.deepEqual(H.parseResults('{}'), []);
    assert.deepEqual(H.parseResults('{"results":[]}'), []);
    for (const body of ['null', '[]', 'bad json', '{"error":true}', '{"results":{}}',
        '{"results":[{"name":"Bad","latitude":91,"longitude":0}]}'])
        assert.throws(() => H.parseResults(body));
    const valid = { name: "Quito", country: "Ecuador", latitude: 0, longitude: -78.5 };
    assert.deepEqual(H.parseResults(JSON.stringify({ results: [valid, valid,
        { ...valid, latitude: null }, { ...valid, longitude: "-78.5" }, { ...valid, longitude: 181 }
    ] })), [{ name: "Quito", detail: "Ecuador", lat: 0, lon: -78.5 }]);
});
