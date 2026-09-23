# Quickshell settings

Use this guide only for values persisted in
`~/.config/cybexos/shell.json`. Personal widget packages and their
separate preferences use [the user widget API](user-widgets.md).

## Inspect the active schema

Do not assume a schema version or copy defaults from another release. Read:

```text
~/.local/share/cybexos/current/roles/desktop/files/quickshell/Common/SettingsHelpers.js
~/.local/share/cybexos/current/roles/desktop/files/quickshell/Common/Settings.qml
```

`SettingsHelpers.js` is authoritative for `VERSION`, `defaults()`, accepted
enums and ranges, module IDs, composite normalization, and migrations.
`Settings.qml` identifies the persisted properties and the live watcher. It can
be loaded with Node because it exports its pure helpers:

```bash
node -e 'const s=require(process.argv[1]); console.log(JSON.stringify({version:s.VERSION,defaults:s.defaults(),modules:s.MODULE_IDS},null,2))' \
  "$HOME/.local/share/cybexos/current/roles/desktop/files/quickshell/Common/SettingsHelpers.js"
```

The stable top-level setting families are:

- Wallpaper: `wall`, `wallDir`, and `shuffle`.
- Appearance: theme, glass, contrast, motion, text scale, density, bar color,
  font, accent, and palette fields.
- Bar: `position`, `barStyle`, `gap`, `barHeight`, `barRadius`, `autoHide`, and
  `exclusive`.
- System behavior: clock format, temperature unit, night-light warmth, OSD
  edge, polling cap, touchpad scroll factor, night light, and idle inhibition.
- Notifications: DND, quiet hours, duration, position, density, icons,
  progress, and body-line limit.
- Composite layout: `drawerTabs`, `drawerOverview`, `drawerHover`,
  `drawerWidth`, `mods`, and `modOpts`.

Always consult the active `merge()` and option validators for exact accepted
values. Arrays such as `mods` and `drawerTabs` are complete ordered structures,
not partial patches. Do not set or lower the `v` field manually.

## Merge safely

1. If a live shell will be checked, first locate the applicable checkout (the
   active release is sufficient for diagnostics), source
   `tests/lib/quickshell-live`, and call `qs_live_begin`. Arrange cleanup so
   `qs_live_end` runs even after failure or interruption.
2. Read the current file. If it exists, require a regular, valid JSON object;
   stop on a symlink, non-regular file, malformed JSON, or read failure.
3. Put only the requested keys in a JSON object patch. Preserve arrays in full.
4. Create an exact, timestamped `cp -a` backup of the original before any
   replacement. If the backup fails, do not edit the file.
5. Build a candidate in the same directory with `jq -s '.[0] * .[1]'`, using
   the existing object as the left input and the requested patch as the right
   input. This recursively merges objects, replaces requested arrays, and
   preserves every existing key—including keys unknown to the active schema.
6. Require `jq -e 'type == "object"'` to accept the candidate. Then load the
   candidate through the active `SettingsHelpers.merge()` and confirm that
   every requested key retains the requested normalized value. Reject values
   that the schema clamps, replaces, or drops instead of silently accepting a
   different result.
7. Preserve the original mode (or use `0600` for a new file), then atomically
   replace it with `mv -T` from the same directory. Never stream partial JSON
   into the live path.

For the normalization check, a recursive containment assertion keeps unknown
pre-existing keys out of the decision while rejecting unsupported requested
keys:

```javascript
const fs = require("fs");
const schema = require(process.argv[2]);
const candidate = JSON.parse(fs.readFileSync(process.argv[3], "utf8"));
const requested = JSON.parse(fs.readFileSync(process.argv[4], "utf8"));
function contains(actual, expected) {
  if (expected && typeof expected === "object" && !Array.isArray(expected))
    return Object.keys(expected).every(key => key in actual && contains(actual[key], expected[key]));
  return JSON.stringify(actual) === JSON.stringify(expected);
}
if (!contains(schema.merge(candidate), requested)) process.exit(1);
```

Run it with `node - <schema> <candidate> <patch>`; in that form the first path
is `process.argv[2]`.

## Verify live application

The file watcher normally applies a valid external edit without restarting the
service. Verify the requested effect through an observable appropriate to the
setting, then confirm settings IPC responds with
`qs_live_wait_ipc "$QS_LIVE_TIMEOUT" settings close`. Finish with
`qs_live_end`; it requires `quickshell.service` to be active, its `MainPID` to
be the sole `qs` PID, and the current service invocation to be free of QML
errors.

Do not claim that a file comparison alone proves live application. If there is
no machine-readable observable, ask the user to confirm the visible result. If
the live check fails, atomically restore the exact backup, restart only
`quickshell.service`, and repeat `qs_live_begin` and `qs_live_end`. Never use
`pkill qs`.
