pragma Singleton

import QtQuick
import Quickshell
import "I18nHelpers.js" as I18nHelpers
import "LocaleNames.js" as LocaleNames
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

    // A shortcut's label. Numbered labels are composed in bindings.lua
    // ("Switch to workspace 3"), so they translate through "<stem> %1".
    function actionLabel(label: string): string {
        const numbered = /^(.*\D)\s+(\d+)$/.exec(label);
        if (numbered && I18nHelpers.translate(root.catalog, numbered[1] + " %1") !== numbered[1] + " %1")
            return root.format(numbered[1] + " %1", [numbered[2]]);
        return root.tr(label);
    }

    // A POSIX locale value by name in the session's language: "en_US.UTF-8"
    // is "English (United States)", "Engels (Verenigde Staten)" in Dutch.
    // An unknown language keeps the raw value.
    function localeName(value: string): string {
        const found = LocaleNames.names(value);
        if (!found)
            return value;
        return found.territory ? root.format("%1 (%2)", [root.tr(found.language), root.tr(found.territory)])
            : root.tr(found.language);
    }
}
