// The webcam bubble of `screen-record --webcam` and the scrolling-screenshot
// indicator: placement and device choice (pure helpers), and the structure
// that keeps the camera open only while a recording runs.
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { shellDir, load } = require("./shell.cjs");

const H = load("CaptureHelpers.js");
const read = relative => fs.readFileSync(path.join(shellDir, relative), "utf8");

test("recorded areas parse from slurp's geometry and nothing else", () => {
    assert.deepEqual(H.parseGeometry("10,-20 300x200\n"), { x: 10, y: -20, width: 300, height: 200 });
    for (const bad of ["", "10,20 0x200", "10,20 300x200 extra", "a,b cxd", null, undefined])
        assert.equal(H.parseGeometry(bad), null, String(bad));
});

test("the bubble sits on the output holding the area's bottom-right corner", () => {
    const screens = [
        { x: 0, y: 0, width: 1920, height: 1080 },
        { x: 1920, y: 0, width: 1280, height: 720 }
    ];
    // Entirely on the second output: coordinates become that output's own.
    let placement = H.webcamPlacement({ x: 2000, y: 100, width: 800, height: 500 }, screens);
    assert.deepEqual(placement, { screen: 1, x: 80, y: 100, width: 800, height: 500, size: 110, margin: 13 });

    // Spanning both outputs: the part on the output with the corner.
    placement = H.webcamPlacement({ x: 1000, y: 0, width: 1500, height: 600 }, screens);
    assert.equal(placement.screen, 1);
    assert.deepEqual([placement.x, placement.y, placement.width, placement.height], [0, 0, 580, 600]);

    // A corner on no output (below the second one's bottom edge): the
    // output with the larger share of the area, 280×720 against 120×1000.
    placement = H.webcamPlacement({ x: 1800, y: 0, width: 400, height: 1000 }, screens);
    assert.deepEqual([placement.screen, placement.width, placement.height], [1, 280, 720]);

    // A full 4K screen caps the size; a tiny area gets no bubble at all.
    const large = H.webcamPlacement({ x: 0, y: 0, width: 3840, height: 2160 },
        [{ x: 0, y: 0, width: 3840, height: 2160 }]);
    assert.equal(large.size, 200);
    assert.equal(H.webcamPlacement({ x: 0, y: 0, width: 90, height: 60 }, screens), null);
    assert.equal(H.webcamPlacement({ x: 5000, y: 0, width: 400, height: 400 }, screens), null);
    assert.equal(H.webcamPlacement(null, screens), null);
});

test("corners position and snap the bubble", () => {
    assert.deepEqual(H.cornerPosition("bottom-right", 800, 500, 110, 13), { x: 677, y: 377 });
    assert.deepEqual(H.cornerPosition("top-left", 800, 500, 110, 13), { x: 13, y: 13 });
    assert.deepEqual(H.cornerPosition("top-right", 800, 500, 110, 13), { x: 677, y: 13 });
    assert.deepEqual(H.cornerPosition("bottom-left", 800, 500, 110, 13), { x: 13, y: 377 });
    assert.equal(H.nearestCorner(30, 20, 800, 500, 110), "top-left");
    assert.equal(H.nearestCorner(600, 20, 800, 500, 110), "top-right");
    assert.equal(H.nearestCorner(30, 300, 800, 500, 110), "bottom-left");
    assert.equal(H.nearestCorner(500, 300, 800, 500, 110), "bottom-right");
    for (const corner of H.CORNERS) {
        const at = H.cornerPosition(corner, 800, 500, 110, 13);
        assert.equal(H.nearestCorner(at.x, at.y, 800, 500, 110), corner);
    }
});

test("the default camera is used unless it is an infrared sensor", () => {
    const camera = (description, isDefault = false) => ({ description, isDefault });
    assert.equal(H.pickCamera([camera("Integrated Camera"), camera("USB Webcam", true)]), 1);
    assert.equal(H.pickCamera([camera("Integrated IR Camera", true), camera("Integrated Camera")]), 1);
    assert.equal(H.pickCamera([camera("Infrared Camera"), camera("Hardware ISP Camera")]), 1);
    assert.equal(H.pickCamera([camera("Mirrorless Capture")]), 0, "\"ir\" inside a word is not IR");
    assert.equal(H.pickCamera([camera("IR_Camera", true)]), -1);
    assert.equal(H.pickCamera([]), -1);
    assert.equal(H.pickCamera(undefined), -1);
});

test("a light camera format is preferred for the small bubble", () => {
    const format = (width, height, maxFps) => ({ width, height, maxFps });
    assert.equal(H.pickCameraFormat([format(1920, 1080, 30), format(640, 480, 30),
        format(1280, 720, 30), format(320, 240, 30)]), 1);
    assert.equal(H.pickCameraFormat([format(1920, 1080, 30), format(640, 480, 15)]), 0,
        "too slow a format is skipped");
    assert.equal(H.pickCameraFormat([format(320, 240, 30), format(160, 120, 30)]), 0,
        "the largest small format when no format reaches 360 lines");
    assert.equal(H.pickCameraFormat([format(0, 0, 30)]), -1);
    assert.equal(H.pickCameraFormat(null), -1);
});

