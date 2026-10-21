# Notification refinements

## Shared settings contract (for schema integration)

All existing notification preferences keep their values. New properties in
`Common/Settings.qml` use the following defaults; normalize finite numeric
values by rounding and clamping, invalid types to defaults. No migration resets
existing DND, quiet hours, duration, appearance or source choices.

| Property | Type/default | Normalization |
| --- | --- | --- |
| `notifHistoryPersist` | bool `false` | strict boolean |
| `notifHistoryCount` | int `50` | 10–200 |
| `notifHistoryHours` | int `24` | 1–168 |
| `notifHistoryBytes` | int `262144` | 16384–1048576 |
| `notifDedupeSeconds` | int `10` | 0–60; zero disables |
| `notifBurstLimit` | int `5` | 1–20 admissions per source per rolling 10-second window |
| `notifPopupGroups` | int `3` | 1–5 |
| `notifPopupPerGroup` | int `3` | 1–5 |
| `notifFullscreen` | string `"away"` | `"away"` or `"show"`; invalid → `"away"` |

Source snoozes are session-scoped (including shell hot reload only when the
singleton survives); they never write source names to settings. Durations are
15 minutes, 1 hour and 8 hours, with explicit unsnooze controls in the center
and settings. They do not survive logout. DND and quiet-hour settings retain
their existing persistence and startup policy. Codes never bypass any quiet
policy; there is no implicit exception for critical senders either.

Persisted history is separate from settings and disabled by default. Disabling
it deletes the owned history file. Clear all clears memory and the file. The
count, age and byte bounds apply together. The runtime session retains at most
`notifHistoryCount` entries regardless of persistence.

New English keys requiring Dutch translations (all are passed through I18n):
`Notification history`, `Remember notification history`,
`Store private history across shell restarts and logins`, `Retention`,
`1 hour`, `24 hours`, `7 days`, `History limit`, `50 notifications`,
`100 notifications`, `200 notifications`, `Clear notification history`,
`Source snoozes`, `No sources snoozed`, `Unsnooze`, `Unsnooze all`,
`Snooze 15 minutes`, `Snooze 1 hour`, `Snooze 8 hours`,
`Copy verification code`, `Open link`, `Dismiss group`, `Expand group`,
`Collapse group`, `Repeated %1 times`, `Verification notification`,
`Content redacted`, `History storage unavailable`, `Fullscreen notifications`,
`Use another display or history`, `Show over fullscreen`, `Grouped popups`,
`Burst limit`, `Extra notifications collect in the center`,
`Send grouped preview`, `Send verification preview`.

## Provenance

Reference: Omarchy tag `v4.5.0-rc1`, commit
`03ff1eff3812933f7088484533784d2f63eaf19a`, reviewed from the pinned checkout
`/tmp/cybexos-desktop-20261021-upstream`. Read `docs/notifications.md`, the
notification plugin manifest, `Service.qml`, `Store.js`, `Detect.js`,
`Security.js`, `Delivery.js`, `Layout.js`, `Settings.js`, and the notification
test runner and logic fixtures before adaptation. The upstream engine uses
Quickshell NotificationServer/Io/Wayland/Hyprland, its own shell/Commons plugin
loader, theme and settings. CybexOS keeps its existing singleton, theme,
settings, actions and sole D-Bus owner rather than importing that plugin.

`NotifSmart.js` adapts the bounded keyword-near-code detector and narrow HTTP
URL grammar from upstream `Detect.js` and `Security.js`. Its embedded MIT
notice preserves Omarchy's copyright and the engine's Omapager attribution
(Neil Jagdish Patel, 2026). Other notification admission, grouping and private
storage code is implemented for CybexOS. No later moving-branch changes are
incorporated. Upstream executable hints, automatic click fallbacks, network
favicon fetching, live-popup restore and default code quiet bypass are not
used. No dependency version increase is required.

Implementation behavior and actual validation evidence are appended below.

## Using the controls

Hover a card, or Tab to it in the center, to reveal sender actions, verification
code copy, safe link offers and the three snooze durations. Source snoozes show
an end time and an Unsnooze button in both notification views and Settings →
Notifications. Unsnooze all is available there too. Snoozed, DND and quiet-hour
arrivals stay in the center; they never become a delayed popup queue.

