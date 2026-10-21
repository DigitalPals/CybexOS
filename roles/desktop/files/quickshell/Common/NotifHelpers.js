// Pure notification presentation helpers shared by QML and Node tests.
// Keep this file free of Qt APIs so notification parsing stays deterministic.

var MIN_TIMEOUT_MS = 8000;
var MAX_TIMEOUT_MS = 12000;

// Chromium's Linux notification bridge identifies web senders by origin, not
// by the --app window that happened to host them. Keep the small set of
// product identities used by this shell here; everything else remains a
// hostname and is eligible for the browser-favicon fallback.
var WEB_SOURCES = [
    {
        domain: "slack.com",
        name: "Slack",
        brandIcon: "slack"
    },
    {
        domain: "whatsapp.com",
        name: "WhatsApp",
        brandIcon: "whatsapp"
    },
    {
        domain: "youtube.com",
        name: "YouTube",
        brandIcon: "youtube"
    }
];

function textValue(value) {
    return typeof value === "string" ? value : "";
}

function decodeEntities(value) {
    var named = {
        amp: "&",
        apos: "'",
        gt: ">",
        lt: "<",
        nbsp: " ",
        quot: "\""
    };
    return value.replace(/&(#(?:x[0-9a-f]+|[0-9]+)|[a-z]+);/gi,
        function(match, entity) {
            var lower = entity.toLowerCase();
            if (lower.charAt(0) !== "#")
                return Object.prototype.hasOwnProperty.call(named, lower)
                    ? named[lower] : match;
            var hexadecimal = lower.charAt(1) === "x";
            var codePoint = parseInt(lower.slice(hexadecimal ? 2 : 1),
                hexadecimal ? 16 : 10);
            if (!isFinite(codePoint) || codePoint <= 0 || codePoint > 0x10ffff)
                return match;
            if (codePoint <= 0xffff)
                return String.fromCharCode(codePoint);
            codePoint -= 0x10000;
            return String.fromCharCode(0xd800 + (codePoint >> 10),
                0xdc00 + (codePoint & 0x3ff));
        });
}

function stripMarkup(value) {
    var text = textValue(value)
        .replace(/\r\n?/g, "\n")
        .replace(/<\s*br\s*\/?\s*>/gi, "\n")
        .replace(/<\s*\/?\s*(?:div|p|li)(?:\s[^>]*)?>/gi, "\n")
        .replace(/<[^>]*>/g, "");
    text = decodeEntities(text).replace(/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f\u200b-\u200f\u202a-\u202e\u2066-\u2069\ufeff]/g, "");
    var lines = text.split("\n").map(function(line) {
        return line.replace(/[\t\f\v ]+/g, " ").trim();
    });
    return lines.join("\n").replace(/\n{3,}/g, "\n\n").trim();
}

function singleLine(value) {
    return stripMarkup(value).replace(/\s+/g, " ").trim();
}

function canonicalOriginHost(value, preserveRootDot) {
    var host = value.toLowerCase().replace(/\.$/, "");
    var rootDot = preserveRootDot && /\.$/.test(value) ? "." : "";
    if (host.length > 253) return "";
    if (host.charAt(0) === "[") {
        if (!/^\[[0-9a-f:.]+\]$/.test(host)) return "";
        var address = host.slice(1, -1);
        if (address.indexOf(".") >= 0) {
            var at = address.lastIndexOf(":");
            var ipv4 = canonicalOriginHost(address.slice(at + 1));
            if (!/^(?:[0-9]+\.){3}[0-9]+$/.test(ipv4)) return "";
            var octets4 = ipv4.split(".").map(Number);
            address = address.slice(0, at + 1) + (octets4[0] * 256 + octets4[1]).toString(16)
                + ":" + (octets4[2] * 256 + octets4[3]).toString(16);
        }
        var halves = address.split("::");
        if (halves.length > 2) return "";
        var left = halves[0] ? halves[0].split(":") : [];
        var right = halves.length === 2 && halves[1] ? halves[1].split(":") : [];
        var words = left.concat(right);
        if (!words.every(function(word) { return /^[0-9a-f]{1,4}$/.test(word); })
                || (halves.length === 1 ? words.length !== 8 : words.length >= 8)) return "";
        var missing = halves.length === 2 ? 8 - words.length : 0;
        var expanded = left.concat(Array(missing).fill("0"), right);
        return "[" + expanded.map(function(word) { return parseInt(word, 16).toString(16); }).join(":") + "]";
    }
    if (host === "localhost") return host + rootDot;
    if (/^(?:[0-9]+\.){3}[0-9]+$/.test(host)) {
        var octets = host.split(".");
        return octets.every(function(octet) { return /^(?:0|[1-9][0-9]{0,2})$/.test(octet) && +octet <= 255; }) ? host : "";
    }
    // Reject numeric-looking hosts with browser-specific IPv4 spellings.
    if (!/^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$/.test(host)
            || /^(?:0x[0-9a-f]*|[0-9]+)$/.test(host.split(".").pop())) return "";
    return host + rootDot;
}

