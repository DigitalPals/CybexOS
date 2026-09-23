const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { shellDir, load } = require("./shell.cjs");

const repo = path.resolve(shellDir, "../../../..");
const SettingsHelpers = load("SettingsHelpers.js");
const PanelRegistry = load("PanelRegistryData.js");

function shellPath(relative) {
    return path.join(shellDir, relative);
}

function read(relative) {
    return fs.readFileSync(shellPath(relative), "utf8");
}

function readRepo(relative) {
    return fs.readFileSync(path.join(repo, relative), "utf8");
}

test("Hermes is one configurable chip and one registry-owned popover", () => {
    const defaults = SettingsHelpers.defaults();
    const right = defaults.mods.right.map(module => module.id);
    assert.equal(right[right.indexOf("t3") + 1], "hermes");
    assert.equal(SettingsHelpers.moduleGroup("hermes"), "chip");
    assert.ok(SettingsHelpers.DETAIL_IDS.includes("hermes"));
    assert.deepEqual(defaults.modOpts.hermes,
        { showLabel: true, activityDetail: "verb" });
    assert.deepEqual(PanelRegistry.byName("hermes"), {
        name: "hermes", island: "right", moduleId: "hermes",
        source: "Popovers/HermesPopover.qml"
    });

    const bar = read("Bar/Bar.qml");
    const module = read("Bar/Modules/Hermes.qml");
    assert.match(bar, /hermes:\s*"Modules\/Hermes\.qml"/);
    assert.match(module, /moduleId:\s*"hermes"/);
    assert.match(module, /HermesChip\s*\{/);
    assert.match(module, /panelName:\s*"hermes"/);
});

test("responsive chip measurements survive their compact state", () => {
    const bar = read("Bar/Bar.qml");
    const hermes = read("Bar/HermesChip.qml");
    const t3 = read("Bar/T3Chip.qml");
    const github = read("Bar/Modules/GitHub.qml");
    const clock = read("Bar/Modules/Clock.qml");

    for (const [name, chip] of [["Hermes", hermes], ["T3", t3]]) {
        assert.match(chip,
            /detailSaving:\s*labelText\.implicitWidth\s*\+\s*spacing/,
            `${name} must retain its expanded measurement while compact`);
        assert.doesNotMatch(chip,
            /detailSaving:\s*labelText\.visible/,
            `${name} must not erase its saving when its label is hidden`);
    }
    assert.match(github,
        /detailSaving:\s*detailAvailable[\s\S]{0,80}?countLabel\.implicitWidth/);
    assert.doesNotMatch(github,
        /detailSaving:\s*countLabel\.visible/);
    assert.match(clock,
        /detailSaving:\s*Settings\.modOpts\.clock\.showDate/);
    assert.doesNotMatch(clock, /detailSaving:\s*showDate\s*\?/);
    assert.match(bar,
        /id:\s*fitTimer[\s\S]{0,600}?interval:\s*Math\.max\(1,\s*Theme\.expandDuration\s*\+\s*20\)/,
        "fit decisions must wait for animated widths to settle");
    assert.doesNotMatch(bar,
        /id:\s*fitTimer[\s\S]{0,120}?interval:\s*0/);
});

test("the menubar projects priority conversation activity", () => {
    const chip = read("Bar/HermesChip.qml");
    const facade = read("Common/Hermes.qml");
    const helpers = read("Common/HermesHelpers.js");

    assert.ok(chip.indexOf("Hermes.attentionCount > 0")
        < chip.indexOf("Hermes.errorCount > 0"));
    assert.ok(chip.indexOf("Hermes.errorCount > 0")
        < chip.indexOf("Hermes.workingCount > 1"));
    assert.match(chip,
        /Hermes\.workingCount === 1[\s\S]{0,120}?Hermes\.activityLabel/);
    assert.match(chip, /Hermes\.unreadCount > 0/);
    assert.match(chip, /Hermes\.doneCount > 0/);
    assert.match(chip, /text:\s*"⚕"/);
    assert.match(chip, /Accessible\.ignored:\s*true/);
    assert.match(facade,
        /\["full", "verb", "generic"\][\s\S]{0,100}?opts\.activityDetail/);
    assert.match(helpers,
        /if \(detailMode === "full" && conversation\.statusText\)/);
});

test("the transport reconciles native WebUI conversations without replaying prompts", () => {
    const connection = read("Common/HermesConnection.qml");
    const rpc = read("Common/HermesRpc.qml");
    const conversations = read("Common/HermesConversations.qml");
    const facade = read("Common/Hermes.qml");

    assert.match(connection, /"ws:\/\/127\.0\.0\.1:9120\/ws"/);
    assert.match(connection, /Quickshell\.env\("HERMES_MENUBAR_WS_URL"\)/);
    assert.match(connection, /generation !== root\.generation/);
    assert.match(connection, /retrySecs = Math\.min\(60, retrySecs \* 2\)/);
    assert.match(rpc, /function abortAll\(reason\)/);
    assert.doesNotMatch(rpc, /retryTimer|scheduleRetry|pendingReplay|replayQueue/);
    assert.match(conversations,
        /HermesRpc\.request\("conversations\.list"/);
    assert.match(conversations,
        /function refreshConversation[\s\S]*?const loadStatus = \(\) => HermesRpc\.request\("session\.status"[\s\S]*?HermesRpc\.request\("session\.history"[\s\S]*?root\.mergeHistory\(conversationId, result\);[\s\S]{0,100}?loadStatus\(\)/,
        "status must wait for history to import an external transcript");
    assert.match(conversations, /"\/hermes-menubar\/client\.json"/);
    assert.match(facade, /function onOpened\(\) \{ root\.hello\(\); \}/);
});

test("new chat is the non-persisted default and first send creates a WebUI session", () => {
    const conversations = read("Common/HermesConversations.qml");
    const facade = read("Common/Hermes.qml");
    const bridge = readRepo(
        "roles/desktop/files/hermes-menubar-bridge/hermes_bridge.py");
    const service = readRepo(
        "roles/desktop/templates/hermes-menubar-bridge.service.j2");

    assert.match(conversations, /property string selectedConversationId:\s*""/);
    assert.match(conversations, /title:\s*"New chat"/);
    assert.match(conversations,
        /function createConversation[\s\S]*?"conversations\.create"/);
    assert.doesNotMatch(conversations,
        /selectedConversationId[\s\S]{0,100}?settings\.setValue/);
    assert.match(facade,
        /function submit\(conversationId, text\)[\s\S]*?conversationId === ""[\s\S]*?createConversation[\s\S]*?root\.submit\(conversation\.id, prompt\)/);
    assert.match(facade,
        /function startNewChat\(\)[\s\S]*?selectConversation\("", false\)/);
    assert.match(bridge, /GET", "\/api\/sessions\?exclude_hidden=1"/);
    assert.match(bridge, /POST", "\/api\/session\/new"/);
    assert.match(bridge, /POST",\s*"\/api\/session\/delete"/);
    assert.match(service, /\/conversations\.json/);
    assert.doesNotMatch(bridge, /"channels\.|"channel\./);
    assert.doesNotMatch(bridge, /HomeAssistant|"general"|"homeassistant"/);
});

test("historical chats are selectable from a dropdown and no channel rail remains", () => {
    const commonQmldir = read("Common/qmldir");
    const popoverQmldir = read("Popovers/qmldir");
    const inbox = read("Popovers/HermesInboxPage.qml");

    assert.match(commonQmldir, /singleton HermesConversations/);
    assert.doesNotMatch(commonQmldir, /HermesChannels/);
    assert.doesNotMatch(popoverQmldir, /HermesChannelRail/);
    assert.equal(fs.existsSync(shellPath("Common/HermesChannels.qml")), false);
    assert.equal(fs.existsSync(shellPath("Popovers/HermesChannelRail.qml")), false);
    assert.match(inbox,
        /pickerRows:\s*\[HermesConversations\.newConversation\][\s\S]{0,120}?Hermes\.conversations/);
    assert.match(inbox, /ListView\s*\{[\s\S]{0,500}?cacheBuffer:\s*0/,
        "long WebUI history must use a virtualized dropdown");
    assert.match(inbox,
        /model:\s*root\.pickerOpen\s*\?\s*root\.pickerRows\s*:\s*\[\]/,
        "a closed history dropdown must not retain conversation delegates");
    assert.match(inbox, /\? "New chat" : "Conversation " \+ modelData\.title/);
    assert.match(inbox, /Hermes\.selectConversation\(conversationId\)/);
    assert.match(inbox, /HermesTranscript\s*\{/);
    assert.match(inbox, /HermesRequestCard\s*\{/);
    assert.match(inbox, /HermesComposer\s*\{/);
    assert.doesNotMatch(inbox, /HermesChannelRail/);
});

test("new chat surfaces priority work and history stays searchable", () => {
    const inbox = read("Popovers/HermesInboxPage.qml");

    assert.match(inbox,
        /for \(const priority of \["attention", "error", "working", "unread"\]\)/,
        "activity rows must retain the chip's needs-you/error/working/unread order");
    assert.match(inbox, /priorityRows:\s*allPriorityConversations\.slice\(0, 3\)/);
    assert.match(inbox,
        /showPriorityHome:\s*Hermes\.isNewChat[\s\S]{0,100}?priorityRows\.length > 0[\s\S]{0,60}?Hermes\.selectedError === ""/,
        "New-chat creation errors must replace activity shortcuts, not hide behind them");
    assert.match(inbox,
        /id:\s*activityHome[\s\S]{0,100}?visible:\s*root\.showPriorityHome/);
    assert.match(inbox,
        /Accessible\.onPressAction:\s*root\.choose\(conversation\.id\)/);

    assert.match(inbox,
        /showPickerSearch:\s*Hermes\.conversations\.length > 6/);
    assert.match(inbox,
        /function matchesPickerSearch\(conversation\)[\s\S]{0,400}?conversation\?\.title[\s\S]{0,160}?conversation\?\.statusText/);
    assert.match(inbox,
        /\.concat\(Hermes\.conversations\.filter\(conversation =>[\s\S]{0,100}?matchesPickerSearch/);
    assert.match(inbox, /label:\s*conversationRow\.requestCount \+ " req"/);
    assert.match(inbox, /label:\s*conversationRow\.unreadCount \+ " new"/);
    assert.match(inbox, /TapHandler\s*\{[\s\S]{0,100}?root\.pickerOpen \|\| root\.actionsOpen/);
    assert.match(inbox, /event\.key === Qt\.Key_Space/);
    assert.doesNotMatch(inbox, /pickerSearchInput\.text\s*=\s*""/,
        "clearing history search must preserve its query binding");
    assert.match(inbox, /onShowPickerSearchChanged:/,
        "a disappearing search row must hand focus to visible history");
});

test("Hermes normal views use one toolbar with an always-available menu", () => {
    const inbox = read("Popovers/HermesInboxPage.qml");

    assert.match(inbox, /signal setupRequested\(\)/);
    assert.match(inbox, /id:\s*actionsButton[\s\S]{0,180}?accessibleName:\s*"Hermes menu"/);
    assert.match(inbox,
        /id:\s*actionsButton[\s\S]{0,260}?accessibleDescription:\s*"Connection: "[\s\S]{0,80}?root\.connectionSummary\(\)/);
    const connectionInfo = inbox.slice(inbox.indexOf("id: connectionInfo"),
        inbox.indexOf("id: setupAction"));
    assert.match(connectionInfo, /text:\s*root\.connectionSummary\(\)/,
        "the overflow must show current connection information");
    assert.match(inbox, /label:\s*"Connection setup"/);
    assert.match(inbox, /root\.setupRequested\(\)/);
    assert.match(inbox, /label:\s*Hermes\.isNewChat \? "Refresh conversations"/);
    assert.match(inbox,
        /function choose\(conversationId\)[\s\S]{0,220}?pickerButton\.forceActiveFocus\(\)/,
        "conversation activation must return focus to the surviving toolbar");
    assert.match(inbox,
        /id:\s*refreshAction[\s\S]{0,500}?root\.closeActions\(true\)/,
        "overflow actions must restore focus to their visible trigger");
    assert.match(inbox, /restoreTriggerIfFocusHidden\(popup, trigger\)/,
        "outside-click closure must not retain focus in a hidden menu");
    assert.doesNotMatch(inbox, /symbol:\s*"add_comment"/);
});

test("remote WebUI sign-in remains primary, session-aware, and secret-safe", () => {
    const facade = read("Common/Hermes.qml");
    const chip = read("Bar/HermesChip.qml");
    const popover = read("Popovers/HermesPopover.qml");
    const auth = read("Popovers/HermesAuthPanel.qml");

    assert.match(facade,
        /remoteState === "connected" && remoteAuthenticated/);
    assert.match(facade, /HermesRpc\.request\("remote\.status", \{\}/);
    assert.match(facade,
        /HermesRpc\.request\("remote\.login", \{[\s\S]{0,120}?url: safeUrl,[\s\S]{0,80}?password: password/);
    assert.match(facade, /HermesRpc\.request\("remote\.logout", \{\}/);
    assert.doesNotMatch(facade,
        /property\s+(?:string|var)\s+\w*password/i);
    assert.match(auth, /label:\s*"Hermes WebUI URL"/);
    assert.match(auth, /label:\s*"WebUI password"/);
    assert.match(auth, /echoMode:\s*TextInput\.Password/);
    assert.match(auth,
        /Hermes\.loginRemote\(url, remotePasswordField\.text,[\s\S]{0,300}?remotePasswordField\.text = ""/);
    assert.match(auth, /never retained or displayed by Quickshell/);
    assert.match(popover, /Remote · " \+ Hermes\.remoteOrigin/);
    assert.match(chip, /remote WebUI session expired/);
});

test("streaming, tools, requests, stop, steering, and private input use conversation ids", () => {
    const facade = read("Common/Hermes.qml");
    const conversations = read("Common/HermesConversations.qml");
    const composer = read("Popovers/HermesComposer.qml");
    const request = read("Popovers/HermesRequestCard.qml");
    const tool = read("Popovers/HermesToolCard.qml");
    const bridge = readRepo(
        "roles/desktop/files/hermes-menubar-bridge/hermes_bridge.py");

    assert.match(conversations, /Helpers\.applyMessageEvent/);
    assert.match(conversations, /Helpers\.applyToolEvent/);
    assert.match(conversations, /Helpers\.applyRequestEvent/);
    for (const method of ["approval.respond", "clarify.respond", "sudo.respond",
                          "secret.respond"])
        assert.ok(facade.includes(`"${method}"`), `${method} is not exposed`);
    assert.match(composer, /Hermes\.submit\(conversationId, promptEdit\.text\)/);
    assert.match(composer, /Hermes\.interrupt\(root\.conversationId\)/);
    assert.match(composer, /Hermes\.steer\(conversationId, promptEdit\.text\)/);
    assert.match(composer,
        /else if \(root\.working\)[\s\S]{0,80}?root\.steer\(\)/,
        "Enter must steer rather than start a second prompt during a live turn");
    assert.match(facade,
        /function steer\(conversationId, text\)[\s\S]*?"session\.steer"/);
    assert.match(request, /TextInput\.Password/);
    assert.match(request,
        /request\.kind === "sudo" \|\| root\.request\.kind === "secret"/);
    assert.match(bridge, /params\.get\("choice"\) or params\.get\("decision"\)/);
    assert.match(tool, /progress_activity/);
});

test("Hermes approvals and selectors expose safe keyboard semantics", () => {
    const request = read("Popovers/HermesRequestCard.qml");
    const reasoning = read("Popovers/HermesInlineSelect.qml");
    const models = read("Popovers/HermesModelPicker.qml");

    assert.match(request,
        /description:\s*String\(choice\.description \?\? choice\.detail/,
        "approval descriptions must survive normalization into the decision UI");
    assert.match(request,
        /maximumLineCount:\s*root\.detailExpanded \? 100000 : 7/);
    assert.match(request, /detailExpanded[\s\S]{0,80}?requestDetailText\.truncated/,
        "wrapped approval text, not a character heuristic, must drive disclosure");
    assert.match(request,
        /id:\s*requestFlick[\s\S]{0,300}?activeFocusOnTab:\s*interactive/,
        "a bounded approval card must remain keyboard-scrollable");
    assert.match(request, /function ensureVisible\(item\)/);
    assert.match(request,
        /onActiveFocusChanged:\s*if \(activeFocus\) root\.ensureVisible\(action\)/,
        "tabbing through a capped request must reveal each focused action");
    assert.doesNotMatch(request, /id:\s*requestDetailFlick/,
        "one card-level viewport must own request scrolling without a nested trap");
    assert.match(request,
        /questionIndex\+\+;[\s\S]{0,100}?detailExpanded = false;[\s\S]{0,100}?requestFlick\.contentY = 0/,
        "each clarification question must start collapsed at its prompt");
    assert.match(request, /function focusQuestionStart\(\)/,
        "question paging must move focus back to its visible prompt");
    assert.match(request,
        /Accessible\.onPressAction:[\s\S]{0,80}?root\.chooseOption\(modelData\.value\)/,
        "assistive activation must select clarification options");
    assert.match(request, /height:\s*Math\.min\(maxHeight,/,
        "requests must not push the transcript or composer outside the panel");
    assert.match(request,
        /decision === "allow_always" && confirmDecision !== decision/,
        "persistent approval must require a second explicit action");
    assert.match(request, /"Confirm always"/);
    assert.match(request, /signal responseStarted\(string requestId\)/);

    assert.match(reasoning, /function move\(delta\)/);
    assert.match(reasoning, /Qt\.Key_Down \|\| event\.key === Qt\.Key_Right/);
    assert.match(reasoning, /Qt\.Key_Escape && root\.expanded/);
    assert.match(reasoning, /Accessible\.role:\s*Accessible\.ListItem/);
    assert.match(reasoning, /function focusAdjacentChoice\(index, delta\)/);
    assert.match(reasoning, /border\.width:\s*activeFocus \? 1 : 0/);
    assert.match(reasoning, /trigger\.forceActiveFocus\(\)/,
        "closing a reasoning menu must restore focus to its visible trigger");

    assert.match(models, /property int highlighted:\s*0/);
    assert.match(models, /Accessible\.name:\s*"Search Hermes models"/);
    assert.match(models, /Accessible\.role:\s*Accessible\.EditableText/);
    assert.match(models, /root\.moveHighlight\(1\)/);
    assert.match(models, /root\.activate\(root\.rows\[root\.highlighted\]\)/);
    assert.match(models,
        /function close\(restoreFocus, restoreIfHidden\)[\s\S]{0,180}?trigger\.forceActiveFocus\(\)/,
        "closing a model menu from the keyboard must restore trigger focus");
    assert.match(models,
        /function open\(\)[\s\S]{0,700}?root\.revealHighlighted\(\)/,
        "reopening the picker must reveal its selected model");
    assert.match(models, /function focusModelRow\(index\)/);
    assert.match(models, /readonly property var configuredGroup:/);
    assert.doesNotMatch(models, /providerRail|providerFlick|chooseProvider/,
        "provider selection belongs in Hermes configuration, not the composer");
    assert.match(models,
        /id:\s*modelRow[\s\S]{0,1000}?border\.width:\s*activeFocus \? 1 : 0/,
        "tab-focused model rows need a visible focus ring");
});

test("Hermes history projects prose, one tool activity line, pagination, and compact long messages", () => {
    const helpers = read("Common/HermesHelpers.js");
    const conversations = read("Common/HermesConversations.qml");
    const transcript = read("Popovers/HermesTranscript.qml");
    const tool = read("Popovers/HermesToolCard.qml");
    const bridge = readRepo(
        "roles/desktop/files/hermes-menubar-bridge/hermes_bridge.py");

    assert.match(helpers, /function renderableMessage/);
    assert.match(helpers, /return "metadata"/,
        "unknown protocol roles must not default to assistant prose");
    assert.match(helpers, /function transcriptItems/);
    assert.match(conversations, /Helpers\.normalizeHistory/);
    assert.match(conversations, /function loadEarlier/);
    assert.match(conversations, /before:\s*Math\.max/);
    assert.match(transcript, /model:\s*transcriptModel/);
    assert.match(transcript, /Helpers\.transcriptItems\(allMessages, \[\]\)/,
        "persisted tool records must not become transcript rows");
    assert.match(transcript, /property var latestTool:/);
    assert.equal((transcript.match(/HermesToolCard\s*\{/g) || []).length, 1,
        "tool activity must render through one updating line");
    assert.match(transcript, /HermesConversations\.loadEarlier/);
    assert.match(transcript, /property bool longMessage:/);
    assert.match(transcript, /maximumLineCount:[\s\S]{0,120}?14/);
    assert.match(transcript, /ActionButton\s*\{[\s\S]{0,320}?"Show more"/);
    assert.match(transcript, /property string messageText:\s*String/,
        "optional remote text must not assign undefined to QString");
    assert.match(tool, /tool\.output/);
    assert.match(tool, /property string toolName:\s*String/,
        "optional historical tool labels must have a QString-safe fallback");
    assert.match(tool, /implicitHeight:\s*30/);
    assert.match(tool, /property string detailText:/);
    assert.doesNotMatch(tool, /expanded|"INPUT"|"OUTPUT"/,
        "tool activity must stay a single non-expanding line");
    assert.match(bridge, /project_remote_transcript/);
    assert.match(bridge, /msg_limit=/);
    assert.match(bridge, /"session\.todos"/);
    assert.match(bridge, /"session\.context"/);
    assert.match(bridge, /"session\.goal"/);
    assert.match(bridge, /"session\.warning"/);
});

test("selected conversation failures stay visible and dismiss one occurrence", () => {
    const facade = read("Common/Hermes.qml");
    const conversations = read("Common/HermesConversations.qml");
    const transcript = read("Popovers/HermesTranscript.qml");

    assert.match(conversations,
        /property var dismissedErrorSequencesByConversation:\s*\(\{\}\)/);
    assert.match(conversations,
        /function setError\(conversationId, value, retry\)[\s\S]*?sequence:\s*\+\+errorSequence/,
        "a later identical failure must be a new dismissible occurrence");
    assert.match(conversations,
        /function errorFor\(conversationId\)[\s\S]*?dismissed !== record\.sequence/);
    assert.match(conversations,
        /function dismissError\(conversationId\)[\s\S]*?record\.sequence/);
    assert.match(conversations,
        /setError\(conversationId, reason, "refresh"\)/,
        "only an existing read-only reload path should advertise retry");
    assert.match(conversations,
        /setError\(conversationId, reason, "load-earlier"\)/);
    assert.match(facade, /function dismissSelectedError\(\)/);
    assert.match(facade, /function retrySelectedError\(\)/);
    assert.match(transcript,
        /id:\s*errorBanner[\s\S]{0,120}?visible:\s*Hermes\.selectedError !== ""/,
        "the error banner must not depend on an empty transcript");
    assert.match(transcript, /Accessible\.role:\s*Accessible\.AlertMessage/);
    assert.match(transcript,
        /Hermes\.dismissSelectedError\(\)[\s\S]{0,80}?root\.errorHandled\(\)/);
    const retryControl = transcript.slice(transcript.indexOf("id: retryError"),
        transcript.indexOf("id: errorMessage"));
    assert.match(retryControl, /visible:\s*Hermes\.selectedErrorRetryable/);
    assert.match(retryControl,
        /Hermes\.retrySelectedError\(\)[\s\S]{0,80}?root\.errorHandled\(\)/);
    assert.match(transcript, /signal errorHandled\(\)/);
    assert.match(transcript, /anchors\.fill:\s*transcriptFlick/,
        "fixed feedback must leave scroll chrome bound to the resized viewport");
});

test("Hermes uses the compact T3-style composer with live model and reasoning controls", () => {
    const facade = read("Common/Hermes.qml");
    const theme = read("Common/HermesTheme.qml");
    const composer = read("Popovers/HermesComposer.qml");
    const inbox = read("Popovers/HermesInboxPage.qml");
    const popover = read("Popovers/HermesPopover.qml");
    const strip = read("Popovers/HermesSessionStrip.qml");
    const auth = read("Popovers/HermesAuthPanel.qml");
    const bridge = readRepo(
        "roles/desktop/files/hermes-menubar-bridge/hermes_bridge.py");

    assert.match(theme, /readonly property color composerGlass:/);
    assert.match(composer, /color:\s*HermesTheme\.composerGlass/);
    assert.match(composer, /HermesModelPicker\s*\{/);
    assert.match(composer,
        /id:\s*modelSelect[\s\S]{0,300}?openUpward:\s*false/,
        "the model picker must open below the composer control");
    assert.match(composer,
        /readonly property real modelPickerOverflowHeight:[\s\S]{0,120}?modelSelect\.popupHeight \+ 6/,
        "the composer must publish the model picker's detached extent");
    assert.match(composer,
        /name:\s*root\.sending \? "more_horiz" : "arrow_upward"[\s\S]{0,100}?color:\s*"white"/,
        "the send arrow must remain visible against the accent fill");
    assert.match(composer,
        /!primaryMouse\.enabled \? Theme\.accentAlpha\(0\.35\)/,
        "disabled styling belongs on the circle fill, not the white send glyph");
    assert.doesNotMatch(composer,
        /opacity:\s*primaryMouse\.enabled \? 1 : 0\.35/);
    assert.match(composer, /HermesInlineSelect\s*\{/);
    assert.match(composer, /text:\s*"Reasoning"/);
    assert.match(composer, /radius:\s*width \/ 2/,
        "the primary send/stop action should be circular");
    assert.match(composer, /HermesTheme\.dangerForeground/);
    assert.match(inbox, /HermesSessionStrip\s*\{/);
    assert.match(strip, /HermesConversations\.sessionStateFor/);
    assert.match(popover, /visible:\s*root\.showingSetup/);
    assert.doesNotMatch(popover,
        /visible:\s*root\.showingSetup \|\| Hermes\.isNewChat/,
        "New chat must not restore the removed second toolbar/footer");
    assert.match(popover,
        /onSetupRequested:\s*root\.openSetup\(\)/);
    assert.match(popover,
        /detachedOverflowHeight:\s*!root\.showingSetup[\s\S]{0,100}?inbox\.detachedOverflowHeight/,
        "the Hermes surface must pass model-menu overflow to the popout host");
    assert.match(inbox,
        /implicitHeight:\s*Math\.min\(maxHeight, content\.implicitHeight\)[\s\S]{0,80}?\+ detachedOverflowHeight/,
        "model-menu overflow must extend below the bounded conversation view");
    assert.match(popover,
        /function closeSetup\(\)[\s\S]{0,300}?inbox\.focusToolbar\(\)/,
        "leaving setup must return focus to the visible conversation toolbar");
    assert.match(popover,
        /onShowingSetupChanged:[\s\S]{0,260}?authPanel\.focusFirstField\(\)[\s\S]{0,100}?inbox\.focusToolbar\(\)/,
        "automatic setup state transitions must hand focus to the visible page");
    assert.match(auth,
        /function focusFirstField\(\)[\s\S]{0,320}?backToChat\.forceActiveFocus\(\)/,
        "connected setup must focus its visible Back action");
    assert.match(auth, /id:\s*authFlick/);
    assert.match(auth,
        /function ensureVisible\(item\)[\s\S]{0,900}?authFlick\.contentY/,
        "keyboard focus must keep long setup forms in view");
    assert.match(auth,
        /function logoutRemote\(\)[\s\S]{0,900}?root\.focusFirstField\(\)/,
        "remote sign-out must focus a control that remains visible");
    assert.match(inbox,
        /errorFloor:\s*Hermes\.selectedError !== "" \? 64 : 0/);
    assert.match(inbox,
        /transcriptFloor:\s*requests\.length > 0 \? errorFloor/,
        "request-time errors must reserve banner height in normal flow");
    assert.match(inbox, /requestMaxHeight:\s*Math\.max\(requestFloor,/);
    assert.match(strip, /property bool forceCompact:\s*false/);
    assert.match(inbox,
        /forceCompact:\s*root\.requests\.length > 0 \|\| root\.maxHeight < 580/);
    assert.match(strip,
        /Accessible\.role:\s*root\.expandable \? Accessible\.Button[\s\S]{0,80}?Accessible\.StaticText/);
    assert.match(strip,
        /Keys\.onPressed:[\s\S]{0,400}?Qt\.Key_Space/,
        "the expandable session strip must support keyboard activation");
    assert.match(strip,
        /onExpandableChanged:[\s\S]{0,100}?focusFallbackRequested\(\)/);
    assert.match(inbox,
        /onFocusFallbackRequested:\s*root\.restoreConversationFocus\(\)/);
    assert.match(inbox,
        /onRequestsChanged:[\s\S]{0,700}?restoreConversationFocus\(\)/,
        "resolving a focused request must restore a stable conversation target");
    assert.match(inbox,
        /onResponseStarted:[\s\S]{0,100}?root\.trackRequestResponse\(requestId\)/);
    assert.match(popover, /threadMaxHeight/);
    assert.match(facade, /HermesRpc\.request\("models\.catalog"/);
    assert.match(facade, /HermesRpc\.request\("reasoning\.get"/);
    assert.match(facade, /HermesRpc\.request\("reasoning\.set"/);
    assert.match(facade,
        /property string defaultReasoningEffort:[\s\S]*?loadReasoning\("", true\)/,
        "the configured model's reasoning effort must load with its catalog");
    assert.match(facade, /HermesRpc\.request\("session\.configure"/);
    assert.match(facade,
        /const raw = result\?\.conversation \?\? result\?\.session \?\? result/,
        "the server-confirmed model must replace the optimistic selection");
    assert.match(bridge, /"GET", "\/api\/models"/);
    assert.match(bridge,
        /active_provider and provider_id != active_provider/,
        "the bridge must not publish unconfigured provider groups");
    assert.match(bridge, /"POST", "\/api\/reasoning"/);
    assert.match(bridge, /"POST", "\/api\/session\/update"/);
    assert.match(bridge, /accepted_model = str\([\s\S]{0,300}?session\.get\("model"\)/,
        "session updates must use the model accepted by Hermes");
    assert.match(bridge, /"explicit_model_pick"/);
});

test("Hermes exposes capability-gated attachments, branches, editing, and regeneration", () => {
    const facade = read("Common/Hermes.qml");
    const composer = read("Popovers/HermesComposer.qml");
    const transcript = read("Popovers/HermesTranscript.qml");
    const inbox = read("Popovers/HermesInboxPage.qml");
    const helpers = read("Common/HermesHelpers.js");
    const bridge = readRepo(
        "roles/desktop/files/hermes-menubar-bridge/hermes_bridge.py");

    assert.match(composer, /Hermes\.capabilities\.attachments === true/);
    assert.match(facade, /"zenity", "--file-selection", "--multiple"/);
    assert.match(composer, /Hermes\.pickAttachments\(conversationId\)/);
    assert.match(facade, /stageAttachments\(conversationId, paths\)/);
    assert.match(facade,
        /"prompt\.submit"[\s\S]{0,300}?attachments:\s*staged\.map/);
    assert.match(bridge, /multipart\/form-data; boundary=/);
    assert.match(bridge, /MAX_REMOTE_ATTACHMENT_BYTES\s*=\s*20 \* 1024 \* 1024/);
    assert.match(bridge, /O_NOFOLLOW/);
    assert.match(bridge, /self\.remote_auth\.upload_file\(\s*"\/api\/upload"/);
    assert.match(helpers, /function normalizeAttachments/);

    assert.match(inbox, /Hermes\.capabilities\.branches === true/);
    assert.match(transcript, /Hermes\.capabilities\.branches === true/);
    assert.match(transcript, /Hermes\.capabilities\.messageEditing === true/);
    assert.match(transcript, /Hermes\.capabilities\.regeneration === true/);
    assert.match(facade, /HermesRpc\.request\("session\.branch"/);
    assert.match(facade, /HermesRpc\.request\("message\.edit"/);
    assert.match(facade, /HermesRpc\.request\("message\.regenerate"/);
    assert.match(bridge, /"\/api\/session\/branch"/);
    assert.match(bridge, /"\/api\/session\/truncate"/);
    assert.match(bridge, /"regeneration_revision"/);
    assert.match(bridge, /remote_route_supported/,
        "older WebUIs must be probed before advanced controls appear");
});
