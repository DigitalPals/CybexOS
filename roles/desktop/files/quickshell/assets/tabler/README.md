# Tabler interface icons

Pinned source: [`@tabler/icons-webfont` 3.48.0](https://www.npmjs.com/package/@tabler/icons-webfont/v/3.48.0),
[upstream repository](https://github.com/tabler/tabler-icons), MIT (see LICENSE).
Archive SHA-256: `0525656a825b56735c2e87e83d9906ad1e3c42f400918c5ae245217909cffd42`.

`outline.ttf` is a subset of Tabler's standard 2px stroke on its 24px design
grid, with unchanged outlines and metrics. Its internal family is renamed
`Cybex Tabler Outline` to avoid collisions with installed Tabler fonts.
`Common/TablerIcons.qml` loads it locally once; no system font installation is
required. All built-in interface icons, including selected states and playback,
use outlines. We do not bundle the filled font or synthesize bold strokes.

Controls communicate selection through their existing colour, background,
border, checkmark, label or switch position. Pinned thread actions use accent
ink; favourite stars retain their amber tint and stronger opacity. Icon colour
fades, button press motion, spinners and panel transitions remain in place.
The old `fill`, `animateFill`, `glyphFill` and `symbolFill` component properties
remain accepted as inert compatibility inputs for existing plugins.

This policy covers interface symbols. Product artwork and application/tray
icons keep their original artwork, and functional UI shapes (switch tracks,
progress meters, radio indicators and status dots) still express their state.

`aliases.json` maps the shell's existing semantic names to canonical Tabler
names, preserving existing built-ins and plugin callers. New code may use any
canonical name included in the generated registry. To add an icon, add a
mapping here (a canonical name can map to itself), then regenerate. Unknown
names render help-circle; empty names render nothing. Weather conditions use
the nearest upstream symbol, so partly cloudy day/night share the cloud icon.

Regenerate from the repository root using a disposable Python environment:

```bash
work=$(mktemp -d /tmp/cybexos-tabler.XXXXXX)
trap 'rm -rf -- "$work"' EXIT
python3 -m venv "$work/venv"
"$work/venv/bin/pip" install fonttools==4.65.0
"$work/venv/bin/python" scripts/update-tabler-icons
node --test tests/quickshell/tabler-icons.test.cjs
```

The generator verifies the archive checksum, subsets the outline font, renames its
family, and writes `Common/TablerGlyphs.js`. Commit those generated files with
changes to the mapping. FontTools is a maintenance dependency only. The tests
read the bundled TTF cmap tables directly, including supplementary codepoints;
they do not depend on system fonts or skip missing font coverage.
