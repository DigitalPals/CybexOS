// Wallhaven (wallhaven.cc) API v1, for the Wallpaper page's Online view.
//
// Only safe-for-work images, always: every request asks for purity=100, and
// parseResults drops anything the reply does not mark "sfw" as well. The
// server does not enforce that on its own: without an API key it still
// answers a purity=110 request with "sketchy" images.
//
// Provider data is untrusted. Every URL the shell will later load or download
// is matched against Wallhaven's own hosts and path shapes here, and the file
// name the picker saves under is derived from the validated id rather than
// taken from the reply.

const SEARCH_URL = "https://wallhaven.cc/api/v1/search";
const PAGE_URL = "https://wallhaven.cc/w/";
const MAX_QUERY = 100;
// Search accepts only this fixed palette; returned image swatches may be any
// six-digit hex (https://wallhaven.cc/help/api, checked 2026-10-25).
const COLORS = ["660000", "990000", "cc0000", "cc3333", "ea4c88", "993399",
    "663399", "333399", "0066cc", "0099cc", "66cccc", "77cc33", "669900",
    "336600", "666600", "999900", "cccc33", "ffff00", "ffcc33", "ff9900",
    "ff6600", "cc6633", "996633", "663300", "000000", "999999", "cccccc",
    "ffffff", "424153"];
const TOPICS = [
    { value: "minimalism", label: "Minimal" }, { value: "nature", label: "Nature" },
    { value: "space", label: "Space" }, { value: "city", label: "City" },
    { value: "abstract", label: "Abstract" }, { value: "dark", label: "Dark" },
    { value: "pixel art", label: "Pixel art" }
];

const SORTS = [
    { value: "popular", label: "Popular" },
    { value: "trending", label: "Trending" },
    { value: "latest", label: "Latest" },
    { value: "random", label: "Random" }
];
const SORT_PARAMS = {
    popular: { sorting: "favorites" },
    trending: { sorting: "toplist", topRange: "1M" },
    latest: { sorting: "date_added" },
    random: { sorting: "random" }
};

// Wallhaven's category bits are General, Anime, People. People is never
// requested: it is the category where "safe for work" is least reliable.
const CATEGORIES = [
    { value: "general", label: "General" },
    { value: "anime", label: "Anime" },
    { value: "both", label: "Both" }
];
const CATEGORY_BITS = { general: "100", anime: "010", both: "110" };

const SIZES = [
    { value: "fit", label: "Fits my displays" },
    { value: "any", label: "Any size" }
];

const TYPES = { "image/jpeg": "jpg", "image/png": "png" };
const ID = /^[a-z0-9]{1,16}$/;
const SEED = /^[A-Za-z0-9]{1,16}$/;
const RESOLUTION = /^[1-9][0-9]{0,4}x[1-9][0-9]{0,4}$/;

function choice(list, value, fallback) {
    return list.some(item => item.value === value) ? value : fallback;
}

// options: { query, sort, category, minimum: "WxH" or "", landscape, page, seed }
function searchUrl(options) {
    const opts = options || {};
    const sort = choice(SORTS, opts.sort, "popular");
    const params = [
        ["categories", CATEGORY_BITS[choice(CATEGORIES, opts.category, "general")]],
        ["purity", "100"]
    ];
    const query = typeof opts.query === "string" ? opts.query.trim().slice(0, MAX_QUERY) : "";
    if (query !== "")
        params.push(["q", query]);
    const color = typeof opts.color === "string" ? opts.color.toLowerCase() : "";
    if (COLORS.indexOf(color) !== -1)
        params.push(["colors", color]);
    const sortParams = SORT_PARAMS[sort];
    for (const key of Object.keys(sortParams))
        params.push([key, sortParams[key]]);
    params.push(["order", "desc"]);
    if (typeof opts.minimum === "string" && RESOLUTION.test(opts.minimum))
        params.push(["atleast", opts.minimum]);
    if (opts.landscape)
        params.push(["ratios", "landscape"]);
    const page = Math.floor(Number(opts.page));
    if (Number.isFinite(page) && page > 1)
        params.push(["page", String(Math.min(page, 10000))]);
    // A random listing is only stable across pages with the seed its first
    // page returned.
    if (sort === "random" && typeof opts.seed === "string" && SEED.test(opts.seed))
        params.push(["seed", opts.seed]);
    return SEARCH_URL + "?" + params
        .map(pair => pair[0] + "=" + encodeURIComponent(pair[1]))
        .join("&");
}

