import QtQuick
import Quickshell
import "../Common"
import "../Common/RecoveryHelpers.js" as RecoveryHelpers

// The last row of the recovery points group, shown only on an ISO
// installation that has its factory recovery point. The first press turns
// the row into its own warning; the second opens `cybex factory-reset` in a
// terminal, which asks for the typed confirmation, the administrator
// password and, on an encrypted disk, the next owner's temporary passphrase.
// Nothing is erased from here.
ValueRow {
    id: row
    property bool confirming: false

    visible: RecoveryHelpers.hasFactoryPoint(Recovery.points)
        && !Recovery.recoveryBoot && !Recovery.restartPending
    label: I18n.tr("Factory reset")
    hint: confirming
        ? "Erases every account and all files in home folders, then restarts for a new owner. "
            + "Back up first, for example with cybex backup now."
        : "Returns this computer to its installed state for a new owner"
    hintTone: confirming ? "warning" : "info"

    SettingsAction {
        text: row.confirming ? I18n.tr("Continue in terminal") : I18n.tr("Factory reset…")
        glyph: "history"
        danger: row.confirming
        Accessible.name: row.confirming ? "Continue the factory reset in a terminal"
            : "Factory reset"
        onTriggered: {
            if (row.confirming) {
                row.confirming = false;
                Quickshell.execDetached(RecoveryHelpers.factoryResetCommand());
            } else {
                row.confirming = true;
            }
        }
    }
    SettingsAction {
        visible: row.confirming
        text: I18n.tr("Cancel")
        onTriggered: row.confirming = false
    }
}