Exact repeated messages show “Repeated N times”. The window is measured from
the first occurrence, so a continuous repeat cannot keep extending it. Source,
full bounded summary/body, urgency, icon/image content and action identity/labels
must match. Quickshell's transient numeric image handles are compared using
bounded native pixel fingerprints. Different handles containing identical
pixels can merge; different pixels remain separate. A missing module, invalid
handle, unavailable provider or oversized image disables deduplication for that
image. Long inputs that exceed admission bounds and progress-hinted messages
never deduplicate. A D-Bus replacement updates its existing slot and restarts
its displayed lifetime, without increasing the occurrence count. Obsolete
senders cannot close or update a slot transferred to a later duplicate.

The display-only `webOrigin` hostname is separate from the bounded
`webSourceIdentity` used for deduplication, snoozes, burst limits and groups.
Qualified HTTP(S) senders use canonical lowercase scheme/host and effective
port: `https://chat.example` and `https://chat.example:443` both identify
`https://chat.example:443`; `https://chat.example:8443` and
`http://chat.example:80` are separate sources. IPv4/IPv6 forms are validated,
IPv6 spelling is canonicalized, and a DNS root dot stays distinct in source
identity even though the display hostname omits it. Invalid ports, credentials,
controls, escaped authorities and unsafe/ambiguous numeric hosts are rejected.

A supplied bare hostname has no known scheme. Its identity is
`unqualified:chat.example`, separate from every qualified URL origin; a supplied
port is retained without inventing a scheme. An explicit origin hint keeps
precedence over a body anchor. If only an actual HTTP(S) origin anchor or legacy
origin prefix supplies the source, its supplied scheme and port are retained.
Snooze controls show the qualified authority (or bare host/port) so two ports
remain distinguishable in the unsnooze list. Existing friendly names, brands
and icon consumers continue to use `webOrigin`.

History's additive `webSourceIdentity` field is at most 320 characters and
contains only an origin authority, never path, query, fragment, credentials or
an executable link. Both admission and the storage helper validate it. Existing
v1 history with only a hostname migrates to the unqualified namespace; the lost
scheme/port cannot be reconstructed. Invalid or mismatched stored identity
also falls back conservatively to its validated unqualified hostname. Code
redaction includes this field in detection and clears it along with all other
source/display fields. Source snoozes remain session-only; no preference or
shared-schema migration is required.

Popups group by exact website origin or the native desktop-entry/app-name pair;
friendly brand labels do not combine unrelated websites. There are at most
three groups with three cards each by default, with at most five new popup
admissions per source in a rolling ten-second window. Excess arrivals remain in
the center. The front card and group count show while collapsed; hover or
Expand group reveals the members. Each card has its own dismiss control, and
Dismiss group clears the currently displayed members. Hover and keyboard focus
pause all members. New distinct cards from a held group collect in the center
rather than rearranging the controls beneath the pointer. No held cards replay
when the pointer leaves. All motion follows reduced-motion settings.

A source deck stays on the display chosen at admission. New decks use the
focused display. The default fullscreen policy routes to another available
display, or directly to history when all displays are fullscreen. Changing
focus does not drag a deck between displays; disconnects and fullscreen changes
reconcile existing decks. Popup surfaces use OnDemand keyboard focus, and their
height is bounded to the screen with scrolling for expanded content.

Code detection requires a nearby English or Dutch verification keyword and a
numeric or mixed uppercase token. It deliberately excludes product names such
as “VS Code”, ordinary years and unlabelled order numbers. Copy is explicit,
uses `wl-copy --sensitive` with separate arguments, and clears the clipboard
after 60 seconds only if it still contains that code. The clipboard manager
must honor the sensitive hint to avoid retaining it. Link offers show their
actual host, expose the full destination to accessibility, and only open on
explicit activation through Qt. HTTP(S) URLs must pass a narrow ASCII hostname,
port and escape grammar; executable schemes, credentials, control/bidi
characters, numeric-host ambiguities and nested escapes fail closed. No
notification content is interpolated into a command shell. Sender text always
renders as plain text. Attached images are limited to safe local files and
Quickshell in-process images; notification arrivals trigger no icon subprocess
or network favicon request.

## Storage and integration

