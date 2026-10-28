pragma Singleton
import QtQuick
import "../Common"
import "ChangesModel.js" as Model

// Everything in Settings that waits for Apply, across pages (2026-10
// redesign). Touchpad, keyboard and shortcut drafts apply to the session;
// a regional or cleanup change is prepared as a system change, reviewed in
// Software Update and used after a restart. The header's chip counts these,
// the rail marks their pages, and ChangesSheet applies them in one go. A
// page's own Apply bar still settles its own draft.
QtObject {
    id: root

    // Home's "Review…" asks the window to open the review sheet it hosts.
    signal reviewRequested()

    readonly property var items: {
        const touchpad = InputDrafts.touchpad;
        const keyboard = InputDrafts.keyboard;
        return [].concat(
            Model.touchpadItems(touchpad.original, touchpad.draft, touchpad.changes),
            Model.keyboardItems(keyboard.original, keyboard.draft, keyboard.changes),
            Model.shortcutItems(Keybindings.changes),
            Model.regionItems(RegionDrafts, value => I18n.localeName(value)),
            Model.retentionItems(RetentionDraft.draft, RetentionDraft.policyBaseline, RetentionDraft.dirty));
    }
    readonly property int count: items.length
    readonly property var pages: Model.pagesOf(items)
    readonly property bool hasSystem: items.some(item => item.system)

    // A deployment already on its way: the updater takes one at a time.
    readonly property bool systemBusy: Updates.runActive || Updates.ready || Updates.rebootRecommended
        || Maintenance.busy || RegionDrafts.busy
    readonly property var plan: Model.plan(items, systemBusy)

    // A settings deployment the chip follows after its drafts are gone:
    // regional and cleanup changes, never a software update.
    readonly property string deploymentKind: Updates.deployment.changeKind || ""
    readonly property bool settingsDeployment: deploymentKind === "region" || deploymentKind === "maintenance"
    readonly property string deploymentState: !settingsDeployment ? ""
        : Updates.rebootRecommended ? "restart"
        : Updates.ready ? "review"
        : Updates.runActive ? "preparing" : ""

    // One Apply, one group at a time: the input service takes one request at
    // a time, and each group settles before the next starts.
    property var queue: []
    property string step: ""
    property string error: ""
    readonly property bool applying: step !== "" || queue.length > 0

    function apply() {
        if (applying || plan.steps.length === 0)
            return false;
        error = "";
        queue = plan.steps.slice();
        next();
        return true;
    }

    function discardGroup(group) {
        switch (group) {
        case "touchpad": InputDrafts.touchpad.load(); break;
        case "keyboard": InputDrafts.keyboard.load(); break;
        case "shortcuts": Keybindings.discard(); break;
        case "region": RegionDrafts.discard(); break;
        case "retention": RetentionDraft.discard(); break;
        }
    }

    function discardItem(item) {
        if (item.id === "region.timezone")
            RegionDrafts.discardTimezone();
        else if (item.id === "region.locale")
            RegionDrafts.discardLocale();
        else if (item.group === "touchpad") {
            const key = item.id.slice("touchpad.".length);
            const draft = Object.assign({}, InputDrafts.touchpad.draft);
            draft[key] = InputDrafts.touchpad.original[key];
            InputDrafts.touchpad.draft = draft;
        } else
            discardGroup(item.group);
    }

    function discardAll() {
        if (applying)
            return;
        for (const group of new Set(items.map(item => item.group)))
            discardGroup(group);
    }

    function start(group) {
        switch (group) {
        case "touchpad":
            InputDrafts.touchpad.apply();
            return InputDrafts.touchpad.submitted !== null;
        case "keyboard":
            InputDrafts.keyboard.apply();
            return InputDrafts.keyboard.submitted !== null;
        case "shortcuts":
            return Keybindings.apply() === true;
        case "region":
            return RegionDrafts.prepare();
        case "retention":
            return RetentionDraft.prepare();
        }
        return false;
    }

    function busy(group) {
        switch (group) {
        case "touchpad": return InputDrafts.touchpad.submitted !== null || InputDrafts.touchpad.service.busy;
        case "keyboard": return InputDrafts.keyboard.submitted !== null || InputDrafts.keyboard.service.busy;
        case "shortcuts": return Keybindings.busy;
        case "region": return RegionDrafts.busy;
        case "retention": return Maintenance.busy;
        }
        return false;
    }

    function stillPending(group) {
        return items.some(item => item.group === group);
    }

    function next() {
        if (queue.length === 0) {
            step = "";
            return;
        }
        step = queue[0];
        queue = queue.slice(1);
        if (!start(step)) {
            error = I18n.tr("Some changes could not be applied. Open their page to see why.");
            next();
            return;
        }
        watcher.restart();
    }

    property Timer watcher: Timer {
        interval: 150
        repeat: true
        onTriggered: {
            if (root.step === "" || root.busy(root.step))
                return;
            // A system group stays "pending" in the drafts only until its
            // request is accepted; a live group that is still dirty failed.
            if (root.stillPending(root.step) && root.step !== "retention")
                root.error = I18n.tr("Some changes could not be applied. Open their page to see why.");
            stop();
            root.next();
        }
    }
}
