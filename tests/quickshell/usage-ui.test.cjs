const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { shellDir } = require("./shell.cjs");

const popover = fs.readFileSync(
    path.join(shellDir, "Popovers", "UsagePopover.qml"), "utf8");
const usage = fs.readFileSync(
    path.join(shellDir, "Common", "Usage.qml"), "utf8");
const moduleDetail = fs.readFileSync(
    path.join(shellDir, "Settings", "ModuleDetailView.qml"), "utf8");
const settingsText = fs.readFileSync(
    path.join(shellDir, "Settings", "SettingsTextRow.qml"), "utf8");
const drawerUsage = fs.readFileSync(
    path.join(shellDir, "Popovers", "Drawer", "DrawerUsage.qml"), "utf8");
const drawerAccount = fs.readFileSync(
    path.join(shellDir, "Popovers", "Drawer", "DrawerUsageAccount.qml"), "utf8");
const drawerDetails = fs.readFileSync(
    path.join(shellDir, "Popovers", "Drawer", "DrawerUsageDetails.qml"), "utf8");

test("model usage no longer collects or renders usage history", () => {
    assert.doesNotMatch(popover, /histMode|histBars|USAGE HISTORY/);
    assert.doesNotMatch(usage,
        /property var history|recordSamples|histBars|quickshell-usage-history/);
});

test("model-specific quota periods render in full on their own line", () => {
    assert.ok(popover.includes(
        'return `${m[1]}\\n${m[2].replace(" ", "-")} usage`.toUpperCase();'));
    assert.ok(popover.includes('return `${title.toUpperCase()}\\n\\u00a0`;'),
        "single-line labels should reserve an empty subtitle row");
    assert.match(popover,
        /id:\s*cardLabel[\s\S]{0,600}?wrapMode:\s*Text\.Wrap/);
});

test("usage cards contain their content on padded tile backgrounds", () => {
    assert.match(popover,
        /id:\s*card[\s\S]{0,1100}?color:\s*Theme\.tile[\s\S]{0,100}?border\.color:\s*Theme\.hairlineSoft/);
    assert.match(popover,
        /id:\s*resetCol[\s\S]{0,700}?"resets in " \+ Usage\.formatReset[\s\S]{0,500}?Usage\.formatResetAbs/,
        "relative and absolute reset times should occupy separate contained rows");
});

test("Claude refresh is explicit and stale readings stay visibly qualified", () => {
    assert.match(usage,
        /claudeAutoRefresh[\s\S]{0,250}?--refresh-claude/,
        "the helper flag must follow the persisted setting");
    assert.match(moduleDetail,
        /Keep Claude signed in[\s\S]{0,300}?claudeAutoRefresh/,
        "credential refresh must remain visible and configurable");
    assert.match(usage,
        /if \(fetchProc\.running\)\s*return;/,
        "a refresh must not cancel an in-flight credential rotation");
    assert.match(usage, /p\.stale === true|p\.stale/);
    assert.match(popover, /Showing last known usage/);
    assert.match(popover, /last live/);
    assert.match(popover, /retry in/);
});

test("menubar quota thresholds color text without semantic backgrounds", () => {
    const chips = fs.readFileSync(
        path.join(shellDir, "Bar", "UsageChips.qml"), "utf8");
    assert.doesNotMatch(chips, /Theme\.bar(?:Amber|Red)Bg/);
    assert.match(chips, /status === "crit" \? Theme\.barRedText/);
    assert.match(chips, /status === "warn" \? Theme\.barAmber/);
});

test("provider header shows Sub2API activity or the full subscription", () => {
    assert.match(popover, /Usage.activityText\(root.sel\)/);
    assert.match(popover, /return root\.p\.plan \|\| "";/);
    assert.doesNotMatch(popover, /root\.p\.(?:account|source)/);
    assert.doesNotMatch(popover, /join\(" · "\)/);
});

