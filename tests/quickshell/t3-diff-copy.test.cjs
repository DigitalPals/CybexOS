const test = require("node:test");
const { untranslated } = require("./shell.cjs");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { shellDir } = require("./shell.cjs");

function read(relative) {
    return untranslated(fs.readFileSync(path.join(shellDir, relative), "utf8"));
}

test("full diff copy is on demand and never becomes singleton state", () => {
    const detail = read("Common/T3Detail.qml");
    const copy = detail.slice(detail.indexOf("function copyFullThreadDiff"),
        detail.indexOf("function reconcileCommandEvent"));

    assert.match(copy, /actionKey\("diff-copy", threadId, ""\)/);
    assert.match(copy, /requestOnce\("orchestration\.getFullThreadDiff"/);
    assert.match(copy,
        /root\.detailThreadId !== threadId[\s\S]{0,180}?root\.detailCheckpointSummary\?\.checkpointRef !== checkpoint\.checkpointRef/,
        "a response for a replaced thread/checkpoint must not reach the clipboard");
    assert.match(copy, /Quickshell\.clipboardText = value\.diff/);
    assert.doesNotMatch(copy, /detailDiff\s*=|fullText|fullDiff\s*=/,
        "the transient full payload must not be assigned to singleton state");
    assert.doesNotMatch(detail, /property\s+(?:var|string)\s+(?:fullText|fullDiff)\b/);
});

test("full diff copy shares detail lifecycle cancellation and exposes failures", () => {
    const detail = read("Common/T3Detail.qml");
    const facade = read("Common/T3Code.qml");
    const page = read("Popovers/T3ThreadPage.qml");
    const cancel = detail.slice(detail.indexOf("function cancelDiffRequests"),
        detail.indexOf("function loadFullThreadDiff"));

    assert.match(cancel, /actionKey\("diff", threadId, ""\)/);
    assert.match(cancel, /actionKey\("diff-copy", threadId, ""\)/);
    assert.ok((detail.match(/cancelDiffRequests\(/g) ?? []).length >= 6,
        "checkpoint replacement, resubscribe, thread switch, and close must cancel both requests");
    assert.match(facade,
        /function copyFullThreadDiff\(threadId, checkpoint\)[\s\S]{0,120}?T3Detail\.copyFullThreadDiff/);
    assert.match(page, /label:\s*root\.fullDiffCopyPending \? "Copying full patch…" : "Copy full patch"/);
    assert.match(page, /onTriggered:\s*T3Code\.copyFullThreadDiff\(root\.threadId, root\.checkpoint\)/);
    assert.match(page, /visible:\s*root\.fullDiffCopyError !== ""[\s\S]{0,100}?text:\s*root\.fullDiffCopyError/);
});