// The smallest image that covers every display in physical pixels, so one
// wallpaper can fill each of them. screens: [{ width, height, devicePixelRatio }]
function minimumFor(screens) {
    let width = 0;
    let height = 0;
    for (const screen of screens || []) {
        const scale = Number(screen && screen.devicePixelRatio) > 0 ? Number(screen.devicePixelRatio) : 1;
        const w = Math.round(Number(screen && screen.width) * scale);
        const h = Math.round(Number(screen && screen.height) * scale);
        if (!Number.isFinite(w) || !Number.isFinite(h) || w <= 0 || h <= 0)
            continue;
        width = Math.max(width, w);
        height = Math.max(height, h);
    }
    return width > 0 && height > 0 ? width + "x" + height : "";
}

function allLandscape(screens) {
    const list = screens || [];
    return list.length > 0 && list.every(screen => Number(screen.width) >= Number(screen.height));
}

function positiveInt(value) {
    return typeof value === "number" && Number.isInteger(value) && value > 0;
}

function count(value) {
    return typeof value === "number" && Number.isInteger(value) && value >= 0 ? value : 0;
}

function parseItem(item) {
    if (!item || typeof item !== "object" || typeof item.id !== "string" || !ID.test(item.id))
        return null;
    if (item.purity !== "sfw")
        return null;
    const extension = TYPES[item.file_type];
    if (!extension || !positiveInt(item.dimension_x) || !positiveInt(item.dimension_y)
            || !positiveInt(item.file_size))
        return null;
    const id = item.id;
    const shard = id.slice(0, 2);
    const image = "https://w.wallhaven.cc/full/" + shard + "/wallhaven-" + id + "." + extension;
    if (item.path !== image)
        return null;
    const thumbs = item.thumbs && typeof item.thumbs === "object" ? item.thumbs : {};
    let thumb = "";
    for (const size of ["lg", "small"]) {
        const key = size === "lg" ? "large" : "small";
        const expected = "https://th.wallhaven.cc/" + size + "/" + shard + "/" + id + ".jpg";
        if (thumbs[key] === expected) {
            thumb = expected;
            break;
        }
    }
    if (thumb === "")
        return null;
    return {
        id: id,
        width: item.dimension_x,
        height: item.dimension_y,
        size: item.file_size,
        favorites: count(item.favorites),
        colors: imageColors(item.colors),
        category: typeof item.category === "string" ? item.category : "",
        thumb: thumb,
        image: image,
        page: PAGE_URL + id,
        fileName: "wallhaven-" + id + "." + extension
    };
}

// Returns { items, page, lastPage, seed }; throws on a reply that is not a
// Wallhaven listing at all (an error document, HTML, a truncated body).
function parseResults(body) {
    const data = JSON.parse(body);
    if (!data || typeof data !== "object" || Array.isArray(data) || data.error
            || !Array.isArray(data.data) || !data.meta || typeof data.meta !== "object")
        throw new Error("Invalid Wallhaven response");
    const items = [];
    const seen = {};
    for (const raw of data.data) {
        const item = parseItem(raw);
        if (!item || seen[item.id])
            continue;
        seen[item.id] = true;
        items.push(item);
    }
    const page = positiveInt(data.meta.current_page) ? data.meta.current_page : 1;
    const lastPage = positiveInt(data.meta.last_page) ? Math.max(page, data.meta.last_page) : page;
    const seed = typeof data.meta.seed === "string" && SEED.test(data.meta.seed) ? data.meta.seed : "";
    return { items: items, page: page, lastPage: lastPage, seed: seed };
}

// Appends a later page, dropping repeats: a listing can shift while the
// person reads it, and a random one can hand back an image twice.
function merge(existing, incoming) {
    const seen = {};
    for (const item of existing)
        seen[item.id] = true;
    return existing.concat(incoming.filter(item => !seen[item.id]));
}

