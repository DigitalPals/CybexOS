pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// Starred models, as the model picker's first rail entry.
//
// The reference client keeps these in the browser's localStorage rather than
// on the server, so they are per-client by design and there is no RPC to
// share them. This shell is another client: it keeps its own list, in the
// same place every other piece of per-feature shell state lives.
Singleton {
    id: root

    // [{ instanceId, model }], in the order the user starred them.
    property var favorites: []

    // A fixed path, not Quickshell.statePath(): that resolves under
    // by-shell/<config-hash>/, so a dev run from another config directory
    // would silently fork the list. Settings and the wallpaper palette are
    // pinned for the same reason.
    readonly property string statePath:
        Quickshell.env("HOME") + "/.local/state/cybexos/shell/t3-model-favorites.json"

    function isFavorite(instanceId, model) {
        return indexOf(instanceId, model) >= 0;
    }

    function indexOf(instanceId, model) {
        for (let at = 0; at < favorites.length; at++) {
            if (favorites[at].instanceId === instanceId && favorites[at].model === model)
                return at;
        }
        return -1;
    }

    function toggle(instanceId, model) {
        if (typeof instanceId !== "string" || instanceId === ""
                || typeof model !== "string" || model === "")
            return;
        const next = favorites.slice();
        const at = indexOf(instanceId, model);
        if (at >= 0)
            next.splice(at, 1);
        else
            next.push({ instanceId: instanceId, model: model });
        favorites = next;
        favoritesView.setText(JSON.stringify(favorites));
    }

    function sanitize(parsed) {
        if (!Array.isArray(parsed))
            return [];
        return parsed.filter(entry => entry && typeof entry.instanceId === "string"
            && typeof entry.model === "string" && entry.instanceId !== "" && entry.model !== "")
            .map(entry => ({ instanceId: entry.instanceId, model: entry.model }));
    }

    FileView {
        id: favoritesView
        path: root.statePath
        printErrors: false
        atomicWrites: true
        blockWrites: true
        onLoaded: {
            try {
                root.favorites = root.sanitize(JSON.parse(text()));
            } catch (e) {
                console.warn("T3 model favorites state is invalid:", e);
            }
        }
    }
}