When enabled, history lives at
`$XDG_STATE_HOME/cybexos/notifications/history.json` (fallback
`~/.local/state/cybexos/notifications/history.json`). The directory is 0700 and
the file 0600. One long-lived Python standard-library helper handles JSON-lines
requests. Changes coalesce behind a 250 ms timer, with at most one snapshot in
flight and one dirty flag, so a slow disk cannot accumulate notification
snapshots in the process pipe. Reads have a hard 1 MiB cap; requests have an
8 MiB framing cap; count, age and actual encoded byte limits apply together.
Writes use a private exclusive temporary file, fsync and same-directory atomic
replacement. Owned directory components and file reads do not follow symlinks;
clear removes only the owned history filename. Invalid, corrupt, wrong-version,
oversized or nonprivate files recover as empty and are repaired atomically.
Storage failure leaves session history available and shows a settings hint.

Only inert, whitelisted text and count/time/urgency fields reach disk. A
code-bearing entry becomes a generic verification placeholder: source labels,
origin, desktop entry, raw/displayed text and every alternate/derived string are
discarded, including any identity that repeats the code. The storage helper
also checks alternate/nested input before whitelisting. It never stores images,
hints, links, executable argv, source fingerprints, D-Bus IDs or action handles.
Restored rows have no live, code or link actions and never create popups. New
arrivals received during the startup read take precedence. Obsolete read replies
after Clear all or a preference change are ignored. Disabling persistence
removes the file without creating storage when it never existed.

Parent integration owns the Settings properties/schema/translations/package
parity and `Common/qmldir`. Register **ordinary types**, not singletons:
`NotifButton NotifButton.qml` and `NotifSnoozes NotifSnoozes.qml`. The existing
recursive shell payload must include the two new JS modules and
`scripts/notification-history.py`; Python 3 and wl-clipboard are existing
runtime dependencies. The helper is invoked through Python, so it does not
need a separate service or executable installation target. There remains one
existing `Notifs.server` NotificationServer owner.

The Quickshell 0.2.1 source API was additionally checked at the pinned release:
`src/wayland/toplevel_management/qml.hpp` provides fullscreen state and the
screens where a toplevel is visible, and `src/services/notifications/notification.hpp`
provides replacement property signals and action lifecycle. The installed
Fedora Quickshell `0.2.1^git20260209.dacfa9d-5.fc44` removes `image-data`,
`image_data` and `icon_data` from exposed hints in `notification.cpp:152–154`.
Those hints therefore cannot supply stable attached-image identity. Its public
image provider exposes existing images through `QQuickImageProvider::Image`.
No newer API or dependency upgrade is assumed. `NotifSmart.js` also adapts
`Security.js`'s local-image-path validation under its embedded MIT notice.

## Native attached-image identity and installation

`roles/desktop/files/notification-images/` is local MIT-licensed repository
source, with no external source dependency or Quickshell SDK. The
`CybexOS.Images 1.0` module uses the current `QQmlEngine`'s public
`imageProvider("qsimage")` API and a checked `QQuickImageProvider` cast.
Its only accepted input is the exact form
`image://qsimage/<1–20 decimal digits>/<1–20 decimal digits>`. It never opens
files, URLs, other providers or commands. Image/Pixmap providers are supported;
missing, null and unsupported providers return a precise bounded error ID.

Before canonicalization, both dimensions are capped at 4096, canonical storage
and original QImage storage at 16 MiB. SHA-256 covers a domain separator,
big-endian width/height and RGBA8888 pixels, excluding row padding. Pixel data
and image handles are not retained by the module. Runtime fingerprints are
excluded from persisted history along with all images. No subprocess runs
when a notification arrives. `NotifImageFingerprint.qml` loads synchronously
through a fixed-URL lazy Loader only for valid numeric image handles; it must
stay absent from Common/qmldir. A source preview without the module continues
to receive notifications, with dynamic-image dedupe disabled and a diagnostic
such as `native-module-unavailable` or `provider-unavailable`.

Both installation paths use the identical `notification-images/build.py`
CMake recipe and native CTest. The checkout role is
`roles/desktop/tasks/notification-images.yml`; the image builder runs
`python3 image/notification_images.py` before `image/package`, which calls
`prepare_notification_images(ROOT, build, payload)`. The recipe uses standard
Fedora CMake, C++ compiler, pkgconf, `qt6-qtbase-devel` and
`qt6-qtdeclarative-devel`; public Qt6 Qml/Quick APIs need no compositor ABI pin.
Installation is `/usr/lib64/qt6/qml/CybexOS/Images`. Source checksums, Qt versions
and installed artifact checksums are recorded in
`/usr/share/cybexos/notification-images/build.json`. A changed recipe, Qt version
or installed artifact triggers rebuilding; valid unchanged artifacts skip the
build. The image packager rejects missing/changed sources, unexpected artifacts,
altered binaries or inconsistent build manifests. The compiler's temporary
directory is removed even on failure.