function formatBytes(bytes) {
    if (!(bytes > 0))
        return "";
    if (bytes < 1000 * 1000)
        return Math.max(1, Math.round(bytes / 1000)) + " kB";
    return (bytes / (1000 * 1000)).toFixed(1) + " MB";
}

function describe(item) {
    return item.width + " × " + item.height + " · " + formatBytes(item.size);
}

function statusError(status) {
    if (status === 429)
        return "Wallhaven is limiting requests. Wait a minute and try again.";
    if (status === 0)
        return "Wallhaven could not be reached. Check your connection and try again.";
    return "Wallhaven is unavailable right now (HTTP %1). Try again later.";
}

function validId(id) {
    return typeof id === "string" && ID.test(id);
}

function detailsUrl(id) {
    return validId(id) ? "https://wallhaven.cc/api/v1/w/" + id : "";
}

function likeQuery(id) {
    return validId(id) ? "like:" + id : "";
}

function imageColors(colors) {
    return Array.isArray(colors) ? colors.filter(color =>
        typeof color === "string" && /^#[0-9a-f]{6}$/i.test(color))
        .slice(0, 10).map(color => color.toLowerCase()) : [];
}

function plain(value, limit) {
    return typeof value === "string" ? value.replace(/[\x00-\x1f\x7f]/g, "").trim().slice(0, limit) : "";
}

// These are navigation links only, never image/download sources. Disallow
// credentials, whitespace and control characters as well as other schemes.
function httpUrl(value) {
    return typeof value === "string" && value.length <= 2048
        && /^https?:\/\/[^/\s@?#]+(?:[/?#][^\s]*)?$/i.test(value)
        && !/[\x00-\x20\x7f\\<>"]/.test(value) ? value : "";
}

function parseDetails(body, expectedId) {
    const data = JSON.parse(body);
    const raw = data && data.data;
    const item = parseItem(raw);
    if (!item || item.id !== expectedId)
        throw new Error("Invalid Wallhaven details");
    return Object.assign(item, {
        uploader: plain(raw.uploader && raw.uploader.username, 64),
        tags: Array.isArray(raw.tags) ? raw.tags.filter(tag => tag && tag.purity === "sfw")
            .slice(0, 30).map(tag => plain(tag.name, 64)).filter(Boolean) : [],
        source: httpUrl(raw.source),
        short_url: httpUrl(raw.short_url)
    });
}

// Shared by listings and detail requests. A sliding window counts cancelled
// attempts too. Reserve the last two server slots for other Wallhaven users
// behind this connection; missing headers never bypass our own limit.
function requestWindow(times, now) {
    return (times || []).filter(time => now - time < 60000);
}

function ratePause(status, remaining, limit, retryAfter, now) {
    const number = value => typeof value === "string" && /^\d+$/.test(value.trim())
        ? Number(value) : NaN;
    const left = number(remaining);
    const maximum = number(limit);
    if (status === 429) {
        const retry = number(retryAfter);
        const date = Date.parse(retryAfter);
        return now + Math.max(60000, Number.isFinite(retry) ? retry * 1000
            : Number.isFinite(date) ? date - now : 0);
    }
    return Number.isFinite(left) && left <= 2 && (!Number.isFinite(maximum) || maximum > 0)
        ? now + 60000 : 0;
}

// The download helper's failure codes, in the words the page shows.
const DOWNLOAD_ERRORS = {
    url: "The download address was not a Wallhaven image.",
    network: "The download failed. Check your connection and try again.",
    http: "Wallhaven refused the download. Try again later.",
    type: "The download was not a JPEG or PNG image.",
    size: "The download was incomplete or larger than expected.",
    write: "The wallpaper folder is not writable. Choose another folder in Library.",
    interrupted: "The download was cancelled."
};

function downloadError(code) {
    return DOWNLOAD_ERRORS[code] || "The download failed.";
}

if (typeof module !== "undefined")
    module.exports = {
        SORTS, CATEGORIES, SIZES, COLORS, TOPICS, searchUrl, minimumFor, allLandscape,
        parseResults, merge, formatBytes, describe, statusError, downloadError, validId, detailsUrl, likeQuery, imageColors,
        parseDetails, httpUrl, requestWindow, ratePause, DOWNLOAD_ERRORS
    };
