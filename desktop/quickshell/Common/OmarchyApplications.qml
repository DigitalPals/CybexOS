pragma Singleton
import QtQuick
import Quickshell

Singleton {
    id: root
    signal appsChanged()
    readonly property var entries: DesktopEntries.applications.values
    onEntriesChanged: appsChanged()

    function entryName(entry) { return entry ? String(entry.name || entry.id || "") : ""; }
    function entrySubtext(entry) { return entry ? String(entry.genericName || entry.comment || "") : ""; }
    function sortedEntries(query) {
        const needle = String(query || "").toLowerCase();
        return entries.filter(entry => !entry.noDisplay
            && (entryName(entry) + " " + entrySubtext(entry)).toLowerCase().includes(needle))
            .slice().sort((a, b) => entryName(a).localeCompare(entryName(b)));
    }
    function iconSource(icon) {
        const value = String(icon || "");
        return /^(file:|image:|\/)/.test(value) ? value : Quickshell.iconPath(value || "application-x-executable", true);
    }
    function refreshIcons() { appsChanged(); }
    function launch(desktopId, name) {
        const id = String(desktopId).replace(/\.desktop$/, "");
        const entry = entries.find(item => String(item.id).replace(/\.desktop$/, "") === id);
        if (!entry)
            return false;
        entry.execute();
        return true;
    }
    function remove(desktopId, name) {
        // Package/application deletion requires a distribution-specific flow.
        return false;
    }
}
