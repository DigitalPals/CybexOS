# Browser experience asset sources

| Asset | Source | Rights information |
| --- | --- | --- |
| `public/wallpapers/moon-mountains-{1280,2560,5120}.png` | Original procedural landscapes from `../scripts/generate-wallpapers.py`; native `moon-mountains.png` and the 2560-pixel web file are byte-identical. All dimensions and generator/file digests are in `../assets/PROVENANCE.json`. | Newly authored geometric artwork under the repository MIT license; no third-party input images. |
| `public/nerdos-logo.svg`, favicon set and web manifest | Supplied NerdOS identity kit, `derived/welcome/` and `derived/web/`; canonical source in `../assets/brand/` | Original project artwork, October 2026, repository MIT license. Outlined Space Grotesk/JetBrains Mono lettering (SIL OFL 1.1); font notices in `../assets/brand/FONT-LICENSES/`. |
| Figtree | `@fontsource/figtree`, installed through the npm lockfile | SIL Open Font License 1.1. Copyright 2022 The Figtree Project Authors, https://github.com/erikdkennedy/figtree. The full license is also shipped in `public/licenses/`. |
| JetBrains Mono | `@fontsource/jetbrains-mono`, installed through the npm lockfile | SIL Open Font License 1.1. Copyright 2020 The JetBrains Mono Project Authors, https://github.com/JetBrains/JetBrainsMono. The full license is also shipped in `public/licenses/`. |
| Interface icons | `lucide-react`, installed through the npm lockfile | ISC license and included upstream notices; the complete license and Feather notices are shipped in `public/licenses/lucide.txt`. |

Font files are bundled and served with the application. They do not depend on
a remote font CDN. Procedural wallpaper choices are drawn with CSS.

Do not apply a repository-wide code license to third-party images or brand
marks without checking their original terms. The former undocumented photograph
and its WebP derivatives have been removed. Run `python3 -B
scripts/generate-wallpapers.py --check` from the repository root to verify the
original replacements. This does not approve the other fonts, dependencies or
marks for public hosting. The [distribution review](../assets/distribution-review.json)
requires owner review of the actual compiled web output; normal builds and tests remain internal.

## Model Usage provider marks

`public/providers/codex.svg` and `public/providers/claude.svg` are unchanged
copies from the native `desktop/quickshell/ModelUsage/assets/`
widget. Its notices identify their source as `basecamp/omarchy` commit
`2c247e390e357ae0fee3f8565b0c816adb705e6a` (MIT). The corresponding notice is
shipped at `public/licenses/model-usage-marks.txt`. Provider marks belong to
their owners and do not imply affiliation or endorsement.

`public/nerdos.svg` and `public/nerdos-white.svg`: unchanged glasses from the
kit's `derived/quickshell/`, original project artwork, MIT. See
`../assets/brand/USAGE.md`. Trademark clearance for NerdOS has not been done.
