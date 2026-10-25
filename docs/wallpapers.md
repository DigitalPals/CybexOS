# Wallpapers

Open **Settings → Wallpaper** or the welcome guide's wallpaper step. The same
picker offers **Cybex OS collection**, **Wallhaven** and **My pictures**.
Selecting a tile previews it. **Use this wallpaper** applies the selection.
Arrow keys move around the grid, Enter selects, Tab reaches the filters and
preview actions, and Escape returns to the containing window.

Tiles show the image's size, or its name where the size is not known; a
badge that does not fit a small tile is left out rather than cut short. The
collection's images are named as titles (*Moon Mountains*); your own pictures
are named after their files, with dashes and underscores read as spaces. File
names never change.

The collection contains seven original procedural landscapes under the
repository's MIT licence; `assets/PROVENANCE.json` records their origin. A
fresh desktop shows `moon-mountains.png` without saving a wallpaper preference
or deriving a new colour palette. The overview, bar preview and lock screen
use that same default. The fixed theme remains active until you choose an
image and enable wallpaper colours.

Applying a collection image copies it into the configured wallpaper folder
(default `~/Pictures/Wallpapers`) with a `cybexos-` prefix. Existing files are
never overwritten: a conflicting name gets a content-derived suffix. The
copy then behaves like any other library image, including rotation and
Matugen colours. In Settings, **Rotation and folder** reveals the existing
shuffle schedule and folder chooser. **Shuffle now** changes the current
image immediately. My pictures lists supported JPEG, PNG and WebP files in
that folder; it does not scan unrelated picture directories.

## Wallhaven

The picker always requests safe-for-work images and rejects results not
marked SFW. It offers topic chips, sort/category/display-size filters, the
29 search colours documented by Wallhaven, and **More like this**. The colours
sit behind one compact **Any colour** control beside the other filters; it
opens a grid of swatches (arrow keys move, Enter picks, Escape closes). The
four filters share one row when their labels fit and form two rows otherwise. The last
option searches similar tags with `like:ID`. SFW classification is provided
by Wallhaven, rather than a guarantee about the image's content.

Opening the Wallhaven tab in Settings loads one listing. Searches run only
when submitted or a filter is chosen; **Show more** loads another page.
Scrolling and typing alone do not issue requests. The welcome guide can
request its first listing automatically when NetworkManager reports an
unmetered connection. Metered, guessed-metered and unknown connections show
**Load wallpapers from Wallhaven?** until the user chooses to load them.
The metering check reads `GENERAL.TYPE`, `GENERAL.STATE` and `GENERAL.METERED` locally; it
does not contact an Internet service.

Searches and selection details share a sliding budget of at most 45 API
requests per minute, including cancelled attempts. The picker reads the
server's rate-limit headers and pauses for at least a minute when two or
fewer requests remain or it receives HTTP 429, respecting longer Retry-After
values. A paused state is shown in the view. Retry after the pause; requests
are not queued or retried automatically.

A selection fetches `/api/v1/w/ID` once and keeps its validated details in
memory for the shell session. The preview uses a large thumbnail until the
full image has been saved. It shows size, resolution, display fit, colour
swatches, uploader, SFW tags and the source link when available. Image
swatches also come with listings and do not need a detail request. Attribution
strings are bounded and displayed as plain text; navigation links accept only
HTTP(S). Image and download URLs must match Wallhaven's known hosts and paths.

Full Wallhaven images are never bundled or downloaded in advance. **Use this
wallpaper** explicitly downloads into your own wallpaper folder, then applies
the file. Only one download runs at a time; choosing another image to apply
cancels the older download and the latest choice wins. Errors and progress
appear in the preview, with progress also on the tile. The uploader and source
help identify the creator; Wallhaven's listing does not grant a reuse licence.
Check the source before distributing or otherwise reusing an image.

## Embedding the picker

Import `desktop/quickshell/Settings` and instantiate `WallpaperPicker` with
an explicit width and height (or `anchors.fill: parent`). It has no dependency
on a `SettingsPage` ancestor. Its implicit size is **740 × 430** logical pixels;
allow at least **600 × 400**, and preferably **740 × 430**, for the online
filters and three-column gallery. Large text may wrap filters and metadata;
the preview scrolls while the primary action remains visible, and reads
**Apply** when **Use this wallpaper** would not fit.

```qml
import "../Settings" as SettingsUi

SettingsUi.WallpaperPicker {
    anchors.fill: parent
    embedded: true
    automaticOnlineLoad: true
    onApplied: fileName => welcomeStep.wallpaperApplied(fileName)
    onEscapeRequested: welcomeWindow.finishLater()
}
```

Public properties and signals:

- `embedded: bool = false`: embedding hint; defaults `compact` to its value.
- `compact: bool = embedded`: uses a 180 px preview instead of 200 px.
- `previewWidth: real = compact ? 180 : 200`: override the preview lane; it is
  capped at 36% of the picker width.
- `tab: string = "collection"`: `collection`, `online` or `library`.
  Settings synchronizes it with `OnlineWallpapers.view`; the welcome step
  can keep its own tab state.
- `automaticOnlineLoad: bool = false`: gate the initial online listing on
  `OnlineWallpapers.autoLoadAllowed()`. Set **true in the welcome guide**.
  An unknown answer waits for the local probe; metered/unknown users can
  still load explicitly. This never automatically selects or applies an image.
- `selected: var` (read-only): current local item or
  `OnlineWallpapers.selected`; null when nothing is selected.
- `applied(string fileName)`: emitted after a local selection, bundled import
  or successful online download has been applied. `fileName` is the basename
  persisted as `Settings.wall`, inside `Settings.wallDir`.
- `escapeRequested()`: the containing window decides how to handle Escape.

`WallpaperGrid` is the shared preview-only grid (`items`, `selectedKey`,
`online`, `selected(item)`). `WallpaperPreviewPanel` accepts `item`, `details`,
`online`, `busy`, `progress`, `error`; it emits `useRequested()` and
`moreLikeRequested()`. Local rows use `{path, fileName, label, width, height,
size, colors}`; online rows use the validated `WallhavenHelpers.parseResults`
shape. Do not feed arbitrary remote image URLs into these components.

`OnlineWallpapers.select(id)` accepts a listed, validated ID without applying
it and exposes `selected`, `details`, `detailsBusy` and `detailsError`.
`autoLoadAllowed()` returns true only for a known unmetered connection;
`meteredKnown`, `metered` and `refreshMetered()` expose the cheap local probe.
The old `popular`, `results` and `pick` IPC calls were removed. The supported
wallpaper IPC remains `browse`, `list`, `set` and `status`.

## Validation

Node fixtures exercise URL/id/colour validation, details sanitization and
rate windows. Python tests cover bundled import collisions and metering.
`tests/wallpaper-picker.py` runs the actual shell under private headless Sway,
with isolated HOME/XDG directories, and captures all three Settings tabs in
`/data/tmp/cybexos-onboarding-wallpaper/`. It exercises the read-only default,
bundled apply into a previously missing folder, cached online details, arrow/Enter selection, Tab/Enter apply, Escape,
metered gating and selection without downloading. It needs the Nix dev shell with `grim`, `wtype` and ImageMagick on PATH; it
builds the native notification-image QML module in its private workspace. It makes one live listing
and one detail request; ordinary fixture tests never contact Wallhaven.
This does not qualify installation, Hyprland runtime, physical displays or
a live hyprlock session.