test("the camera exists only while a --webcam recording runs", () => {
    const shell = read("shell.qml");
    assert.match(shell, /LazyLoader\s*\{\s*active:\s*Recorder\.webcamWanted\s*WebcamOverlay\s*\{\}\s*\}/);
    assert.match(read("qmldir"), /^WebcamOverlay WebcamOverlay\.qml$/m);

    const recorder = read("Common/Recorder.qml");
    assert.match(recorder, /path: root\.stateDir \+ "\/webcam"/);
    assert.match(recorder,
        /webcamWanted: webcamRequested\s*&& \(active \|\| webcamStartup\.running\)/,
        "a request left behind without a recording must not keep the camera open");
    assert.match(recorder, /id: webcamStartup\s*interval: \d+/);
});

test("the bubble is a round, input-masked overlay inside the recorded area", () => {
    const overlay = read("WebcamOverlay.qml");
    assert.match(overlay, /^import QtMultimedia$/m);
    assert.match(overlay, /WlrLayershell\.layer: WlrLayer\.Overlay/,
        "the recording must include the bubble");
    assert.match(overlay, /WlrLayershell\.keyboardFocus: WlrKeyboardFocus\.None/);
    assert.match(overlay, /exclusionMode: ExclusionMode\.Ignore/);
    assert.match(overlay, /mask: Region \{\s*item: bubble\s*\}/,
        "the recorded area must stay usable around the bubble");
    assert.match(overlay, /color: "transparent"/);
    assert.match(overlay, /CaptureSession \{[\s\S]*camera: Camera \{[\s\S]*videoOutput: preview/);
    assert.match(overlay, /: mediaDevices\.defaultVideoInput\s*active: root\.cameraWanted/);
    assert.match(overlay,
        /cameraWanted: root\.formatChosen && root\.cameraDevice !== null\s*&& root\.placement !== null && !root\.failed/,
        "the camera opens only with a device, a format and a place to show it");
    assert.match(overlay, /CaptureHelpers\.pickCamera\(/);
    assert.match(overlay, /CaptureHelpers\.pickCameraFormat\(/);
    assert.match(overlay, /CaptureHelpers\.webcamPlacement\(root\.region, screens\)/);
    assert.match(overlay, /maskEnabled: true\s*maskSource: bubbleMask/);
    assert.match(overlay, /id: bubbleMask[\s\S]*radius: width \/ 2/);
    assert.match(overlay, /xScale: -1/, "the preview is mirrored");
    assert.match(overlay, /drag\.target: bubble/);
    assert.match(overlay, /Recorder\.webcamCorner = CaptureHelpers\.nearestCorner\(/);
    // One notice at most, whatever went wrong.
    assert.match(overlay, /if \(root\.told\)\s*return;\s*root\.told = true;/);
    assert.match(overlay, /No camera found\. Recording without the webcam\./);
    assert.match(overlay, /onErrorOccurred: \{\s*root\.failed = true;/);
    assert.match(overlay, /visible: root\.targetScreen !== null && root\.cameraDevice !== null && !root\.failed/);
});

test("a scrolling screenshot lights the recording indicator and finishes from it", () => {
    const recorder = read("Common/Recorder.qml");
    const indicators = read("Bar/Modules/Indicators.qml");
    assert.match(recorder, /path: root\.stateDir \+ "\/scroll-capture"/);
    assert.match(recorder, /path: root\.scrollPid > 0 \? "\/proc\/" \+ root\.scrollPid \+ "\/stat" : ""/);
    assert.match(recorder,
        /root\.scrolling = root\.scrollStartTicks !== ""\s*&& root\.startTicks\(text\(\)\) === root\.scrollStartTicks/,
        "a killed capture cannot leave the indicator lit");
    assert.match(recorder,
        /running: root\.scrollPid > 0 && root\.scrolling\s*repeat: true\s*onTriggered: scrollStatView\.reload\(\)/,
        "only a live capture is polled");
    assert.match(recorder, /Quickshell\.execDetached\(\[root\.screenshotScript, "scroll-stop"\]\)/,
        "the indicator can finish a capture but never start one");
    assert.match(indicators, /case "recording": return Recorder\.active \|\| Recorder\.scrolling;/);
    assert.match(indicators,
        /if \(Recorder\.scrolling && !Recorder\.active\)\s*Recorder\.finishScroll\(\);\s*else\s*Recorder\.toggle/);
    assert.match(indicators, /Finish scrolling screenshot · Enter/);

    const screenshot = fs.readFileSync(path.resolve(__dirname, "../../assets/scripts/screenshot"), "utf8");
    assert.match(screenshot, /RECORD_STATE_DIR="\$\{XDG_RUNTIME_DIR:-\/tmp\}\/screen-record"/,
        "the script and the shell must agree on the state directory");
    assert.match(screenshot, /SCROLL_STATE="\$RECORD_STATE_DIR\/scroll-capture"/);
});
