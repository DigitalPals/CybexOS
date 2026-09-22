# Shared shell typography

`Common/Typography.js` owns both font sizes and their intended use. Native
views use `Theme.typography.<role>`, Omarchy-compatible plugins use
`Style.font.<role>`, and native API 1 widgets use `api.theme.typography.<role>`.
All three resolve through the same library. Existing `Theme.fontBody` and
similar aliases, `Style.font.body`, and `api.theme.fontSize` remain compatible.
New native views must use the named roles below, not the old aliases.

## Comparison with Omarchy

Audited on 2026-09-21 against Omarchy commit
[`961ec7f39fd0d70c7d2944c5b80585a86713693d`](https://github.com/omacom/omarchy/tree/961ec7f39fd0d70c7d2944c5b80585a86713693d).
The reference is its current Quickshell implementation, not the older Waybar
stylesheet. This project already selected a 12px base, but its views heavily
used smaller tokens. In the pre-update installed native QML, 205 direct text
size bindings selected `fontCaption` and 142 selected `fontMicro` (both 10px),
against only 66 selecting `fontBody` (12px). These are source-binding counts,
not a count of simultaneously visible labels.

The audit covered the shared Style and UI components, bar widgets, audio,
network, power, weather and clock panels, notifications and OSDs. Omarchy
does not have an exact counterpart to our settings workspace or T3/Hermes
views; those use the same control/list/detail rules as its shared UI.

| Purpose | Omarchy reference at 12px base | Previous native usage | Shared role / new usage |
| --- | --- | --- | --- |
| Bar text, clock/date, weather | `WidgetButton`: body 12 | Clock 12; most other readings 10 | `bar`: 12 |
| Buttons, inputs, dropdown values | `Button`, `TextField`, `Dropdown`: body 12 | Settings controls 12; other actions/inputs often 10–11 | `control`: 12 |
| Navigation, primary device/list labels | Audio device labels and menu controls: body 12 | Many drawer labels and settings navigation 11 | `navigation`, `primary`: 12 |
| Descriptions, hints, secondary details | Weather descriptions, power telemetry: body-small 11 | Often caption 10 | `secondary`: 11 |
| Tooltips | `PanelToolTip`: body-small 11 | 11 | `tooltip`: 11 |
| Section labels, compact timestamps/readouts | `PanelSectionHeader`, audio percentages: caption 10 | 10, also used indiscriminately for primary text | `section`, `metadata`: 10 |
| Panel titles | `PanelHero` and audio/power titles: title 14 | 14–16; some local arithmetic | `title`: 14 |
| Notification summary/body | `NotificationCard`: title 14 | Toast 10, history 11 | `notification`: 14 in both |
| OSD message/value | `Osd` message metrics: title 14 | 10 | `osd`: 14 |
| Large date/time hero | Clock panel date: explicit 52 | Day-sheet clock: local 40 | `clock`: shared 52px reference |

Sources at the audited revision:
[scale](https://github.com/omacom/omarchy/blob/961ec7f39fd0d70c7d2944c5b80585a86713693d/shell/Commons/Style.qml),
[bar text](https://github.com/omacom/omarchy/blob/961ec7f39fd0d70c7d2944c5b80585a86713693d/shell/Ui/WidgetButton.qml),
[controls](https://github.com/omacom/omarchy/blob/961ec7f39fd0d70c7d2944c5b80585a86713693d/shell/Ui/Dropdown.qml),
[audio](https://github.com/omacom/omarchy/blob/961ec7f39fd0d70c7d2944c5b80585a86713693d/shell/plugins/panels/audio/Panel.qml),
[notifications](https://github.com/omacom/omarchy/blob/961ec7f39fd0d70c7d2944c5b80585a86713693d/shell/plugins/notifications/components/NotificationCard.qml),
[OSD](https://github.com/omacom/omarchy/blob/961ec7f39fd0d70c7d2944c5b80585a86713693d/shell/plugins/osd/Osd.qml),
[clock hero](https://github.com/omacom/omarchy/blob/961ec7f39fd0d70c7d2944c5b80585a86713693d/shell/plugins/panels/clock/Panel.qml).

The core scale is caption 10, body-small 11, body 12, subtitle 13, title 14,
heading 16, display 24 and display-large 28. The `clock` role explicitly
centralizes Omarchy's exceptional 52px date treatment for our date/time hero;
it is not a general heading. Icons keep their separate optical sizes.
Omarchy uses Liberation Sans for notifications; we retain the user's shared
shell font selection there while matching the message sizes. Thus this is a
shared size/usage contract, not a claim of identical layout or rendering.

## Implementation contract

`ShellMetrics.calculate()` combines base size, UI scale and accessibility
scale once. `Typography.resolve()` applies Omarchy's multipliers and rounds
once per token. Density affects spacing, not font size; Qt applies monitor
scaling. Native and plugin adapters no longer maintain independent type
scales. At default plugin settings their role values are identical, including
at larger accessibility sizes.

Plugin scale and explicit `[font]` overrides remain intentional exceptions.
Overrides resolve before usage roles: a plugin body override changes its
controls, navigation and bar consistently. Icon-small and icon retain
Omarchy's fallback to body-small and title overrides. Invalid overrides fall
back safely; positive values have a 1px floor.

```qml
Text {
    text: device.name
    font.family: Theme.fontMenu
    font.pixelSize: Theme.typography.primary
}
```

For plugin code, the equivalent is `Style.font.family` and
`Style.font.primary`. Use `control` for labels, entered text and placeholders
belonging to a control. Use `secondary` for descriptions, not `metadata` just
because the available row is short. Reserve `section` for group labels and
`metadata` for compact timestamps, badges and supplementary readouts. Allow
wrapping, scrolling or elision when space is constrained; do not invent a
local smaller size. New exceptional sizes need a documented shared token.

The launcher deliberately uses `heading` (16px at the default base) for its
search query and primary result labels, matching Omarchy v4.0.4's menu.
The query is regular weight and result labels are medium weight. Provider tabs
use `title` (14px) at medium weight with 16px icons. This prominent search field
is an exception to the ordinary `control` input role and still follows the
shared accessibility scale.

## Verification

`tests/quickshell/typography-scale.test.cjs` checks reference values, usage
roles, native/plugin adapter wiring, the accessibility/density matrix, plugin
overrides and icon fallbacks. Source checks reject pixel literals, point
sizes, local text-size arithmetic and old native size aliases. Additional
checks protect bar text, navigation, editable controls and notifications.
Two existing optical icon expressions are explicitly exempted; they contain
no copy. `typography.test.cjs` also checks shared control roles and contrast.

The managed-shell `shell debugPluginTheme` IPC exposes `nativeTypography`
and `pluginTypography` for runtime equality checks. Live tests must use
`tests/lib/quickshell-live` and inspect settings, drawer and plugin surfaces
at the default size and an enlarged size, including wrapping and clipping.

Validated on 2026-09-21: all 751 unit tests and the repository gate passed.
Managed-service checks confirmed equal native/plugin role maps for all nine
text-accessibility/density combinations (effective bases 12, 14 and 16px).
Settings, audio and Model Usage were inspected at default and enlarged sizes;
the 12-hour date/time hero, notification preview and OSD were also inspected.
Temporary preference changes were restored byte-for-byte. The managed service
remained the sole Quickshell process and its invocation journal was clean.
The isolated full-shell QML lifecycle test was skipped because the managed
shell was active; both connected outputs use 2× scale, so fractional monitor
scaling was not checked visually.
