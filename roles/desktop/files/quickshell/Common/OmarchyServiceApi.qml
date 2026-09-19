import QtQuick

// Explicit adapters for the four non-authentication services in upstream bars.
QtObject {
    required property string serviceId
    property string selectedPlayer: ""
    readonly property bool stayAwake: serviceId === "omarchy.idle" && SysInfo.idleInhibited
    readonly property bool enabled: serviceId === "omarchy.nightlight" && Settings.nightLight
    readonly property bool doNotDisturb: serviceId === "omarchy.notifications" && Notifs.dnd
    readonly property var sourcePlayers: serviceId === "omarchy.media" ? Media.players : []
    readonly property var activePlayer: sourcePlayers.find(player => playerKey(player) === selectedPlayer) || (serviceId === "omarchy.media" ? Media.player : null)
    function setIdleEnabled(value) {
        if (serviceId === "omarchy.idle") SysInfo.setIdleInhibited(!value);
    }
    function setNightlight(value) {
        if (serviceId === "omarchy.nightlight") Settings.set("nightLight", !!value);
    }
    function setDoNotDisturb(value) {
        if (serviceId === "omarchy.notifications") Notifs.setDnd(!!value);
    }
    function playerKey(player) { return player ? String(player.dbusName || player.identity || "") : ""; }
    function selectPlayer(id) {
        if (serviceId === "omarchy.media") selectedPlayer = String(id || "");
    }
    function runAction(action, showFeedback, playerId) {
        if (serviceId !== "omarchy.media") return false;
        const player = playerId ? sourcePlayers.find(item => playerKey(item) === playerId) : activePlayer;
        if (!player) return false;
        if (action === "playPause" && player.canTogglePlaying) player.togglePlaying();
        else if (action === "play" && player.canPlay) player.play();
        else if (action === "pause" && player.canPause) player.pause();
        else if (action === "next" && player.canGoNext) player.next();
        else if (action === "previous" && player.canGoPrevious) player.previous();
        else return false;
        return true;
    }
}
