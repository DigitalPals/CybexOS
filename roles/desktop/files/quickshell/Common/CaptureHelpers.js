// Placement and device choice for the webcam bubble a `screen-record
// --webcam` recording shows (WebcamOverlay.qml). Pure — no Qt APIs — so the
// same code runs under Node in tests.

var CORNERS = ["bottom-right", "bottom-left", "top-left", "top-right"];

// "X,Y WxH" (slurp's format, in the compositor's logical layout) as numbers,
// or null for anything else.
function parseGeometry(text) {
    var match = /^(-?\d+),(-?\d+) (\d+)x(\d+)$/.exec(String(text || "").trim());
    if (!match)
        return null;
    var geometry = {
        x: Number(match[1]), y: Number(match[2]),
        width: Number(match[3]), height: Number(match[4])
    };
    return geometry.width > 0 && geometry.height > 0 ? geometry : null;
}

function intersect(a, b) {
    var left = Math.max(a.x, b.x);
    var top = Math.max(a.y, b.y);
    var right = Math.min(a.x + a.width, b.x + b.width);
    var bottom = Math.min(a.y + a.height, b.y + b.height);
    return right > left && bottom > top
        ? { x: left, y: top, width: right - left, height: bottom - top } : null;
}

// The bubble's diameter and its distance from the area's edges: about a
// fifth of the area's short side, so a small window recording is not
// buried, within sensible bounds on a large screen.
function bubbleMetrics(width, height) {
    var shortSide = Math.min(width, height);
    var size = Math.round(Math.max(72, Math.min(200, shortSide * 0.22)));
    var margin = Math.round(Math.max(8, Math.min(24, size * 0.12)));
    return { size: size, margin: margin };
}

// Where the overlay window goes: the part of the recorded area on the output
// that holds its bottom-right corner (a layer surface lives on one output),
// in that output's coordinates. screens are { x, y, width, height } in the
// same logical layout. Null when the area is on no output, or too small to
// hold the bubble without covering most of it.
function webcamPlacement(region, screens) {
    if (!region || !Array.isArray(screens))
        return null;
    var cornerX = region.x + region.width - 1;
    var cornerY = region.y + region.height - 1;
    var chosen = -1;
    var area = null;
    for (var index = 0; index < screens.length; index++) {
        var screen = screens[index];
        var overlap = intersect(region, screen);
        if (!overlap)
            continue;
        var holdsCorner = cornerX >= screen.x && cornerX < screen.x + screen.width
            && cornerY >= screen.y && cornerY < screen.y + screen.height;
        if (holdsCorner || area === null
                || overlap.width * overlap.height > area.width * area.height) {
            chosen = index;
            area = overlap;
            if (holdsCorner)
                break;
        }
    }
    if (chosen < 0)
        return null;
    var metrics = bubbleMetrics(area.width, area.height);
    if (Math.min(area.width, area.height) < metrics.size + metrics.margin * 2)
        return null;
    return {
        screen: chosen,
        x: area.x - screens[chosen].x,
        y: area.y - screens[chosen].y,
        width: area.width,
        height: area.height,
        size: metrics.size,
        margin: metrics.margin
    };
}

// The bubble's top-left inside an area of width × height.
function cornerPosition(corner, width, height, size, margin) {
    var right = corner === "bottom-right" || corner === "top-right";
    var bottom = corner === "bottom-right" || corner === "bottom-left";
    return {
        x: right ? width - size - margin : margin,
        y: bottom ? height - size - margin : margin
    };
}

// The corner a bubble dropped with its top-left at x, y snaps to.
function nearestCorner(x, y, width, height, size) {
    var right = x + size / 2 >= width / 2;
    var bottom = y + size / 2 >= height / 2;
    return bottom ? (right ? "bottom-right" : "bottom-left")
        : (right ? "top-right" : "top-left");
}

// Infrared cameras (Windows Hello style face login) show up as video
// devices of their own and produce a grey, flickering picture.
function isInfrared(description) {
    return /(^|[^a-z])(ir|infrared)([^a-z]|$)/i.test(String(description || ""));
}

// The camera for the bubble: the system default unless it is an infrared
// sensor, otherwise the first camera that is not. -1 when there is none.
// inputs are { description, isDefault }, in the platform's order.
function pickCamera(inputs) {
    if (!Array.isArray(inputs))
        return -1;
    var first = -1;
    for (var index = 0; index < inputs.length; index++) {
        if (isInfrared(inputs[index].description))
            continue;
        if (inputs[index].isDefault)
            return index;
        if (first < 0)
            first = index;
    }
    return first;
}

// A camera format for a bubble at most a few hundred pixels across: the
// smallest whose short side is at least 360 pixels and that runs at 24 fps
// or more. Larger formats only cost bandwidth and decoding for detail the
// bubble cannot show. Falls back to the largest format that is smaller, and
// to -1 (the camera's own default) when there is no information.
// formats are { width, height, maxFps }.
function pickCameraFormat(formats) {
    if (!Array.isArray(formats))
        return -1;
    var best = -1;
    var fallback = -1;
    for (var index = 0; index < formats.length; index++) {
        var format = formats[index];
        var pixels = format.width * format.height;
        if (!(pixels > 0) || !(format.maxFps >= 24))
            continue;
        if (Math.min(format.width, format.height) >= 360) {
            if (best < 0 || pixels < formats[best].width * formats[best].height)
                best = index;
        } else if (fallback < 0
                || pixels > formats[fallback].width * formats[fallback].height) {
            fallback = index;
        }
    }
    return best >= 0 ? best : fallback;
}

var exported = {
    CORNERS: CORNERS,
    parseGeometry: parseGeometry,
    intersect: intersect,
    bubbleMetrics: bubbleMetrics,
    webcamPlacement: webcamPlacement,
    cornerPosition: cornerPosition,
    nearestCorner: nearestCorner,
    isInfrared: isInfrared,
    pickCamera: pickCamera,
    pickCameraFormat: pickCameraFormat
};

if (typeof module !== "undefined" && module.exports)
    module.exports = exported;
