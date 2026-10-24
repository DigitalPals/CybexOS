pragma Singleton

import QtQuick
import Quickshell
import "I18nHelpers.js" as I18nHelpers
import "i18n/nl.js" as Nl

// The shell's own text in the session's language. Settings → Region sets
// the system language, which applies at the next login to every
// application; the shell follows the same rule rather than offering a
// language choice of its own. CYBEXOS_LANG overrides it for tests and
// screenshots. Untranslated text stays English.
Singleton {
    id: root

    readonly property string language: I18nHelpers.languageFor([
        Quickshell.env("CYBEXOS_LANG"), Quickshell.env("LC_ALL"),
        Quickshell.env("LC_MESSAGES"), Quickshell.env("LANG")])
    readonly property var catalog: language === "nl" ? Nl.MESSAGES : ({})

    function tr(text: string): string {
        return I18nHelpers.translate(root.catalog, text);
    }

    // tr() with positional %1…%9 arguments filled in after translation.
    function format(text: string, args: var): string {
        return I18nHelpers.format(root.catalog, text, args);
    }
}
