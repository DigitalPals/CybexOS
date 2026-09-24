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
    assert.equal((appearance.match(/SettingsSubsection \{/g) || []).length, 2);
    assert.doesNotMatch(appearance, /SectionHeader \{/);
    for (const page of ['AppearancePage', 'BarLayoutGroups', 'DrawerPage', 'NotificationsPage',
            'PowerPage', 'RegionPage', 'TouchpadPage', 'ModulesPage', 'PluginsPage'])
        assert.match(read(`Settings/${page}.qml`), /spacing: Theme.settingsGroupSpacing/);
});

test('responsive controls and focus scrolling respect their content bounds', () => {
    const picker = read('Settings/PickerRow.qml');
    assert.match(picker, /wideHeight: Math.max\(Theme.panelRowHeight, pills.implicitHeight\) \+ rowPad \* 2/);
    // Every control ends on the page's right-hand edge and tells the row
    // where it begins, so labels take the room to its left (2026-09).
    for (const row of ['PickerRow', 'SliderRow', 'SettingsTextRow', 'TimeRow', 'CornerPickerRow',
            'SwitchRow', 'SelectRow'])
        assert.match(read(`Settings/${row}.qml`), /controlLeft:/, `${row} reports its control's left edge`);
    for (const row of ['PickerRow', 'TimeRow', 'CornerPickerRow', 'SelectRow'])
        assert.match(read(`Settings/${row}.qml`), /root\.narrow \? root\.markInset : root\.contentRight - width/);
    assert.match(read('Settings/SliderRow.qml'), /Math\.min\(root\.trackWidth,/,
        'a slider keeps a bounded track instead of stretching across the page');
    // A switch keeps its own line beside the label; its description is the
    // shared hint line underneath, which wraps instead of eliding.
    assert.match(read('Settings/SwitchRow.qml'), /hint: description/);
    assert.match(read('Settings/SettingsRow.qml'),
        /height: lineHeight \+ \(hintLine\.visible \? hintLine\.height/);
    assert.match(read('Settings/ResponsiveActionRow.qml'), /Flow \{/);
    assert.match(read('Settings/SettingsPage.qml'), /while \(ancestor && ancestor !== contentRoot/);
    assert.match(read('Settings/SettingsRow.qml'), /Accessible.name: "Reset " \+ root.resetLabel/);
});

test('notification actions wrap and image captions retain independent contrast', () => {
    assert.match(read('Common/NotifActions.qml'), /Flow \{\s*width: root.width/);
    const wallpaper = read('Settings/WallpaperPage.qml');
    const caption = wallpaper.slice(wallpaper.indexOf('id: fileName'), wallpaper.indexOf('visible: cell.current'));
    assert.match(caption, /color: "#ffffff"/);
    assert.match(read('ShortcutsOverlay.qml'), /contentHeight: body.implicitHeight/);
    const shortcuts = read('ShortcutsOverlay.qml');
    assert.match(shortcuts, /width: Math\.min\(Theme\.scaled\(1180\), root\.width - 96\)/,
        'the shortcut sheet uses the width of a wide screen');
    assert.match(shortcuts,
        /count: Math\.max\(1, Math\.min\(3,\s*Math\.floor\(\(width \+ spacing\) \/ \(minimumColumnWidth \+ spacing\)\)\)\)/,
        'columns follow the available width, one to three');
    assert.match(shortcuts, /width: shortcut\.stacked \? parent\.width\s*: Math\.min\(parent\.width, naturalWidth\)/,
        'stacked keys wrap inside the column instead of overflowing its left edge');
});

test('shortcut rows size from their column, not a parent that closing unsets', () => {
    // Closing the sheet clears the group model; each row is unparented
    // before its bindings are torn down, so `parent.width` threw once per row.
    const sheet = read('ShortcutsOverlay.qml');
    const row = sheet.slice(sheet.indexOf('id: shortcut\n'), sheet.indexOf('id: label'));
    assert.match(row, /width: rows\.width/);
    assert.doesNotMatch(row, /width: parent\.width/);
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

test('widget editor pins a bar preview over lanes and one tray, and opens options in a dialog', () => {
    const editor = read('Settings/ModulesPage.qml');
    assert.match(editor, /model: \["left", "center", "right"\]/);
    assert.match(editor, /WidgetPill \{/);
    assert.match(editor, /popupType: Controls.Popup.Item/);
    assert.match(editor, /function focusEntry/);
    assert.doesNotMatch(editor, /id: availablePanel|id: previewZone/);

    // The preview is pinned above the scrolling page, not scrolled with it,
    // and a widget in it opens the same options dialog as its pill.
    const header = editor.indexOf('id: header');
    const arrangement = editor.indexOf('id: arrangement');
    assert.ok(header > 0 && arrangement > header);
    assert.match(editor.slice(header, arrangement), /BarPreview \{[\s\S]*?onWidgetActivated: key => page\.openFromPreview\(key\)/);
    assert.match(editor, /function openFromPreview\(id\) \{\s*openSubPage\(id\);/);
    assert.match(editor, /id: arrangement\s+anchors\.top: header\.bottom/);
    assert.match(read('Settings/qmldir'), /^BarPreview BarPreview\.qml$/m);

    // Lanes are rows, not cards; adding happens from one tray, not a picker per lane.
    const lane = editor.slice(editor.indexOf('component ArrangementSection'), editor.indexOf('component Caption'));
    assert.match(lane, /component ArrangementSection: Item \{/);
    assert.doesNotMatch(lane, /Theme\.cardFill|border\.width/);
    assert.doesNotMatch(editor, /WidgetPicker/);
    assert.ok(!fs.existsSync(path.join(root, 'Settings/WidgetPicker.qml')));
    assert.match(editor, /title: "Add widgets"[\s\S]*?model: page\.availableEntries[\s\S]*?onAddRequested: page\.addFromTray\(modelData, index\)/);
    assert.match(editor, /function addFromTray\(entry, index, section\) \{[\s\S]*?setEnabled\(entry, true, false, section\);/,
        'the tray adds through the same membership path as everything else');
    assert.match(editor, /Widgets from plugins show up here too/);

    // Every pill shows its Move/Remove menu without a right-click.
    const pill = read('Settings/WidgetPill.qml');
    assert.match(pill, /SettingsAction \{\s*id: moreAction[\s\S]*?glyph: "more_horiz"[\s\S]*?onTriggered: root\.openMenu\(moreAction\)/);
    assert.match(pill, /event\.button === Qt\.RightButton\) menu\.popup\(\)/);
    assert.doesNotMatch(pill, /glyph: "settings"/, 'the chip body is the way into its options');
    assert.match(pill, /SettingsTooltip \{/);
    assert.doesNotMatch(pill, /Controls\.ToolTip\./);
});

test('the bar preview draws the live bar settings', () => {
    const preview = read('Settings/BarPreview.qml');
    for (const token of ['Settings.position', 'Theme.barHeight', 'Theme.barTopMargin', 'Theme.barSideMargin',
            'Theme.clusterRadius', 'Theme.barHug', 'Theme.barSurface', 'Theme.barIcon', 'Settings.autoHide'])
        assert.ok(preview.includes(token), `the preview ignores ${token}`);
    assert.equal((preview.match(/HugCorner \{/g) || []).length, 2, "Hug's two inverted corners");
    assert.match(preview, /BarGeometry\.exclusiveZone\(/, 'reserved space uses the bar\'s own geometry');
    for (const section of ['left', 'center', 'right'])
        assert.match(preview, new RegExp(`Editor\\.sectionEntries\\(root\\.entries, "${section}"\\)`));
    assert.match(preview, /onClicked: root\.widgetActivated\(widget\.modelData\.key\)/);
});