test("CLIProxyAPI source and credentials are configurable without persisting the key", () => {
    assert.match(moduleDetail,
        /Usage source[\s\S]{0,500}?CLIProxyAPI[\s\S]{0,800}?Management URL/);
    assert.match(moduleDetail,
        /Verify TLS[\s\S]{0,700}?Management key[\s\S]{0,300}?secret:\s*true/);
    assert.match(usage,
        /--source[\s\S]{0,350}?--cliproxy-url[\s\S]{0,200}?--cliproxy-insecure/);
    assert.match(usage,
        /stdinEnabled:\s*action === "store"[\s\S]{0,250}?write\(pendingKey \+ "\\n"\)/,
        "the management key must go to the private helper over stdin");
    assert.doesNotMatch(usage, /command:[^\n]*pendingKey|args\.push\(pendingKey/);
    assert.match(settingsText, /echoMode:\s*root\.secret \? TextInput\.Password/);
});

test("drawer exposes every CLIProxy subscription behind a provider group", () => {
    assert.match(drawerUsage,
        /Array\.isArray\(record\.accounts\)[\s\S]{0,120}?record\.accounts/);
    assert.match(drawerUsage,
        /text:\s*"SUBSCRIPTIONS"[\s\S]{0,300}?model:\s*root\.accounts[\s\S]{0,200}?DrawerUsageAccount/);
    assert.match(drawerUsage,
        /expandedAccountId:[\s\S]{0,650}?record\.selectedAccountId[\s\S]{0,300}?record\.bestAccountId/,
        "recent activity should open first, with best quota as a fallback");
    assert.match(drawerUsage,
        /requestedAccountId === ""[\s\S]{0,80}?return ""/,
        "an explicit empty selection should keep every subscription collapsed");
    assert.match(drawerUsage,
        /function toggleAccount\(accountId\)[\s\S]{0,160}?accountId === expandedAccountId \? "" : accountId/,
        "pressing the expanded subscription should collapse it");
    assert.match(drawerUsage,
        /onToggled:\s*root\.toggleAccount\(modelData\.id\)/);
    assert.match(drawerUsage,
        /`\$\{availableCount\}\/\$\{accountCount\} \$\{noun\} available`/);
});

test("subscription accordion is accessible and keeps account failures visible", () => {
    assert.match(drawerAccount, /activeFocusOnTab:\s*visible/);
    assert.match(drawerAccount,
        /Qt\.Key_Return[\s\S]{0,180}?Qt\.Key_Enter[\s\S]{0,180}?Qt\.Key_Space/);
    assert.match(drawerAccount, /Accessible\.role:\s*Accessible\.Button/);
    assert.match(drawerAccount, /root\.expanded && !root\.ok/,
        "an unavailable account needs its own expandable error body");
    assert.match(drawerDetails,
        /hasUsage:\s*typeof modelData\.used === "number"[\s\S]{0,100}?isFinite/);
    assert.match(drawerDetails,
        /text:\s*windowCard\.hasUsage \? windowCard\.remaining : "—"/);
    assert.match(drawerDetails,
        /height:\s*contentHeight/,
        "repeated account details must report their height to the accordion");
    assert.match(drawerAccount,
        /height:\s*summary\.height[\s\S]{0,180}?usageDetails\.height/,
        "the accordion delegate must include the expanded details height");
    assert.match(drawerAccount,
        /windows:\s*root\.record && root\.record\.windows[\s\S]{0,100}?root\.record\.windows : \[\]/,
        "nested JSON windows must remain compatible with QML sequence values");
    assert.doesNotMatch(drawerAccount,
        /Array\.isArray\(root\.record\.windows\)/,
        "Array.isArray rejects valid nested sequences inside a Repeater delegate");
});

test("xAI Grok is configurable and unknown quota percentages stay unknown", () => {
    assert.match(usage,
        /supportedProviderKeys:\s*Helpers\.SUPPORTED_PROVIDER_KEYS/);
    assert.match(usage, /xai:\s*\{[^}]*title:\s*"xAI Grok"[^}]*icon:\s*"grok"/);
    assert.match(moduleDetail,
        /label:\s*"xAI \/ Grok"[\s\S]{0,500}?view\.opts\.xai/);
    assert.match(usage,
        /typeof w\.used === "number"[\s\S]{0,150}?numeric\.length === 0[\s\S]{0,80}?return -1/,
        "a null xAI percentage must not become 100% remaining on the bar");
    assert.match(popover, /hasUsage:\s*typeof modelData\.used === "number"/);
    assert.match(popover, /text:\s*card\.hasUsage \? card\.remaining : "—"/);
    assert.match(popover, /text:\s*card\.hasUsage \? "% left" : "usage unavailable"/,
        "the xAI tab should still show its reset while its percentage is absent");
});


test("Sub2API settings use their own private key and fetch configuration", () => {
    assert.match(moduleDetail, /value: "sub2api", label: "Sub2API"/);
    assert.match(moduleDetail, /label: "Server URL"[\s\S]{0,150}?sub2apiUrl/);
    assert.match(moduleDetail, /label: "Admin API key"[\s\S]{0,250}?secret: true/);
    assert.match(moduleDetail, /saveManagementKey\(text, "sub2api"\)/);
    assert.match(moduleDetail, /clearManagementKey\("sub2api"\)/);
    assert.match(usage, /--sub2api-url[\s\S]{0,150}?--sub2api-insecure/);
    assert.match(usage, /configuration !== root.fetchConfiguration[\s\S]{0,100}?Qt.callLater\(root.refresh\)/);
    assert.match(drawerUsage, /Usage.dashboardUrl/);
});


test("connection testing shares server settings, waits for key saves, and exposes results", () => {
    assert.match(moduleDetail, /"Test connection"/);
    assert.match(moduleDetail, /onTriggered: Usage.testConnection\(\)/);
    assert.match(moduleDetail, /text: Usage.connectionTestMessage/);
    assert.match(usage, /command: root.fetchCommand\(true\)/);
    assert.match(usage, /if \(testing\)[\s\S]{0,80}?--test-connection/);
    assert.match(usage, /!connectionTestPending \|\| credentialProc.running/);
    assert.match(usage, /credentialRevision\+\+/);
    assert.match(usage, /connectionTestSucceeded[\s\S]{0,600}?root.refresh\(\)/);
});


test("both Claude overview surfaces expose account-labelled Fable windows", () => {
    assert.match(popover, /model: Usage.displayWindows\(root.sel\)/);
    assert.match(drawerUsage, /additionalWindows: Usage.additionalFableWindows\(root.selected\)/);
    assert.match(drawerUsage, /windows: additionalWindows/);
});