function webSource(value) {
    var empty = { hostname: "", identity: "" };
    // Never repair controls/markup into an apparently trusted origin. Only
    // the HTTP(S) authority is retained; paths, credentials and queries are
    // never part of a source identity or its persisted representation.
    if (typeof value !== "string" || value.length > 4096
            || /[\x00-\x1f\x7f-\x9f\\<>"'\u0080-\uffff]/.test(value)) return empty;
    var origin = value.trim().replace(/^origin: */i, "");
    var qualified = origin.match(/^(https?):\/\/([^/?#]+)(?:[/?#][^]*)?$/i);
    var authority = qualified ? qualified[2] : origin.replace(/^\/\//, "");
    if (!qualified && /[/?#]/.test(authority)) return empty;
    var match = authority.match(/^(\[[0-9a-f:.]+\]|[^:%@\s]+)(?::([0-9]{1,5}))?$/i);
    if (!match) return empty;
    var host = canonicalOriginHost(match[1]);
    // A DNS root dot is harmless for display, but browsers retain it in
    // origin identity. Do not alias two distinct browser origins.
    var identityHost = canonicalOriginHost(match[1], true);
    var port = match[2] ? +match[2] : 0;
    if (!host || (match[2] && (port < 1 || port > 65535))) return empty;
    var scheme = qualified ? qualified[1].toLowerCase() : "";
    return { hostname: host, identity: scheme
        ? scheme + "://" + identityHost + ":" + (port || (scheme === "https" ? 443 : 80))
        : "unqualified:" + identityHost + (port ? ":" + port : "") };
}

function canonicalWebSourceIdentity(identity, hostname) {
    var raw = typeof identity === "string" ? identity : "";
    if (raw.length > 320) return "";
    var parsed = webSource(raw.indexOf("unqualified:") === 0 ? raw.slice(12) : raw);
    return parsed.hostname === hostname && parsed.identity === raw ? raw : "";
}

function normalizeOrigin(value) {
    return webSource(value).hostname;
}

function isBrowser(appName, desktopEntry) {
    var identity = (textValue(appName) + " " + textValue(desktopEntry)).toLowerCase();
    return /(?:^|[^a-z0-9])(?:google[ -]?chrome(?:-stable)?|chrome|chromium|brave|vivaldi|opera|microsoft[ -]?edge|msedge|firefox|librewolf|zen)(?:[^a-z0-9]|$)/
        .test(identity);
}

function parseLegacyBody(value) {
    var body = stripMarkup(value);
    var separator = body.search(/\n\s*\n/);
    if (separator === -1)
        return { origin: "", identity: "", body: body };
    var candidate = webSource(body.slice(0, separator));
    if (candidate.hostname === "")
        return { origin: "", identity: "", body: body };
    return {
        origin: candidate.hostname,
        identity: candidate.identity,
        body: body.slice(separator).replace(/^\s+/, "").trim()
    };
}

function hintValue(hints, key) {
    if (!hints || typeof hints !== "object")
        return "";
    return textValue(hints[key]);
}

function comparableText(value) {
    return singleLine(value).toLowerCase();
}

function domainMatches(origin, domain) {
    return origin === domain || origin.slice(-(domain.length + 1)) === "." + domain;
}

function webSourceForOrigin(origin) {
    for (var i = 0; i < WEB_SOURCES.length; i++) {
        if (domainMatches(origin, WEB_SOURCES[i].domain))
            return WEB_SOURCES[i];
    }
    return null;
}

function displayNameForOrigin(origin) {
    var source = webSourceForOrigin(origin);
    return source ? source.name : origin;
}

function derivePresentation(notification) {
    notification = notification || {};
    var browser = isBrowser(notification.appName, notification.desktopEntry);
    var rawBody = stripMarkup(notification.body);
    var legacy = parseLegacyBody(notification.body);
    var advertisedOrigin = notification.originName
        || hintValue(notification.hints, "x-kde-origin-name");
    var hinted = webSource(advertisedOrigin);
    var anchor = textValue(notification.body).match(/^\s*<a\s+href=["'](https?:\/\/[^"']+)["'][^>]*>([^]*?)<\/a>\s*/i);
    var anchored = webSource(anchor ? decodeEntities(anchor[1]) : "");
    // Preserve a supplied hostname's ambiguity instead of inventing a scheme
    // from another body field. Explicit origin hints keep their precedence.
    var selected = hinted.hostname ? hinted : anchored.hostname ? anchored
        : { hostname: legacy.origin, identity: legacy.identity };
    var origin = browser ? selected.hostname : "";
    var sourceIdentity = browser ? selected.identity : "";
    var source = webSourceForOrigin(origin);
    var body = rawBody;
    if (browser && anchor && anchored.identity === sourceIdentity)
        body = stripMarkup(textValue(notification.body).slice(anchor[0].length));
    else if (origin !== "" && legacy.identity === sourceIdentity)
        body = legacy.body;

    var summary = singleLine(notification.summary);
    if (body !== "" && comparableText(body) === comparableText(summary))
        body = "";

    return {
        browser: browser,
        displayAppName: origin !== "" ? displayNameForOrigin(origin)
            : (singleLine(notification.appName) || "Notification"),
        displaySummary: summary,
        displayBody: body,
        webOrigin: origin,
        webSourceIdentity: sourceIdentity,
        brandIcon: source ? source.brandIcon : ""
    };
}

function actionIdentifier(action) {
    if (!action || typeof action !== "object")
        return "";
    return textValue(action.identifier || action.id || action.key).toLowerCase();
}

function actionList(actions) {
    if (!actions || typeof actions.length !== "number")
        return [];
    var list = [];
    for (var i = 0; i < Math.min(16, actions.length); i++)
        list.push(actions[i]);
    return list;
}

function defaultAction(actions) {
    var list = actionList(actions);
    for (var i = 0; i < list.length; i++) {
        if (actionIdentifier(list[i]) === "default")
            return list[i];
    }
    return null;
}

function secondaryActions(actions) {
    var list = actionList(actions);
    return list.filter(function(action) {
        var identifier = actionIdentifier(action);
        return identifier !== "default" && identifier !== "close"
            && singleLine(action && action.text) !== "";
    }).slice(0, 2);
}

function visibleCharacterCount(entry) {
    entry = entry || {};
    return singleLine(entry.displaySummary || entry.summary).length
        + singleLine(entry.displayBody || entry.body).length;
}

// baseMs is the user's configured toast duration; the adaptive extension for
// long text and the sender-requested clamp both stay relative to it so the
// setting shifts the whole window rather than being overridden.
function timeoutMs(visibleCharacters, requestedSeconds, baseMs) {
    var base = typeof baseMs === "number" && isFinite(baseMs) && baseMs > 0
        ? Math.round(baseMs) : MIN_TIMEOUT_MS;
    var cap = base + (MAX_TIMEOUT_MS - MIN_TIMEOUT_MS);
    if (typeof requestedSeconds === "number" && isFinite(requestedSeconds)
            && requestedSeconds > 0) {
        return Math.max(base, Math.min(cap, Math.round(requestedSeconds * 1000)));
    }
    var count = typeof visibleCharacters === "number" && isFinite(visibleCharacters)
        ? Math.max(0, Math.floor(visibleCharacters)) : 0;
    var extraSeconds = count <= 80 ? 0 : Math.ceil((count - 80) / 40);
    return Math.min(cap, base + extraSeconds * 1000);
}

// This describes precedence without doing any Qt theme lookups. Web sources
// deliberately omit the browser's app icon once their origin is known.
function iconPreference(entry) {
    entry = entry || {};
    var choices = [];
    if (textValue(entry.brandIcon) !== "")
        choices.push({ kind: "brand", value: entry.brandIcon });
    if (textValue(entry.webOrigin) !== "") {
        if (textValue(entry.image) !== "")
            choices.push({ kind: "image", value: entry.image });
        if (textValue(entry.siteIcon) !== "")
            choices.push({ kind: "site-icon", value: entry.siteIcon });
        choices.push({ kind: "web-fallback", value: "" });
        return choices;
    }
    if (textValue(entry.appIcon) !== "")
        choices.push({ kind: "app-icon", value: entry.appIcon });
    if (textValue(entry.desktopEntry) !== "")
        choices.push({ kind: "desktop-entry", value: entry.desktopEntry });
    if (textValue(entry.image) !== "")
        choices.push({ kind: "image", value: entry.image });
    choices.push({ kind: "generic-fallback", value: "" });
    return choices;
}

// Milliseconds until a "N min left" countdown to `untilMs` next reads
// differently, or 0 once the deadline has passed. The label is
// ceil(remaining / 1 min), so it steps exactly on whole minutes before the
// deadline, and the last wait lands on the deadline itself — which is when
// the caller ends the countdown. `minimumMs` keeps a timer that fired a
// little early (Qt's coarse timers may) from spinning.
function countdownTickMs(untilMs, nowMs, minimumMs) {
    var remaining = untilMs - nowMs;
    if (!(remaining > 0))
        return 0;
    var minute = 60000;
    var wait = remaining - minute * (Math.ceil(remaining / minute) - 1);
    return Math.max(minimumMs === undefined ? 50 : minimumMs, wait);
}

var exported = {
    textValue: textValue,
    actionList: actionList,
    MIN_TIMEOUT_MS: MIN_TIMEOUT_MS,
    MAX_TIMEOUT_MS: MAX_TIMEOUT_MS,
    decodeEntities: decodeEntities,
    stripMarkup: stripMarkup,
    singleLine: singleLine,
    normalizeOrigin: normalizeOrigin,
    webSource: webSource,
    canonicalOriginHost: canonicalOriginHost,
    canonicalWebSourceIdentity: canonicalWebSourceIdentity,
    isBrowser: isBrowser,
    parseLegacyBody: parseLegacyBody,
    derivePresentation: derivePresentation,
    actionIdentifier: actionIdentifier,
    defaultAction: defaultAction,
    secondaryActions: secondaryActions,
    visibleCharacterCount: visibleCharacterCount,
    timeoutMs: timeoutMs,
    iconPreference: iconPreference,
    countdownTickMs: countdownTickMs
};

if (typeof module !== "undefined" && module.exports)
    module.exports = exported;
