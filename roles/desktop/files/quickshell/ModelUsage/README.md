# Model Usage (built in)

This directory is the [Model Usage](https://github.com/DigitalPals/omarchy-modelusage)
Omarchy plugin, vendored as the shell's built-in Model Usage widget.

Commit: `8266a07495674d2d425f6d76b67833872a69d466` (version 1.1.1)

Everything here except this README is upstream's, unchanged: the QML and
JavaScript, `assets/`, `scripts/`, `LICENSE` and `THIRD_PARTY_NOTICES.md`. The
manifest, documentation, keeper deployment and CI are not copied. The unit
tests and fixtures live in `tests/model-usage/`, with the manifest as test data.

How the shell hosts it:

- `Bar/Modules/ModelUsage.qml` is the `modelusage` bar module. It gives
  `Panel.qml` the Omarchy `bar` facade that installed plugins receive
  (`Common/OmarchyBarApi.qml`). The panel keeps its `qs.Ui` and `qs.Commons`
  imports, which resolve to the shell's own Omarchy compatibility types.
- The panel's settings live in `shell.json` as `modOpts.modelusage`.
  `Common/SettingsHelpers.js` mirrors the manifest's defaults and bounds, and
  the panel saves through the facade's `updateEntryInline`.
- The scripts keep their upstream state and credential paths
  (`~/.local/state/omarchy/model-usage`, `~/.config/omarchy/...`), so an
  installed copy of the plugin and the built-in share them.
- `scripts/user-plugins.py` refuses to load the `digitalpals.model-usage`
  package, so an installed copy never draws a second widget.

To update, run `scripts/sync-model-usage <commit>` from the repository root,
review the diff, and run `./tests/run`. If the manifest's settings changed,
update `modelusage` in `Common/SettingsHelpers.js` to match.
