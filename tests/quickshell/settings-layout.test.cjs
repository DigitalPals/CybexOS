const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '../../roles/desktop/files/quickshell');
const read = name => fs.readFileSync(path.join(root, name), 'utf8');

test('settings subsections own separation inside revealers and preserve the row grid', () => {
    const subsection = read('Settings/SettingsSubsection.qml');
    assert.match(subsection, /implicitHeight: Theme.settingsSubsectionSpacing/);
    assert.match(subsection, /heading.height[\s\S]*Theme.settingsContentSpacing/);
    assert.match(subsection, /root.insetContent \? Theme.settingsMarkInset : 0/);
    const appearance = read('Settings/AppearancePage.qml');
    assert.equal((appearance.match(/SettingsSubsection \{/g) || []).length, 3);
    assert.doesNotMatch(appearance, /SectionHeader \{/);
    for (const page of ['Appearance', 'BarLayout', 'Drawer', 'Notifications', 'System', 'Modules', 'Plugins'])
        assert.match(read(`Settings/${page}Page.qml`), /spacing: Theme.settingsGroupSpacing/);
});

test('responsive controls and focus scrolling respect their content bounds', () => {
    const picker = read('Settings/PickerRow.qml');
    assert.match(picker, /wideHeight: Math.max\(Theme.panelRowHeight, pills.implicitHeight\)/);
    for (const row of ['PickerRow', 'SliderRow', 'SettingsTextRow', 'TimeRow', 'CornerPickerRow'])
        assert.match(read(`Settings/${row}.qml`), /root\.narrow \? root\.markInset : root\.labelWidth/);
    // A switch keeps its own line beside the label; its description is the
    // shared hint line underneath, which wraps instead of eliding.
    assert.match(read('Settings/SwitchRow.qml'), /hint: description/);
    assert.match(read('Settings/SettingsRow.qml'),
        /height: lineHeight \+ \(hintLine\.visible \? hintLine\.height/);
    assert.match(read('Settings/ResponsiveActionRow.qml'), /Flow \{/);
    assert.match(read('Settings/SettingsPage.qml'), /while \(ancestor && ancestor !== contentRoot\)/);
    assert.match(read('Settings/SettingsRow.qml'), /Accessible.name: "Reset " \+ root.resetLabel/);
});

test('notification actions wrap and image captions retain independent contrast', () => {
    assert.match(read('Common/NotifActions.qml'), /Flow \{\s*width: root.width/);
    const wallpaper = read('Settings/WallpaperPage.qml');
    const caption = wallpaper.slice(wallpaper.indexOf('id: fileName'), wallpaper.indexOf('visible: cell.current'));
    assert.match(caption, /color: "#ffffff"/);
    assert.match(read('ShortcutsOverlay.qml'), /contentHeight: body.implicitHeight/);
    assert.match(read('ShortcutsOverlay.qml'), /columns: width < Theme.settingsNarrowWidth \? 1 : 2/);
});

test('accent ink remains readable without changing the chosen fill', () => {
    const helpers = require('../../roles/desktop/files/quickshell/Common/SettingsHelpers.js');
    for (const background of ['#201e1b', '#eeedf3', '#f7f5fb']) {
        for (const accent of ['#d1d581', '#9ecbeb', '#a992e0', '#79b88b', '#d3b47e', '#e8837a']) {
            const ink = helpers.ensureContrast(accent, background, 4.5);
            assert.ok(helpers.contrastRatio(ink, background) >= 4.5,
                `${accent} ink on ${background}`);
        }
    }
    assert.match(read('Common/Theme.qml'), /accentText: SettingsHelpers.ensureContrast\(\s*accent.toString\(\), copyReferenceBg.toString\(\), 4.5\)/);
    assert.match(read('Common/Theme.qml'), /accent: paletteActive \? Common.Palette.primary\s*: Settings.effectiveAccent/);
    assert.match(read('Settings/SettingsHint.qml'), /tone === "active" \? Theme\.accentText/);
});

test('native forms share field chrome and drawer tabs expose keyboard selection', () => {
    assert.match(read('Settings/SettingsTextRow.qml'), /SettingsField \{/);
    assert.match(read('Settings/PluginsPage.qml'), /SettingsField \{/);
    assert.doesNotMatch(read('Settings/PluginsPage.qml'), /Controls.TextField/);
    for (const surface of ['T3InboxPage', 'GitHubPopover'])
        assert.match(read(`Popovers/${surface}.qml`), /component GroupHeader: SectionLabel/);
    const tabs = read('Popovers/Drawer/DrawerTabs.qml');
    assert.match(tabs, /activeFocusOnTab: on/);
    assert.match(tabs, /Accessible.selected: on/);
    for (const key of ['Left', 'Right', 'Home', 'End'])
        assert.match(tabs, new RegExp(`Qt.Key_${key}`));
    assert.match(tabs, /Math.max\(0, usableWidth - restingWidth/);
});

test('widget editor keeps section cards visible and opens options in an embedded dialog', () => {
    const editor = read('Settings/ModulesPage.qml');
    assert.match(editor, /model: \["left", "center", "right"\]/);
    assert.match(editor, /WidgetPicker \{/);
    assert.match(editor, /WidgetPill \{/);
    assert.match(editor, /popupType: Controls.Popup.Item/);
    assert.match(editor, /function focusEntry/);
    assert.doesNotMatch(editor, /id: availablePanel|id: previewZone/);
    assert.match(read('Settings/WidgetPicker.qml'), /Editor.search\(root.entries, search.text, "available"\)/);
});
