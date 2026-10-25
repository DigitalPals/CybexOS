const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { shellDir, load } = require('./shell.cjs');
const L = load('LocaleNames.js');
const I18nHelpers = load('I18nHelpers.js');
const nl = require(path.join(shellDir, 'Common/i18n/nl.js'));

// The same composition as I18n.localeName().
function localeName(value, catalog) {
    const found = L.names(value);
    if (!found) return value;
    const tr = text => I18nHelpers.translate(catalog, text);
    return found.territory ? I18nHelpers.format(catalog, '%1 (%2)', [tr(found.language), tr(found.territory)])
        : tr(found.language);
}

test('locale values become readable names, in English and Dutch', () => {
    assert.equal(localeName('en_US.UTF-8', {}), 'English (United States)');
    assert.equal(localeName('en_US.UTF-8', nl.MESSAGES), 'Engels (Verenigde Staten)');
    assert.equal(localeName('nl_BE.UTF-8', nl.MESSAGES), 'Nederlands (België)');
    assert.equal(localeName('de', {}), 'German');
    assert.equal(localeName('sr_RS.UTF-8@latin', {}), 'Serbian (Serbia)');
    assert.equal(localeName('fr_XK.UTF-8', {}), 'French', 'an unknown territory is left out');
    for (const raw of ['C.UTF-8', 'POSIX', 'xx_YY.UTF-8', '', 'en-US'])
        assert.equal(localeName(raw, {}), raw, 'anything unknown keeps its raw value');
});

test('every installer language has a name, and the I18n singleton composes it the same way', () => {
    const installer = fs.readFileSync(path.join(shellDir, '../../installer/cybexos-installerd'), 'utf8');
    const locales = [...installer.matchAll(/\('([a-z]{2}_[A-Z]{2}\.UTF-8)', '/g)].map(match => match[1]);
    assert.ok(locales.length >= 14, locales);
    for (const value of locales) {
        const found = L.names(value);
        assert.ok(found && found.territory, value);
        assert.notEqual(localeName(value, nl.MESSAGES), localeName(value, {}), 'translated: ' + value);
    }
    const singleton = fs.readFileSync(path.join(shellDir, 'Common/I18n.qml'), 'utf8');
    assert.match(singleton, /function localeName\(value: string\): string \{[\s\S]*?LocaleNames\.names\(value\)[\s\S]*?root\.format\("%1 \(%2\)", \[root\.tr\(found\.language\), root\.tr\(found\.territory\)\]\)/);
    const hello = fs.readFileSync(path.join(shellDir, 'Welcome/HelloStep.qml'), 'utf8');
    assert.match(hello, /I18n\.localeName\(region\.locale\)/);
});
