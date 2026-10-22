# Shell translations

The menubar, launcher, Settings, notifications and every other Quickshell
surface show their own text in the session's language. NerdOS ships English
and Dutch. There is no separate language setting: **Settings → Region &
formats → System language** sets the language every application uses after
the next login, and the shell follows the same rule. Text without a
translation stays English.

The language comes from the first of `LC_ALL`, `LC_MESSAGES` and `LANG` that
names one (`C` and `POSIX` name none). An unsupported language falls back to
English, as gettext does. `NERDOS_LANG=nl` overrides all three for tests and
screenshots.

## How it works

`Common/I18n.qml` is a singleton with two functions:

```qml
text: I18n.tr("Show dock")
text: I18n.format("Switch output to %1", [sinkName])
```

Catalogs (`Common/i18n/<language>.js`) are keyed by the English text exactly
as it is displayed. Any string can therefore be translated where it is shown,
whoever composed it: views translate labels that JS modules supply
(`SettingsSearchData.js`, the launcher's actions and tabs, the shortcut
sheet's groups) at display time. `I18n.format` fills `%1`…`%9` after
translation, so a translation may reorder them. Write whole sentences: a
sentence assembled from pieces cannot be translated well.

Names the logic compares (an `IpSettings` title, a model `value`) and product
or technical names stay untranslated. Mark such a literal with a trailing
`// i18n: untranslated` comment.

## Adding or changing text

`tests/quickshell/i18n.test.cjs` fails when a user-visible QML literal is not
wrapped, when a translated string has no Dutch entry, or when an entry is no
longer used. The key list comes from `tests/quickshell/i18n-keys.cjs`.

```bash
scripts/i18n-catalog missing nl > /tmp/missing.json   # English strings without Dutch
# translate them into a JSON object {"English": "Nederlands", …}, then:
scripts/i18n-catalog merge nl /tmp/translations.json  # sorted; unused entries dropped
scripts/i18n-catalog check nl                         # what the unit test checks
```

The catalog is shell source, so both installation paths receive it with the
rest of the Quickshell tree. The vendored Model Usage widget keeps its
upstream English text.