Parent integration: import `notification-images.yml` from desktop main.yml;
import/call `prepare_notification_images` adjacent to titlebars in image/package;
run image/notification_images.py before desktop-payload and copy
notification-images.json into delivered artifacts. The RPM needs
`qt6-qtbase-devel qt6-qtdeclarative-devel`, the module under
`/usr/lib64/qt6/qml/CybexOS/`, and its license directory under `%license`.
The existing `/usr/share/cybexos/` file entry covers the recipe and manifest.
Uninstall removes only Images/, the recipe directory and its license directory.
Add `notification-images` to tests/run's Python fixtures. No new schema, setting
or translated user-facing string is introduced by image identity.

## Validation evidence and limits

Starting revision: `3b310d106255558ca213c955ef37ee314e8681f2`; implementation is
an uncommitted shared-worktree diff as requested. Parent records the final
integrated tested commit. This agent did not install the live desktop, start
Quickshell, launch a host container/VM, commit, reset or stash work.

Passed: 114 Node tests across notification-policy, notification-history,
notif-helpers, notif-card, notifications-widget, notification-icon,
accessibility-contracts, indicators, settings-layout, typography, idle-timeouts,
view-churn, brand-icons and format test files. The new policy fixtures execute
actual service functions/subscriptions against fake signals, covering
replacement versus duplicate ownership, progress/source separation, quiet
expiry, burst/output routing, stale actions and restore redaction. The history
fixtures run the actual persistent Python process on disposable directories,
cover restart, corruption, permissions, symlinks, alternate-field redaction,
retention, encoded byte caps and clear/disable. Temporary test directories are
removed by each test. `git diff --check` passes.

The parent's integrated QML lint reported an unused Quickshell
import in NotificationsPage; it has been removed. Parent source-gate findings
for brand allow-list validation and open-coded duration constants were fixed
without weakening their contracts, and the adjacent tests pass.

The independent review P2 image-identity fix was compiled and tested in the
parent's existing Fedora 44 container `6d814bcad464` using GCC 16.2.1 and Qt
6.11.2. Native CTest passes (9 behavioral cases plus init/cleanup: 11 QtTest
passes): same/different pixel content under different handles, dimensions,
canonical format equality, row padding, URI rejection without provider fetch,
missing/null/unsupported providers, dimensions/original-storage bounds,
Pixmap and a real QML singleton using its engine's fake public provider.
Five Python artifact-admission/parity cases and 27 focused Node cases pass.
The unchanged second installer invocation reports UNCHANGED. Fedora's
tests/qml-lint passes all 355 QML files plus four harnesses with the native
module installed. Ruff, yamllint, ansible-lint and git diff --check pass.
These native tests establish the public Qt contract; the provider is a fake,
so they do not establish actual Quickshell/D-Bus image behavior.

Independent review R2 found and fixed a further source collision: display-host
normalization had collapsed origins with different schemes/ports. The focused
fixtures now cover effective/default ports, scheme/nondefault-port/root-dot
separation, ambiguous hostname sources, canonical IPv4/IPv6, hostile origin
input, per-origin dedupe/groups/snoozes, additive v1 history migration and
identity-only code redaction. The notification/adjacent suite passes 130 Node
checks; full Fedora QML lint and helper Ruff pass. Parent reports actual D-Bus
image/replacement/snooze/action and private-history restart/redaction checks
passed before this R2 fix; the new origin routing needs its integrated runtime
rerun. This agent made no VM changes for R2.

QML engine loading, real D-Bus replacement/action execution, pointer/keyboard
and assistive-technology behavior, hover countdowns, fullscreen routing,
multi-monitor/hotplug/scaling and shell/login restart are **pending parent VM
qualification**, not established by these fixtures. Settings now provides Send
test, Send grouped preview and Send verification preview using the same
in-shell admission path. The parent must run source/image installation parity
and runtime qualification against its integrated revision. The installed native
module remains in the parent's existing container for final source lint.
A 92,160-byte matching VM module/recipe/license payload is retained at
`/var/lib/agent-resources/leases/29c5e2febb054008b06ff08cd794e589/workspace/notification-images-native-module.tar`
for the parent's isolated VM qualification, SHA-256
`9dc18af643be70b4fe42211c667aeb4e9749f5a1cab856f027a75e5fa3fef458`.
Its lease owns cleanup. No host services or live desktop were changed.
