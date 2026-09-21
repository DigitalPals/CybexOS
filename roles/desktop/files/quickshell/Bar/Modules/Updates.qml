import QtQuick
import ".."
import "../../Common"
import "../../Common/Format.js" as Format
import "../../Common/UpdatesHelpers.js" as UpdatesHelpers

// Pending updates, and the native run's progress once one is going. The bar's
// auto-rule hides this module while a completed check has nothing to report,
// but leaves failures, manual rechecks, and every run state visible — closing
// the panel mid-run hands the story to this chip, so it must not vanish.
BarModule {
    id: root

    moduleId: "updates"
    detailSaving: chip.detailSaving

    BarIcon {
        id: chip

        // Indirection keeps the `glyph:` line to one validated ligature; the
        // icon-name test reads every string on that line as one.
        readonly property bool rebootRecommended: Updates.rebootRecommended
        readonly property string stateGlyph: chip.rebootRecommended
            ? "restart_alt" : Updates.runState === "done" ? "check"
            : "deployed_code_update"

        host: root.host
        panelName: "updates"
        isle: root.isle
        anchorItem: root.groupAnchor ?? chip
        glyph: chip.stateGlyph
        glyphSize: Theme.barIconSize - 1
        glyphWeight: 600
        glyphFill: chip.rebootRecommended || chip.alert ? 1 : 0
        // Pinned: the glyph, its completed state and the progress ring trade places here,
        // and the right cluster is right-anchored, so a wobbling column would
        // slide every module beside it.
        glyphWidth: Theme.barIconSize
        progress: Updates.runActive
            ? Math.max(0.04, Updates.runPercent / 100) : -1
        idleColor: chip.rebootRecommended ? Theme.barAmber : Theme.barIcon
        progressColor: chip.rebootRecommended ? Theme.barAmber : Theme.barAccent
        label: Updates.runActive
            ? (Updates.runPercent >= 0 ? Updates.runPercent + "%" : "…")
            : chip.rebootRecommended ? ""
            : Updates.runState === "done" ? ""
            : Updates.runState === "failed" ? "!"
            : Updates.busy ? "…" : Updates.packageError !== "" ? "!" : Updates.total
        compact: root.compact
        labelColor: chip.rebootRecommended ? Theme.barAmber
            : Updates.runActive ? Theme.barAccent : Theme.barTextMid
        alert: Updates.runState === "failed"
            || (Updates.error !== "" && Updates.runState === "idle")
        tooltip: Updates.runActive
            ? "Updating · " + (Updates.runPercent >= 0
                ? Updates.runPercent + "% · " : "")
                + Format.mmss(Updates.runElapsed)
            : chip.rebootRecommended
            ? UpdatesHelpers.rebootLabel(Updates.rebootRecommendation,
                Updates.kernelPending)
            : Updates.runState === "done" ? "Update finished · open for the transcript"
            : Updates.runState === "failed" ? "Update failed · " + Updates.failHeadline
            : "Updates · " + Updates.summary
        tooltipAlign: 1
    }
}
