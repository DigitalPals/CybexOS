pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Services.Mpris
import "StatusHelpers.js" as StatusHelpers

// Which MPRIS player the shell is talking about. The selection rule
// (playing → paused → first) lives in StatusHelpers; this is the reactive
// wrapper the bar chip and the media popover both read, so a manual pick in
// the popover's source switcher starts from the same default the bar shows.
Singleton {
    id: root

    readonly property var players: Mpris.players.values
    readonly property var player: StatusHelpers.activePlayer(players)

    // A player with no track is a running app, not something to show — the
    // bar module's auto-rule turns on exactly here.
    readonly property bool hasTrack: player !== null && player.trackTitle !== ""

    readonly property string glyph: StatusHelpers.playerGlyph(player)
    readonly property string brandIcon: player
        && StatusHelpers.playerBrand(player) === "youtube" ? "youtube" : ""
    readonly property string iconSource: resolvePlayerIcon(player)

    function resolvedIcon(value) {
        if (!value)
            return "";
        if (value.startsWith("/"))
            return "file://" + value;
        if (value.startsWith("file://") || value.startsWith("data:")
                || value.startsWith("qrc:") || value.startsWith("image://"))
            return value;
        return Quickshell.iconPath(value, true);
    }

    function resolvePlayerIcon(target) {
        if (!target)
            return "";

        // The YouTube shortcut is a Brave --app window, so it has no desktop
        // entry of its own. Its MPRIS URL is classified in the pure helper.
        if (StatusHelpers.playerBrand(target) === "youtube")
            return "";

        const candidates = StatusHelpers.playerIconCandidates(target);
        for (const candidate of candidates) {
            const entry = DesktopEntries.heuristicLookup(candidate);
            if (entry && entry.icon) {
                const source = resolvedIcon(entry.icon);
                if (source !== "")
                    return source;
            }
            const source = resolvedIcon(candidate);
            if (source !== "")
                return source;
        }
        return "";
    }
}
