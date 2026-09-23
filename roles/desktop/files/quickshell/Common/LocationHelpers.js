// Open-Meteo geocoding (GeoNames). Keep provider data outside the settings store
// until a complete, validated location has been chosen.
function searchUrl(query) {
    return "https://geocoding-api.open-meteo.com/v1/search?name="
        + encodeURIComponent(query.trim()) + "&count=10&language=en&format=json";
}

function parseResults(body) {
    const data = JSON.parse(body);
    if (!data || typeof data !== "object" || Array.isArray(data) || data.error
            || (data.results !== undefined && !Array.isArray(data.results)))
        throw new Error("Invalid location response");
    const seen = {};
    const results = [];
    for (const item of data.results || []) {
        if (!item || typeof item.name !== "string" || !item.name.trim()
                || typeof item.latitude !== "number" || !Number.isFinite(item.latitude)
                || typeof item.longitude !== "number" || !Number.isFinite(item.longitude)
                || Math.abs(item.latitude) > 90 || Math.abs(item.longitude) > 180)
            continue;
        const key = item.name + "/" + item.latitude + "/" + item.longitude;
        if (seen[key])
            continue;
        seen[key] = true;
        const parts = [];
        for (const part of [item.admin1, item.admin2, item.country || item.country_code]) {
            if (typeof part === "string" && part.trim() && part !== item.name
                    && parts.indexOf(part) === -1)
                parts.push(part);
        }
        results.push({
            name: item.name.trim(),
            detail: parts.join(" · "),
            lat: item.latitude,
            lon: item.longitude
        });
    }
    if (data.results && data.results.length && !results.length)
        throw new Error("No valid locations in response");
    return results.slice(0, 10);
}

if (typeof module !== "undefined")
    module.exports = { searchUrl, parseResults };
